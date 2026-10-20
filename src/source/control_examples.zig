// Copyright (c) 2026 Boundary contributors. MIT license.
//! Nested answers and a shallow protocol, authored through the public builder.
const source = @import("../source.zig");
const p = @import("horos_data").program;

fn arithmetic(b: *source.Builder, operation: p.Opcode, left: p.Id, right: u64) source.Error!p.Id {
    return b.value(.{ .schema = try b.scalar(u64), .expression = .{ .primitive = .{
        .opcode = operation,
        .operands = &.{ left, try b.constant(u64, right) },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}

pub fn nested(b: *source.Builder) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "example/nested-answer",
        .payload = unit,
        .result = integer,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const inner_k = try b.reserveSchema();
    const outer_k = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = integer,
        .answer = integer,
        .capture_bound = &.{ integer, cap, inner_k },
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    try b.defineSchema(
        inner_k,
        .{ .internal = .{ .resumption = .{
            .effect = effect,
            .input = integer,
            .answer = integer,
            .effects = &.{effect},
            .capture_bound = &.{ integer, cap, inner_k },
            .handled = &.{effect},
            .mode = .deep,
            .use = .linear,
        } } },
    );
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    try b.define(
        returns,
        try b.pure(try arithmetic(
            b,
            .integer_mul,
            try b.reference(b.parameter(returns, 0)),
            10,
        )),
    );
    var handlers: [2]p.Id = undefined;
    for ([_]p.Id{ outer_k, inner_k }, 0..) |token, index| {
        const row: []const p.Id = if (index == 0) &.{} else &.{effect};
        const clause = try b.declare(&.{ unit, token }, integer, row, &.{});
        const answer = try b.variable(integer);
        const resumed = try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(clause, 1)),
            .argument = try b.constant(u64, 5),
        } });
        try b.define(
            clause,
            try b.bind(
                answer,
                resumed,
                try b.pure(try arithmetic(b, .integer_add, try b.reference(answer), 7)),
            ),
        );
        handlers[index] = try b.handler(.{
            .mode = .deep,
            .input = integer,
            .answer = integer,
            .return_function = returns,
            .effects = row,
            .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
        });
    }
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    const outer = try b.declare(&.{cap}, integer, &.{effect}, &.{});
    const inner = try b.declare(&.{cap}, integer, &.{effect}, &.{});
    const value = try b.variable(integer);
    const first = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(inner, 0)),
        .payload = try b.constant(void, {}),
    } });
    const second = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(outer, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(
        inner,
        try b.bind(
            try b.variable(integer),
            first,
            try b.bind(
                value,
                second,
                try b.pure(try arithmetic(b, .integer_add, try b.reference(value), 1)),
            ),
        ),
    );
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{effect},
        .capture_bound = &.{cap},
    } } });
    try b.define(
        outer,
        try b.term(.{ .handle = .{
            .handler = handlers[1],
            .body = try b.lambda(inner, inner_type),
        } }),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{effect},
    } } });
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handlers[0],
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    return b.module(main, unit);
}

pub fn shallow(b: *source.Builder) source.Error!source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const effect = try b.effect(.{
        .identity = "example/shallow-send-receive",
        .payload = boolean,
        .result = boolean,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = boolean,
        .answer = boolean,
        .effects = &.{effect},
        .capture_bound = &.{ boolean, cap },
        .handled = &.{effect},
        .mode = .shallow,
        .use = .linear,
    } } });
    const main = try b.declare(&.{boolean}, boolean, &.{}, &.{});
    const body = try b.declare(&.{cap}, boolean, &.{effect}, &.{});
    const returns = try b.declare(&.{ boolean, boolean }, boolean, &.{}, &.{});
    const clause = try b.declare(&.{ boolean, boolean, token }, boolean, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const handler = try b.handler(.{
        .mode = .shallow,
        .input = boolean,
        .answer = boolean,
        .return_function = returns,
        .state = &.{boolean},
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    const phase = try b.reference(b.parameter(clause, 0));
    const operation = try b.reference(b.parameter(clause, 1));
    const valid = try b.primitive(boolean, .equal, &.{ phase, operation }, 0);
    const continued = try b.term(.{ .resume_with = .{
        .resumption = try b.reference(b.parameter(clause, 2)),
        .argument = operation,
        .handler = handler,
        .state = &.{try b.primitive(boolean, .boolean_not, &.{phase}, 0)},
    } });
    try b.define(
        clause,
        try b.term(.{ .conditional = .{
            .condition = valid,
            .when_true = continued,
            .when_false = try b.term(.{ .fail = try b.constant(void, {}) }),
        } }),
    );
    const capability = try b.reference(b.parameter(body, 0));
    const first = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = capability,
        .payload = try b.reference(b.parameter(main, 0)),
    } });
    const second = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = capability,
        .payload = try b.constant(bool, true),
    } });
    try b.define(body, try b.bind(try b.variable(boolean), first, second));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = boolean,
        .effects = &.{effect},
        .capture_bound = &.{boolean},
    } } });
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handler,
            .body = try b.lambda(body, body_type),
            .state = &.{try b.constant(bool, false)},
        } }),
    );
    return b.module(main, unit);
}
