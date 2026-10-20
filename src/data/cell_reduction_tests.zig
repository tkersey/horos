// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const reduce = @import("cell_reduction.zig");
const dead = @import("dead_computation.zig");
const a = std.testing.allocator;
const private_cell: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                                         .unit, .{ .internal = .{ .region = 0 } },
        .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 2, 0, 0 },
            .result = 0,
            .use = .reusable,
            .regions = &.{0},
        } } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 4, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 2, 0, 0, 3, 0, 1, 0 } },
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
        .{ .function = 1, .instructions = &.{
            .{ .destination = 3, .opcode = .cell_new, .operands = &.{ 0, 1 } },
            .{ .destination = 4, .opcode = .cell_get, .operands = &.{3} },
            .{ .destination = 5, .opcode = .cell_set, .operands = &.{ 3, 2 } },
            .{ .destination = 6, .opcode = .cell_get, .operands = &.{3} },
        }, .terminator = .{ .return_value = 6 } },
    },
    .scopes = .{ .region_count = 1, .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 4 }},
};

test "private cell reads and writes become explicit scalar values" {
    var stats: reduce.Statistics = .{};
    var scalar = try reduce.run(a, private_cell, &stats, .{});
    defer scalar.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.cells_removed);
    try std.testing.expectEqual(@as(usize, 2), stats.reads_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.stores_removed);
    var result = try dead.run(a, scalar.program, null, .{});
    defer result.deinit();
    for (result.program.blocks) |block| for (block.instructions) |op| {
        try std.testing.expect(
            op.opcode != .cell_new and op.opcode != .cell_get and op.opcode != .cell_set,
        );
    };
    std.debug.print(
        "private cell scalar replacement: {d} -> {d} bytes\n",
        .{
            try @import("program_image.zig").encodedLength(private_cell),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}

test "two private stores before any observation leave only their final scalar value" {
    var program = private_cell;
    var blocks = private_cell.blocks[0..3].*;
    blocks[2].instructions = &.{
        private_cell.blocks[2].instructions[0],
        .{ .destination = 5, .opcode = .cell_set, .operands = &.{ 3, 1 } },
        private_cell.blocks[2].instructions[2],
        private_cell.blocks[2].instructions[3],
    };
    program.blocks = &blocks;
    var stats: reduce.Statistics = .{};
    var scalar = try reduce.run(a, program, &stats, .{});
    defer scalar.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.stores_removed);
    var result = try dead.run(a, scalar.program, null, .{});
    defer result.deinit();
    var moves: usize = 0;
    for (result.program.blocks) |block| for (block.instructions) |op| {
        if (op.opcode == .move) moves += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), moves);
}

test "independent cell checker rejects a wrong same-type stored value" {
    var functions = private_cell.functions[0..2].*;
    functions[1].layout.slots = &.{ 2, 0, 0, 0, 0, 1, 0 };
    var instructions = [_]ir.Instruction{
        .{ .destination = 3, .opcode = .move, .operands = &.{1} },
        .{ .destination = 4, .opcode = .move, .operands = &.{3} },
        .{ .destination = 3, .opcode = .move, .operands = &.{2} },
        .{ .destination = 5, .opcode = .constant, .immediate = 0 },
        .{ .destination = 6, .opcode = .move, .operands = &.{3} },
    };
    var blocks = private_cell.blocks[0..3].*;
    blocks[2].instructions = &instructions;
    var candidate = private_cell;
    candidate.functions = &functions;
    candidate.blocks = &blocks;
    candidate.constants = &.{.{ .schema = 1, .bytes = &.{} }};
    const witnesses = &.{reduce.Witness{ .block = 2, .construction = 0 }};
    try reduce.validate(a, private_cell, candidate, witnesses);
    instructions[2].operands = &.{1};
    try std.testing.expectError(
        error.InvalidCellReduction,
        reduce.validate(a, private_cell, candidate, witnesses),
    );
}

test "aliasing the cell into another value retains its representation" {
    var program = private_cell;
    program.schemas = &.{
        private_cell.schemas[0],
        private_cell.schemas[1],
        private_cell.schemas[2],
        private_cell.schemas[3],
        private_cell.schemas[4],
        .{ .product = &.{3} },
    };
    var functions = private_cell.functions[0..2].*;
    functions[1].layout.slots = &.{ 2, 0, 0, 3, 0, 1, 0, 5 };
    program.functions = &functions;
    var blocks = private_cell.blocks[0..3].*;
    blocks[2].instructions = &.{
        private_cell.blocks[2].instructions[0],
        .{ .destination = 7, .opcode = .product, .operands = &.{3} },
        private_cell.blocks[2].instructions[1],
        private_cell.blocks[2].instructions[2],
        private_cell.blocks[2].instructions[3],
    };
    program.blocks = &blocks;
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.cells_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_cells);
}

test "suspension across the cell lifetime retains checkpoint-visible storage" {
    var program = private_cell;
    program.blocks = &.{
        private_cell.blocks[0], private_cell.blocks[1],
        .{
            .function = 1,
            .instructions = private_cell.blocks[2].instructions[0..1],
            .terminator = .{ .yield_value = .{ .block = 3 } },
        },
        .{
            .function = 1,
            .instructions = private_cell.blocks[2].instructions[1..],
            .terminator = private_cell.blocks[2].terminator,
        },
    };
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.cells_removed);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try reduce.run(allocator, private_cell, null, .{});
    defer result.deinit();
}
test "cell scalar replacement releases partial owners on every allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "a fault observation during the cell lifetime retains the original storage" {
    var program = private_cell;
    program.constants = &.{.{ .schema = 1, .bytes = &.{} }};
    var blocks = private_cell.blocks[0..3].*;
    blocks[2].instructions = &.{
        private_cell.blocks[2].instructions[0],
        .{
            .destination = 4,
            .opcode = .integer_div,
            .operands = &.{ 1, 2 },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = 0 },
                .{ .kind = .division_by_zero, .value = 0 },
            },
        },
        private_cell.blocks[2].instructions[2],
        private_cell.blocks[2].instructions[3],
    };
    program.blocks = &blocks;
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.cells_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_cells);
}
