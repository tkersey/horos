const std = @import("std");
const Dir = std.Io.Dir;
const maximum_bytes = 64 << 20;
const maximum_files = 10000;

const Entry = struct {
    path: []const u8,
    blob: []const u8,
    mode: u32,
    bytes: ?[]const u8 = null,
};

pub const File = struct { path: []const u8, blob: []const u8, mode: u32 };

pub const Snapshot = struct {
    files: []const File,
    commit: []const u8,
    tree: []const u8,
    archive: []const u8,
    sha256: []const u8,
    size: usize,
    source: []const u8,
};

fn identity(bytes: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, bytes, "\r\n");
    if (value.len != 40) return error.InvalidGitIdentity;
    for (value) |byte| if (!std.ascii.isDigit(byte) and
        !(byte >= 'a' and byte <= 'f')) return error.InvalidGitIdentity;
    return value;
}

fn safePath(path: []const u8) !void {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes or
        std.mem.indexOfAny(u8, path, "\\\x00") != null or
        !std.unicode.utf8ValidateSlice(path)) return error.InvalidSourcePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, "..") or
            std.ascii.eqlIgnoreCase(part, ".git")) return error.InvalidSourcePath;
    }
}

fn gitMode(mode: []const u8) !u32 {
    if (std.mem.eql(u8, mode, "100644")) return 0o644;
    if (std.mem.eql(u8, mode, "100755")) return 0o755;
    return error.UnsupportedGitMode;
}

fn inventory(r: anytype, repository: []const u8, commit: []const u8) ![]Entry {
    const result = try r.run(
        &.{ "git", "--no-replace-objects", "ls-tree", "-rz", "--full-tree", commit },
        repository,
        true,
    );
    var entries: std.ArrayList(Entry) = .empty;
    var records = std.mem.splitScalar(u8, result.stdout, 0);
    while (records.next()) |record| {
        if (record.len == 0) {
            if (records.next() != null) return error.InvalidGitInventory;
            break;
        }
        if (entries.items.len == maximum_files or record.len < 54 or
            !std.mem.eql(u8, record[6..12], " blob ") or
            record[52] != '\t') return error.InvalidGitInventory;
        const mode = try gitMode(record[0..6]);
        const path = record[53..];
        try safePath(path);
        try entries.append(r.a, .{
            .path = path,
            .blob = try identity(record[12..52]),
            .mode = mode,
        });
    }
    if (entries.items.len == 0) return error.EmptyGitInventory;
    return entries.toOwnedSlice(r.a);
}

fn verifyBlob(expected: []const u8, bytes: []const u8) !void {
    var hash = std.crypto.hash.Sha1.init(.{});
    var buffer: [64]u8 = undefined;
    hash.update(try std.fmt.bufPrint(&buffer, "blob {d}\x00", .{bytes.len}));
    hash.update(bytes);
    const actual = std.fmt.bytesToHex(hash.finalResult(), .lower);
    if (!std.mem.eql(u8, expected, &actual)) return error.GitBlobMismatch;
}

fn tarSize(raw: *const [12]u8) !u64 {
    if (raw[0] == 0xff) return error.TarNumericValueNegative;
    if (raw[0] == 0x80) {
        if (raw[1] != 0 or raw[2] != 0 or raw[3] != 0)
            return error.TarNumericValueTooBig;
        return std.mem.readInt(u64, raw[4..12], .big);
    }
    const start = std.mem.trimStart(u8, raw, "0 ");
    const digits = std.mem.trimEnd(u8, start, " \x00");
    if (digits.len == 0) return 0;
    return std.fmt.parseInt(u64, digits, 8) catch return error.TarHeader;
}

fn paxSize(bytes: []const u8) !u64 {
    var offset: usize = 0;
    var size: u64 = 0;
    while (offset < bytes.len) {
        const remaining = bytes[offset..];
        const separator = std.mem.indexOfScalar(u8, remaining, ' ') orelse
            return error.UnexpectedEndOfStream;
        const length = try std.fmt.parseInt(usize, remaining[0..separator], 10);
        if (length > remaining.len or length <= separator + 1)
            return error.UnexpectedEndOfStream;
        const record = remaining[separator + 1 .. length];
        const equals = std.mem.indexOfScalar(u8, record, '=') orelse
            return error.UnexpectedEndOfStream;
        if (record.len < equals + 2 or record[record.len - 1] != '\n')
            return error.UnexpectedEndOfStream;
        const keyword = record[0..equals];
        if (std.mem.indexOfScalar(u8, keyword, 0) != null) return error.PaxNullInKeyword;
        if (std.mem.eql(u8, keyword, "size")) {
            const value = record[equals + 1 .. record.len - 1];
            if (value.len > 64) return error.PaxSizeAttrOverflow;
            size = try std.fmt.parseInt(u64, value, 10);
            if (size > maximum_bytes) return error.SourceTooLarge;
        }
        offset += length;
    }
    return size;
}

fn tarFraming(bytes: []const u8) !void {
    if (bytes.len > maximum_bytes) return error.SourceTooLarge;
    var offset: usize = 0;
    var extended_size: u64 = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 512) return error.UnexpectedEndOfStream;
        const header = bytes[offset..][0..512];
        if (std.mem.allEqual(u8, header, 0)) return;
        offset += 512;
        const raw_size = try tarSize(header[124..136]);
        if (raw_size > maximum_bytes) return error.SourceTooLarge;
        var payload = raw_size;
        switch (header[156]) {
            0, '0', '2', '5' => {
                if (extended_size != 0) payload = extended_size;
                extended_size = 0;
            },
            'x' => {
                if (raw_size > bytes.len - offset) return error.UnexpectedEndOfStream;
                extended_size = try paxSize(bytes[offset..][0..@intCast(raw_size)]);
            },
            'g', 'L', 'K' => {},
            else => return error.TarUnsupportedHeader,
        }
        if (payload > bytes.len - offset) return error.UnexpectedEndOfStream;
        offset += @intCast(payload);
        const padding: usize = @intCast((512 - payload % 512) % 512);
        if (padding > bytes.len - offset) return error.UnexpectedEndOfStream;
        offset += padding;
    }
}

fn admit(r: anytype, entries: []Entry, bytes: []const u8) !void {
    try tarFraming(bytes);
    for (entries) |*entry| entry.bytes = null;
    var reader = std.Io.Reader.fixed(bytes);
    var name: [std.fs.max_path_bytes]u8 = undefined;
    var link: [std.fs.max_path_bytes]u8 = undefined;
    var iterator = std.tar.Iterator.init(&reader, .{
        .file_name_buffer = &name,
        .link_name_buffer = &link,
    });
    var indexed: std.StringHashMapUnmanaged(usize) = .empty;
    defer indexed.deinit(r.a);
    var directories: std.StringHashMapUnmanaged(void) = .empty;
    defer directories.deinit(r.a);
    for (entries, 0..) |entry, index| {
        try indexed.put(r.a, entry.path, index);
        for (entry.path, 0..) |byte, offset| {
            if (byte == '/') try directories.put(r.a, entry.path[0..offset], {});
        }
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(r.a);
    while (try iterator.next()) |file| {
        const path = if (file.kind == .directory)
            std.mem.trimEnd(u8, file.name, "/")
        else
            file.name;
        try safePath(path);
        if (seen.contains(path)) return error.DuplicateSourcePath;
        try seen.put(r.a, try r.a.dupe(u8, path), {});
        if (file.kind == .directory) {
            if (file.size != 0 or !directories.contains(path))
                return error.InvalidSourceDirectory;
            continue;
        }
        if (file.kind != .file or file.link_name.len != 0) return error.UnsupportedSourceKind;
        const entry = &entries[indexed.get(path) orelse return error.UntrackedSourcePath];
        if (file.mode & 0o7777 != entry.mode) return error.GitModeMismatch;
        if (file.size > maximum_bytes or file.size > reader.buffer.len - reader.seek)
            return error.SourceTooLarge;
        const content = try reader.take(@intCast(file.size));
        iterator.unread_file_bytes = 0;
        try verifyBlob(entry.blob, content);
        entry.bytes = content;
    }
    for (entries) |entry| if (entry.bytes == null) return error.MissingSourcePath;
}

fn canonical(r: anytype, entries: []const Entry) ![]const u8 {
    var buffer = std.Io.Writer.Allocating.init(r.a);
    var writer: std.tar.Writer = .{ .underlying_writer = &buffer.writer };
    for (entries) |entry| try writer.writeFileBytes(
        entry.path,
        entry.bytes orelse return error.MissingSourcePath,
        .{ .mode = entry.mode, .mtime = 0 },
    );
    try writer.finishPedantically();
    if (buffer.written().len > maximum_bytes) return error.SourceTooLarge;
    return buffer.toOwnedSlice();
}

fn extract(r: anytype, entries: []const Entry, source: []const u8) !void {
    try Dir.cwd().createDir(r.io, source, .fromMode(0o700));
    errdefer Dir.cwd().deleteTree(r.io, source) catch |err|
        std.log.err("source cleanup failed: {s}", .{@errorName(err)});
    var root = try Dir.cwd().openDir(r.io, source, .{
        .follow_symlinks = false,
        .iterate = true,
    });
    defer root.close(r.io);
    for (entries) |entry| {
        if (std.fs.path.dirname(entry.path)) |parent| try root.createDirPath(r.io, parent);
        var file = try root.createFile(r.io, entry.path, .{ .exclusive = true });
        defer file.close(r.io);
        try file.writeStreamingAll(r.io, entry.bytes.?);
        try file.setPermissions(r.io, .fromMode(@intCast(entry.mode)));
    }
    try verifyNamespace(r, root, entries);
}

fn verifyNamespace(r: anytype, root: Dir, entries: []const Entry) !void {
    var expected: std.StringHashMapUnmanaged(std.Io.File.Kind) = .empty;
    defer expected.deinit(r.a);
    for (entries) |entry| {
        try expected.put(r.a, entry.path, .file);
        for (entry.path, 0..) |byte, offset| {
            if (byte == '/') try expected.put(r.a, entry.path[0..offset], .directory);
        }
    }
    var directories: std.ArrayList([]const u8) = .empty;
    defer directories.deinit(r.a);
    try directories.append(r.a, "");
    var cursor: usize = 0;
    while (cursor < directories.items.len) : (cursor += 1) {
        const path = directories.items[cursor];
        var directory = try root.openDir(r.io, if (path.len == 0) "." else path, .{
            .follow_symlinks = false,
            .iterate = true,
        });
        defer directory.close(r.io);
        var iterator = directory.iterate();
        while (try iterator.next(r.io)) |entry| {
            const actual = try r.path(&.{ path, entry.name });
            defer r.a.free(actual);
            const admitted = expected.fetchRemove(actual) orelse
                return error.SourceNamespaceMismatch;
            const stat = try directory.statFile(r.io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind != admitted.value) return error.SourceNamespaceMismatch;
            if (stat.kind == .directory) try directories.append(r.a, admitted.key);
        }
    }
    if (expected.count() != 0) return error.SourceNamespaceMismatch;
}

fn stable(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.kind == b.kind and
        a.permissions == b.permissions and std.meta.eql(a.mtime, b.mtime) and
        std.meta.eql(a.ctime, b.ctime);
}

fn openRegular(io: std.Io, directory: Dir, path: []const u8, writable: bool) !std.Io.File {
    const descriptor = try std.posix.openat(directory.handle, path, .{
        .ACCMODE = if (writable) .RDWR else .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    }, 0);
    const file: std.Io.File = .{ .handle = descriptor, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);
    const kind = (try file.stat(io)).kind;
    if (kind == .directory) return error.IsDir;
    if (kind != .file) return error.NonregularFile;
    return file;
}

pub fn compilerPlatform() []const u8 {
    return std.fmt.comptimePrint("{s}-{s}", .{
        @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch),
    });
}

pub fn compilerSha256(r: anytype, supplied: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(supplied)) return error.AbsolutePathRequired;
    const path = try Dir.cwd().realPathFileAlloc(r.io, supplied, r.a);
    var file = openRegular(r.io, .cwd(), path, false) catch |err| {
        if (err == error.NonregularFile) return error.InvalidCompilerExecutable;
        return err;
    };
    defer file.close(r.io);
    const before = try file.stat(r.io);
    if (before.kind != .file or before.size == 0 or before.size > 512 << 20)
        return error.InvalidCompilerExecutable;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var reader = file.reader(r.io, &.{});
    var buffer: [32768]u8 = undefined;
    var remaining = before.size;
    while (remaining > 0) {
        const length: usize = @intCast(@min(remaining, buffer.len));
        try reader.interface.readSliceAll(buffer[0..length]);
        hash.update(buffer[0..length]);
        remaining -= length;
    }
    const after = try file.stat(r.io);
    const named = try Dir.cwd().statFile(r.io, path, .{ .follow_symlinks = false });
    if (!stable(before, after) or !stable(after, named)) return error.SourceChanged;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return r.a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn copyCompiler(r: anytype, original: []const u8, destination: []const u8) ![]const u8 {
    var input = openRegular(r.io, .cwd(), original, false) catch |err| {
        if (err == error.NonregularFile) return error.InvalidCompilerExecutable;
        return err;
    };
    defer input.close(r.io);
    const before = try input.stat(r.io);
    if (before.size == 0 or before.size > 512 << 20 or
        before.permissions.toMode() & 0o111 == 0) return error.InvalidCompilerExecutable;
    var output = try Dir.cwd().createFile(r.io, destination, .{ .exclusive = true });
    defer output.close(r.io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var reader = input.reader(r.io, &.{});
    var buffer: [32768]u8 = undefined;
    var remaining = before.size;
    while (remaining > 0) {
        const length: usize = @intCast(@min(remaining, buffer.len));
        try reader.interface.readSliceAll(buffer[0..length]);
        hash.update(buffer[0..length]);
        try output.writeStreamingAll(r.io, buffer[0..length]);
        remaining -= length;
    }
    const after = try input.stat(r.io);
    const named = try Dir.cwd().statFile(r.io, original, .{ .follow_symlinks = false });
    if (!stable(before, after) or !stable(after, named)) return error.SourceChanged;
    try output.setPermissions(r.io, .fromMode(0o500));
    return r.a.dupe(u8, &std.fmt.bytesToHex(hash.finalResult(), .lower));
}

pub const CapturedCompiler = struct {
    path: []const u8,
    sha256: []const u8,
    directory: []const u8,
    env: std.process.Environ.Map,

    pub fn acquire(
        r: anytype,
        supplied: []const u8,
        parent: []const u8,
        environ: ?*const std.process.Environ.Map,
    ) !CapturedCompiler {
        if (!std.fs.path.isAbsolute(supplied)) return error.AbsolutePathRequired;
        const original = try Dir.cwd().realPathFileAlloc(r.io, supplied, r.a);
        const directory = try r.path(&.{ parent, "compiler" });
        try Dir.cwd().createDir(r.io, directory, .fromMode(0o700));
        errdefer Dir.cwd().deleteTree(r.io, directory) catch |err|
            std.log.err("compiler cleanup failed: {s}", .{@errorName(err)});
        const path = try r.path(&.{ directory, "zig" });
        const sha256 = try copyCompiler(r, original, path);
        var env = if (environ) |value| try value.clone(r.a) else std.process.Environ.Map.init(r.a);
        errdefer env.deinit();
        if (!env.contains("ZIG_LIB_DIR")) {
            const cwd = try Dir.cwd().realPathFileAlloc(r.io, ".", r.a);
            if (std.zig.findZigLibDirFromSelfExe(r.a, r.io, cwd, original)) |library| {
                defer library.handle.close(r.io);
                const absolute = try library.handle.realPathFileAlloc(r.io, ".", r.a);
                try env.put("ZIG_LIB_DIR", absolute);
            } else |err| {
                if (err != error.FileNotFound) return err;
            }
        }
        return .{ .path = path, .sha256 = sha256, .directory = directory, .env = env };
    }

    pub fn close(compiler: *CapturedCompiler, io: std.Io) void {
        compiler.env.deinit();
        Dir.cwd().deleteTree(io, compiler.directory) catch |err|
            std.log.err("compiler cleanup failed: {s}", .{@errorName(err)});
        compiler.* = undefined;
    }
};

pub fn readArchive(r: anytype, path: []const u8) ![]const u8 {
    return readBounded(r, path, maximum_bytes);
}

pub fn readBounded(r: anytype, path: []const u8, limit: usize) ![]const u8 {
    var file = openRegular(r.io, .cwd(), path, false) catch |err| {
        if (err == error.NonregularFile) return error.InvalidSourceArchive;
        return err;
    };
    defer file.close(r.io);
    const before = try file.stat(r.io);
    if (before.kind != .file or before.size > limit) return error.InvalidSourceArchive;
    var reader = file.reader(r.io, &.{});
    const bytes = try reader.interface.allocRemaining(r.a, .limited(limit));
    const after = try file.stat(r.io);
    const named = try Dir.cwd().statFile(r.io, path, .{ .follow_symlinks = false });
    if (!stable(before, after) or !stable(after, named) or bytes.len != before.size)
        return error.SourceChanged;
    return bytes;
}

pub fn testedArchive(r: anytype, snapshot: Snapshot) ![]const u8 {
    const bytes = try readArchive(r, snapshot.archive);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (bytes.len != snapshot.size or !std.mem.eql(
        u8,
        snapshot.sha256,
        &std.fmt.bytesToHex(digest, .lower),
    )) return error.SourceChanged;
    return bytes;
}

pub fn retain(r: anytype, path: []const u8, bytes: []const u8) !bool {
    var file = Dir.cwd().createFile(r.io, path, .{ .exclusive = true }) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        if (!std.mem.eql(u8, bytes, try readArchive(r, path))) {
            return error.ReleaseArtifactCollision;
        }
        return false;
    };
    defer file.close(r.io);
    errdefer Dir.cwd().deleteFile(r.io, path) catch |err|
        std.log.err("retained file cleanup failed: {s}", .{@errorName(err)});
    try file.writeStreamingAll(r.io, bytes);
    return true;
}

pub const BuildOutput = struct {
    directory: Dir,
    lock: std.Io.File,

    pub fn acquire(r: anytype, path: []const u8) !BuildOutput {
        try Dir.cwd().createDirPath(r.io, path);
        const directory = try Dir.cwd().openDir(r.io, path, .{ .follow_symlinks = false });
        errdefer directory.close(r.io);
        const lock_path = ".release.lock";
        const lock = directory.createFile(r.io, lock_path, .{
            .exclusive = true,
        }) catch |err| blk: {
            if (err != error.PathAlreadyExists) return err;
            break :blk openRegular(r.io, directory, lock_path, true) catch |open_error| {
                if (open_error == error.NonregularFile) return error.InvalidBuildOutputLock;
                return open_error;
            };
        };
        errdefer lock.close(r.io);
        if ((try lock.stat(r.io)).kind != .file) return error.InvalidBuildOutputLock;
        if (!try lock.tryLock(r.io, .exclusive)) return error.BuildOutputBusy;
        return .{ .directory = directory, .lock = lock };
    }

    pub fn close(output: BuildOutput, io: std.Io) void {
        output.lock.unlock(io);
        output.lock.close(io);
        output.directory.close(io);
    }

    fn regular(output: BuildOutput, io: std.Io, name: []const u8) !void {
        const stat = output.directory.statFile(io, name, .{
            .follow_symlinks = false,
        }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        if (stat.kind != .file) return error.InvalidBuildOutput;
    }

    pub fn retain(output: BuildOutput, io: std.Io, archive: []const u8, receipt: []const u8) !void {
        try output.regular(io, "source.tar");
        try output.regular(io, "source.json");
        var staged_archive = try output.directory.createFileAtomic(io, "source.tar", .{
            .replace = true,
        });
        defer staged_archive.deinit(io);
        var staged_receipt = try output.directory.createFileAtomic(io, "source.json", .{
            .replace = true,
        });
        defer staged_receipt.deinit(io);
        try staged_archive.file.writeStreamingAll(io, archive);
        try staged_receipt.file.writeStreamingAll(io, receipt);
        try output.regular(io, "source.tar");
        try output.regular(io, "source.json");
        output.directory.deleteFile(io, "source.json") catch |err| {
            if (err != error.FileNotFound) return err;
        };
        try staged_archive.replace(io);
        try staged_receipt.replace(io);
    }
};

pub fn prepare(r: anytype, repository: []const u8, output: []const u8) !Snapshot {
    const commit = try identity((try r.run(
        &.{ "git", "--no-replace-objects", "rev-parse", "HEAD" },
        repository,
        true,
    )).stdout);
    const tree_ref = try std.fmt.allocPrint(r.a, "{s}^{{tree}}", .{commit});
    const tree = try identity((try r.run(
        &.{ "git", "--no-replace-objects", "rev-parse", tree_ref },
        repository,
        true,
    )).stdout);
    const entries = try inventory(r, repository, commit);
    const original = try r.run(
        &.{
            "git",     "--no-replace-objects", "-c",   "tar.umask=0022",
            "archive", "--format=tar",         commit,
        },
        repository,
        true,
    );
    try admit(r, entries, original.stdout);
    const bytes = try canonical(r, entries);
    const archive = try r.path(&.{ output, "source.tar" });
    try r.write(archive, bytes);
    return verify(r, repository, commit, tree, archive, try r.path(&.{ output, "source" }));
}

pub fn verify(
    r: anytype,
    repository: []const u8,
    commit: []const u8,
    tree: []const u8,
    archive: []const u8,
    source: []const u8,
) !Snapshot {
    _ = try identity(commit);
    _ = try identity(tree);
    const object_kind = try r.run(
        &.{ "git", "--no-replace-objects", "cat-file", "-t", commit },
        repository,
        true,
    );
    if (!std.mem.eql(u8, object_kind.stdout, "commit\n")) return error.ExpectedGitCommit;
    const tree_ref = try std.fmt.allocPrint(r.a, "{s}^{{tree}}", .{commit});
    const actual_tree = try identity((try r.run(&.{
        "git", "--no-replace-objects", "rev-parse", tree_ref,
    }, repository, true)).stdout);
    if (!std.mem.eql(u8, actual_tree, tree)) return error.GitTreeMismatch;
    const entries = try inventory(r, repository, commit);
    const bytes = try readArchive(r, archive);
    try admit(r, entries, bytes);
    if (!std.mem.eql(u8, bytes, try canonical(r, entries))) return error.NoncanonicalSourceArchive;
    try extract(r, entries, source);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const files = try r.a.alloc(File, entries.len);
    for (entries, files) |entry, *file| {
        file.* = .{ .path = entry.path, .blob = entry.blob, .mode = entry.mode };
    }
    return .{
        .files = files,
        .commit = commit,
        .tree = tree,
        .archive = archive,
        .sha256 = try r.a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)),
        .size = bytes.len,
        .source = source,
    };
}

const TestRunner = struct {
    a: std.mem.Allocator,
    io: std.Io = std.testing.io,
    env: ?*const std.process.Environ.Map = null,

    pub fn run(
        r: TestRunner,
        argv: []const []const u8,
        cwd: []const u8,
        success: bool,
    ) !std.process.RunResult {
        const result = try std.process.run(r.a, r.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = r.env,
            .stdout_limit = .limited(maximum_bytes),
            .stderr_limit = .limited(maximum_bytes),
        });
        if (result.term != .exited or (result.term.exited == 0) != success) {
            std.debug.print("{s}", .{result.stderr});
            return error.ProcessFailed;
        }
        return result;
    }
    pub fn path(r: TestRunner, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(r.a, parts);
    }
    pub fn write(r: TestRunner, path_name: []const u8, bytes: []const u8) !void {
        try Dir.cwd().writeFile(r.io, .{ .sub_path = path_name, .data = bytes });
    }
};

fn fixture(r: TestRunner, root: []const u8) !void {
    _ = try r.run(&.{ "git", "init", "--quiet", root }, ".", true);
    try r.write(try r.path(&.{ root, "ordinary" }), "source\n");
    try r.write(try r.path(&.{ root, "executable" }), "#!/bin/sh\nexit 0\n");
    _ = try r.run(&.{ "git", "add", "." }, root, true);
    _ = try r.run(&.{ "git", "update-index", "--chmod=+x", "executable" }, root, true);
    try commitFixture(r, root);
}

fn commitFixture(r: TestRunner, root: []const u8) !void {
    const author = "user.name=Fixture";
    const email = "user.email=fixture@example.invalid";
    _ = try r.run(&.{
        "git",     "-c",                   author,   "-c",      email,
        "-c",      "commit.gpgsign=false", "commit", "--quiet", "-m",
        "fixture",
    }, root, true);
}

fn temporary(r: TestRunner) ![]const u8 {
    const result = try r.run(&.{ "mktemp", "-d" }, ".", true);
    return std.mem.trim(u8, result.stdout, "\r\n");
}

fn removeFixture(r: TestRunner, path: []const u8) void {
    Dir.cwd().deleteTree(r.io, path) catch |err|
        std.debug.panic("fixture cleanup failed: {s}", .{@errorName(err)});
}

test "full Git archive is deterministic and retains executable modes and exact blobs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    const one = try r.path(&.{ root, "one" });
    const two = try r.path(&.{ root, "two" });
    try Dir.cwd().createDirPath(r.io, one);
    try Dir.cwd().createDirPath(r.io, two);
    const first = try prepare(r, repo, one);
    const second = try prepare(r, repo, two);
    try std.testing.expectEqualStrings(first.sha256, second.sha256);
    try std.testing.expectEqualStrings(
        try readArchive(r, first.archive),
        try readArchive(r, second.archive),
    );
    try std.testing.expectEqual(@as(usize, 2), first.files.len);
    try std.testing.expectEqual(@as(u32, 0o755), first.files[0].mode);
    const executable_path = try r.path(&.{ first.source, "executable" });
    var executable = try Dir.cwd().openFile(r.io, executable_path, .{});
    defer executable.close(r.io);
    const mode = (try executable.stat(r.io)).permissions.toMode() & 0o7777;
    try std.testing.expectEqual(@as(u32, 0o755), mode);
    const corruption = try r.a.dupe(u8, try readArchive(r, first.archive));
    corruption[512] ^= 1;
    try r.write(first.archive, corruption);
    try std.testing.expectError(error.GitBlobMismatch, verify(
        r,
        repo,
        first.commit,
        first.tree,
        first.archive,
        try r.path(&.{ root, "rejected" }),
    ));
}

fn rejectArchive(
    r: TestRunner,
    repo: []const u8,
    snapshot: Snapshot,
    bytes: []const u8,
    expected: anyerror,
) !void {
    const corrupted = try r.path(&.{ repo, "corrupted.tar" });
    const destination = try r.path(&.{ repo, "rejected" });
    try r.write(corrupted, bytes);
    try std.testing.expectError(expected, verify(
        r,
        repo,
        snapshot.commit,
        snapshot.tree,
        corrupted,
        destination,
    ));
    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(r.io, destination, .{}));
}

test "archive corruption cannot add paths change modes omit files or repeat paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    const prepared = try prepare(r, repo, root);
    const original = try readArchive(r, prepared.archive);
    const entries = try inventory(r, repo, prepared.commit);
    try admit(r, entries, original);
    const expected_mode = entries[0].mode;
    entries[0].mode = 0o644;
    const wrong_mode = try canonical(r, entries);
    entries[0].mode = expected_mode;
    try rejectArchive(r, repo, prepared, wrong_mode, error.GitModeMismatch);
    try admit(r, entries, original);
    const missing = try canonical(r, entries[0..1]);
    entries[1].bytes = null;
    try rejectArchive(r, repo, prepared, missing, error.MissingSourcePath);
    try admit(r, entries, original);
    const duplicate = try canonical(r, &.{ entries[0], entries[0], entries[1] });
    try rejectArchive(r, repo, prepared, duplicate, error.DuplicateSourcePath);
    try admit(r, entries, original);
    entries[0].path = "../escape";
    const traversal = try canonical(r, entries);
    try rejectArchive(r, repo, prepared, traversal, error.InvalidSourcePath);
}

test "Git export attributes cannot silently remove or substitute tracked source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    try r.write(try r.path(&.{ repo, ".gitattributes" }), "ordinary export-ignore\n");
    _ = try r.run(&.{ "git", "add", "." }, repo, true);
    try commitFixture(r, repo);
    try std.testing.expectError(error.MissingSourcePath, prepare(r, repo, root));
    try r.write(try r.path(&.{ repo, ".gitattributes" }), "ordinary export-subst\n");
    try r.write(try r.path(&.{ repo, "ordinary" }), "$Format:%H$\n");
    _ = try r.run(&.{ "git", "add", "." }, repo, true);
    try commitFixture(r, repo);
    try std.testing.expectError(error.GitBlobMismatch, prepare(r, repo, root));
}

test "source admission rejects Git symlinks and noncanonical trailing archive data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    const prepared = try prepare(r, repo, root);
    const original = try readArchive(r, prepared.archive);
    const trailing = try std.mem.concat(r.a, u8, &.{ original, "extra" });
    try r.write(prepared.archive, trailing);
    try std.testing.expectError(error.NoncanonicalSourceArchive, verify(
        r,
        repo,
        prepared.commit,
        prepared.tree,
        prepared.archive,
        try r.path(&.{ root, "rejected" }),
    ));
    _ = try r.run(&.{ "ln", "-s", "ordinary", "linked" }, repo, true);
    _ = try r.run(&.{ "git", "add", "linked" }, repo, true);
    try commitFixture(r, repo);
    try std.testing.expectError(error.UnsupportedGitMode, prepare(r, repo, root));
}

test "archive symlink entries fail before extraction even with a matching name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    var buffer = std.Io.Writer.Allocating.init(r.a);
    var writer: std.tar.Writer = .{ .underlying_writer = &buffer.writer };
    try writer.writeLink("ordinary", "../../escape", .{});
    try writer.finishPedantically();
    var entries = [_]Entry{.{
        .path = "ordinary",
        .blob = "0000000000000000000000000000000000000000",
        .mode = 0o644,
    }};
    try std.testing.expectError(error.UnsupportedSourceKind, admit(r, &entries, buffer.written()));
}

test "retained source artifacts converge on identical bytes and preserve collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const path = try r.path(&.{ root, "asset" });
    try std.testing.expect(try retain(r, path, "accepted"));
    try std.testing.expect(!try retain(r, path, "accepted"));
    try std.testing.expectError(error.ReleaseArtifactCollision, retain(r, path, "different"));
    try std.testing.expectEqualStrings("accepted", try readArchive(r, path));
}

test "build-owned output replaces changed heads and producers with exclusive ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const path = try r.path(&.{ root, "build" });
    {
        const owner = try BuildOutput.acquire(r, path);
        defer owner.close(r.io);
        try owner.retain(r.io, "head-one", "producer-one");
        try std.testing.expectError(error.BuildOutputBusy, BuildOutput.acquire(r, path));
    }
    const owner = try BuildOutput.acquire(r, path);
    defer owner.close(r.io);
    try std.testing.expectEqualStrings("head-one", try readArchive(
        r,
        try r.path(&.{ path, "source.tar" }),
    ));
    try owner.retain(r.io, "head-two", "producer-one-next-head");
    try owner.retain(r.io, "head-two", "producer-two-next-head");
    try std.testing.expectEqualStrings("head-two", try readArchive(
        r,
        try r.path(&.{ path, "source.tar" }),
    ));
    try std.testing.expectEqualStrings("producer-two-next-head", try readArchive(
        r,
        try r.path(&.{ path, "source.json" }),
    ));
}

test "build-owned output rejects special destinations before replacing either accepted file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const path = try r.path(&.{ root, "build" });
    const owner = try BuildOutput.acquire(r, path);
    defer owner.close(r.io);
    try owner.retain(r.io, "accepted", "accepted-receipt");
    const receipt = try r.path(&.{ path, "source.json" });
    const outside = try r.path(&.{ root, "outside" });
    try r.write(outside, "preserved");
    try Dir.cwd().deleteFile(r.io, receipt);
    try Dir.cwd().symLink(r.io, outside, receipt, .{});
    try std.testing.expectError(error.InvalidBuildOutput, owner.retain(r.io, "wrong", "wrong"));
    try std.testing.expectEqualStrings("accepted", try readArchive(
        r,
        try r.path(&.{ path, "source.tar" }),
    ));
    try std.testing.expectEqualStrings("preserved", try readArchive(r, outside));
    try Dir.cwd().deleteFile(r.io, receipt);
    try Dir.cwd().createDir(r.io, receipt, .fromMode(0o700));
    try std.testing.expectError(error.InvalidBuildOutput, owner.retain(r.io, "wrong", "wrong"));
}

test "compiler identity hashes exact bounded bytes and rejects empty or relative input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const path = try r.path(&.{ root, "compiler" });
    try r.write(path, "abc");
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        try compilerSha256(r, path),
    );
    try r.write(path, "");
    try std.testing.expectError(error.InvalidCompilerExecutable, compilerSha256(r, path));
    try std.testing.expectError(error.AbsolutePathRequired, compilerSha256(r, "relative"));
    try std.testing.expect(compilerPlatform().len > 0);
}

fn checksumHeader(header: *[512]u8) !void {
    @memset(header[148..156], ' ');
    var sum: u32 = 0;
    for (header) |byte| sum += byte;
    _ = try std.fmt.bufPrint(header[148..155], "{o:0>7}", .{sum});
    header[155] = 0;
}

fn framingHeader(kind: u8, size: u64) ![512]u8 {
    var header = std.tar.Writer.Header.init(.regular);
    try header.setSize(size);
    var bytes: [512]u8 = undefined;
    @memcpy(&bytes, std.mem.asBytes(&header));
    bytes[0] = 'x';
    bytes[156] = kind;
    try checksumHeader(&bytes);
    return bytes;
}

test "raw binary TAR sizes fail before iterator padding arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    var header = try framingHeader('0', 0);
    @memset(header[124..136], 0);
    header[124] = 0x80;
    @memset(header[128..136], 0xff);
    try checksumHeader(&header);
    var entries: [0]Entry = .{};
    try std.testing.expectError(error.SourceTooLarge, admit(r, &entries, &header));
}

test "effective PAX sizes fail before iterator padding arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    var bytes: [1536]u8 = @splat(0);
    const record = "29 size=18446744073709551615\n";
    @memcpy(bytes[0..512], &(try framingHeader('x', record.len)));
    @memcpy(bytes[512..][0..record.len], record);
    @memcpy(bytes[1024..1536], &(try framingHeader('0', 0)));
    var entries: [0]Entry = .{};
    try std.testing.expectError(error.SourceTooLarge, admit(r, &entries, &bytes));
}

test "PAX framing cannot read an attribute beyond its declared payload" {
    const record = "99 size=1\n";
    var bytes: [1024]u8 = @splat(0);
    @memcpy(bytes[0..512], &(try framingHeader('x', record.len)));
    @memcpy(bytes[512..][0..record.len], record);
    try std.testing.expectError(error.UnexpectedEndOfStream, tarFraming(&bytes));
}

test "source and compiler FIFOs return errors without a writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const fifo = try r.path(&.{ root, "fifo" });
    _ = try r.run(&.{ "mkfifo", fifo }, root, true);
    try std.testing.expectError(error.InvalidSourceArchive, readArchive(r, fifo));
    try std.testing.expectError(error.InvalidSourceArchive, retain(r, fifo, "bytes"));
    try std.testing.expectError(error.InvalidCompilerExecutable, compilerSha256(r, fifo));
    try std.testing.expectError(
        error.InvalidCompilerExecutable,
        CapturedCompiler.acquire(r, fifo, root, null),
    );
}

test "output directory aliases share one persistent lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const path = try r.path(&.{ root, "output" });
    const owner = try BuildOutput.acquire(r, path);
    defer owner.close(r.io);
    const slash = try std.fmt.allocPrint(r.a, "{s}/", .{path});
    const dot = try std.fmt.allocPrint(r.a, "{s}/./", .{path});
    try std.testing.expectError(error.BuildOutputBusy, BuildOutput.acquire(r, slash));
    try std.testing.expectError(error.BuildOutputBusy, BuildOutput.acquire(r, dot));
}

fn failReceiptRename(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_path: []const u8,
    new_dir: Dir,
    new_path: []const u8,
) Dir.RenameError!void {
    if (std.mem.eql(u8, new_path, "source.json")) return error.AccessDenied;
    return std.testing.io.vtable.dirRename(userdata, old_dir, old_path, new_dir, new_path);
}

test "failed receipt replacement cannot retain stale success beside a new archive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const owner = try BuildOutput.acquire(r, root);
    defer owner.close(r.io);
    try owner.retain(r.io, "old", "old-receipt");
    var vtable = r.io.vtable.*;
    vtable.dirRename = failReceiptRename;
    const failing: std.Io = .{ .userdata = r.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.AccessDenied, owner.retain(failing, "new", "new-receipt"));
    try std.testing.expectEqualStrings("new", try readArchive(
        r,
        try r.path(&.{ root, "source.tar" }),
    ));
    try std.testing.expectError(error.FileNotFound, readArchive(
        r,
        try r.path(&.{ root, "source.json" }),
    ));
    try owner.retain(r.io, "new", "new-receipt");
    try std.testing.expectEqualStrings("new-receipt", try readArchive(
        r,
        try r.path(&.{ root, "source.json" }),
    ));
}

fn writeExecutable(r: TestRunner, path: []const u8, bytes: []const u8) !void {
    var file = try Dir.cwd().createFile(r.io, path, .{ .exclusive = true });
    defer file.close(r.io);
    try file.writeStreamingAll(r.io, bytes);
    try file.setPermissions(r.io, .fromMode(0o700));
}

test "captured compiler execution survives replacement and supplied symlink retargeting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const original = try r.path(&.{ root, "original" });
    const replacement = try r.path(&.{ root, "replacement" });
    const supplied = try r.path(&.{ root, "supplied" });
    try writeExecutable(r, original, "#!/bin/sh\nprintf 'original-%s-%s\\n' \"$1\" \"$CC\"\n");
    try writeExecutable(r, replacement, "#!/bin/sh\nprintf 'replacement\\n'\n");
    try Dir.cwd().symLink(r.io, original, supplied, .{});
    var env = std.process.Environ.Map.init(r.a);
    defer env.deinit();
    try env.put("ZIG_LIB_DIR", ".");
    try env.put("CC", "selected-cc");
    var compiler = try CapturedCompiler.acquire(r, supplied, root, &env);
    defer compiler.close(r.io);
    const selected: TestRunner = .{ .a = r.a, .env = &compiler.env };
    try std.testing.expectEqualStrings(".", compiler.env.get("ZIG_LIB_DIR").?);
    try std.testing.expectEqualStrings("original-version-selected-cc\n", (try selected.run(
        &.{ compiler.path, "version" },
        root,
        true,
    )).stdout);
    try Dir.cwd().rename(replacement, .cwd(), original, r.io);
    try Dir.cwd().deleteFile(r.io, supplied);
    try Dir.cwd().symLink(r.io, "/bin/false", supplied, .{});
    try std.testing.expectEqualStrings("original-fetch-selected-cc\n", (try selected.run(
        &.{ compiler.path, "fetch" },
        root,
        true,
    )).stdout);
    try std.testing.expectEqualStrings(compiler.sha256, try compilerSha256(r, compiler.path));
    try std.testing.expect(!std.mem.eql(u8, compiler.sha256, try compilerSha256(r, original)));
}

test "Git PAX paths and canonical GNU long names retain exact source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    const segment: [100]u8 = @splat('a');
    const parent = try r.path(&.{ repo, &segment, &segment });
    try Dir.cwd().createDirPath(r.io, parent);
    try r.write(try r.path(&.{ parent, &segment }), "long-path-source\n");
    _ = try r.run(&.{ "git", "add", "." }, repo, true);
    try commitFixture(r, repo);
    const snapshot = try prepare(r, repo, root);
    try std.testing.expectEqual(@as(usize, 3), snapshot.files.len);
    const extracted = try r.path(&.{ snapshot.source, &segment, &segment, &segment });
    try std.testing.expectEqualStrings("long-path-source\n", try readArchive(r, extracted));
}

test "captured native Zig preserves library discovery and configured compiler environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = try std.testing.environ.createMap(arena.allocator());
    defer env.deinit();
    const r: TestRunner = .{ .a = arena.allocator(), .env = &env };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const supplied = std.mem.trim(u8, (try r.run(&.{ "which", "zig" }, root, true)).stdout, "\r\n");
    var compiler = try CapturedCompiler.acquire(r, supplied, root, &env);
    defer compiler.close(r.io);
    const selected: TestRunner = .{ .a = r.a, .env = &compiler.env };
    try std.testing.expectEqualStrings("0.17.0\n", (try selected.run(
        &.{ compiler.path, "version" },
        root,
        true,
    )).stdout);
    const probe = try r.path(&.{ root, "probe.zig" });
    try r.write(probe,
        \\const std = @import("std");
        \\test "captured compiler" { try std.testing.expectEqual(@as(u8, 7), @as(u8, 7)); }
    );
    const result = try std.process.run(r.a, r.io, .{
        .argv = &.{ compiler.path, "test", probe },
        .cwd = .{ .path = root },
        .environ_map = &compiler.env,
        .stdout_limit = .limited(65536),
        .stderr_limit = .limited(65536),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "All 1 tests passed.") != null);
    try std.testing.expectEqualStrings(compiler.sha256, try compilerSha256(r, compiler.path));
}

test "successful Git archive with a corrupt declared blob size returns an admission error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    const oid = try identity((try r.run(
        &.{ "git", "rev-parse", "HEAD:ordinary" },
        repo,
        true,
    )).stdout);
    const object = try r.path(&.{ repo, ".git", "objects", oid[0..2], oid[2..] });
    try Dir.cwd().deleteFile(r.io, object);
    try r.write(
        object,
        "\x78\x9c\x4b\xca\xc9\x4f\x52\x30\xb4\x30\x31\x31\x33\x37\x31\x31" ++
            "\x30\x37\x36\x37\xb0\x34\x35\x35\x34\x33\x34\x65\xa8\x00\x00\x60" ++
            "\x00\x06\x4f",
    );
    try std.testing.expectError(error.SourceTooLarge, prepare(r, repo, root));
    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(
        r.io,
        try r.path(&.{ root, "source.tar" }),
        .{},
    ));
}

test "final archive bytes must still match the tested snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    const snapshot = try prepare(r, repo, root);
    const original = try testedArchive(r, snapshot);
    const changed = try r.a.dupe(u8, original);
    changed[512] ^= 1;
    try r.write(snapshot.archive, changed);
    try std.testing.expectError(error.SourceChanged, testedArchive(r, snapshot));
    try r.write(snapshot.archive, original[0 .. original.len - 1]);
    try std.testing.expectError(error.SourceChanged, testedArchive(r, snapshot));
    try r.write(snapshot.archive, original);
    try std.testing.expectEqualStrings(original, try testedArchive(r, snapshot));
}

test "forwarding compiler wrappers preserve configured execution without library overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = try std.testing.environ.createMap(arena.allocator());
    defer env.deinit();
    _ = env.swapRemove("ZIG_LIB_DIR");
    const r: TestRunner = .{ .a = arena.allocator(), .env = &env };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const supplied = std.mem.trim(u8, (try r.run(&.{ "which", "zig" }, root, true)).stdout, "\r\n");
    try env.put("PINNED_ZIG", supplied);
    const wrapper = try r.path(&.{ root, "forward" });
    try writeExecutable(r, wrapper, "#!/bin/sh\nexec \"$PINNED_ZIG\" \"$@\"\n");
    const original = try r.run(&.{ wrapper, "env" }, root, true);
    var compiler = try CapturedCompiler.acquire(r, wrapper, root, &env);
    defer compiler.close(r.io);
    const selected: TestRunner = .{ .a = r.a, .env = &compiler.env };
    try std.testing.expect(compiler.env.get("ZIG_LIB_DIR") == null);
    try std.testing.expectEqualStrings(original.stdout, (try selected.run(
        &.{ compiler.path, "env" },
        root,
        true,
    )).stdout);
    try std.testing.expectEqualStrings("0.17.0\n", (try selected.run(
        &.{ compiler.path, "version" },
        root,
        true,
    )).stdout);
}

fn distinctDirectoryNames(r: TestRunner, root: []const u8, names: [2][]const u8) !bool {
    const probe = try r.path(&.{ root, "names" });
    try Dir.cwd().createDir(r.io, probe, .fromMode(0o700));
    defer removeFixture(r, probe);
    var directory = try Dir.cwd().openDir(r.io, probe, .{ .iterate = true });
    defer directory.close(r.io);
    try directory.createDir(r.io, names[0], .default_dir);
    directory.createDir(r.io, names[1], .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) return false;
        return err;
    };
    var iterator = directory.iterate();
    var found: [2]bool = .{ false, false };
    while (try iterator.next(r.io)) |entry| {
        for (names, 0..) |name, index| {
            if (std.mem.eql(u8, entry.name, name)) found[index] = true;
        }
    }
    return found[0] and found[1];
}

fn indexPaths(r: TestRunner, repo: []const u8, paths: []const []const u8) !void {
    const blob = std.mem.trim(u8, (try r.run(
        &.{ "git", "rev-parse", "HEAD:ordinary" },
        repo,
        true,
    )).stdout, "\r\n");
    for (paths) |path| _ = try r.run(&.{
        "git",          "-c",    "core.ignorecase=false", "-c",     "core.precomposeunicode=false",
        "update-index", "--add", "--cacheinfo",           "100644", blob,
        path,
    }, repo, true);
    try commitFixture(r, repo);
}

fn checkNamespacePair(r: TestRunner, names: [2][]const u8, shape: u8) !void {
    const root = try temporary(r);
    defer removeFixture(r, root);
    const representable = try distinctDirectoryNames(r, root, names);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    const paths = [_][]const u8{
        try r.path(&.{ "test", names[0], if (shape == 0) "one.txt" else "" }),
        try r.path(&.{ "test", names[1], if (shape == 1) "" else "two.txt" }),
    };
    try indexPaths(r, repo, &paths);
    const snapshot = prepare(r, repo, root) catch |err| {
        if (representable) return err;
        if (shape == 0) try std.testing.expectEqual(error.SourceNamespaceMismatch, err);
        try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(
            r.io,
            try r.path(&.{ root, "source" }),
            .{ .follow_symlinks = false },
        ));
        return;
    };
    try std.testing.expect(representable);
    try std.testing.expectEqual(@as(usize, 4), snapshot.files.len);
    for (paths) |path| try std.testing.expectEqualStrings("source\n", try readArchive(
        r,
        try r.path(&.{ snapshot.source, path }),
    ));
}

test "filesystem case and Unicode aliases preserve exact representable Git paths or reject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    for ([_][2][]const u8{ .{ "A", "a" }, .{ "\u{e9}", "e\u{301}" } }) |names| {
        for (0..3) |shape| try checkNamespacePair(r, names, @intCast(shape));
    }
}

test "shared exact prefixes preserve files modes and existing destination ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r: TestRunner = .{ .a = arena.allocator() };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const repo = try r.path(&.{ root, "repo" });
    try fixture(r, repo);
    try indexPaths(r, repo, &.{ "test/Shared/one.txt", "test/Shared/two.txt", "test/\u{3bb}.txt" });
    const snapshot = try prepare(r, repo, root);
    try std.testing.expectEqual(@as(usize, 5), snapshot.files.len);
    const executable_path = try r.path(&.{ snapshot.source, "executable" });
    const executable = try Dir.cwd().statFile(r.io, executable_path, .{});
    try std.testing.expectEqual(@as(u32, 0o755), executable.permissions.toMode() & 0o7777);
    try std.testing.expectError(error.PathAlreadyExists, verify(
        r,
        repo,
        snapshot.commit,
        snapshot.tree,
        snapshot.archive,
        snapshot.source,
    ));
    try std.testing.expectEqualStrings("source\n", try readArchive(
        r,
        try r.path(&.{ snapshot.source, "test/Shared/two.txt" }),
    ));
}

test "compiler library discovered below producer cwd remains absolute in another cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = try std.testing.environ.createMap(arena.allocator());
    defer env.deinit();
    _ = env.swapRemove("ZIG_LIB_DIR");
    const r: TestRunner = .{ .a = arena.allocator(), .env = &env };
    const root = try temporary(r);
    defer removeFixture(r, root);
    const supplied = std.mem.trim(u8, (try r.run(&.{ "which", "zig" }, root, true)).stdout, "\r\n");
    const original = try Dir.cwd().realPathFileAlloc(r.io, supplied, r.a);
    const cwd = try Dir.cwd().openDir(r.io, ".", .{});
    defer cwd.close(r.io);
    const cwd_path = try cwd.realPathFileAlloc(r.io, ".", r.a);
    const library = try std.zig.findZigLibDirFromSelfExe(r.a, r.io, cwd_path, original);
    defer library.handle.close(r.io);
    const library_path = try library.handle.realPathFileAlloc(r.io, ".", r.a);
    const local = try r.path(&.{ root, "zig" });
    _ = try copyCompiler(r, original, local);
    const local_library = try r.path(&.{ root, "lib" });
    try Dir.cwd().symLink(r.io, library_path, local_library, .{ .is_directory = true });
    try std.process.setCurrentPath(r.io, root);
    defer std.process.setCurrentDir(r.io, cwd) catch |err|
        std.debug.panic("cwd restoration failed: {s}", .{@errorName(err)});
    var compiler = try CapturedCompiler.acquire(r, local, root, &env);
    defer compiler.close(r.io);
    try std.testing.expect(std.fs.path.isAbsolute(compiler.env.get("ZIG_LIB_DIR").?));
    const elsewhere = try r.path(&.{ root, "elsewhere" });
    try Dir.cwd().createDir(r.io, elsewhere, .default_dir);
    const probe = try r.path(&.{ elsewhere, "probe.zig" });
    try r.write(probe, "test { try @import(\"std\").testing.expect(true); }\n");
    const selected: TestRunner = .{ .a = r.a, .env = &compiler.env };
    _ = try selected.run(&.{ compiler.path, "test", probe }, elsewhere, true);
}
