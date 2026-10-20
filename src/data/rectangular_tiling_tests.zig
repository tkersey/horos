// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const tiling = @import("rectangular_tiling.zig");
const fixture = @import("rectangular_loops_tests.zig");
const own = @import("activation_ownership.zig");
const a = std.testing.allocator;
test "four by four tiles admit partial final tiles and retain the exact body" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try fixture.rectangle(arena.allocator(), 5, 7);
    var candidate = (try tiling.construct(a, original, .{})).?;
    defer candidate.deinit();
    try tiling.validate(a, original, candidate.program, candidate.source, .{});
    try std.testing.expectEqual(@as(usize, 13), candidate.program.blocks.len);
    try std.testing.expectEqual(@as(?u64, 373), tiling.executionWork(candidate.source, 3));
    try std.testing.expect(@import("record_equal.zig").equal(
        []const ir.Instruction,
        original.blocks[4].instructions,
        candidate.program.blocks[8].instructions,
    ));
}
test "admitted wrong final endpoint and wrong tile advance fail independent validation" {
    var candidate = (try tiling.construct(a, fixture.base, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    const end = try a.dupe(ir.Instruction, blocks[4].instructions);
    defer a.free(end);
    // Always selecting the full width would overrun a partial final tile.
    end[2].operands = &.{ 6, 13, 13 };
    blocks[4].instructions = end;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidRectangularTiling,
        tiling.validate(a, fixture.base, forged, candidate.source, .{}),
    );
    @memcpy(blocks, candidate.program.blocks);
    const advance = try a.dupe(ir.Instruction, blocks[10].instructions);
    defer a.free(advance);
    advance[0].operands = &.{10};
    blocks[10].instructions = advance;
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidRectangularTiling,
        tiling.validate(a, fixture.base, forged, candidate.source, .{}),
    );
}
test "tiling proof includes maximum unsigned dimensions without endpoint overflow" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try fixture.rectangle(
        arena.allocator(),
        std.math.maxInt(u64),
        std.math.maxInt(u64),
    );
    var candidate = (try tiling.construct(a, original, .{})).?;
    defer candidate.deinit();
    try tiling.validate(a, original, candidate.program, candidate.source, .{});
    try std.testing.expect(tiling.executionWork(candidate.source, 3) == null);
}

test "observable iteration yield and nonprogressing counters are not tiled" {
    var original = fixture.base;
    var blocks = fixture.base.blocks[0..7].*;
    original.blocks = &blocks;
    blocks[4].terminator = .{ .yield_value = .{ .block = 3 } };
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try tiling.construct(a, original, .{}) == null);
    blocks[4] = fixture.base.blocks[4];
    var constants = fixture.base.constants[0..5].*;
    constants[3].bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 };
    original.constants = &constants;
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try tiling.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try tiling.run(allocator, fixture.base, null, .{});
    defer result.deinit();
}
test "uneconomical tiling retains checked input and cleans every allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: tiling.Statistics = .{};
    var result = try tiling.run(a, fixture.base, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.candidates);
    try std.testing.expect(stats.economic_rejection);
    try std.testing.expectEqual(@as(usize, 0), stats.tiled);
}
