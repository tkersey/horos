const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const relation = @import("relation.zig");
const Error = relation.Error;
const require = relation.Context.require;
const Layout = relation.Layout;

pub fn permutation(layouts: []const Layout, schema: u64) ?[]const u64 {
    for (layouts) |layout| if (layout.schema == schema) return layout.coordinates;
    return null;
}
pub fn apply(ctx: *relation.Context, layouts: []const Layout) Error!void {
    const facts = try data.admission.schemas(ctx.a, ctx.before.schemas);
    const order_facts = try orderFacts(ctx, facts);
    const changed = try ctx.a.alloc(bool, ctx.before.schemas.len);
    @memset(changed, false);
    for (layouts, 0..) |layout, index| {
        try require(layout.schema < ctx.before.schemas.len);
        try require(permutation(layouts[0..index], layout.schema) == null);
        try require(std.mem.indexOfScalar(u64, ctx.policy.private_schemas, layout.schema) != null);
        const shape = ctx.before.schemas[@intCast(layout.schema)];
        try require(shape == .product and facts.exportable[@intCast(layout.schema)]);
        try require(layout.coordinates.len == shape.product.len);
        const fields = try ctx.a.alloc(u64, shape.product.len);
        for (layout.coordinates, 0..) |coordinate, i| {
            try require(coordinate < fields.len);
            try require(std.mem.indexOfScalar(u64, layout.coordinates[0..i], coordinate) == null);
            fields[i] = shape.product[@intCast(coordinate)];
        }
        @constCast(ctx.expected.schemas)[@intCast(layout.schema)] = .{ .product = fields };
        changed[@intCast(layout.schema)] = true;
    }
    try closure(ctx, changed);
    for (ctx.policy.fixed_schemas) |id| {
        try require(id < changed.len and !changed[@intCast(id)]);
    }
    for (ctx.before.effects) |effect| {
        try require(!changed[@intCast(effect.payload)] and !changed[@intCast(effect.result)]);
        for (effect.bodies) |id| try require(!changed[@intCast(id)]);
    }
    for (ctx.before.resources) |resource|
        try require(!changed[@intCast(resource.representation)]);
    for (ctx.before.constants, 0..) |literal, i| {
        if (!changed[@intCast(literal.schema)]) continue;
        @constCast(ctx.expected.constants)[i].bytes = try transport(ctx, facts, layouts, literal);
    }
    for (ctx.before.values, 0..) |value, i| {
        if (value.expression == .primitive) try primitive(ctx, layouts, changed, order_facts, i);
    }
    for (ctx.before.terms, 0..) |term, i| {
        if (term != .unpack_product) continue;
        const unpack = term.unpack_product;
        const schema = ctx.before.values[@intCast(unpack.value)].schema;
        const order = permutation(layouts, schema) orelse continue;
        const variables = try ctx.a.alloc(u64, unpack.variables.len);
        for (order, variables) |old, *variable| variable.* = unpack.variables[@intCast(old)];
        @constCast(ctx.expected.terms)[i].unpack_product.variables = variables;
    }
}
fn child(changed: []const bool, id: u64) bool {
    return changed[@intCast(id)];
}
fn children(changed: []const bool, ids: []const u64) bool {
    for (ids) |id| if (child(changed, id)) return true;
    return false;
}
fn affected(shape: p.Schema, changed: []const bool) bool {
    return switch (shape) {
        .product, .sum => |ids| children(changed, ids),
        .seq => |id| child(changed, id),
        .vector => |v| child(changed, v.element),
        .array => |v| child(changed, v.element),
        .internal => |inner| switch (inner) {
            .computation => |v| child(changed, v.result) or children(changed, v.parameters) or
                children(changed, v.capture_bound),
            .resumption => |v| child(changed, v.input) or child(changed, v.answer) or
                children(changed, v.capture_bound),
            .cell => |v| child(changed, v.element),
            .borrowed => |v| child(changed, v.value),
            .suspension_package => |v| child(changed, v),
            .capability, .region, .abstract_resource => false,
        },
        else => false,
    };
}
fn closure(ctx: *relation.Context, changed: []bool) Error!void {
    for (0..changed.len + 1) |_| {
        var progress = false;
        for (ctx.before.schemas, 0..) |shape, i| {
            try ctx.spend(1);
            if (changed[i] or !affected(shape, changed)) continue;
            if (shape == .internal and shape.internal != .computation and
                shape.internal != .resumption) return error.UnsupportedRelation;
            changed[i] = true;
            progress = true;
        }
        if (!progress) return;
    }
    return error.InvalidRelation;
}
fn primitive(
    ctx: *relation.Context,
    layouts: []const Layout,
    changed: []const bool,
    order_facts: OrderFacts,
    index: usize,
) Error!void {
    const value = ctx.before.values[index];
    const op = value.expression.primitive;
    const target = &@constCast(ctx.expected.values)[index].expression.primitive;
    if (op.opcode == .product) {
        if (permutation(layouts, value.schema)) |order| {
            try preserveOrder(ctx, order_facts, op.operands, order);
            const operands = try ctx.a.alloc(u64, op.operands.len);
            for (order, operands) |old, *operand| operand.* = op.operands[@intCast(old)];
            target.operands = operands;
        }
        return;
    }
    if (op.opcode == .field) {
        const schema = ctx.before.values[@intCast(op.operands[0])].schema;
        if (permutation(layouts, schema)) |order| {
            target.immediate = std.mem.indexOfScalar(u64, order, op.immediate) orelse
                return error.InvalidRelation;
        }
        return;
    }
    var touches = changed[@intCast(value.schema)];
    for (op.operands) |id| touches = touches or
        changed[@intCast(ctx.before.values[@intCast(id)].schema)];
    if (!touches) return;
    if (op.opcode == .sequence_pop_last and permutation(layouts, value.schema) != null)
        return error.UnsupportedRelation;
    if (op.opcode == .sequence_pop) {
        const pair = ctx.before.schemas[@intCast(value.schema)].sum[1];
        if (permutation(layouts, pair) != null) return error.UnsupportedRelation;
    }
    switch (op.opcode) {
        .move,
        .variant,
        .variant_tag,
        .variant_payload,
        .sequence,
        .sequence_length,
        .sequence_get,
        .sequence_append,
        .sequence_concat,
        .sequence_pop,
        .sequence_set,
        .sequence_take,
        .sequence_pop_last,
        .select,
        .equal,
        .computation,
        => {},
        else => return error.UnsupportedRelation,
    }
}
const Piece = struct { schema: u64, bytes: []const u8 };
const Frame = struct {
    literal: p.Literal,
    children: []const Piece = &.{},
    outputs: [][]const u8 = &.{},
    prefix: []const u8 = &.{},
    cursor: usize = 0,
};
fn frame(
    ctx: *relation.Context,
    facts: data.admission.SchemaFacts,
    layouts: []const Layout,
    literal: p.Literal,
) Error!Frame {
    try ctx.spend(1);
    var result: Frame = .{ .literal = literal };
    var reader: data.wire.Reader = .{ .input = literal.bytes };
    const shape = ctx.before.schemas[@intCast(literal.schema)];
    var schemas: []const u64 = &.{};
    switch (shape) {
        .product => |fields| schemas = fields,
        .sum => |fields| schemas = try ctx.a.dupe(u64, &.{fields[try reader.count()]}),
        .seq, .vector, .array => {
            const count = if (shape == .array) shape.array.length else try reader.natural();
            try ctx.spend(std.math.cast(usize, count) orelse return error.RelationLimit);
            const ids = try ctx.a.alloc(u64, @intCast(count));
            @memset(ids, switch (shape) {
                .seq => |id| id,
                .vector => |v| v.element,
                .array => |v| v.element,
                else => unreachable,
            });
            schemas = ids;
        },
        else => return result,
    }
    result.prefix = literal.bytes[0..reader.position];
    const pieces = try ctx.a.alloc(Piece, schemas.len);
    for (schemas, pieces) |schema, *piece| piece.* = .{
        .schema = schema,
        .bytes = try data.admission.readValue(ctx.a, ctx.before.schemas, facts, schema, &reader),
    };
    if (permutation(layouts, literal.schema)) |order| {
        const ordered = try ctx.a.alloc(Piece, pieces.len);
        for (order, ordered) |old, *piece| piece.* = pieces[@intCast(old)];
        result.children = ordered;
    } else result.children = pieces;
    result.outputs = try ctx.a.alloc([]const u8, pieces.len);
    return result;
}
fn transport(
    ctx: *relation.Context,
    facts: data.admission.SchemaFacts,
    layouts: []const Layout,
    literal: p.Literal,
) Error![]const u8 {
    var pending: std.ArrayList(Frame) = .empty;
    try pending.append(ctx.a, try frame(ctx, facts, layouts, literal));
    while (pending.items.len != 0) {
        const current = &pending.items[pending.items.len - 1];
        if (current.cursor < current.children.len) {
            const next = current.children[current.cursor];
            try pending.append(ctx.a, try frame(ctx, facts, layouts, .{
                .schema = next.schema,
                .bytes = next.bytes,
            }));
            continue;
        }
        const bytes = if (current.children.len == 0) current.literal.bytes else blk: {
            try ctx.spend(current.literal.bytes.len);
            const output = try ctx.a.alloc(u8, current.literal.bytes.len);
            var writer: data.wire.Writer = .{ .output = output };
            try writer.put(current.prefix);
            for (current.outputs) |part| try writer.put(part);
            try require(writer.position == output.len);
            break :blk output;
        };
        _ = pending.pop();
        if (pending.items.len == 0) return bytes;
        const parent = &pending.items[pending.items.len - 1];
        parent.outputs[parent.cursor] = bytes;
        parent.cursor += 1;
    }
    unreachable;
}

pub fn totalValues(
    ctx: *relation.Context,
    facts: data.admission.SchemaFacts,
    product_construction: bool,
) Error![]const bool {
    const stable = try ctx.a.alloc(bool, ctx.before.values.len);
    @memset(stable, false);
    for (ctx.before.values, 0..) |value, i| {
        try ctx.spend(1);
        if (!facts.exportable[@intCast(value.schema)]) continue;
        stable[i] = switch (value.expression) {
            .variable, .literal => true,
            .lambda => false,
            .primitive => |op| blk: {
                if (op.failures.len != 0) break :blk false;
                for (op.operands) |operand| {
                    try ctx.spend(1);
                    if (!stable[@intCast(operand)]) break :blk false;
                }
                break :blk switch (op.opcode) {
                    .constant,
                    .move,
                    .field,
                    .equal,
                    .less,
                    .boolean_not,
                    .variant_tag,
                    .sequence_length,
                    .integer_bit_not,
                    .integer_bit_and,
                    .integer_bit_or,
                    .integer_bit_xor,
                    => true,
                    .product => product_construction,
                    else => false,
                };
            },
        };
    }
    return stable;
}

const OrderFacts = struct { stable: []const bool, cores: []const u64 };
fn orderFacts(ctx: *relation.Context, facts: data.admission.SchemaFacts) Error!OrderFacts {
    const stable = try totalValues(ctx, facts, false);
    const traits = try data.traits.derive(ctx.a, ctx.before.schemas);
    const cacheable = try @import("value_cache.zig").derive(ctx.a, ctx.before, traits);
    const cores = try ctx.a.alloc(u64, ctx.before.values.len);
    for (ctx.before.values, 0..) |value, i| {
        try ctx.spend(1);
        cores[i] = @intCast(i);
        if (!cacheable[i] or value.expression != .primitive) continue;
        const op = value.expression.primitive;
        if (op.opcode == .field or op.opcode == .move)
            cores[i] = cores[@intCast(op.operands[0])];
    }
    return .{ .stable = stable, .cores = cores };
}
fn preserveOrder(
    ctx: *relation.Context,
    facts: OrderFacts,
    operands: []const u64,
    order: []const u64,
) Error!void {
    var cursor: usize = 0;
    for (order) |coordinate| {
        try ctx.spend(1);
        const next = operands[@intCast(coordinate)];
        if (facts.stable[@intCast(next)]) continue;
        while (cursor < operands.len and facts.stable[@intCast(operands[cursor])])
            cursor += 1;
        try require(cursor < operands.len);
        if (facts.cores[@intCast(next)] != facts.cores[@intCast(operands[cursor])])
            return error.UnsupportedRelation;
        cursor += 1;
    }
}
