// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const outline = @import("outlining.zig");
const a = std.testing.allocator;
pub const repeated: ir.Program = blk: {
    @setEvalBranchQuota(10000);
    var slots: [53]p.Id = @splat(0);
    slots[2] = 1;
    var left: [25]ir.Instruction = undefined;
    var right: [25]ir.Instruction = undefined;
    left[0] = .{ .destination = 3, .opcode = .constant };
    right[0] = .{ .destination = 28, .opcode = .constant };
    for (1..25) |i| {
        const op: p.Opcode = switch ((i - 1) % 3) {
            0 => .integer_bit_xor,
            1 => .integer_bit_not,
            else => .integer_bit_or,
        };
        left[i] = .{
            .destination = 3 + i,
            .opcode = op,
            .operands = if (op == .integer_bit_not) &.{2 + i} else &.{
                if (i == 1) 0 else 2 + i,
                3,
            },
        };
        right[i] = .{
            .destination = 28 + i,
            .opcode = op,
            .operands = if (op == .integer_bit_not) &.{27 + i} else &.{
                if (i == 1) 1 else 27 + i,
                28,
            },
        };
    }
    const frozen_slots = slots;
    const frozen_left = left;
    const frozen_right = right;
    break :blk .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{ .u64, .boolean },
        .constants = &.{.{
            .schema = 0,
            .bytes = &.{ 0x15, 0x7c, 0x4a, 0x7f, 0xb9, 0x79, 0x37, 0x9e },
        }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &frozen_slots },
            .result = 0,
        }},
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
            .{ .function = 0, .instructions = &frozen_left, .terminator = .{ .return_value = 27 } },
            .{
                .function = 0,
                .instructions = &frozen_right,
                .terminator = .{ .return_value = 52 },
            },
        },
    };
};
test "two normalized pure sequences share one private worker" {
    var candidate = (try outline.construct(a, repeated, .{})).?;
    defer candidate.deinit();
    try outline.validate(a, repeated, candidate.program, candidate.sites, .{});
    try std.testing.expectEqual(@as(usize, 2), candidate.sites.len);
    try std.testing.expectEqualSlices(u64, &.{0}, candidate.sites[0].arguments);
    try std.testing.expectEqualSlices(u64, &.{1}, candidate.sites[1].arguments);
    var stats: outline.Statistics = .{};
    var result = try outline.run(a, repeated, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.calls_added);
    try std.testing.expectEqual(@as(usize, 25), stats.instructions_shared);
    try std.testing.expectEqual(@as(usize, 2), result.program.functions.len);
}
test "independent checker rejects an admissible wrong call argument" {
    var candidate = (try outline.construct(a, repeated, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..6].*;
    blocks[1].terminator.call.arguments = &.{1};
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidOutlining,
        outline.validate(a, repeated, wrong, candidate.sites, .{}),
    );
    var sites = candidate.sites[0..2].*;
    sites[0].arguments = &.{1};
    try std.testing.expectError(
        error.InvalidOutlining,
        outline.validate(a, repeated, wrong, &sites, .{}),
    );
}
test "different custody and a failing operation are not outline opportunities" {
    var original = repeated;
    var functions = repeated.functions[0..1].*;
    functions[0].custody = &.{ .{}, .{ .parent = 0 } };
    original.functions = &functions;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try outline.construct(a, original, .{}) == null);
    original = repeated;
    var blocks = repeated.blocks[0..3].*;
    var ops = repeated.blocks[1].instructions[0..25].*;
    ops[1] = .{
        .destination = 4,
        .opcode = .integer_div,
        .operands = &.{ 0, 3 },
        .failures = &.{
            .{ .kind = .arithmetic_overflow, .value = 0 },
            .{ .kind = .division_by_zero, .value = 0 },
        },
    };
    blocks[1].instructions = &ops;
    original.blocks = &blocks;
    var failing = try @import("activation_ownership.zig").analyze(a, original);
    defer failing.deinit();
    try std.testing.expect(try outline.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try outline.run(allocator, repeated, null, .{});
    defer result.deinit();
}
test "outline allocation and work limits preserve the canonical baseline" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, repeated, .{});
    defer baseline.deinit();
    for ([_]outline.Options{ .{ .work_limit = 0 }, .{ .max_sites = 1 } }) |options| {
        var stats: outline.Statistics = .{};
        var result = try outline.run(a, repeated, &stats, options);
        defer result.deinit();
        try std.testing.expect(stats.work_limit);
        try std.testing.expectEqual(
            try @import("program_image.zig").identity(a, baseline.program),
            try @import("program_image.zig").identity(a, result.program),
        );
    }
}

test "shared pipeline retains one worker without an inline-outline cycle" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        repeated,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    try std.testing.expectEqual(@as(usize, 2), result.program.functions.len);
    var again = try @import("closed_compilation.zig").run(
        a,
        result.program,
        .{ .contract = .semantic },
    );
    defer again.deinit();
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, result.program),
        try @import("program_image.zig").identity(a, again.program),
    );
}
test "outlined call cannot be redirected to an existing handler authority" {
    var original = repeated;
    original.functions = &.{
        repeated.functions[0],
        .{ .entry = 3, .inputs = &.{0}, .layout = repeated.functions[0].layout, .result = 0 },
    };
    var blocks: [4]ir.Block = undefined;
    @memcpy(blocks[0..3], repeated.blocks);
    blocks[3] = repeated.blocks[1];
    blocks[3].function = 1;
    original.blocks = &blocks;
    original.handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 1,
        .clauses = &.{},
    }};
    var candidate = (try outline.construct(a, original, .{})).?;
    defer candidate.deinit();
    const changed = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(changed);
    changed[1].terminator.call.function = 1;
    var wrong = candidate.program;
    wrong.blocks = changed;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidOutlining,
        outline.validate(a, original, wrong, candidate.sites, .{}),
    );
}
