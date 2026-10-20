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
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    const wrapper = try b.declare(&.{region_type}, integer, &.{}, &.{region});
    const template = try b.variable(template_cell);
    const counter = try b.variable(counter_cell);
    const body = try b.declare(&.{cap}, integer, &.{operation}, &.{region});
    const returns = try b.declare(
        &.{ template_cell, counter_cell, integer },
        integer,
        &.{},
        &.{region},
    );
    try b.define(returns, try b.pure(try add(b, try b.reference(b.parameter(returns, 2)), 1)));
    const owned_token = if (convert) try b.schema(.{ .internal = .{ .resumption = .{
        .effect = operation,
        .input = unit,
        .answer = integer,
        .capture_bound = &.{ template_cell, counter_cell },
        .handled = &.{operation},
        .mode = .deep,
        .use = .linear,
    } } }) else token;
    const clause = try b.declare(
        &.{ template_cell, counter_cell, unit, owned_token },
        integer,
        &.{},
        &.{region},
    );
    const converted = if (convert) try b.variable(token) else b.parameter(clause, 3);
    const k = try b.reference(converted);
    const save = try b.pure(try b.primitive(
        unit,
        .cell_set,
        &.{ try b.reference(b.parameter(clause, 0)), try b.primitive(maybe, .variant, &.{k}, 1) },
        0,
    ));
    const first = try b.variable(integer);
    const resumed = try b.term(.{ .resume_value = .{
        .resumption = k,
        .argument = try b.constant(void, {}),
    } });
    const clause_body = try b.bind(
        try b.variable(unit),
        save,
        try b.bind(first, resumed, try b.pure(try add(b, try b.reference(first), 1))),
    );
    try b.define(
        clause,
        if (convert) try b.bind(
            converted,
            try b.pure(try b.cloneResumption(try b.reference(b.parameter(clause, 3)), token)),
            clause_body,
        ) else clause_body,
    );
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .return_function = returns,
        .state = &.{ template_cell, counter_cell },
        .clauses = &.{.{ .effect = operation, .function = clause, .resumption = owned_token }},
    });
    const observed = try b.primitive(integer, .cell_get, &.{try b.reference(counter)}, 0);
    const condition = try b.primitive(boolean, .equal, &.{ observed, try b.constant(u64, 0) }, 0);
    const mark = try b.pure(try b.primitive(
        unit,
        .cell_set,
        &.{ try b.reference(counter), try b.constant(u64, 1) },
        0,
    ));
    const stored = try b.primitive(maybe, .cell_get, &.{try b.reference(template)}, 0);
    const present = try b.variable(token);
    const second = try b.variable(integer);
    const reentered = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(present),
        .argument = try b.constant(void, {}),
    } });
    const matched = try b.term(.{ .match_sum = .{ .value = stored, .cases = &.{
        .{
            .variable = try b.variable(unit),
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
        try b.variable(unit),
        mark,
        matched,
    ) });
    const choose = try b.term(.{ .conditional = .{
        .condition = condition,
        .when_true = recursive,
        .when_false = if (result) |function| try b.term(.{ .call = .{
            .function = function,
            .arguments = &.{},
        } }) else try b.pure(try b.constant(u64, 10)),
    } });
    const capture = try b.term(.{ .perform = .{
        .effect = operation,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(body, try b.bind(try b.variable(unit), capture, choose));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{operation},
        .capture_bound = &.{ template_cell, counter_cell },
        .regions = &.{region},
    } } });
    const empty = try b.primitive(maybe, .variant, &.{try b.constant(void, {})}, 0);
    const r = try b.reference(b.parameter(wrapper, 0));
    const initialize_template = try b.pure(try b.primitive(
        template_cell,
        .cell_new,
        &.{ r, empty },
        0,
    ));
    const initialize_counter = try b.pure(try b.primitive(
        counter_cell,
        .cell_new,
        &.{ r, try b.constant(u64, 0) },
        0,
    ));
    const handled = try b.term(.{ .handle = .{
        .handler = handler,
        .body = try b.lambda(body, body_type),
        .state = &.{ try b.reference(template), try b.reference(counter) },
    } });
    try b.define(
        wrapper,
        try b.bind(
            template,
            initialize_template,
            try b.bind(counter, initialize_counter, handled),
        ),
    );
    const wrapper_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region_type},
        .result = integer,
        .regions = &.{region},
    } } });
    try b.define(
        main,
        try b.term(.{ .with_region = .{
            .region = region,
            .body = try b.lambda(wrapper, wrapper_type),
        } }),
    );
    return b.module(main, unit);
}
