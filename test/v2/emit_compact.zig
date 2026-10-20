//! Reproducible synthetic size witnesses; stdout remains a portable image.
const std = @import("std");
const horos = @import("horos");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const count = try std.fmt.parseInt(usize, args.next() orelse return error.MissingCount, 10);
    const kind = args.next() orelse return error.MissingKind;
    if (args.next() != null or count == 0) return error.InvalidArguments;
    const mixed = std.mem.eql(u8, kind, "mixed");
    const irregular = std.mem.eql(u8, kind, "irregular");
    const constant = std.mem.eql(u8, kind, "constant");
    if (!mixed and !irregular and !constant and !std.mem.eql(u8, kind, "install"))
        return error.InvalidKind;
    var builder = horos.source.Builder.init(init.gpa);
    defer builder.deinit();
    const module = if (constant)
        try @import("compact_fixtures.zig").storedConstant(
            &builder,
            std.math.mul(usize, count, 1024) catch return error.InvalidLength,
        )
    else if (irregular)
        try @import("compact_fixtures.zig").variedMixed(&builder, count, .{ .seed = 11 })
    else if (mixed)
        try @import("compact_fixtures.zig").mixed(&builder, count, 0, false)
    else
        try horos.source.examples.installations(&builder, count);
    var compiled = try horos.program.compile(init.gpa, module);
    defer compiled.deinit();
    if (constant and compiled.program.constants.len != 1) return error.DuplicatedConstant;
    const bytes = try init.gpa.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    defer init.gpa.free(bytes);
    _ = try compiled.encode(init.gpa, bytes);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bytes);
    try output.interface.flush();
}
