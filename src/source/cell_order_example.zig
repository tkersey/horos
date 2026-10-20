// Copyright (c) 2026 Boundary contributors. MIT license.
//! Reusing syntax is not a let binding: reads on either side of a write differ.
const source = @import("../source.zig");
pub fn build(b: *source.Builder) source.Error!source.ast.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const answer = try b.schema(.{ .product = &.{ integer, unit, integer } });
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = integer, .region = r } } });
    const main = try b.declare(&.{}, answer, &.{}, &.{});
    const inside = try b.declare(&.{region}, answer, &.{}, &.{r});
    const allocated = try b.variable(cell);
    const ref = try b.reference(allocated);
    const read = try b.primitive(integer, .cell_get, &.{ref}, 0);
    const write = try b.primitive(unit, .cell_set, &.{ ref, try b.constant(u64, 7) }, 0);
    const ordered = try b.primitive(answer, .product, &.{ read, write, read }, 0);
    try b.define(
        inside,
        try b.bind(
            allocated,
            try b.pure(try b.primitive(
                cell,
                .cell_new,
                &.{ try b.reference(b.parameter(inside, 0)), try b.constant(u64, 1) },
                0,
            )),
            try b.pure(ordered),
        ),
    );
    const body = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = answer,
        .regions = &.{r},
    } } });
    try b.define(
        main,
        try b.term(.{ .with_region = .{ .region = r, .body = try b.lambda(inside, body) } }),
    );
    return b.module(main, unit);
}
