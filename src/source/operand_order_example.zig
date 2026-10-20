// Copyright (c) 2026 Boundary contributors. MIT license.
//! Each control operand writes a distinct value before the final operand reads.
const source = @import("../source.zig");
const p = @import("horos_data").program;

pub fn handle(b: *source.Builder) source.Error!source.Module {
    return build(b, false);
}

pub fn protect(b: *source.Builder) source.Error!source.Module {
    return build(b, true);
}

fn afterWrite(
    b: *source.Builder,
    unit: p.Id,
    schema: p.Id,
    cell: p.Id,
    value: u64,
    computation: p.Id,
) source.Error!p.Id {
    const pair = try b.schema(.{ .product = &.{ unit, schema } });
    const write = try b.primitive(unit, .cell_set, &.{ cell, try b.constant(u64, value) }, 0);
    const ordered = try b.primitive(pair, .product, &.{ write, computation }, 0);
    return b.primitive(schema, .field, &.{ordered}, 1);
}

fn build(b: *source.Builder, comptime protected: bool) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = integer, .region = r } } });
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    const inside = try b.declare(&.{region}, integer, &.{}, &.{r});
    const allocated = try b.variable(cell);
    const ref = try b.reference(allocated);
    const read = try b.primitive(integer, .cell_get, &.{ref}, 0);
    const write = try b.primitive(unit, .cell_set, &.{ ref, try b.constant(u64, 7) }, 0);
    const control = if (protected) blk: {
        const owned = try b.resource(integer);
        const loan = b.region();
        const borrowed = try b.schema(.{ .internal = .{ .borrowed = .{
            .value = owned,
            .region = loan,
        } } });
        const info = try @import("../library/cleanup.zig").exitInfo(b, unit);
        const body = try b.declare(&.{ borrowed, unit }, integer, &.{}, &.{loan});
        const cleanup = try b.declare(&.{ info, owned }, unit, &.{}, &.{});
        try b.resourceAuthority(owned, &.{inside}, &.{ body, cleanup });
        try b.define(
            body,
            try b.pure(try b.primitive(
                integer,
                .resource_unpack,
                &.{try b.reference(b.parameter(body, 0))},
                0,
            )),
        );
        const discarded = try b.variable(integer);
        const release = try b.pure(try b.primitive(
            integer,
            .resource_unpack,
            &.{try b.reference(b.parameter(cleanup, 1))},
            0,
        ));
        try b.define(cleanup, try b.bind(discarded, release, try b.pure(try b.constant(void, {}))));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{ borrowed, unit },
            .result = integer,
            .regions = &.{loan},
        } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{ info, owned },
            .result = unit,
        } } });
        break :blk try b.term(.{ .protect = .{
            .body = try afterWrite(b, unit, body_type, ref, 3, try b.lambda(body, body_type)),
            .cleanup = try afterWrite(
                b,
                unit,
                cleanup_type,
                ref,
                5,
                try b.lambda(cleanup, cleanup_type),
            ),
            .arguments = &.{write},
            .resource = try b.primitive(owned, .resource_pack, &.{read}, 0),
            .loan_region = loan,
        } });
    } else blk: {
        const body = try b.declare(&.{unit}, unit, &.{}, &.{});
        try b.define(body, try b.pure(try b.reference(b.parameter(body, 0))));
        const returns = try b.declare(&.{ integer, unit }, integer, &.{}, &.{});
        try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
        const handler = try b.handler(.{
            .mode = .deep,
            .input = unit,
            .answer = integer,
            .return_function = returns,
            .clauses = &.{},
            .state = &.{integer},
        });
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{unit},
            .result = unit,
        } } });
        break :blk try b.term(.{ .handle = .{
            .handler = handler,
            .body = try afterWrite(b, unit, body_type, ref, 3, try b.lambda(body, body_type)),
            .arguments = &.{write},
            .state = &.{read},
        } });
    };
    const initial = try b.primitive(
        cell,
        .cell_new,
        &.{ try b.reference(b.parameter(inside, 0)), try b.constant(u64, 1) },
        0,
    );
    try b.define(inside, try b.bind(allocated, try b.pure(initial), control));
    const inside_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = integer,
        .regions = &.{r},
    } } });
    try b.define(
        entry,
        try b.term(.{ .with_region = .{
            .region = r,
            .body = try b.lambda(inside, inside_type),
        } }),
    );
    return b.module(entry, unit);
}
