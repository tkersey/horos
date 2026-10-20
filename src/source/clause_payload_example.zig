// Copyright (c) 2026 Boundary contributors. MIT license.
//! A clause may borrow an older attachment, but not its own suspended one.
const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;

pub fn build(b: *source.Builder) source.Error!source.Module {
    return variant(b, true, false);
}

pub fn variant(
    b: *source.Builder,
    comptime older: bool,
    comptime helper: bool,
) source.Error!source.Module {
    const unit = try b.scalar(void);
    const family: p.Id = b.effects.items.len;
    const cap = try b.schema(.{ .internal = .{ .capability = family } });
    const effect = try b.effect(.{
        .identity = "example/clause-payload",
        .payload = cap,
        .result = unit,
        .external = false,
    });
    std.debug.assert(effect == family);
    const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    var handlers: [2]p.Id = undefined;
    for (&handlers, 0..) |*handler, index| {
        const effects: []const p.Id = if (index == 0) &.{} else &.{effect};
        const token = try b.schema(.{ .internal = .{ .resumption = .{
            .effect = effect,
            .input = unit,
            .answer = unit,
            .handled = &.{effect},
            .effects = effects,
            .capture_bound = &.{ unit, cap },
            .mode = .deep,
            .use = .linear,
        } } });
        const clause = try b.declare(&.{ cap, token }, unit, effects, &.{});
        const disposed = try b.term(.{ .dispose = try b.reference(b.parameter(clause, 1)) });
        const completed = try b.bind(
            try b.variable(unit),
            disposed,
            try b.pure(try b.constant(void, {})),
        );
        try b.define(
            clause,
            if (index == 0) completed else try b.term(.{ .yield_then = completed }),
        );
        handler.* = try b.handler(.{
            .mode = .deep,
            .input = unit,
            .answer = unit,
            .effects = effects,
            .return_function = returns,
            .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
        });
    }
    const body = try b.declare(&.{ cap, cap }, unit, &.{effect}, &.{});
    const selected = try b.reference(b.parameter(body, 0));
    const payload = try b.reference(b.parameter(body, @intFromBool(older)));
    const invoked = if (helper) blk: {
        const call = try b.declare(&.{ cap, cap }, unit, &.{effect}, &.{});
        try b.define(
            call,
            try b.term(.{ .perform = .{
                .effect = effect,
                .capability = try b.reference(b.parameter(call, 0)),
                .payload = try b.reference(b.parameter(call, 1)),
            } }),
        );
        break :blk try b.term(.{ .call = .{
            .function = call,
            .arguments = &.{ selected, payload },
        } });
    } else try b.term(.{ .perform = .{
        .effect = effect,
        .capability = selected,
        .payload = payload,
    } });
    try b.define(body, invoked);
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ cap, cap },
        .result = unit,
        .effects = &.{effect},
    } } });
    const outer = try b.declare(&.{cap}, unit, &.{effect}, &.{});
    try b.define(
        outer,
        try b.term(.{ .handle = .{
            .handler = handlers[1],
            .body = try b.lambda(body, body_type),
            .arguments = &.{try b.reference(b.parameter(outer, 0))},
        } }),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = unit,
        .effects = &.{effect},
    } } });
    const entry = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(
        entry,
        try b.term(.{ .handle = .{
            .handler = handlers[0],
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    return b.module(entry, unit);
}
