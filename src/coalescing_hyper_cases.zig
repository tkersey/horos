// Copyright (c) 2026 Boundary contributors. MIT license.
//! Fresh ordinary hyper helper emissions, without pre-emission specialization.
const source = @import("source.zig");
const hyper = @import("library/hyper.zig");
const Id = source.Id;
pub const Kind = enum { duplicate, configured, lazy };

fn Forward(comptime adjustment: u64, comptime lazy: bool) type {
    return struct {
        pub fn emit(b: *source.Builder, q: hyper.Query) !Id {
            const integer = try b.scalar(u64);
            const thunk = try b.declare(&.{}, integer, &.{}, &.{});
            const answer = try b.variable(integer);
            const delayed = try b.variable(q.types.answer_backward);
            // Even the lazy case emits a real query; only demand may enter its peer.
            const ask = try q.ask(b, q.state);
            const result = if (lazy) q.state else try add(b, q.state, try b.reference(answer));
            const final = if (adjustment == 0) result else try add(
                b,
                result,
                try b.constant(u64, adjustment),
            );
            const done = try b.pure(final);
            const body = if (lazy) done else try b.bind(
                answer,
                try hyper.force(b, try b.reference(delayed)),
                done,
            );
            try b.define(thunk, try b.bind(delayed, ask, body));
            return b.pure(try b.lambda(thunk, q.types.answer_forward));
        }
    };
}

const Peer = struct {
    pub fn emit(b: *source.Builder, q: hyper.Query) !Id {
        return b.pure(try hyper.deferValue(b, q.types.answer_forward, q.state));
    }
};

pub fn build(b: *source.Builder, kind: Kind) !source.Module {
    const integer = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const types = try hyper.pairWith(b, integer, integer, &.{integer});
    const first = if (kind == .lazy)
        try hyper.ana(b, types, integer, Forward(0, true))
    else
        try hyper.ana(b, types, integer, Forward(0, false));
    const second = switch (kind) {
        .duplicate => try hyper.ana(b, types, integer, Forward(0, false)),
        .configured => try hyper.ana(b, types, integer, Forward(1, false)),
        .lazy => try hyper.ana(b, types, integer, Forward(0, true)),
    };
    if (first.function == second.function) return error.ExpectedIndependentEmission;
    const main = try b.declare(&.{ integer, integer }, pair, &.{}, &.{});
    const left = try b.variable(integer);
    const right = try b.variable(integer);
    const peer_function = try b.declare(&.{}, types.backward, &.{}, &.{});
    if (kind == .lazy) {
        try b.define(peer_function, try b.term(.{ .call = .{
            .function = peer_function,
            .arguments = &.{},
        } }));
    } else {
        const peer = try hyper.ana(b, hyper.swap(types), integer, Peer);
        try b.define(peer_function, try hyper.start(b, peer, try b.constant(u64, 10)));
    }
    const delayed_peer = try b.lambda(peer_function, types.peer_backward);
    const result = try b.pure(try b.primitive(
        pair,
        .product,
        &.{ try b.reference(left), try b.reference(right) },
        0,
    ));
    const second_call = try observe(
        b,
        types,
        second,
        try b.reference(b.parameter(main, 1)),
        delayed_peer,
    );
    const first_call = try observe(
        b,
        types,
        first,
        try b.reference(b.parameter(main, 0)),
        delayed_peer,
    );
    try b.define(main, try b.bind(left, first_call, try b.bind(right, second_call, result)));
    return b.module(main, try b.scalar(void));
}

fn observe(b: *source.Builder, types: hyper.Pair, definition: hyper.Ana, state: Id, peer: Id) !Id {
    const participant = try b.variable(types.forward);
    const result = try b.variable(types.answer_forward);
    const invoke = try hyper.invoke(b, try b.reference(participant), peer);
    return b.bind(
        participant,
        try hyper.start(b, definition, state),
        try b.bind(result, invoke, try hyper.force(b, try b.reference(result))),
    );
}

fn add(b: *source.Builder, left: Id, right: Id) !Id {
    return b.value(.{ .schema = try b.scalar(u64), .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ left, right },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}
