const std = @import("std");
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const hyper = @import("hyper.zig");
const native = @import("horos_data").schema.native;

const Knowledge = enum { known, peer, row, answer, row_answer, endpoint, erased };

const NamedDelay = struct {
    pub const internal: a.InternalInfo = .{
        .callable = a.Signature(native.Fields(&.{}, &.{}), a.Shape(u64)),
    };
};

test "typed hyper observations normalize admitted partial answer delays" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const options = .{
        .use = .reusable,
        .captures = .{
            types.forward(),
            types.backward(),
            types.peerForward(),
            types.peerBackward(),
            types.answerForward(),
            types.answerBackward(),
            integer,
            integer,
        },
    };
    const answer_schema = try c.callable(
        try a.interop.RuntimeNamed(.schema).init(c, &.{}),
        integer,
        .{},
        options,
    );
    const schema = try c.callable(.{ .peer = types.peerBackward() }, answer_schema, .{}, options);
    const entry = try c.function("partial answer", .{}, integer, .{});
    const body = try c.body(entry);
    const answer = try hyper.deferValue(body, types.answerForward(), try body.constant(u64, 42));
    const participant = try a.interop.refineValue(
        body,
        try hyper.base(body, types, answer),
        schema,
    );
    const projected = try exerciseOperations(
        a.ShapeOf(@TypeOf(answer_schema)),
        hyper.Delayed(a.Shape(u64)),
        body,
        types,
        participant,
    );
    try c.define(entry, try body.ret(try hyper.force(body, projected)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper observations normalize structurally compatible named answer delays" {
    inline for (.{ false, true }) |erased| try namedAnswer(erased);
}

fn namedAnswer(comptime erased: bool) !void {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const delayed = try c.declareSchema(.callable, NamedDelay);
    const schema = try c.callable(.{ .peer = types.peerBackward() }, delayed.schema(), .{}, .{
        .use = .reusable,
        .captures = .{delayed.schema()},
    });
    try c.defineCallable(delayed, .{}, integer, .{}, .{
        .use = .reusable,
        .captures = .{ schema, types.peerBackward(), integer },
    });
    const entry = try c.function("named answer", .{}, integer, .{});
    const body = try c.body(entry);
    const function = try c.functionFor("participant", schema);
    const nested = try body.closureBody(function);
    try c.define(function, try nested.ret(try hyper.deferValue(
        nested,
        delayed.schema(),
        try nested.constant(u64, 42),
    )));
    const known = try body.lambda(function, schema);
    const participant = if (erased) a.interop.erase(known) else known;
    const Invoked = if (erased) a.Dynamic else NamedDelay;
    const Observed = hyper.Delayed(if (erased) a.Dynamic else a.Shape(u64));
    const projected = try exerciseOperations(Invoked, Observed, body, types, participant);
    try c.define(entry, try body.ret(try hyper.force(body, projected)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper partial callable knowledge preserves checked operations" {
    inline for (comptime std.meta.tags(Knowledge)) |knowledge| {
        partialOperations(knowledge) catch |err| {
            std.debug.print("partial callable {s}: {}\n", .{ @tagName(knowledge), err });
            return err;
        };
    }
}

test "typed hyper erased observations retain the actual answer instead of the pair output" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const types = try hyper.pair(c, integer, integer, .{});
    const delayed = try c.declareSchema(.callable, hyper.Delayed(a.Shape(bool)));
    const schema = try c.callable(.{ .peer = types.peerBackward() }, delayed.schema(), .{}, .{
        .use = .reusable,
        .captures = .{delayed.schema()},
    });
    try c.defineCallable(delayed, .{}, boolean, .{}, .{
        .use = .reusable,
        .captures = .{ schema, types.peerBackward(), boolean },
    });
    const entry = try c.function("erased answer", .{}, boolean, .{});
    const body = try c.body(entry);
    const function = try c.functionFor("participant", schema);
    const nested = try body.closureBody(function);
    try c.define(function, try nested.ret(try hyper.deferValue(
        nested,
        delayed.schema(),
        try nested.constant(bool, true),
    )));
    const participant = a.interop.erase(try body.lambda(function, schema));
    const argument = try hyper.deferValue(
        body,
        types.answerBackward(),
        try body.constant(u64, 23),
    );
    try std.testing.expectError(error.SchemaMismatch, hyper.run(body, types, participant));
    const projected = try hyper.project(body, types, participant, argument);
    try std.testing.expect(@TypeOf(projected) == *const a.Value(hyper.Delayed(a.Dynamic)));
    const forced = try hyper.force(body, projected);
    try std.testing.expect(@TypeOf(forced) == *const a.Value(a.Dynamic));
    try std.testing.expectError(error.SchemaMismatch, a.interop.refineValue(body, forced, integer));
    const result = try a.interop.refineValue(body, forced, boolean);
    try c.define(entry, try body.ret(result));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

fn partialOperations(comptime knowledge: Knowledge) !void {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const options = .{
        .use = .reusable,
        .captures = .{
            types.forward(),
            types.backward(),
            types.peerForward(),
            types.peerBackward(),
            types.answerForward(),
            types.answerBackward(),
            integer,
            integer,
        },
    };
    const peer = if (knowledge == .peer)
        a.interop.erase(types.peerBackward())
    else
        types.peerBackward();
    const parameters = if (knowledge == .row or knowledge == .row_answer)
        try a.interop.RuntimeNamed(.schema).init(c, &.{
            .{ .name = "peer", .handle = a.interop.erase(peer) },
        })
    else
        .{ .peer = peer };
    const result = if (knowledge == .answer or knowledge == .row_answer)
        a.interop.erase(types.answerForward())
    else if (knowledge == .endpoint)
        try c.callable(.{}, a.interop.erase(integer), .{}, options)
    else
        types.answerForward();
    const callable = try c.callable(parameters, result, .{}, options);
    const schema = if (knowledge == .erased)
        a.interop.erase(callable)
    else
        callable;
    const entry = try c.function("partial", .{}, integer, .{});
    const body = try c.body(entry);
    const answer = try hyper.deferValue(body, types.answerForward(), try body.constant(u64, 42));
    const participant = try a.interop.refineValue(
        body,
        try hyper.base(body, types, answer),
        schema,
    );
    const Invoked = switch (knowledge) {
        .answer, .row_answer, .erased => a.Dynamic,
        .endpoint => hyper.Delayed(a.Dynamic),
        else => hyper.Delayed(a.Shape(u64)),
    };
    const Observed = switch (knowledge) {
        .answer, .row_answer, .endpoint, .erased => hyper.Delayed(a.Dynamic),
        else => hyper.Delayed(a.Shape(u64)),
    };
    const projected = try exerciseOperations(Invoked, Observed, body, types, participant);
    try c.define(entry, try body.ret(try hyper.force(body, projected)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

fn exerciseOperations(
    comptime Invoked: type,
    comptime Observed: type,
    body: anytype,
    types: anytype,
    participant: anytype,
) !*const a.Value(Observed) {
    const c = try body.context();
    const argument = try hyper.deferValue(
        body,
        types.answerBackward(),
        try body.constant(u64, 23),
    );
    const counterpart = try hyper.base(body, types.swap(), argument);
    const peer = try hyper.deferValue(body, types.peerBackward(), counterpart);
    const invoked = try hyper.invoke(body, participant, peer);
    try std.testing.expect(@TypeOf(invoked) == *const a.Value(Invoked));
    const Answer = *const a.Value(Observed);
    const run = try hyper.run(body, types, participant);
    const projected = try hyper.project(body, types, participant, argument);
    try std.testing.expect(@TypeOf(run) == Answer);
    try std.testing.expect(@TypeOf(projected) == Answer);
    const incompatible = try hyper.pair(c, try c.schema(u64), try c.schema(u64), .{
        .captures = .{try c.schema(bool)},
    });
    const wrong_answer = try hyper.deferValue(
        body,
        incompatible.answerBackward(),
        try body.constant(u64, 23),
    );
    const wrong_peer = try hyper.deferValue(
        body,
        incompatible.peerBackward(),
        try hyper.base(body, incompatible.swap(), wrong_answer),
    );
    try std.testing.expectError(error.SchemaMismatch, hyper.invoke(body, participant, wrong_peer));
    return projected;
}

test "typed hyper invokes completed callable promises with unknown signatures" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const delayed = try c.declareSchema(.callable, hyper.Delayed(a.Shape(u64)));
    const declaration = try c.declareSchema(.callable, a.Internal(.{ .callable = a.Dynamic }));
    try c.defineCallable(declaration, .{ .peer = types.peerBackward() }, delayed.schema(), .{}, .{
        .use = .reusable,
        .captures = .{delayed.schema()},
    });
    try c.defineCallable(delayed, .{}, integer, .{}, .{
        .use = .reusable,
        .captures = .{ declaration.schema(), types.peerBackward(), integer },
    });
    const entry = try c.function("unknown signature", .{}, integer, .{});
    const body = try c.body(entry);
    const answer = try hyper.deferValue(body, delayed.schema(), try body.constant(u64, 42));
    const function = try c.functionFor("participant", declaration.schema());
    const nested = try body.closureBody(function);
    try c.define(function, try nested.ret(answer));
    const participant = try body.lambda(function, declaration.schema());
    const argument = try hyper.deferValue(body, types.answerBackward(), try body.constant(u64, 23));
    const counterpart = try hyper.base(body, types.swap(), argument);
    const peer = try hyper.deferValue(body, types.peerBackward(), counterpart);
    const invoked = try hyper.invoke(body, participant, peer);
    try std.testing.expect(@TypeOf(invoked) == *const a.Value(a.Dynamic));
    try c.define(entry, try body.ret(try hyper.force(body, invoked)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}
