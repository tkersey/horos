// Copyright (c) 2026 Boundary contributors. MIT license.
//! Internal record encoding: explicit declaration order, minimal unsigned tags.
//! Only the checked logical catalog types call this module; no native layout is used.
const std = @import("std");
const wire = @import("wire.zig");
pub const Error = wire.Error || std.mem.Allocator.Error;

// A sizing sink can sum numeric sequence widths without generating each byte.
// Hashing, comparison and real output always use the original writer below.
fn measuredSequence(comptime T: type, values: []const T) wire.Error!usize {
    var total: usize = 0;
    for (values) |value| {
        comptime std.debug.assert(T == u64);
        const length = wire.naturalLength(value);
        total = std.math.add(usize, total, length) catch return error.InvalidLength;
    }
    return total;
}

/// Traverses borrowed record storage, including nested arrays of slices, before
/// a caller-owned encoder writes its first byte. Native bytes are never encoded.
pub fn overlaps(comptime T: type, value: T, output: []const u8) bool {
    return RecordOps(T, &.{}).overlaps(value, output);
}

pub fn write(comptime T: type, value: T, writer: *wire.Writer) wire.Error!void {
    return RecordOps(T, &.{}).write(value, writer);
}

fn RecordOps(comptime T: type, comptime ancestors: []const type) type {
    for (ancestors) |ancestor| {
        if (T == ancestor) @compileError("portable record storage must have finite type depth");
    }
    const ancestry = ancestors ++ .{T};
    return struct {
        fn write(value: T, writer: *wire.Writer) wire.Error!void {
            switch (@typeInfo(T)) {
                .void => {},
                .bool => try writer.byte(@intFromBool(value)),
                .int => |info| {
                    comptime std.debug.assert(info.signedness == .unsigned and info.bits <= 64);
                    try writer.natural(value);
                },
                .@"enum" => try writer.natural(@backingInt(value)),
                .optional => |info| {
                    try writer.byte(@intFromBool(value != null));
                    if (value) |present|
                        try RecordOps(
                            info.child,
                            ancestry,
                        ).write(
                            present,
                            writer,
                        );
                },
                .pointer => try writeSlice(value, writer),
                .array => |info| {
                    if (info.child == u8) return writer.put(&value);
                    for (value) |element|
                        try RecordOps(
                            info.child,
                            ancestry,
                        ).write(
                            element,
                            writer,
                        );
                },
                .@"struct" => |info| {
                    inline for (
                        info.field_names,
                        info.field_types,
                    ) |field_name, FieldType|
                        try RecordOps(
                            FieldType,
                            ancestry,
                        ).write(
                            @field(
                                value,
                                field_name,
                            ),
                            writer,
                        );
                },
                .@"union" => {
                    try writer.natural(@backingInt(std.meta.activeTag(value)));
                    switch (value) {
                        inline else => |payload| try RecordOps(
                            @TypeOf(
                                payload,
                            ),
                            ancestry,
                        ).write(
                            payload,
                            writer,
                        ),
                    }
                },
                else => @compileError("not a logical portable record: " ++ @typeName(T)),
            }
        }
        fn writeSlice(value: T, writer: *wire.Writer) wire.Error!void {
            const info = @typeInfo(T).pointer;
            comptime std.debug.assert(info.size == .slice);
            try writer.natural(value.len);
            if (info.child == u64) {
                if (writer.output ==
                    null and
                    writer.expected ==
                        null and
                    writer.hasher ==
                        null)
                {
                    writer.position = std.math.add(
                        usize,
                        writer.position,
                        try measuredSequence(info.child, value),
                    ) catch return error.InvalidLength;
                    return;
                }
            }
            if (info.child == u8) return writer.put(value);
            for (value) |element|
                try RecordOps(
                    info.child,
                    ancestry,
                ).write(
                    element,
                    writer,
                );
        }
        fn overlaps(value: T, output: []const u8) bool {
            switch (@typeInfo(T)) {
                .pointer => |info| {
                    if (wire.overlap(std.mem.sliceAsBytes(value), output)) return true;
                    if (info.child != u8) for (value) |element| {
                        if (RecordOps(info.child, ancestry).overlaps(element, output)) return true;
                    };
                },
                .array => |info| {
                    if (info.child != u8) for (value) |element| {
                        if (RecordOps(info.child, ancestry).overlaps(element, output)) return true;
                    };
                },
                .@"struct" => |info| inline for (
                    info.field_names,
                    info.field_types,
                ) |field_name, FieldType| {
                    if (RecordOps(
                        FieldType,
                        ancestry,
                    ).overlaps(
                        @field(
                            value,
                            field_name,
                        ),
                        output,
                    ))
                        return true;
                },
                .@"union" => switch (value) {
                    inline else => |payload| return RecordOps(
                        @TypeOf(
                            payload,
                        ),
                        ancestry,
                    ).overlaps(
                        payload,
                        output,
                    ),
                },
                .optional => |info| {
                    if (value) |present|
                        return RecordOps(
                            info.child,
                            ancestry,
                        ).overlaps(
                            present,
                            output,
                        );
                },
                else => {},
            }
            return false;
        }

        fn read(
            reader: *wire.Reader,
            allocator: std.mem.Allocator,
            remaining: *usize,
        ) Error!T {
            return switch (@typeInfo(T)) {
                .void => {},
                .bool => switch (try reader.byte()) {
                    0 => false,
                    1 => true,
                    else => error.InvalidTag,
                },
                .int => std.math.cast(T, try reader.natural()) orelse error.InvalidLength,
                .@"enum" => |info| blk: {
                    const tag = try reader.natural();
                    inline for (info.field_values) |field_value| {
                        if (tag == field_value) break :blk @fromBackingInt(@intCast(field_value));
                    }
                    break :blk error.InvalidTag;
                },
                .optional => |info| switch (try reader.byte()) {
                    0 => null,
                    1 => try RecordOps(info.child, ancestry).read(reader, allocator, remaining),
                    else => error.InvalidTag,
                },
                .pointer => readSlice(reader, allocator, remaining),
                .array => readArray(reader, allocator, remaining),
                .@"struct" => readStruct(reader, allocator, remaining),
                .@"union" => readUnion(reader, allocator, remaining),
                else => @compileError("not a logical portable record: " ++ @typeName(T)),
            };
        }

        fn readSlice(
            reader: *wire.Reader,
            allocator: std.mem.Allocator,
            remaining: *usize,
        ) Error!T {
            const info = @typeInfo(T).pointer;
            comptime std.debug.assert(info.size == .slice);
            const count = try reader.count();
            if (count > reader.input.len - reader.position) return error.Truncated;
            if (info.child == u8) return try reader.take(count);
            const bytes = std.math.mul(
                usize,
                @sizeOf(info.child),
                count,
            ) catch return error.InvalidLength;
            if (bytes > remaining.*) return error.Capacity;
            remaining.* -= bytes;
            const result = try allocator.alloc(info.child, count);
            for (result) |*element| element.* = try RecordOps(info.child, ancestry).read(
                reader,
                allocator,
                remaining,
            );
            return result;
        }
        fn readArray(
            reader: *wire.Reader,
            allocator: std.mem.Allocator,
            remaining: *usize,
        ) Error!T {
            const info = @typeInfo(T).array;
            var result: T = undefined;
            if (info.child == u8) {
                @memcpy(&result, try reader.take(info.len));
                return result;
            }
            for (&result) |*element| element.* = try RecordOps(info.child, ancestry).read(
                reader,
                allocator,
                remaining,
            );
            return result;
        }
        fn readStruct(
            reader: *wire.Reader,
            allocator: std.mem.Allocator,
            remaining: *usize,
        ) Error!T {
            const info = @typeInfo(T).@"struct";
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |field_name, FieldType| {
                @field(result, field_name) = try RecordOps(FieldType, ancestry).read(
                    reader,
                    allocator,
                    remaining,
                );
            }
            return result;
        }
        fn readUnion(
            reader: *wire.Reader,
            allocator: std.mem.Allocator,
            remaining: *usize,
        ) Error!T {
            const info = @typeInfo(T).@"union";
            const raw_tag = try reader.natural();
            const tag = std.enums.fromInt(info.tag_type.?, raw_tag) orelse return error.InvalidTag;
            return switch (tag) {
                inline else => |known| @unionInit(
                    T,
                    @tagName(known),
                    try RecordOps(@FieldType(T, @tagName(known)), ancestry).read(
                        reader,
                        allocator,
                        remaining,
                    ),
                ),
            };
        }

        fn equal(a: T, b: T) bool {
            return switch (@typeInfo(T)) {
                .pointer => |info| blk: {
                    if (a.len != b.len) break :blk false;
                    for (a, b) |left, right|
                        if (!RecordOps(
                            info.child,
                            ancestry,
                        ).equal(
                            left,
                            right,
                        ))
                            break :blk false;
                    break :blk true;
                },
                .@"struct" => |info| blk: {
                    inline for (
                        info.field_names,
                        info.field_types,
                    ) |field_name, FieldType| if (!RecordOps(FieldType, ancestry).equal(
                        @field(a, field_name),
                        @field(b, field_name),
                    )) break :blk false;
                    break :blk true;
                },
                .@"union" => switch (a) {
                    inline else => |payload, tag| switch (b) {
                        tag => |other| RecordOps(@TypeOf(payload), ancestry).equal(
                            payload,
                            other,
                        ),
                        else => false,
                    },
                },
                .array => |info| blk: {
                    for (a, b) |left, right|
                        if (!RecordOps(
                            info.child,
                            ancestry,
                        ).equal(
                            left,
                            right,
                        ))
                            break :blk false;
                    break :blk true;
                },
                .optional => |info| if (a) |left|
                    (if (b) |right|
                        RecordOps(
                            info.child,
                            ancestry,
                        ).equal(
                            left,
                            right,
                        )
                    else
                        false)
                else
                    b == null,
                .void => true,
                else => a == b,
            };
        }
    };
}

/// Allocations and decoded slices belong to allocator; use an invocation arena.
/// Counts are bounded by remaining bytes before allocating, including empty rows.
pub fn read(comptime T: type, reader: *wire.Reader, allocator: std.mem.Allocator) Error!T {
    var remaining: usize = std.math.maxInt(usize);
    return readBounded(T, reader, allocator, &remaining);
}

pub fn readBounded(
    comptime T: type,
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    remaining: *usize,
) Error!T {
    return RecordOps(T, &.{}).read(reader, allocator, remaining);
}

test "union decoding uses declared wire tags instead of field indexes" {
    const Tag = enum(u8) { earlier = 3, later = 11 };
    const Record = union(Tag) { earlier: u64, later };
    var bytes: [4]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try write(Record, .{ .earlier = 42 }, &writer);
    try std.testing.expectEqualSlices(u8, &.{ 3, 42 }, bytes[0..writer.position]);
    var reader: wire.Reader = .{ .input = bytes[0..writer.position] };
    const decoded = try read(Record, &reader, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), decoded.earlier);
    reader = .{ .input = &.{11} };
    try std.testing.expect(try read(Record, &reader, std.testing.allocator) == .later);
    reader = .{ .input = &.{0} };
    try std.testing.expectError(error.InvalidTag, read(Record, &reader, std.testing.allocator));
}

test "numeric sequence sizing agrees with emitted and hashed current record bytes" {
    const Argument = @import("activation.zig").Source;
    const Row = struct { ids: []const u64, arguments: []const Argument };
    for ([_]u64{ 0, 127, 128, 16383, 16384, std.math.maxInt(u64) }) |number| {
        const value: Row = .{
            .ids = &.{ number, 0, 128 },
            .arguments = &.{ .{ .slot = number }, .returned, .{ .slot = 0 } },
        };
        var measured: wire.Writer = .{};
        try write(Row, value, &measured);
        var buffer: [128]u8 = undefined;
        var emitted: wire.Writer = .{ .output = &buffer };
        try write(Row, value, &emitted);
        try std.testing.expectEqual(emitted.position, measured.position);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var hashed: wire.Writer = .{ .hasher = &hash };
        try write(Row, value, &hashed);
        try std.testing.expectEqual(emitted.position, hashed.position);
        try std.testing.expectEqual(wire.digest(buffer[0..emitted.position]), hash.finalResult());
        var compared: wire.Writer = .{ .expected = buffer[0..emitted.position] };
        try write(Row, value, &compared);
    }
}

test "current record hashes preserve long full-width vectors" {
    const Argument = @import("activation.zig").Source;
    inline for (.{ u64, Argument }) |T| {
        var values: [257]T = undefined;
        for (&values, 0..) |*value, index| {
            const id = std.math.maxInt(u64) - index;
            value.* = if (T == u64) id else if (index % 3 == 0) .returned else .{ .slot = id };
        }
        var buffer: [4096]u8 = undefined;
        var emitted: wire.Writer = .{ .output = &buffer };
        try write([]const T, &values, &emitted);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var hashed: wire.Writer = .{ .hasher = &hash };
        try write([]const T, &values, &hashed);
        try std.testing.expectEqual(emitted.position, hashed.position);
        try std.testing.expectEqual(wire.digest(buffer[0..emitted.position]), hash.finalResult());
    }
}

/// Compare declared record contents, including borrowed slice elements.
pub fn equal(comptime T: type, a: T, b: T) bool {
    return RecordOps(T, &.{}).equal(a, b);
}
