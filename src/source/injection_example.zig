// Copyright (c) 2026 Boundary contributors. MIT license.
//! The same raised value reaches the clause's outer handler or the suspended
//! operation's inner handler, selected by resumeWithComputation.
const source = @import("../source.zig");
const p = @import("horos_data").program;

pub fn build(b: *source.Builder) source.Error!source.Module {
    return buildMode(b, .deep);
}

pub fn shallow(b: *source.Builder) source.Error!source.Module {
    return buildMode(b, .shallow);
}

fn buildMode(b: *source.Builder, mode: p.Mode) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const raised = try b.effect(.{
        .identity = "example/lexical-failure",
        .payload = integer,
        .result = unit,
        .external = false,
    });
    const asking = try b.effect(.{
        .identity = "example/injected-ask",
        .payload = unit,
        .result = integer,
        .use_site_effects = &.{raised},
        .external = mode == .shallow,
    });
    const outer_row: []const p.Id = if (mode == .shallow) &.{asking} else &.{};
    const ask_row: []const p.Id = if (mode == .shallow) &.{ raised, asking } else &.{raised};
    const failure_cap = try b.schema(.{ .internal = .{ .capability = raised } });
    const ask_cap = try b.schema(.{ .internal = .{ .capability = asking } });
    const outer_k = try b.reserveSchema();
    const inner_k = try b.reserveSchema();
    const ask_k = try b.reserveSchema();
    const captures = &.{ integer, boolean, failure_cap, ask_cap, outer_k, inner_k, ask_k };
    try defineInjectionTokens(
        b,
        outer_k,
        inner_k,
        ask_k,
        raised,
        asking,
        unit,
        integer,
        outer_row,
        ask_row,
        captures,
        mode,
    );
    return defineInjectionProgram(
        b,
        integer,
        unit,
        outer_k,
        inner_k,
        outer_row,
        asking,
        raised,
        failure_cap,
        boolean,
        ask_k,
        ask_row,
        mode,
        ask_cap,
    );
}

fn defineInjectionTokens(
    b: *source.Builder,
    outer_k: p.Id,
    inner_k: p.Id,
    ask_k: p.Id,
    raised: p.Id,
    asking: p.Id,
    unit: p.Id,
    integer: p.Id,
    outer_row: []const p.Id,
    ask_row: []const p.Id,
    captures: []const p.Id,
    mode: p.Mode,
) source.Error!void {
    try b.defineSchema(
        outer_k,
        .{ .internal = .{ .resumption = .{
            .effect = raised,
            .input = unit,
            .answer = integer,
            .effects = outer_row,
            .capture_bound = captures,
            .handled = &.{raised},
            .mode = .deep,
            .use = .linear,
        } } },
    );
    try b.defineSchema(
        inner_k,
        .{ .internal = .{ .resumption = .{
            .effect = raised,
            .input = unit,
            .answer = integer,
            .effects = &.{asking},
            .capture_bound = captures,
            .handled = &.{raised},
            .mode = .deep,
            .use = .linear,
        } } },
    );
    try b.defineSchema(
        ask_k,
        .{ .internal = .{ .resumption = .{
            .effect = asking,
            .input = integer,
            .answer = integer,
            .effects = ask_row,
            .escaping = if (mode == .shallow) &.{raised} else &.{},
            .capture_bound = captures,
            .handled = &.{asking},
            .mode = mode,
            .use = .linear,
        } } },
    );
}

fn defineCatchers(
    b: *source.Builder,
    integer: p.Id,
    unit: p.Id,
    outer_k: p.Id,
    inner_k: p.Id,
    outer_row: []const p.Id,
    asking: p.Id,
    raised: p.Id,
) source.Error![2]p.Id {
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    var catchers: [2]p.Id = undefined;
    for ([_]p.Id{ outer_k, inner_k }, 0..) |token, index| {
        const row: []const p.Id = if (index == 0) outer_row else &.{asking};
        const clause = try b.declare(&.{ integer, token }, integer, row, &.{});
        const disposed = try b.term(.{ .dispose = try b.reference(b.parameter(clause, 1)) });
        try b.define(
            clause,
            try b.bind(
                try b.variable(unit),
                disposed,
                try b.pure(try b.constant(u64, if (index == 0) 109 else 209)),
            ),
        );
        catchers[index] = try b.handler(.{
            .mode = .deep,
            .input = integer,
            .answer = integer,
            .return_function = returns,
            .effects = row,
            .clauses = &.{.{ .effect = raised, .function = clause, .resumption = token }},
        });
    }
    return catchers;
}

fn defineInjectionHandler(
    b: *source.Builder,
    failure_cap: p.Id,
    integer: p.Id,
    raised: p.Id,
    boolean: p.Id,
    ask_k: p.Id,
    ask_row: []const p.Id,
    unit: p.Id,
    mode: p.Mode,
    asking: p.Id,
) source.Error!p.Id {
    const thrower = try b.declare(&.{failure_cap}, integer, &.{raised}, &.{});
    const use_site_raise = try b.term(.{ .perform = .{
        .effect = raised,
        .capability = try b.reference(b.parameter(thrower, 0)),
        .payload = try b.constant(u64, 9),
    } });
    try b.define(
        thrower,
        try b.bind(try b.variable(unit), use_site_raise, try b.pure(try b.constant(u64, 0))),
    );
    const throw_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{failure_cap},
        .result = integer,
        .effects = &.{raised},
    } } });
    const ask_returns = try b.declare(&.{ boolean, failure_cap, integer }, integer, &.{}, &.{});
    try b.define(ask_returns, try b.pure(try b.reference(b.parameter(ask_returns, 2))));
    const clause = try b.declare(&.{ boolean, failure_cap, unit, ask_k }, integer, ask_row, &.{});
    const token = try b.reference(b.parameter(clause, 3));
    const injected = try b.term(.{ .resume_computation = .{
        .resumption = token,
        .computation = try b.lambda(thrower, throw_type),
    } });
    const clause_site_raise = try b.term(.{ .perform = .{
        .effect = raised,
        .capability = try b.reference(b.parameter(clause, 1)),
        .payload = try b.constant(u64, 9),
    } });
    const unreachable_resume = try b.term(.{ .resume_value = .{
        .resumption = token,
        .argument = try b.constant(u64, 0),
    } });
    try b.define(
        clause,
        try b.term(.{ .conditional = .{
            .condition = try b.reference(b.parameter(clause, 0)),
            .when_true = injected,
            .when_false = try b.bind(
                try b.variable(unit),
                clause_site_raise,
                unreachable_resume,
            ),
        } }),
    );
    const interpret = try b.handler(.{
        .mode = mode,
        .input = integer,
        .answer = integer,
        .return_function = ask_returns,
        .state = &.{ boolean, failure_cap },
        .effects = ask_row,
        .clauses = &.{.{ .effect = asking, .function = clause, .resumption = ask_k }},
    });
    return interpret;
}

fn defineInjectionBodies(
    b: *source.Builder,
    boolean: p.Id,
    integer: p.Id,
    outer_row: []const p.Id,
    failure_cap: p.Id,
    ask_row: []const p.Id,
    ask_cap: p.Id,
    asking: p.Id,
    raised: p.Id,
    catchers: [2]p.Id,
    interpret: p.Id,
    unit: p.Id,
) source.Error!source.Module {
    const main = try b.declare(&.{boolean}, integer, outer_row, &.{});
    const outside = try b.declare(&.{failure_cap}, integer, ask_row, &.{});
    const handled = try b.declare(&.{ask_cap}, integer, &.{asking}, &.{});
    const inside = try b.declare(&.{failure_cap}, integer, &.{ raised, asking }, &.{});
    try defineInjectionInside(
        b,
        inside,
        asking,
        handled,
        failure_cap,
        integer,
        raised,
        ask_cap,
        catchers,
    );
    const handled_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ask_cap},
        .result = integer,
        .effects = &.{asking},
    } } });
    try b.define(
        outside,
        try b.term(.{ .handle = .{
            .handler = interpret,
            .body = try b.lambda(handled, handled_type),
            .state = &.{
                try b.reference(b.parameter(main, 0)),
                try b.reference(b.parameter(outside, 0)),
            },
        } }),
    );
    const outside_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{failure_cap},
        .result = integer,
        .effects = ask_row,
        .capture_bound = &.{boolean},
    } } });
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = catchers[0],
            .body = try b.lambda(outside, outside_type),
        } }),
    );
    return b.module(main, unit);
}

fn defineInjectionInside(
    b: *source.Builder,
    inside: p.Id,
    asking: p.Id,
    handled: p.Id,
    failure_cap: p.Id,
    integer: p.Id,
    raised: p.Id,
    ask_cap: p.Id,
    catchers: [2]p.Id,
) source.Error!void {
    try b.define(
        inside,
        try b.term(.{ .perform = .{
            .effect = asking,
            .capability = try b.reference(b.parameter(handled, 0)),
            .payload = try b.constant(void, {}),
            .use_site_capabilities = &.{try b.reference(b.parameter(inside, 0))},
        } }),
    );
    const inside_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{failure_cap},
        .result = integer,
        .effects = &.{ raised, asking },
        .capture_bound = &.{ask_cap},
    } } });
    try b.define(
        handled,
        try b.term(.{ .handle = .{
            .handler = catchers[1],
            .body = try b.lambda(inside, inside_type),
        } }),
    );
}

fn defineInjectionProgram(
    b: *source.Builder,
    integer: p.Id,
    unit: p.Id,
    outer_k: p.Id,
    inner_k: p.Id,
    outer_row: []const p.Id,
    asking: p.Id,
    raised: p.Id,
    failure_cap: p.Id,
    boolean: p.Id,
    ask_k: p.Id,
    ask_row: []const p.Id,
    mode: p.Mode,
    ask_cap: p.Id,
) source.Error!source.Module {
    const catchers = try defineCatchers(
        b,
        integer,
        unit,
        outer_k,
        inner_k,
        outer_row,
        asking,
        raised,
    );
    const interpret = try defineInjectionHandler(
        b,
        failure_cap,
        integer,
        raised,
        boolean,
        ask_k,
        ask_row,
        unit,
        mode,
        asking,
    );
    return defineInjectionBodies(
        b,
        boolean,
        integer,
        outer_row,
        failure_cap,
        ask_row,
        ask_cap,
        asking,
        raised,
        catchers,
        interpret,
        unit,
    );
}
