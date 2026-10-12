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
    const captures: []const *const a.Schema(a.Dynamic) = &.{ a.interop.erase(unit), a.interop.erase(integer), a.interop.erase(pair), tokens[0], tokens[1], tokens[2], tokens[3] };
    const family = try reader_library.family(c, "example/scoped-reader", integer, integer, &.{}, &.{log}, &.{});
    const reader = try reader_library.interpret(c, family, pair, .{ .continuation = captures });
    const effects = &.{ log, family.ask(), family.local() };
    const bound = try b.allocator().alloc(*const a.Schema(a.Dynamic), captures.len + reader.resumptions.len + 3);
    @memcpy(bound[0..captures.len], captures);
    @memcpy(bound[captures.len..][0..reader.resumptions.len], reader.resumptions);
    @memcpy(bound[bound.len - 3 ..], &[_]*const a.Schema(a.Dynamic){ a.interop.erase(family.askCapability()), a.interop.erase(family.localCapability()), a.interop.erase(family.inside()) });
    const Ops = native.Fields(&.{ "ask", "local" }, &.{ a.ShapeOf(@TypeOf(family.ask())), a.ShapeOf(@TypeOf(family.local())) });
    const State = native.Fields(&.{ "outer_ask", "outer_local" }, &.{ a.ShapeOf(@TypeOf(family.askCapability())), a.ShapeOf(@TypeOf(family.localCapability())) });
    const Empty = native.Fields(&.{}, &.{});
    const Pair = a.ShapeOf(@TypeOf(pair));
    const Integer = a.Shape(u64);
    var forwarding: struct {
        *const a.Handler(a.HandlerShape(Ops, Pair, Pair, State, Empty, .deep)),
        *const a.Handler(a.HandlerShape(Ops, Integer, Integer, State, Empty, .deep)),
    } = undefined;
    inline for (.{ pair, integer }, 0..) |answer, index| {
        const handler = try c.handlerSet(.{ .ask = family.ask(), .local = family.local() }, answer, answer, .{
            .mode = .deep,
            .use = .linear,
            .residual = effects,
            .return_effects = &.{},
            .captures = bound,
            .body_captures = if (index == 0) &.{} else &.{family.inside()},
            .state = .{ .outer_ask = family.askCapability(), .outer_local = family.localCapability() },
            .resumption_slots = declarations[index * 2 ..][0..2],
        });
        forwarding[index] = handler;
        const returns_fn = try c.returnFunction(handler);
        const returns = try c.body(returns_fn);
        try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
        const asks_fn = try c.clauseFunctionFor(handler, family.ask());
        const asks = try c.body(asks_fn);
        _ = try asks.perform(log, try asks.constant(u64, 1));
        const answer_value = try asks.performLocal(family.ask(), try asks.parameter("outer_ask"), try asks.constant(void, {}));
        try c.define(asks_fn, try asks.ret(try asks.resumeValue(try asks.parameter("resumption"), answer_value)));
    }
    inline for (forwarding) |handler| {
        const clause_fn = try c.clauseFunctionFor(handler, family.local());
        const clause = try c.body(clause_fn);
        const wrapper_fn = try c.functionFor("forward scoped body", family.inside());
        const wrapper = try clause.closureBody(wrapper_fn);
        const wrapped = try wrapper.handleWith(forwarding[1], try clause.parameter("inside"), .{ .outer_ask = try wrapper.parameter("ask"), .outer_local = try wrapper.parameter("local") });
        try c.define(wrapper_fn, try wrapper.ret(wrapped));
        _ = try clause.perform(log, try clause.constant(u64, 2));
        const forwarded = try clause.performScoped(family.local(), try clause.parameter("outer_local"), try clause.parameter("payload"), .{ .inside = try clause.lambda(wrapper_fn, family.inside()) });
        try c.define(clause_fn, try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), forwarded)));
    }
    const inside_fn = try c.functionFor("local read", family.inside());
    const inside = try c.body(inside_fn);
    try c.define(inside_fn, try inside.ret(try inside.performLocal(family.ask(), try inside.parameter("ask"), try inside.constant(void, {}))));
    const client_schema = try c.handledSchema(forwarding[0]);
    const client_fn = try c.functionFor("client", client_schema);
    const client = try c.body(client_fn);
    const local = try client.performScoped(family.local(), try client.parameter("local"), try client.constant(u64, 20), .{ .inside = try client.lambda(inside_fn, family.inside()) });
    const outer = try client.performLocal(family.ask(), try client.parameter("ask"), try client.constant(void, {}));
    try c.define(client_fn, try client.ret(try client.product(pair, .{ .local = local, .outer = outer })));
    const reader_schema = try c.handledSchema(reader.handler);
    const reader_fn = try c.functionFor("reader body", reader_schema);
    const reader_body = try c.body(reader_fn);
    const interpreted = try reader_body.handleWith(forwarding[0], try reader_body.lambda(client_fn, client_schema), .{ .outer_ask = try reader_body.parameter("ask"), .outer_local = try reader_body.parameter("local") });
    try c.define(reader_fn, try reader_body.ret(interpreted));
    const main = try c.function("entry", .{}, pair, &.{log});
    const entry = try c.body(main);
    try c.define(main, try entry.ret(try entry.handleWith(reader.handler, try entry.lambda(reader_fn, reader_schema), .{ .environment = try entry.constant(u64, 10) })));
    return c.module(main, unit);
}
