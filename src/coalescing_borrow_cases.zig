// Copyright (c) 2026 Boundary contributors. MIT license.
//! Equivalent helpers reached through two separately established resource loans.
const source = @import("source.zig");
const Id = @import("horos_data").program.Id;

pub fn build(b: *source.Builder, escape: bool) !source.Module {
    const original = try source.examples.resourceScalar(b);
    const acquired = try @import("source/fixture_inspection.zig").resourceEntry(b, original.entry);
    const protected = b.terms.items[@intCast(acquired.next)].protect;
    const body_value = b.values.items[@intCast(protected.body)];
    const first_body = body_value.expression.lambda;
    const signature = b.functions.items[@intCast(first_body)];
    const borrowed = b.variables.items[@intCast(b.parameter(first_body, 0))];
    const owned = b.variables.items[@intCast(acquired.variable)];
    const integer = signature.result;
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const read = b.resources.items[0].eliminators[0];
    const second_body = try b.declare(
        &.{borrowed},
        if (escape) borrowed else integer,
        signature.effects,
        signature.regions,
    );
    for ([_]Id{ first_body, second_body }, 0..) |body, index| {
        const identity = try b.declare(&.{borrowed}, borrowed, &.{}, signature.regions);
        try b.define(identity, try b.pure(try b.reference(b.parameter(identity, 0))));
        const alias = try b.variable(borrowed);
        const invoke = try b.term(.{ .call = .{
            .function = identity,
            .arguments = &.{try b.reference(b.parameter(body, 0))},
        } });
        const result = if (escape and index == 1)
            try b.pure(try b.reference(alias))
        else
            try b.term(.{ .call = .{ .function = read, .arguments = &.{try b.reference(alias)} } });
        b.functions.items[@intCast(body)].body = try b.bind(alias, invoke, result);
    }
    var body_shape = b.schemas.items[@intCast(body_value.schema)].internal.computation;
    if (escape) body_shape.result = borrowed;
    const second_resource = try b.variable(owned);
    var second_protection = protected;
    second_protection.resource = try b.reference(second_resource);
    second_protection.body = try b.lambda(
        second_body,
        if (escape) try b.schema(
            .{ .internal = .{ .computation = body_shape } },
        ) else body_value.schema,
    );
    const left = try b.variable(integer);
    const right = try b.variable(integer);
    var tail = try b.pure(try b.primitive(
        pair,
        .product,
        &.{ try b.reference(left), try b.reference(right) },
        0,
    ));
    if (escape) {
        const escaped = try b.variable(borrowed);
        const outside = try b.term(.{ .call = .{
            .function = read,
            .arguments = &.{try b.reference(escaped)},
        } });
        tail = try b.bind(
            escaped,
            try b.term(.{ .protect = second_protection }),
            try b.bind(right, outside, tail),
        );
    } else tail = try b.bind(right, try b.term(.{ .protect = second_protection }), tail);
    tail = try b.bind(second_resource, acquired.value, tail);
    tail = try b.bind(left, acquired.next, tail);
    b.functions.items[@intCast(original.entry)].result = pair;
    b.functions.items[@intCast(original.entry)].body = try b.bind(
        acquired.variable,
        acquired.value,
        tail,
    );
    return b.module(original.entry, original.failure);
}
