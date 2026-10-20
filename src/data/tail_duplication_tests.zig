// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const duplicate = @import("tail_duplication.zig");
const a = std.testing.allocator;

test "a profile spends one tail copy on the hot proved incoming edge" {
    const profiles = @import("optimization_profile.zig");
    var counts = @as([split.blocks.len]u64, @splat(0));
    counts[2] = 100;
    const record: profiles.Record = .{
        .image_identity = try @import("program_image.zig").identity(a, split),
        .block_counts = &counts,
        .total = 100,
    };
    var candidate = (try duplicate.construct(a, split, .{ .profile = record, .max_copies = 1 })).?;
    defer candidate.deinit();
    try duplicate.validate(a, split, candidate.program, candidate.witnesses, .{});
    try std.testing.expectEqual(@as(usize, 1), candidate.witnesses.len);
    try std.testing.expectEqual(@as(usize, 2), candidate.witnesses[0].predecessor);
    try std.testing.expect(!candidate.witnesses[0].condition);
    try std.testing.expectEqual(@as(u64, 3), candidate.program.blocks[1].terminator.jump.block);
}
pub const split: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 0 },
    .schemas = &.{ .u64, .boolean },
    .constants = &.{ .{ .schema = 1, .bytes = &.{1} }, .{ .schema = 1, .bytes = &.{0} } },
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 1, 1, 0 } },
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
            .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 3,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 4 },
                .when_false = .{ .block = 5 },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    },
};
test "duplicated tails expose distinct incoming constants to checked branch reduction" {
    var candidate = (try duplicate.construct(a, split, .{})).?;
    defer candidate.deinit();
    try duplicate.validate(a, split, candidate.program, candidate.witnesses, .{});
    try std.testing.expectEqual(@as(usize, 2), candidate.witnesses.len);
    try std.testing.expect(candidate.witnesses[0].condition and !candidate.witnesses[1].condition);
    var stats: duplicate.Statistics = .{};
    var result = try duplicate.run(a, split, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.exposed_branches);
    var branches: usize = 0;
    for (result.program.blocks) |block| {
        if (block.terminator == .branch) branches += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), branches);
}
test "wrong copy content and forged incoming conditions reject" {
    var candidate = (try duplicate.construct(a, split, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..8].*;
    blocks[6].instructions = &.{.{ .destination = 3, .opcode = .move, .operands = &.{0} }};
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidTailDuplication,
        duplicate.validate(a, split, wrong, candidate.witnesses, .{}),
    );
    var witnesses = candidate.witnesses[0..2].*;
    witnesses[0].condition = false;
    try std.testing.expectError(
        error.InvalidTailDuplication,
        duplicate.validate(a, split, candidate.program, &witnesses, .{}),
    );
}
test "condition overwritten inside the tail and different custody decline" {
    var original = split;
    var blocks = split.blocks[0..6].*;
    blocks[3].instructions = &.{
        split.blocks[3].instructions[0],
        .{ .destination = 2, .opcode = .boolean_not, .operands = &.{2} },
    };
    original.blocks = &blocks;
    try std.testing.expect(try duplicate.construct(a, original, .{}) == null);
    blocks[3] = split.blocks[3];
    blocks[3].custody = 1;
    var functions = split.functions[0..1].*;
    functions[0].custody = &.{ .{}, .{ .parent = 0 } };
    original.functions = &functions;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try duplicate.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try duplicate.run(allocator, split, null, .{});
    defer result.deinit();
}
test "duplication budgets and allocation failures retain P01" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, split, .{});
    defer baseline.deinit();
    for ([_]duplicate.Options{
        .{ .work_limit = 0 },
        .{ .max_copies = 0 },
        .{ .max_added_bytes = 0 },
    }) |options| {
        var stats: duplicate.Statistics = .{};
        var result = try duplicate.run(a, split, &stats, options);
        defer result.deinit();
        try std.testing.expect(stats.work_limit);
        try std.testing.expectEqual(
            try @import("program_image.zig").identity(a, baseline.program),
            try @import("program_image.zig").identity(a, result.program),
        );
    }
}

pub const cell_effect: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                                         .unit, .{ .internal = .{ .region = 0 } },
        .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 2, 0, 5 },
            .result = 0,
            .use = .reusable,
            .regions = &.{0},
        } } },
        .boolean,
    },
    .constants = &.{ .{ .schema = 5, .bytes = &.{1} }, .{ .schema = 5, .bytes = &.{0} } },
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 5, 4, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 2, 0, 5, 3, 0, 1, 5, 0 } },
            .result = 0,
            .regions = &.{0},
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .computation, .immediate = 0 }},
            .terminator = .{ .with_region = .{
                .region = 0,
                .body = 2,
                .arguments = &.{ 0, 1 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 3, .opcode = .cell_new, .operands = &.{ 0, 1 } }},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 6, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .jump = .{ .block = 5 } },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 6, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .jump = .{ .block = 5 } },
        },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 4, .opcode = .cell_get, .operands = &.{3} },
                .{ .destination = 4, .opcode = .integer_bit_not, .operands = &.{4} },
                .{ .destination = 5, .opcode = .cell_set, .operands = &.{ 3, 4 } },
            },
            .terminator = .{ .branch = .{
                .condition = 6,
                .when_true = .{ .block = 6 },
                .when_false = .{ .block = 7 },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 7, .opcode = .cell_get, .operands = &.{3} }},
            .terminator = .{ .return_value = 7 },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 7, .opcode = .cell_get, .operands = &.{3} }},
            .terminator = .{ .return_value = 7 },
        },
    },
    .scopes = .{ .region_count = 1, .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 4 }},
};
test "copying an effectful tail must not execute its mutation twice" {
    var candidate = (try duplicate.construct(a, cell_effect, .{})).?;
    defer candidate.deinit();
    try duplicate.validate(a, cell_effect, candidate.program, candidate.witnesses, .{});
    var blocks = candidate.program.blocks[0..10].*;
    const original = cell_effect.blocks[5].instructions;
    var twice: [6]ir.Instruction = undefined;
    @memcpy(twice[0..3], original);
    @memcpy(twice[3..6], original);
    blocks[8].instructions = &twice;
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidTailDuplication,
        duplicate.validate(a, cell_effect, wrong, candidate.witnesses, .{}),
    );
}
test "incoming parallel assignments retain their predecessor view" {
    var original = split;
    var functions = split.functions[0..1].*;
    functions[0].inputs = &.{ 0, 1, 3 };
    original.functions = &functions;
    var blocks = split.blocks[0..6].*;
    const swaps: []const ir.Assignment = &.{
        .{ .destination = 0, .source = .{ .slot = 3 } },
        .{ .destination = 3, .source = .{ .slot = 0 } },
    };
    blocks[1].terminator.jump.assignments = swaps;
    blocks[2].terminator.jump.assignments = swaps;
    original.blocks = &blocks;
    var candidate = (try duplicate.construct(a, original, .{})).?;
    defer candidate.deinit();
    try duplicate.validate(a, original, candidate.program, candidate.witnesses, .{});
    try std.testing.expectEqual(
        @as(u64, 3),
        candidate.program.blocks[1].terminator.jump.assignments[0].source.slot,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        candidate.program.blocks[1].terminator.jump.assignments[1].source.slot,
    );
}

test "shared compiler selects duplication rather than folding copies back together" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        split,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    var branches: usize = 0;
    for (result.program.blocks) |block| {
        if (block.terminator == .branch) branches += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), branches);
}
