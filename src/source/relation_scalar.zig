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
    const known = try ctx.a.alloc(k.Knowledge, op.operands.len);
    for (op.operands, known) |id, *item| {
        const operand = ctx.before.values[@intCast(id)];
        try require(operand.expression == .literal);
        item.* = .{ .known = ctx.before.constants[@intCast(operand.expression.literal)] };
    }
    const facts = try data.admission.schemas(ctx.a, ctx.before.schemas);
    const result = try k.primitive(ctx.a, ctx.before, facts, value, known, ctx.left);
    try require(result == .known);
    const constants = try ctx.a.alloc(p.Literal, ctx.before.constants.len + 1);
    @memcpy(constants[0..ctx.before.constants.len], ctx.before.constants);
    constants[ctx.before.constants.len] = result.known;
    ctx.expected.constants = constants;
    return .{ .schema = value.schema, .expression = .{ .literal = ctx.before.constants.len } };
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
    const facts = try data.admission.schemas(ctx.a, ctx.before.schemas);
    const total = try @import("relation_layout.zig").totalValues(ctx, facts, true);
    for (constructor.operands, 0..) |operand, index| {
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
