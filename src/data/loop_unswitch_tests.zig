// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const unswitch = @import("loop_unswitch.zig");
const a = std.testing.allocator;

test "profile order spends the one-loop unswitch attempt on the hotter header" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var original = selectable;
    const blocks = try allocator.alloc(ir.Block, 1 + 2 * selectable.blocks.len);
    blocks[0] = .{
        .function = 0,
        .instructions = &.{},
        .terminator = .{ .branch = .{
            .condition = 1,
            .when_true = .{ .block = 1 },
            .when_false = .{ .block = 8 },
        } },
    };
    for ([_]usize{ 1, 8 }) |offset| for (selectable.blocks, 0..) |block, id| {
        blocks[offset + id] = block;
        switch (blocks[offset + id].terminator) {
            .jump => |*edge| edge.block += offset,
            .branch => |*branch| {
                branch.when_true.block += offset;
                branch.when_false.block += offset;
            },
            else => {},
        }
    };
    original.blocks = blocks;
    const counts = try allocator.alloc(u64, blocks.len);
    @memset(counts, 0);
    counts[9] = 100;
    const profile: @import("optimization_profile.zig").Record = .{
        .image_identity = try @import("program_image.zig").identity(a, original),
        .block_counts = counts,
        .total = 100,
    };
    var candidate = (try unswitch.construct(a, original, .{ .profile = profile })).?;
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 9), candidate.witness.header);
    try unswitch.validate(a, original, candidate.program, candidate.witness, .{});
    try std.testing.expect(@import("record_equal.zig").equal(
        ir.Block,
        original.blocks[3],
        candidate.program.blocks[3],
    ));
}
pub const selectable: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .boolean },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{} },
    },
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 0, 2, 0, 0, 0, 2, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 3, .opcode = .constant, .immediate = 0 },
                .{ .destination = 4, .opcode = .constant, .immediate = 0 },
                .{ .destination = 6, .opcode = .constant, .immediate = 1 },
            },
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 5, .opcode = .less, .operands = &.{ 3, 0 } }},
            .terminator = .{ .branch = .{
                .condition = 5,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 6 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 1,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .integer_bit_xor,
                .operands = &.{ 4, 2 },
            }},
            .terminator = .{ .jump = .{ .block = 5 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .integer_bit_or,
                .operands = &.{ 4, 2 },
            }},
            .terminator = .{ .jump = .{ .block = 5 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 3,
                .opcode = .integer_add,
                .operands = &.{ 3, 6 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
            }},
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
    },
};
test "runtime invariant selection yields separately admitted loop copies" {
    var candidate = (try unswitch.construct(a, selectable, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 1), candidate.witness.header);
    try std.testing.expectEqual(@as(usize, 2), candidate.witness.dispatch);
    try unswitch.validate(a, selectable, candidate.program, candidate.witness, .{});
    var stats: unswitch.Statistics = .{};
    var result = try unswitch.run(a, selectable, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.unswitched);
    try std.testing.expectEqual(@as(usize, 10), stats.copied_blocks);
}
test "admitted wrong variant and selector mutations fail independent substitution checks" {
    var candidate = (try unswitch.construct(a, selectable, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    const true_start = blocks[2].terminator.branch.when_true.block;
    const false_start = blocks[2].terminator.branch.when_false.block;
    const true_latch = blocks[@intCast(true_start)].terminator.jump.block;
    const false_latch = blocks[@intCast(false_start)].terminator.jump.block;
    blocks[
        @intCast(true_latch)
    ].terminator.jump.block = blocks[
        @intCast(false_latch)
    ].terminator.jump.block;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidLoopUnswitch,
        unswitch.validate(a, selectable, forged, candidate.witness, .{}),
    );
    @memcpy(blocks, candidate.program.blocks);
    blocks[2].terminator.branch.condition = 5;
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidLoopUnswitch,
        unswitch.validate(a, selectable, forged, candidate.witness, .{}),
    );
}
test "loop-carried condition writes and transfers are not invariant" {
    var original = selectable;
    var blocks = selectable.blocks[0..7].*;
    blocks[2].instructions = &.{.{ .destination = 1, .opcode = .boolean_not, .operands = &.{1} }};
    original.blocks = &blocks;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try unswitch.construct(a, original, .{}) == null);
    blocks[2].instructions = &.{};
    blocks[5].terminator.jump.assignments = &.{.{ .destination = 1, .source = .{ .slot = 5 } }};
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try unswitch.construct(a, original, .{}) == null);
}
test "custody establishment is not cloned across a dispatch boundary" {
    var original = selectable;
    var functions = selectable.functions[0..1].*;
    functions[0].custody = &.{ .{}, .{ .parent = 0 } };
    original.functions = &functions;
    var blocks = selectable.blocks[0..7].*;
    blocks[3].custody = 1;
    original.blocks = &blocks;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try unswitch.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try unswitch.run(allocator, selectable, null, .{});
    defer result.deinit();
}
test "unswitching retains exact P01 on exhausted work or insufficient final code budget" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, selectable, .{});
    defer baseline.deinit();
    var stats: unswitch.Statistics = .{};
    var limited = try unswitch.run(a, selectable, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    var sized = try unswitch.run(a, selectable, &stats, .{ .max_added_bytes = 0 });
    defer sized.deinit();
    try std.testing.expect(stats.code_budget_rejected);
    const identity = @import("program_image.zig").identity;
    try std.testing.expectEqual(
        try identity(a, baseline.program),
        try identity(a, limited.program),
    );
    try std.testing.expectEqual(try identity(a, baseline.program), try identity(a, sized.program));
    var invalid = selectable;
    invalid.roots.entry = 99;
    try std.testing.expectError(
        error.InvalidReference,
        unswitch.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}

pub const cells: ir.Program = .{
    .roots = selectable.roots,
    .schemas = &.{
        .u64,                                                         .unit, .boolean, .{ .internal = .{ .region = 0 } },
        .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 3, 0, 2, 0 },
            .result = 0,
            .use = .reusable,
            .regions = &.{0},
        } } },
    },
    .constants = selectable.constants,
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 2, 0, 5, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 3, 0, 2, 0, 0, 0, 2, 0, 4, 0, 1 } },
            .result = 0,
            .regions = &.{0},
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 3, .opcode = .computation, .immediate = 0 }},
            .terminator = .{ .with_region = .{
                .region = 0,
                .body = 3,
                .arguments = &.{ 0, 1, 2 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 4, .opcode = .constant, .immediate = 0 },
                .{ .destination = 5, .opcode = .constant, .immediate = 0 },
                .{ .destination = 7, .opcode = .constant, .immediate = 1 },
            },
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 6, .opcode = .less, .operands = &.{ 4, 1 } }},
            .terminator = .{ .branch = .{
                .condition = 6,
                .when_true = .{ .block = 4 },
                .when_false = .{ .block = 8 },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 8, .opcode = .cell_new, .operands = &.{ 0, 3 } },
                .{ .destination = 9, .opcode = .cell_get, .operands = &.{8} },
            },
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 5 },
                .when_false = .{ .block = 6 },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 10, .opcode = .cell_set, .operands = &.{ 8, 4 } },
                .{ .destination = 9, .opcode = .cell_get, .operands = &.{8} },
                .{ .destination = 5, .opcode = .integer_bit_xor, .operands = &.{ 5, 9 } },
            },
            .terminator = .{ .jump = .{ .block = 7 } },
        },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 10, .opcode = .cell_set, .operands = &.{ 8, 3 } },
                .{ .destination = 9, .opcode = .cell_get, .operands = &.{8} },
                .{ .destination = 5, .opcode = .integer_bit_or, .operands = &.{ 5, 9 } },
            },
            .terminator = .{ .jump = .{ .block = 7 } },
        },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .integer_add,
                .operands = &.{ 4, 7 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
            }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 5 } },
    },
    .scopes = .{ .region_count = 1, .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 5 }},
};
test "region-local cell allocation and mutation remain in each specialized iteration" {
    var admitted = try own.analyze(a, cells);
    admitted.deinit();
    var candidate = (try unswitch.construct(a, cells, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 4), candidate.witness.dispatch);
    try unswitch.validate(a, cells, candidate.program, candidate.witness, .{});
}
fn cellAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try unswitch.run(allocator, cells, null, .{});
    defer result.deinit();
}
test "copied region-local loops clean up allocation failures" {
    try @import("allocation_testing.zig").check(a, cellAllocationAttempt, .{});
}

pub fn branchCells(allocator: std.mem.Allocator) !ir.Program {
    var program = cells;
    const blocks = try allocator.dupe(ir.Block, cells.blocks);
    const prefix = cells.blocks[4].instructions;
    blocks[4].instructions = &.{};
    for ([_]usize{ 5, 6 }) |id| {
        const original = cells.blocks[id].instructions;
        const instructions = try allocator.alloc(ir.Instruction, prefix.len + original.len);
        @memcpy(instructions[0..prefix.len], prefix);
        @memcpy(instructions[prefix.len..], original);
        blocks[id].instructions = instructions;
    }
    program.blocks = blocks;
    return program;
}
test "branch-local allocations provide a removable dispatch without moving a prefix" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try branchCells(arena.allocator());
    var candidate = (try unswitch.construct(a, original, .{})).?;
    defer candidate.deinit();
    try unswitch.validate(a, original, candidate.program, candidate.witness, .{});
    const cost = @import("loop_motion.zig").repeatedWorkEstimate;
    try std.testing.expect((try cost(a, candidate.program)).?.branch_tests < (try cost(a, original)).?.branch_tests);
    try std.testing.expectEqual(@as(u64, 0), (try cost(a, cells)).?.branch_tests);
}
