const std = @import("std");
const horos = @import("horos");
const a = horos.authoring;
const hyper = horos.library.hyper;
const native = horos.data.schema.native;

pub const Application = struct {
    pub fn emit(raw: *horos.source.Builder) !horos.source.Module {
        const c = try a.Context.init(raw);
        const integer = try c.schema(u64);
        const Task = a.Internal(.{ .callable = a.Signature(
            native.Fields(&.{}, &.{}),
            a.Shape(u64),
        ) });
        const task = try c.declareSchema(.callable, Task);
        const tasks = try hyper.pair(c, task.schema(), task.schema(), .{ .captures = .{integer} });
        const lookup = try c.external("hyper-client/task", integer, integer);
        try c.defineCallable(task, .{}, integer, .{lookup}, .{
            .use = .reusable,
            .captures = .{ integer, tasks.peerForward(), tasks.peerBackward() },
        });
        const types = try hyper.pair(c, integer, integer, .{});
        const entry = try c.function("entry", .{}, integer, .{});
        const body = try c.body(entry);
        const answer = try hyper.deferValue(
            body,
            types.answerForward(),
            try body.constant(u64, 42),
        );
        const participant = try hyper.base(body, types, answer);
        const peer_answer = try hyper.deferValue(
            body,
            types.answerBackward(),
            try body.constant(u64, 7),
        );
        const peer = try hyper.base(body, types.swap(), peer_answer);
        const delayed_peer = try hyper.deferValue(body, types.peerBackward(), peer);
        const result = try hyper.force(body, try hyper.invoke(body, participant, delayed_peer));
        try c.define(entry, try body.ret(result));
        return c.module(entry, try c.schema(void));
    }
};

pub fn main(init: std.process.Init) !void {
    var compiled = try horos.program.lower(init.gpa, Application);
    defer compiled.deinit();
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
