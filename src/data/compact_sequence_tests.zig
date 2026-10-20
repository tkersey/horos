const std = @import("std");
const p = @import("program.zig");
const wire = @import("wire.zig");
const sequence = @import("compact_sequence.zig");

fn sequenceRoundTrip(comptime T: type, values: []const T) !void {
    const allocator = std.testing.allocator;
    var buffer: [8192]u8 = undefined;
    var writer: wire.Writer = .{ .output = &buffer };
    try sequence.write(T, values, &writer);
    var reader: wire.Reader = .{ .input = buffer[0..writer.position] };
    var requested: usize = 0;
    const decoded = try sequence.read(T, true, &reader, allocator, &requested);
    defer allocator.free(decoded);
    try reader.finish();
    try std.testing.expectEqualDeep(values, decoded);
}

test "current compact ID sequences preserve literals and full-width IDs" {
    try sequenceRoundTrip(p.Id, &.{});
    try sequenceRoundTrip(p.Id, &.{std.math.maxInt(u64)});
    try sequenceRoundTrip(p.Id, &.{ 5, 5, 5, 5, 5, 0, 1, 2, 3, 4, 1, 8, 1 });
}
test "range endpoint and expanded allocation overflow reject before expansion" {
    var reader: wire.Reader = .{ .input = &.{
        3,
        1,
        2,
        3,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        1,
    } };
    var requested: usize = 0;
    try std.testing.expectError(
        error.InvalidLength,
        sequence.read(p.Id, false, &reader, std.testing.allocator, &requested),
    );
    reader = .{ .input = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 } };
    try std.testing.expectError(
        error.InvalidLength,
        sequence.read(p.Id, false, &reader, std.testing.allocator, &requested),
    );
}
