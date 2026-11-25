const std = @import("std");
const p = @import("program.zig");
const wire = @import("wire.zig");
const admission = @import("admission.zig");
const Error = admission.Error;
const SchemaFacts = admission.SchemaFacts;
const schemaAt = admission.schemaAt;

pub fn readValue(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    facts: SchemaFacts,
    schema: p.Id,
    reader: *wire.Reader,
    remaining: ?*u64,
) Error![]const u8 {
    return readValueMetered(allocator, catalog, facts, schema, reader, remaining);
}

fn valueWork(remaining: ?*u64, count: usize) Error!void {
    const left = remaining orelse return;
    if (count > left.*) return error.ValueWorkLimit;
    left.* -= @intCast(count);
}

fn readValueMetered(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    facts: SchemaFacts,
    schema: p.Id,
    reader: *wire.Reader,
    remaining: ?*u64,
) Error![]const u8 {
    _ = try schemaAt(catalog, schema);
    if (!facts.exportable[@intCast(schema)]) return error.InvalidValue;
    if (reader.position > reader.input.len) return error.Truncated;
    const start = reader.position;
    var pending: std.ArrayList(ValueTask) = .empty;
    defer pending.deinit(allocator);
    try valueWork(remaining, 1);
    try pending.append(allocator, .{ .schema = schema, .count = 1 });
    while (pending.pop()) |task| {
        try valueWork(remaining, 1);
        const index: usize = @intCast(task.schema);
        const minimum = facts.minimum[index];
        if (task.count == 0 or minimum == 0) continue;
        if (task.count > (reader.input.len - reader.position) / minimum) return error.InvalidValue;
        if (task.count > 1) {
            try valueWork(remaining, 1);
            try pending.append(allocator, .{ .schema = task.schema, .count = task.count - 1 });
        }
        try readValueTask(allocator, catalog[index], minimum, reader, &pending, remaining);
    }
    return reader.input[start..reader.position];
}

const ValueTask = struct { schema: p.Id, count: u64 };

fn readValueTask(
    allocator: std.mem.Allocator,
    shape: p.Schema,
    minimum: u64,
    reader: *wire.Reader,
    pending: *std.ArrayList(ValueTask),
    remaining: ?*u64,
) Error!void {
    switch (shape) {
        .unit => {},
        .boolean => {
            if (try reader.byte() > 1) return error.InvalidValue;
        },
        .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64 => {
            _ = try reader.take(@intCast(minimum));
        },
        .enumeration => |tags| {
            const bytes = try reader.take(4);
            const tag = std.mem.readInt(u32, bytes[0..4], .little);
            try valueWork(remaining, tags.len);
            if (std.mem.indexOfScalar(u32, tags, tag) == null) return error.InvalidValue;
        },
        .bytes => {
            _ = try reader.bytes();
        },
        .text => {
            _ = try readValueText(reader, remaining);
        },
        .bounded_bytes => |maximum| {
            if ((try reader.bytes()).len > maximum) return error.InvalidValue;
        },
        .bounded_text => |maximum| {
            if ((try readValueText(reader, remaining)).len > maximum) return error.InvalidValue;
        },
        else => try queueValueChildren(allocator, shape, reader, pending, remaining),
    }
}

fn readValueText(reader: *wire.Reader, remaining: ?*u64) Error![]const u8 {
    if (remaining != null) {
        var measured = reader.*;
        try valueWork(remaining, (try measured.bytes()).len);
    }
    return reader.text();
}

fn queueValueChildren(
    allocator: std.mem.Allocator,
    shape: p.Schema,
    reader: *wire.Reader,
    pending: *std.ArrayList(ValueTask),
    remaining: ?*u64,
) Error!void {
    try valueWork(remaining, if (shape == .product) shape.product.len else 1);
    switch (shape) {
        .product => |fields| {
            var i = fields.len;
            while (i != 0) {
                i -= 1;
                try pending.append(allocator, .{ .schema = fields[i], .count = 1 });
            }
        },
        .sum => |fields| {
            const tag = try reader.count();
            if (tag >= fields.len) return error.InvalidValue;
            try pending.append(allocator, .{ .schema = fields[tag], .count = 1 });
        },
        .seq => |element| try pending.append(
            allocator,
            .{ .schema = element, .count = try reader.natural() },
        ),
        .vector => |vector| {
            const count = try reader.natural();
            if (count > vector.maximum) return error.InvalidValue;
            try pending.append(allocator, .{ .schema = vector.element, .count = count });
        },
        .array => |array| try pending.append(
            allocator,
            .{ .schema = array.element, .count = array.length },
        ),
        else => return error.InvalidValue,
    }
}
