// Copyright (c) 2026 Boundary contributors. MIT license.
//! An authored caller retains a generator with a private cell and exit obligation.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const gen = @import("../library/generator.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    return authored(b) catch |err| return a.sourceError(err);
}
fn authored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const pair = try c.record(.{ .first = integer, .second = integer });
    const scope = try c.region();
    const cell_type = try c.cell(scope, integer);
    const release = try c.external("example/generator-release", integer, unit);
    const generator = try gen.create(c, "example/generator-yield", unit, integer, unit, .{
        .captures = .{ .continuation = &.{ unit, integer, cell_type } },
        .owned_regions = &.{scope},
        .residual = &.{release},
        .body_use = .reusable,
    });
    const effects = &.{ release, generator.effect() };
    const start_type = try c.handledSchema(generator.handler());
    const start_fn = try c.functionFor("generator producer", start_type);
    const start = try c.body(start_fn);
    const capability = try start.parameter("capability");
    const private_type = try c.regionBodySchema(
        scope,
        .{},
        unit,
        effects,
        .{ .use = .reusable, .captures = &.{generator.capability()} },
    );
    const private_fn = try c.functionFor("private generator state", private_type);
    const private = try start.closureBody(private_fn);
    const cell = try private.newCell(
        cell_type,
        try private.parameter("region"),
        try private.constant(u64, 42),
    );
    const body_type = try c.callable(
        .{},
        unit,
        &.{generator.effect()},
        .{
            .use = .reusable,
            .captures = &.{ generator.capability(), cell_type },
            .regions = &.{scope},
        },
    );
    const body_fn = try c.functionFor("generator yields", body_type);
    const body = try private.closureBody(body_fn);
    _ = try body.performLocal(generator.effect(), capability, try body.readCell(cell));
    _ = try body.writeCell(cell, try body.constant(u64, 43));
    _ = try body.performLocal(generator.effect(), capability, try body.readCell(cell));
    try c.define(body_fn, try body.ret(try body.constant(void, {})));
    const cleanup_type = try c.callable(
        .{ .exit = try c.cleanupInfo(unit) },
        unit,
        &.{release},
        .{ .use = .reusable, .captures = &.{cell_type}, .regions = &.{scope} },
    );
    const cleanup_fn = try c.functionFor("generator release", cleanup_type);
    const cleanup = try private.closureBody(cleanup_fn);
    try c.define(
        cleanup_fn,
        try cleanup.ret(try cleanup.perform(release, try cleanup.readCell(cell))),
    );
    try c.define(
        private_fn,
        try private.ret(try private.protect(
            try private.lambda(body_fn, body_type),
            try private.lambda(cleanup_fn, cleanup_type),
            .{},
        )),
    );
    try c.define(
        start_fn,
        try start.ret(try start.withRegion(
            scope,
            try start.lambda(private_fn, private_type),
            .{},
        )),
    );

    const main = try c.function("entry", .{}, pair, &.{release});
    const entry = try c.body(main);
    const answer = try entry.handleWith(
        generator.handler(),
        try entry.lambda(start_fn, start_type),
        .{},
    );
    const done = try entry.caseOf(answer, "done");
    const yielded = try entry.caseOf(answer, "yielded");
    const first = yielded.body();
    const parts = try first.destructure(yielded.payload());
    const first_value = try parts.get("value");
    const future = try parts.get("future");
    _ = try first.yieldNow();
    const answer2 = try first.resumePackage(future, try first.constant(void, {}));
    const done2 = try first.caseOf(answer2, "done");
    const yielded2 = try first.caseOf(answer2, "yielded");
    const second = yielded2.body();
    const parts2 = try second.destructure(yielded2.payload());
    const second_value = try parts2.get("value");
    _ = try second.disposePackage(try parts2.get("future"));
    const result = try second.product(pair, .{ .first = first_value, .second = second_value });
    const next = try first.match(
        answer2,
        .{
            .done = try done2.fail(pair, try done2.body().constant(void, {})),
            .yielded = try yielded2.ret(result),
        },
    );
    try c.define(
        main,
        try entry.ret(try entry.match(
            answer,
            .{
                .done = try done.fail(pair, try done.body().constant(void, {})),
                .yielded = try yielded.ret(next),
            },
        )),
    );
    return c.module(main, unit);
}
