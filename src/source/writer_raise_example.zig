// Copyright (c) 2026 Boundary contributors. MIT license.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const writer = @import("../library/writer.zig");
const raise = @import("../library/raise.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    return authored(b) catch |err| return a.sourceError(err);
}
fn authored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const region = try c.region();
    const w = try writer.family(c, "example/writer", integer);
    const r = try raise.family(c, "example/raise", integer);
    const caught = try raise.catching(c, r, integer, .{
        .captures = .{
            .continuation = &.{ unit, integer, w.capability() },
            .body = &.{w.capability()},
        },
        .residual = &.{w.effect()},
        .borrowed_regions = &.{region},
    });
    const written = try writer.interpret(c, w, caught.answer, region, .{
        .captures = .{ .continuation = &.{ unit, integer, caught.answer, r.capability() } },
        .residual = &.{},
    });
    return declareProtectedWork(.{
        .c = c,
        .unit = unit,
        .integer = integer,
        .region = region,
        .w = w,
        .r = r,
        .caught = caught,
        .written = written,
    });
}

fn declareProtectedWork(
    ctx: anytype,
) a.Error!source.Module {
    const main = try ctx.c.function("entry", .{}, ctx.written.answer, &.{});
    const entry = try ctx.c.body(main);
    const inside_type = try ctx.c.regionBodySchema(
        ctx.region,
        .{},
        ctx.written.answer,
        &.{},
        .{ .use = .linear, .captures = &.{} },
    );
    const inside_fn = try ctx.c.functionFor("writer region", inside_type);
    const inside = try ctx.c.body(inside_fn);
    const written_type = try ctx.c.handledSchema(ctx.written.handler);
    const written_fn = try ctx.c.functionFor("written work", written_type);
    const written_body = try ctx.c.body(written_fn);
    const write_capability = try written_body.parameter("capability");
    const caught_type = try ctx.c.handledSchema(ctx.caught.handler);
    const caught_fn = try ctx.c.functionFor("caught work", caught_type);
    const caught_body = try written_body.closureBody(caught_fn);
    const raise_capability = try caught_body.parameter("capability");
    const body_type = try ctx.c.callable(.{}, ctx.integer, &.{ ctx.w.effect(), ctx.r.effect() }, .{
        .use = .linear,
        .captures = &.{ ctx.w.capability(), ctx.r.capability() },
        .regions = &.{ctx.region},
    });
    const body_fn = try ctx.c.functionFor("raise under protection", body_type);
    const body = try caught_body.closureBody(body_fn);
    _ = try body.performLocal(ctx.w.effect(), write_capability, try body.constant(u64, 1));
    _ = try body.performLocal(ctx.r.effect(), raise_capability, try body.constant(u64, 9));
    _ = try body.performLocal(ctx.w.effect(), write_capability, try body.constant(u64, 2));
    try ctx.c.define(body_fn, try body.ret(try body.constant(u64, 42)));
    return defineCleanup(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .region = ctx.region,
        .w = ctx.w,
        .caught = ctx.caught,
        .written = ctx.written,
        .main = main,
        .entry = entry,
        .inside_type = inside_type,
        .inside_fn = inside_fn,
        .inside = inside,
        .written_type = written_type,
        .written_fn = written_fn,
        .written_body = written_body,
        .write_capability = write_capability,
        .caught_type = caught_type,
        .caught_fn = caught_fn,
        .caught_body = caught_body,
        .body_type = body_type,
        .body_fn = body_fn,
    });
}

fn defineCleanup(
    ctx: anytype,
) a.Error!source.Module {
    const cleanup_type = try ctx.c.callable(
        .{ .exit = try ctx.c.cleanupInfo(ctx.unit) },
        ctx.unit,
        &.{ctx.w.effect()},
        .{ .use = .linear, .captures = &.{ctx.w.capability()}, .regions = &.{ctx.region} },
    );
    const cleanup_fn = try ctx.c.functionFor("log cleanup", cleanup_type);
    const cleanup_body = try ctx.written_body.closureBody(cleanup_fn);
    try ctx.c.define(
        cleanup_fn,
        try cleanup_body.ret(try cleanup_body.performLocal(
            ctx.w.effect(),
            ctx.write_capability,
            try cleanup_body.constant(u64, 3),
        )),
    );
    try ctx.c.define(ctx.caught_fn, try ctx.caught_body.ret(try ctx.caught_body.protect(
        try ctx.caught_body.lambda(ctx.body_fn, ctx.body_type),
        try ctx.caught_body.lambda(cleanup_fn, cleanup_type),
        .{},
    )));
    try ctx.c.define(
        ctx.written_fn,
        try ctx.written_body.ret(try ctx.written_body.handleWith(
            ctx.caught.handler,
            try ctx.written_body.lambda(ctx.caught_fn, ctx.caught_type),
            .{},
        )),
    );
    return interpretWriter(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .region = ctx.region,
        .written = ctx.written,
        .main = ctx.main,
        .entry = ctx.entry,
        .inside_type = ctx.inside_type,
        .inside_fn = ctx.inside_fn,
        .inside = ctx.inside,
        .written_type = ctx.written_type,
        .written_fn = ctx.written_fn,
    });
}

fn interpretWriter(
    ctx: anytype,
) a.Error!source.Module {
    const cell = try ctx.inside.newCell(
        ctx.written.cell,
        try ctx.inside.parameter("region"),
        try ctx.inside.sequenceValue(ctx.written.sequence, &.{}),
    );
    try ctx.c.define(
        ctx.inside_fn,
        try ctx.inside.ret(try ctx.inside.handleWith(
            ctx.written.handler,
            try ctx.inside.lambda(ctx.written_fn, ctx.written_type),
            .{ .log = cell },
        )),
    );
    try ctx.c.define(
        ctx.main,
        try ctx.entry.ret(try ctx.entry.withRegion(
            ctx.region,
            try ctx.entry.lambda(ctx.inside_fn, ctx.inside_type),
            .{},
        )),
    );
    return ctx.c.module(ctx.main, ctx.unit);
}
