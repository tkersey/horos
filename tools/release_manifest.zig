const std = @import("std");
const Dir = std.Io.Dir;
const maximum_bytes = 1024 * 1024;

comptime {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
        @compileError("Zig 0.17.0 is required");
}

const Version = struct { version: []const u8 };
const Binding = struct { version: []const u8, start: usize, end: usize };
const Source = struct { bytes: [:0]const u8, permissions: std.Io.File.Permissions };

fn bounded(source: [:0]const u8) !void {
    if (source.len > maximum_bytes) return error.ManifestTooLarge;
    var tokenizer = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var remaining = source.len + 1;
    while (remaining > 0) : (remaining -= 1) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return,
            .invalid => return error.InvalidManifest,
            .l_brace, .l_bracket, .l_paren => {
                depth += 1;
                if (depth > 64) return error.ManifestTooDeep;
            },
            .r_brace, .r_bracket, .r_paren => depth -|= 1,
            else => {},
        }
    }
    return error.InvalidManifest;
}

fn checkVersion(version: []const u8) !void {
    const parsed = std.SemanticVersion.parse(version) catch return error.InvalidVersion;
    if (parsed.pre != null or parsed.build != null) return error.UnsupportedVersion;
    for ([_]usize{ parsed.major, parsed.minor, parsed.patch }) |part| {
        if (part > 9007199254740991) return error.UnsupportedVersion;
    }
}

fn versionField(a: std.mem.Allocator, ast: std.zig.Ast) !std.zig.Ast.Node.Index {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const root = ast.fullStructInit(&buffer, ast.rootDecls()[0]) orelse
        return error.InvalidManifestRoot;
    for (root.ast.fields) |field| {
        const token = ast.tokenSlice(ast.firstToken(field) - 2);
        const name = if (std.mem.startsWith(u8, token, "@\""))
            try std.zig.string_literal.parseAlloc(a, token[1..])
        else
            token;
        if (std.mem.eql(u8, name, "version")) return field;
    }
    return error.MissingVersion;
}

fn binding(a: std.mem.Allocator, source: [:0]const u8) !Binding {
    try bounded(source);
    var ast = try std.zig.Ast.parse(a, source, .{ .mode = .zon });
    defer ast.deinit(a);
    var zoir = try std.zig.ZonGen.generate(a, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(a);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const selected = try std.zon.parse.fromZoir(Version, .{
        .arena = a,
        .ast = &ast,
        .zoir = &zoir,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    try checkVersion(selected.version);
    const field = try versionField(a, ast);
    if (ast.nodeTag(field) != .string_literal) return error.UnsupportedVersionLiteral;
    const token = ast.nodeMainToken(field);
    const start = ast.tokenStart(token);
    return .{
        .version = selected.version,
        .start = start,
        .end = start + ast.tokenSlice(token).len,
    };
}

pub fn read(a: std.mem.Allocator, source: [:0]const u8) ![]const u8 {
    return (try binding(a, source)).version;
}

pub fn prepare(a: std.mem.Allocator, source: [:0]const u8, target: []const u8) ![]const u8 {
    try checkVersion(target);
    const selected = try binding(a, source);
    if (std.mem.eql(u8, selected.version, target)) return source;
    const result = try std.mem.concat(a, u8, &.{
        source[0..selected.start], "\"", target, "\"", source[selected.end..],
    });
    const admitted = try binding(a, try a.dupeSentinel(u8, result, 0));
    if (!std.mem.eql(u8, admitted.version, target)) return error.VersionMismatch;
    return result;
}

fn stable(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.kind == b.kind and
        a.permissions == b.permissions and std.meta.eql(a.mtime, b.mtime) and
        std.meta.eql(a.ctime, b.ctime);
}

fn readSource(a: std.mem.Allocator, io: std.Io, path: []const u8) !Source {
    var file = try Dir.cwd().openFile(io, path, .{
        .follow_symlinks = false,
        .allow_directory = false,
    });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.size > maximum_bytes) return error.InvalidManifestFile;
    var reader = file.reader(io, &.{});
    const bytes = try reader.interface.allocRemaining(a, .limited(maximum_bytes));
    const after = try file.stat(io);
    const named = try Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (!stable(before, after) or !stable(after, named) or bytes.len != before.size)
        return error.ManifestChanged;
    return .{ .bytes = try a.dupeSentinel(u8, bytes, 0), .permissions = before.permissions };
}

fn retain(
    a: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: Source,
    bytes: []const u8,
) !void {
    var file = Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        const existing = try readSource(a, io, path);
        if (!std.mem.eql(u8, bytes, existing.bytes) or existing.permissions != source.permissions)
            return error.CandidateCollision;
        return;
    };
    defer file.close(io);
    errdefer Dir.cwd().deleteFile(io, path) catch |err|
        std.log.err("candidate cleanup failed: {s}", .{@errorName(err)});
    try file.writeStreamingAll(io, bytes);
    try file.setPermissions(io, source.permissions);
}

fn prepareFile(
    a: std.mem.Allocator,
    io: std.Io,
    source: Source,
    target: []const u8,
    output: []const u8,
) ![]const u8 {
    const bytes = try prepare(a, source.bytes, target);
    try retain(a, io, output, source, bytes);
    return std.json.Stringify.valueAlloc(a, .{
        .version = target,
        .changed = !std.mem.eql(u8, bytes, source.bytes),
    }, .{});
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next() orelse return error.MissingCommand;
    const input = args.next() orelse return error.MissingManifest;
    const source = try readSource(a, init.io, input);
    const result = if (std.mem.eql(u8, command, "read")) result: {
        if (args.next() != null) return error.UnexpectedArgument;
        break :result try std.json.Stringify.valueAlloc(a, .{
            .version = try read(a, source.bytes),
        }, .{});
    } else if (std.mem.eql(u8, command, "prepare")) result: {
        const target = args.next() orelse return error.MissingVersion;
        const output = args.next() orelse return error.MissingOutput;
        if (args.next() != null) return error.UnexpectedArgument;
        break :result try prepareFile(a, init.io, source, target, output);
    } else return error.UnknownCommand;
    try std.Io.File.stdout().writeStreamingAll(init.io, result);
}

test "manifest preparation changes only the semantic root version literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\.{
        \\  .name = .horos, .version = "8.0.0",
        \\  .minimum_zig_version = "0.17.0",
        \\  .dependencies = .{.peer = .{.version="8.0.0", .url="https://host/8.0.0"}},
        \\  .paths = .{"version", "8.0.0"}, .fingerprint = 0x7039c7146825577e,
        \\}
    ;
    const expected =
        \\.{
        \\  .name = .horos, .version = "8.0.1",
        \\  .minimum_zig_version = "0.17.0",
        \\  .dependencies = .{.peer = .{.version="8.0.0", .url="https://host/8.0.0"}},
        \\  .paths = .{"version", "8.0.0"}, .fingerprint = 0x7039c7146825577e,
        \\}
    ;
    try std.testing.expectEqualStrings("8.0.0", try read(a, source));
    try std.testing.expectEqualStrings(expected, try prepare(a, source, "8.0.1"));
    try std.testing.expectEqualStrings(source, try prepare(a, source, "8.0.0"));
}

test "quoted field names and escaped literals retain byte identity on semantic noops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = ".{ .@\"version\" = \"8\\x2e0.0\", .label = \"version\" }";
    try std.testing.expectEqualStrings("8.0.0", try read(a, source));
    try std.testing.expectEqualStrings(source, try prepare(a, source, "8.0.0"));
    try std.testing.expectEqualStrings(
        ".{ .@\"version\" = \"9.0.0\", .label = \"version\" }",
        try prepare(a, source, "9.0.0"),
    );
}

test "duplicate fields and malformed unrelated values cannot enter a candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{
        ".{.version=\"1.0.0\",.version=\"2.0.0\"}",
        ".{.version=\"1.0.0\",.@\"version\"=\"1.0.0\"}",
        ".{.version=\"1.0.0\",.other=\"\\q\"}",
        ".{.version=\"1.0.0\",.other=.{.a=1,.a=2}}",
        ".{.version=123}",
        ".{.name=.horos}",
        ".{.version=\"1.0.0\",.bad=@import(\"other\")}",
        ".{.version=\"1.0.0\"} trailing",
    }) |source| {
        try std.testing.expectError(error.ParseZon, prepare(a, source, "2.0.0"));
    }
}

test "version syntax rejects noncanonical and unsupported decisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "01.2.3", "1.2", "v1.2.3", "1.2.3\"", "-1.2.3" }) |version| {
        try std.testing.expectError(
            error.InvalidVersion,
            prepare(a, ".{.version=\"1.0.0\"}", version),
        );
    }
    for ([_][]const u8{ "1.2.3-rc.1", "1.2.3+build", "9007199254740992.0.0" }) |version| {
        try std.testing.expectError(
            error.UnsupportedVersion,
            prepare(a, ".{.version=\"1.0.0\"}", version),
        );
    }
}

test "candidate failures preserve input and existing output while repeated preparation converges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const original = ".{.version=\"8.0.0\",.name=.horos}";
    try temporary.dir.writeFile(io, .{ .sub_path = "input.zon", .data = original });
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    const input = try std.fs.path.join(a, &.{ root, "input.zon" });
    const output = try std.fs.path.join(a, &.{ root, "output.zon" });
    const source = try readSource(a, io, input);
    try std.testing.expectError(
        error.InvalidVersion,
        prepareFile(a, io, source, "invalid", output),
    );
    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, output, .{}));
    _ = try prepareFile(a, io, source, "8.0.1", output);
    const candidate = try readSource(a, io, output);
    try std.testing.expectEqualStrings("8.0.1", try read(a, candidate.bytes));
    try std.testing.expectEqualStrings(original, (try readSource(a, io, input)).bytes);
    _ = try prepareFile(a, io, source, "8.0.1", output);
    try std.testing.expectEqualStrings(candidate.bytes, (try readSource(a, io, output)).bytes);
    try std.testing.expectError(
        error.CandidateCollision,
        prepareFile(a, io, source, "8.0.2", output),
    );
    try std.testing.expectEqualStrings(candidate.bytes, (try readSource(a, io, output)).bytes);
    try std.testing.expectError(
        error.CandidateCollision,
        prepareFile(a, io, source, "8.0.1", input),
    );
    try std.testing.expectEqualStrings(original, (try readSource(a, io, input)).bytes);
}

test "manifest work is bounded before semantic parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const oversized = try a.allocSentinel(u8, maximum_bytes + 1, 0);
    @memset(oversized, ' ');
    try std.testing.expectError(error.ManifestTooLarge, read(a, oversized));
    var nested: std.Io.Writer.Allocating = .init(a);
    for (0..65) |_| try nested.writer.writeAll(".{");
    for (0..65) |_| try nested.writer.writeAll("}");
    const source = try a.dupeSentinel(u8, nested.written(), 0);
    try std.testing.expectError(error.ManifestTooDeep, read(a, source));
}
