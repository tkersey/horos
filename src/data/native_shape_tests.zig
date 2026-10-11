const std = @import("std");
const native = @import("schema.zig").native;

test "native contracts normalize structure and preserve names, order, and bounds" {
    const A = struct { count: u64, done: bool };
    const B = struct { count: u64, done: bool };
    const C = struct { total: u64, done: bool };
    const D = struct { done: bool, count: u64 };
    try std.testing.expect(A != B);
    try std.testing.expect(native.Shape(A) == native.Shape(B));
    try std.testing.expect(native.Shape(A) != native.Shape(C));
    try std.testing.expect(native.Shape(A) != native.Shape(D));
    try std.testing.expect(native.Shape([2]A) == native.Shape([2]B));
    try std.testing.expect(native.Shape([2]A) != native.Shape([3]A));
    try std.testing.expect(native.Shape(native.Vector(A, null)) != native.Shape(native.Vector(C, null)));
    try std.testing.expect(native.Shape(native.Text(null)) == native.Shape(native.Utf8));
    try std.testing.expect(native.Shape(native.Bytes(null)) == native.Shape([]const u8));
    try std.testing.expect(native.Shape(native.Bytes(null)) == native.Shape([]u8));
    try std.testing.expect(native.Shape(native.Vector(u8, null)) != native.Shape([]const u8));
    try std.testing.expect(native.Shape(native.Vector(A, null)) == native.Shape([]const B));
    try std.testing.expect(native.Shape(native.Bytes(null)) != native.Shape(native.Bytes(0)));
    try std.testing.expect(native.Shape(native.Text(64)) != native.Shape(native.Text(256)));
    try std.testing.expect(native.Shape([0]u8) != native.Shape(native.Bytes(0)));
}

test "native enum tags and union case ordinals have distinct normalization laws" {
    const A = enum(u32) { red = 9, blue = 2 };
    const B = enum(u8) { first = 2, second = 9 };
    try std.testing.expect(native.Shape(A) == native.Shape(B));
    try std.testing.expectEqualSlices(u32, &.{ 2, 9 }, &native.enumTags(A));
    const U = union(A) { red: u64, blue: void };
    const V = union(enum) { red: u64, blue: void };
    try std.testing.expect(native.Shape(U) == native.Shape(V));
    try std.testing.expect(native.Shape(?u64) == native.Shape(union(enum) { none: void, some: u64 }));
    try std.testing.expect(native.info(struct {}).product == native.Fields(&.{}, &.{}));
    try std.testing.expectEqual(@as(usize, 0), native.enumTags(enum(noreturn) {}).len);
}

test "native logical contracts preserve previously accepted aggregate forms" {
    try std.testing.expect(native.Shape(packed struct { a: u8, b: u8 }) == native.Shape(struct { a: u8, b: u8 }));
    try std.testing.expect(native.Shape(extern struct { a: u32 }) == native.Shape(struct { a: u32 }));
    try std.testing.expect(native.Shape([2:0]u8) == native.Shape([2]u8));
    const Tuple = @Tuple(&.{ u64, bool });
    try std.testing.expectEqualStrings("0", @typeInfo(native.info(Tuple).product).@"struct".field_names[0]);
    try std.testing.expect(native.Shape(usize) == native.Shape(@Int(.unsigned, @bitSizeOf(usize))));
    const Pretend = struct {
        pub const protean_value_kind = .text;
        pub const max_length: ?u64 = null;
        bytes: []const u8,
    };
    try std.testing.expect(!native.wrapped(Pretend));
    try std.testing.expect(native.info(Pretend) == .product);
}
