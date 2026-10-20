// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const reduce = @import("induction_reduction.zig");
const base = @import("loop_motion_tests.zig").counted;
const a = std.testing.allocator;
pub const guarded: ir.Program = .{
    .roots = base.roots,
    .schemas = base.schemas,
    .constants = base.constants,
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 0, 0, 0, 0, 0, 2, 0, 0, 2, 1 } },
        .result = 0,
    }},
    .blocks = &.{
        base.blocks[0],
        .{
            .function = 0,
            .instructions = base.blocks[1].instructions,
            .terminator = .{ .branch = .{
                .condition = 5,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 4 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 8, .opcode = .less, .operands = &.{ 3, 0 } }},
            .terminator = .{ .branch = .{
                .condition = 8,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 5 },
            } },
        },
        base.blocks[2],
        base.blocks[3],
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 9, .opcode = .constant, .immediate = 2 }},
            .terminator = .{ .fail = 9 },
        },
    },
};
test "finite unit induction removes an exact repeated bounds relation" {
    var candidate = (try reduce.construct(a, guarded, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 2), candidate.witness.block);
    try reduce.validate(a, guarded, candidate.program, candidate.witness, .{});
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, guarded, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.guards_removed);
}
test "admitted wrong success edge is not an induction rewrite" {
    var candidate = (try reduce.construct(a, guarded, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[2].terminator.jump.block = 5;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidInductionReduction,
        reduce.validate(a, guarded, forged, candidate.witness, .{}),
    );
}
test "a distinct bound and a counter update before the check remain observable" {
    var program = guarded;
    var blocks = guarded.blocks[0..6].*;
    blocks[2].instructions = &.{.{ .destination = 8, .opcode = .less, .operands = &.{ 3, 1 } }};
    program.blocks = &blocks;
    var admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try reduce.construct(a, program, .{}) == null);
    blocks[2].instructions = &.{
        guarded.blocks[3].instructions[2],
        guarded.blocks[2].instructions[0],
    };
    admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try reduce.construct(a, program, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try reduce.run(allocator, guarded, null, .{});
    defer result.deinit();
}
test "induction reduction cleans allocation failures and preserves zero-work admission" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: reduce.Statistics = .{};
    var limited = try reduce.run(a, guarded, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    var baseline = try @import("coalescing.zig").run(a, guarded, .{});
    defer baseline.deinit();
    try std.testing.expect(stats.work_limit);
    const identity = @import("program_image.zig").identity;
    try std.testing.expectEqual(
        try identity(a, baseline.program),
        try identity(a, limited.program),
    );
    var invalid = guarded;
    invalid.roots.entry = 99;
    try std.testing.expectError(
        error.InvalidReference,
        reduce.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}

pub fn sequenceGuard(allocator: std.mem.Allocator, use_capacity: bool) !ir.Program {
    var program = guarded;
    program.roots.failure = 0;
    program.schemas = &.{
        .u64,                                            .unit,                  .boolean,
        .{ .vector = .{ .element = 1, .maximum = 50 } }, .{ .sum = &.{ 1, 1 } },
    };
    program.constants = &.{
        guarded.constants[0],                                     guarded.constants[1],
        .{ .schema = 0, .bytes = &.{ 99, 0, 0, 0, 0, 0, 0, 0 } },
        .{
            .schema = 0,
            .bytes = &.{ 73, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{ .schema = 0, .bytes = &.{ 50, 0, 0, 0, 0, 0, 0, 0 } },
    };
    const functions = try allocator.dupe(ir.Function, program.functions);
    functions[0].layout.slots = &.{ 3, 0, 0, 0, 0, 2, 0, 0, 2, 0, 0, 4, 0, 1 };
    program.functions = functions;
    const blocks = try allocator.dupe(ir.Block, program.blocks);
    const init = try allocator.alloc(ir.Instruction, blocks[0].instructions.len + 2);
    @memcpy(init[0..blocks[0].instructions.len], blocks[0].instructions);
    init[init.len - 2] = .{ .destination = 10, .opcode = .sequence_length, .operands = &.{0} };
    init[init.len - 1] = .{ .destination = 12, .opcode = .constant, .immediate = 4 };
    blocks[0].instructions = init;
    blocks[1].instructions = try allocator.dupe(
        ir.Instruction,
        &.{.{
            .destination = 5,
            .opcode = .less,
            .operands = try allocator.dupe(
                p.Id,
                &.{ 3, if (use_capacity) @as(p.Id, 12) else 10 },
            ),
        }},
    );
    blocks[2].instructions = &.{.{ .destination = 8, .opcode = .less, .operands = &.{ 3, 10 } }};
    const work = try allocator.alloc(ir.Instruction, blocks[3].instructions.len + 2);
    work[0] = .{ .destination = 11, .opcode = .sequence_get, .operands = &.{ 0, 3 } };
    work[1] = .{
        .destination = 13,
        .opcode = .variant_payload,
        .operands = &.{11},
        .immediate = 1,
        .failures = &.{.{ .kind = .invalid_variant, .value = 3 }},
    };
    @memcpy(work[2..], blocks[3].instructions);
    blocks[3].instructions = work;
    program.blocks = blocks;
    return program;
}
test "actual length guards can be reused but capacity cannot replace the actual length" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const exact = try sequenceGuard(arena.allocator(), false);
    var candidate = (try reduce.construct(a, exact, .{})).?;
    defer candidate.deinit();
    try reduce.validate(a, exact, candidate.program, candidate.witness, .{});
    const capacity = try sequenceGuard(arena.allocator(), true);
    var admitted = try own.analyze(a, capacity);
    admitted.deinit();
    try std.testing.expect(try reduce.construct(a, capacity, .{}) == null);
}
