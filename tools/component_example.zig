// Copyright (c) 2026 Boundary contributors. MIT license.
//! One native driver shares component construction and public-consumer checks.
//! The transported linker imports data only; package consumers use Zig's package.
const std = @import("std");
const horos = @import("horos");
const Dir = std.Io.Dir;
const Runner = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,

    fn path(r: Runner, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(r.a, parts);
    }
    fn run(r: Runner, argv: []const []const u8, cwd: []const u8, success: bool) !std.process.RunResult {
        const result = try std.process.run(r.a, r.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = r.env, .stdout_limit = .limited(64 << 20), .stderr_limit = .limited(8 << 20), .timeout = .{ .duration = .{ .raw = .fromSeconds(300), .clock = .awake } } });
        if (result.term != .exited or (result.term.exited == 0) != success) {
            std.debug.print("{s}\n", .{result.stderr});
            return error.UnexpectedProcessResult;
        }
        return result;
    }
    fn write(r: Runner, file_path: []const u8, bytes: []const u8) !void {
        try Dir.cwd().writeFile(r.io, .{ .sub_path = file_path, .data = bytes });
    }
    fn read(r: Runner, file_path: []const u8) ![]u8 {
        return Dir.cwd().readFileAlloc(r.io, file_path, r.a, .limited(64 << 20));
    }
};
fn require(value: bool) !void {
    if (!value) return error.ContractMismatch;
}
fn components(r: Runner, linker: []const u8, output: []const u8) !void {
    const transported = try r.path(&.{ output, "horos-link" });
    try r.write(transported, try r.read(linker));
    var executable = try Dir.cwd().openFile(r.io, transported, .{});
    defer executable.close(r.io);
    try executable.setPermissions(r.io, .fromMode(0o755));
    inline for (.{ .{ "call", .call }, .{ "state", .state }, .{ "suspend", .suspended }, .{ "double", .double } }) |item| {
        const bytes = try horos.source.component_examples.emit(r.a, item[1]);
        try r.write(try r.path(&.{ output, item[0] ++ ".bmo1" }), bytes);
    }
    const bindings: []const horos.data.linker.Binding = &.{
        .{ .required = .{ .instance = "call", .symbol = "read" }, .supplied = .{ .instance = "state", .symbol = "read" } },
        .{ .required = .{ .instance = "state", .symbol = "twice" }, .supplied = .{ .instance = "call", .symbol = "twice" } },
        .{ .required = .{ .instance = "suspend", .symbol = "compute" }, .supplied = .{ .instance = "state", .symbol = "compute" } },
        .{ .required = .{ .instance = "suspend", .symbol = "read" }, .supplied = .{ .instance = "state", .symbol = "read" } },
    };
    const Instance = struct { key: []const u8, path: []const u8 };
    const instances: []const Instance = &.{ .{ .key = "call", .path = "call.bmo1" }, .{ .key = "state", .path = "state.bmo1" }, .{ .key = "suspend", .path = "suspend.bmo1" } };
    const manifest = .{ .instances = instances, .bindings = bindings, .entry = .{ .instance = "suspend", .symbol = "main" } };
    const manifest_path = try r.path(&.{ output, "link.json" });
    const bytes = try std.json.Stringify.valueAlloc(r.a, manifest, .{});
    try r.write(manifest_path, bytes);
    const first = try r.run(&.{ transported, "link.json" }, output, true);
    var admitted = try horos.data.program_image.Admitted.decode(r.a, first.stdout);
    defer admitted.deinit();
    const reverse_instances = try r.a.dupe(Instance, instances);
    const reverse_bindings = try r.a.dupe(horos.data.linker.Binding, bindings);
    std.mem.reverse(Instance, reverse_instances);
    std.mem.reverse(horos.data.linker.Binding, reverse_bindings);
    try r.write(manifest_path, try std.json.Stringify.valueAlloc(r.a, .{ .instances = reverse_instances, .bindings = reverse_bindings, .entry = manifest.entry }, .{}));
    const reversed = try r.run(&.{ transported, "link.json" }, output, true);
    try require(std.mem.eql(u8, first.stdout, reversed.stdout));
    var extended: std.ArrayList(horos.data.linker.Binding) = .empty;
    try extended.appendSlice(r.a, bindings);
    for ([_][]const u8{ "main", "read", "release" }) |name| try extended.append(r.a, .{ .required = .{ .instance = "double", .symbol = name }, .supplied = .{ .instance = "suspend", .symbol = name } });
    var additional: std.ArrayList(Instance) = .empty;
    try additional.appendSlice(r.a, instances);
    try additional.append(r.a, .{ .key = "double", .path = "double.bmo1" });
    try r.write(manifest_path, try std.json.Stringify.valueAlloc(r.a, .{ .instances = additional.items, .bindings = extended.items, .entry = .{ .instance = "double", .symbol = "main" } }, .{}));
    const second = try r.run(&.{ transported, "link.json" }, output, true);
    var second_admitted = try horos.data.program_image.Admitted.decode(r.a, second.stdout);
    defer second_admitted.deinit();
    try require(!std.mem.eql(u8, first.stdout, second.stdout));
    for ([_][]const u8{ "off", "safe" }) |retired| {
        try r.write(manifest_path, try std.fmt.allocPrint(r.a, "{s},\"coalescing\":\"{s}\"}}", .{ bytes[0 .. bytes.len - 1], retired }));
        const rejected = try r.run(&.{ transported, "link.json" }, output, false);
        try require(rejected.stdout.len == 0 and std.mem.indexOf(u8, rejected.stderr, "UnknownField") != null);
    }
}
fn package(r: Runner, zig: []const u8, repository: []const u8, output: []const u8) !void {
    const status = try r.run(&.{ "git", "--no-replace-objects", "status", "--porcelain", "--untracked-files=all" }, repository, true);
    if (status.stdout.len != 0) return error.PackageCheckRequiresCommittedCandidate;
    const snapshot = try r.run(&.{ "git", "--no-replace-objects", "archive", "--format=tar", "HEAD" }, repository, true);
    const archive = try r.path(&.{ output, "source.tar" });
    try r.write(archive, snapshot.stdout);
    const source = try r.path(&.{ output, "source" });
    try Dir.cwd().createDirPath(r.io, source);
    _ = try r.run(&.{ "tar", "-xf", archive, "-C", source }, output, true);
    var env = try r.env.clone(r.a);
    defer env.deinit();
    const global = try r.path(&.{ output, "global" });
    try env.put("ZIG_GLOBAL_CACHE_DIR", global);
    try env.put("ZIG_LOCAL_CACHE_DIR", try r.path(&.{ output, "local" }));
    try env.put("ZIG_LOCAL_PKG_DIR", try r.path(&.{ output, "packages" }));
    const selected: Runner = .{ .a = r.a, .io = r.io, .env = &env };
    const fetched = try selected.run(&.{ zig, "fetch", source }, output, true);
    const hash = std.mem.trim(u8, fetched.stdout, "\r\n ");
    if (hash.len == 0 or std.mem.indexOfAny(u8, hash, "/\\\r\n") != null) return error.InvalidPackageIdentity;
    const consumed = try r.path(&.{ output, "package" });
    try Dir.cwd().createDirPath(r.io, consumed);
    _ = try selected.run(&.{ "tar", "-xzf", try std.fmt.allocPrint(r.a, "{s}/p/{s}.tar.gz", .{ global, hash }), "--strip-components=1", "-C", consumed }, output, true);
    const consumer = try r.path(&.{ output, "consumer" });
    try Dir.cwd().createDirPath(r.io, consumer);
    try r.write(try r.path(&.{ consumer, "build.zig.zon" }), ".{ .name=.consumer, .version=\"0.0.0\", .fingerprint=0x705b3727bb03dcc2, .dependencies=.{ .horos=.{.path=\"../package\"}}, .paths=.{\"\"} }");
    inline for (.{ "build.zig", "rejection.zig", "category.zig", "failure_literal_category.zig", "lifecycle.zig", "data.zig", "static.zig", "static_cases.zig" }) |file| try r.write(try r.path(&.{ consumer, file }), try r.read(try r.path(&.{ source, "test/package_authoring", file })));
    try r.write(try r.path(&.{ consumer, "client.zig" }), try r.read(try r.path(&.{ source, "examples/authoring_client.zig" })));
    const image = try selected.run(&.{ zig, "build", "emit", "reject", "data", "comptime-reject" }, consumer, true);
    var admitted = try horos.data.program_image.Admitted.decode(r.a, image.stdout);
    defer admitted.deinit();
    inline for (.{ .{ "category", "wrong handle family", "expected schema" }, .{ "failure_literal_category", "wrong handle family", "expected failure_literal" }, .{ "lifecycle", "Body", "does not support field access" } }) |item| {
        const rejected = try selected.run(&.{ zig, "build", "-D" ++ item[0] ++ "=true" }, consumer, false);
        try require(std.mem.indexOf(u8, rejected.stderr, item[0] ++ ".zig:") != null and std.mem.indexOf(u8, rejected.stderr, item[1]) != null and std.mem.indexOf(u8, rejected.stderr, item[2]) != null);
    }
}
fn scratch(r: Runner, parent: []const u8) ![]const u8 {
    const absolute = try Dir.cwd().realPathFileAlloc(r.io, parent, r.a);
    var random: [16]u8 = undefined;
    r.io.random(&random);
    const selected = try r.path(&.{ absolute, &std.fmt.bytesToHex(random, .lower) });
    try Dir.cwd().createDir(r.io, selected, .fromMode(0o700));
    return selected;
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const name = args.next() orelse return error.MissingComponent;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const r: Runner = .{ .a = arena.allocator(), .io = init.io, .env = init.environ_map };
    if (std.mem.eql(u8, name, "check-components")) {
        const linker = args.next() orelse return error.MissingLinker;
        const output = try scratch(r, args.next() orelse return error.MissingOutput);
        defer Dir.cwd().deleteTree(r.io, output) catch {};
        if (args.next() != null) return error.UnexpectedArgument;
        return components(r, linker, output);
    }
    if (std.mem.eql(u8, name, "check-package")) {
        const zig = args.next() orelse return error.MissingCompiler;
        const repository = args.next() orelse return error.MissingRepository;
        const output = try scratch(r, args.next() orelse return error.MissingOutput);
        defer Dir.cwd().deleteTree(r.io, output) catch {};
        if (args.next() != null) return error.UnexpectedArgument;
        return package(r, zig, repository, output);
    }
    if (args.next() != null) return error.UnexpectedArgument;
    const kind = std.meta.stringToEnum(horos.source.component_examples.Kind, name) orelse return error.InvalidComponent;
    const bytes = try horos.source.component_examples.emit(init.gpa, kind);
    defer init.gpa.free(bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
}
