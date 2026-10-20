//! Diagnostic measurements; no timing threshold changes program admission.
const std = @import("std");
const horos = @import("root.zig");
const Meter = @import("coalescing_allocation_meter.zig").Meter;
const fixtures = @import("admission_bench_fixtures.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const directory = args.next() orelse return error.MissingDirectory;
    if (args.next() != null) return error.InvalidArguments;
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    for (fixtures.names, 0..) |name, index| {
        var builder = horos.source.Builder.init(init.gpa);
        defer builder.deinit();
        const module = try switch (index) {
            0 => horos.source.examples.recursive(&builder),
            1 => horos.source.examples.generator(&builder),
            2 => horos.source.examples.scopedReader(&builder),
            3 => horos.source.examples.stateLocal(&builder),
            4 => horos.source.examples.stateShared(&builder),
            5 => horos.source.examples.choicesAll(&builder),
            6 => horos.source.examples.queensDfs(&builder),
            else => horos.source.examples.installations(
                &builder,
                fixtures.installations[index - 7],
            ),
        };
        var identity: ?[32]u8 = null;
        for (0..fixtures.samples) |sample| {
            var meter: Meter = .{ .parent = init.gpa };
            const start = std.Io.Clock.awake.now(init.io);
            var compiled = try horos.program.compile(meter.allocator(), module);
            const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            const retained = meter.live;
            const peak = meter.peak;
            const bytes = try init.gpa.alloc(
                u8,
                try horos.data.program_image.encodedLength(compiled.program),
            );
            defer init.gpa.free(bytes);
            _ = try compiled.encode(init.gpa, bytes);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
            if (identity) |expected| {
                if (!std.mem.eql(u8, &expected, &hash)) return error.ImageChanged;
            } else identity = hash;
            if (sample == 0) {
                const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}.bpi3", .{ directory, name });
                defer init.gpa.free(path);
                try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
            }
            compiled.deinit();
            if (meter.live != 0) return error.LeakedCompilation;
            try std.json.Stringify.value(
                .{
                    .fixture = name,
                    .operation = "compile",
                    .sample = sample,
                    .ns = elapsed,
                    .retained_bytes = retained,
                    .peak_bytes = peak,
                    .image_bytes = bytes.len,
                    .sha256 = std.fmt.bytesToHex(hash, .lower),
                },
                .{},
                &output.interface,
            );
            try output.interface.writeByte('\n');

            meter = .{ .parent = init.gpa };
            const admit_start = std.Io.Clock.awake.now(init.io);
            const admitted = try horos.data.program_image.Admitted.decode(meter.allocator(), bytes);
            const admit_elapsed = admit_start.durationTo(
                std.Io.Clock.awake.now(init.io),
            ).nanoseconds;
            try std.json.Stringify.value(
                .{
                    .fixture = name,
                    .operation = "admit",
                    .sample = sample,
                    .ns = admit_elapsed,
                    .retained_bytes = meter.live,
                    .peak_bytes = meter.peak,
                    .owner_storage_bytes = admitted.storageBytes(),
                },
                .{},
                &output.interface,
            );
            try output.interface.writeByte('\n');
            admitted.deinit();
            if (meter.live != 0) return error.LeakedAdmission;
        }
        try output.interface.flush();
    }
}
