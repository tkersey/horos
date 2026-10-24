const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const relation = @import("relation.zig");
const ast = @import("ast.zig");
const source = @import("../source.zig");
const k = source.specialize.values;
const Error = relation.Error;
const require = relation.Context.require;

pub fn apply(ctx: *relation.Context, rule: relation.Scalar) Error!void {
    try require(rule.value < ctx.before.values.len);
    const value = ctx.before.values[@intCast(rule.value)];
    try require(value.expression == .primitive);
    const result = switch (rule.rule) {
        .fold => try fold(ctx, value),
        .identity => try identity(ctx, value),
        .projection => try projection(ctx, value),
    };
    try require(result.schema == value.schema);
    @constCast(ctx.expected.values)[@intCast(rule.value)] = result;
}
fn fold(ctx: *relation.Context, value: ast.Value) Error!ast.Value {
    const op = value.expression.primitive;
    try ctx.spend(op.operands.len);
    const known = try ctx.a.alloc(k.Knowledge, op.operands.len);
    for (op.operands, known) |id, *item| {
        const operand = ctx.before.values[@intCast(id)];
        try require(operand.expression == .literal);
        item.* = .{ .known = ctx.before.constants[@intCast(operand.expression.literal)] };
    }
    const facts = try data.admission.schemasWithWork(ctx.a, ctx.before.schemas, ctx.left);
    const result = k.primitive(ctx.a, ctx.before, facts, value, known, ctx.left) catch |err|
        return if (err == error.SpecializationLimit) error.RelationLimit else err;
    try require(result == .known);
    const literal = try appendFolded(ctx, result.known);
    return .{ .schema = value.schema, .expression = .{ .literal = literal } };
}
fn appendFolded(ctx: *relation.Context, literal: p.Literal) Error!u64 {
    const original_count = ctx.before.constants.len;
    try require(ctx.constants.len >= original_count);
    const emitted = if (ctx.constants.len > original_count) ctx.constants[original_count] else null;
    const retain_unit = if (emitted) |unit|
        ctx.before.schemas[@intCast(literal.schema)] == .unit and unit.schema != literal.schema
    else
        false;
    const index = std.math.add(usize, original_count, @intFromBool(retain_unit)) catch
        return error.RelationLimit;
    const count = std.math.add(usize, index, 1) catch return error.RelationLimit;
    try ctx.spend(count);
    const constants = try ctx.a.alloc(p.Literal, count);
    @memcpy(constants[0..original_count], ctx.before.constants);
    if (retain_unit) constants[original_count] = emitted.?;
    constants[index] = literal;
    ctx.expected.constants = constants;
    if (emitted) |unit| {
        try require(ctx.constants.len == original_count + 1);
        const selected = try @import("check.zig").selectUnit(
            ctx.expected.schemas,
            constants,
            ctx.left,
        ) orelse return error.InvalidRelation;
        try require(selected.schema == unit.schema);
        try transportEmittedUnit(ctx, original_count, selected.constant orelse count);
    }
    return index;
}
fn transportEmittedUnit(ctx: *relation.Context, before: u64, after: u64) Error!void {
    for (@constCast(ctx.expected.values)) |*value| {
        try ctx.spend(1);
        if (value.expression != .primitive) continue;
        const op = &value.expression.primitive;
        if (op.opcode == .constant and op.immediate == before) op.immediate = after;
        try ctx.spend(op.failures.len);
        for (@constCast(op.failures)) |*failure|
            if (failure.value == before) {
                failure.value = after;
            };
    }
}
fn leaf(ctx: *relation.Context, id: p.Id) bool {
    const value = ctx.before.values[@intCast(id)];
    return value.expression == .literal or
        (value.expression == .variable and ctx.before.schemas[@intCast(value.schema)] != .internal);
}
fn identity(ctx: *relation.Context, value: ast.Value) Error!ast.Value {
    const op = value.expression.primitive;
    if (op.opcode == .move) return ctx.before.values[@intCast(op.operands[0])];
    if (op.opcode == .boolean_not or op.opcode == .integer_bit_not) {
        const child = ctx.before.values[@intCast(op.operands[0])];
        try require(child.expression == .primitive);
        try require(child.expression.primitive.opcode == op.opcode);
        return ctx.before.values[@intCast(child.expression.primitive.operands[0])];
    }
    if (try maskIdentity(ctx, value)) |result| return result;
    try require(op.opcode == .integer_bit_and or op.opcode == .integer_bit_or);
    try require(op.operands[0] == op.operands[1] and leaf(ctx, op.operands[0]));
    return ctx.before.values[@intCast(op.operands[0])];
}
fn projection(ctx: *relation.Context, value: ast.Value) Error!ast.Value {
    const op = value.expression.primitive;
    try require(op.opcode == .field);
    const product = ctx.before.values[@intCast(op.operands[0])];
    try require(product.expression == .primitive);
    const constructor = product.expression.primitive;
    try require(constructor.opcode == .product and op.immediate < constructor.operands.len);
    const facts = try data.admission.schemasWithWork(ctx.a, ctx.before.schemas, ctx.left);
    const total = try @import("relation_layout.zig").totalValues(ctx, facts, true);
    for (constructor.operands, 0..) |operand, index| {
        try ctx.spend(1);
        if (index != op.immediate) try require(total[@intCast(operand)]);
    }
    try require(facts.exportable[@intCast(product.schema)]);
    return ctx.before.values[@intCast(constructor.operands[@intCast(op.immediate)])];
}

fn maskIdentity(ctx: *relation.Context, value: ast.Value) Error!?ast.Value {
    const op = value.expression.primitive;
    const mask: u8 = switch (op.opcode) {
        .integer_bit_and => 255,
        .integer_bit_or, .integer_bit_xor => 0,
        else => return null,
    };
    for (0..2) |index| {
        const operand = ctx.before.values[@intCast(op.operands[index])];
        if (operand.expression != .literal) continue;
        const literal = ctx.before.constants[@intCast(operand.expression.literal)];
        try ctx.spend(literal.bytes.len);
        if (!std.mem.allEqual(u8, literal.bytes, mask)) continue;
        return ctx.before.values[@intCast(op.operands[1 - index])];
    }
    return null;
}
