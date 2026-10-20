// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const pass = @import("coalescing.zig");
const testing = std.testing;

fn program(a: std.mem.Allocator, changed: bool) !ir.Program {
    const functions = try a.alloc(ir.Function, 5);
    const blocks = try a.alloc(ir.Block, 11);
    for (0..4) |id| {
        functions[id] = .{
            .entry = id * 2,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 0, 0 } },
            .result = 0,
        };
        const operations = try a.alloc(ir.Instruction, 1);
        operations[0] = .{
            .destination = 1,
            .opcode = .constant,
            .immediate = if (changed and id == 3) 2 else id % 2,
        };
        blocks[id * 2] = .{
            .function = id,
            .instructions = operations,
            .terminator = .{ .call = .{
                .function = id ^ 1,
                .arguments = &.{0},
                .next = .{
                    .block = id * 2 + 1,
                    .assignments = &.{.{ .destination = 0, .source = .returned }},
                },
            } },
        };
        blocks[id * 2 + 1] = .{
            .function = id,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        };
    }
    functions[4] = .{ .entry = 8, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 };
    for (0..2) |id| blocks[8 + id] = .{
        .function = 4,
        .instructions = &.{},
        .terminator = .{ .call = .{
            .function = id * 2,
            .arguments = &.{0},
            .next = .{ .block = 9 + id },
        } },
    };
    blocks[10] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
    return .{
        .roots = .{ .entry = 4, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{
            .{ .schema = 0, .bytes = &.{ 41, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 0, .bytes = &.{ 43, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .effects = &.{},
        .functions = functions,
        .blocks = blocks,
    };
}

test "coalescing actual recursive candidates merge role for role and propagate deep differences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var equal = try pass.run(testing.allocator, try program(arena.allocator(), false), .{});
    defer equal.deinit();
    try testing.expectEqual(@as(usize, 3), equal.program.functions.len);
    var different = try pass.run(testing.allocator, try program(arena.allocator(), true), .{});
    defer different.deinit();
    try testing.expectEqual(@as(usize, 5), different.program.functions.len);
    var again = try pass.run(testing.allocator, equal.program, .{});
    defer again.deinit();
    const image = @import("program_image.zig");
    try testing.expectEqual(
        try image.identity(testing.allocator, equal.program),
        try image.identity(testing.allocator, again.program),
    );
}
