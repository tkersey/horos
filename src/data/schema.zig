// Copyright (c) 2026 Boundary contributors. MIT license.
//! Self-contained structural schemas for residual contracts.
const std = @import("std");
pub const native = @import("native_shape.zig");
const p = @import("program.zig");
const wire = @import("wire.zig");
const record = @import("record.zig");
const admission = @import("admission.zig");
pub const Error = admission.Error;
pub const Descriptor = struct { root: p.Id = 0, types: []const p.Schema };
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: Descriptor,
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn children(schema: p.Schema, single: *[1]p.Id) []const p.Id {
    return switch (schema) {
        .product, .sum => |fields| fields,
        .seq => |element| blk: {
            single[0] = element;
            break :blk single;
        },
        .vector => |vector| blk: {
            single[0] = vector.element;
            break :blk single;
        },
        .array => |array| blk: {
            single[0] = array.element;
            break :blk single;
        },
        else => &.{},
    };
}

fn equivalent(a: p.Schema, b: p.Schema, classes: []const usize) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    if (a == .vector and a.vector.maximum != b.vector.maximum) return false;
    if (a == .array and a.array.length != b.array.length) return false;
    if (a == .bounded_bytes and a.bounded_bytes != b.bounded_bytes) return false;
    if (a == .bounded_text and a.bounded_text != b.bounded_text) return false;
    if (a == .enumeration and !std.mem.eql(u32, a.enumeration, b.enumeration)) return false;
    if (a == .internal) return std.meta.eql(a.internal, b.internal);
    var a_single: [1]p.Id = undefined;
    var b_single: [1]p.Id = undefined;
    const left = children(a, &a_single);
    const right = children(b, &b_single);
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (classes[@intCast(x)] != classes[@intCast(y)]) return false;
    return true;
}

/// Bisimulation refinement collapses equal immutable recursive type definitions.
pub fn canonicalize(allocator: std.mem.Allocator, types: []const p.Schema, root: p.Id) Error!Owned {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();
    const facts = try admission.schemas(storage, types);
    _ = try admission.schemaAt(types, root);
    if (!facts.exportable[@intCast(root)]) return error.InvalidSchema;
    var classes = try storage.alloc(usize, types.len);
    var next = try storage.alloc(usize, types.len);
    @memset(classes, 0);
    var changed = true;
    while (changed) {
        for (types, 0..) |schema, index| {
            next[index] = index;
            for (types[0..index], 0..) |prior, candidate| {
                if (equivalent(schema, prior, classes)) {
                    next[index] = next[candidate];
                    break;
                }
            }
        }
        changed = !std.mem.eql(usize, classes, next);
        if (changed) std.mem.swap([]usize, &classes, &next);
    }
    const map = try storage.alloc(p.Id, types.len);
    @memset(map, std.math.maxInt(p.Id));
    var order: std.ArrayList(usize) = .empty;
    var pending: std.ArrayList(usize) = .empty;
    try pending.append(storage, classes[@intCast(root)]);
    while (pending.pop()) |representative| {
        if (map[representative] != std.math.maxInt(p.Id)) continue;
        map[representative] = order.items.len;
        try order.append(storage, representative);
        var single: [1]p.Id = undefined;
        const references = children(types[representative], &single);
        var index = references.len;
        while (index != 0) {
            index -= 1;
            try pending.append(storage, classes[@intCast(references[index])]);
        }
    }
    const result = try storage.alloc(p.Schema, order.items.len);
    for (result, order.items) |*target, source| {
        target.* = types[source];
        switch (target.*) {
            .enumeration => |tags| target.* = .{ .enumeration = try storage.dupe(u32, tags) },
            .product, .sum => |references| {
                const mapped = try storage.alloc(p.Id, references.len);
                for (mapped, references) |*id, old| id.* = map[classes[@intCast(old)]];
                if (target.* == .product) target.* = .{ .product = mapped } else target.* = .{ .sum = mapped };
            },
            .seq => |old| target.* = .{ .seq = map[classes[@intCast(old)]] },
            .vector => |vector| target.* = .{ .vector = .{
                .element = map[classes[@intCast(vector.element)]],
                .maximum = vector.maximum,
            } },
            .array => |array| target.* = .{ .array = .{
                .element = map[classes[@intCast(array.element)]],
                .length = array.length,
            } },
            else => {},
        }
    }
    return .{ .arena = arena, .descriptor = .{ .types = result } };
}

pub fn encode(
    allocator: std.mem.Allocator,
    types: []const p.Schema,
    root: p.Id,
    output: []u8,
) Error![]const u8 {
    var canonical = try canonicalize(allocator, types, root);
    defer canonical.deinit();
    var measure: wire.Writer = .{};
    try record.write(Descriptor, canonical.descriptor, &measure);
    if (output.len < measure.position) return error.Capacity;
    var writer: wire.Writer = .{ .output = output };
    try record.write(Descriptor, canonical.descriptor, &writer);
    return output[0..writer.position];
}

pub fn encodeOwned(allocator: std.mem.Allocator, types: []const p.Schema, root: p.Id) Error![]u8 {
    var canonical = try canonicalize(allocator, types, root);
    defer canonical.deinit();
    var measure: wire.Writer = .{};
    try record.write(Descriptor, canonical.descriptor, &measure);
    const output = try allocator.alloc(u8, measure.position);
    errdefer allocator.free(output);
    var writer: wire.Writer = .{ .output = output };
    try record.write(Descriptor, canonical.descriptor, &writer);
    return output;
}

pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error!Owned {
    return decodeLimited(allocator, input, std.math.maxInt(usize));
}

pub fn decodeLimited(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_decoded_bytes: usize,
) Error!Owned {
    if (input.len > max_decoded_bytes) return error.Capacity;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var reader: wire.Reader = .{ .input = input };
    var remaining = max_decoded_bytes - input.len;
    const decoded = try record.readBounded(Descriptor, &reader, scratch.allocator(), &remaining);
    try reader.finish();
    var canonical = try canonicalize(allocator, decoded.types, decoded.root);
    errdefer canonical.deinit();
    var comparison: wire.Writer = .{ .expected = input };
    try record.write(Descriptor, canonical.descriptor, &comparison);
    if (comparison.position != input.len) return error.NonCanonical;
    return canonical;
}

/// Validate an encoded value while the surrounding builder may contain unrelated
/// unfinished declarations. Only the reachable, exportable schema graph is read.
pub fn validateReachableValue(
    allocator: std.mem.Allocator,
    types: []const p.Schema,
    root: p.Id,
    value: []const u8,
) Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const storage = scratch.allocator();
    const missing = std.math.maxInt(p.Id);
    const map = try storage.alloc(p.Id, types.len);
    @memset(map, missing);
    var order: std.ArrayList(p.Id) = .empty;
    _ = try admission.schemaAt(types, root);
    map[@intCast(root)] = 0;
    try order.append(storage, root);
    var cursor: usize = 0;
    while (cursor < order.items.len) : (cursor += 1) {
        const schema = types[@intCast(order.items[cursor])];
        if (schema == .internal) return error.InvalidSchema;
        var single: [1]p.Id = undefined;
        for (children(schema, &single)) |id| {
            _ = try admission.schemaAt(types, id);
            if (map[@intCast(id)] != missing) continue;
            map[@intCast(id)] = order.items.len;
            try order.append(storage, id);
        }
    }
    const reachable = try storage.alloc(p.Schema, order.items.len);
    for (reachable, order.items) |*target, id| {
        target.* = types[@intCast(id)];
        switch (target.*) {
            .product, .sum => |refs| {
                const remapped = try storage.alloc(p.Id, refs.len);
                for (remapped, refs) |*out, old| out.* = map[@intCast(old)];
                target.* = if (target.* == .product) .{ .product = remapped } else .{ .sum = remapped };
            },
            .seq => |old| target.* = .{ .seq = map[@intCast(old)] },
            .vector => |v| target.* = .{ .vector = .{
                .element = map[@intCast(v.element)],
                .maximum = v.maximum,
            } },
            .array => |v| target.* = .{ .array = .{
                .element = map[@intCast(v.element)],
                .length = v.length,
            } },
            else => {},
        }
    }
    const facts = try admission.schemas(storage, reachable);
    try admission.value(storage, reachable, facts, .{ .schema = 0, .bytes = value });
}

pub fn validateValue(
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    value: []const u8,
) Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const facts = try admission.schemas(scratch.allocator(), descriptor.types);
    try admission.value(
        scratch.allocator(),
        descriptor.types,
        facts,
        .{ .schema = descriptor.root, .bytes = value },
    );
}

test "equal definitions share one canonical schema independent of original IDs" {
    const first: []const p.Schema = &.{ .{ .product = &.{ 1, 2 } }, .u64, .u64 };
    const second: []const p.Schema = &.{ .u64, .{ .product = &.{ 0, 0 } } };
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const left = try encode(std.testing.allocator, first, 0, &a);
    const right = try encode(std.testing.allocator, second, 1, &b);
    try std.testing.expectEqualSlices(u8, left, right);
    var decoded = try decode(std.testing.allocator, left);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 2), decoded.descriptor.types.len);
}

test "recursive schema descriptors reject internal handles and noncanonical bytes" {
    const types: []const p.Schema = &.{ .unit, .{ .sum = &.{ 0, 1 } } };
    var output: [128]u8 = undefined;
    const encoded = try encode(std.testing.allocator, types, 1, &output);
    var parsed = try decode(std.testing.allocator, encoded);
    defer parsed.deinit();
    try validateValue(std.testing.allocator, parsed.descriptor, &.{ 1, 1, 0 });
    const internal: []const p.Schema = &.{.{ .internal = .{ .capability = 0 } }};
    try std.testing.expectError(
        error.InvalidSchema,
        encode(std.testing.allocator, internal, 0, &output),
    );
}

test "schema canonicalization preserves array lengths and text or byte bounds" {
    const types: []const p.Schema = &.{
        .{ .product = &.{ 1, 2, 3, 4, 5, 6 } },
        .{ .array = .{ .element = 7, .length = 1 } },
        .{ .array = .{ .element = 7, .length = 2 } },
        .{ .bounded_bytes = 1 },
        .{ .bounded_bytes = 2 },
        .{ .bounded_text = 1 },
        .{ .bounded_text = 2 },
        .u8,
    };
    const encoded = try encodeOwned(std.testing.allocator, types, 0);
    defer std.testing.allocator.free(encoded);
    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 8), decoded.descriptor.types.len);
    const again = try encodeOwned(std.testing.allocator, decoded.descriptor.types, 0);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualSlices(u8, encoded, again);
}
