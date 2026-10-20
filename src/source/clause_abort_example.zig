// Copyright (c) 2026 Boundary contributors. MIT license.
//! A clause fails while still owning the continuation of a protected body.
const source = @import("../source.zig");
const a = @import("../authoring.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    return authored(b) catch |err| return a.sourceError(err);
}

fn authored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const info = try c.cleanupInfo(integer);
    const operation = try c.local("example/abort-owned-continuation", unit, unit, .linear);
    const release = try c.external("example/abandoned-release", info, unit);
    const cap = try c.capability(operation);
    const handler = try c.handler(operation, integer, integer, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{release},
        .captures = &.{ unit, cap },
        .obligations = true,
    });
    const returns_fn = try c.returnFunction(handler);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
    const clause_fn = try c.clauseFunction(handler);
    const clause = try c.body(clause_fn);
    try c.define(clause_fn, try clause.fail(integer, try clause.constant(u64, 9)));

    const body_type = try c.handledSchema(handler);
    const body_fn = try c.functionFor("protected work", body_type);
    const body = try c.body(body_fn);
    const capability = try body.parameter("capability");
    const inside_type = try c.callable(.{}, integer, &.{operation}, .{
        .use = .linear,
        .captures = &.{cap},
    });
    const inside_fn = try c.functionFor("request", inside_type);
    const inside = try body.closureBody(inside_fn);
    _ = try inside.performLocal(operation, capability, try inside.constant(void, {}));
    try c.define(inside_fn, try inside.ret(try inside.constant(u64, 42)));
    const cleanup_type = try c.callable(
        .{ .exit = info },
        unit,
        &.{release},
        .{ .use = .linear, .captures = &.{} },
    );
    const cleanup_fn = try c.functionFor("release", cleanup_type);
    const cleanup = try c.body(cleanup_fn);
    try c.define(
        cleanup_fn,
        try cleanup.ret(try cleanup.perform(release, try cleanup.parameter("exit"))),
    );
    const protected = try body.protect(
        try body.lambda(inside_fn, inside_type),
        try body.lambda(cleanup_fn, cleanup_type),
        .{},
    );
    try c.define(body_fn, try body.ret(protected));
    const main = try c.function("entry", .{}, integer, &.{release});
    const entry = try c.body(main);
    try c.define(main, try entry.ret(try entry.handleWith(
        handler,
        try entry.lambda(body_fn, body_type),
        .{},
    )));
    return c.module(main, integer);
}
