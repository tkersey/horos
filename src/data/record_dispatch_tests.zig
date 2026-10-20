const std = @import("std");
const record = @import("record.zig");
const golden = @embedFile("testdata/record-unions.bin");
const wire = @import("wire.zig");
const p = @import("program.zig");
const ir = @import("activation.zig");
const g = @import("graph.zig");
const invocation = @import("invocation.zig");
const families = .{
    p.Schema,
    p.Internal,
    ir.Source,
    ir.Terminator,
    g.Node,
    @FieldType(g.Value, "body"),
    @FieldType(g.Exit, "reason"),
    @FieldType(@FieldType(g.Node, "obligation"), "status"),
    invocation.Reason,
    invocation.Instance,
    invocation.Control,
    invocation.Outcome,
};
fn sample(comptime T: type, allocator: std.mem.Allocator, mode: usize) std.mem.Allocator.Error!T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => mode % 2 != 0,
        .int => @as(T, if (mode % 2 == 0) 0 else 137),
        .@"enum" => std.meta.tags(T)[mode % std.meta.tags(T).len],
        .optional => |o| if (mode % 2 == 0) null else try sample(o.child, allocator, mode),
        .pointer => |ptr| blk: {
            const values = try allocator.alloc(ptr.child, if (mode % 2 == 0) 0 else 2);
            for (values, 0..) |*value, i| value.* = try sample(ptr.child, allocator, mode + i);
            break :blk values;
        },
        .array => |ar| blk: {
            var out: T = undefined;
            for (&out, 0..) |*v, i| v.* = try sample(ar.child, allocator, mode + i);
            break :blk out;
        },
        .@"struct" => |s| blk: {
            var out: T = undefined;
            inline for (
                s.field_names,
                s.field_types,
            ) |name, Field| @field(out, name) = try sample(Field, allocator, mode);
            break :blk out;
        },
        .@"union" => |u| blk: {
            inline for (
                u.field_names,
                u.field_types,
                0..,
            ) |name, Field, i| if (mode % u.field_types.len == i) break :blk @unionInit(
                T,
                name,
                try sample(Field, allocator, mode),
            );
            unreachable;
        },
        else => @compileError("unsupported fixture shape"),
    };
}
test "direct union dispatch preserves all variants against captured baseline wire vectors" {
    var expected: wire.Writer = .{ .expected = golden };
    inline for (families) |T| {
        inline for (
            @typeInfo(T).@"union".field_names,
            @typeInfo(T).@"union".field_types,
        ) |name, Field| {
            for (0..4) |mode| {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const value = @unionInit(T, name, try sample(Field, arena.allocator(), mode));
                var new_storage: [4096]u8 = undefined;
                var new_writer: wire.Writer = .{ .output = &new_storage };
                try record.write(T, value, &expected);
                try record.write(T, value, &new_writer);
                try std.testing.expect(!record.overlaps(T, value, &new_storage));
                var reader: wire.Reader = .{ .input = new_storage[0..new_writer.position] };
                const decoded = try record.read(T, &reader, arena.allocator());
                try std.testing.expect(record.equal(T, value, decoded));
                for (0..new_writer.position) |length| {
                    var truncated: wire.Reader = .{ .input = new_storage[0..length] };
                    if (record.read(
                        T,
                        &truncated,
                        arena.allocator(),
                    )) |_| return error.ExpectedTruncation else |_| {}
                }
            }
        }
    }
    try std.testing.expectEqual(golden.len, expected.position);
}

test "direct dispatch rejects sparse holes oversized tags and retired terminators" {
    const Tag = enum(u8) { first = 3, last = 11 };
    const Value = union(Tag) { first: u64, last };
    for ([_][]const u8{ &.{0}, &.{7}, &.{12}, &.{ 0x80, 0x02 } }) |bytes| {
        var reader: wire.Reader = .{ .input = bytes };
        try std.testing.expectError(
            error.InvalidTag,
            record.read(Value, &reader, std.testing.allocator),
        );
        try std.testing.expectEqual(bytes.len, reader.position);
    }
    var reader: wire.Reader = .{ .input = &.{14} };
    try std.testing.expectError(
        error.InvalidTag,
        record.read(ir.Terminator, &reader, std.testing.allocator),
    );
    reader = .{ .input = &.{ 15, 1, 2, 0 } };
    const valid = try record.read(ir.Terminator, &reader, std.testing.allocator);
    defer std.testing.allocator.free(valid.dispose.next.assignments);
    try std.testing.expectEqual(@as(u64, 1), valid.dispose.owned);
    try std.testing.expectEqual(@as(u64, 2), valid.dispose.next.block);
    try std.testing.expect(!record.equal(Value, .{ .first = 11 }, .last));
}

test "direct dispatch preserves nested borrowed slices overlap and allocation budget precedence" {
    const Value = union(enum) { empty, names: []const []const u8 };
    const bytes = [_]u8{ 1, 2, 1, 'a', 1, 'b' };
    var reader: wire.Reader = .{ .input = &bytes };
    var budget: usize = @sizeOf([]const u8) * 2 - 1;
    try std.testing.expectError(
        error.Capacity,
        record.readBounded(Value, &reader, std.testing.allocator, &budget),
    );
    try std.testing.expectEqual(@as(usize, 2), reader.position);
    try std.testing.expectEqual(@sizeOf([]const u8) * 2 - 1, budget);
    budget = @sizeOf([]const u8) * 2;
    reader = .{ .input = &bytes };
    const decoded = try record.readBounded(Value, &reader, std.testing.allocator, &budget);
    defer std.testing.allocator.free(decoded.names);
    try std.testing.expect(decoded.names[0].ptr == bytes[3..].ptr);
    try std.testing.expect(decoded.names[1].ptr == bytes[5..].ptr);
    try std.testing.expect(record.overlaps(Value, decoded, bytes[3..4]));
    try std.testing.expect(record.overlaps(Value, decoded, std.mem.sliceAsBytes(decoded.names)));
    reader = .{ .input = &.{ 1, 3, 0 } };
    budget = 0;
    try std.testing.expectError(
        error.Truncated,
        record.readBounded(Value, &reader, std.testing.allocator, &budget),
    );
    try std.testing.expectEqual(@as(usize, 2), reader.position);
}
