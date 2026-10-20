// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independent recursive groups with role-specific base values and request traces.
const std = @import("std");
const source = @import("source.zig");
const data = @import("horos_data");
const Id = source.Id;
pub const Kind = enum { recursive, recursive_near, recursive_infinite };

pub fn compile(
    allocator: std.mem.Allocator,
    kind: Kind,
    options: data.coalescing.Options,
) !source.Compiled {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const effect: ?Id = if (kind == .recursive_infinite)
        try b.effect(.{
            .identity = "coalescing/recursive-step",
            .payload = integer,
            .result = unit,
        })
    else
        null;
    const row: []const Id = if (effect) |*id| id[0..1] else &.{};
    var groups: [2][2]Id = undefined;
    for (&groups) |*group| for (group) |*function| {
        function.* = try b.declare(&.{integer}, integer, row, &.{});
    };
    try defineRecursiveGroups(&b, groups, kind, effect, integer, boolean, unit);
    const entry = try b.declare(&.{integer}, pair, row, &.{});
    const n = try b.reference(b.parameter(entry, 0));
    const left = try b.variable(integer);
    const right = try b.variable(integer);
    const first = try b.term(.{ .call = .{ .function = groups[0][0], .arguments = &.{n} } });
    const second = try b.term(.{ .call = .{ .function = groups[1][0], .arguments = &.{n} } });
    const result = try b.primitive(
        pair,
        .product,
        &.{ try b.reference(left), try b.reference(right) },
        0,
    );
    try b.define(entry, try b.bind(left, first, try b.bind(right, second, try b.pure(result))));
    return source.lowerObserved(allocator, b.module(entry, unit), .{ .coalescing = options });
}

fn defineRecursiveGroups(
    b: *source.Builder,
    groups: [2][2]Id,
    kind: Kind,
    effect: ?Id,
    integer: Id,
    boolean: Id,
    unit: Id,
) source.Error!void {
    for (groups, 0..) |group, side| for (group, 0..) |function, role| {
        const n = try b.reference(b.parameter(function, 0));
        const base: u64 = if (kind == .recursive_near and side == 1 and role == 1)
            43
        else
            41 + @as(u64, @intCast(role));
        const value = try b.constant(u64, base);
        if (effect) |operation| {
            const request = try b.term(.{ .perform = .{ .effect = operation, .payload = value } });
            const call = try b.term(.{ .call = .{
                .function = group[1 - role],
                .arguments = &.{n},
            } });
            try b.define(function, try b.bind(try b.variable(unit), request, call));
        } else {
            const zero = try b.primitive(boolean, .equal, &.{ n, try b.constant(u64, 0) }, 0);
            const decrement = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
                .opcode = .integer_sub,
                .operands = &.{ n, try b.constant(u64, 1) },
                .failures = &.{.{
                    .kind = .arithmetic_overflow,
                    .value = try b.failureLiteral(try b.constant(void, {})),
                }},
            } } });
            try b.define(function, try b.term(.{ .conditional = .{
                .condition = zero,
                .when_true = try b.pure(value),
                .when_false = try b.term(.{ .call = .{
                    .function = group[1 - role],
                    .arguments = &.{decrement},
                } }),
            } }));
        }
    };
}
