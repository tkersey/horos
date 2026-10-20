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
    const outer_token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = outer_effect,
        .input = integer,
        .answer = result,
        .handled = &.{outer_effect},
        .capture_bound = &.{ unit, integer, cell, outer_cap, inner_cap, state },
        .owned_regions = &.{r},
        .mode = .deep,
        .use = .linear,
    } } });
    const inner_token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = inner_effect,
        .input = unit,
        .answer = unit,
        .handled = &.{inner_effect},
        .effects = &.{inner_effect},
        .capture_bound = &.{ unit, inner_cap },
        .mode = .shallow,
        .use = .linear,
    } } });
    const outer_returns = try b.declare(&.{result}, result, &.{}, &.{});
    try b.define(outer_returns, try b.pure(try b.reference(b.parameter(outer_returns, 0))));
    const outer_clause = try b.declare(&.{ unit, outer_token }, result, &.{}, &.{});
    try b.define(
        outer_clause,
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(outer_clause, 1)),
            .argument = try b.constant(u64, 42),
        } }),
    );
    const outer_handler = try b.handler(.{
        .mode = .deep,
        .input = result,
        .answer = result,
        .return_function = outer_returns,
        .clauses = &.{.{
            .effect = outer_effect,
            .function = outer_clause,
            .resumption = outer_token,
        }},
    });
    const inner_returns = try b.declare(&.{ state, unit }, result, &.{outer_effect}, &.{r});
    const carried = try b.reference(b.parameter(inner_returns, 0));
    const answer = try b.variable(integer);
    const asked = if (carries_capability) try b.term(.{ .perform = .{
        .effect = outer_effect,
        .capability = try b.primitive(outer_cap, .field, &.{carried}, 0),
        .payload = try b.constant(void, {}),
    } }) else try b.pure(try b.constant(u64, 42));
    const read = if (carries_cell) try b.primitive(
        integer,
        .cell_get,
        &.{try b.primitive(cell, .field, &.{carried}, 1)},
        0,
    ) else try b.constant(u64, 37);
    try b.define(
        inner_returns,
        try b.bind(
            answer,
            asked,
            try b.pure(try b.primitive(
                result,
                .product,
                &.{ try b.reference(answer), read },
                0,
            )),
        ),
    );
    const inner_clause = try b.declare(
        &.{ state, unit, inner_token },
        result,
        &.{outer_effect},
        &.{r},
    );
    const inner_handler = try b.handler(.{
        .mode = .shallow,
        .input = unit,
        .answer = result,
        .effects = &.{outer_effect},
        .return_function = inner_returns,
        .state = &.{state},
        .clauses = &.{.{
            .effect = inner_effect,
            .function = inner_clause,
            .resumption = inner_token,
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
    const inner = try b.declare(&.{inner_cap}, unit, &.{inner_effect}, &.{});
    const performed = try b.term(.{ .perform = .{
        .effect = inner_effect,
        .capability = try b.reference(b.parameter(inner, 0)),
        .payload = try b.constant(void, {}),
    } });
    const paused = try b.term(.{ .yield_then = performed });
    try b.define(inner, try b.bind(try b.variable(unit), performed, paused));
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{inner_cap},
        .result = unit,
        .effects = &.{inner_effect},
    } } });
    const outer = try b.declare(&.{outer_cap}, result, &.{outer_effect}, &.{});
    const scope = try b.declare(&.{region}, result, &.{outer_effect}, &.{r});
    const allocated = try b.primitive(
        cell,
        .cell_new,
        &.{ try b.reference(b.parameter(scope, 0)), try b.constant(u64, 37) },
        0,
    );
    const state_value = try b.primitive(
        state,
        .product,
        &.{
            if (carries_capability) try b.reference(b.parameter(outer, 0)) else try b.constant(void, {}),
            if (carries_cell) allocated else try b.constant(void, {}),
        },
        0,
    );
    try b.define(
        scope,
        try b.term(.{ .handle = .{
            .handler = inner_handler,
            .body = try b.lambda(inner, inner_type),
            .state = &.{state_value},
        } }),
    );
    const scope_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = result,
        .effects = &.{outer_effect},
        .capture_bound = &.{outer_cap},
        .regions = &.{r},
    } } });
    try b.define(
        outer,
        try b.term(.{ .with_region = .{ .region = r, .body = try b.lambda(scope, scope_type) } }),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{outer_cap},
        .result = result,
        .effects = &.{outer_effect},
    } } });
    const entry = try b.declare(&.{}, result, &.{}, &.{});
    try b.define(
        entry,
        try b.term(.{ .handle = .{
            .handler = outer_handler,
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    return b.module(entry, unit);
}
