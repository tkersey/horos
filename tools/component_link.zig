// Copyright (c) 2026 Boundary contributors. MIT license.
//! This executable imports pure data only: no source compiler or emitter.
const std = @import("std");
const data = @import("horos_data");
const compilation_defaults: data.closed_compilation.Options = .{};
const Manifest = struct {
    instances: []const struct { key: []const u8, path: []const u8 },
    bindings: []const data.linker.Binding,
    entry: data.linker.Endpoint,
    contract: data.closed_compilation.Contract = .structural,
    objective: data.closed_compilation.Objective = compilation_defaults.objective,
    work_limit: u64 = compilation_defaults.work_limit,
    round_limit: usize = compilation_defaults.round_limit,
    image_growth_bytes: ?usize = null,
    max_image_bytes: ?usize = null,
    profile: ?data.closed_compilation.ProfilePolicy = null,
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.MissingManifest;
    if (args.next() != null) return error.UnexpectedArgument;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    if (std.mem.eql(u8, path, "--help")) {
        try output.interface.writeAll(
            "Usage: horos-link MANIFEST.json > PROGRAM.bpi3\nBMO1 instance paths are " ++
            "relative to the current directory.\nOptional manifest contract: structural " ++
            "(default) or semantic. Both invoke checked P01.\nOptional objective, " ++
            "work_limit, round_limit, image_growth_bytes, max_image_bytes and profile use " ++
            "shared compilation policy.\n",
        );
        try output.interface.flush();
        return;
    }
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(4 << 20));
    const manifest = try std.json.parseFromSlice(
        Manifest,
        a,
        bytes,
        .{ .allocate = .alloc_always },
    );
    defer manifest.deinit();
    const instances = try a.alloc(data.linker.Instance, manifest.value.instances.len);
    for (instances, manifest.value.instances) |*instance, item| instance.* = .{
        .key = item.key,
        .object = try std.Io.Dir.cwd().readFileAlloc(init.io, item.path, a, .limited(64 << 20)),
    };
    var linked = try data.linker.linkWithCompilation(
        init.gpa,
        instances,
        manifest.value.bindings,
        manifest.value.entry,
        .{
            .contract = manifest.value.contract,
            .objective = manifest.value.objective,
            .work_limit = manifest.value.work_limit,
            .round_limit = manifest.value.round_limit,
            .image_growth_bytes = manifest.value.image_growth_bytes,
            .max_image_bytes = manifest.value.max_image_bytes,
            .profile = manifest.value.profile,
        },
    );
    defer linked.deinit();
    const image = try a.alloc(u8, try data.program_image.encodedLength(linked.program));
    _ = try linked.encode(init.gpa, image);
    try output.interface.writeAll(image);
    try output.interface.flush();
}
