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
    const middle = try b.declare(&.{exit_info}, unit, &.{middle_effect}, &.{});
    const middle_info = try b.reference(b.parameter(middle, 0));
    const suspended = if (yielding_cleanup) blk: {
        // The call after the yield is internal; run must continue to the request.
        const request = try b.declare(&.{exit_info}, unit, &.{middle_effect}, &.{});
        try b.define(
            request,
            try b.term(.{ .perform = .{
                .effect = middle_effect,
                .payload = try b.reference(b.parameter(request, 0)),
            } }),
        );
        break :blk try b.term(.{ .call = .{ .function = request, .arguments = &.{middle_info} } });
    } else try b.term(.{ .perform = .{ .effect = middle_effect, .payload = middle_info } });
    const failure = try b.term(.{ .fail = try b.constant(u64, 8) });
    const after_request = if (yielding_cleanup) blk: {
        const resume_cleanup = try b.declare(&.{}, unit, &.{}, &.{});
        try b.define(resume_cleanup, try b.pure(try b.constant(void, {})));
        const resumed = try b.term(.{ .call = .{ .function = resume_cleanup, .arguments = &.{} } });
        break :blk try b.term(.{ .yield_then = try b.bind(
            try b.variable(unit),
            resumed,
            failure,
        ) });
    } else failure;
    const middle_body = try b.bind(try b.variable(unit), suspended, after_request);
    try b.define(
        middle,
        if (yielding_cleanup) try b.term(.{ .yield_then = middle_body }) else middle_body,
    );
    const outer = try b.declare(&.{exit_info}, unit, &.{outer_effect}, &.{});
    try b.define(
        outer,
        try b.term(.{ .perform = .{
            .effect = outer_effect,
            .payload = try b.reference(b.parameter(outer, 0)),
        } }),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .capture_bound = &.{boolean},
    } } });
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{exit_info},
        .result = unit,
    } } });
    const middle_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{exit_info},
        .result = unit,
        .effects = &.{middle_effect},
    } } });
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{exit_info},
        .result = unit,
        .effects = &.{outer_effect},
    } } });
    const first = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(
        first,
        try b.term(.{ .protect = .{
            .body = try b.lambda(body, body_type),
            .cleanup = try b.lambda(inner, inner_type),
        } }),
    );
    const second = try b.declare(&.{}, integer, &.{middle_effect}, &.{});
    try b.define(
        second,
        try b.term(.{ .protect = .{
            .body = try b.lambda(first, body_type),
            .cleanup = try b.lambda(middle, middle_type),
        } }),
    );
    const second_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .effects = &.{middle_effect},
        .capture_bound = &.{boolean},
    } } });
    try b.define(
        main,
        try b.term(.{ .protect = .{
            .body = try b.lambda(second, second_type),
            .cleanup = try b.lambda(outer, outer_type),
        } }),
    );
    return b.module(main, integer);
}
