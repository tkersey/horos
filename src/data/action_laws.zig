// Copyright (c) 2026 Boundary contributors. MIT license.
//! Closed P15 registry. compose(outer, inner) acts as outer(inner(value)).
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const equal = @import("record_equal.zig").equal;
pub const Kind = enum { xor_word, boolean_table };
pub const Law = struct { kind: Kind, action: p.Id, value: p.Id, width: usize };
pub const Bindings = struct {
    summary: p.Id,
    summary_high: p.Id,
    action: p.Id,
    value: p.Id,
    result: p.Id,
    scratch: p.Id,
    scratch_high: p.Id,
};
pub fn classify(schemas: []const p.Schema, action: p.Id, value: p.Id) ?Law {
    if (action == value) {
        const width: usize = switch (schemas[@intCast(value)]) {
            .u8, .i8 => 1,
            .u16, .i16 => 2,
            .u32, .i32 => 4,
            .u64, .i64 => 8,
            else => return null,
        };
        return .{ .kind = .xor_word, .action = action, .value = value, .width = width };
    }
    const shape = schemas[@intCast(action)];
    if (schemas[@intCast(value)] != .boolean or shape != .product or !std.mem.eql(
        p.Id,
        shape.product,
        &.{ value, value },
    )) return null;
    return .{ .kind = .boolean_table, .action = action, .value = value, .width = 2 };
}
pub fn stateCount(law: Law) usize {
    return if (law.kind == .boolean_table) 2 else 1;
}
pub fn identity(law: Law, index: usize) []const u8 {
    return switch (law.kind) {
        .xor_word => (&@as([8]u8, @splat(0)))[0..law.width],
        .boolean_table => if (index == 0) &.{0} else &.{1},
    };
}
fn op(
    actual: ir.Instruction,
    tag: p.Opcode,
    destination: p.Id,
    operands: []const p.Id,
    immediate: p.Id,
) bool {
    return equal(
        ir.Instruction,
        .{
            .destination = destination,
            .opcode = tag,
            .operands = operands,
            .immediate = immediate,
        },
        actual,
    );
}
/// Match the original pending action, including its exact operand orientation.
pub fn matches(law: Law, block: ir.Block, action: p.Id, value: p.Id) bool {
    if (block.terminator != .return_value) return false;
    const out = block.terminator.return_value;
    return switch (law.kind) {
        .xor_word => block.instructions.len == 1 and op(
            block.instructions[0],
            .integer_bit_xor,
            out,
            &.{ action, value },
            0,
        ),
        .boolean_table => block.instructions.len == 3 and
            op(block.instructions[0], .field, block.instructions[0].destination, &.{action}, 0) and
            op(block.instructions[1], .field, block.instructions[1].destination, &.{action}, 1) and
            op(
                block.instructions[2],
                .select,
                out,
                &.{ value, block.instructions[1].destination, block.instructions[0].destination },
                0,
            ),
    };
}
fn owned(a: std.mem.Allocator, instructions: []const ir.Instruction) ![]const ir.Instruction {
    const result = try a.dupe(ir.Instruction, instructions);
    for (result) |*instruction| instruction.operands = try a.dupe(p.Id, instruction.operands);
    return result;
}
pub fn compose(a: std.mem.Allocator, law: Law, b: Bindings) ![]const ir.Instruction {
    if (law.kind == .xor_word) return owned(
        a,
        &.{.{
            .destination = b.summary,
            .opcode = .integer_bit_xor,
            .operands = &.{ b.summary, b.action },
        }},
    );
    const s = b.scratch;
    return owned(a, &.{
        .{ .destination = s, .opcode = .field, .operands = &.{b.action}, .immediate = 0 },
        .{
            .destination = b.scratch_high,
            .opcode = .field,
            .operands = &.{b.action},
            .immediate = 1,
        },
        .{ .destination = s, .opcode = .select, .operands = &.{ s, b.summary_high, b.summary } },
        .{
            .destination = b.scratch_high,
            .opcode = .select,
            .operands = &.{ b.scratch_high, b.summary_high, b.summary },
        },
    });
}
pub fn apply(a: std.mem.Allocator, law: Law, b: Bindings) ![]const ir.Instruction {
    if (law.kind == .xor_word) return owned(
        a,
        &.{.{
            .destination = b.result,
            .opcode = .integer_bit_xor,
            .operands = &.{ b.summary, b.value },
        }},
    );
    return owned(
        a,
        &.{.{
            .destination = b.result,
            .opcode = .select,
            .operands = &.{ b.value, b.summary_high, b.summary },
        }},
    );
}
// These check the actual operation/operand stream, not output from the emitters.
pub fn checkComposition(law: Law, b: Bindings, instructions: []const ir.Instruction) bool {
    if (law.kind == .xor_word) return instructions.len == 1 and op(
        instructions[0],
        .integer_bit_xor,
        b.summary,
        &.{ b.summary, b.action },
        0,
    );
    if (instructions.len != 4) return false;
    const s = b.scratch;
    return op(instructions[0], .field, s, &.{b.action}, 0) and
        op(instructions[1], .field, b.scratch_high, &.{b.action}, 1) and
        op(instructions[2], .select, s, &.{ s, b.summary_high, b.summary }, 0) and
        op(
            instructions[3],
            .select,
            b.scratch_high,
            &.{ b.scratch_high, b.summary_high, b.summary },
            0,
        );
}
pub fn checkApplication(law: Law, b: Bindings, instructions: []const ir.Instruction) bool {
    if (law.kind == .xor_word) return instructions.len == 1 and op(
        instructions[0],
        .integer_bit_xor,
        b.result,
        &.{ b.summary, b.value },
        0,
    );
    return instructions.len == 1 and op(
        instructions[0],
        .select,
        b.result,
        &.{ b.value, b.summary_high, b.summary },
        0,
    );
}
fn tableApply(table: u2, value: u1) u1 {
    return @truncate(table >> value);
}
fn tableCompose(outer: u2, inner: u2) u2 {
    return @as(u2, tableApply(outer, tableApply(inner, 0))) | (@as(u2, tableApply(outer, tableApply(inner, 1))) << 1);
}
test "Boolean actions exhaustively obey identity composition and noncommuting orientation" {
    for (0..4) |a| for (0..4) |b| for (0..4) |c| {
        const x: u2 = @intCast(a);
        const y: u2 = @intCast(b);
        const z: u2 = @intCast(c);
        try std.testing.expectEqual(x, tableCompose(2, x));
        try std.testing.expectEqual(x, tableCompose(x, 2));
        try std.testing.expectEqual(
            tableCompose(tableCompose(x, y), z),
            tableCompose(x, tableCompose(y, z)),
        );
        for (0..2) |v| try std.testing.expectEqual(
            tableApply(x, tableApply(y, @intCast(v))),
            tableApply(tableCompose(x, y), @intCast(v)),
        );
    };
    try std.testing.expect(tableCompose(1, 0) != tableCompose(0, 1));
}
fn relationCompose(outer: u4, inner: u4) u4 {
    var result: u4 = 0;
    for (0..2) |out| for (0..2) |in| for (0..2) |middle| {
        const left = (outer >> @as(u2, @intCast(out * 2 + middle))) & 1;
        const right = (inner >> @as(u2, @intCast(middle * 2 + in))) & 1;
        result |= (left & right) << @as(u2, @intCast(out * 2 + in));
    };
    return result;
}
test "finite Boolean-semiring relation composition validates associativity and distributivity" {
    for (0..16) |a| for (0..16) |b| for (0..16) |c| {
        const x: u4 = @intCast(a);
        const y: u4 = @intCast(b);
        const z: u4 = @intCast(c);
        try std.testing.expectEqual(x, relationCompose(9, x));
        try std.testing.expectEqual(x, relationCompose(x, 9));
        try std.testing.expectEqual(
            relationCompose(relationCompose(x, y), z),
            relationCompose(x, relationCompose(y, z)),
        );
        try std.testing.expectEqual(
            relationCompose(x, y | z),
            relationCompose(x, y) | relationCompose(x, z),
        );
        try std.testing.expectEqual(
            relationCompose(x | y, z),
            relationCompose(x, z) | relationCompose(y, z),
        );
    };
}
