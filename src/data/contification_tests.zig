// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const joins = @import("contification.zig");
const a = std.testing.allocator;
pub const shared: ir.Program = .{
    .roots = .{ .entry = 0, .result = 2, .failure = 3 },
    .schemas = &.{ .u64, .boolean, .{ .product = &.{ 0, 0 } }, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 1, 1, 2 } },
            .result = 2,
        },
        .{
            .entry = 4,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 1, 2 } },
            .result = 2,
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 1, 3 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 1, 0, 3 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{
                    .block = 5,
                    .assignments = &.{
                        .{ .destination = 0, .source = .{ .slot = 1 } },
                        .{ .destination = 1, .source = .{ .slot = 0 } },
                    },
                },
                .when_false = .{ .block = 5 },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 3, .opcode = .product, .operands = &.{ 0, 1 } }},
            .terminator = .{ .return_value = 3 },
        },
    },
};
test "two predecessors share one local body with parallel argument and swap edges" {
    var candidate = (try joins.construct(a, shared, .{})).?;
    defer candidate.deinit();
    try joins.validate(a, shared, candidate.program, candidate.witness, .{});
    try std.testing.expectEqual(@as(usize, 8), candidate.program.blocks.len);
    try std.testing.expectEqual(
        candidate.program.blocks[1].terminator.jump.block,
        candidate.program.blocks[2].terminator.jump.block,
    );
    const transfers = candidate.program.blocks[6].terminator.branch.when_true.assignments;
    try std.testing.expectEqual(@as(u64, 6), transfers[0].source.slot);
    try std.testing.expectEqual(@as(u64, 5), transfers[1].source.slot);
    var stats: joins.Statistics = .{};
    var result = try joins.run(a, shared, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.program.functions.len);
    try std.testing.expectEqual(@as(usize, 2), stats.calls_removed);
    var products: usize = 0;
    for (result.program.blocks) |block| {
        try std.testing.expect(block.terminator != .call);
        for (block.instructions) |op| {
            if (op.opcode == .product) products += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), products);
    std.debug.print(
        "shared join bytes: {d} -> {d}\n",
        .{
            try @import("program_image.zig").encodedLength(shared),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}
test "admissible wrong incoming argument and swapped-edge mutations reject" {
    var candidate = (try joins.construct(a, shared, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..8].*;
    var assignments = blocks[1].terminator.jump.assignments[0..3].*;
    assignments[0].source = .{ .slot = 1 };
    blocks[1].terminator.jump.assignments = &assignments;
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidContification,
        joins.validate(a, shared, wrong, candidate.witness, .{}),
    );
    blocks[1] = candidate.program.blocks[1];
    var swap = blocks[6].terminator.branch.when_true.assignments[0..2].*;
    swap[1].source.slot = 6;
    blocks[6].terminator.branch.when_true.assignments = &swap;
    try std.testing.expectError(
        error.InvalidContification,
        joins.validate(a, shared, wrong, candidate.witness, .{}),
    );
}
test "different continuations retain the helper" {
    var original = shared;
    var blocks: [7]ir.Block = undefined;
    @memcpy(blocks[0..6], shared.blocks);
    blocks[2].terminator.call.next.block = 6;
    blocks[6] = .{
        .function = 0,
        .instructions = &.{.{ .destination = 4, .opcode = .product, .operands = &.{ 1, 0 } }},
        .terminator = .{ .return_value = 4 },
    };
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try joins.construct(a, original, .{}) == null);
}
test "suspension before a call and nested custody remain outside the join domain" {
    var original = shared;
    var blocks = shared.blocks[0..6].*;
    blocks[0].terminator = .{ .yield_value = .{ .block = 1 } };
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try joins.construct(a, original, .{}) == null);
    blocks[0] = shared.blocks[0];
    blocks[1].custody = 1;
    var functions = shared.functions[0..2].*;
    functions[0].custody = &.{ .{}, .{ .parent = 0 } };
    original.functions = &functions;
    var scoped = try @import("activation_ownership.zig").analyze(a, original);
    defer scoped.deinit();
    try std.testing.expect(try joins.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try joins.run(allocator, shared, null, .{});
    defer result.deinit();
}
test "join allocation and budget exhaustion preserve the P01 baseline" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, shared, .{});
    defer baseline.deinit();
    for ([_]joins.Options{
        .{ .work_limit = 0 },
        .{ .max_blocks = 0 },
        .{ .max_slots = 0 },
        .{ .max_added_bytes = 0 },
    }) |options| {
        var stats: joins.Statistics = .{};
        var result = try joins.run(a, shared, &stats, options);
        defer result.deinit();
        try std.testing.expect(stats.work_limit);
        try std.testing.expectEqual(
            try @import("program_image.zig").identity(a, baseline.program),
            try @import("program_image.zig").identity(a, result.program),
        );
    }
}

test "shared pipeline selects a single relocated join body" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        shared,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    try std.testing.expectEqual(@as(usize, 1), result.program.functions.len);
}

test "constructor-addressable helpers retain their callable interface" {
    var original = shared;
    original.schemas = &.{
        shared.schemas[0], shared.schemas[1], shared.schemas[2], shared.schemas[3],
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 0, 0, 1 },
            .result = 2,
            .use = .reusable,
        } } },
    };
    original.scopes.captures = &.{.{ .fields = &.{}, .use = .reusable }};
    original.constructors = &.{.{ .function = 1, .capture = 0, .schema = 4 }};
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try joins.construct(a, original, .{}) == null);
}

test "return-only continuation may return an original caller value" {
    var original = shared;
    original.roots.result = 0;
    var functions = shared.functions[0..2].*;
    functions[0].result = 0;
    original.functions = &functions;
    var blocks = shared.blocks[0..6].*;
    blocks[3].terminator.return_value = 0;
    original.blocks = &blocks;
    var candidate = (try joins.construct(a, original, .{})).?;
    defer candidate.deinit();
    try joins.validate(a, original, candidate.program, candidate.witness, .{});
    try std.testing.expectEqual(@as(u64, 0), candidate.program.blocks[7].terminator.return_value);
    var changed = candidate.program.blocks[0..8].*;
    changed[7].terminator.return_value = 5;
    var wrong = candidate.program;
    wrong.blocks = &changed;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidContification,
        joins.validate(a, original, wrong, candidate.witness, .{}),
    );
}
test "a continuation with real work cannot be bypassed by a direct return" {
    var original = shared;
    var blocks = shared.blocks[0..6].*;
    blocks[3].instructions = &.{.{ .destination = 4, .opcode = .product, .operands = &.{ 0, 1 } }};
    original.blocks = &blocks;
    var candidate = (try joins.construct(a, original, .{})).?;
    defer candidate.deinit();
    try joins.validate(a, original, candidate.program, candidate.witness, .{});
    try std.testing.expect(candidate.program.blocks[7].terminator == .jump);
    var changed = candidate.program.blocks[0..8].*;
    changed[7].terminator = .{ .return_value = 8 };
    var wrong = candidate.program;
    wrong.blocks = &changed;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidContification,
        joins.validate(a, original, wrong, candidate.witness, .{}),
    );
}
