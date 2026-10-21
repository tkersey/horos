// Copyright (c) 2026 Boundary contributors. MIT license.
//! Immutable binding-time facts. These rules never execute effects or storage.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ast = @import("ast.zig");
const source = @import("../source.zig");
pub const Error = source.Error || error{SpecializationLimit};
fn spend(left: *u64, count: u64) Error!void {
    if (left.* < count) return error.SpecializationLimit;
    left.* -= count;
}
fn readValue(
    a: std.mem.Allocator,
    schemas: []const p.Schema,
    facts: data.admission.SchemaFacts,
    schema: p.Id,
    reader: *data.wire.Reader,
    left: *u64,
) Error![]const u8 {
    return data.admission.readValueWithWork(a, schemas, facts, schema, reader, left) catch |err|
        return if (err == error.ValueWorkLimit) error.SpecializationLimit else err;
}
pub const Knowledge = union(enum) {
    dynamic,
    known: p.Literal,
    product: struct { schema: p.Id, fields: []const Knowledge },
};
pub fn own(a: std.mem.Allocator, value: Knowledge) Error!Knowledge {
    return source.own(Knowledge, a, value);
}
pub fn ownMany(a: std.mem.Allocator, values: []const Knowledge) Error![]const Knowledge {
    return source.own([]const Knowledge, a, values);
}
pub fn equal(a: std.mem.Allocator, lhs: Knowledge, rhs: Knowledge) Error!bool {
    return data.record.equalAlloc(Knowledge, a, lhs, rhs);
}
pub fn equalWithWork(
    a: std.mem.Allocator,
    lhs: Knowledge,
    rhs: Knowledge,
    work: ?*u64,
) Error!bool {
    const Pair = struct { lhs: Knowledge, rhs: Knowledge };
    var pending: std.ArrayList(Pair) = .empty;
    defer pending.deinit(a);
    try data.admission.spend(work, 1);
    try pending.append(a, .{ .lhs = lhs, .rhs = rhs });
    while (pending.pop()) |pair| {
        try data.admission.spend(work, 1);
        if (std.meta.activeTag(pair.lhs) != std.meta.activeTag(pair.rhs)) return false;
        switch (pair.lhs) {
            .dynamic => {},
            .known => |left| {
                const right = pair.rhs.known;
                if (left.schema != right.schema or left.bytes.len != right.bytes.len) return false;
                try data.admission.spend(work, left.bytes.len);
                if (!std.mem.eql(u8, left.bytes, right.bytes)) return false;
            },
            .product => |left| {
                const right = pair.rhs.product;
                if (left.schema != right.schema or
                    left.fields.len != right.fields.len) return false;
                try data.admission.spend(work, left.fields.len);
                for (left.fields, right.fields) |x, y| try pending.append(
                    a,
                    .{ .lhs = x, .rhs = y },
                );
            },
        }
    }
    return true;
}
const Validation = struct { schema: p.Id, value: Knowledge };
pub fn validate(
    a: std.mem.Allocator,
    m: ast.Module,
    facts: data.admission.SchemaFacts,
    schema: p.Id,
    k: Knowledge,
) Error!void {
    return validateWithWork(a, m, facts, schema, k, null);
}
pub fn validateWithWork(
    a: std.mem.Allocator,
    m: ast.Module,
    facts: data.admission.SchemaFacts,
    schema: p.Id,
    k: Knowledge,
    work: ?*u64,
) Error!void {
    var pending: std.ArrayList(Validation) = .empty;
    defer pending.deinit(a);
    var current: Validation = .{ .schema = schema, .value = k };
    var remaining = true;
    while (remaining) {
        try data.admission.spend(work, 1);
        switch (current.value) {
            .dynamic => {},
            .known => |literal| {
                if (literal.schema != current.schema) return error.TypeMismatch;
                var reader: data.wire.Reader = .{ .input = literal.bytes };
                if (work) |left| {
                    _ = try readValue(a, m.schemas, facts, literal.schema, &reader, left);
                } else _ = try data.admission.readValue(
                    a,
                    m.schemas,
                    facts,
                    literal.schema,
                    &reader,
                );
                try reader.finish();
            },
            .product => |v| {
                if (v.schema != current.schema or current.schema >= m.schemas.len or
                    m.schemas[@intCast(current.schema)] != .product) return error.TypeMismatch;
                if (!facts.exportable[@intCast(current.schema)]) return error.InvalidValue;
                const fields = m.schemas[@intCast(current.schema)].product;
                if (v.fields.len != fields.len) return error.TypeMismatch;
                try data.admission.spend(work, fields.len);
                var index = fields.len;
                while (index > 0) {
                    index -= 1;
                    try pending.append(a, .{ .schema = fields[index], .value = v.fields[index] });
                }
            },
        }
        if (pending.pop()) |next| current = next else remaining = false;
    }
}
pub fn field(
    a: std.mem.Allocator,
    m: ast.Module,
    facts: data.admission.SchemaFacts,
    value: Knowledge,
    index: p.Id,
    left: *u64,
) Error!Knowledge {
    return switch (value) {
        .dynamic => .dynamic,
        .product => |v| if (index < v.fields.len) v.fields[@intCast(index)] else .dynamic,
        .known => |v| blk: {
            const shape = m.schemas[@intCast(v.schema)];
            if (shape != .product or index >= shape.product.len) break :blk .dynamic;
            var reader: data.wire.Reader = .{ .input = v.bytes };
            for (shape.product, 0..) |schema, i| {
                try spend(left, 1);
                const bytes = try readValue(a, m.schemas, facts, schema, &reader, left);
                if (i == index) break :blk .{ .known = .{ .schema = schema, .bytes = bytes } };
            }
            unreachable;
        },
    };
}
fn scalar(a: std.mem.Allocator, m: ast.Module, schema: p.Id, bytes: [8]u8) Error!Knowledge {
    const n = data.scalar.width(m.schemas[@intCast(schema)]) orelse return .dynamic;
    return .{ .known = .{ .schema = schema, .bytes = try a.dupe(u8, bytes[0..n]) } };
}
fn number(a: std.mem.Allocator, m: ast.Module, schema: p.Id, value: u64) Error!Knowledge {
    return scalar(
        a,
        m,
        schema,
        data.scalar.fromInteger(m.schemas[@intCast(schema)], value) orelse return .dynamic,
    );
}
fn encoded(
    a: std.mem.Allocator,
    schema: p.Id,
    prefix: ?u64,
    fields: []const Knowledge,
    left: *u64,
) Error!Knowledge {
    try spend(left, fields.len);
    var measure: data.wire.Writer = .{};
    if (prefix) |v| try measure.natural(v);
    for (fields) |f| {
        if (f != .known) return .dynamic;
        try measure.put(f.known.bytes);
    }
    try spend(left, measure.position);
    const bytes = try a.alloc(u8, measure.position);
    var writer: data.wire.Writer = .{ .output = bytes };
    if (prefix) |v| try writer.natural(v);
    for (fields) |f| try writer.put(f.known.bytes);
    return .{ .known = .{ .schema = schema, .bytes = bytes } };
}
/// Partial fields may be propagated only after the enclosing expression has
/// evaluated. The caller separately tracks whether deleting evaluation is safe.
pub fn primitive(
    a: std.mem.Allocator,
    m: ast.Module,
    facts: data.admission.SchemaFacts,
    value: ast.Value,
    operands: []const Knowledge,
    left: *u64,
) Error!Knowledge {
    const op = value.expression.primitive;
    const schema = value.schema;
    // Knowledge reifies into ordinary source literals. Keep its entire
    // codomain exportable, including empty containers and a public arm of a
    // mixed sum. Their runtime expressions remain legal residual operations.
    if (!facts.exportable[@intCast(schema)]) return .dynamic;
    if (op.opcode == .product) {
        const full = try encoded(a, schema, null, operands, left);
        if (full == .known) return full;
        return .{ .product = .{ .schema = schema, .fields = try a.dupe(Knowledge, operands) } };
    }
    if (op.opcode == .field) return field(a, m, facts, operands[0], op.immediate, left);
    if (op.opcode == .move) return operands[0];
    try spend(left, operands.len);
    for (operands) |v| if (v != .known) return .dynamic;
    switch (op.opcode) {
        .product, .field, .move => unreachable,
        .variant => return encoded(a, schema, op.immediate, operands, left),
        .sequence => return encoded(
            a,
            schema,
            if (m.schemas[@intCast(schema)] == .array) null else operands.len,
            operands,
            left,
        ),
        .boolean_not => {
            var bytes = @as([8]u8, @splat(0));
            bytes[0] = 1 - operands[0].known.bytes[0];
            return scalar(a, m, schema, bytes);
        },
        .integer_add,
        .integer_sub,
        .integer_mul,
        .integer_div,
        .integer_rem,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .equal,
        .less,
        => return binaryPrimitive(a, m, value, operands),
        .integer_convert, .integer_bit_not, .enum_tag => {
            return unaryPrimitive(a, m, value, operands);
        },
        .variant_tag, .variant_payload => return variantPrimitive(a, m, value, operands),
        .sequence_length, .sequence_get => {
            return sequencePrimitive(a, m, facts, value, operands, left);
        },
        .select => return if (operands[0].known.bytes[0] == 1) operands[1] else operands[2],
        // Unknown primitive rules, allocation with observable identity, and
        // reads of mutable storage are always residual.
        else => return .dynamic,
    }
}
fn binaryPrimitive(
    a: std.mem.Allocator,
    m: ast.Module,
    value: ast.Value,
    operands: []const Knowledge,
) Error!Knowledge {
    const op = value.expression.primitive;
    const schema = value.schema;
    const shape = m.schemas[@intCast(operands[0].known.schema)];
    const lhs = data.scalar.fromBytes(shape, operands[0].known.bytes) catch return .dynamic;
    const right = data.scalar.fromBytes(
        shape,
        operands[1].known.bytes,
    ) catch return .dynamic;
    const result = data.scalar.binary(op.opcode, shape, lhs, right) catch return .dynamic;
    return if (result == .value) scalar(a, m, schema, result.value) else .dynamic;
}
fn unaryPrimitive(
    a: std.mem.Allocator,
    m: ast.Module,
    value: ast.Value,
    operands: []const Knowledge,
) Error!Knowledge {
    const op = value.expression.primitive;
    const schema = value.schema;
    const shape = m.schemas[@intCast(operands[0].known.schema)];
    const input = data.scalar.fromBytes(
        shape,
        operands[0].known.bytes,
    ) catch return .dynamic;
    const result = data.scalar.unary(
        op.opcode,
        shape,
        m.schemas[@intCast(schema)],
        input,
    ) catch return .dynamic;
    return if (result == .value) scalar(a, m, schema, result.value) else .dynamic;
}
fn variantPrimitive(
    a: std.mem.Allocator,
    m: ast.Module,
    value: ast.Value,
    operands: []const Knowledge,
) Error!Knowledge {
    const op = value.expression.primitive;
    const schema = value.schema;
    var reader: data.wire.Reader = .{ .input = operands[0].known.bytes };
    const tag = try reader.natural();
    if (op.opcode == .variant_tag) return number(a, m, schema, tag);
    if (tag != op.immediate) return .dynamic;
    return .{ .known = .{ .schema = schema, .bytes = reader.input[reader.position..] } };
}
fn sequencePrimitive(
    a: std.mem.Allocator,
    m: ast.Module,
    facts: data.admission.SchemaFacts,
    value: ast.Value,
    operands: []const Knowledge,
    left: *u64,
) Error!Knowledge {
    const op = value.expression.primitive;
    const schema = value.schema;
    const input = operands[0].known;
    const shape = m.schemas[@intCast(input.schema)];
    var reader: data.wire.Reader = .{ .input = input.bytes };
    const n = if (shape == .array) shape.array.length else try reader.natural();
    if (op.opcode == .sequence_length) return number(a, m, schema, n);
    const index = std.mem.readInt(u64, operands[1].known.bytes[0..8], .little);
    // sequence_get's result is option(element), including out of range.
    if (index >= n) return .{ .known = .{ .schema = schema, .bytes = &.{0} } };
    const element = switch (shape) {
        .array => |v| v.element,
        .vector => |v| v.element,
        .seq => |v| v,
        else => return .dynamic,
    };
    if (facts.minimum[@intCast(element)] == 0) return encoded(
        a,
        schema,
        1,
        &.{.{ .known = .{ .schema = element, .bytes = &.{} } }},
        left,
    );
    var i: u64 = 0;
    while (i <= index) : (i += 1) {
        try spend(left, 1);
        const bytes = try readValue(a, m.schemas, facts, element, &reader, left);
        if (i == index) return encoded(
            a,
            schema,
            1,
            &.{.{ .known = .{ .schema = element, .bytes = bytes } }},
            left,
        );
    }
    unreachable;
}

const Normalization = struct {
    value: Knowledge,
    fields: []Knowledge,
    index: usize = 0,
    any: bool = false,
    all: bool = true,
};
/// Canonical keys identify equal full values regardless of whether they arrived
/// as a record of known fields or as one canonical literal.
pub fn normalize(a: std.mem.Allocator, value: Knowledge, left: *u64) Error!Knowledge {
    var pending: std.ArrayList(Normalization) = .empty;
    defer pending.deinit(a);
    var current = value;
    var entering = true;
    while (entering or pending.items.len > 0) {
        if (entering) {
            try spend(left, 1);
            if (current == .product) {
                try spend(left, current.product.fields.len);
                const fields = try a.alloc(Knowledge, current.product.fields.len);
                if (fields.len == 0) {
                    current = try encoded(a, current.product.schema, null, fields, left);
                } else {
                    try pending.append(a, .{ .value = current, .fields = fields });
                    current = current.product.fields[0];
                    continue;
                }
            }
            entering = false;
        }
        if (pending.items.len == 0) break;
        const frame = &pending.items[pending.items.len - 1];
        frame.fields[frame.index] = current;
        frame.any = frame.any or current != .dynamic;
        frame.all = frame.all and current == .known;
        frame.index += 1;
        if (frame.index < frame.fields.len) {
            current = frame.value.product.fields[frame.index];
            entering = true;
            continue;
        }
        const completed = pending.pop().?;
        current = if (completed.all)
            try encoded(a, completed.value.product.schema, null, completed.fields, left)
        else if (!completed.any)
            .dynamic
        else
            .{ .product = .{
                .schema = completed.value.product.schema,
                .fields = completed.fields,
            } };
    }
    return current;
}
pub fn payload(value: Knowledge, schema: p.Id) Error!struct { tag: usize, value: Knowledge } {
    if (value != .known) return error.InvalidValue;
    var reader: data.wire.Reader = .{ .input = value.known.bytes };
    const tag = try reader.count();
    return .{
        .tag = tag,
        .value = .{ .known = .{ .schema = schema, .bytes = reader.input[reader.position..] } },
    };
}

fn deepStaticKnowledge(
    a: std.mem.Allocator,
    root: Knowledge,
    module: ast.Module,
    facts: data.admission.SchemaFacts,
) !void {
    try std.testing.expect(try equal(a, root, root));
    try validate(a, module, facts, root.product.schema, root);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const copied = try own(arena.allocator(), root);
    try std.testing.expect(try equal(a, root, copied));
    const copies = try ownMany(arena.allocator(), &.{ root, .dynamic });
    try std.testing.expect(try equal(a, root, copies[0]));
    try std.testing.expect(copies[1] == .dynamic);
    var leaf = copied;
    var original = root;
    for (0..4096) |_| {
        leaf = leaf.product.fields[0];
        original = original.product.fields[0];
    }
    try std.testing.expectEqualSlices(u8, &.{1}, leaf.known.bytes);
    try std.testing.expect(leaf.known.bytes.ptr != original.known.bytes.ptr);
    var left: u64 = 100_000;
    const normalized = try normalize(arena.allocator(), root, &left);
    try std.testing.expect(try equal(a, root, normalized));
    try std.testing.expectEqual(@as(u64, 100_000 - 8193), left);
}

test "static knowledge traverses deep partial products and allocation failures" {
    const a = std.testing.allocator;
    const fields = try a.alloc([2]Knowledge, 4096);
    defer a.free(fields);
    const shapes = try a.alloc([2]p.Id, fields.len);
    defer a.free(shapes);
    const schemas = try a.alloc(p.Schema, fields.len + 1);
    defer a.free(schemas);
    const minimum = try a.alloc(u64, schemas.len);
    defer a.free(minimum);
    const exportable = try a.alloc(bool, schemas.len);
    defer a.free(exportable);
    schemas[0] = .u8;
    minimum[0] = 1;
    @memset(exportable, true);
    var root: Knowledge = .{ .known = .{ .schema = 0, .bytes = &.{1} } };
    for (fields, shapes, 0..) |*pair, *shape, index| {
        pair.* = .{ root, .dynamic };
        shape.* = .{ @intCast(index), 0 };
        schemas[index + 1] = .{ .product = shape };
        minimum[index + 1] = index + 2;
        root = .{ .product = .{ .schema = @intCast(index + 1), .fields = pair } };
    }
    const module: ast.Module = .{
        .entry = 0,
        .failure = 0,
        .schemas = schemas,
        .constants = &.{},
        .effects = &.{},
        .handlers = &.{},
        .region_count = 0,
        .variables = &.{},
        .values = &.{},
        .terms = &.{},
        .functions = &.{},
    };
    const facts: data.admission.SchemaFacts = .{ .minimum = minimum, .exportable = exportable };
    try deepStaticKnowledge(a, root, module, facts);
    try std.testing.checkAllAllocationFailures(a, deepStaticKnowledge, .{ root, module, facts });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var left: u64 = 100_000;
    const normalized = try normalize(arena.allocator(), root, &left);
    fields[0][0] = .dynamic;
    try std.testing.expect(!try equal(a, root, normalized));
}
