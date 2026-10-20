// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independently described handlers retain distinct installation state.
const source = @import("source.zig");
const p = @import("horos_data").program;
pub const Kind = enum { duplicate, mixed_mode, effect_duplicate };

pub fn build(b: *source.Builder, kind: Kind) !source.Module {
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const effect: ?p.Id = if (kind == .effect_duplicate)
        try b.effect(.{
            .identity = "coalescing/handled",
            .payload = unit,
            .result = integer,
            .external = false,
        })
    else
        null;
    const cap: ?p.Id = if (effect) |id|
        try b.schema(.{ .internal = .{ .capability = id } })
    else
        null;
    const parameters: []const p.Id = if (cap) |*id| id[0..1] else &.{};
    const effects: []const p.Id = if (effect) |*id| id[0..1] else &.{};
    const callable = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = parameters,
        .result = integer,
        .use = .reusable,
        .effects = effects,
    } } });
    var handlers: [2]p.Id = undefined;
    var bodies: [2]p.Id = undefined;
    for (&handlers, &bodies, 0..) |*handler, *body, index| {
        const returns = try b.declare(&.{ integer, integer }, integer, &.{}, &.{});
        const sum = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{
                try b.reference(b.parameter(returns, 0)),
                try b.reference(b.parameter(returns, 1)),
            },
            .failures = &.{.{
                .kind = .arithmetic_overflow,
                .value = try b.failureLiteral(try b.constant(void, {})),
            }},
        } } });
        try b.define(returns, try b.pure(sum));
        handler.* = try b.handler(.{
            .mode = if (kind == .mixed_mode and index == 1) .shallow else .deep,
            .input = integer,
            .answer = integer,
            .state = &.{integer},
            .return_function = returns,
            .clauses = if (effect) |id|
                try clauses(b, unit, integer, cap.?, id)
            else
                &.{},
        });
        body.* = try b.declare(parameters, integer, effects, &.{});
        const body_term = if (effect) |id| try b.term(.{ .perform = .{
            .effect = id,
            .capability = try b.reference(b.parameter(body.*, 0)),
            .payload = try b.constant(void, {}),
        } }) else try b.pure(try b.constant(u64, 10));
        try b.define(body.*, body_term);
    }
    const entry = try b.declare(&.{ integer, integer }, pair, &.{}, &.{});
    const results = [_]p.Id{ try b.variable(integer), try b.variable(integer) };
    var next = try b.pure(try b.primitive(
        pair,
        .product,
        &.{ try b.reference(results[0]), try b.reference(results[1]) },
        0,
    ));
    var index: usize = handlers.len;
    while (index != 0) {
        index -= 1;
        const installation = try b.term(.{ .handle = .{
            .handler = handlers[index],
            .body = try b.lambda(bodies[index], callable),
            .state = &.{try b.reference(b.parameter(entry, index))},
        } });
        next = try b.bind(results[index], installation, next);
    }
    try b.define(entry, next);
    return b.module(entry, unit);
}

fn clauses(
    b: *source.Builder,
    unit: p.Id,
    integer: p.Id,
    cap: p.Id,
    effect: p.Id,
) ![]const p.Clause {
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = integer,
        .answer = integer,
        .capture_bound = &.{ unit, integer, cap },
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const function = try b.declare(&.{ integer, unit, token }, integer, &.{}, &.{});
    try b.define(function, try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(function, 2)),
        .argument = try b.constant(u64, 10),
    } }));
    return b.allocator().dupe(
        p.Clause,
        &.{.{ .effect = effect, .function = function, .resumption = token }},
    );
}
