// Copyright (c) 2026 Boundary contributors. MIT license.
//! Projection must retain evaluation of the whole constructed product.
const source = @import("../source.zig");

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
