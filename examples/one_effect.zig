//! Compile a typed residual effect into portable data; no evaluator is linked.
const std = @import("std");
const horos = @import("horos");

pub const Application = struct {
    pub fn emit(b: *horos.source.Builder) !horos.source.Module {
        const c = try horos.authoring.Context.init(b);
        const integer = try c.schema(u32);
        const lookup = try c.external("example.lookup.v2", integer, integer);
        const entry = try c.function("lookup", .{ .key = integer }, integer, &.{lookup});
        const body = try c.body(entry);
        const answer = try body.perform(lookup, try body.parameter("key"));
        try c.define(entry, try body.ret(answer));
        return c.module(entry, try c.schema(void));
    }
};

pub fn main(init: std.process.Init) !void {
    var compiled = try horos.program.lower(init.gpa, Application);
    defer compiled.deinit();
    const bytes = try init.gpa.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer init.gpa.free(bytes);
    _ = try compiled.encode(init.gpa, bytes);
    // A compiler-only consumer can decode, inspect and admit the emitted image.
    var decoded = try horos.data.program_image.decode(init.gpa, bytes);
    defer decoded.deinit();
    var checked = try horos.data.activation_ownership.analyze(init.gpa, decoded.program);
    defer checked.deinit();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bytes);
    try output.interface.flush();
}
