// Copyright (c) 2026 Boundary contributors. MIT license.
//! Shared code must preserve capture occurrence order even for equal field types.
const source = @import("source.zig");
const Id = source.Id;

pub fn build(b: *source.Builder) !source.Module {
    const integer = try b.scalar(i64);
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const shape = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .capture_bound = &.{integer},
        .use = .reusable,
    } } });
    const main = try b.declare(&.{ integer, integer }, pair, &.{}, &.{});
    var captures: [4]Id = undefined;
    for (&captures) |*value| value.* = try b.variable(integer);
    var closures: [2]Id = undefined;
    var results: [2]Id = undefined;
    var functions: [2]Id = undefined;
    const failure = try b.failureLiteral(try b.constant(void, {}));
    for (&functions, &closures, &results, 0..) |*function, *closure, *result, side| {
        function.* = try b.declare(&.{}, integer, &.{}, &.{});
        closure.* = try b.variable(shape);
        result.* = try b.variable(integer);
        const subtraction = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
            .opcode = .integer_sub,
            .operands = &.{
                try b.reference(captures[side * 2]),
                try b.reference(captures[side * 2 + 1]),
            },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } } });
        try b.define(function.*, try b.pure(subtraction));
    }
    var next = try b.pure(try b.primitive(
        pair,
        .product,
        &.{ try b.reference(results[0]), try b.reference(results[1]) },
        0,
    ));
    var cursor: usize = 2;
    while (cursor != 0) {
        cursor -= 1;
        const apply = try b.term(.{ .apply = .{
            .computation = try b.reference(closures[cursor]),
            .arguments = &.{},
        } });
        next = try b.bind(
            closures[cursor],
            try b.pure(try b.lambda(functions[cursor], shape)),
            try b.bind(results[cursor], apply, next),
        );
    }
    // The second closure intentionally captures right then left. Both fields
    // have the same schema, so sorting operands would silently change behavior.
    const parameter_order = [_]usize{ 0, 1, 1, 0 };
    cursor = captures.len;
    while (cursor != 0) {
        cursor -= 1;
        next = try b.bind(
            captures[cursor],
            try b.pure(try b.reference(b.parameter(main, parameter_order[cursor]))),
            next,
        );
    }
    try b.define(main, next);
    return b.module(main, unit);
}
