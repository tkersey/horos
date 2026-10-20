// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const borrows = @import("borrow_flow.zig");
const testing = std.testing;

test "stable borrow requirements use the value and owner versions at a store" {
    const writing: ir.Instruction = .{
        .destination = 3,
        .opcode = .cell_set,
        .operands = &.{ 2, 1 },
    };
    const value_rebind: ir.Instruction = .{ .destination = 1, .opcode = .move, .operands = &.{0} };
    const owner_rebind: ir.Instruction = .{ .destination = 2, .opcode = .move, .operands = &.{4} };
    for ([_]bool{ false, true }) |before| {
        const code = if (before) [_]ir.Instruction{
            value_rebind,
            owner_rebind,
            writing,
        } else [_]ir.Instruction{ writing, value_rebind, owner_rebind };
        const program: ir.Program = .{
            .roots = .{ .entry = 1, .result = 0, .failure = 0 },
            .schemas = &.{
                .unit,
                .{ .internal = .{ .capability = 0 } },
                .{ .internal = .{ .cell = .{ .element = 1, .region = 0 } } },
            },
            .constants = &.{.{ .schema = 0, .bytes = &.{} }},
            .effects = &.{.{
                .identity = "borrow/store",
                .payload = 0,
                .result = 0,
                .external = false,
            }},
            .functions = &.{
                .{
                    .entry = 0,
                    .inputs = &.{ 0, 1, 2, 4 },
                    .layout = .{ .slots = &.{ 1, 1, 2, 0, 2 } },
                    .result = 0,
                    .regions = &.{0},
                },
                .{ .entry = 1, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
            },
            .blocks = &.{
                .{ .function = 0, .instructions = &code, .terminator = .{ .return_value = 3 } },
                .{
                    .function = 1,
                    .instructions = &.{.{ .destination = 0, .opcode = .constant }},
                    .terminator = .{ .return_value = 0 },
                },
            },
            .scopes = .{ .region_count = 1 },
        };
        try @import("activation_types.zig").validate(testing.allocator, program);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const facts = try @import("admission.zig").schemas(arena.allocator(), program.schemas);
        var flow = try borrows.StableFlow.init(arena.allocator(), program, facts.exportable);
        const required = try flow.required(0);
        try testing.expectEqual(1, required.len);
        try testing.expectEqual(@as(p.Id, if (before) 0 else 1), required[0].value.parameter);
        try testing.expectEqual(@as(p.Id, if (before) 3 else 2), required[0].owner.parameter);
        try testing.expectEqual(borrows.Bound.region, required[0].bound);
        const suffix = try flow.requiredFrom(0, 1);
        try testing.expectEqual(@as(usize, if (before) 1 else 0), suffix.len);
        if (before) {
            try testing.expect(suffix[0].value.stable_slot and suffix[0].owner.stable_slot);
            try testing.expectEqual(1, suffix[0].value.parameter);
            try testing.expectEqual(4, suffix[0].owner.parameter);
            const at_store = try flow.requiredFrom(0, 2);
            try testing.expectEqual(1, at_store.len);
            try testing.expectEqual(2, at_store[0].owner.parameter);
        }
        try testing.expectEqual(0, (try flow.requiredFrom(0, 3)).len);
    }
}

test "stable borrow tracing follows simultaneous loop transfers and non-prefix inputs" {
    const program: ir.Program = .{
        .roots = .{ .entry = 1, .result = 0, .failure = 0 },
        .schemas = &.{ .unit, .boolean, .{ .internal = .{ .capability = 0 } } },
        .constants = &.{.{ .schema = 0, .bytes = &.{} }},
        .effects = &.{.{ .identity = "borrow/loop", .payload = 0, .result = 0, .external = false }},
        .functions = &.{
            .{
                .entry = 0,
                .inputs = &.{ 2, 0, 1 },
                .layout = .{ .slots = &.{ 2, 2, 1 } },
                .result = 2,
            },
            .{ .entry = 3, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
        },
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 1 } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 1, .assignments = &.{
                    .{ .destination = 0, .source = .{ .slot = 1 } },
                    .{ .destination = 1, .source = .{ .slot = 0 } },
                } },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{
                .function = 1,
                .instructions = &.{.{ .destination = 0, .opcode = .constant }},
                .terminator = .{ .return_value = 0 },
            },
        },
    };
    try @import("activation_types.zig").validate(testing.allocator, program);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const facts = try @import("admission.zig").schemas(arena.allocator(), program.schemas);
    var flow = try borrows.StableFlow.init(arena.allocator(), program, facts.exportable);
    const sources = try flow.returned(0);
    try testing.expectEqual(2, sources.len);
    var found = [_]bool{ false, false };
    for (sources) |source| {
        try testing.expect(source.ambient == null and source.path == 0);
        try testing.expect(source.parameter == 1 or source.parameter == 2);
        found[@intCast(source.parameter - 1)] = true;
    }
    try testing.expect(found[0] and found[1]);
    try testing.expectError(error.InvalidProgram, flow.returned(1));
    const resumed = try flow.returnedFrom(1, 0, 0);
    try testing.expectEqual(2, resumed.len);
    found = .{ false, false };
    for (resumed) |source| {
        try testing.expect(source.stable_slot and source.parameter <= 1);
        found[@intCast(source.parameter)] = true;
    }
    try testing.expect(found[0] and found[1]);
}
