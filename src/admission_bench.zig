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
        var measurement: Measurement = .{
            .allocator = init.gpa,
            .io = init.io,
            .writer = &output.interface,
            .module = module,
            .name = name,
            .directory = directory,
        };
        for (0..fixtures.samples) |sample| try measurement.run(sample);
        try output.interface.flush();
    }
}

const Measurement = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    module: horos.source.ast.Module,
    name: []const u8,
    directory: []const u8,
    identity: ?[32]u8 = null,

    fn run(self: *Measurement, sample: usize) !void {
        var meter: Meter = .{ .parent = self.allocator };
        const start = std.Io.Clock.awake.now(self.io);
        var compiled = try horos.program.compile(meter.allocator(), self.module);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds;
        const retained = meter.live;
        const peak = meter.peak;
        const bytes = try self.allocator.alloc(
            u8,
            try horos.data.program_image.encodedLength(compiled.program),
        );
        defer self.allocator.free(bytes);
        _ = try compiled.encode(self.allocator, bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        if (self.identity) |expected| {
            if (!std.mem.eql(u8, &expected, &hash)) return error.ImageChanged;
        } else self.identity = hash;
        if (sample == 0) {
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}.bpi3",
                .{ self.directory, self.name },
            );
            defer self.allocator.free(path);
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
        }
        compiled.deinit();
        if (meter.live != 0) return error.LeakedCompilation;
        try std.json.Stringify.value(
            .{
                .fixture = self.name,
                .operation = "compile",
                .sample = sample,
                .ns = elapsed,
                .retained_bytes = retained,
                .peak_bytes = peak,
                .image_bytes = bytes.len,
                .sha256 = std.fmt.bytesToHex(hash, .lower),
            },
            .{},
            self.writer,
        );
        try self.writer.writeByte('\n');

        try self.admit(sample, bytes);
    }

    fn admit(self: Measurement, sample: usize, bytes: []const u8) !void {
        var meter: Meter = .{ .parent = self.allocator };
        const admit_start = std.Io.Clock.awake.now(self.io);
        const admitted = try horos.data.program_image.Admitted.decode(meter.allocator(), bytes);
        const admit_elapsed = admit_start.durationTo(
            std.Io.Clock.awake.now(self.io),
        ).nanoseconds;
        try std.json.Stringify.value(
            .{
                .fixture = self.name,
                .operation = "admit",
                .sample = sample,
                .ns = admit_elapsed,
                .retained_bytes = meter.live,
                .peak_bytes = meter.peak,
                .owner_storage_bytes = admitted.storageBytes(),
            },
            .{},
            self.writer,
        );
        try self.writer.writeByte('\n');
        admitted.deinit();
        if (meter.live != 0) return error.LeakedAdmission;
    }
};
