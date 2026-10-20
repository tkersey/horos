// Copyright (c) 2026 Boundary contributors. MIT license.
//! Deep and shallow resumptions differ observably at the return clause.
const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;

pub fn build(b: *source.Builder) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const answer = try b.schema(.{ .product = &(@as([8]p.Id, @splat(integer))) });
    var calls: [8]p.Id = undefined;
    var variables: [8]p.Id = undefined;
    var results: [8]p.Id = undefined;
    var effects: [8]p.Id = undefined;
    var index: usize = 0;
    inline for (.{ p.Mode.deep, p.Mode.shallow }) |mode| {
        inline for (.{ p.Use.linear, p.Use.multi }) |use| inline for (.{
            false,
            true,
        }) |injecting| {
            const name = try b.allocator().print(
                "example/resume-{s}-{s}-{s}",
                .{ @tagName(mode), @tagName(use), if (injecting) "computation" else "value" },
            );
            effects[index] = b.effects.items.len;
            const function = try instance(b, name, mode, use, injecting);
            calls[index] = try b.term(.{ .call = .{ .function = function, .arguments = &.{} } });
            variables[index] = try b.variable(integer);
            results[index] = try b.reference(variables[index]);
            index += 1;
        };
    }
    var body = try b.pure(try b.primitive(answer, .product, &results, 0));
    while (index != 0) {
        index -= 1;
        body = try b.bind(variables[index], calls[index], body);
    }
    const entry = try b.declare(&.{}, answer, &effects, &.{});
    try b.define(entry, body);
    return b.module(entry, unit);
}

fn instance(
    b: *source.Builder,
    identity: []const u8,
    comptime mode: p.Mode,
    comptime use: p.Use,
    comptime injecting: bool,
) !p.Id {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = identity,
        .payload = unit,
        .result = unit,
        .external = true,
        .control_use = use,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.reserveSchema();
    try b.defineSchema(token, .{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = integer,
        .mode = mode,
        .use = use,
        .handled = &.{effect},
        .effects = &.{effect},
        .capture_bound = &.{ unit, cap, integer, token },
    } } });
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.constant(u64, 99)));
    const clause = try b.declare(&.{ unit, token }, integer, &.{effect}, &.{});
    const k = try b.reference(b.parameter(clause, 1));
    return defineResumeClause(b, mode, use, injecting, .{
        .unit = unit,
        .integer = integer,
        .effect = effect,
        .cap = cap,
        .token = token,
        .returns = returns,
        .clause = clause,
        .k = k,
    });
}

fn defineResumeClause(
    b: *source.Builder,
    comptime mode: p.Mode,
    comptime use: p.Use,
    comptime injecting: bool,
    ctx: anytype,
) source.Error!p.Id {
    const resume_term = if (injecting) blk: {
        const thunk = try b.declare(&.{}, ctx.unit, &.{}, &.{});
        try b.define(thunk, try b.pure(try b.constant(void, {})));
        const thunk_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = ctx.unit,
        } } });
        break :blk try b.term(.{ .resume_computation = .{
            .resumption = ctx.k,
            .computation = try b.lambda(thunk, thunk_type),
        } });
    } else try b.term(.{ .resume_value = .{
        .resumption = ctx.k,
        .argument = try b.constant(void, {}),
    } });
    const body_term = if (use == .multi)
        try b.bind(try b.variable(ctx.integer), resume_term, resume_term)
    else
        resume_term;
    try b.define(ctx.clause, body_term);
    const handler = try b.handler(.{
        .mode = mode,
        .input = ctx.integer,
        .answer = ctx.integer,
        .effects = &.{ctx.effect},
        .return_function = ctx.returns,
        .clauses = &.{.{ .effect = ctx.effect, .function = ctx.clause, .resumption = ctx.token }},
    });
    return defineHandledBody(b, .{
        .unit = ctx.unit,
        .integer = ctx.integer,
        .effect = ctx.effect,
        .cap = ctx.cap,
        .handler = handler,
    });
}

fn defineHandledBody(
    b: *source.Builder,
    ctx: anytype,
) source.Error!p.Id {
    const body = try b.declare(&.{ctx.cap}, ctx.integer, &.{ctx.effect}, &.{});
    const call = try b.term(.{ .perform = .{
        .effect = ctx.effect,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(
        body,
        try b.bind(try b.variable(ctx.unit), call, try b.pure(try b.constant(u64, 42))),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.cap},
        .result = ctx.integer,
        .effects = &.{ctx.effect},
    } } });
    const entry = try b.declare(&.{}, ctx.integer, &.{ctx.effect}, &.{});
    try b.define(
        entry,
        try b.term(.{ .handle = .{
            .handler = ctx.handler,
            .body = try b.lambda(body, body_type),
        } }),
    );
    return entry;
}
