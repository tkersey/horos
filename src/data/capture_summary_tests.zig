// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const summary = @import("capture_summary.zig");
const a = std.testing.allocator;
const reused: ir.Program = .{
    .roots = .{ .entry = 0, .result = 3, .failure = 1 },
    .schemas = &.{
        .u64,                       .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
        .{ .product = &.{ 0, 0 } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 2, 0, 0, 3 } },
            .result = 3,
        },
        .{
            .entry = 3,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 0 } },
            .result = 0,
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .computation,
                .operands = &.{ 0, 1 },
                .immediate = 0,
            }},
            .terminator = .{ .apply = .{
                .computation = 4,
                .arguments = &.{2},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 4,
                .arguments = &.{3},
                .next = .{
                    .block = 2,
                    .assignments = &.{.{ .destination = 6, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 7, .opcode = .product, .operands = &.{ 5, 6 } }},
            .terminator = .{ .return_value = 7 },
        },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } },
                .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 3, 2 } },
            },
            .terminator = .{ .return_value = 4 },
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{ 0, 0 }, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
};

test "two live scalar captures become one XOR summary" {
    var stats: summary.Statistics = .{};
    var result = try summary.run(a, reused, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.constructors_summarized);
    try std.testing.expectEqual(@as(usize, 1), stats.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.worker_xors_replaced);
    try std.testing.expectEqual(@as(usize, 1), stats.construction_xors);
    try std.testing.expectEqual(
        @as(usize, 1),
        result.program.scopes.captures[@intCast(result.program.constructors[0].capture)].fields.len,
    );
    std.debug.print(
        "XOR capture summary: {d} -> {d} bytes; captured u64 payload 16 -> 8 bytes\n",
        .{
            try @import("program_image.zig").encodedLength(reused),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}

test "summary checker rejects a well-typed OR substituted for XOR" {
    var functions = reused.functions[0..2].*;
    functions[0].layout.slots = &.{ 0, 0, 0, 0, 2, 0, 0, 3, 0 };
    functions[1].inputs = &.{ 0, 2 };
    var constructor_ops = [_]ir.Instruction{
        .{ .destination = 8, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } },
        .{ .destination = 4, .opcode = .computation, .operands = &.{8}, .immediate = 0 },
    };
    var blocks = reused.blocks[0..4].*;
    blocks[0].instructions = &constructor_ops;
    blocks[3].instructions = &.{
        .{ .destination = 3, .opcode = .move, .operands = &.{0} },
        reused.blocks[3].instructions[1],
    };
    var candidate = reused;
    candidate.functions = &functions;
    candidate.blocks = &blocks;
    candidate.scopes.captures = &.{
        reused.scopes.captures[0],
        .{ .fields = &.{0}, .use = .reusable },
    };
    candidate.constructors = &.{.{ .function = 1, .capture = 1, .schema = 2 }};
    const witnesses = &.{summary.Witness{ .constructor = 0 }};
    try summary.validate(a, reused, candidate, witnesses);
    constructor_ops[0].opcode = .integer_bit_or;
    try std.testing.expectError(
        error.InvalidCaptureSummary,
        summary.validate(a, reused, candidate, witnesses),
    );
}

test "an individual capture observer prevents sufficient-summary reduction" {
    var original = reused;
    var blocks = reused.blocks[0..4].*;
    blocks[3].instructions = &.{
        reused.blocks[3].instructions[0],                                          reused.blocks[3].instructions[1],
        .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 4, 0 } },
    };
    original.blocks = &blocks;
    var stats: summary.Statistics = .{};
    var result = try summary.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.constructors_summarized);
}

test "a capture update invalidates immutable-summary selection" {
    var original = reused;
    var blocks = reused.blocks[0..4].*;
    blocks[3].instructions = &.{
        .{ .destination = 0, .opcode = .move, .operands = &.{2} },
        reused.blocks[3].instructions[0],
        reused.blocks[3].instructions[1],
    };
    original.blocks = &blocks;
    var stats: summary.Statistics = .{};
    var result = try summary.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.constructors_summarized);
}

test "direct worker calls receive the same ordered XOR summary" {
    var original = reused;
    original.blocks = &.{
        reused.blocks[0], reused.blocks[1],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 1, 2 },
                .next = .{
                    .block = 4,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        reused.blocks[3], reused.blocks[2],
    };
    var stats: summary.Statistics = .{};
    var result = try summary.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.direct_call_xors);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try summary.run(allocator, reused, null, .{});
    defer result.deinit();
}
test "XOR summary releases all partial owners on allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "u64 XOR summary law follows every bit and native scalar semantics" {
    // Every output bit is the truth-table XOR of only its two input bits.
    // Exhaust one byte lane and check all 64 bit positions. The implementation
    // applies the same bytewise operator independently to all eight lanes.
    const scalar = @import("scalar.zig");
    for (0..256) |left| for (0..256) |right| {
        var x: [8]u8 = @splat(0);
        var y: [8]u8 = @splat(0);
        x[0] = @intCast(left);
        y[0] = @intCast(right);
        const result = try scalar.binary(.integer_bit_xor, .u64, x, y);
        try std.testing.expect(result == .value);
        try std.testing.expectEqual(@as(u8, @intCast(left ^ right)), result.value[0]);
    };
    for (0..64) |bit| {
        const x: u64 = @as(u64, 1) << @intCast(bit);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, x, .little);
        const result = try scalar.binary(.integer_bit_xor, .u64, bytes, @splat(0));
        try std.testing.expectEqualSlices(u8, &bytes, &result.value);
    }
}

test "summary retains faulting capture evaluation before constructor rewriting" {
    var original = reused;
    original.constants = &.{.{ .schema = 1, .bytes = &.{} }};
    var blocks = reused.blocks[0..4].*;
    blocks[0].instructions = &.{
        .{
            .destination = 0,
            .opcode = .integer_div,
            .operands = &.{ 0, 1 },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = 0 },
                .{ .kind = .division_by_zero, .value = 0 },
            },
        },
        reused.blocks[0].instructions[0],
    };
    original.blocks = &blocks;
    var stats: summary.Statistics = .{};
    var result = try summary.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.constructors_summarized);
    const entry = result.program.functions[@intCast(result.program.roots.entry)].entry;
    const instructions = result.program.blocks[@intCast(entry)].instructions;
    try std.testing.expect(instructions[0].opcode == .integer_div);
    try std.testing.expect(instructions[1].opcode == .integer_bit_xor);
    try std.testing.expect(instructions[2].opcode == .computation);
}

test "opaque closure alias keeps the original two-field representation" {
    var original = reused;
    var functions = reused.functions[0..2].*;
    functions[0].layout.slots = &.{ 0, 0, 0, 0, 2, 0, 0, 3, 2 };
    original.functions = &functions;
    var blocks = reused.blocks[0..4].*;
    blocks[0].instructions = &.{
        reused.blocks[0].instructions[0],
        .{ .destination = 8, .opcode = .move, .operands = &.{4} },
    };
    original.blocks = &blocks;
    var stats: summary.Statistics = .{};
    var result = try summary.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.constructors_summarized);
}
