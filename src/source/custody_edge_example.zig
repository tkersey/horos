// Copyright (c) 2026 Boundary contributors. MIT license.
//! Owners survive completed successor interfaces, including unnamed values.
const source = @import("../source.zig");
const p = @import("horos_data").program;
const Error = source.Error;
pub const count = 12;
const Kind = enum {
    binding,
    branch,
    call,
    apply,
    temporary_binding,
    temporary_branch,
    temporary_call,
    temporary_apply,
    returned_owner,
    match_payload,
    unpack_payload,
    unpack_operand,
};

pub fn scenario(b: *source.Builder, index: usize, fail: bool) Error!p.Id {
    const kind: Kind = @fromBackingInt(@intCast(index));
    const integer = try b.scalar(u64);
    const queue = try b.schema(.{ .seq = try b.resource(integer) });
    const parameter = switch (kind) {
        .binding, .branch, .call, .apply, .unpack_operand => true,
        else => false,
    };
    const helper = try b.declare(if (parameter) &.{queue} else &.{}, integer, &.{}, &.{});
    const empty = try b.primitive(queue, .sequence, &.{}, 0);
    const items = if (parameter) try b.reference(b.parameter(helper, 0)) else empty;
    const length = try b.primitive(integer, .sequence_length, &.{items}, 0);
    const value = try expression(b, kind, integer, queue, empty, length);
    const terminal = if (fail)
        try b.term(.{ .yield_then = try b.term(.{ .fail = try b.constant(u64, 8) }) })
    else
        try b.pure(try b.constant(u64, 7));
    try b.define(helper, try b.bind(try b.variable(integer), value, terminal));
    if (!parameter) return helper;
    const caller = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(caller, try b.term(.{ .call = .{ .function = helper, .arguments = &.{empty} } }));
    return caller;
}

fn expression(
    b: *source.Builder,
    kind: Kind,
    integer: p.Id,
    queue: p.Id,
    empty: p.Id,
    length: p.Id,
) Error!p.Id {
    const ordinary = try b.pure(try b.constant(u64, 3));
    switch (kind) {
        .binding, .temporary_binding => return b.pure(length),
        .branch, .temporary_branch => return b.term(.{ .conditional = .{
            .condition = try b.primitive(
                try b.scalar(bool),
                .equal,
                &.{ length, try b.constant(u64, 0) },
                0,
            ),
            .when_true = try b.pure(try b.constant(u64, 1)),
            .when_false = try b.pure(try b.constant(u64, 2)),
        } }),
        .call, .temporary_call, .apply, .temporary_apply => {
            const identity = try b.declare(&.{integer}, integer, &.{}, &.{});
            try b.define(identity, try b.pure(try b.reference(b.parameter(identity, 0))));
            if (kind == .call or kind == .temporary_call)
                return b.term(.{ .call = .{ .function = identity, .arguments = &.{length} } });
            const signature = try b.schema(.{ .internal = .{ .computation = .{
                .parameters = &.{integer},
                .result = integer,
                .effects = &.{},
            } } });
            return b.term(.{ .apply = .{
                .computation = try b.lambda(identity, signature),
                .arguments = &.{length},
            } });
        },
        .returned_owner => {
            const factory = try b.declare(&.{}, queue, &.{}, &.{});
            try b.define(factory, try b.pure(empty));
            return b.bind(
                try b.variable(queue),
                try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } }),
                ordinary,
            );
        },
        .match_payload => {
            const unit = try b.scalar(void);
            const sum = try b.schema(.{ .sum = &.{ unit, queue } });
            return b.term(.{ .match_sum = .{
                .value = try b.primitive(sum, .variant, &.{empty}, 1),
                .cases = &.{
                    .{ .variable = try b.variable(unit), .body = ordinary },
                    .{ .variable = try b.variable(queue), .body = ordinary },
                },
            } });
        },
        .unpack_payload, .unpack_operand => {
            const schema = if (kind == .unpack_payload) queue else integer;
            const product = try b.schema(.{ .product = &.{schema} });
            return b.term(.{ .unpack_product = .{
                .value = try b.primitive(
                    product,
                    .product,
                    &.{if (kind == .unpack_payload) empty else length},
                    0,
                ),
                .variables = &.{try b.variable(schema)},
                .body = ordinary,
            } });
        },
    }
}
