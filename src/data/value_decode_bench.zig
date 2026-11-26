const std = @import("std");
const p = @import("program.zig");
const wire = @import("wire.zig");
const admission = @import("admission.zig");

const records = 64;
const samples = 31;
const iterations = 200;
const tags = blk: {
    var dense: [48]u32 = undefined;
    for (&dense, 0..) |*tag, index| tag.* = index;
    break :blk dense;
};
const catalog = [_]p.Schema{
    .u64,
    .{ .enumeration = &tags },
    .{ .seq = 0 },
    .{ .sum = &.{ 4, 0 } },
    .unit,
    .{ .product = &.{ 0, 1, 2, 3, 6 } },
    .text,
    .{ .seq = 5 },
    .{ .product = &.{ 7, 0 } },
};
const record_schema = 5;
const collection_schema = 7;
const head_schema = 8;

fn natural(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buffer: [10]u8 = undefined;
    var writer: wire.Writer = .{ .output = &buffer };
    try writer.natural(value);
    try output.appendSlice(allocator, buffer[0..writer.position]);
}

fn word(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
}

fn encodeHead(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try natural(&output, allocator, records);
    for (0..records) |_| {
        try word(&output, allocator, random.int(u64));
        const tag = random.uintLessThan(u32, tags.len);
        try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, tag)));
        const length = random.uintAtMost(u64, 12);
        try natural(&output, allocator, length);
        for (0..length) |_| try word(&output, allocator, random.int(u64));
        const present = random.boolean();
        try natural(&output, allocator, @intFromBool(present));
        if (present) try word(&output, allocator, random.int(u64));
        const text = "task-label";
        const text_length = random.uintAtMost(usize, text.len);
        try natural(&output, allocator, text_length);
        try output.appendSlice(allocator, text[0..text_length]);
    }
    try word(&output, allocator, random.int(u64));
    return output.toOwnedSlice(allocator);
}

fn iterate(allocator: std.mem.Allocator, facts: admission.SchemaFacts, head: []const u8) !u64 {
    var decoded: u64 = 0;
    var start: wire.Reader = .{ .input = head };
    _ = try start.natural();
    for (0..records) |index| {
        var reader = start;
        for (0..index + 1) |_| {
            decoded += (try admission.readValue(allocator, &catalog, facts, record_schema, &reader))
                .len;
        }
    }
    try admission.value(allocator, &catalog, facts, .{ .schema = head_schema, .bytes = head });
    var scalars: wire.Reader = .{ .input = head[head.len - 8 ..] };
    for (0..records) |_| {
        scalars.position = 0;
        decoded += (try admission.readValue(allocator, &catalog, facts, 0, &scalars)).len;
    }
    return decoded;
}

pub fn main(init: std.process.Init) !void {
    var prng = std.Random.DefaultPrng.init(0x7a1e);
    const head = try encodeHead(init.gpa, prng.random());
    defer init.gpa.free(head);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const facts = try admission.schemas(arena.allocator(), &catalog);
    var observed: [samples]u64 = undefined;
    var decoded: u64 = 0;
    for (&observed) |*sample| {
        const started = std.Io.Clock.awake.now(init.io);
        for (0..iterations) |_| decoded +%= try iterate(arena.allocator(), facts, head);
        const elapsed = started.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        sample.* = @intCast(@divTrunc(elapsed, iterations));
    }
    std.mem.sort(u64, &observed, {}, std.sort.asc(u64));
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(.{
        .workload = "skip-to-index over 64 records, whole-head admission, scalar roots",
        .head_bytes = head.len,
        .samples = samples,
        .iterations_per_sample = iterations,
        .median_ns = observed[samples / 2],
        .p95_ns = observed[(samples * 95 + 99) / 100 - 1],
        .min_ns = observed[0],
        .max_ns = observed[samples - 1],
        .decoded_bytes = decoded,
    }, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
