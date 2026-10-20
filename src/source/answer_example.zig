// Copyright (c) 2026 Boundary contributors. MIT license.
//! One body and constructor, interpreted into two different answer types.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const state = @import("../library/state.zig");
pub fn build(b: *source.Builder) source.Error!source.Module {
    return authored(b) catch |err| return a.sourceError(err);
}
fn authored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const region = try c.region();
    const family = try state.family(c, "example/answers", integer);
    const captures = &.{ integer, family.getCapability(), family.putCapability() };
    const optional = (try state.interpret(
        c,
        family,
        integer,
        region,
        .{ .continuation = captures },
        &.{},
        .optional,
    )).optional;
    const paired = (try state.interpret(
        c,
        family,
        integer,
        region,
        .{ .continuation = captures },
        &.{},
        .with_state,
    )).with_state;
    const result = try c.record(.{ .optional = optional.answer, .paired = paired.answer });
    const body_type = try c.handledSchema(optional.handler);
    const body_fn = try c.functionFor("increment read", body_type);
    const body = try c.body(body_fn);
    try defineIncrement(c, body, body_fn, family);
    const inside_type = try c.regionBodySchema(
        region,
        .{},
        result,
        &.{},
        .{ .use = .linear, .captures = &.{} },
    );
    const inside_fn = try c.functionFor("shared cell", inside_type);
    const inside = try c.body(inside_fn);
    const cell = try inside.newCell(
        optional.cell,
        try inside.parameter("region"),
        try inside.constant(u64, 9),
    );
    const first = try inside.handleWith(
        optional.handler,
        try inside.lambda(body_fn, body_type),
        .{ .state = cell },
    );
    const second = try inside.handleWith(
        paired.handler,
        try inside.lambda(body_fn, body_type),
        .{ .state = cell },
    );
    try c.define(
        inside_fn,
        try inside.ret(try inside.product(result, .{ .optional = first, .paired = second })),
    );
    const main = try c.function("entry", .{}, result, &.{});
    const entry = try c.body(main);
    try c.define(
        main,
        try entry.ret(try entry.withRegion(
            region,
            try entry.lambda(inside_fn, inside_type),
            .{},
        )),
    );
    return c.module(main, unit);
}

fn defineIncrement(
    c: *a.Context,
    body: anytype,
    body_fn: anytype,
    family: anytype,
) a.Error!void {
    const read = try body.performLocal(
        family.get(),
        try body.parameter("get"),
        try body.constant(void, {}),
    );
    try c.define(
        body_fn,
        try body.ret(try body.checkedAdd(
            read,
            try body.constant(u64, 1),
            try c.literalFailure(void, {}),
        )),
    );
}
