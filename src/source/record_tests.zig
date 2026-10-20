const std = @import("std");
const data = @import("horos_data");
const pe = @import("specialize.zig");
const source = @import("../source.zig");

const expected = @as([192]u8, @splat(0)) ++ [_]u8{
    7, 4, 0, 1, 5, 2, 0xaa, 0xbb, 2, 9, 2, 0, 1, 3, 0, 0, 128, 1, 32, 128, 4,
};

fn request() pe.Request {
    return .{
        .context = std.mem.zeroes(pe.Context),
        .function = 7,
        .arguments = &.{
            .dynamic,
            .{ .known = .{ .schema = 5, .bytes = &.{ 0xaa, 0xbb } } },
            .{ .product = .{ .schema = 9, .fields = &.{
                .dynamic,
                .{ .known = .{ .schema = 3, .bytes = &.{} } },
            } } },
            .dynamic,
        },
        .policy = .{ .work = 128, .keys_per_function = 32, .depth = 512 },
    };
}

fn checkWriters(a: std.mem.Allocator) !void {
    var bytes: [expected.len]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var writer: data.wire.Writer = .{
        .output = &bytes,
        .expected = &expected,
        .hasher = &hash,
    };
    try data.record.writeAlloc(pe.Request, a, request(), &writer);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
    try std.testing.expectEqual(data.wire.digest(&expected), hash.finalResult());
    var size: data.wire.Writer = .{};
    try data.record.writeAlloc(pe.Request, a, request(), &size);
    try std.testing.expectEqual(expected.len, size.position);
    var short: data.wire.Writer = .{ .output = bytes[0 .. bytes.len - 1] };
    data.record.writeAlloc(pe.Request, a, request(), &short) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.Capacity, err);
        try std.testing.expectEqual(expected.len - 1, short.position);
        return;
    };
    return error.TestUnexpectedResult;
}

fn checkDecoded(a: std.mem.Allocator, decoded: pe.Request) !void {
    try std.testing.expect(try data.record.equalAlloc(pe.Request, a, request(), decoded));
    try std.testing.expect(try pe.requestEqual(a, request(), decoded));
    const literal = decoded.arguments[1].known.bytes;
    try std.testing.expectEqual(@intFromPtr(&expected[198]), @intFromPtr(literal.ptr));
    try std.testing.expect(try data.record.overlapsAlloc(pe.Request, a, decoded, literal));
    try std.testing.expect(try data.record.overlapsAlloc(
        pe.Request,
        a,
        decoded,
        std.mem.sliceAsBytes(decoded.arguments[2].product.fields),
    ));
    const copied = try source.own(pe.Request, a, decoded);
    try std.testing.expect(try data.record.equalAlloc(pe.Request, a, decoded, copied));
    try std.testing.expect(!try data.record.overlapsAlloc(pe.Request, a, copied, &expected));
    var changed = copied;
    changed.policy.work += 1;
    try std.testing.expect(!try pe.requestEqual(a, decoded, changed));
}

fn checkReaders(a: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    var reader: data.wire.Reader = .{ .input = &expected };
    const decoded = try data.record.read(pe.Request, &reader, storage);
    try reader.finish();
    try checkDecoded(storage, decoded);
    var budget: usize = 6 * @sizeOf(pe.Knowledge);
    reader.position = 0;
    const bounded = try data.record.readBounded(pe.Request, &reader, storage, &budget);
    try std.testing.expectEqual(@as(usize, 0), budget);
    try reader.finish();
    try std.testing.expect(try data.record.equalAlloc(pe.Request, storage, decoded, bounded));
    budget = 4 * @sizeOf(pe.Knowledge);
    reader.position = 0;
    _ = data.record.readBounded(pe.Request, &reader, storage, &budget) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.Capacity, err);
        try std.testing.expectEqual(@as(usize, 203), reader.position);
        try std.testing.expectEqual(@as(usize, 0), budget);
        return;
    };
    return error.TestUnexpectedResult;
}

test "public specialization records retain canonical modes and recursive decoding" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkWriters, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkReaders, .{});
}
