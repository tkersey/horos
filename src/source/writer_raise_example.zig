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
    const caught = try raise.catching(c, r, integer, .{ .continuation = &.{ unit, integer, w.capability() }, .body = &.{w.capability()} }, &.{w.effect()}, &.{region});
    const written = try writer.interpret(c, w, caught.answer, region, .{ .continuation = &.{ unit, integer, caught.answer, r.capability() } }, &.{});
    const main = try c.function("entry", .{}, written.answer, &.{});
    const entry = try c.body(main);
    const inside_type = try c.regionBodySchema(region, .{}, written.answer, &.{}, .{ .use = .linear, .captures = &.{} });
    const inside_fn = try c.functionFor("writer region", inside_type);
    const inside = try c.body(inside_fn);
    const written_type = try c.handledSchema(written.handler);
    const written_fn = try c.functionFor("written work", written_type);
    const written_body = try c.body(written_fn);
    const write_capability = try written_body.parameter("capability");
    const caught_type = try c.handledSchema(caught.handler);
    const caught_fn = try c.functionFor("caught work", caught_type);
    const caught_body = try written_body.closureBody(caught_fn);
    const raise_capability = try caught_body.parameter("capability");
    const body_type = try c.callable(.{}, integer, &.{ w.effect(), r.effect() }, .{
        .use = .linear,
        .captures = &.{ w.capability(), r.capability() },
        .regions = &.{region},
    });
    const body_fn = try c.functionFor("raise under protection", body_type);
    const body = try caught_body.closureBody(body_fn);
    _ = try body.performLocal(w.effect(), write_capability, try body.constant(u64, 1));
    _ = try body.performLocal(r.effect(), raise_capability, try body.constant(u64, 9));
    _ = try body.performLocal(w.effect(), write_capability, try body.constant(u64, 2));
    try c.define(body_fn, try body.ret(try body.constant(u64, 42)));
    const cleanup_type = try c.callable(.{ .exit = try c.cleanupInfo(unit) }, unit, &.{w.effect()}, .{
        .use = .linear,
        .captures = &.{w.capability()},
        .regions = &.{region},
    });
    const cleanup_fn = try c.functionFor("log cleanup", cleanup_type);
    const cleanup_body = try written_body.closureBody(cleanup_fn);
    try c.define(cleanup_fn, try cleanup_body.ret(try cleanup_body.performLocal(w.effect(), write_capability, try cleanup_body.constant(u64, 3))));
    try c.define(caught_fn, try caught_body.ret(try caught_body.protect(
        try caught_body.lambda(body_fn, body_type),
        try caught_body.lambda(cleanup_fn, cleanup_type),
        .{},
    )));
    try c.define(written_fn, try written_body.ret(try written_body.handleWith(caught.handler, try written_body.lambda(caught_fn, caught_type), .{})));
    const cell = try inside.newCell(written.cell, try inside.parameter("region"), try inside.sequenceValue(written.sequence, &.{}));
    try c.define(inside_fn, try inside.ret(try inside.handleWith(written.handler, try inside.lambda(written_fn, written_type), .{ .log = cell })));
    try c.define(main, try entry.ret(try entry.withRegion(region, try entry.lambda(inside_fn, inside_type), .{})));
    return c.module(main, unit);
}
