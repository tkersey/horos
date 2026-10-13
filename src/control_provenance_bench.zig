//! Private derivation measurement. Does not export a new authoring/data API.
const std = @import("std");
const image = @import("data/program_image.zig");
const provenance = @import("data/control_provenance.zig");
const Meter = @import("coalescing_allocation_meter.zig").Meter;
const fixtures = @import("admission_bench_fixtures.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const directory = args.next() orelse return error.MissingDirectory;
    if (args.next() != null) return error.InvalidArguments;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    for (fixtures.names) |name| {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}.bpi3", .{ directory, name });
        defer init.gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .unlimited);
        defer init.gpa.free(bytes);
        const admitted = try image.Admitted.decode(init.gpa, bytes);
        defer admitted.deinit();
        for (0..fixtures.samples) |sample| {
            var meter: Meter = .{ .parent = init.gpa };
            var arena = std.heap.ArenaAllocator.init(meter.allocator());
            const start = std.Io.Clock.awake.now(init.io);
            const control = try provenance.derive(arena.allocator(), admitted.program(), &.{}, false);
            const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            var recipients: usize = 0;
            for (admitted.program().blocks, 0..) |block, index| {
                if (block.terminator == .perform) recipients += control.targets(.{ .block = index, .role = .operation }, block.terminator.perform.effect).len;
            }
            try std.json.Stringify.value(.{ .fixture = name, .operation = "derive", .sample = sample, .ns = elapsed, .retained_bytes = meter.live, .peak_bytes = meter.peak, .arena_capacity = arena.queryCapacity(), .direct_recipients = recipients }, .{}, &output.interface);
            try output.interface.writeByte('\n');
            arena.deinit();
            if (meter.live != 0) return error.LeakedDerivation;
        }
        try output.interface.flush();
    }
}
