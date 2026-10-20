// Copyright (c) 2026 Boundary contributors. MIT license.
//! Symbolic execution of admitted scalar records for affine capture synthesis.
//! Slot writes replace versions. A parallel edge always reads the old view.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const space = @import("affine_space.zig");
pub const Expression = struct {
    state: space.Row = 0,
    input: space.Row = 0,
    constant: u64 = 0,
    pub fn xor(left: Expression, right: Expression) Expression {
        return .{
            .state = left.state ^ right.state,
            .input = left.input ^ right.input,
            .constant = left.constant ^ right.constant,
        };
    }
};
pub const Error = std.mem.Allocator.Error || space.Error;

pub fn unsignedWidth(schema: p.Schema) ?usize {
    return switch (schema) {
        .u8 => 1,
        .u16 => 2,
        .u32 => 4,
        .u64 => 8,
        else => null,
    };
}

/// Unsupported expressions become unknown. Their observers must seed original
/// coordinates or make the enclosing slice ineligible; unknown is never zero.
pub fn instruction(
    program: ir.Program,
    function: ir.Function,
    op: ir.Instruction,
    values: []const ?Expression,
    word_schema: p.Id,
    budget: *space.Budget,
) Error!?Expression {
    try budget.charge();
    if (op.destination >= function.layout.slots.len or function.layout.slots[
        @intCast(op.destination)
    ] != word_schema or op.failures.len != 0) return null;
    switch (op.opcode) {
        .move => {
            if (op.operands.len != 1 or op.immediate != 0) return null;
            return values[@intCast(op.operands[0])];
        },
        .integer_bit_xor => {
            if (op.operands.len != 2 or op.immediate != 0) return null;
            const left = values[@intCast(op.operands[0])] orelse return null;
            const right = values[@intCast(op.operands[1])] orelse return null;
            return left.xor(right);
        },
        .constant => {
            if (op.immediate >= program.constants.len or op.operands.len != 0) return null;
            const literal = program.constants[@intCast(op.immediate)];
            const width = unsignedWidth(program.schemas[@intCast(word_schema)]) orelse return null;
            if (literal.schema != word_schema or literal.bytes.len != width) return null;
            var constant: u64 = 0;
            for (
                literal.bytes,
                0..,
            ) |byte, index| constant |= @as(u64, byte) << @intCast(8 * index);
            return .{ .constant = constant };
        },
        else => return null,
    }
}

pub fn execute(
    program: ir.Program,
    block: ir.Block,
    values: []?Expression,
    word_schema: p.Id,
    budget: *space.Budget,
) Error!void {
    const function = program.functions[@intCast(block.function)];
    for (block.instructions) |op| {
        const value = try instruction(program, function, op, values, word_schema, budget);
        values[@intCast(op.destination)] = value;
    }
}

pub fn transfer(
    a: std.mem.Allocator,
    old: []const ?Expression,
    edge: ir.Edge,
    returned: ?Expression,
    budget: *space.Budget,
) Error![]?Expression {
    const next = try a.dupe(?Expression, old);
    errdefer a.free(next);
    for (edge.assignments) |assignment| {
        try budget.charge();
        next[@intCast(assignment.destination)] = switch (assignment.source) {
            .slot => |slot| old[@intCast(slot)],
            .returned => returned,
        };
    }
    return next;
}

/// Extract the next capture coordinates in their actual constructor/call order.
/// Closure consumes these state rows; synthesis retains input and affine terms.
pub fn interface(
    a: std.mem.Allocator,
    values: []const ?Expression,
    operands: []const p.Id,
    budget: *space.Budget,
) Error!?[]Expression {
    const result = try a.alloc(Expression, operands.len);
    errdefer a.free(result);
    for (operands, result) |slot, *out| {
        try budget.charge();
        out.* = values[@intCast(slot)] orelse {
            a.free(result);
            return null;
        };
    }
    return result;
}

test "record extraction preserves overwritten operands and parallel predecessor values" {
    const a = std.testing.allocator;
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0 } },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{.{
                .destination = 0,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 3 },
            }},
            .terminator = .{ .return_value = 0 },
        }},
    };
    var admitted = try @import("activation_ownership.zig").analyze(a, program);
    defer admitted.deinit();
    var values = [_]?Expression{
        .{ .state = 1 },
        .{ .state = 2 },
        .{ .state = 4 },
        .{ .input = 1 },
    };
    var budget: space.Budget = .{ .remaining = 10000 };
    try execute(program, program.blocks[0], &values, 0, &budget);
    try std.testing.expectEqualDeep(Expression{ .state = 1, .input = 1 }, values[0].?);
    const next = try transfer(a, &values, .{ .block = 0, .assignments = &.{
        .{ .destination = 0, .source = .{ .slot = 1 } },
        .{ .destination = 1, .source = .{ .slot = 2 } },
        .{ .destination = 2, .source = .{ .slot = 0 } },
    } }, null, &budget);
    defer a.free(next);
    const extracted = (try interface(a, next, &.{ 0, 1, 2 }, &budget)).?;
    defer a.free(extracted);
    var rows: [3]space.Row = undefined;
    for (extracted, &rows) |expression, *row| row.* = expression.state;
    var seed = try space.Space.init(3);
    _ = try seed.insert(3, &budget);
    _ = try seed.insert(6, &budget);
    const closed = try space.close(a, seed, &.{&rows}, &budget);
    try std.testing.expectEqual(@as(usize, 2), closed.rank);
    try std.testing.expectEqual(@as(space.Row, 1), extracted[2].input);
    try std.testing.expectEqual(@as(space.Row, 2), extracted[0].state);
}
