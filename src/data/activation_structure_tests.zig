// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const validate = @import("activation_structure.zig").validate;
const testing = std.testing;

fn fixture(blocks: []const ir.Block) ir.Program {
    return .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 1 } },
            .result = 0,
        }},
        .blocks = blocks,
    };
}

const end: ir.Block = .{
    .function = 0,
    .instructions = &.{},
    .terminator = .{ .return_value = 0 },
};

test "stable structure permits genuine permutations and repeated copyable arguments" {
    for ([_][]const ir.Assignment{
        &.{
            .{ .destination = 0, .source = .{ .slot = 1 } },
            .{ .destination = 1, .source = .{ .slot = 0 } },
        },
        &.{
            .{ .destination = 0, .source = .{ .slot = 0 } },
            .{ .destination = 1, .source = .{ .slot = 0 } },
        },
    }) |assignments| {
        const blocks = [_]ir.Block{ .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .jump = .{ .block = 1, .assignments = assignments } },
        }, end };
        try validate(testing.allocator, fixture(&blocks));
    }
}

test "stable structure rejects malformed assignments without predecessor expansion" {
    const Case = struct { assignments: []const ir.Assignment, expected: anyerror };
    const cases = [_]Case{
        .{ .assignments = &.{
            .{ .destination = 0, .source = .{ .slot = 1 } },
            .{ .destination = 0, .source = .{ .slot = 0 } },
        }, .expected = error.DuplicateDestination },
        .{
            .assignments = &.{.{ .destination = 9, .source = .{ .slot = 0 } }},
            .expected = error.InvalidReference,
        },
        .{
            .assignments = &.{.{ .destination = 0, .source = .{ .slot = 9 } }},
            .expected = error.InvalidReference,
        },
        .{
            .assignments = &.{.{ .destination = 0, .source = .{ .slot = 2 } }},
            .expected = error.TypeMismatch,
        },
        .{
            .assignments = &.{.{ .destination = 0, .source = .returned }},
            .expected = error.TypeMismatch,
        },
    };
    for (cases) |case| {
        const blocks = [_]ir.Block{ .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .jump = .{ .block = 1, .assignments = case.assignments } },
        }, end };
        try testing.expectError(case.expected, validate(testing.allocator, fixture(&blocks)));
    }
}

test "stable structure rejects cross-function and nonexistent destinations" {
    var blocks = [_]ir.Block{ .{
        .function = 0,
        .instructions = &.{},
        .terminator = .{ .jump = .{ .block = 1 } },
    }, end };
    blocks[1].function = 1;
    try testing.expectError(error.InvalidReference, validate(testing.allocator, fixture(&blocks)));
    blocks[1] = end;
    blocks[0].terminator.jump.block = 2;
    try testing.expectError(error.InvalidReference, validate(testing.allocator, fixture(&blocks)));
}

test "stable structure checks instruction references against the owning layout" {
    var instructions = [_]ir.Instruction{.{
        .destination = 0,
        .opcode = .move,
        .operands = &.{3},
    }};
    const blocks = [_]ir.Block{.{
        .function = 0,
        .instructions = &instructions,
        .terminator = .{ .return_value = 0 },
    }};
    try testing.expectError(error.InvalidReference, validate(testing.allocator, fixture(&blocks)));
    instructions[0] = .{ .destination = 3, .opcode = .move, .operands = &.{0} };
    try testing.expectError(error.InvalidReference, validate(testing.allocator, fixture(&blocks)));
}

test "stable structure checks result type and duplicate function inputs" {
    var blocks = [_]ir.Block{end};
    var image = fixture(&blocks);
    var functions = [_]ir.Function{image.functions[0]};
    image.functions = &functions;
    functions[0].inputs = &.{ 0, 0, 2 };
    try testing.expectError(error.DuplicateDestination, validate(testing.allocator, image));
    functions[0].inputs = &.{ 0, 1, 2 };
    blocks[0].terminator = .{ .return_value = 2 };
    try testing.expectError(error.TypeMismatch, validate(testing.allocator, image));
}
