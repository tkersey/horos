// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const patterns = @import("call_patterns.zig");
const a = std.testing.allocator;
pub const words: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .boolean, .unit },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
    },
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 1, 0, 0 } },
            .result = 0,
        },
        .{
            .entry = 4,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 0, 1 } },
            .result = 0,
        },
    },
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
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 2 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 2 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 2, .opcode = .constant, .immediate = 0 },
                .{ .destination = 3, .opcode = .equal, .operands = &.{ 1, 2 } },
            },
            .terminator = .{ .branch = .{
                .condition = 3,
                .when_true = .{ .block = 5 },
                .when_false = .{ .block = 6 },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 2 },
        },
    },
};
test "unsigned constants materialize in reduced private worker interfaces" {
    var candidate = (try patterns.construct(a, words, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        words,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 2), candidate.variants.len);
    for (candidate.variants, 0..) |variant, index| {
        try std.testing.expectEqual(@as(u64, index), variant.key.value.unsigned);
        const initialization = candidate.program.blocks[variant.first_block].instructions[0];
        try std.testing.expectEqual(@as(u64, 1), initialization.destination);
        try std.testing.expectEqual(@as(u64, index), initialization.immediate);
        try std.testing.expectEqual(
            @as(usize, 1),
            candidate.program.functions[@intCast(variant.function)].inputs.len,
        );
    }
}
test "all unsigned widths preserve schema-specific literal interpretation" {
    for (
        [_]@import("program.zig").Schema{ .u8, .u16, .u32, .u64 },
        [_]usize{ 1, 2, 4, 8 },
    ) |schema, width| {
        var original = words;
        original.schemas = &.{ schema, words.schemas[1], words.schemas[2] };
        original.constants = &.{
            .{ .schema = 0, .bytes = words.constants[0].bytes[0..width] },
            .{ .schema = 0, .bytes = words.constants[1].bytes[0..width] },
        };
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
    }
}
test "wrong literal initialization is admissible but not a valid specialization" {
    var candidate = (try patterns.construct(a, words, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    const first = candidate.variants[0].first_block;
    const instructions = try a.dupe(ir.Instruction, blocks[first].instructions);
    defer a.free(instructions);
    instructions[0].immediate = 1;
    blocks[first].instructions = instructions;
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, words, wrong, candidate.variants, candidate.sites, 1000000),
    );
    var variants = candidate.variants[0..2].*;
    variants[0].literal = 1;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, words, wrong, &variants, candidate.sites, 1000000),
    );
}
test "shared pipeline consumes materialized facts to eliminate comparison branches" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        words,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    var branches: usize = 0;
    for (result.program.blocks) |block| {
        if (block.terminator == .branch) branches += 1;
        for (block.instructions) |op| try std.testing.expect(op.opcode != .equal);
    }
    try std.testing.expectEqual(@as(usize, 1), branches);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try patterns.run(allocator, words, null, .{});
    defer result.deinit();
}
test "word worker allocation failures release temporary owners" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "unknown word argument retains generic fallback" {
    var original = words;
    var functions = words.functions[0..2].*;
    functions[0].inputs = &.{ 0, 1, 2 };
    original.functions = &functions;
    var blocks = words.blocks[0..7].*;
    blocks[1].instructions = &.{};
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
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[1].terminator.call.function);
}
test "out-of-width constant certificate cannot change a narrow worker" {
    var original = words;
    original.schemas = &.{ .u8, .boolean, .unit };
    original.constants = &.{ .{ .schema = 0, .bytes = &.{0} }, .{ .schema = 0, .bytes = &.{1} } };
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    var variants = candidate.variants[0..2].*;
    variants[0].key.value.unsigned = 256;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, original, candidate.program, &variants, candidate.sites, 1000000),
    );
}
