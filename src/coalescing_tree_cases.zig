// Copyright (c) 2026 Boundary contributors. MIT license.
//! Two independent depth-eight helper chains, alternating calls and computations.
const std = @import("std");
const source = @import("source.zig");
const data = @import("horos_data");
const Id = data.program.Id;
pub const Kind = enum { tree, tree_near };
const depth = 8;

pub fn compile(
    a: std.mem.Allocator,
    kind: Kind,
    options: data.coalescing.Options,
) !source.Compiled {
    var b = source.Builder.init(a);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const callable = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{integer},
        .result = integer,
        .use = .reusable,
    } } });
    var groups: [2][depth + 1]Id = undefined;
    for (&groups) |*group| for (group) |*function| {
        function.* = try b.declare(&.{integer}, integer, &.{}, &.{});
    };
    for (groups, 0..) |group, side| {
        const argument = try b.reference(b.parameter(group[0], 0));
        const leaf = if (kind == .tree_near and side == 1)
            try addOne(&b, integer, argument)
        else
            argument;
        try b.define(group[0], try b.pure(leaf));
        for (1..depth + 1) |level|
            try parent(&b, integer, callable, group[level], group[level - 1], level % 2 == 1);
    }
    const main = try b.declare(&.{integer}, pair, &.{}, &.{});
    const argument = try b.reference(b.parameter(main, 0));
    const left = try b.variable(integer);
    const right = try b.variable(integer);
    const first = try b.term(.{ .call = .{
        .function = groups[0][depth],
        .arguments = &.{argument},
    } });
    const second = try b.term(.{ .call = .{
        .function = groups[1][depth],
        .arguments = &.{argument},
    } });
    const result = try b.primitive(
        pair,
        .product,
        &.{ try b.reference(left), try b.reference(right) },
        0,
    );
    try b.define(main, try b.bind(left, first, try b.bind(right, second, try b.pure(result))));
    return source.lowerObserved(a, b.module(main, unit), .{ .coalescing = options });
}

fn addOne(b: *source.Builder, integer: Id, value: Id) !Id {
    return b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ value, try b.constant(u64, 1) },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}

fn parent(
    b: *source.Builder,
    integer: Id,
    callable: Id,
    function: Id,
    child: Id,
    indirect: bool,
) !void {
    const argument = try b.reference(b.parameter(function, 0));
    const result = try b.variable(integer);
    const next = try b.pure(try addOne(b, integer, try b.reference(result)));
    if (indirect) {
        const closure = try b.variable(callable);
        const apply = try b.term(.{ .apply = .{
            .computation = try b.reference(closure),
            .arguments = &.{argument},
        } });
        try b.define(
            function,
            try b.bind(
                closure,
                try b.pure(try b.lambda(child, callable)),
                try b.bind(result, apply, next),
            ),
        );
    } else {
        const call = try b.term(.{ .call = .{ .function = child, .arguments = &.{argument} } });
        try b.define(function, try b.bind(result, call, next));
    }
}
