const source = @import("source.zig");
const a = @import("authoring.zig");
const hyper = @import("library/hyper.zig");

pub const Kind = enum {
    constant_peer,
    ignored_argument,
    unused_query,
    ignored_successor,
    demanded_successor,
    lazy_product,
    lazy_sum,
    lazy_stream,
    stream_head,
    identity_project,
    run_constant,
};

pub fn build(raw: *source.Builder, kind: Kind) !source.Module {
    return switch (kind) {
        .constant_peer => constantPeer(raw),
        .ignored_argument => ignoredArgument(raw),
        .unused_query, .ignored_successor, .demanded_successor => queryCase(raw, kind),
        .lazy_product => lazyProduct(raw),
        .lazy_sum => lazySum(raw),
        .lazy_stream, .stream_head => lazyStream(raw, kind == .stream_head),
        .identity_project, .run_constant => observation(raw, kind == .run_constant),
    };
}

fn failing(body: anytype, schema: anytype) !*const a.Value(a.ShapeOf(@TypeOf(schema))) {
    const c = try body.context();
    const function = try c.functionFor("failing delay", schema);
    const nested = try body.closureBody(function);
    try c.define(function, try nested.fail(
        try schema.resultSchema(),
        try nested.constant(void, {}),
    ));
    return body.lambda(function, schema);
}

fn lazyProduct(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const entry = try c.function("lazy product", .{}, integer, .{});
    const body = try c.body(entry);
    const value = try hyper.lazyProduct(body, .{
        .first = try hyper.deferValue(body, delay, try body.constant(u64, 23)),
        .second = try failing(body, delay),
    });
    const answer = try hyper.force(body, try body.field(value, "first"));
    try c.define(entry, try body.ret(answer));
    return c.module(entry, try c.schema(void));
}

fn lazySum(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const choices = try c.alternatives(.{ .good = delay, .bad = delay });
    const entry = try c.function("lazy sum", .{}, integer, .{});
    const body = try c.body(entry);
    const value = try hyper.lazySum(body, choices, "bad", try failing(body, delay));
    try c.define(entry, try body.ret(try body.variantTag(value)));
    return c.module(entry, try c.schema(void));
}

fn lazyStream(raw: *source.Builder, demand_head: bool) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const definition = try hyper.stream(c, integer, .{});
    const entry = try c.function("lazy stream", .{}, integer, .{});
    const body = try c.body(entry);
    _ = try hyper.emptyStream(body, definition);
    const head = if (demand_head)
        try hyper.deferValue(body, definition.element(), try body.constant(u64, 23))
    else
        try failing(body, definition.element());
    const value = try hyper.cons(body, definition, head, try failing(body, definition.spine()));
    const answer = if (demand_head) try streamHead(body, value) else try body.variantTag(value);
    try c.define(entry, try body.ret(answer));
    return c.module(entry, try c.schema(void));
}

fn streamHead(body: anytype, value: anytype) a.Error!*const a.Value(a.Shape(u64)) {
    const none = try body.caseOf(value, "none");
    const some = try body.caseOf(value, "some");
    const head = try some.body().field(some.payload(), "head");
    return body.match(value, .{
        .none = try none.ret(try none.body().constant(u64, 0)),
        .some = try some.ret(try hyper.force(some.body(), head)),
    });
}

fn observation(raw: *source.Builder, run_constant: bool) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const types_value = try hyper.pair(c, integer, integer, .{});
    const entry = try c.function("observation", .{}, integer, .{});
    const body = try c.body(entry);
    const delay = if (run_constant) types_value.answerForward() else types_value.answerBackward();
    const value = try hyper.deferValue(body, delay, try body.constant(u64, 42));
    const answer = if (run_constant)
        try hyper.run(body, types_value, try hyper.base(body, types_value, value))
    else
        try hyper.project(body, types_value, try hyper.identity(body, types_value), value);
    try c.define(entry, try body.ret(try hyper.force(body, answer)));
    return c.module(entry, try c.schema(void));
}

fn diverging(body: anytype, schema: anytype) !*const a.Value(a.ShapeOf(@TypeOf(schema))) {
    const c = try body.context();
    const function = try c.functionFor("diverging", schema);
    const nested = try body.closureBody(function);
    try c.define(function, try nested.ret(try nested.call(function, .{})));
    return body.lambda(function, schema);
}

fn constantPeer(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const f = try c.function("constant", .{}, integer, .{});
    const b = try c.body(f);
    const answer = try hyper.deferValue(b, types.answerForward(), try b.constant(u64, 42));
    const participant = try hyper.base(b, types, answer);
    const peer = try diverging(b, types.peerBackward());
    try c.define(f, try b.ret(try hyper.force(b, try hyper.invoke(b, participant, peer))));
    return c.module(f, try c.schema(void));
}

fn ignoredArgument(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const transform = try c.function("constant transform", .{
        .argument = types.answerBackward(),
    }, types.answerForward(), .{});
    const transform_body = try c.body(transform);
    try c.define(transform, try transform_body.ret(try hyper.deferValue(
        transform_body,
        types.answerForward(),
        try transform_body.constant(u64, 43),
    )));
    const f = try c.function("ignored argument", .{}, integer, .{});
    const b = try c.body(f);
    const participant = try hyper.lift(b, types, transform);
    const peer = try diverging(b, types.peerBackward());
    try c.define(f, try b.ret(try hyper.force(b, try hyper.invoke(b, participant, peer))));
    return c.module(f, try c.schema(void));
}

const QueryStep = struct {
    state_delay: *const a.Schema(hyper.Delayed(a.Shape(u64))),
    kind: Kind,
    emissions: *usize,

    pub fn emit(
        self: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(a.Shape(u64))) {
        self.emissions.* += 1;
        const c = try body.context();
        const function = try c.functionFor("query answer", query.types().answerForward());
        const nested = try body.closureBody(function);
        const condition = try nested.equal(query.state(), try nested.constant(u64, 0));
        const initial_body = try nested.branch();
        const result = try self.initial(initial_body, query);
        const terminal = try nested.branch();
        const done = try terminal.checkedAdd(
            query.state(),
            try terminal.constant(u64, 41),
            try c.literalFailure(void, {}),
        );
        try c.define(function, try nested.ret(try nested.conditional(
            condition,
            try initial_body.ret(result),
            try terminal.ret(done),
        )));
        return body.ret(try body.lambda(function, query.types().answerForward()));
    }

    fn initial(self: @This(), body: anytype, query: anytype) a.Error!*const a.Value(a.Shape(u64)) {
        const c = try body.context();
        const function = try c.functionFor("successor state", self.state_delay);
        const nested = try body.closureBody(function);
        const successor = if (self.kind == .demanded_successor)
            try nested.ret(try nested.constant(u64, 1))
        else
            try nested.fail(try c.schema(u64), try nested.constant(void, {}));
        try c.define(function, successor);
        const answer = try query.ask(body, try body.lambda(function, self.state_delay));
        return if (self.kind == .unused_query)
            body.constant(u64, 42)
        else
            hyper.force(body, answer);
    }
};

fn queryCase(raw: *source.Builder, kind: Kind) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const state_delay = try hyper.delayed(c, integer, .{ .captures = .{integer} });
    const types = try hyper.pair(c, integer, integer, .{
        .captures = .{ integer, state_delay },
    });
    const f = try c.function("query", .{}, integer, .{});
    const b = try c.body(f);
    var emissions: usize = 0;
    const definition = try hyper.ana(b, types, integer, QueryStep{
        .kind = kind,
        .state_delay = state_delay,
        .emissions = &emissions,
    });
    const participant = try hyper.start(b, definition, try b.constant(u64, 0));
    _ = try hyper.start(b, definition, try b.constant(u64, 7));
    if (emissions != 1) return error.ExpectedRetainedDefinition;
    const peer = switch (kind) {
        .unused_query => try diverging(b, types.peerBackward()),
        .ignored_successor => try constantCounterpart(b, types),
        .demanded_successor => try demandingCounterpart(b, types),
        else => unreachable,
    };
    const answer = try hyper.invoke(b, participant, peer);
    try c.define(f, try b.ret(try hyper.force(b, answer)));
    return c.module(f, try c.schema(void));
}

fn constantCounterpart(
    body: anytype,
    types: anytype,
) a.Error!*const a.Value(hyper.Delayed(hyper.Hyper(a.Shape(u64), a.Shape(u64)))) {
    const answer = try hyper.deferValue(
        body,
        types.answerBackward(),
        try body.constant(u64, 42),
    );
    const peer = try hyper.base(body, types.swap(), answer);
    return hyper.deferValue(body, types.peerBackward(), peer);
}

fn demandingCounterpart(
    body: anytype,
    types: anytype,
) a.Error!*const a.Value(hyper.Delayed(hyper.Hyper(a.Shape(u64), a.Shape(u64)))) {
    const c = try body.context();
    const function = try c.functionFor("demanding peer", types.backward());
    const nested = try body.closureBody(function);
    const answer = try c.functionFor("demanding answer", types.answerBackward());
    const answer_body = try nested.closureBody(answer);
    const successor = try hyper.force(answer_body, try nested.parameter("peer"));
    const never = try diverging(answer_body, types.peerBackward());
    const result = try hyper.force(answer_body, try hyper.invoke(answer_body, successor, never));
    try c.define(answer, try answer_body.ret(result));
    try c.define(function, try nested.ret(try nested.lambda(answer, types.answerBackward())));
    const peer = try hyper.make(body, types.swap(), function);
    return hyper.deferValue(body, types.peerBackward(), peer);
}
