const source = @import("source.zig");
const a = @import("authoring.zig");
const hyper = @import("library/hyper.zig");

pub fn nested(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const outer = try hyper.demand.family(c, "same need", integer, integer);
    const inner = try hyper.demand.family(c, "same need", integer, integer);
    const captures = .{ integer, outer.capability(), inner.capability() };
    const outer_handler = try c.handler(outer.effect(), integer, integer, .{
        .use = .linear,
        .mode = .deep,
        .captures = captures,
        .body_captures = .{},
        .return_effects = .{},
    });
    const inner_handler = try c.handler(inner.effect(), integer, integer, .{
        .use = .linear,
        .mode = .deep,
        .captures = captures,
        .body_captures = .{outer.capability()},
        .residual = .{outer.effect()},
        .return_effects = .{},
    });
    try defineHandler(c, outer_handler, 100);
    try defineHandler(c, inner_handler, 1000);
    const entry = try c.function("nested Need", .{}, integer, .{});
    const body = try c.body(entry);
    const outer_schema = try c.handledSchema(outer_handler);
    const outer_function = try c.functionFor("outer Need", outer_schema);
    const outer_body = try body.closureBody(outer_function);
    const outer_capability = try outer_body.parameter("capability");
    const inner_schema = try c.handledSchema(inner_handler);
    const inner_function = try c.functionFor("inner Need", inner_schema);
    const inner_body = try outer_body.closureBody(inner_function);
    const first = try hyper.demand.request(
        inner_body,
        outer,
        outer_capability,
        try inner_body.constant(u64, 1),
    );
    const second = try hyper.demand.request(
        inner_body,
        inner,
        try inner_body.parameter("capability"),
        try inner_body.constant(u64, 2),
    );
    const result = try inner_body.checkedAdd(first, second, try c.literalFailure(void, {}));
    try c.define(inner_function, try inner_body.ret(result));
    try c.define(outer_function, try outer_body.ret(try outer_body.handleWith(
        inner_handler,
        try outer_body.lambda(inner_function, inner_schema),
        .{},
    )));
    try c.define(entry, try body.ret(try body.handleWith(
        outer_handler,
        try body.lambda(outer_function, outer_schema),
        .{},
    )));
    return c.module(entry, try c.schema(void));
}

fn defineHandler(c: *a.Context, handler: anytype, offset: u64) !void {
    const returns = try c.returnFunction(handler);
    const return_body = try c.body(returns);
    try c.define(returns, try return_body.ret(try return_body.parameter("result")));
    const clause = try c.clauseFunction(handler);
    const body = try c.body(clause);
    const contribution = try body.checkedAdd(
        try body.parameter("payload"),
        try body.constant(u64, offset),
        try c.literalFailure(void, {}),
    );
    try c.define(clause, try body.ret(try body.resumeValue(
        try body.parameter("resumption"),
        contribution,
    )));
}
