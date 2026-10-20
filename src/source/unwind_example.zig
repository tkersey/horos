// Copyright (c) 2026 Boundary contributors. MIT license.
//! Nested cleanup keeps its primary exit, records both failures, and continues
//! to an outer effect with the complete accumulated ExitInfo.
const source = @import("../source.zig");
const cleanup = @import("../library/cleanup.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    return buildWithYield(b, false);
}

pub fn yielding(b: *source.Builder) source.Error!source.Module {
    return buildWithYield(b, true);
}

fn buildWithYield(b: *source.Builder, comptime yielding_cleanup: bool) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const exit_info = try cleanup.exitInfo(b, integer);
    const middle_effect = try b.effect(.{
        .identity = "example/middle-cleanup",
        .payload = exit_info,
        .result = unit,
    });
    const outer_effect = try b.effect(.{
        .identity = "example/outer-cleanup",
        .payload = exit_info,
        .result = unit,
    });
    const main = try b.declare(&.{boolean}, integer, &.{ middle_effect, outer_effect }, &.{});
    const body = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(
        body,
        try b.term(.{ .conditional = .{
            .condition = try b.reference(b.parameter(main, 0)),
            .when_true = try b.term(.{ .fail = try b.constant(u64, 9) }),
            .when_false = try b.pure(try b.constant(u64, 42)),
        } }),
    );
    const inner = try b.declare(&.{exit_info}, unit, &.{}, &.{});
    try b.define(inner, try b.term(.{ .fail = try b.constant(u64, 7) }));
    return defineMiddleCleanup(b, yielding_cleanup, .{
        .unit = unit,
        .integer = integer,
        .boolean = boolean,
        .exit_info = exit_info,
        .middle_effect = middle_effect,
        .outer_effect = outer_effect,
        .main = main,
        .body = body,
        .inner = inner,
    });
}

fn defineMiddleCleanup(
    b: *source.Builder,
    comptime yielding_cleanup: bool,
    ctx: anytype,
) source.Error!source.Module {
    const middle = try b.declare(&.{ctx.exit_info}, ctx.unit, &.{ctx.middle_effect}, &.{});
    const middle_info = try b.reference(b.parameter(middle, 0));
    const suspended = if (yielding_cleanup) blk: {
        // The call after the yield is internal; run must continue to the request.
        const request = try b.declare(&.{ctx.exit_info}, ctx.unit, &.{ctx.middle_effect}, &.{});
        try b.define(
            request,
            try b.term(.{ .perform = .{
                .effect = ctx.middle_effect,
                .payload = try b.reference(b.parameter(request, 0)),
            } }),
        );
        break :blk try b.term(.{ .call = .{ .function = request, .arguments = &.{middle_info} } });
    } else try b.term(.{ .perform = .{ .effect = ctx.middle_effect, .payload = middle_info } });
    const failure = try b.term(.{ .fail = try b.constant(u64, 8) });
    const after_request = if (yielding_cleanup) blk: {
        const resume_cleanup = try b.declare(&.{}, ctx.unit, &.{}, &.{});
        try b.define(resume_cleanup, try b.pure(try b.constant(void, {})));
        const resumed = try b.term(.{ .call = .{ .function = resume_cleanup, .arguments = &.{} } });
        break :blk try b.term(.{ .yield_then = try b.bind(
            try b.variable(ctx.unit),
            resumed,
            failure,
        ) });
    } else failure;
    const middle_body = try b.bind(try b.variable(ctx.unit), suspended, after_request);
    try b.define(
        middle,
        if (yielding_cleanup) try b.term(.{ .yield_then = middle_body }) else middle_body,
    );
    return declareCleanupBodies(b, .{
        .unit = ctx.unit,
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .exit_info = ctx.exit_info,
        .middle_effect = ctx.middle_effect,
        .outer_effect = ctx.outer_effect,
        .main = ctx.main,
        .body = ctx.body,
        .inner = ctx.inner,
        .middle = middle,
    });
}

fn declareCleanupBodies(
    b: *source.Builder,
    ctx: anytype,
) source.Error!source.Module {
    const outer = try b.declare(&.{ctx.exit_info}, ctx.unit, &.{ctx.outer_effect}, &.{});
    try b.define(
        outer,
        try b.term(.{ .perform = .{
            .effect = ctx.outer_effect,
            .payload = try b.reference(b.parameter(outer, 0)),
        } }),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = ctx.integer,
        .capture_bound = &.{ctx.boolean},
    } } });
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.exit_info},
        .result = ctx.unit,
    } } });
    const middle_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.exit_info},
        .result = ctx.unit,
        .effects = &.{ctx.middle_effect},
    } } });
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.exit_info},
        .result = ctx.unit,
        .effects = &.{ctx.outer_effect},
    } } });
    return protectCleanups(b, .{
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .middle_effect = ctx.middle_effect,
        .main = ctx.main,
        .body = ctx.body,
        .inner = ctx.inner,
        .middle = ctx.middle,
        .outer = outer,
        .body_type = body_type,
        .inner_type = inner_type,
        .middle_type = middle_type,
        .outer_type = outer_type,
    });
}

fn protectCleanups(
    b: *source.Builder,
    ctx: anytype,
) source.Error!source.Module {
    const first = try b.declare(&.{}, ctx.integer, &.{}, &.{});
    try b.define(
        first,
        try b.term(.{ .protect = .{
            .body = try b.lambda(ctx.body, ctx.body_type),
            .cleanup = try b.lambda(ctx.inner, ctx.inner_type),
        } }),
    );
    const second = try b.declare(&.{}, ctx.integer, &.{ctx.middle_effect}, &.{});
    try b.define(
        second,
        try b.term(.{ .protect = .{
            .body = try b.lambda(first, ctx.body_type),
            .cleanup = try b.lambda(ctx.middle, ctx.middle_type),
        } }),
    );
    const second_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = ctx.integer,
        .effects = &.{ctx.middle_effect},
        .capture_bound = &.{ctx.boolean},
    } } });
    try b.define(
        ctx.main,
        try b.term(.{ .protect = .{
            .body = try b.lambda(second, second_type),
            .cleanup = try b.lambda(ctx.outer, ctx.outer_type),
        } }),
    );
    return b.module(ctx.main, ctx.integer);
}
