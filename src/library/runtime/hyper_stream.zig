const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const cache_key = @import("../../authoring/cache_key.zig");

pub const Stream = opaque {
    pub fn node(self: *const Stream) *const a.Schema {
        return data(self).node;
    }
    pub fn cell(self: *const Stream) *const a.Schema {
        return data(self).cell;
    }
    pub fn element(self: *const Stream) *const a.Schema {
        return data(self).element;
    }
    pub fn spine(self: *const Stream) *const a.Schema {
        return data(self).spine;
    }
};

const StreamData = struct {
    node: *const a.Schema,
    cell: *const a.Schema,
    element: *const a.Schema,
    spine: *const a.Schema,
};

fn data(value: *const Stream) *const StreamData {
    return @ptrCast(@alignCast(value));
}

const Key = struct { element: *const a.Schema, captures: []const *const a.Schema };
const KeyOps = cache_key.KeyOps(Key, cache_key.DefaultPolicy);
const Cache = struct {
    entries: std.ArrayList(struct { key: Key, value: *const Stream }) = .empty,
};

pub fn create(
    c: *a.Context,
    value: *const a.Schema,
    captures: []const *const a.Schema,
) a.Error!*const Stream {
    _ = try a.interop.schemaId(c, value);
    for (captures) |schema| _ = try a.interop.schemaId(c, schema);
    const cache = try a.interop.libraryStorage(c, Cache);
    const key: Key = .{ .element = value, .captures = captures };
    for (cache.entries.items) |entry| if (KeyOps.eql(key, entry.key)) return entry.value;
    const node = try c.declareSchema(.alternatives);
    const element = try c.declareSchema(.callable);
    const spine = try c.declareSchema(.callable);
    const cell = try c.record(&.{
        .{ .name = "head", .schema = element.schema() },
        .{ .name = "tail", .schema = spine.schema() },
    });
    const allocator = a.interop.builder(c).allocator();
    const count = std.math.add(usize, captures.len, 5) catch return error.Capacity;
    const bound = try allocator.alloc(*const a.Schema, count);
    @memcpy(bound[0..captures.len], captures);
    @memcpy(bound[captures.len..], &[_]*const a.Schema{
        value, node.schema(), cell, element.schema(), spine.schema(),
    });
    try c.defineAlternatives(node, &.{
        .{ .name = "none", .schema = try c.scalar(void) },
        .{ .name = "some", .schema = cell },
    });
    try c.defineCallable(element, &.{}, value, &.{}, .{ .use = .reusable, .captures = bound });
    try c.defineCallable(spine, &.{}, node.schema(), &.{}, .{
        .use = .reusable,
        .captures = bound,
    });
    const stored = try a.interop.namedStorage(c, StreamData, .{
        .node = node.schema(),
        .cell = cell,
        .element = element.schema(),
        .spine = spine.schema(),
    });
    const result: *const Stream = @ptrCast(stored);
    try cache.entries.append(allocator, .{
        .key = try KeyOps.snapshot(allocator, key),
        .value = result,
    });
    return result;
}
