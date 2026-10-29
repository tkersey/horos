// Copyright (c) 2026 Boundary contributors. MIT license.
//! Projection must retain evaluation of the whole constructed product.
const source = @import("../source.zig");

pub fn composition(b: *source.Builder) source.Error!source.Module {
    const word = try b.scalar(u64);
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const producer = try b.declare(&.{ word, word }, pair, &.{}, &.{});
    const x = try b.reference(b.parameter(producer, 0));
    const mask = try b.reference(b.parameter(producer, 1));
    const first = try b.primitive(word, .integer_bit_and, &.{ x, mask }, 0);
    const second = try b.primitive(word, .integer_bit_xor, &.{ x, mask }, 0);
    try b.define(producer, try b.pure(try b.primitive(pair, .product, &.{ first, second }, 0)));
    const consumers = [_]source.Id{
        try compositionConsumer(b, word, pair, boolean, 0),
        try compositionConsumer(b, word, pair, boolean, 1),
    };
    const callers = [_]source.Id{
        try compositionCaller(b, word, pair, boolean, producer, consumers[0], 0),
        try compositionCaller(b, word, pair, boolean, producer, consumers[1], 1),
    };
    const entry = try b.declare(&.{ word, word, word, boolean }, boolean, &.{}, &.{});
    const arguments = [_]source.Id{
        try b.reference(b.parameter(entry, 0)),
        try b.reference(b.parameter(entry, 1)),
        try b.reference(b.parameter(entry, 2)),
    };
    const left = try b.term(.{ .call = .{ .function = callers[0], .arguments = &arguments } });
    const right = try b.term(.{ .call = .{ .function = callers[1], .arguments = &arguments } });
    try b.define(entry, try b.term(.{ .conditional = .{
        .condition = try b.reference(b.parameter(entry, 3)),
        .when_true = left,
        .when_false = right,
    } }));
    return b.module(entry, unit);
}

fn compositionConsumer(
    b: *source.Builder,
    word: source.Id,
    pair: source.Id,
    boolean: source.Id,
    field: u1,
) source.Error!source.Id {
    const function = try b.declare(
        if (field == 0) &.{ pair, word } else &.{ word, pair },
        boolean,
        &.{},
        &.{},
    );
    const product = try b.reference(b.parameter(function, field));
    const cutoff = try b.reference(b.parameter(function, 1 - @as(usize, field)));
    const selected = try b.primitive(word, .field, &.{product}, field);
    const result = try b.primitive(
        boolean,
        if (field == 0) .less else .equal,
        &.{ selected, cutoff },
        0,
    );
    try b.define(function, try b.pure(result));
    return function;
}

fn compositionCaller(
    b: *source.Builder,
    word: source.Id,
    pair: source.Id,
    boolean: source.Id,
    producer: source.Id,
    consumer: source.Id,
    position: u1,
) source.Error!source.Id {
    const function = try b.declare(&.{ word, word, word }, boolean, &.{}, &.{});
    const product = try b.variable(pair);
    const produced = try b.term(.{ .call = .{
        .function = producer,
        .arguments = &.{
            try b.reference(b.parameter(function, 0)),
            try b.reference(b.parameter(function, 1)),
        },
    } });
    const value = try b.reference(product);
    const cutoff = try b.reference(b.parameter(function, 2));
    const consumed = try b.term(.{ .call = .{
        .function = consumer,
        .arguments = if (position == 0) &.{ value, cutoff } else &.{ cutoff, value },
    } });
    try b.define(function, try b.bind(product, produced, consumed));
    return function;
}

pub fn build(b: *source.Builder) source.Error!source.Module {
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const ordered_type = try b.schema(.{ .product = &.{ integer, unit, integer } });
    const failure = try b.failureLiteral(try b.constant(u64, 77));
    const entry = try b.declare(&.{boolean}, integer, &.{}, &.{});
    const region = b.region();
    const region_type = try b.schema(.{ .internal = .{ .region = region } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{
        .element = integer,
        .region = region,
    } } });
    const inside = try b.declare(&.{region_type}, integer, &.{}, &.{region});
    const allocated = try b.variable(cell);
    const reference = try b.reference(allocated);
    const read = try b.primitive(integer, .cell_get, &.{reference}, 0);
    const write = try b.primitive(unit, .cell_set, &.{ reference, try b.constant(u64, 7) }, 0);
    const ordered = try b.primitive(ordered_type, .product, &.{ read, write, read }, 0);
    const first = try b.primitive(integer, .field, &.{ordered}, 0);
    // The first read is 1; the later read is 7. A source expression is evaluated
    // again when it contains mutable reads, even when its syntax ID is reused.
    const total = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ first, read },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
    } } });
    const initial = try b.primitive(
        cell,
        .cell_new,
        &.{ try b.reference(b.parameter(inside, 0)), try b.constant(u64, 1) },
        0,
    );
    try b.define(inside, try b.bind(allocated, try b.pure(initial), try b.pure(total)));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region_type},
        .result = integer,
        .regions = &.{region},
    } } });
    const mutable = try b.term(.{ .with_region = .{
        .region = region,
        .body = try b.lambda(inside, body_type),
    } });
    const overflow = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ try b.constant(u64, ~@as(u64, 0)), try b.constant(u64, 1) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
    } } });
    const failing_product = try b.primitive(
        pair,
        .product,
        &.{ try b.constant(u64, 42), overflow },
        0,
    );
    const selected = try b.primitive(integer, .field, &.{failing_product}, 0);
    try b.define(entry, try b.term(.{ .conditional = .{
        .condition = try b.reference(b.parameter(entry, 0)),
        .when_true = try b.pure(selected),
        .when_false = mutable,
    } }));
    return b.module(entry, integer);
}
