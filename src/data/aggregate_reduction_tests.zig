// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const reduce = @import("aggregate_reduction.zig");
const dead = @import("dead_computation.zig");
const a = std.testing.allocator;
const original: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .{ .product = &.{ 0, 0 } } },
    .constants = &.{.{ .schema = 0, .bytes = &.{ 99, 0, 0, 0, 0, 0, 0, 0 } }},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 0, 2, 0, 0, 0, 2 } },
        .result = 0,
    }},
    .blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } },
        .{ .destination = 3, .opcode = .field, .operands = &.{2}, .immediate = 0 },
        .{ .destination = 4, .opcode = .field, .operands = &.{2}, .immediate = 1 },
        .{ .destination = 5, .opcode = .integer_bit_xor, .operands = &.{ 3, 4 } },
    }, .terminator = .{ .return_value = 5 } }},
};

test "product projections forward exact operands and eliminate materialization" {
    var stats: reduce.Statistics = .{};
    var forwarded = try reduce.run(a, original, &stats, .{});
    defer forwarded.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.fields_forwarded);
    var eliminated = try dead.run(a, forwarded.program, null, .{});
    defer eliminated.deinit();
    for (eliminated.program.blocks) |block| for (block.instructions) |instruction| {
        try std.testing.expect(instruction.opcode != .product and instruction.opcode != .field);
    };
    std.debug.print(
        "product scalar replacement: {d} -> {d} bytes\n",
        .{
            try @import("program_image.zig").encodedLength(original),
            try @import("program_image.zig").encodedLength(eliminated.program),
        },
    );
}

test "independent product checker rejects a same-type wrong field" {
    var instructions = original.blocks[0].instructions[0..4].*;
    instructions[1] = .{ .destination = 3, .opcode = .move, .operands = &.{0} };
    var blocks = original.blocks[0..1].*;
    blocks[0].instructions = &instructions;
    var candidate = original;
    candidate.blocks = &blocks;
    const witnesses = &.{reduce.Witness{ .block = 0, .projection = 1, .construction = 0 }};
    try reduce.validate(a, original, candidate, witnesses);
    instructions[1].operands = &.{1};
    try std.testing.expectError(
        error.InvalidAggregateReduction,
        reduce.validate(a, original, candidate, witnesses),
    );
}

test "overwritten source retains its stored product value" {
    var program = original;
    program.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            original.blocks[0].instructions[0],
            .{ .destination = 0, .opcode = .constant, .immediate = 0 },
            original.blocks[0].instructions[1],
            original.blocks[0].instructions[2],
            original.blocks[0].instructions[3],
        },
        .terminator = original.blocks[0].terminator,
    }};
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.fields_forwarded);
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_fields);
    var instructions = program.blocks[0].instructions[0..5].*;
    instructions[2] = .{ .destination = 3, .opcode = .move, .operands = &.{0} };
    var blocks = program.blocks[0..1].*;
    blocks[0].instructions = &instructions;
    var forged = program;
    forged.blocks = &blocks;
    try std.testing.expectError(
        error.InvalidAggregateReduction,
        reduce.validate(
            a,
            program,
            forged,
            &.{.{ .block = 0, .projection = 2, .construction = 0 }},
        ),
    );
}

test "product aliases retain definition provenance" {
    var program = original;
    program.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            original.blocks[0].instructions[0],
            .{ .destination = 6, .opcode = .move, .operands = &.{2} },
            .{ .destination = 3, .opcode = .field, .operands = &.{6}, .immediate = 0 },
            original.blocks[0].instructions[2],
            original.blocks[0].instructions[3],
        },
        .terminator = original.blocks[0].terminator,
    }};
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.fields_forwarded);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try reduce.run(allocator, original, null, .{});
    defer result.deinit();
}
test "product reduction releases partial owners on allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "an externally returned product remains materialized" {
    var program = original;
    program.roots.result = 2;
    var functions = original.functions[0..1].*;
    functions[0].result = 2;
    program.functions = &functions;
    var blocks = original.blocks[0..1].*;
    blocks[0].terminator = .{ .return_value = 2 };
    program.blocks = &blocks;
    var forwarded = try reduce.run(a, program, null, .{});
    defer forwarded.deinit();
    var retained = try dead.run(a, forwarded.program, null, .{});
    defer retained.deinit();
    var count: usize = 0;
    for (retained.program.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode == .product) count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "invalid product failure annotation is rejected before optimization" {
    var program = original;
    program.constants = &.{ original.constants[0], .{ .schema = 1, .bytes = &.{} } };
    var instructions = original.blocks[0].instructions[0..4].*;
    instructions[0].failures = &.{.{ .kind = .capacity_exceeded, .value = 1 }};
    var blocks = original.blocks[0..1].*;
    blocks[0].instructions = &instructions;
    program.blocks = &blocks;
    try std.testing.expectError(error.InvalidProgram, reduce.run(a, program, null, .{}));
}
