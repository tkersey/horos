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

fn admit(r: anytype, entries: []Entry, bytes: []const u8) !void {
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
    var root = try Dir.cwd().openDir(r.io, source, .{ .follow_symlinks = false });
    defer root.close(r.io);
    for (entries) |entry| {
        if (std.fs.path.dirname(entry.path)) |parent| try root.createDirPath(r.io, parent);
        var file = try root.createFile(r.io, entry.path, .{ .exclusive = true });
        defer file.close(r.io);
        try file.writeStreamingAll(r.io, entry.bytes.?);
        try file.setPermissions(r.io, .fromMode(@intCast(entry.mode)));
    }
}

fn stable(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.kind == b.kind and
        a.permissions == b.permissions and std.meta.eql(a.mtime, b.mtime) and
        std.meta.eql(a.ctime, b.ctime);
}

pub fn readArchive(r: anytype, path: []const u8) ![]const u8 {
    var file = try Dir.cwd().openFile(r.io, path, .{
        .follow_symlinks = false,
        .allow_directory = false,
    });
    defer file.close(r.io);
    const before = try file.stat(r.io);
    if (before.kind != .file or before.size > maximum_bytes) return error.InvalidSourceArchive;
    var reader = file.reader(r.io, &.{});
    const bytes = try reader.interface.allocRemaining(r.a, .limited(maximum_bytes));
    const after = try file.stat(r.io);
    const named = try Dir.cwd().statFile(r.io, path, .{ .follow_symlinks = false });
    if (!stable(before, after) or !stable(after, named) or bytes.len != before.size)
        return error.SourceChanged;
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
        const lock_path = try std.fmt.allocPrint(r.a, "{s}.lock", .{path});
        const lock = Dir.cwd().createFile(r.io, lock_path, .{
            .exclusive = true,
        }) catch |err| blk: {
            if (err != error.PathAlreadyExists) return err;
            break :blk try Dir.cwd().openFile(r.io, lock_path, .{
                .mode = .read_write,
                .follow_symlinks = false,
                .allow_directory = false,
            });
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

    pub fn run(
        r: TestRunner,
        argv: []const []const u8,
        cwd: []const u8,
        success: bool,
    ) !std.process.RunResult {
        const result = try std.process.run(r.a, r.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
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
