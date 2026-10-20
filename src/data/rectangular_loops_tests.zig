// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const pass = @import("rectangular_loops.zig");
const own = @import("activation_ownership.zig");
const a = std.testing.allocator;
pub const base: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .boolean },
    .effects = &.{},
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 8, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 2, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{} },
    },
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{},
        .layout = .{ .slots = &.{ 0, 0, 0, 0, 0, 0, 2, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 0, .opcode = .constant, .immediate = 0 },
                .{ .destination = 1, .opcode = .constant, .immediate = 1 },
                .{ .destination = 2, .opcode = .constant, .immediate = 2 },
                .{ .destination = 4, .opcode = .constant, .immediate = 2 },
                .{ .destination = 5, .opcode = .constant, .immediate = 3 },
            },
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 6, .opcode = .less, .operands = &.{ 2, 0 } }},
            .terminator = .{ .branch = .{
                .condition = 6,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 6 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 3, .opcode = .constant, .immediate = 2 }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 6, .opcode = .less, .operands = &.{ 3, 1 } }},
            .terminator = .{ .branch = .{
                .condition = 6,
                .when_true = .{ .block = 4 },
                .when_false = .{ .block = 5 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 7, .opcode = .integer_bit_xor, .operands = &.{ 2, 3 } },
                .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 4, 7 } },
                .{
                    .destination = 3,
                    .opcode = .integer_add,
                    .operands = &.{ 3, 5 },
                    .failures = &.{.{ .kind = .arithmetic_overflow, .value = 4 }},
                },
            },
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .integer_add,
                .operands = &.{ 2, 5 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 4 }},
            }},
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
    },
};
pub fn rectangle(allocator: std.mem.Allocator, rows: u64, columns: u64) !ir.Program {
    var result = base;
    const constants = try allocator.dupe(p.Literal, base.constants);
    for ([_]u64{ rows, columns }, 0..) |value, index| {
        const bytes = try allocator.alloc(u8, 8);
        std.mem.writeInt(u64, bytes[0..8], value, .little);
        constants[index].bytes = bytes;
    }
    result.constants = constants;
    return result;
}

pub fn aliasedRectangle(allocator: std.mem.Allocator) !ir.Program {
    var result = base;
    result.schemas = &.{
        .u64,                                                         .unit, .boolean, .{ .internal = .{ .region = 0 } },
        .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{3},
            .result = 0,
            .use = .reusable,
            .regions = &.{0},
        } } },
    };
    result.functions = &.{
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 5, 0 } }, .result = 0 },
        .{
            .entry = 2,
            .inputs = &.{8},
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 0, 0, 2, 0, 3, 4, 4, 1, 0 } },
            .result = 0,
            .regions = &.{0},
        },
    };
    const blocks = try allocator.alloc(ir.Block, 9);
    blocks[0] = .{
        .function = 0,
        .instructions = &.{.{ .destination = 0, .opcode = .computation, .immediate = 0 }},
        .terminator = .{ .with_region = .{
            .region = 0,
            .body = 0,
            .arguments = &.{},
            .next = .{ .block = 1, .assignments = &.{.{ .destination = 1, .source = .returned }} },
        } },
    };
    blocks[1] = .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } };
    for (base.blocks, 0..) |source, id| {
        blocks[id + 2] = source;
        blocks[id + 2].function = 1;
        switch (blocks[id + 2].terminator) {
            .jump => |*edge| edge.block += 2,
            .branch => |*branch| {
                branch.when_true.block += 2;
                branch.when_false.block += 2;
            },
            else => {},
        }
    }
    const initial = try allocator.alloc(ir.Instruction, 7);
    @memcpy(initial[0..5], base.blocks[0].instructions);
    initial[5] = .{ .destination = 9, .opcode = .cell_new, .operands = &.{ 8, 4 } };
    initial[6] = .{ .destination = 10, .opcode = .move, .operands = &.{9} };
    blocks[2].instructions = initial;
    blocks[6].instructions = &.{
        .{ .destination = 7, .opcode = .cell_get, .operands = &.{9} },
        .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 4, 7 } },
        .{ .destination = 12, .opcode = .integer_bit_xor, .operands = &.{ 2, 3 } },
        .{ .destination = 12, .opcode = .integer_bit_or, .operands = &.{ 12, 7 } },
        .{ .destination = 11, .opcode = .cell_set, .operands = &.{ 10, 12 } },
        base.blocks[4].instructions[2],
    };
    result.blocks = blocks;
    result.scopes = .{ .region_count = 1, .captures = &.{.{ .fields = &.{}, .use = .reusable }} };
    result.constructors = &.{.{ .function = 1, .capture = 0, .schema = 5 }};
    return result;
}

test "admitted rectangular iteration through a mutable alias is outside reordering" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try aliasedRectangle(arena.allocator());
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
    try std.testing.expect(try @import("rectangular_tiling.zig").construct(
        a,
        original,
        .{},
    ) == null);
}
test "checked interchange preserves the rectangular domain and lowers outer control work" {
    var candidate = (try pass.construct(a, base, .{})).?;
    defer candidate.deinit();
    try pass.validate(a, base, candidate.program, candidate.shape, .{});
    try std.testing.expectEqual(@as(?u64, 169), try pass.executionWork(a, base));
    try std.testing.expectEqual(@as(?u64, 121), try pass.executionWork(a, candidate.program));
    try std.testing.expect(try pass.construct(a, candidate.program, .{}) == null);
}
test "triangular domains accumulator dependence and checked body arithmetic remain ordered" {
    var blocks = base.blocks[0..7].*;
    var original = base;
    original.blocks = &blocks;
    var compare = base.blocks[3].instructions[0..1].*;
    compare[0].operands = &.{ 3, 2 };
    blocks[3].instructions = &compare;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
    blocks[3] = base.blocks[3];
    var body = base.blocks[4].instructions[0..3].*;
    blocks[4].instructions = &body;
    body[0].operands = &.{ 2, 4 };
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
    body[0] = base.blocks[4].instructions[0];
    body[0].opcode = .integer_add;
    body[0].failures = &.{.{ .kind = .arithmetic_overflow, .value = 4 }};
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
}
test "an admitted changed reduction cannot masquerade as interchange" {
    var candidate = (try pass.construct(a, base, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    const body = try a.dupe(ir.Instruction, blocks[4].instructions);
    defer a.free(body);
    body[0].opcode = .integer_bit_and;
    blocks[4].instructions = body;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidRectangularLoop,
        pass.validate(a, base, forged, candidate.shape, .{}),
    );
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try pass.run(allocator, base, null, .{});
    defer result.deinit();
}
test "interchange allocation cleanup and deterministic work rollback retain admission" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: pass.Statistics = .{};
    var limited = try pass.run(a, base, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    var baseline = try @import("coalescing.zig").run(a, base, .{});
    defer baseline.deinit();
    try std.testing.expect(@import("record_equal.zig").equal(
        ir.Program,
        baseline.program,
        limited.program,
    ));
}
