//! Frozen Program data from accepted Horos 6313768, never compiled by the candidate.
const std = @import("std");
const data = @import("horos_data");

pub fn get(allocator: std.mem.Allocator, name: []const u8) !data.program_image.Decoded {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        @embedFile("coalescing_predecessors.json"),
        .{},
    );
    defer parsed.deinit();
    const entry = parsed.value.object.get("images").?.object.get(name) orelse
        return error.MissingPredecessorFixture;
    const encoded = entry.object.get("base64").?.string;
    const decoder = std.base64.standard.Decoder;
    const bytes = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer allocator.free(bytes);
    try decoder.decode(bytes, encoded);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, entry.object.get("sha256").?.string))
        return error.CorruptPredecessorFixture;
    // decode owns the returned records independently of bytes and parsed JSON.
    return data.program_image.decode(allocator, bytes);
}

pub fn kind(
    allocator: std.mem.Allocator,
    comptime prefix: []const u8,
    value: anytype,
) !data.program_image.Decoded {
    var key: [128]u8 = undefined;
    return get(allocator, try std.fmt.bufPrint(&key, "{s}{s}", .{ prefix, @tagName(value) }));
}

pub fn closures(allocator: std.mem.Allocator, count: usize) !data.program_image.Decoded {
    var key: [64]u8 = undefined;
    return get(allocator, try std.fmt.bufPrint(&key, "closure/{d}", .{count}));
}
