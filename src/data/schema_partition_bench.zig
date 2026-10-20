const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const partition = @import("schema_partition.zig");
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const count = try std.fmt.parseInt(usize, args.next() orelse return error.Count, 10);
    const mode = args.next() orelse return error.Mode;
    if (count > 8192 or
        (!std.mem.eql(u8, mode, "unique") and
            !std.mem.eql(u8, mode, "duplicate")) or
        args.next() != null)
        return error.Arguments;
    const schemas = try init.gpa.alloc(p.Schema, count + 1);
    defer init.gpa.free(schemas);
    schemas[0] = .u8;
    for (
        schemas[1..],
        0..,
    ) |*schema, i| schema.* = .{ .array = .{
        .element = 0,
        .length = if (std.mem.eql(u8, mode, "unique")) i else i % 8,
    } };
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = schemas,
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        }},
    };
    var samples: [9]f64 = undefined;
    var stats: partition.Statistics = .{};
    var digest: [32]u8 = undefined;
    var scratch: usize = 0;
    for (0..12) |window| {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const start = std.Io.Clock.awake.now(init.io);
        const classes = try partition.computeObserved(arena.allocator(), program, &stats);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        scratch = @max(scratch, arena.queryCapacity());
        std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(classes), &digest, .{});
        if (window >= 3) samples[window - 3] = @floatFromInt(elapsed);
    }
    const hex = std.fmt.bytesToHex(digest, .lower);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(
        .{
            .count = count,
            .mode = mode,
            .samplesNs = samples,
            .statistics = stats,
            .scratchCapacity = scratch,
            .classesSha256 = hex[0..],
        },
        .{},
        &out.interface,
    );
    try out.interface.writeByte('\n');
    try out.interface.flush();
}
