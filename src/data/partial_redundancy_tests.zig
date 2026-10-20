const std = @import("std");
const ir = @import("activation.zig");
const pre = @import("partial_redundancy.zig");
const a = std.testing.allocator;
pub const diamond: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .boolean, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2, 3 },
        .layout = .{ .slots = &.{ 0, 0, 1, 1, 0, 0 } },
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
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 3 } } },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 5,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .return_value = 5 },
        },
    },
};
pub fn critical() ir.Program {
    var program = diamond;
    program.blocks = &.{
        diamond.blocks[0], diamond.blocks[1],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 3,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        diamond.blocks[3],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        },
    };
    return program;
}
test "PRE computes on the missing predecessor and reuses the other definition" {
    var candidate = (try pre.construct(a, diamond, 100000)).?;
    defer candidate.deinit();
    try pre.validate(a, diamond, candidate.program, candidate.witness, 100000);
    try std.testing.expectEqual(@as(usize, 0), candidate.program.blocks[3].instructions.len);
    try std.testing.expectEqual(@as(usize, 1), candidate.program.blocks[2].instructions.len);
    var stats: pre.Statistics = .{};
    var result = try pre.run(a, diamond, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.reused_paths);
    try std.testing.expectEqual(@as(usize, 1), stats.computed_paths);
    try std.testing.expectEqual(@as(usize, 0), stats.split_edges);
}
test "PRE splits only the edge to the join and preserves an early return" {
    const original = comptime critical();
    var candidate = (try pre.construct(a, original, 100000)).?;
    defer candidate.deinit();
    try pre.validate(a, original, candidate.program, candidate.witness, 100000);
    try std.testing.expectEqual(@as(usize, 6), candidate.program.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), candidate.program.blocks[2].instructions.len);
    try std.testing.expectEqualDeep(
        original.blocks[2].terminator.branch.when_false,
        candidate.program.blocks[2].terminator.branch.when_false,
    );
    try std.testing.expectEqual(
        @as(u64, 5),
        candidate.program.blocks[2].terminator.branch.when_true.block,
    );
}
test "PRE independently rejects a wrong reused value and an omitted incoming path" {
    var candidate = (try pre.construct(a, diamond, 100000)).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[1].terminator.jump.assignments = &.{.{ .destination = 5, .source = .{ .slot = 0 } }};
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidPartialRedundancy,
        pre.validate(a, diamond, wrong, candidate.witness, 100000),
    );
    var incomplete = candidate.witness;
    incomplete.paths = incomplete.paths[0..1];
    try std.testing.expectError(
        error.InvalidPartialRedundancy,
        pre.validate(a, diamond, candidate.program, incomplete, 100000),
    );
}
test "PRE does not treat overwritten operands as the same value version" {
    var original = diamond;
    var blocks = diamond.blocks[0..4].*;
    blocks[1].instructions = &.{
        diamond.blocks[1].instructions[0],
        .{ .destination = 0, .opcode = .move, .operands = &.{1} },
    };
    original.blocks = &blocks;
    var candidate = try pre.construct(a, original, 100000);
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}
test "PRE cannot speculate failing arithmetic" {
    var original = diamond;
    original.constants = &.{.{ .schema = 2, .bytes = &.{} }};
    var blocks = diamond.blocks[0..4].*;
    blocks[1].instructions = &.{.{
        .destination = 4,
        .opcode = .integer_div,
        .operands = &.{ 0, 1 },
        .failures = &.{
            .{ .kind = .arithmetic_overflow, .value = 0 },
            .{ .kind = .division_by_zero, .value = 0 },
        },
    }};
    blocks[3].instructions = &.{.{
        .destination = 5,
        .opcode = .integer_div,
        .operands = &.{ 0, 1 },
        .failures = &.{
            .{ .kind = .arithmetic_overflow, .value = 0 },
            .{ .kind = .division_by_zero, .value = 0 },
        },
    }};
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var candidate = try pre.construct(a, original, 100000);
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try pre.run(allocator, comptime critical(), null, .{});
    defer result.deinit();
}
test "PRE allocation failures and work exhaustion preserve original ownership" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: pre.Statistics = .{};
    var limited = try pre.run(a, diamond, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    var baseline = try @import("coalescing.zig").run(a, diamond, .{});
    defer baseline.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
}

pub fn liveDiamond() ir.Program {
    var program = diamond;
    program.roots.result = 1;
    program.functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2, 3 },
        .layout = .{ .slots = &.{ 0, 0, 1, 1, 1, 1 } },
        .result = 1,
    }};
    program.blocks = &.{
        diamond.blocks[0],
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 4, .opcode = .equal, .operands = &.{ 0, 1 } }},
            .terminator = .{ .branch = .{
                .condition = 4,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        diamond.blocks[2],
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 5, .opcode = .equal, .operands = &.{ 0, 1 } }},
            .terminator = .{ .return_value = 5 },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
    };
    return program;
}
test "shared semantic compiler consumes PRE with path-sensitive cost" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        comptime liveDiamond(),
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.applied, stats.outcome);
    try std.testing.expectEqual(.full, stats.selected_candidate);
    // The arm comparison is also a live branch condition, so DCE cannot erase
    // the original partial redundancy before this stage.
    var joins_without_expression: usize = 0;
    for (result.program.blocks) |block|
        if (block.instructions.len == 0 and
            block.terminator == .return_value)
        {
            joins_without_expression += 1;
        };
    try std.testing.expect(joins_without_expression != 0);
}
test "PRE computes after parallel edge writes on the missing path" {
    var original = diamond;
    var blocks = diamond.blocks[0..4].*;
    blocks[2].terminator.jump.assignments = &.{.{ .destination = 0, .source = .{ .slot = 1 } }};
    original.blocks = &blocks;
    var candidate = (try pre.construct(a, original, 100000)).?;
    defer candidate.deinit();
    try pre.validate(a, original, candidate.program, candidate.witness, 100000);
    try std.testing.expectEqual(@as(usize, 5), candidate.program.blocks.len);
    try std.testing.expectEqual(@as(u64, 4), candidate.program.blocks[2].terminator.jump.block);
    try std.testing.expectEqualDeep(
        blocks[2].terminator.jump.assignments,
        candidate.program.blocks[2].terminator.jump.assignments,
    );
}
test "PRE checker rejects a forged source after operand mutation" {
    var candidate = (try pre.construct(a, diamond, 100000)).?;
    defer candidate.deinit();
    var original = diamond;
    var before = diamond.blocks[0..4].*;
    before[1].instructions = &.{
        diamond.blocks[1].instructions[0],
        .{ .destination = 0, .opcode = .move, .operands = &.{1} },
    };
    original.blocks = &before;
    const after = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(after);
    after[1].instructions = before[1].instructions;
    var wrong = candidate.program;
    wrong.blocks = after;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidPartialRedundancy,
        pre.validate(a, original, wrong, candidate.witness, 100000),
    );
}
test "PRE does not cross different lexical custody" {
    var original = diamond;
    var function = diamond.functions[0];
    function.custody = &.{ .{}, .{ .parent = 0 } };
    original.functions = &.{function};
    var blocks = diamond.blocks[0..4].*;
    blocks[1].custody = 1;
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var candidate = try pre.construct(a, original, 100000);
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}

test "PRE rejects an admissible speculative evaluation on an early-return predecessor" {
    const original = comptime critical();
    var candidate = (try pre.construct(a, original, 100000)).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[2].instructions = original.blocks[3].instructions;
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidPartialRedundancy,
        pre.validate(a, original, wrong, candidate.witness, 100000),
    );
}

const PredecessorRegionFixture = struct {
    const original: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 5 },
        .schemas = &.{
            .u64,                                                         .boolean,
            .{
                .internal = .{ .region = 0 },
            },
            .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } },
            .{ .internal = .{ .computation = .{
                .parameters = &.{ 2, 0, 0, 1 },
                .result = 0,
                .use = .reusable,
                .regions = &.{0},
            } } },
            .unit,
        },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{
            .{
                .entry = 0,
                .inputs = &.{ 0, 1, 2 },
                .layout = .{ .slots = &.{ 0, 0, 1, 4, 0 } },
                .result = 0,
            },
            .{
                .entry = 2,
                .inputs = &.{ 0, 1, 2, 3 },
                .layout = .{ .slots = &.{ 2, 0, 0, 1, 3, 0, 0 } },
                .result = 0,
                .regions = &.{0},
            },
        },
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{.{ .destination = 3, .opcode = .computation }},
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
                .instructions = &.{},
                .terminator = .{ .branch = .{
                    .condition = 3,
                    .when_true = .{ .block = 3 },
                    .when_false = .{ .block = 4 },
                } },
            },
            .{
                .function = 1,
                .instructions = &.{
                    .{ .destination = 4, .opcode = .cell_new, .operands = &.{ 0, 1 } },
                    .{ .destination = 5, .opcode = .cell_get, .operands = &.{4} },
                },
                .terminator = .{ .jump = .{ .block = 5 } },
            },
            .{ .function = 1, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 5 } } },
            .{
                .function = 1,
                .instructions = &.{
                    .{ .destination = 4, .opcode = .cell_new, .operands = &.{ 0, 2 } },
                    .{ .destination = 6, .opcode = .cell_get, .operands = &.{4} },
                },
                .terminator = .{ .return_value = 6 },
            },
        },
        .scopes = .{ .region_count = 1, .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
        .constructors = &.{.{ .function = 1, .capture = 0, .schema = 4 }},
    };
};

test "PRE cannot move a region-owned read before its owner exists on a predecessor" {
    const original = PredecessorRegionFixture.original;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var candidate = try pre.construct(a, original, 100000);
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
    var misplaced = original;
    var blocks = original.blocks[0..6].*;
    blocks[4].instructions = &.{original.blocks[5].instructions[1]};
    misplaced.blocks = &blocks;
    if (@import("activation_ownership.zig").analyze(a, misplaced)) |owner| {
        var unexpected = owner;
        unexpected.deinit();
        return error.ExpectedUnavailableOwner;
    } else |_| {}
}
