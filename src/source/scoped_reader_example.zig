// Copyright (c) 2026 Boundary contributors. MIT license.
//! Scoped forwarding transforms the inside computation and resumes the outside.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const native = @import("horos_data").schema.native;
const reader_library = @import("../library/reader.zig");
pub fn build(b: *source.Builder) source.Error!source.Module {
    return authored(b) catch |err| return a.sourceError(err);
}
fn authored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const pair = try c.record(.{ .local = integer, .outer = integer });
    const log = try c.external("example/reader-log", integer, unit);
    var declarations: [4]@TypeOf(try c.declareSchema(.resumption, a.Dynamic)) = undefined;
    var tokens: [4]*const a.Schema(a.Dynamic) = undefined;
    for (&declarations, &tokens) |*slot, *schema| {
        slot.* = try c.declareSchema(.resumption, a.Dynamic);
        schema.* = slot.*.schema();
    }
    const captures: []const *const a.Schema(a.Dynamic) = &.{
        a.interop.erase(unit),
        a.interop.erase(integer),
        a.interop.erase(pair),
        tokens[0],
        tokens[1],
        tokens[2],
        tokens[3],
    };
    const family = try reader_library.family(
        c,
        "example/scoped-reader",
        integer,
        integer,
        &.{},
        &.{log},
        &.{},
    );
    const reader = try reader_library.interpret(c, family, pair, .{ .continuation = captures });
    return declareForwarders(b, .{
        .c = c,
        .unit = unit,
        .integer = integer,
        .pair = pair,
        .log = log,
        .declarations = declarations,
        .captures = captures,
        .family = family,
        .reader = reader,
    });
}

fn declareForwarders(
    b: *source.Builder,
    ctx: anytype,
) a.Error!source.Module {
    const effects = &.{ ctx.log, ctx.family.ask(), ctx.family.local() };
    const bound = try b.allocator().alloc(
        *const a.Schema(a.Dynamic),
        ctx.captures.len + ctx.reader.resumptions.len + 3,
    );
    @memcpy(bound[0..ctx.captures.len], ctx.captures);
    @memcpy(bound[ctx.captures.len..][0..ctx.reader.resumptions.len], ctx.reader.resumptions);
    @memcpy(
        bound[bound.len - 3 ..],
        &[_]*const a.Schema(a.Dynamic){
            a.interop.erase(ctx.family.askCapability()),
            a.interop.erase(ctx.family.localCapability()),
            a.interop.erase(ctx.family.inside()),
        },
    );
    const Ops = native.Fields(
        &.{ "ask", "local" },
        &.{ a.ShapeOf(@TypeOf(ctx.family.ask())), a.ShapeOf(@TypeOf(ctx.family.local())) },
    );
    const State = native.Fields(
        &.{ "outer_ask", "outer_local" },
        &.{
            a.ShapeOf(@TypeOf(ctx.family.askCapability())),
            a.ShapeOf(@TypeOf(ctx.family.localCapability())),
        },
    );
    const Empty = native.Fields(&.{}, &.{});
    const Pair = a.ShapeOf(@TypeOf(ctx.pair));
    const Integer = a.Shape(u64);
    var forwarding: struct {
        *const a.Handler(a.HandlerShape(Ops, Pair, Pair, State, Empty, .deep)),
        *const a.Handler(a.HandlerShape(Ops, Integer, Integer, State, Empty, .deep)),
    } = undefined;
    return defineAskForwarders(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .pair = ctx.pair,
        .log = ctx.log,
        .declarations = ctx.declarations,
        .family = ctx.family,
        .reader = ctx.reader,
        .effects = effects,
        .bound = bound,
        .forwarding = &forwarding,
    });
}

fn defineAskForwarders(
    ctx: anytype,
) a.Error!source.Module {
    inline for (.{ ctx.pair, ctx.integer }, 0..) |answer, index| {
        const handler = try ctx.c.handlerSet(.{
            .ask = ctx.family.ask(),
            .local = ctx.family.local(),
        }, answer, answer, .{
            .mode = .deep,
            .use = .linear,
            .residual = ctx.effects,
            .return_effects = &.{},
            .captures = ctx.bound,
            .body_captures = if (index == 0) &.{} else &.{ctx.family.inside()},
            .state = .{
                .outer_ask = ctx.family.askCapability(),
                .outer_local = ctx.family.localCapability(),
            },
            .resumption_slots = ctx.declarations[index * 2 ..][0..2],
        });
        ctx.forwarding[index] = handler;
        const returns_fn = try ctx.c.returnFunction(handler);
        const returns = try ctx.c.body(returns_fn);
        try ctx.c.define(returns_fn, try returns.ret(try returns.parameter("result")));
        const asks_fn = try ctx.c.clauseFunctionFor(handler, ctx.family.ask());
        const asks = try ctx.c.body(asks_fn);
        _ = try asks.perform(ctx.log, try asks.constant(u64, 1));
        const answer_value = try asks.performLocal(
            ctx.family.ask(),
            try asks.parameter("outer_ask"),
            try asks.constant(void, {}),
        );
        try ctx.c.define(
            asks_fn,
            try asks.ret(try asks.resumeValue(try asks.parameter("resumption"), answer_value)),
        );
    }
    return defineScopedForwarders(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .pair = ctx.pair,
        .log = ctx.log,
        .family = ctx.family,
        .reader = ctx.reader,
        .forwarding = ctx.forwarding,
    });
}

fn defineScopedForwarders(
    ctx: anytype,
) a.Error!source.Module {
    inline for (ctx.forwarding.*) |handler| {
        const clause_fn = try ctx.c.clauseFunctionFor(handler, ctx.family.local());
        const clause = try ctx.c.body(clause_fn);
        const wrapper_fn = try ctx.c.functionFor("forward scoped body", ctx.family.inside());
        const wrapper = try clause.closureBody(wrapper_fn);
        const wrapped = try wrapper.handleWith(
            ctx.forwarding[1],
            try clause.parameter("inside"),
            .{
                .outer_ask = try wrapper.parameter("ask"),
                .outer_local = try wrapper.parameter("local"),
            },
        );
        try ctx.c.define(wrapper_fn, try wrapper.ret(wrapped));
        _ = try clause.perform(ctx.log, try clause.constant(u64, 2));
        const forwarded = try clause.performScoped(
            ctx.family.local(),
            try clause.parameter("outer_local"),
            try clause.parameter("payload"),
            .{ .inside = try clause.lambda(wrapper_fn, ctx.family.inside()) },
        );
        try ctx.c.define(
            clause_fn,
            try clause.ret(try clause.resumeValue(
                try clause.parameter("resumption"),
                forwarded,
            )),
        );
    }
    return defineClient(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .pair = ctx.pair,
        .log = ctx.log,
        .family = ctx.family,
        .reader = ctx.reader,
        .forwarding = ctx.forwarding,
    });
}

fn defineClient(
    ctx: anytype,
) a.Error!source.Module {
    const inside_fn = try ctx.c.functionFor("local read", ctx.family.inside());
    const inside = try ctx.c.body(inside_fn);
    try ctx.c.define(
        inside_fn,
        try inside.ret(try inside.performLocal(
            ctx.family.ask(),
            try inside.parameter("ask"),
            try inside.constant(void, {}),
        )),
    );
    const client_schema = try ctx.c.handledSchema(ctx.forwarding[0]);
    const client_fn = try ctx.c.functionFor("client", client_schema);
    const client = try ctx.c.body(client_fn);
    const local = try client.performScoped(
        ctx.family.local(),
        try client.parameter("local"),
        try client.constant(u64, 20),
        .{ .inside = try client.lambda(inside_fn, ctx.family.inside()) },
    );
    const outer = try client.performLocal(
        ctx.family.ask(),
        try client.parameter("ask"),
        try client.constant(void, {}),
    );
    try ctx.c.define(
        client_fn,
        try client.ret(try client.product(ctx.pair, .{ .local = local, .outer = outer })),
    );
    return interpretClient(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .pair = ctx.pair,
        .log = ctx.log,
        .reader = ctx.reader,
        .forwarding = ctx.forwarding,
        .client_schema = client_schema,
        .client_fn = client_fn,
    });
}

fn interpretClient(
    ctx: anytype,
) a.Error!source.Module {
    const reader_schema = try ctx.c.handledSchema(ctx.reader.handler);
    const reader_fn = try ctx.c.functionFor("reader body", reader_schema);
    const reader_body = try ctx.c.body(reader_fn);
    const interpreted = try reader_body.handleWith(
        ctx.forwarding[0],
        try reader_body.lambda(ctx.client_fn, ctx.client_schema),
        .{
            .outer_ask = try reader_body.parameter("ask"),
            .outer_local = try reader_body.parameter("local"),
        },
    );
    try ctx.c.define(reader_fn, try reader_body.ret(interpreted));
    const main = try ctx.c.function("entry", .{}, ctx.pair, &.{ctx.log});
    const entry = try ctx.c.body(main);
    try ctx.c.define(
        main,
        try entry.ret(try entry.handleWith(
            ctx.reader.handler,
            try entry.lambda(reader_fn, reader_schema),
            .{ .environment = try entry.constant(u64, 10) },
        )),
    );
    return ctx.c.module(main, ctx.unit);
}
