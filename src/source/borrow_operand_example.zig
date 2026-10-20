// Copyright (c) 2026 Boundary contributors. MIT license.
//! Borrowing an evaluated operand preserves the remaining owned values on failure.
const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;
const Error = source.Error;
const Kind = enum { length, tag, get, owned_length, owned_tag };
const edges = @import("custody_edge_example.zig");
const custody = @import("custody_order_example.zig");
const operand_failures = @import("operand_failure_example.zig");

pub fn build(b: *source.Builder) Error!source.Module {
    const release = try b.effect(.{
        .identity = "custody/release",
        .payload = try b.scalar(u64),
        .result = try b.scalar(void),
    });
    const main = try b.declare(&.{try b.scalar(u8)}, try b.scalar(u64), &.{release}, &.{});
    const input = try b.reference(b.parameter(main, 0));
    var cases: [20 + edges.count + custody.count + operand_failures.count]p.Id = undefined;
    var index: usize = 0;
    for (std.enums.values(Kind)) |kind| {
        for ([_]bool{ false, true }) |explicit| {
            for ([_]bool{ false, true }) |populated| {
                const function = try scenario(b, kind, explicit, populated);
                cases[index] = try b.term(.{ .call = .{
                    .function = function,
                    .arguments = &.{},
                } });
                index += 1;
            }
        }
    }
    for (0..edges.count) |case| {
        const function = try edges.scenario(b, case, true);
        cases[index] = try b.term(.{ .call = .{ .function = function, .arguments = &.{} } });
        index += 1;
    }
    const order = try custody.define(b, release);
    for (0..custody.count) |mode| {
        const function = try custody.build(b, order, @intCast(mode));
        cases[index] = try b.term(.{ .call = .{ .function = function, .arguments = &.{} } });
        index += 1;
    }
    for (0..operand_failures.count) |mode| {
        const function = try operand_failures.build(b, order, mode);
        cases[index] = try b.term(.{ .call = .{ .function = function, .arguments = &.{} } });
        index += 1;
    }
    var body = cases[19];
    while (index > 0) {
        index -= 1;
        const condition = try b.primitive(try b.scalar(bool), .equal, &.{
            input, try b.constant(u8, @intCast(index)),
        }, 0);
        body = try b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = cases[index],
            .when_false = body,
        } });
    }
    try b.define(main, body);
    return b.module(main, try b.scalar(u64));
}

fn scenario(b: *source.Builder, kind: Kind, explicit: bool, populated: bool) Error!p.Id {
    const integer = try b.scalar(u64);
    const byte = try b.scalar(u8);
    const unit = try b.scalar(void);
    const owned = kind == .owned_length or kind == .owned_tag;
    const representation = if (owned) integer else if (kind == .tag)
        try b.schema(.{ .sum = &.{ unit, byte } })
    else
        try b.schema(.{ .vector = .{ .element = byte, .maximum = 2 } });
    const resource = try b.resource(representation);
    const container = if (kind == .owned_length)
        try b.schema(.{ .vector = .{ .element = resource, .maximum = 2 } })
    else if (kind == .owned_tag)
        try b.schema(.{ .sum = &.{ unit, resource } })
    else
        representation;
    const factory = try b.declare(&.{}, resource, &.{}, &.{});
    const function = try b.declare(&.{}, integer, &.{}, &.{});
    try b.resourceAuthority(resource, &.{factory}, &.{function});
    const contents = if (owned) try b.constant(u64, 1) else if (kind == .tag)
        try b.primitive(representation, .variant, &.{if (populated)
            try b.constant(u8, 42)
        else
            try b.constant(void, {})}, @intFromBool(populated))
    else
        try b.primitive(representation, .sequence, if (populated)
            &.{try b.constant(u8, 42)}
        else
            &.{}, 0);
    const wrapped = try b.primitive(resource, .resource_pack, &.{contents}, 0);
    try b.define(factory, try b.pure(wrapped));
    const held = try b.variable(resource);
    const bound = try b.variable(container);
    const raw = try b.primitive(container, switch (kind) {
        .owned_length => .sequence,
        .owned_tag => .variant,
        else => .resource_unpack,
    }, &.{try b.reference(held)}, if (kind == .owned_tag) 1 else 0);
    const operand = if (explicit) try b.reference(bound) else raw;
    var body = try finish(b, kind, operand, populated);
    if (explicit) body = try b.bind(bound, try b.pure(raw), body);
    const acquire = try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } });
    try b.define(function, try b.bind(held, acquire, body));
    return function;
}

fn failAfterYield(b: *source.Builder, reason: u64) Error!p.Id {
    const failure = try b.term(.{ .fail = try b.constant(u64, reason) });
    return b.term(.{ .yield_then = failure });
}

fn finish(b: *source.Builder, kind: Kind, operand: p.Id, populated: bool) Error!p.Id {
    const integer = try b.scalar(u64);
    const failure = try failAfterYield(b, 8);
    const success = try b.pure(try b.constant(u64, 7));
    if (kind == .get) {
        const unit = try b.scalar(void);
        const byte = try b.scalar(u8);
        const optional = try b.schema(.{ .sum = &.{ unit, byte } });
        const found = try b.primitive(optional, .sequence_get, &.{
            operand, try b.constant(u64, 0),
        }, 0);
        return b.term(.{ .match_sum = .{ .value = found, .cases = &.{
            .{ .variable = try b.variable(unit), .body = failure },
            .{ .variable = try b.variable(byte), .body = success },
        } } });
    }
    const owned = kind == .owned_length or kind == .owned_tag;
    const tag = kind == .tag or kind == .owned_tag;
    const observed = try b.primitive(
        integer,
        if (tag) .variant_tag else .sequence_length,
        &.{operand},
        0,
    );
    const expected = try b.constant(u64, if (owned) @intFromBool(populated) else 0);
    const condition = try b.primitive(try b.scalar(bool), .equal, &.{ observed, expected }, 0);
    return b.term(.{ .conditional = .{
        .condition = condition,
        .when_true = failure,
        .when_false = if (owned) try failAfterYield(b, 9) else success,
    } });
}
