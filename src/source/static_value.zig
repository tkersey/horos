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
pub const ReadCache = struct {
    const Key = struct { schema: p.Id, pointer: usize, length: usize, start: usize };
    module: ast.Module,
    facts: data.admission.SchemaFacts,
    entries: std.AutoArrayHashMapUnmanaged(Key, usize) = .empty,

    pub fn deinit(self: *ReadCache, a: std.mem.Allocator) void {
        self.entries.deinit(a);
        self.* = undefined;
    }
    fn read(
        self: *ReadCache,
        a: std.mem.Allocator,
        schema: p.Id,
        reader: *data.wire.Reader,
        left: *u64,
    ) Error![]const u8 {
        try spend(left, 1);
        const key: Key = .{
            .schema = schema,
            .pointer = @intFromPtr(reader.input.ptr),
            .length = reader.input.len,
            .start = reader.position,
        };
        if (self.entries.get(key)) |end| {
            reader.position = end;
            return reader.input[key.start..end];
        }
        try spend(left, 1);
        var measured = reader.*;
        const bytes = try readValue(a, self.module.schemas, self.facts, schema, &measured, left);
        const count = std.math.add(usize, self.entries.count(), 1) catch
            return error.SpecializationLimit;
        if (count > self.entries.capacity()) {
            try spend(left, count);
            try self.entries.ensureTotalCapacity(a, count);
        }
        self.entries.putAssumeCapacityNoClobber(key, measured.position);
        reader.* = measured;
        return bytes;
    }
    pub fn field(
        self: *ReadCache,
        a: std.mem.Allocator,
        value: Knowledge,
        index: p.Id,
        left: *u64,
    ) Error!Knowledge {
        return fieldWithCache(a, self.module, self.facts, value, index, left, self);
    }
    pub fn primitive(
        self: *ReadCache,
        a: std.mem.Allocator,
        value: ast.Value,
        operands: []const Knowledge,
        left: *u64,
    ) Error!Knowledge {
        return primitiveWithCache(a, self.module, self.facts, value, operands, left, self);
    }
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
pub fn literalEqualWithWork(lhs: p.Literal, rhs: p.Literal, work: ?*u64) Error!bool {
    if (lhs.schema != rhs.schema or lhs.bytes.len != rhs.bytes.len) return false;
    try data.admission.spend(work, lhs.bytes.len);
    return std.mem.eql(u8, lhs.bytes, rhs.bytes);
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
                if (!try literalEqualWithWork(left, pair.rhs.known, work)) return false;
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
    return fieldWithCache(a, m, facts, value, index, left, null);
}
fn fieldWithCache(
    a: std.mem.Allocator,
    m: ast.Module,
    facts: data.admission.SchemaFacts,
    value: Knowledge,
    index: p.Id,
    left: *u64,
    cache: ?*ReadCache,
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
                const bytes = if (cache) |memo|
                    try memo.read(a, schema, &reader, left)
                else
                    try readValue(a, m.schemas, facts, schema, &reader, left);
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
    return primitiveWithCache(a, m, facts, value, operands, left, null);
}
fn primitiveWithCache(
    a: std.mem.Allocator,
    m: ast.Module,
    facts: data.admission.SchemaFacts,
    value: ast.Value,
    operands: []const Knowledge,
    left: *u64,
    cache: ?*ReadCache,
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
    if (op.opcode == .field)
        return fieldWithCache(a, m, facts, operands[0], op.immediate, left, cache);
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
            return sequencePrimitive(a, m, facts, value, operands, left, cache);
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
    cache: ?*ReadCache,
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
        const bytes = if (cache) |memo|
            try memo.read(a, element, &reader, left)
        else
            try readValue(a, m.schemas, facts, element, &reader, left);
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
    try std.testing.expectEqual(@as(u64, 100_000 - 16_385), left);
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
    left = 16_384;
    try std.testing.expectError(
        error.SpecializationLimit,
        normalize(arena.allocator(), root, &left),
    );
    fields[0][0] = .dynamic;
    try std.testing.expect(!try equal(a, root, normalized));
}

const read_cache_module: ast.Module = .{
    .entry = 0,
    .failure = 0,
    .schemas = &.{
        .unit,
        .u8,
        .u16,
        .{ .seq = 1 },
        .{ .product = &.{ 1, 0, 3 } },
        .{ .product = &.{} },
        .{ .sum = &.{ 0, 1 } },
        .boolean,
        .u64,
        .{ .product = &.{ 4, 5, 1 } },
    },
    .constants = &.{},
    .effects = &.{},
    .handlers = &.{},
    .region_count = 0,
    .variables = &.{},
    .values = &.{},
    .terms = &.{},
    .functions = &.{},
};
const read_cache_facts: data.admission.SchemaFacts = .{
    .minimum = &.{ 0, 1, 2, 1, 2, 0, 1, 1, 8, 3 },
    .exportable = &.{ true, true, true, true, true, true, true, true, true, true },
};

fn readCacheDifferential(a: std.mem.Allocator) !void {
    var cache: ReadCache = .{ .module = read_cache_module, .facts = read_cache_facts };
    defer cache.deinit(a);
    const cases = [_]Knowledge{
        .{ .known = .{ .schema = 9, .bytes = &.{ 7, 2, 8, 9, 10 } } },
        .{ .known = .{ .schema = 5, .bytes = &.{} } },
        .dynamic,
        .{ .product = .{ .schema = 9, .fields = &.{
            .{ .known = .{ .schema = 4, .bytes = &.{ 7, 2, 8, 9 } } },
            .{ .known = .{ .schema = 5, .bytes = &.{} } },
            .dynamic,
        } } },
    };
    var left: u64 = 100_000;
    for (0..2) |_| for (cases) |value| for (0..4) |index| {
        const expected = try field(a, cache.module, cache.facts, value, index, &left);
        const actual = try cache.field(a, value, index, &left);
        try std.testing.expect(try equal(a, expected, actual));
        if (actual == .known) try std.testing.expect(
            actual.known.bytes.ptr == expected.known.bytes.ptr,
        );
    };
    const bytes: [32]u8 = @splat(1);
    for (0..bytes.len) |start| {
        var reader: data.wire.Reader = .{ .input = &bytes, .position = start };
        const actual = try cache.read(a, 1, &reader, &left);
        try std.testing.expectEqualSlices(u8, bytes[start .. start + 1], actual);
    }
}

test "static read cache matches uncached fields and releases partial growth" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, readCacheDifferential, .{});
}

test "static read cache distinguishes exact keys and fresh validation ownership" {
    const a = std.testing.allocator;
    var cache: ReadCache = .{ .module = read_cache_module, .facts = read_cache_facts };
    defer cache.deinit(a);
    var first = [_]u8{ 1, 2, 3, 4 };
    var second = first;
    var left: u64 = 1000;
    const readers = [_]data.wire.Reader{
        .{ .input = &first },                .{ .input = &first },  .{ .input = first[0..2] },
        .{ .input = &first, .position = 1 }, .{ .input = &second }, .{ .input = &first },
    };
    for (readers, [_]p.Id{ 1, 2, 1, 1, 1, 0 }, 0..) |input, schema, index| {
        var reader = input;
        _ = try cache.read(a, schema, &reader, &left);
        try std.testing.expectEqual(index + 1, cache.entries.count());
    }
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    for (readers, [_]p.Id{ 1, 2, 1, 1, 1, 0 }) |input, schema| {
        var reader = input;
        left = 1;
        const result = try cache.read(failing.allocator(), schema, &reader, &left);
        try std.testing.expect(result.ptr == input.input[input.position..].ptr);
        try std.testing.expectEqual(input.position + result.len, reader.position);
        try std.testing.expectEqual(@as(u64, 0), left);
    }
    try std.testing.expect(!failing.has_induced_failure);
    var checked: ReadCache = .{ .module = cache.module, .facts = cache.facts };
    defer checked.deinit(a);
    var reader = readers[0];
    left = 1;
    try std.testing.expectError(error.SpecializationLimit, checked.read(a, 1, &reader, &left));
    try std.testing.expectEqual(@as(usize, 0), checked.entries.count());
}

test "static read cache does not publish failed decoding growth or allocation" {
    const a = std.testing.allocator;
    var cache: ReadCache = .{ .module = read_cache_module, .facts = read_cache_facts };
    defer cache.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    var reader: data.wire.Reader = .{ .input = &.{} };
    var left: u64 = 4;
    try std.testing.expectError(
        error.SpecializationLimit,
        cache.read(failing.allocator(), 0, &reader, &left),
    );
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    failing.fail_index = failing.alloc_index + 1;
    left = 100;
    try std.testing.expectError(
        error.OutOfMemory,
        cache.read(failing.allocator(), 0, &reader, &left),
    );
    try std.testing.expectEqual(@as(usize, 0), cache.entries.count());
    try std.testing.expectEqual(@as(usize, 0), reader.position);
    failing.fail_index = std.math.maxInt(usize);
    _ = try cache.read(failing.allocator(), 0, &reader, &left);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
    const invalid: data.wire.Reader = .{ .input = &.{2} };
    for (0..2) |_| {
        var actual = invalid;
        left = 100;
        try std.testing.expectError(error.InvalidValue, cache.read(a, 7, &actual, &left));
        try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
        try std.testing.expectEqual(@as(usize, 0), actual.position);
        actual = invalid;
        try std.testing.expectError(
            error.InvalidValue,
            readValue(a, cache.module.schemas, cache.facts, 7, &actual, &left),
        );
    }
}

test "static read cache preserves sequence projections and residual partial values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cache: ReadCache = .{ .module = read_cache_module, .facts = read_cache_facts };
    defer cache.deinit(a);
    const op: ast.Value = .{ .schema = 6, .expression = .{ .primitive = .{
        .opcode = .sequence_get,
        .operands = &.{ 0, 1 },
    } } };
    const operands = [_]Knowledge{
        .{ .known = .{ .schema = 3, .bytes = &.{ 2, 8, 9 } } },
        .{ .known = .{ .schema = 8, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } } },
    };
    var left: u64 = 1000;
    const expected = try primitive(a, cache.module, cache.facts, op, &operands, &left);
    for (0..2) |_| try std.testing.expect(try equal(
        a,
        expected,
        try cache.primitive(a, op, &operands, &left),
    ));
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    left = 0;
    const partial: Knowledge = .{ .product = .{ .schema = 4, .fields = &.{
        .dynamic, .{ .known = .{ .schema = 0, .bytes = &.{} } }, .dynamic,
    } } };
    try std.testing.expect(try equal(a, partial.product.fields[1], try cache.field(
        failing.allocator(),
        partial,
        1,
        &left,
    )));
    try std.testing.expect(try cache.field(failing.allocator(), .dynamic, 0, &left) == .dynamic);
    try std.testing.expect(!failing.has_induced_failure);
}
