// Copyright (c) 2026 Boundary contributors. MIT license.
//! A shallow successor carries an outer capability and a live region cell.
const source = @import("../source.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    return variant(b, true, true);
}

pub fn variant(
    b: *source.Builder,
    comptime carries_capability: bool,
    comptime carries_cell: bool,
) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const result = try b.schema(.{ .product = &.{ integer, integer } });
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = integer, .region = r } } });
    const outer_effect = try b.effect(.{
        .identity = "example/successor-outer",
        .payload = unit,
        .result = integer,
        .external = false,
    });
    const inner_effect = try b.effect(.{
        .identity = "example/successor-inner",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const outer_cap = try b.schema(.{ .internal = .{ .capability = outer_effect } });
    const inner_cap = try b.schema(.{ .internal = .{ .capability = inner_effect } });
    const state = try b.schema(.{ .product = &.{
        if (carries_capability) outer_cap else unit,
        if (carries_cell) cell else unit,
    } });
    return declareResumptions(b, carries_capability, carries_cell, .{
        .unit = unit,
        .integer = integer,
        .result = result,
        .r = r,
        .region = region,
        .cell = cell,
        .outer_effect = outer_effect,
        .inner_effect = inner_effect,
        .outer_cap = outer_cap,
        .inner_cap = inner_cap,
        .state = state,
    });
}

fn declareResumptions(
    b: *source.Builder,
    comptime carries_capability: bool,
    comptime carries_cell: bool,
    ctx: anytype,
) source.Error!source.Module {
    const outer_token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = ctx.outer_effect,
        .input = ctx.integer,
        .answer = ctx.result,
        .handled = &.{ctx.outer_effect},
        .capture_bound = &.{
            ctx.unit,
            ctx.integer,
            ctx.cell,
            ctx.outer_cap,
            ctx.inner_cap,
            ctx.state,
        },
        .owned_regions = &.{ctx.r},
        .mode = .deep,
        .use = .linear,
    } } });
    const inner_token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = ctx.inner_effect,
        .input = ctx.unit,
        .answer = ctx.unit,
        .handled = &.{ctx.inner_effect},
        .effects = &.{ctx.inner_effect},
        .capture_bound = &.{ ctx.unit, ctx.inner_cap },
        .mode = .shallow,
        .use = .linear,
    } } });
    const outer_returns = try b.declare(&.{ctx.result}, ctx.result, &.{}, &.{});
    try b.define(outer_returns, try b.pure(try b.reference(b.parameter(outer_returns, 0))));
    const outer_clause = try b.declare(&.{ ctx.unit, outer_token }, ctx.result, &.{}, &.{});
    try b.define(
        outer_clause,
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(outer_clause, 1)),
            .argument = try b.constant(u64, 42),
        } }),
    );
    const outer_handler = try b.handler(.{
        .mode = .deep,
        .input = ctx.result,
        .answer = ctx.result,
        .return_function = outer_returns,
        .clauses = &.{.{
            .effect = ctx.outer_effect,
            .function = outer_clause,
            .resumption = outer_token,
        }},
    });
    return defineSuccessorReturn(b, carries_capability, carries_cell, .{
        .unit = ctx.unit,
        .integer = ctx.integer,
        .result = ctx.result,
        .r = ctx.r,
        .region = ctx.region,
        .cell = ctx.cell,
        .outer_effect = ctx.outer_effect,
        .inner_effect = ctx.inner_effect,
        .outer_cap = ctx.outer_cap,
        .inner_cap = ctx.inner_cap,
        .state = ctx.state,
        .inner_token = inner_token,
        .outer_handler = outer_handler,
    });
}

fn defineSuccessorReturn(
    b: *source.Builder,
    comptime carries_capability: bool,
    comptime carries_cell: bool,
    ctx: anytype,
) source.Error!source.Module {
    const inner_returns = try b.declare(
        &.{ ctx.state, ctx.unit },
        ctx.result,
        &.{ctx.outer_effect},
        &.{ctx.r},
    );
    const carried = try b.reference(b.parameter(inner_returns, 0));
    const answer = try b.variable(ctx.integer);
    const asked = if (carries_capability) try b.term(.{ .perform = .{
        .effect = ctx.outer_effect,
        .capability = try b.primitive(ctx.outer_cap, .field, &.{carried}, 0),
        .payload = try b.constant(void, {}),
    } }) else try b.pure(try b.constant(u64, 42));
    const read = if (carries_cell) try b.primitive(
        ctx.integer,
        .cell_get,
        &.{try b.primitive(ctx.cell, .field, &.{carried}, 1)},
        0,
    ) else try b.constant(u64, 37);
    try b.define(
        inner_returns,
        try b.bind(
            answer,
            asked,
            try b.pure(try b.primitive(
                ctx.result,
                .product,
                &.{ try b.reference(answer), read },
                0,
            )),
        ),
    );
    return defineSuccessorHandler(b, carries_capability, carries_cell, .{
        .unit = ctx.unit,
        .result = ctx.result,
        .r = ctx.r,
        .region = ctx.region,
        .cell = ctx.cell,
        .outer_effect = ctx.outer_effect,
        .inner_effect = ctx.inner_effect,
        .outer_cap = ctx.outer_cap,
        .inner_cap = ctx.inner_cap,
        .state = ctx.state,
        .inner_token = ctx.inner_token,
        .outer_handler = ctx.outer_handler,
        .inner_returns = inner_returns,
    });
}

fn defineSuccessorHandler(
    b: *source.Builder,
    comptime carries_capability: bool,
    comptime carries_cell: bool,
    ctx: anytype,
) source.Error!source.Module {
    const inner_clause = try b.declare(
        &.{ ctx.state, ctx.unit, ctx.inner_token },
        ctx.result,
        &.{ctx.outer_effect},
        &.{ctx.r},
    );
    const inner_handler = try b.handler(.{
        .mode = .shallow,
        .input = ctx.unit,
        .answer = ctx.result,
        .effects = &.{ctx.outer_effect},
        .return_function = ctx.inner_returns,
        .state = &.{ctx.state},
        .clauses = &.{.{
            .effect = ctx.inner_effect,
            .function = inner_clause,
            .resumption = ctx.inner_token,
        }},
    });
    try b.define(
        inner_clause,
        try b.term(.{ .resume_with = .{
            .resumption = try b.reference(b.parameter(inner_clause, 2)),
            .argument = try b.constant(void, {}),
            .handler = inner_handler,
            .state = &.{try b.reference(b.parameter(inner_clause, 0))},
        } }),
    );
    const inner = try b.declare(&.{ctx.inner_cap}, ctx.unit, &.{ctx.inner_effect}, &.{});
    const performed = try b.term(.{ .perform = .{
        .effect = ctx.inner_effect,
        .capability = try b.reference(b.parameter(inner, 0)),
        .payload = try b.constant(void, {}),
    } });
    const paused = try b.term(.{ .yield_then = performed });
    try b.define(inner, try b.bind(try b.variable(ctx.unit), performed, paused));
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.inner_cap},
        .result = ctx.unit,
        .effects = &.{ctx.inner_effect},
    } } });
    return initializeSuccessorState(b, carries_capability, carries_cell, .{
        .unit = ctx.unit,
        .result = ctx.result,
        .r = ctx.r,
        .region = ctx.region,
        .cell = ctx.cell,
        .outer_effect = ctx.outer_effect,
        .outer_cap = ctx.outer_cap,
        .state = ctx.state,
        .outer_handler = ctx.outer_handler,
        .inner_handler = inner_handler,
        .inner = inner,
        .inner_type = inner_type,
    });
}

fn initializeSuccessorState(
    b: *source.Builder,
    comptime carries_capability: bool,
    comptime carries_cell: bool,
    ctx: anytype,
) source.Error!source.Module {
    const outer = try b.declare(&.{ctx.outer_cap}, ctx.result, &.{ctx.outer_effect}, &.{});
    const scope = try b.declare(&.{ctx.region}, ctx.result, &.{ctx.outer_effect}, &.{ctx.r});
    const allocated = try b.primitive(
        ctx.cell,
        .cell_new,
        &.{ try b.reference(b.parameter(scope, 0)), try b.constant(u64, 37) },
        0,
    );
    const state_value = try b.primitive(
        ctx.state,
        .product,
        &.{
            if (carries_capability)
                try b.reference(b.parameter(outer, 0))
            else
                try b.constant(void, {}),
            if (carries_cell) allocated else try b.constant(void, {}),
        },
        0,
    );
    try b.define(
        scope,
        try b.term(.{ .handle = .{
            .handler = ctx.inner_handler,
            .body = try b.lambda(ctx.inner, ctx.inner_type),
            .state = &.{state_value},
        } }),
    );
    return interpretSuccessor(b, .{
        .unit = ctx.unit,
        .result = ctx.result,
        .r = ctx.r,
        .region = ctx.region,
        .outer_effect = ctx.outer_effect,
        .outer_cap = ctx.outer_cap,
        .outer_handler = ctx.outer_handler,
        .outer = outer,
        .scope = scope,
    });
}

fn interpretSuccessor(
    b: *source.Builder,
    ctx: anytype,
) source.Error!source.Module {
    const scope_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.region},
        .result = ctx.result,
        .effects = &.{ctx.outer_effect},
        .capture_bound = &.{ctx.outer_cap},
        .regions = &.{ctx.r},
    } } });
    try b.define(
        ctx.outer,
        try b.term(.{ .with_region = .{
            .region = ctx.r,
            .body = try b.lambda(ctx.scope, scope_type),
        } }),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.outer_cap},
        .result = ctx.result,
        .effects = &.{ctx.outer_effect},
    } } });
    const entry = try b.declare(&.{}, ctx.result, &.{}, &.{});
    try b.define(
        entry,
        try b.term(.{ .handle = .{
            .handler = ctx.outer_handler,
            .body = try b.lambda(ctx.outer, outer_type),
        } }),
    );
    return b.module(entry, ctx.unit);
}
