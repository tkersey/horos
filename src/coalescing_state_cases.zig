// Copyright (c) 2026 Boundary contributors. MIT license.
//! Stateful closure witnesses authored with the public staged builder.
const source = @import("source.zig");
const Id = source.Id;
pub const Kind = enum { cells_independent, cells_shared, memo_independent, memo_shared };
const Types = struct {
    unit: Id,
    integer: Id,
    region: Id,
    token: Id,
    counter: Id,
    optional: Id,
    memo: Id,
    result: Id,
    thunk: Id,
};

pub fn build(b: *source.Builder, kind: Kind) !source.Module {
    const memo = kind == .memo_independent or kind == .memo_shared;
    const shared = kind == .cells_shared or kind == .memo_shared;
    const t = try types(b, memo);
    const entry = try b.declare(&.{}, t.result, &.{}, &.{});
    const inside = try b.declare(&.{t.token}, t.result, &.{}, &.{t.region});
    const counter = try b.variable(t.counter);
    const cell_type = if (memo) t.memo else t.counter;
    const cells = [_]Id{ try b.variable(cell_type), try b.variable(cell_type) };
    const closures = [_]Id{ try b.variable(t.thunk), try b.variable(t.thunk) };
    var helpers: [2]Id = undefined;
    for (&helpers, cells) |*helper, cell| {
        helper.* = try b.declare(&.{}, t.integer, &.{}, &.{t.region});
        try b.define(
            helper.*,
            if (memo) try memoBody(b, t, cell, counter) else try increment(b, t, cell, null),
        );
    }
    var next = try calls(b, t, closures, if (memo) counter else null);
    next = try b.bind(closures[1], try b.pure(try b.lambda(helpers[1], t.thunk)), next);
    next = try b.bind(closures[0], try b.pure(try b.lambda(helpers[0], t.thunk)), next);
    const token = try b.reference(b.parameter(inside, 0));
    const initial = if (memo)
        try b.primitive(t.optional, .variant, &.{try b.constant(void, {})}, 0)
    else
        try b.constant(u64, 0);
    const first = try b.primitive(cell_type, .cell_new, &.{ token, initial }, 0);
    const second = if (shared) try b.reference(cells[0]) else try b.primitive(
        cell_type,
        .cell_new,
        &.{ token, initial },
        0,
    );
    next = try b.bind(cells[0], try b.pure(first), try b.bind(cells[1], try b.pure(second), next));
    if (memo) next = try b.bind(
        counter,
        try b.pure(try b.primitive(
            t.counter,
            .cell_new,
            &.{ token, try b.constant(u64, 0) },
            0,
        )),
        next,
    );
    try b.define(inside, next);
    const body = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{t.token},
        .result = t.result,
        .regions = &.{t.region},
    } } });
    try b.define(entry, try b.term(.{ .with_region = .{
        .region = t.region,
        .body = try b.lambda(inside, body),
    } }));
    return b.module(entry, t.unit);
}

fn types(b: *source.Builder, memo: bool) !Types {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const region = b.region();
    const token = try b.schema(.{ .internal = .{ .region = region } });
    const counter = try b.schema(.{ .internal = .{ .cell = .{
        .element = integer,
        .region = region,
    } } });
    const optional = try b.schema(.{ .sum = &.{ unit, integer } });
    const cache = try b.schema(.{ .internal = .{ .cell = .{
        .element = optional,
        .region = region,
    } } });
    const result = try b.schema(.{ .product = if (memo)
        &.{ integer, integer, integer, integer }
    else
        &.{ integer, integer, integer } });
    const thunk = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .regions = &.{region},
        .capture_bound = if (memo) &.{ counter, cache } else &.{counter},
        .use = .reusable,
    } } });
    return .{
        .unit = unit,
        .integer = integer,
        .region = region,
        .token = token,
        .counter = counter,
        .optional = optional,
        .memo = cache,
        .result = result,
        .thunk = thunk,
    };
}

fn increment(b: *source.Builder, t: Types, cell: Id, cache: ?Id) !Id {
    const reference = try b.reference(cell);
    const value = try b.variable(t.integer);
    const sum = try b.value(.{ .schema = t.integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{
            try b.primitive(t.integer, .cell_get, &.{reference}, 0),
            try b.constant(u64, 1),
        },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
    const computed = try b.reference(value);
    var next = try b.pure(computed);
    if (cache) |memo| {
        const some = try b.primitive(t.optional, .variant, &.{computed}, 1);
        next = try b.bind(
            try b.variable(t.unit),
            try b.pure(try b.primitive(t.unit, .cell_set, &.{ try b.reference(memo), some }, 0)),
            next,
        );
    }
    next = try b.bind(
        try b.variable(t.unit),
        try b.pure(try b.primitive(t.unit, .cell_set, &.{ reference, computed }, 0)),
        next,
    );
    return b.bind(value, try b.pure(sum), next);
}

fn memoBody(b: *source.Builder, t: Types, cell: Id, counter: Id) !Id {
    const absent = try b.variable(t.unit);
    const ready = try b.variable(t.integer);
    return b.term(.{ .match_sum = .{
        .value = try b.primitive(t.optional, .cell_get, &.{try b.reference(cell)}, 0),
        .cases = &.{
            .{ .variable = absent, .body = try increment(b, t, counter, cell) },
            .{ .variable = ready, .body = try b.pure(try b.reference(ready)) },
        },
    } });
}

fn calls(b: *source.Builder, t: Types, closures: [2]Id, counter: ?Id) !Id {
    const results = [_]Id{
        try b.variable(t.integer),
        try b.variable(t.integer),
        try b.variable(t.integer),
    };
    var values: [4]Id = undefined;
    for (results, values[0..3]) |result, *value| value.* = try b.reference(result);
    if (counter) |cell| values[3] = try b.primitive(
        t.integer,
        .cell_get,
        &.{try b.reference(cell)},
        0,
    );
    var next = try b.pure(try b.primitive(
        t.result,
        .product,
        values[0..@as(usize, if (counter != null) 4 else 3)],
        0,
    ));
    const order = if (counter != null) [_]usize{ 0, 0, 1 } else [_]usize{ 0, 1, 0 };
    var index: usize = results.len;
    while (index != 0) {
        index -= 1;
        const apply = try b.term(.{ .apply = .{
            .computation = try b.reference(closures[order[index]]),
            .arguments = &.{},
        } });
        next = try b.bind(results[index], apply, next);
    }
    return next;
}
