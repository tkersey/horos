// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const patterns = @import("call_patterns.zig");
const base = @import("call_patterns_tests.zig").repeated;
const a = std.testing.allocator;
pub const captured: ir.Program = blk: {
    var functions = base.functions[0..4].*;
    functions[2].inputs = &.{ 0, 1, 2 };
    functions[2].layout.slots = &.{ 0, 0, 0, 0, 0 };
    var blocks = base.blocks[0..11].*;
    blocks[1].instructions = &.{.{
        .destination = 4,
        .opcode = .computation,
        .operands = &.{ 0, 1 },
        .immediate = 0,
    }};
    blocks[3].instructions = &.{.{
        .destination = 4,
        .opcode = .computation,
        .operands = &.{ 1, 0 },
        .immediate = 0,
    }};
    blocks[9].instructions = &.{
        .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 0, 2 } },
        .{ .destination = 4, .opcode = .integer_bit_and, .operands = &.{ 3, 1 } },
    };
    blocks[9].terminator.return_value = 4;
    const frozen_functions = functions;
    const frozen_blocks = blocks;
    var program = base;
    program.functions = &frozen_functions;
    program.blocks = &frozen_blocks;
    program.scopes.captures = &.{
        base.scopes.captures[0],
        .{ .fields = &.{ 0, 0 }, .use = .reusable },
    };
    program.constructors = &.{
        .{ .function = 2, .capture = 1, .schema = 3 },
        base.constructors[1],
    };
    break :blk program;
};
test "different runtime captures share one static worker with ordered capture arguments" {
    var candidate = (try patterns.construct(a, captured, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        captured,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 2), candidate.variants.len);
    try std.testing.expectEqual(
        candidate.program.blocks[1].terminator.call.function,
        candidate.program.blocks[3].terminator.call.function,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{ 0, 1, 0, 1 },
        candidate.program.blocks[1].terminator.call.arguments,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{ 0, 1, 1, 0 },
        candidate.program.blocks[3].terminator.call.arguments,
    );
    const entry = candidate.variants[0].first_block;
    try std.testing.expectEqualSlices(
        u64,
        &.{ 0, 6, 1 },
        candidate.program.blocks[entry].terminator.call.arguments,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{ 0, 6, 2 },
        candidate.program.blocks[entry + 1].terminator.call.arguments,
    );
}
test "wrong capture order is admissible but rejected by raw correspondence" {
    var candidate = (try patterns.construct(a, captured, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[1].terminator.call.arguments = &.{ 0, 1, 1, 0 };
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, captured, wrong, candidate.variants, candidate.sites, 1000000),
    );
    const sites = try a.dupe(patterns.Site, candidate.sites);
    defer a.free(sites);
    sites[0].captures = &.{ 1, 0 };
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, captured, wrong, candidate.variants, sites, 1000000),
    );
    blocks[1] = candidate.program.blocks[1];
    blocks[candidate.variants[0].first_block].terminator.call.arguments = &.{ 6, 0, 1 };
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, captured, wrong, candidate.variants, candidate.sites, 1000000),
    );
}
test "a captured value overwritten before the call keeps its closure" {
    var original = captured;
    var blocks = captured.blocks[0..11].*;
    blocks[1].instructions = &.{
        captured.blocks[1].instructions[0],
        .{ .destination = 0, .opcode = .integer_bit_not, .operands = &.{0} },
    };
    original.blocks = &blocks;
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[1].terminator.call.function);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try patterns.run(allocator, captured, null, .{});
    defer result.deinit();
}
test "capture substitution allocation failure releases temporary owners" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}
test "shared compilation selects captured callable specialization" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        captured,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    for (result.program.blocks) |block| try std.testing.expect(block.terminator != .apply);
}
