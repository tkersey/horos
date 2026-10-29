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
        .{
            .inside_captures = &.{},
            .residual = &.{log},
            .borrowed_regions = &.{},
        },
    );
    const reader = try reader_library.interpret(c, family, pair, .{
        .captures = .{ .continuation = captures },
    });
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

pub const LogicalFrame = struct { domain: u64, key: u64, metadata: u64 };
pub const LogicalRead = struct { current: []const LogicalFrame, snapshot: []const LogicalFrame };
pub const LogicalScope = struct {
    inner: []const LogicalFrame,
    outer: []const LogicalFrame,
    snapshot: []const LogicalFrame,
};
pub const LogicalRetention = struct {
    current: []const LogicalFrame,
    snapshots: []const []const LogicalFrame,
};

pub fn logicalContext(b: *source.Builder) source.Error!source.Module {
    return logicalScopeAuthored(b) catch |err| return a.sourceError(err);
}

fn logicalScopeAuthored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const frame = try c.schema(LogicalFrame);
    const context = try c.schema([]const LogicalFrame);
    const result = try c.schema(LogicalScope);
    const read = try c.schema(LogicalRead);
    const cleanup = try c.external("logical-context/cleanup", context, unit);
    const family = try reader_library.family(c, "logical-context/read", context, read, .{
        .inside_captures = &.{context},
        .residual = &.{cleanup},
        .borrowed_regions = &.{},
    });
    const work = try c.callable(.{}, context, &.{ family.ask(), cleanup }, .{
        .use = .linear,
        .captures = &.{family.askCapability()},
        .regions = &.{},
    });
    const clean = try c.callable(.{ .exit = try c.cleanupInfo(unit) }, unit, &.{cleanup}, .{
        .use = .linear,
        .captures = &.{context},
        .regions = &.{},
    });
    const nested_token = try c.declareSchema(.resumption, a.Dynamic);
    const bounds = .{
        unit,                  integer,                frame,                    context,
        read,                  result,                 work,                     clean,
        nested_token.schema(), family.askCapability(), family.localCapability(),
    };
    const reader = try reader_library.interpret(c, family, result, .{
        .captures = .{ .continuation = bounds },
    });
    const nested = try c.handlerSet(.{ .ask = family.ask() }, context, context, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{ family.ask(), cleanup },
        .return_effects = &.{},
        .captures = bounds,
        .body_captures = &.{family.askCapability()},
        .state = .{ .environment = context },
        .resumption_slots = &.{nested_token},
    });
    const returns_fn = try c.returnFunction(nested);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
    const clause_fn = try c.clauseFunctionFor(nested, family.ask());
    const clause = try c.body(clause_fn);
    try c.define(clause_fn, try clause.ret(try clause.resumeValue(
        try clause.parameter("resumption"),
        try clause.parameter("environment"),
    )));
    return logicalScopeBodies(.{
        .c = c,
        .unit = unit,
        .integer = integer,
        .frame = frame,
        .context = context,
        .result = result,
        .read = read,
        .cleanup = cleanup,
        .family = family,
        .work = work,
        .clean = clean,
        .reader = reader,
        .nested = nested,
    });
}

fn logicalScopeBodies(ctx: anytype) a.Error!source.Module {
    const inside_fn = try ctx.c.functionFor("logical scope", ctx.family.inside());
    const inside = try ctx.c.body(inside_fn);
    const ask = try inside.parameter("ask");
    const snapshot = try inside.performLocal(ctx.family.ask(), ask, try inside.constant(void, {}));
    const work_fn = try ctx.c.functionFor("suspended context", ctx.work);
    const work = try inside.closureBody(work_fn);
    _ = try work.yieldNow();
    const nested_schema = try ctx.c.handledSchema(ctx.nested);
    const nested_fn = try ctx.c.functionFor("explicit captured context", nested_schema);
    const nested = try work.closureBody(nested_fn);
    try ctx.c.define(nested_fn, try nested.ret(try nested.performLocal(
        ctx.family.ask(),
        ask,
        try nested.constant(void, {}),
    )));
    try ctx.c.define(work_fn, try work.ret(try work.handleWith(
        ctx.nested,
        try work.lambda(nested_fn, nested_schema),
        .{ .environment = try work.sequenceValue(ctx.context, .{
            try logicalFrame(work, ctx.frame, try work.constant(u64, 999)),
        }) },
    )));
    const restored = try inside.apply(try inside.lambda(work_fn, ctx.work), .{});
    try ctx.c.define(inside_fn, try inside.ret(try inside.product(ctx.read, .{
        .current = restored,
        .snapshot = snapshot,
    })));
    return logicalScopeClient(ctx, inside_fn);
}

fn logicalScopeClient(ctx: anytype, inside_fn: anytype) a.Error!source.Module {
    const client_schema = try ctx.c.handledSchema(ctx.reader.handler);
    const client_fn = try ctx.c.functionFor("logical client", client_schema);
    const client = try ctx.c.body(client_fn);
    const outer = try client.performLocal(
        ctx.family.ask(),
        try client.parameter("ask"),
        try client.constant(void, {}),
    );
    const annotation = try logicalFrame(client, ctx.frame, try client.constant(u64, 20));
    const inner = try client.append(outer, annotation, .{});
    const scoped = try client.performScoped(
        ctx.family.local(),
        try client.parameter("local"),
        inner,
        .{ .inside = try client.lambda(inside_fn, ctx.family.inside()) },
    );
    const restored = try client.performLocal(
        ctx.family.ask(),
        try client.parameter("ask"),
        try client.constant(void, {}),
    );
    try ctx.c.define(client_fn, try client.ret(try client.product(ctx.result, .{
        .inner = try client.field(scoped, "current"),
        .outer = restored,
        .snapshot = try client.field(scoped, "snapshot"),
    })));
    return logicalScopeEntry(ctx, client_fn, client_schema);
}

fn logicalScopeEntry(
    ctx: anytype,
    client_fn: anytype,
    client_schema: anytype,
) a.Error!source.Module {
    const protected_schema = try ctx.c.callable(
        .{ .seed = ctx.integer },
        ctx.result,
        &.{ctx.cleanup},
        .{ .use = .linear, .captures = &.{}, .regions = &.{} },
    );
    const protected_fn = try ctx.c.functionFor("protected logical scopes", protected_schema);
    const protected = try ctx.c.body(protected_fn);
    const initial = try protected.sequenceValue(ctx.context, .{
        try logicalFrame(protected, ctx.frame, try protected.parameter("seed")),
    });
    try ctx.c.define(protected_fn, try protected.ret(try protected.handleWith(
        ctx.reader.handler,
        try protected.lambda(client_fn, client_schema),
        .{ .environment = initial },
    )));
    const main = try ctx.c.function(
        "logical context",
        .{ .seed = ctx.integer },
        ctx.result,
        &.{ctx.cleanup},
    );
    const entry = try ctx.c.body(main);
    const snapshot = try entry.sequenceValue(ctx.context, .{
        try logicalFrame(entry, ctx.frame, try entry.parameter("seed")),
        try logicalFrame(entry, ctx.frame, try entry.constant(u64, 20)),
    });
    const clean_fn = try ctx.c.functionFor("snapshot cleanup", ctx.clean);
    const clean = try entry.closureBody(clean_fn);
    try ctx.c.define(clean_fn, try clean.ret(try clean.perform(ctx.cleanup, snapshot)));
    try ctx.c.define(main, try entry.ret(try entry.protect(
        try entry.lambda(protected_fn, protected_schema),
        try entry.lambda(clean_fn, ctx.clean),
        .{ .seed = try entry.parameter("seed") },
    )));
    return ctx.c.module(main, ctx.unit);
}

pub fn logicalRetention(b: *source.Builder, retain: bool) source.Error!source.Module {
    return logicalRetentionAuthored(b, retain) catch |err| return a.sourceError(err);
}

fn logicalRetentionAuthored(b: *source.Builder, retain: bool) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const frame = try c.schema(LogicalFrame);
    const context = try c.schema([]const LogicalFrame);
    const history = try c.schema([]const []const LogicalFrame);
    const result = try c.schema(LogicalRetention);
    const fault = try c.literalFailure(void, {});
    const loop = try c.function("replace current annotation", .{
        .remaining = integer,
        .current = context,
        .snapshots = history,
    }, result, &.{});
    const body = try c.body(loop);
    const remaining = try body.parameter("remaining");
    const current = try body.parameter("current");
    const snapshots = try body.parameter("snapshots");
    const done = try body.branch();
    _ = try done.yieldNow();
    const final = try done.product(result, .{ .current = current, .snapshots = snapshots });
    const step = try body.branch();
    const annotation = try logicalFrame(step, frame, remaining);
    const updated = try step.sequenceSet(current, try step.constant(u64, 0), annotation, fault);
    const retained = if (retain) try step.append(snapshots, updated, .{}) else snapshots;
    _ = try step.yieldNow();
    const next = try step.call(loop, .{
        .remaining = try step.checked(
            .subtract,
            remaining,
            try step.constant(u64, 1),
            .{ .overflow = fault },
        ),
        .current = updated,
        .snapshots = retained,
    });
    try c.define(loop, try body.ret(try body.conditional(
        try body.equal(remaining, try body.constant(u64, 0)),
        try done.ret(final),
        try step.ret(next),
    )));
    const main = try c.function("logical retention", .{ .count = integer }, result, &.{});
    const entry = try c.body(main);
    try c.define(main, try entry.ret(try entry.call(loop, .{
        .remaining = try entry.parameter("count"),
        .current = try entry.sequenceValue(context, .{
            try logicalFrame(entry, frame, try entry.constant(u64, 0)),
        }),
        .snapshots = try entry.sequenceValue(history, .{}),
    })));
    return c.module(main, unit);
}

pub fn logicalBranching(b: *source.Builder) source.Error!source.Module {
    return logicalBranchingAuthored(b) catch |err| return a.sourceError(err);
}

fn logicalBranchingAuthored(b: *source.Builder) a.Error!source.Module {
    const choice = @import("../library/choice.zig");
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const boolean = try c.schema(bool);
    const integer = try c.schema(u64);
    const frame = try c.schema(LogicalFrame);
    const context = try c.schema([]const LogicalFrame);
    const family = try reader_library.family(
        c,
        "logical-context/branch-read",
        context,
        context,
        .{ .inside_captures = &.{}, .residual = &.{}, .borrowed_regions = &.{} },
    );
    const reader = try reader_library.interpret(c, family, context, .{
        .captures = .{ .continuation = &.{ unit, integer, frame, context } },
    });
    const branch = try choice.family(c, "logical-context/branch");
    const all = try choice.all(c, branch, context, .{
        .captures = .{
            .continuation = &.{ unit, boolean, integer, frame, context, branch.capability() },
            .body = &.{context},
        },
        .residual = &.{},
    });
    const read_schema = try c.handledSchema(reader.handler);
    const read_fn = try c.functionFor("read branch context", read_schema);
    const read = try c.body(read_fn);
    try c.define(read_fn, try read.ret(try read.performLocal(
        family.ask(),
        try read.parameter("ask"),
        try read.constant(void, {}),
    )));
    const main = try c.function("logical snapshots", .{ .seed = integer }, all.answer, &.{});
    const entry = try c.body(main);
    const prefix = try entry.sequenceValue(context, .{
        try logicalFrame(entry, frame, try entry.parameter("seed")),
    });
    const choose_schema = try c.handledSchema(all.handler);
    const choose_fn = try c.functionFor("snapshot alternatives", choose_schema);
    const choose = try entry.closureBody(choose_fn);
    const selected = try choose.performLocal(
        branch.effect(),
        try choose.parameter("capability"),
        try choose.constant(void, {}),
    );
    const annotation = try choose.product(frame, .{
        .domain = try choose.constant(u64, 1),
        .key = try choose.constant(u64, 7),
        .metadata = try choose.select(
            selected,
            try choose.constant(u64, 101),
            try choose.constant(u64, 202),
        ),
    });
    const local = try choose.append(prefix, annotation, .{});
    try c.define(choose_fn, try choose.ret(try choose.handleWith(
        reader.handler,
        try choose.lambda(read_fn, read_schema),
        .{ .environment = local },
    )));
    try c.define(main, try entry.ret(try entry.handleWith(
        all.handler,
        try entry.lambda(choose_fn, choose_schema),
        .{},
    )));
    return c.module(main, unit);
}

fn logicalFrame(body: anytype, frame: anytype, metadata: anytype) a.Error!*const a.Value(
    a.Shape(LogicalFrame),
) {
    return body.product(frame, .{
        .domain = try body.constant(u64, 1),
        .key = try body.constant(u64, 7),
        .metadata = metadata,
    });
}

pub const LogicalLookup = union(enum) { absent: void, present: u64 };

pub fn logicalQuery(b: *source.Builder) source.Error!source.Module {
    return logicalQueryAuthored(b) catch |err| return a.sourceError(err);
}

fn logicalQueryAuthored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const context = try c.schema([]const LogicalFrame);
    const answer = try c.schema(LogicalLookup);
    const lookup = try c.function("newest matching logical annotation", .{
        .frames = context,
        .domain = integer,
        .key = integer,
    }, answer, &.{});
    const body = try c.body(lookup);
    const frames = try body.parameter("frames");
    const domain = try body.parameter("domain");
    const key = try body.parameter("key");
    const popped = try body.sequencePopLast(frames);
    const rest = try body.field(popped, "rest");
    const last = try body.field(popped, "last");
    const missing = try body.caseOf(last, "none");
    const present = try body.caseOf(last, "some");
    const found = present.payload();
    const matching = try present.body().branch();
    const preceding = try present.body().branch();
    const same_domain = try present.body().equal(try present.body().field(found, "domain"), domain);
    const same_key = try present.body().equal(try present.body().field(found, "key"), key);
    const matches = try present.body().select(
        same_domain,
        same_key,
        try present.body().constant(bool, false),
    );
    const matched = try matching.variant(answer, "present", try matching.field(found, "metadata"));
    const retried = try preceding.call(lookup, .{ .frames = rest, .domain = domain, .key = key });
    const result = try present.body().conditional(
        matches,
        try matching.ret(matched),
        try preceding.ret(retried),
    );
    try c.define(lookup, try body.ret(try body.match(last, .{
        .none = try missing.ret(try missing.body().variant(
            answer,
            "absent",
            try missing.body().constant(void, {}),
        )),
        .some = try present.ret(result),
    })));
    return c.module(lookup, unit);
}
