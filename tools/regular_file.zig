const std = @import("std");
const Dir = std.Io.Dir;

pub fn open(io: std.Io, directory: Dir, path: []const u8, writable: bool) !std.Io.File {
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
