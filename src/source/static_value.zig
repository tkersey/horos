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
pub const Knowledge = union(enum) {
    dynamic,
    known: p.Literal,
    product: struct { schema: p.Id, fields: []const Knowledge },
};
pub fn equal(a: Knowledge, b: Knowledge) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .dynamic => true,
        .known => |v| v.schema == b.known.schema and std.mem.eql(u8, v.bytes, b.known.bytes),
        .product => |v| blk: {
            if (v.schema != b.product.schema or v.fields.len != b.product.fields.len) break :blk false;
            for (v.fields, b.product.fields) |x, y| if (!equal(x, y)) break :blk false;
            break :blk true;
        },
    };
}
pub fn validate(a: std.mem.Allocator, m: ast.Module, facts: data.admission.SchemaFacts, schema: p.Id, k: Knowledge) Error!void {
    switch (k) {
        .dynamic => {},
        .known => |literal| {
            if (literal.schema != schema) return error.TypeMismatch;
            try data.admission.value(a, m.schemas, facts, literal);
        },
        .product => |v| {
            if (v.schema != schema or schema >= m.schemas.len or m.schemas[@intCast(schema)] != .product) return error.TypeMismatch;
            if (!facts.exportable[@intCast(schema)]) return error.InvalidValue;
            const fields = m.schemas[@intCast(schema)].product;
            if (v.fields.len != fields.len) return error.TypeMismatch;
            for (fields, v.fields) |s, f| try validate(a, m, facts, s, f);
        },
    }
}
pub fn field(a: std.mem.Allocator, m: ast.Module, facts: data.admission.SchemaFacts, value: Knowledge, index: p.Id, left: *u64) Error!Knowledge {
    return switch (value) {
        .dynamic => .dynamic,
        .product => |v| if (index < v.fields.len) v.fields[@intCast(index)] else .dynamic,
        .known => |v| blk: {
            const shape = m.schemas[@intCast(v.schema)];
            if (shape != .product or index >= shape.product.len) break :blk .dynamic;
            var reader: data.wire.Reader = .{ .input = v.bytes };
            for (shape.product, 0..) |schema, i| {
                try spend(left, 1);
                const bytes = try data.admission.readValue(a, m.schemas, facts, schema, &reader);
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
    return scalar(a, m, schema, data.scalar.fromInteger(m.schemas[@intCast(schema)], value) orelse return .dynamic);
}
fn encoded(a: std.mem.Allocator, schema: p.Id, prefix: ?u64, fields: []const Knowledge, left: *u64) Error!Knowledge {
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
pub fn primitive(a: std.mem.Allocator, m: ast.Module, facts: data.admission.SchemaFacts, value: ast.Value, operands: []const Knowledge, left: *u64) Error!Knowledge {
    const op = value.expression.primitive;
    const schema = value.schema;
    if (op.opcode == .product) {
        if (!facts.exportable[@intCast(schema)]) return .dynamic;
        const full = try encoded(a, schema, null, operands, left);
        if (full == .known) return full;
        return .{ .product = .{ .schema = schema, .fields = try a.dupe(Knowledge, operands) } };
    }
    if (op.opcode == .field) return field(a, m, facts, operands[0], op.immediate, left);
    if (op.opcode == .move) return operands[0];
    for (operands) |v| if (v != .known) return .dynamic;
    switch (op.opcode) {
        .product, .field, .move => unreachable,
        .variant => return encoded(a, schema, op.immediate, operands, left),
        .sequence => return encoded(a, schema, if (m.schemas[@intCast(schema)] == .array) null else operands.len, operands, left),
        .boolean_not => {
            var bytes = @as([8]u8, @splat(0));
            bytes[0] = 1 - operands[0].known.bytes[0];
            return scalar(a, m, schema, bytes);
        },
        .integer_add, .integer_sub, .integer_mul, .integer_div, .integer_rem, .integer_bit_and, .integer_bit_or, .integer_bit_xor, .equal, .less => {
            const shape = m.schemas[@intCast(operands[0].known.schema)];
            const lhs = data.scalar.fromBytes(shape, operands[0].known.bytes) catch return .dynamic;
            const right = data.scalar.fromBytes(shape, operands[1].known.bytes) catch return .dynamic;
            const result = data.scalar.binary(op.opcode, shape, lhs, right) catch return .dynamic;
            return if (result == .value) scalar(a, m, schema, result.value) else .dynamic;
        },
        .integer_convert, .integer_bit_not, .enum_tag => {
            const shape = m.schemas[@intCast(operands[0].known.schema)];
            const input = data.scalar.fromBytes(shape, operands[0].known.bytes) catch return .dynamic;
            const result = data.scalar.unary(op.opcode, shape, m.schemas[@intCast(schema)], input) catch return .dynamic;
            return if (result == .value) scalar(a, m, schema, result.value) else .dynamic;
        },
        .variant_tag, .variant_payload => {
            var reader: data.wire.Reader = .{ .input = operands[0].known.bytes };
            const tag = try reader.natural();
            if (op.opcode == .variant_tag) return number(a, m, schema, tag);
            if (tag != op.immediate) return .dynamic;
            return .{ .known = .{ .schema = schema, .bytes = reader.input[reader.position..] } };
        },
        .sequence_length, .sequence_get => {
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
            if (facts.minimum[@intCast(element)] == 0) return encoded(a, schema, 1, &.{.{ .known = .{ .schema = element, .bytes = &.{} } }}, left);
            var i: u64 = 0;
            while (i <= index) : (i += 1) {
                try spend(left, 1);
                const bytes = try data.admission.readValue(a, m.schemas, facts, element, &reader);
                if (i == index) return encoded(a, schema, 1, &.{.{ .known = .{ .schema = element, .bytes = bytes } }}, left);
            }
            unreachable;
        },
        .select => return if (operands[0].known.bytes[0] == 1) operands[1] else operands[2],
        // Unknown primitive rules, allocation with observable identity, and
        // reads of mutable storage are always residual.
        else => return .dynamic,
    }
}

/// Canonical keys identify equal full values regardless of whether they arrived
/// as a record of known fields or as one canonical literal.
pub fn normalize(a: std.mem.Allocator, value: Knowledge, left: *u64) Error!Knowledge {
    try spend(left, 1);
    if (value != .product) return value;
    const fields = try a.alloc(Knowledge, value.product.fields.len);
    var any = false;
    var all = true;
    for (value.product.fields, fields) |before, *after| {
        after.* = try normalize(a, before, left);
        any = any or after.* != .dynamic;
        all = all and after.* == .known;
    }
    if (all) return encoded(a, value.product.schema, null, fields, left);
    if (!any) return .dynamic;
    return .{ .product = .{ .schema = value.product.schema, .fields = fields } };
}
pub fn payload(value: Knowledge, schema: p.Id) Error!struct { tag: usize, value: Knowledge } {
    if (value != .known) return error.InvalidValue;
    var reader: data.wire.Reader = .{ .input = value.known.bytes };
    const tag = try reader.count();
    return .{ .tag = tag, .value = .{ .known = .{ .schema = schema, .bytes = reader.input[reader.position..] } } };
}
