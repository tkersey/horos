// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const inline_leaf = @import("leaf_inlining.zig");
const a = std.testing.allocator;
pub const product: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .{ .product = &.{ 0, 0 } } },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 2, 0 } },
            .result = 0,
        },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{ 2, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{2},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 1,
                .opcode = .field,
                .operands = &.{0},
                .immediate = 1,
            }},
            .terminator = .{ .return_value = 1 },
        },
    },
};
test "leaf substitution exposes a local product cancellation" {
    var stats: inline_leaf.Statistics = .{};
    var inlined = try inline_leaf.run(a, product, &stats, .{});
    defer inlined.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.calls_removed);
    try std.testing.expectEqual(@as(usize, 1), inlined.program.functions.len);
    var reduced = try @import("aggregate_reduction.zig").run(a, inlined.program, null, .{});
    defer reduced.deinit();
    var dead = try @import("dead_computation.zig").run(a, reduced.program, null, .{});
    defer dead.deinit();
    for (dead.program.blocks) |block| for (block.instructions) |op| try std.testing.expect(
        op.opcode != .product and op.opcode != .field,
    );
}
test "independent leaf validator rejects admissible wrong field and return substitution" {
    var candidate = (try inline_leaf.construct(a, product, .{})).?;
    defer candidate.deinit();
    try inline_leaf.validate(a, product, candidate.program, candidate.sites, .{});
    var blocks = candidate.program.blocks[0..3].*;
    var instructions = blocks[0].instructions[0..2].*;
    blocks[0].instructions = &instructions;
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    instructions[1].immediate = 0;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidLeafInlining,
        inline_leaf.validate(a, product, wrong, candidate.sites, .{}),
    );
    instructions[1].immediate = 1;
    blocks[0].terminator.jump.assignments = &.{.{ .destination = 3, .source = .{ .slot = 0 } }};
    try std.testing.expectError(
        error.InvalidLeafInlining,
        inline_leaf.validate(a, product, wrong, candidate.sites, .{}),
    );
}
pub const overwrite: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{0},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .return_value = 2 },
        },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 0,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 0 },
        },
    },
};
test "callee overwrites become fresh caller definitions" {
    var candidate = (try inline_leaf.construct(a, overwrite, .{})).?;
    defer candidate.deinit();
    try inline_leaf.validate(a, overwrite, candidate.program, candidate.sites, .{});
    try std.testing.expectEqual(
        @as(u64, 3),
        candidate.program.blocks[0].instructions[0].destination,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{0},
        candidate.program.blocks[0].instructions[0].operands,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        candidate.program.blocks[0].terminator.jump.assignments[0].source.slot,
    );
}
test "Boolean return composition inlines with independently checked select order" {
    var original = overwrite;
    original.schemas = &.{ .boolean, .unit };
    var functions = overwrite.functions[0..2].*;
    functions[1].layout.slots = &.{ 0, 0, 0 };
    original.functions = &functions;
    var blocks = overwrite.blocks[0..3].*;
    blocks[1].instructions = &.{};
    blocks[1].terminator = .{ .return_value = 1 };
    blocks[2].instructions = &.{
        .{ .destination = 1, .opcode = .boolean_not, .operands = &.{0} },
        .{ .destination = 2, .opcode = .select, .operands = &.{ 0, 1, 0 } },
    };
    blocks[2].terminator = .{ .return_value = 2 };
    original.blocks = &blocks;
    var candidate = (try inline_leaf.construct(a, original, .{})).?;
    defer candidate.deinit();
    try inline_leaf.validate(a, original, candidate.program, candidate.sites, .{});
    try std.testing.expectEqual(@as(usize, 1), candidate.sites.len);
    var changed_blocks = candidate.program.blocks[0..3].*;
    var changed_ops = changed_blocks[0].instructions[0..2].*;
    const operands = changed_ops[1].operands;
    const swapped = [_]u64{ operands[0], operands[2], operands[1] };
    changed_ops[1].operands = &swapped;
    changed_blocks[0].instructions = &changed_ops;
    var forged = candidate.program;
    forged.blocks = &changed_blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, forged);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidLeafInlining,
        inline_leaf.validate(a, original, forged, candidate.sites, .{}),
    );
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try inline_leaf.run(allocator, product, null, .{});
    defer result.deinit();
}
test "leaf work and site limits roll back to P01 and allocation failure releases owners" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, product, .{});
    defer baseline.deinit();
    for ([_]inline_leaf.Options{ .{ .work_limit = 0 }, .{ .max_sites = 0 } }) |options| {
        var stats: inline_leaf.Statistics = .{};
        var result = try inline_leaf.run(a, product, &stats, options);
        defer result.deinit();
        try std.testing.expect(stats.work_limit);
        try std.testing.expectEqual(
            try @import("program_image.zig").identity(a, baseline.program),
            try @import("program_image.zig").identity(a, result.program),
        );
    }
}
test "handler authority excludes an otherwise identical leaf" {
    var original = overwrite;
    original.handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 1,
        .clauses = &.{},
    }};
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try inline_leaf.construct(a, original, .{}) == null);
}

test "shared pipeline cancels product exposed by leaf inlining" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        product,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    for (result.program.blocks) |block| {
        try std.testing.expect(block.terminator != .call);
        for (block.instructions) |op| try std.testing.expect(
            op.opcode != .product and op.opcode != .field,
        );
    }
}
test "non-leaf recursion is retained without unfolding" {
    var original = overwrite;
    var blocks = overwrite.blocks[0..3].*;
    blocks[2].instructions = &.{};
    blocks[2].terminator = .{ .call = .{
        .function = 1,
        .arguments = &.{0},
        .next = .{ .block = 2, .assignments = &.{.{ .destination = 0, .source = .returned }} },
    } };
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try inline_leaf.construct(a, original, .{}) == null);
}
test "return transfers retain simultaneous predecessor arguments" {
    var original = overwrite;
    var blocks = overwrite.blocks[0..3].*;
    blocks[0].terminator.call.next.assignments = &.{
        .{ .destination = 0, .source = .returned },
        .{ .destination = 1, .source = .{ .slot = 0 } },
    };
    original.blocks = &blocks;
    var candidate = (try inline_leaf.construct(a, original, .{})).?;
    defer candidate.deinit();
    try inline_leaf.validate(a, original, candidate.program, candidate.sites, .{});
    const transfers = candidate.program.blocks[0].terminator.jump.assignments;
    try std.testing.expectEqual(@as(u64, 3), transfers[0].source.slot);
    try std.testing.expectEqual(@as(u64, 0), transfers[1].source.slot);
}
