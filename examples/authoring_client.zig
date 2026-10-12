//! Public-package client: all generated branching and interpretation is Program code.
const std = @import("std");
const horos = @import("horos");
const a = horos.authoring;

pub const Application = struct {
    pub fn emit(raw: *horos.source.Builder) !horos.source.Module {
        const c = try a.Context.init(raw);
        const integer = try c.schema(u64);
        const boolean = try c.schema(bool);
        const unit = try c.schema(void);
        const input = try c.record(.{ .input = integer, .offset = integer });
        const lookup = try c.external("client/lookup", integer, integer);
        const question = try c.local("client/question", integer, integer, .linear);
        const capability = try c.capability(question);
        const callable = try c.callable(.{}, integer, &.{question}, .{ .use = .reusable, .captures = &.{ integer, capability } });
        const failure = try c.literalFailure(void, {});
        const responder = try c.function("lookup responder", .{ .key = integer }, integer, &.{lookup});
        const response = try c.body(responder);
        try c.define(responder, try response.ret(try response.perform(lookup, try response.parameter("key"))));
        const h = try c.responder(question, integer, responder, .{
            .mode = .deep,
            .use = .linear,
            .residual = &.{lookup},
            .captures = &.{ integer, input, capability, callable },
            .body_captures = &.{integer},
        });
        const entry = try c.function("entry", .{ .use_effect = boolean, .numbers = input }, integer, &.{lookup});
        const body = try c.body(entry);
        const numbers = try body.parameter("numbers");
        const x = try body.field(numbers, "input");
        const offset = try body.field(numbers, "offset");
        const yes = try body.branch();
        const no = try body.branch();
        const handled = try c.handledSchema(h);
        const work = try c.functionFor("interpreted work", handled);
        const interpreted = try yes.closureBody(work);
        const cap = try interpreted.parameter("capability");
        const query = try c.functionFor("reusable question", callable);
        const query_body = try interpreted.closureBody(query);
        try c.define(query, try query_body.ret(try query_body.performLocal(question, cap, x)));
        const ask = try interpreted.lambda(query, callable);
        const first = try interpreted.apply(ask, .{});
        const partial = try interpreted.checkedAdd(first, offset, failure);
        const second = try interpreted.apply(ask, .{});
        const result = try interpreted.checkedAdd(partial, second, failure);
        try c.define(work, try interpreted.ret(result));
        const true_result = try yes.handleWith(h, try yes.lambda(work, handled), .{});
        const false_result = try no.checkedAdd(x, offset, failure);
        const joined = try body.conditional(try body.parameter("use_effect"), try yes.ret(true_result), try no.ret(false_result));
        try c.define(entry, try body.ret(joined));
        return c.module(entry, unit);
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
