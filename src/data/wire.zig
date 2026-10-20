// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");

/// Every returned slice borrows the input or the caller's output buffer.
pub const Error = error{
    Truncated,
    InvalidFamily,
    UnsupportedFamily,
    UnsupportedVersion,
    InvalidFlags,
    InvalidLength,
    NonCanonical,
    InvalidTag,
    InvalidUtf8,
    Capacity,
    InvalidBuffers,
};

pub const header_length = 20;

pub const Reader = struct {
    input: []const u8,
    position: usize = 0,

    pub fn take(self: *Reader, length: usize) Error![]const u8 {
        if (self.position > self.input.len or
            length > self.input.len - self.position)
            return error.Truncated;
        const result = self.input[self.position..][0..length];
        self.position += length;
        return result;
    }

    pub fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    /// At most ten bytes are examined. Overlong and overflowing forms reject.
    pub fn natural(self: *Reader) Error!u64 {
        const first = try self.byte();
        if (first < 0x80) return first;
        var result: u64 = first & 0x7f;
        for (1..10) |index| {
            const next = try self.byte();
            if (index == 9 and next > 1) return error.InvalidLength;
            const shift: u6 = @intCast(index * 7);
            result |= @as(u64, next & 0x7f) << shift;
            if (next & 0x80 == 0) {
                if (next == 0) return error.NonCanonical;
                return result;
            }
        }
        return error.InvalidLength;
    }

    pub fn count(self: *Reader) Error!usize {
        return std.math.cast(usize, try self.natural()) orelse error.InvalidLength;
    }

    pub fn bytes(self: *Reader) Error![]const u8 {
        return self.take(try self.count());
    }

    pub fn text(self: *Reader) Error![]const u8 {
        const result = try self.bytes();
        if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidUtf8;
        return result;
    }

    pub fn fixed(self: *Reader, comptime T: type) Error!T {
        const input = try self.take(@sizeOf(T));
        return std.mem.readInt(T, input[0..@sizeOf(T)], .little);
    }

    pub fn finish(self: Reader) Error!void {
        if (self.position != self.input.len) return error.NonCanonical;
    }
};

/// A null output measures exact encoded length without allocation or writes.
pub const Writer = struct {
    output: ?[]u8 = null,
    expected: ?[]const u8 = null,
    hasher: ?*std.crypto.hash.sha2.Sha256 = null,
    position: usize = 0,

    pub fn put(self: *Writer, input: []const u8) Error!void {
        const end = std.math.add(usize, self.position, input.len) catch
            return error.InvalidLength;
        if (self.expected) |expected| {
            if (end > expected.len or !std.mem.eql(u8, expected[self.position..end], input))
                return error.NonCanonical;
        }
        if (self.output) |output| {
            if (end > output.len) return error.Capacity;
            @memcpy(output[self.position..end], input);
        }
        if (self.hasher) |hash| hash.update(input);
        self.position = end;
    }

    pub fn byte(self: *Writer, value: u8) Error!void {
        try self.put(&.{value});
    }

    pub fn natural(self: *Writer, value: u64) Error!void {
        var remaining = value;
        while (true) {
            const next: u8 = @intCast(remaining & 0x7f);
            remaining >>= 7;
            try self.byte(next | @as(u8, if (remaining == 0) 0 else 0x80));
            if (remaining == 0) return;
        }
    }

    pub fn bytes(self: *Writer, value: []const u8) Error!void {
        try self.natural(value.len);
        try self.put(value);
    }

    pub fn fixed(self: *Writer, comptime T: type, value: T) Error!void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.put(&buffer);
    }
};

pub fn overlap(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    return if (a <= b) b - a < first.len else a - b < second.len;
}

pub fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn hashField(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [10]u8 = undefined;
    var writer: Writer = .{ .output = &length };
    writer.natural(bytes.len) catch unreachable; // Ten bytes encode every u64.
    hash.update(length[0..writer.position]);
    hash.update(bytes);
}

test "minimal naturals include u64 max and reject overflow without trapping" {
    var output: [10]u8 = undefined;
    for ([_]u64{ 0, 127, 128, 16384, std.math.maxInt(u64) }) |value| {
        var writer: Writer = .{ .output = &output };
        try writer.natural(value);
        var reader: Reader = .{ .input = output[0..writer.position] };
        try std.testing.expectEqual(value, try reader.natural());
        try reader.finish();
    }
    var overlong: Reader = .{ .input = &.{ 0x80, 0 } };
    try std.testing.expectError(error.NonCanonical, overlong.natural());
    var overflow: Reader = .{ .input = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 2 } };
    try std.testing.expectError(error.InvalidLength, overflow.natural());
}
