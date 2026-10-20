// Copyright (c) 2026 Boundary contributors. MIT license.
//! An owned value remains in custody across a call on a branch that will fail.
const source = @import("../source.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const resource = try b.resource(integer);
    const effect = try b.effect(.{
        .identity = "example/before-abort",
        .payload = unit,
        .result = unit,
    });
    const factory = try b.declare(&.{}, resource, &.{}, &.{});
    const consume = try b.declare(&.{resource}, integer, &.{}, &.{});
    try b.resourceAuthority(resource, &.{factory}, &.{consume});
    try b.define(
        factory,
        try b.pure(try b.primitive(resource, .resource_pack, &.{try b.constant(u64, 41)}, 0)),
    );
    try b.define(
        consume,
        try b.pure(try b.primitive(
            integer,
            .resource_unpack,
            &.{try b.reference(b.parameter(consume, 0))},
            0,
        )),
    );
    const tick = try b.declare(&.{}, unit, &.{effect}, &.{});
    try b.define(
        tick,
        try b.term(.{ .perform = .{ .effect = effect, .payload = try b.constant(void, {}) } }),
    );
    const main = try b.declare(&.{boolean}, integer, &.{effect}, &.{});
    const owned = try b.variable(resource);
    const acquired = try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } });
    const returned = try b.term(.{ .call = .{
        .function = consume,
        .arguments = &.{try b.reference(owned)},
    } });
    const aborted = try b.bind(
        try b.variable(unit),
        try b.term(.{ .call = .{ .function = tick, .arguments = &.{} } }),
        try b.term(.{ .fail = try b.constant(u64, 9) }),
    );
    try b.define(
        main,
        try b.bind(
            owned,
            acquired,
            try b.term(.{ .conditional = .{
                .condition = try b.reference(b.parameter(main, 0)),
                .when_true = returned,
                .when_false = aborted,
            } }),
        ),
    );
    return b.module(main, integer);
}
