// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const tails = @import("common_tails.zig");
const a = std.testing.allocator;
pub const repeated: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 0 },
    .schemas = &.{ .u64, .boolean },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 1, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 1,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 2 },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 2 },
        },
    },
};
test "common tail sharing is separate from P01 and removes an identical branch" {
    var baseline = try @import("coalescing.zig").run(a, repeated, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(@as(usize, 3), baseline.program.blocks.len);
    var stats: tails.Statistics = .{};
    var result = try tails.run(a, repeated, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.tails_shared);
    try std.testing.expectEqual(@as(usize, 1), stats.branches_removed);
    try std.testing.expectEqual(@as(usize, 2), result.program.blocks.len);
    try std.testing.expect(
        result.program.blocks[
            @intCast(result.program.functions[0].entry)
        ].terminator == .jump,
    );
}
test "independent checker rejects a forged target and an altered common instruction" {
    var candidate = (try tails.construct(a, repeated, .{})).?;
    defer candidate.deinit();
    try tails.validate(a, repeated, candidate.program, candidate.representatives, .{});
    try std.testing.expectError(
        error.InvalidCommonTail,
        tails.validate(a, repeated, candidate.program, &.{ 0, 1, 0 }, .{}),
    );
    var blocks = candidate.program.blocks[0..3].*;
    blocks[1].instructions = &.{.{ .destination = 2, .opcode = .move, .operands = &.{0} }};
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCommonTail,
        tails.validate(a, repeated, wrong, candidate.representatives, .{}),
    );
}
test "same-looking tails with different failure payloads stay separate" {
    var original = repeated;
    original.constants = &.{
        .{ .schema = 0, .bytes = &.{ 5, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 9, 0, 0, 0, 0, 0, 0, 0 } },
    };
    var blocks = repeated.blocks[0..3].*;
    blocks[1].instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 0 }};
    blocks[1].terminator = .{ .fail = 2 };
    blocks[2].instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 1 }};
    blocks[2].terminator = .{ .fail = 2 };
    original.blocks = &blocks;
    try std.testing.expect(try tails.construct(a, original, .{}) == null);
    var changed = blocks;
    changed[0].terminator = .{ .jump = .{ .block = 1 } };
    var wrong = original;
    wrong.blocks = &changed;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCommonTail,
        tails.validate(a, original, wrong, &.{ 0, 1, 1 }, .{}),
    );
}
test "different custody prevents tail sharing" {
    var original = repeated;
    var functions = repeated.functions[0..1].*;
    functions[0].custody = &.{ .{}, .{ .parent = 0 } };
    original.functions = &functions;
    var blocks = repeated.blocks[0..3].*;
    blocks[2].custody = 1;
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try tails.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try tails.run(allocator, repeated, null, .{});
    defer result.deinit();
}
test "common-tail limits and allocation failure retain mandatory P01" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, repeated, .{});
    defer baseline.deinit();
    var stats: tails.Statistics = .{};
    var result = try tails.run(a, repeated, &stats, .{ .work_limit = 0 });
    defer result.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, result.program),
    );
}

test "shared semantic compiler selects within-function tail sharing" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        repeated,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    try std.testing.expectEqual(@as(usize, 2), result.program.blocks.len);
}

test "branch simplification preserves a preceding failing computation" {
    var original = repeated;
    original.constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }};
    var blocks = repeated.blocks[0..3].*;
    blocks[0].instructions = &.{.{
        .destination = 2,
        .opcode = .integer_div,
        .operands = &.{ 0, 0 },
        .failures = &.{
            .{ .kind = .arithmetic_overflow, .value = 0 },
            .{ .kind = .division_by_zero, .value = 0 },
        },
    }};
    original.blocks = &blocks;
    var candidate = (try tails.construct(a, original, .{})).?;
    defer candidate.deinit();
    try tails.validate(a, original, candidate.program, candidate.representatives, .{});
    try std.testing.expectEqual(.integer_div, candidate.program.blocks[0].instructions[0].opcode);
}
