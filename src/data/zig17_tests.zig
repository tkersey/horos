//! Migration witnesses exercise the actual logical-record traversal.
const std = @import("std");
const record = @import("record.zig");
const equal = @import("record_equal.zig").equal;
const wire = @import("wire.zig");

test "Z17 fixed wire integers retain canonical little-endian bytes" {
    var bytes: [2]u8 = undefined;
    var writer = wire.Writer{ .output = &bytes };
    try writer.fixed(u16, 0xab12);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0xab }, &bytes);
    var reader = wire.Reader{ .input = &bytes };
    try std.testing.expectEqual(@as(u16, 0xab12), try reader.fixed(u16));
}

test "Z17 empty records tuples optional values and arrays retain declaration-order bytes" {
    const Product = struct {
        empty: struct {},
        tuple: struct { u3, ?u16 },
        @"wire bytes": [2]u8,
    };
    const value: Product = .{
        .empty = .{},
        .tuple = .{ 5, 300 },
        .@"wire bytes" = .{ 0x80, 0xff },
    };
    var bytes: [32]u8 = undefined;
    var writer = wire.Writer{ .output = &bytes };
    try record.write(Product, value, &writer);
    const golden = [_]u8{ 5, 1, 0xac, 2, 0x80, 0xff };
    try std.testing.expectEqualSlices(u8, &golden, bytes[0..writer.position]);
    var reader = wire.Reader{ .input = &golden };
    const decoded = try record.read(Product, &reader, std.testing.allocator);
    try std.testing.expect(equal(Product, value, decoded));
    try std.testing.expectEqual(golden.len, reader.position);
    var empty_writer = wire.Writer{ .output = &bytes };
    try record.write([0]u8, .{}, &empty_writer);
    try std.testing.expectEqual(@as(usize, 0), empty_writer.position);
}

test "Z17 union declaration order is independent of explicit wire tag values" {
    const Tag = enum(u8) { later = 11, earlier = 3 };
    const Value = union(Tag) { later: void, earlier: u16 };
    var bytes: [16]u8 = undefined;
    var writer = wire.Writer{ .output = &bytes };
    try record.write(Value, .{ .earlier = 9 }, &writer);
    try std.testing.expectEqualSlices(u8, &.{ 3, 9 }, bytes[0..writer.position]);
    var reader = wire.Reader{ .input = &.{ 3, 9 } };
    try std.testing.expectEqual(
        @as(u16, 9),
        (try record.read(Value, &reader, std.testing.allocator)).earlier,
    );
    var wrong = wire.Reader{ .input = &.{7} };
    try std.testing.expectError(
        error.InvalidTag,
        record.read(Value, &wrong, std.testing.allocator),
    );
    var truncated = wire.Reader{ .input = &.{3} };
    try std.testing.expectError(
        error.Truncated,
        record.read(Value, &truncated, std.testing.allocator),
    );
}

test "Z17 structural equality traverses distinct slices and preserves numeric float equality" {
    const Product = struct { values: []const u64, optional: ?u8 };
    const first = [_]u64{ 1, 2 };
    var second = first;
    const left: Product = .{ .values = &first, .optional = 3 };
    const right: Product = .{ .values = &second, .optional = 3 };
    try std.testing.expect(equal(Product, left, right));
    second[1] = 4;
    try std.testing.expect(!equal(Product, left, right));
    const nan = [_]f64{std.math.nan(f64)};
    try std.testing.expect(!equal([]const f64, &nan, &nan));
    try std.testing.expect(equal(f64, 0.0, -0.0));
}
