//! The host constructs both arms; Kosmos executes only the runtime-selected arm.
const std = @import("std");
const horos = @import("horos");
pub const Application = struct {
    pub fn emit(raw: *horos.source.Builder) !horos.source.Module {
        const c = try horos.authoring.Context.init(raw);
        const integer = try c.scalar(u64);
        const boolean = try c.scalar(bool);
        const lookup = try c.external("authoring/lookup", integer, integer);
        const entry = try c.function("entry", &.{.{ .name = "choose", .schema = boolean }}, integer, &.{lookup});
        const body = try c.body(entry);
        const yes = try body.branch();
        const no = try body.branch();
        const chosen = try body.conditional(try body.parameter("choose"), try yes.ret(try yes.perform(lookup, try yes.constant(u64, 19))), try no.ret(try no.constant(u64, 42)));
        try c.define(entry, try body.ret(chosen));
        return c.module(entry, try c.scalar(void));
    }
};
pub fn main(init: std.process.Init) !void {
    var compiled = try horos.program.lower(init.gpa, Application);
    defer compiled.deinit();
    const bytes = try init.gpa.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    defer init.gpa.free(bytes);
    _ = try compiled.encode(init.gpa, bytes);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bytes);
    try output.interface.flush();
}
