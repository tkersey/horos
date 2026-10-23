// Copyright (c) 2026 Boundary contributors. MIT license.
//! Fresh ordinary hyper helper emissions, without pre-emission specialization.
const source = @import("source.zig");
const a = @import("authoring.zig");
const hyper = @import("library/hyper.zig");
const Integer = a.Shape(u64);
const Types = hyper.Pair(Integer, Integer);
const Definition = hyper.Ana(Integer, Integer, Integer);
const PeerValue = a.Value(hyper.Delayed(hyper.Hyper(Integer, Integer)));
pub const Kind = enum { duplicate, configured, lazy };

const Forward = struct {
    adjustment: u64,
    lazy: bool,
    captured: *const a.Value(Integer),
    state_delay: *const a.Schema(hyper.Delayed(Integer)),
    emissions: *usize,

    pub fn emit(
        self: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(Integer)) {
        self.emissions.* += 1;
        const c = try body.context();
        const function = try c.functionFor("coalescing answer", query.types().answerForward());
        const nested = try body.closureBody(function);
        const successor = try hyper.deferValue(nested, self.state_delay, query.state());
        const answer = try query.ask(nested, successor);
        const result = if (self.lazy) query.state() else try nested.checkedAdd(
            query.state(),
            try hyper.force(nested, answer),
            try c.literalFailure(void, {}),
        );
        const final = if (self.adjustment == 0) result else try nested.checkedAdd(
            result,
            self.captured,
            try c.literalFailure(void, {}),
        );
        try c.define(function, try nested.ret(final));
        return body.ret(try body.lambda(function, query.types().answerForward()));
    }
};

const Peer = struct {
    pub fn emit(
        _: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(Integer)) {
        return body.ret(try hyper.deferValue(body, query.types().answerForward(), query.state()));
    }
};

pub fn build(raw: *source.Builder, kind: Kind) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const pair = try c.record(.{ .left = integer, .right = integer });
    const state_delay = try hyper.delayed(c, integer, .{ .captures = .{integer} });
    const types = try hyper.pair(c, integer, integer, .{ .captures = .{ integer, state_delay } });
    const entry = try c.function("entry", .{ .left = integer, .right = integer }, pair, .{});
    const body = try c.body(entry);
    var emissions: usize = 0;
    const first = try hyper.ana(body, types, integer, Forward{
        .adjustment = 0,
        .lazy = kind == .lazy,
        .captured = try body.constant(u64, 0),
        .state_delay = state_delay,
        .emissions = &emissions,
    });
    const adjustment: u64 = if (kind == .configured) 1 else 0;
    const second = try hyper.ana(body, types, integer, Forward{
        .adjustment = adjustment,
        .lazy = kind == .lazy,
        .captured = try body.constant(u64, adjustment),
        .state_delay = state_delay,
        .emissions = &emissions,
    });
    if (first == second or emissions != 2) return error.ExpectedIndependentEmission;
    const peer = try delayedPeer(body, types, integer, kind);
    const left = try observe(body, first, try body.parameter("left"), peer);
    const right = try observe(body, second, try body.parameter("right"), peer);
    if (emissions != 2) return error.UnexpectedStepReemission;
    try c.define(entry, try body.ret(try body.product(pair, .{ .left = left, .right = right })));
    return c.module(entry, try c.schema(void));
}

fn delayedPeer(
    body: anytype,
    types: *const Types,
    integer: *const a.Schema(Integer),
    kind: Kind,
) a.Error!*const PeerValue {
    const c = try body.context();
    const function = try c.functionFor("coalescing peer", types.peerBackward());
    const nested = try body.closureBody(function);
    const result = if (kind == .lazy)
        try nested.call(function, .{})
    else blk: {
        const definition = try hyper.ana(nested, types.swap(), integer, Peer{});
        break :blk try hyper.start(nested, definition, try nested.constant(u64, 10));
    };
    try c.define(function, try nested.ret(result));
    return body.lambda(function, types.peerBackward());
}

fn observe(
    body: anytype,
    definition: *const Definition,
    state: *const a.Value(Integer),
    peer: *const PeerValue,
) a.Error!*const a.Value(Integer) {
    const participant = try hyper.start(body, definition, state);
    return hyper.force(body, try hyper.invoke(body, participant, peer));
}
