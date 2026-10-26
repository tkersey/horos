const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const relation = @import("relation.zig");
const Error = relation.Error;
const require = relation.Context.require;
const Layout = relation.Layout;

const Permutation = struct { forward: []const u64, inverse: []const u64 };
const SchemaMap = struct { allowed: bool = false, permutation: ?Permutation = null };

fn checkedMaps(ctx: *relation.Context, layouts: []const Layout) Error![]const SchemaMap {
    try ctx.spend(ctx.before.schemas.len);
    const maps = try ctx.a.alloc(SchemaMap, ctx.before.schemas.len);
    @memset(maps, .{});
    try ctx.spend(ctx.policy.private_schemas.len);
    for (ctx.policy.private_schemas) |schema| {
        if (schema < maps.len) maps[@intCast(schema)].allowed = true;
    }
    for (layouts) |layout| {
        try ctx.spend(1);
        try require(layout.schema < maps.len);
        const map = &maps[@intCast(layout.schema)];
        try require(map.allowed and map.permutation == null);
        const shape = ctx.before.schemas[@intCast(layout.schema)];
        try require(shape == .product and layout.coordinates.len == shape.product.len);
        try ctx.spend(layout.coordinates.len);
        const inverse = try ctx.a.alloc(u64, layout.coordinates.len);
        @memset(inverse, layout.coordinates.len);
        for (layout.coordinates, 0..) |coordinate, index| {
            try ctx.spend(1);
            try require(coordinate < inverse.len);
            try require(inverse[@intCast(coordinate)] == inverse.len);
            inverse[@intCast(coordinate)] = @intCast(index);
        }
        map.permutation = .{ .forward = layout.coordinates, .inverse = inverse };
    }
    return maps;
}

pub fn apply(ctx: *relation.Context, layouts: []const Layout) Error!void {
    const maps = try checkedMaps(ctx, layouts);
    const facts = try data.admission.schemasWithWork(ctx.a, ctx.before.schemas, ctx.left);
    const order_facts = try orderFacts(ctx, facts);
    try ctx.spend(ctx.before.schemas.len);
    const changed = try ctx.a.alloc(bool, ctx.before.schemas.len);
    @memset(changed, false);
    try rewriteSchemas(ctx, maps, facts, changed);
    try closure(ctx, changed);
    try ctx.spend(ctx.policy.fixed_schemas.len);
    for (ctx.policy.fixed_schemas) |id| {
        try require(id < changed.len and !changed[@intCast(id)]);
    }
    for (ctx.before.effects) |effect| {
        try ctx.spend(1);
        try require(!changed[@intCast(effect.payload)] and !changed[@intCast(effect.result)]);
        try ctx.spend(effect.bodies.len);
        for (effect.bodies) |id| try require(!changed[@intCast(id)]);
    }
    try ctx.spend(ctx.before.resources.len);
    for (ctx.before.resources) |resource|
        try require(!changed[@intCast(resource.representation)]);
    for (ctx.before.constants, 0..) |literal, i| {
        try ctx.spend(1);
        if (!changed[@intCast(literal.schema)]) continue;
        @constCast(ctx.expected.constants)[i].bytes = try transport(ctx, facts, maps, literal);
    }
    for (ctx.before.values, 0..) |value, i| {
        try ctx.spend(1);
        if (value.expression == .primitive) try primitive(ctx, maps, changed, order_facts, i);
    }
    for (ctx.before.terms, 0..) |term, i| {
        try ctx.spend(1);
        if (term != .unpack_product) continue;
        const unpack = term.unpack_product;
        const schema = ctx.before.values[@intCast(unpack.value)].schema;
        const map = maps[@intCast(schema)].permutation orelse continue;
        try ctx.spend(unpack.variables.len);
        const variables = try ctx.a.alloc(u64, unpack.variables.len);
        for (map.forward, variables) |old, *variable| variable.* = unpack.variables[@intCast(old)];
        @constCast(ctx.expected.terms)[i].unpack_product.variables = variables;
    }
}

fn rewriteSchemas(
    ctx: *relation.Context,
    maps: []const SchemaMap,
    facts: data.admission.SchemaFacts,
    changed: []bool,
) Error!void {
    for (maps, 0..) |map, schema| {
        try ctx.spend(1);
        const order = (map.permutation orelse continue).forward;
        try require(facts.exportable[schema]);
        try ctx.spend(order.len);
        const fields = try ctx.a.alloc(u64, order.len);
        const shape = ctx.before.schemas[schema].product;
        for (order, fields) |old, *field| field.* = shape[@intCast(old)];
        @constCast(ctx.expected.schemas)[schema] = .{ .product = fields };
        changed[schema] = true;
    }
}

fn child(ctx: *relation.Context, changed: []const bool, id: u64) Error!bool {
    try ctx.spend(1);
    return changed[@intCast(id)];
}
fn children(ctx: *relation.Context, changed: []const bool, ids: []const u64) Error!bool {
    for (ids) |id| if (try child(ctx, changed, id)) return true;
    return false;
}
fn affected(ctx: *relation.Context, shape: p.Schema, changed: []const bool) Error!bool {
    return switch (shape) {
        .product, .sum => |ids| children(ctx, changed, ids),
        .seq => |id| child(ctx, changed, id),
        .vector => |v| child(ctx, changed, v.element),
        .array => |v| child(ctx, changed, v.element),
        .internal => |inner| switch (inner) {
            .computation => |v| try child(ctx, changed, v.result) or
                try children(ctx, changed, v.parameters) or
                try children(ctx, changed, v.capture_bound),
            .resumption => |v| try child(ctx, changed, v.input) or
                try child(ctx, changed, v.answer) or try children(ctx, changed, v.capture_bound),
            .cell => |v| child(ctx, changed, v.element),
            .borrowed => |v| child(ctx, changed, v.value),
            .suspension_package => |v| child(ctx, changed, v),
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
            if (changed[i] or !try affected(ctx, shape, changed)) continue;
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
    maps: []const SchemaMap,
    changed: []const bool,
    order_facts: OrderFacts,
    index: usize,
) Error!void {
    const value = ctx.before.values[index];
    const op = value.expression.primitive;
    const target = &@constCast(ctx.expected.values)[index].expression.primitive;
    if (op.opcode == .product) {
        if (maps[@intCast(value.schema)].permutation) |map| {
            try preserveOrder(ctx, order_facts, op.operands, map.forward);
            try ctx.spend(op.operands.len);
            const operands = try ctx.a.alloc(u64, op.operands.len);
            for (map.forward, operands) |old, *operand| operand.* = op.operands[@intCast(old)];
            target.operands = operands;
        }
        return;
    }
    if (op.opcode == .field) {
        const schema = ctx.before.values[@intCast(op.operands[0])].schema;
        if (maps[@intCast(schema)].permutation) |map|
            target.immediate = map.inverse[@intCast(op.immediate)];
        return;
    }
    var touches = changed[@intCast(value.schema)];
    try ctx.spend(op.operands.len);
    for (op.operands) |id| touches = touches or
        changed[@intCast(ctx.before.values[@intCast(id)].schema)];
    if (!touches) return;
    if (op.opcode == .sequence_pop_last and maps[@intCast(value.schema)].permutation != null)
        return error.UnsupportedRelation;
    if (op.opcode == .sequence_pop) {
        const pair = ctx.before.schemas[@intCast(value.schema)].sum[1];
        if (maps[@intCast(pair)].permutation != null) return error.UnsupportedRelation;
    }
    switch (op.opcode) {
        .constant,
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
    maps: []const SchemaMap,
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
    try ctx.spend(schemas.len);
    const pieces = try ctx.a.alloc(Piece, schemas.len);
    for (schemas, pieces) |schema, *piece| piece.* = .{
        .schema = schema,
        .bytes = data.admission.readValueWithWork(
            ctx.a,
            ctx.before.schemas,
            facts,
            schema,
            &reader,
            ctx.left,
        ) catch |err| switch (err) {
            error.ValueWorkLimit => return error.RelationLimit,
            else => return err,
        },
    };
    if (maps[@intCast(literal.schema)].permutation) |map| {
        try ctx.spend(pieces.len);
        const ordered = try ctx.a.alloc(Piece, pieces.len);
        for (map.forward, ordered) |old, *piece| piece.* = pieces[@intCast(old)];
        result.children = ordered;
    } else result.children = pieces;
    try ctx.spend(pieces.len);
    result.outputs = try ctx.a.alloc([]const u8, pieces.len);
    return result;
}
fn transport(
    ctx: *relation.Context,
    facts: data.admission.SchemaFacts,
    maps: []const SchemaMap,
    literal: p.Literal,
) Error![]const u8 {
    var pending: std.ArrayList(Frame) = .empty;
    try pending.append(ctx.a, try frame(ctx, facts, maps, literal));
    while (pending.items.len != 0) {
        const current = &pending.items[pending.items.len - 1];
        if (current.cursor < current.children.len) {
            const next = current.children[current.cursor];
            try pending.append(ctx.a, try frame(ctx, facts, maps, .{
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
    try ctx.spend(ctx.before.values.len);
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

const OrderFacts = struct {
    stable: []const bool,
    cacheable: []const bool,
    cores: []const u64,
};
fn orderFacts(ctx: *relation.Context, facts: data.admission.SchemaFacts) Error!OrderFacts {
    const stable = try totalValues(ctx, facts, false);
    const traits = try data.traits.deriveWithWork(ctx.a, ctx.before.schemas, ctx.left);
    const cacheable = try @import("value_cache.zig").deriveWithWork(
        ctx.a,
        ctx.before,
        traits,
        ctx.left,
    );
    try ctx.spend(ctx.before.values.len);
    const cores = try ctx.a.alloc(u64, ctx.before.values.len);
    for (ctx.before.values, 0..) |value, i| {
        try ctx.spend(1);
        cores[i] = @intCast(i);
        if (!cacheable[i] or value.expression != .primitive) continue;
        const op = value.expression.primitive;
        if (op.opcode == .field or op.opcode == .move)
            cores[i] = cores[@intCast(op.operands[0])];
    }
    return .{ .stable = stable, .cacheable = cacheable, .cores = cores };
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
        const previous = operands[cursor];
        if (coordinate != cursor and (!facts.cacheable[@intCast(next)] or
            !facts.cacheable[@intCast(previous)] or
            facts.cores[@intCast(next)] != facts.cores[@intCast(previous)]))
            return error.UnsupportedRelation;
        cursor += 1;
    }
}

const OccurrenceFixture = struct {
    module: @import("ast.zig").Module,
    product: u64,
    projection: u64,
};

fn occurrenceFixture(b: *@import("../source.zig").Builder) !OccurrenceFixture {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const product = try b.schema(.{ .product = &.{ boolean, boolean } });
    const staged = try b.schema(.{ .product = &.{ unit, boolean } });
    const owner = b.region();
    const region = try b.schema(.{ .internal = .{ .region = owner } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{
        .element = boolean,
        .region = owner,
    } } });
    const inside = try b.declare(&.{region}, boolean, &.{}, &.{owner});
    const variable = try b.variable(cell);
    const target = try b.reference(variable);
    const read = try b.primitive(boolean, .cell_get, &.{target}, 0);
    const flipped = try b.primitive(boolean, .boolean_not, &.{read}, 0);
    const write = try b.primitive(unit, .cell_set, &.{ target, flipped }, 0);
    const ordered = try b.primitive(staged, .product, &.{ write, read }, 0);
    const toggled = try b.primitive(boolean, .field, &.{ordered}, 1);
    const pair = try b.primitive(product, .product, &.{ toggled, toggled }, 0);
    const projection = try b.primitive(boolean, .field, &.{pair}, 0);
    const initial = try b.primitive(cell, .cell_new, &.{
        try b.reference(b.parameter(inside, 0)), try b.constant(bool, false),
    }, 0);
    try b.define(inside, try b.bind(variable, try b.pure(initial), try b.pure(projection)));
    const main = try b.declare(&.{}, boolean, &.{}, &.{});
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = boolean,
        .regions = &.{owner},
    } } });
    try b.define(main, try b.term(.{ .with_region = .{
        .region = owner,
        .body = try b.lambda(inside, signature),
    } }));
    return .{ .module = b.module(main, unit), .product = product, .projection = projection };
}

test "private layout retains distinct occurrences of one stateful expression" {
    const source = @import("../source.zig");
    const allocator = std.testing.allocator;
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const fixture = try occurrenceFixture(&b);
    const before = fixture.module;
    const after = try source.own(source.ast.Module, b.allocator(), before);
    const projection = &@constCast(after.values)[@intCast(fixture.projection)].expression.primitive;
    projection.immediate = 1;
    var work: u64 = 1_000_000;
    try source.admitWithWork(allocator, before, &work);
    try source.admitWithWork(allocator, after, &work);
    const policy: relation.Policy = .{ .private_schemas = &.{fixture.product} };
    var step: relation.Step = .{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = fixture.product,
        .coordinates = &.{ 1, 0 },
    }} } };
    try std.testing.expectError(error.UnsupportedRelation, relation.validate(
        allocator,
        before,
        after,
        &.{step},
        policy,
    ));
    projection.immediate = 0;
    step.rule.product_layout = &.{.{ .schema = fixture.product, .coordinates = &.{ 0, 1 } }};
    try relation.validate(allocator, before, after, &.{step}, policy);
}
