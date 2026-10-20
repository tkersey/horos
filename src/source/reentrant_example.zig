// Copyright (c) 2026 Boundary contributors. MIT license.
//! One template is stored in a cell that it captures, then reentered while its
//! first activation is still live. The outer counter breaks the recursion.
const source = @import("../source.zig");
const p = @import("horos_data").program;

fn add(b: *source.Builder, value: p.Id, amount: u64) source.Error!p.Id {
    return b.value(.{
        .schema = try b.scalar(u64),
        .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{ value, try b.constant(u64, amount) },
            .failures = &.{.{
                .kind = .arithmetic_overflow,
                .value = try b.failureLiteral(try b.constant(void, {})),
            }},
        } },
    });
}

pub fn build(b: *source.Builder) source.Error!source.Module {
    return example(b, false, null);
}
pub fn cloned(b: *source.Builder) source.Error!source.Module {
    return example(b, true, null);
}
/// Substitute a checked, closed pure u64 computation at the nested return.
pub fn withResult(
    b: *source.Builder,
    result: p.Id,
    comptime convert: bool,
) source.Error!source.Module {
    return example(b, convert, result);
}
fn example(b: *source.Builder, comptime convert: bool, result: ?p.Id) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const region = b.region();
    const region_type = try b.schema(.{ .internal = .{ .region = region } });
    const operation = try b.effect(.{
        .identity = "example/reentrant",
        .payload = unit,
        .result = unit,
        .control_use = .multi,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = operation } });
    const token = try b.reserveSchema();
    const maybe = try b.schema(.{ .sum = &.{ unit, token } });
    const template_cell = try b.schema(.{ .internal = .{ .cell = .{
        .element = maybe,
        .region = region,
    } } });
    const counter_cell = try b.schema(.{ .internal = .{ .cell = .{
        .element = integer,
        .region = region,
    } } });
    try b.defineSchema(
        token,
        .{ .internal = .{ .resumption = .{
            .effect = operation,
            .input = unit,
            .answer = integer,
            .capture_bound = &.{ template_cell, counter_cell },
            .handled = &.{operation},
            .mode = .deep,
            .use = .multi,
        } } },
    );
    return declareHandlers(b, convert, result, .{
        .unit = unit,
        .integer = integer,
        .boolean = boolean,
        .region = region,
        .region_type = region_type,
        .operation = operation,
        .cap = cap,
        .token = token,
        .maybe = maybe,
        .template_cell = template_cell,
        .counter_cell = counter_cell,
    });
}

fn declareHandlers(
    b: *source.Builder,
    comptime convert: bool,
    result: ?p.Id,
    ctx: anytype,
) source.Error!source.Module {
    const main = try b.declare(&.{}, ctx.integer, &.{}, &.{});
    const wrapper = try b.declare(&.{ctx.region_type}, ctx.integer, &.{}, &.{ctx.region});
    const template = try b.variable(ctx.template_cell);
    const counter = try b.variable(ctx.counter_cell);
    const body = try b.declare(&.{ctx.cap}, ctx.integer, &.{ctx.operation}, &.{ctx.region});
    const returns = try b.declare(
        &.{ ctx.template_cell, ctx.counter_cell, ctx.integer },
        ctx.integer,
        &.{},
        &.{ctx.region},
    );
    try b.define(returns, try b.pure(try add(b, try b.reference(b.parameter(returns, 2)), 1)));
    const owned_token = if (convert) try b.schema(.{ .internal = .{ .resumption = .{
        .effect = ctx.operation,
        .input = ctx.unit,
        .answer = ctx.integer,
        .capture_bound = &.{ ctx.template_cell, ctx.counter_cell },
        .handled = &.{ctx.operation},
        .mode = .deep,
        .use = .linear,
    } } }) else ctx.token;
    const clause = try b.declare(
        &.{ ctx.template_cell, ctx.counter_cell, ctx.unit, owned_token },
        ctx.integer,
        &.{},
        &.{ctx.region},
    );
    const converted = if (convert) try b.variable(ctx.token) else b.parameter(clause, 3);
    return defineCaptureClause(b, convert, result, .{
        .unit = ctx.unit,
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .region = ctx.region,
        .region_type = ctx.region_type,
        .operation = ctx.operation,
        .cap = ctx.cap,
        .token = ctx.token,
        .maybe = ctx.maybe,
        .template_cell = ctx.template_cell,
        .counter_cell = ctx.counter_cell,
        .main = main,
        .wrapper = wrapper,
        .template = template,
        .counter = counter,
        .body = body,
        .returns = returns,
        .owned_token = owned_token,
        .clause = clause,
        .converted = converted,
    });
}

fn defineCaptureClause(
    b: *source.Builder,
    comptime convert: bool,
    result: ?p.Id,
    ctx: anytype,
) source.Error!source.Module {
    const k = try b.reference(ctx.converted);
    const save = try b.pure(try b.primitive(
        ctx.unit,
        .cell_set,
        &.{
            try b.reference(b.parameter(ctx.clause, 0)),
            try b.primitive(ctx.maybe, .variant, &.{k}, 1),
        },
        0,
    ));
    const first = try b.variable(ctx.integer);
    const resumed = try b.term(.{ .resume_value = .{
        .resumption = k,
        .argument = try b.constant(void, {}),
    } });
    const clause_body = try b.bind(
        try b.variable(ctx.unit),
        save,
        try b.bind(first, resumed, try b.pure(try add(b, try b.reference(first), 1))),
    );
    try b.define(
        ctx.clause,
        if (convert) try b.bind(
            ctx.converted,
            try b.pure(try b.cloneResumption(
                try b.reference(b.parameter(ctx.clause, 3)),
                ctx.token,
            )),
            clause_body,
        ) else clause_body,
    );
    const handler = try b.handler(.{
        .mode = .deep,
        .input = ctx.integer,
        .answer = ctx.integer,
        .return_function = ctx.returns,
        .state = &.{ ctx.template_cell, ctx.counter_cell },
        .clauses = &.{.{
            .effect = ctx.operation,
            .function = ctx.clause,
            .resumption = ctx.owned_token,
        }},
    });
    return defineReentry(b, result, .{
        .unit = ctx.unit,
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .region = ctx.region,
        .region_type = ctx.region_type,
        .operation = ctx.operation,
        .cap = ctx.cap,
        .token = ctx.token,
        .maybe = ctx.maybe,
        .template_cell = ctx.template_cell,
        .counter_cell = ctx.counter_cell,
        .main = ctx.main,
        .wrapper = ctx.wrapper,
        .template = ctx.template,
        .counter = ctx.counter,
        .body = ctx.body,
        .handler = handler,
    });
}

fn defineReentry(
    b: *source.Builder,
    result: ?p.Id,
    ctx: anytype,
) source.Error!source.Module {
    const observed = try b.primitive(ctx.integer, .cell_get, &.{try b.reference(ctx.counter)}, 0);
    const condition = try b.primitive(
        ctx.boolean,
        .equal,
        &.{ observed, try b.constant(u64, 0) },
        0,
    );
    const mark = try b.pure(try b.primitive(
        ctx.unit,
        .cell_set,
        &.{ try b.reference(ctx.counter), try b.constant(u64, 1) },
        0,
    ));
    const stored = try b.primitive(ctx.maybe, .cell_get, &.{try b.reference(ctx.template)}, 0);
    const present = try b.variable(ctx.token);
    const second = try b.variable(ctx.integer);
    const reentered = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(present),
        .argument = try b.constant(void, {}),
    } });
    const matched = try b.term(.{ .match_sum = .{ .value = stored, .cases = &.{
        .{
            .variable = try b.variable(ctx.unit),
            .body = try b.term(.{ .fail = try b.constant(void, {}) }),
        },
        .{
            .variable = present,
            .body = try b.bind(
                second,
                reentered,
                try b.pure(try add(b, try b.reference(second), 100)),
            ),
        },
    } } });
    const recursive = try b.term(.{ .yield_then = try b.bind(
        try b.variable(ctx.unit),
        mark,
        matched,
    ) });
    return defineCapturedBody(b, result, .{
        .unit = ctx.unit,
        .integer = ctx.integer,
        .region = ctx.region,
        .region_type = ctx.region_type,
        .operation = ctx.operation,
        .cap = ctx.cap,
        .maybe = ctx.maybe,
        .template_cell = ctx.template_cell,
        .counter_cell = ctx.counter_cell,
        .main = ctx.main,
        .wrapper = ctx.wrapper,
        .template = ctx.template,
        .counter = ctx.counter,
        .body = ctx.body,
        .handler = ctx.handler,
        .condition = condition,
        .recursive = recursive,
    });
}

fn defineCapturedBody(
    b: *source.Builder,
    result: ?p.Id,
    ctx: anytype,
) source.Error!source.Module {
    const choose = try b.term(.{ .conditional = .{
        .condition = ctx.condition,
        .when_true = ctx.recursive,
        .when_false = if (result) |function| try b.term(.{ .call = .{
            .function = function,
            .arguments = &.{},
        } }) else try b.pure(try b.constant(u64, 10)),
    } });
    const capture = try b.term(.{ .perform = .{
        .effect = ctx.operation,
        .capability = try b.reference(b.parameter(ctx.body, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(ctx.body, try b.bind(try b.variable(ctx.unit), capture, choose));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.cap},
        .result = ctx.integer,
        .effects = &.{ctx.operation},
        .capture_bound = &.{ ctx.template_cell, ctx.counter_cell },
        .regions = &.{ctx.region},
    } } });
    return initializeRegion(b, .{
        .unit = ctx.unit,
        .integer = ctx.integer,
        .region = ctx.region,
        .region_type = ctx.region_type,
        .maybe = ctx.maybe,
        .template_cell = ctx.template_cell,
        .counter_cell = ctx.counter_cell,
        .main = ctx.main,
        .wrapper = ctx.wrapper,
        .template = ctx.template,
        .counter = ctx.counter,
        .body = ctx.body,
        .handler = ctx.handler,
        .body_type = body_type,
    });
}

fn initializeRegion(
    b: *source.Builder,
    ctx: anytype,
) source.Error!source.Module {
    const empty = try b.primitive(ctx.maybe, .variant, &.{try b.constant(void, {})}, 0);
    const r = try b.reference(b.parameter(ctx.wrapper, 0));
    const initialize_template = try b.pure(try b.primitive(
        ctx.template_cell,
        .cell_new,
        &.{ r, empty },
        0,
    ));
    const initialize_counter = try b.pure(try b.primitive(
        ctx.counter_cell,
        .cell_new,
        &.{ r, try b.constant(u64, 0) },
        0,
    ));
    const handled = try b.term(.{ .handle = .{
        .handler = ctx.handler,
        .body = try b.lambda(ctx.body, ctx.body_type),
        .state = &.{ try b.reference(ctx.template), try b.reference(ctx.counter) },
    } });
    try b.define(
        ctx.wrapper,
        try b.bind(
            ctx.template,
            initialize_template,
            try b.bind(ctx.counter, initialize_counter, handled),
        ),
    );
    const wrapper_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ctx.region_type},
        .result = ctx.integer,
        .regions = &.{ctx.region},
    } } });
    try b.define(
        ctx.main,
        try b.term(.{ .with_region = .{
            .region = ctx.region,
            .body = try b.lambda(ctx.wrapper, wrapper_type),
        } }),
    );
    return b.module(ctx.main, ctx.unit);
}
