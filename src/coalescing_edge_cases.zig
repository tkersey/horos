// Copyright (c) 2026 Boundary contributors. MIT license.
//! Raw admitted stable-slot cases: source lets do not expose simultaneous cycles.
const std = @import("std");
const data = @import("horos_data");
const source = @import("source.zig");
const ir = data.activation;
pub const Kind = enum { swap, cycle };
pub const LoopKind = enum { loop, loop_near };
const Mutation = enum { none, order, invalid_slot };
const permutations = [_][3]ir.Id{
    .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 },
    .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 },
};

pub fn compile(
    allocator: std.mem.Allocator,
    kind: Kind,
    options: data.coalescing.Options,
) !source.Compiled {
    return build(
        allocator,
        if (kind == .swap) &.{ 1, 0 } else &.{ 1, 2, 0 },
        &.{ 2, 0, 1 },
        .none,
        options,
    );
}

pub fn compileLoop(
    allocator: std.mem.Allocator,
    kind: LoopKind,
    options: data.coalescing.Options,
) !source.Compiled {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const functions = try a.alloc(ir.Function, 3);
    const blocks = try a.alloc(ir.Block, 11);
    const entries = [_][4]ir.Id{ .{ 0, 1, 2, 3 }, .{ 7, 4, 6, 5 } };
    for (entries, 0..) |roles, id| {
        const inputs: []const ir.Id = if (id == 0) &.{ 0, 1, 2 } else &.{ 2, 0, 1 };
        functions[id] = .{
            .entry = roles[0],
            .inputs = inputs,
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 0, 1, 2 } },
            .result = 2,
        };
        try loopBody(a, blocks, id, roles, inputs, id == 1 and kind == .loop_near);
    }
    functions[2] = .{
        .entry = 8,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 0, 0, 0, 2, 2, 4 } },
        .result = 4,
    };
    for (0..2) |id| blocks[8 + id] = try source.own(ir.Block, a, .{
        .function = 2,
        .instructions = &.{},
        .terminator = .{ .call = .{
            .function = id,
            .arguments = &.{ 0, 1, 2 },
            .next = .{
                .block = 9 + id,
                .assignments = &.{.{ .destination = 3 + id, .source = .returned }},
            },
        } },
    });
    blocks[10] = .{ .function = 2, .instructions = &.{.{
        .destination = 5,
        .opcode = .product,
        .operands = &.{ 3, 4 },
    }}, .terminator = .{ .return_value = 5 } };
    const program: ir.Program = .{
        .roots = .{ .entry = 2, .result = 4, .failure = 3 },
        .schemas = &.{
            .u64,                       .boolean,
            .{ .product = &.{ 0, 0 } }, .unit,
            .{ .product = &.{ 2, 2 } },
        },
        .constants = &.{
            .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 3, .bytes = &.{} },
        },
        .effects = &.{},
        .functions = functions,
        .blocks = blocks,
    };
    const result = try data.coalescing.run(allocator, program, options);
    return .{ .arena = result.arena, .program = result.program, .flow = result.flow };
}

fn loopBody(
    a: std.mem.Allocator,
    blocks: []ir.Block,
    function: ir.Id,
    roles: [4]ir.Id,
    inputs: []const ir.Id,
    changed: bool,
) !void {
    blocks[@intCast(roles[0])] = try source.own(ir.Block, a, .{
        .function = function,
        .instructions = &.{
            .{ .destination = 3, .opcode = .constant, .immediate = 0 },
            .{ .destination = 4, .opcode = .constant, .immediate = 1 },
        },
        .terminator = .{ .jump = .{ .block = roles[1] } },
    });
    blocks[@intCast(roles[1])] = try source.own(ir.Block, a, .{
        .function = function,
        .instructions = &.{.{
            .destination = 5,
            .opcode = .equal,
            .operands = &.{ inputs[0], 3 },
        }},
        .terminator = .{ .branch = .{
            .condition = 5,
            .when_true = .{ .block = roles[3] },
            .when_false = .{ .block = roles[2] },
        } },
    });
    blocks[@intCast(roles[2])] = try source.own(ir.Block, a, .{
        .function = function,
        .instructions = &.{.{
            .destination = inputs[0],
            .opcode = .integer_sub,
            .operands = &.{ inputs[0], 4 },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
        }},
        .terminator = .{ .jump = .{ .block = roles[1], .assignments = &.{
            .{ .destination = inputs[1], .source = .{ .slot = inputs[2] } },
            .{ .destination = inputs[2], .source = .{ .slot = inputs[1] } },
        } } },
    });
    blocks[@intCast(roles[3])] = try source.own(ir.Block, a, .{
        .function = function,
        .instructions = &.{.{
            .destination = 6,
            .opcode = .product,
            .operands = if (changed) &.{ inputs[2], inputs[1] } else &.{ inputs[1], inputs[2] },
        }},
        .terminator = .{ .return_value = 6 },
    });
}

/// Seeds 0..35 enumerate independent assignment/slot permutations. Adding 64
/// changes only the second body's returned field order, a semantic negative.
/// Adding 128 instead creates a single out-of-range destination for rejection.
pub fn generated(
    allocator: std.mem.Allocator,
    seed: usize,
    options: data.coalescing.Options,
) !source.Compiled {
    if (seed >= 192 or seed % 64 >= 36) return error.InvalidSeed;
    const ordinal = seed % 64;
    const mutation: Mutation = if (seed >= 128)
        .invalid_slot
    else if (seed >= 64)
        .order
    else
        .none;
    return build(
        allocator,
        &permutations[ordinal % 6],
        &permutations[ordinal / 6],
        mutation,
        options,
    );
}

fn build(
    allocator: std.mem.Allocator,
    order: []const ir.Id,
    renamed: []const ir.Id,
    mutation: Mutation,
    options: data.coalescing.Options,
) !source.Compiled {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const functions = try a.alloc(ir.Function, 3);
    const blocks = try a.alloc(ir.Block, 7);
    try definePermutedBodies(a, functions, blocks, order, renamed, mutation);
    functions[2] = .{
        .entry = 4,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 0, 0, 0, 1, 1, 3 } },
        .result = 3,
    };
    for (0..2) |id| {
        const assignments = try a.alloc(ir.Assignment, 1);
        assignments[0] = .{ .destination = 3 + id, .source = .returned };
        blocks[4 + id] = .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
            .function = id,
            .arguments = &.{ 0, 1, 2 },
            .next = .{ .block = 5 + id, .assignments = assignments },
        } } };
    }
    blocks[6] = .{
        .function = 2,
        .instructions = &.{.{ .destination = 5, .opcode = .product, .operands = &.{ 3, 4 } }},
        .terminator = .{ .return_value = 5 },
    };
    const program: ir.Program = .{
        .roots = .{ .entry = 2, .result = 3, .failure = 2 },
        .schemas = &.{ .u64, .{ .product = &.{ 0, 0, 0 } }, .unit, .{ .product = &.{ 1, 1 } } },
        .constants = &.{},
        .effects = &.{},
        .functions = functions,
        .blocks = blocks,
    };
    const result = try data.coalescing.run(allocator, program, options);
    return .{ .arena = result.arena, .program = result.program, .flow = result.flow };
}

fn definePermutedBodies(
    a: std.mem.Allocator,
    functions: []ir.Function,
    blocks: []ir.Block,
    order: []const ir.Id,
    renamed: []const ir.Id,
    mutation: Mutation,
) !void {
    for (0..2) |id| {
        const inputs: []const ir.Id = if (id == 0) &.{ 0, 1, 2 } else renamed;
        functions[id] = .{
            .entry = id * 2,
            .inputs = inputs,
            .layout = .{ .slots = &.{ 0, 0, 0, 1 } },
            .result = 1,
        };
        const assignments = try a.alloc(ir.Assignment, order.len);
        for (assignments, order, 0..) |*assignment, from, to| assignment.* = .{
            .destination = inputs[to],
            .source = .{ .slot = inputs[from] },
        };
        blocks[id * 2] = .{
            .function = id,
            .instructions = &.{},
            .terminator = .{ .jump = .{ .block = id * 2 + 1, .assignments = assignments } },
        };
        const operations = try a.alloc(ir.Instruction, 1);
        const operands = try a.dupe(ir.Id, inputs);
        if (id == 1 and mutation == .order) std.mem.swap(ir.Id, &operands[0], &operands[1]);
        operations[0] = .{
            .destination = if (id == 1 and mutation == .invalid_slot) 4 else 3,
            .opcode = .product,
            .operands = operands,
        };
        blocks[id * 2 + 1] = .{
            .function = id,
            .instructions = operations,
            .terminator = .{ .return_value = 3 },
        };
    }
}
