// Copyright (c) 2026 Boundary contributors. MIT license.
//! Explicit pure call-by-name computations. Runtime closures use normal lowering.
const source = @import("../source.zig");
const Id = source.Id;
pub const demand = @import("hyper_need.zig");

/// A zero-argument pure computation. Captures are checked by normal admission.
pub fn delayed(b: *source.Builder, result: Id, captures: []const Id) source.Error!Id {
    return b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = result,
        .capture_bound = captures,
    } } });
}

/// Demand a delayed value, producing a source term rather than a host result.
pub fn force(b: *source.Builder, value: Id) source.Error!Id {
    return b.term(.{ .apply = .{ .computation = value, .arguments = &.{} } });
}

pub const Pair = struct {
    forward: Id,
    backward: Id,
    peer_forward: Id,
    peer_backward: Id,
    answer_forward: Id,
    answer_backward: Id,
};

pub fn pair(b: *source.Builder, a: Id, z: Id) source.Error!Pair {
    return pairWith(b, a, z, &.{});
}

/// A finite recursive interface group, not an unfolding of its endpoint types.
/// The bound permits captures; lowering retains only the actually captured values.
/// Reusable pure values cannot hide linear captures: ordinary fixed-point use
/// analysis checks these schemas and the actual generated environments.
pub fn pairWith(b: *source.Builder, a: Id, z: Id, captures: []const Id) source.Error!Pair {
    if (a >= b.schemas.items.len or z >= b.schemas.items.len) return error.InvalidReference;
    for (captures) |id| if (id >= b.schemas.items.len) return error.InvalidReference;
    const cached = try b.specialization(Pair, "boundary.hyper.pair/v1", .{ a, z, captures });
    if (cached.cached) |value| return value;
    const forward = try b.reserveSchema();
    const backward = try b.reserveSchema();
    const peer_forward = try b.reserveSchema();
    const peer_backward = try b.reserveSchema();
    const answer_forward = try b.reserveSchema();
    const answer_backward = try b.reserveSchema();
    const ids = [_]Id{
        forward,
        backward,
        peer_forward,
        peer_backward,
        answer_forward,
        answer_backward,
    };
    const bound = try b.allocator().alloc(Id, captures.len + ids.len + 2);
    @memcpy(bound[0..captures.len], captures);
    @memcpy(bound[captures.len..][0..ids.len], &ids);
    bound[bound.len - 2] = a;
    bound[bound.len - 1] = z;
    const results = [_]Id{ answer_forward, answer_backward, forward, backward, z, a };
    for (ids, results, 0..) |id, result, index| {
        const parameters: []const Id = switch (index) {
            0 => &.{peer_backward},
            1 => &.{peer_forward},
            else => &.{},
        };
        try b.defineSchema(id, .{ .internal = .{ .computation = .{
            .parameters = parameters,
            .result = result,
            .capture_bound = bound,
        } } });
    }
    return cached.finish(b, .{
        .forward = forward,
        .backward = backward,
        .peer_forward = peer_forward,
        .peer_backward = peer_backward,
        .answer_forward = answer_forward,
        .answer_backward = answer_backward,
    });
}

/// A staged body takes the complementary delayed participant and returns a
/// delayed answer. Horos checks the actual body against this callable schema.
pub fn make(b: *source.Builder, body: Id, interface: Id) source.Error!Id {
    return b.lambda(body, interface);
}

/// Construct a delayed invocation. Neither body nor peer is entered until force.
/// The result is a source term yielding Delayed<B>, preserving the normal staged
/// distinction between source terms and source values.
pub fn invoke(b: *source.Builder, participant: Id, peer: Id) source.Error!Id {
    if (participant >= b.values.items.len) return error.InvalidReference;
    const interface = b.values.items[@intCast(participant)].schema;
    if (interface >= b.schemas.items.len) return error.InvalidReference;
    const shape = b.schemas.items[@intCast(interface)];
    if (shape != .internal or shape.internal != .computation) return error.TypeMismatch;
    const answer = shape.internal.computation.result;
    if (answer >= b.schemas.items.len) return error.InvalidReference;
    const answer_shape = b.schemas.items[@intCast(answer)];
    if (answer_shape != .internal or answer_shape.internal != .computation or
        answer_shape.internal.computation.parameters.len != 0) return error.TypeMismatch;
    const thunk = try b.declare(&.{}, answer_shape.internal.computation.result, &.{}, &.{});
    const result = try b.variable(answer);
    const applied = try b.term(.{ .apply = .{
        .computation = participant,
        .arguments = &.{peer},
    } });
    try b.define(thunk, try b.bind(result, applied, try force(b, try b.reference(result))));
    return b.pure(try b.lambda(thunk, answer));
}

test "hyper recursive interfaces share finite schema declarations" {
    const std = @import("std");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const first = try pair(&b, integer, boolean);
    const count = b.schemas.items.len;
    for (0..100) |_| {
        const again = try pair(&b, integer, boolean);
        try std.testing.expectEqual(first, again);
        try std.testing.expectEqual(count, b.schemas.items.len);
    }
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(u64, 42)));
    var compiled = try source.lower(std.testing.allocator, b.module(entry, try b.scalar(void)));
    defer compiled.deinit();
}

test "hyper recursive wrapping cannot declare an exclusive capture reusable" {
    const std = @import("std");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const owned = try b.resource(integer);
    _ = try pairWith(&b, integer, integer, &.{owned});
    const entry = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(u64, 42)));
    try std.testing.expectError(
        error.InvalidOwnership,
        source.lower(std.testing.allocator, b.module(entry, try b.scalar(void))),
    );
}

pub const Ana = struct { function: Id, interface: Id };

/// Step.emit receives source values and a staged query builder. It may emit zero,
/// one, or arbitrarily many runtime queries; no host function enters the image.
/// State must be admitted by the interface's capture bound.
/// Each call emits a definition using the current Step configuration. Reuse the
/// returned Ana with start to share code; runtime queries call that same maker.
pub fn ana(b: *source.Builder, types: Pair, state: Id, comptime Step: type) source.Error!Ana {
    const maker = try b.declare(&.{state}, types.forward, &.{}, &.{});
    const body = try b.declare(&.{types.peer_backward}, types.answer_forward, &.{}, &.{});
    try b.define(body, try Step.emit(b, Query{
        .types = types,
        .maker = maker,
        .state = try b.reference(b.parameter(maker, 0)),
        .peer = try b.reference(b.parameter(body, 0)),
    }));
    try b.define(maker, try b.pure(try make(b, body, types.forward)));
    return .{ .function = maker, .interface = types.forward };
}

pub fn start(b: *source.Builder, definition: Ana, state: Id) source.Error!Id {
    return b.term(.{ .call = .{ .function = definition.function, .arguments = &.{state} } });
}

pub fn swap(types: Pair) Pair {
    return .{
        .forward = types.backward,
        .backward = types.forward,
        .peer_forward = types.peer_backward,
        .peer_backward = types.peer_forward,
        .answer_forward = types.answer_backward,
        .answer_backward = types.answer_forward,
    };
}

pub const Query = struct {
    types: Pair,
    maker: Id,
    state: Id,
    peer: Id,

    /// Return a delayed counterpart answer. Even looking up the counterpart is
    /// deferred, so an unused query cannot evaluate its peer or successor state.
    pub fn ask(self: Query, b: *source.Builder, next_state: Id) source.Error!Id {
        const answer_shape = b.schemas.items[@intCast(self.types.answer_backward)];
        const answer = answer_shape.internal.computation.result;
        const tail = try b.declare(&.{}, self.types.forward, &.{}, &.{});
        try b.define(tail, try b.term(.{ .call = .{
            .function = self.maker,
            .arguments = &.{next_state},
        } }));
        const thunk = try b.declare(&.{}, answer, &.{}, &.{});
        const peer = try b.variable(self.types.backward);
        const result = try b.variable(self.types.answer_backward);
        const invoked = try invoke(
            b,
            try b.reference(peer),
            try b.lambda(tail, self.types.peer_forward),
        );
        try b.define(
            thunk,
            try b.bind(
                peer,
                try force(b, self.peer),
                try b.bind(result, invoked, try force(b, try b.reference(result))),
            ),
        );
        return b.pure(try b.lambda(thunk, self.types.answer_backward));
    }
};

fn delayedResult(b: *source.Builder, schema: Id) source.Error!Id {
    if (schema >= b.schemas.items.len) return error.InvalidReference;
    const shape = b.schemas.items[@intCast(schema)];
    if (shape != .internal or shape.internal != .computation or
        shape.internal.computation.parameters.len != 0) return error.TypeMismatch;
    return shape.internal.computation.result;
}

/// Embed a source value without evaluating its expression before demand.
pub fn deferValue(b: *source.Builder, schema: Id, value: Id) source.Error!Id {
    const thunk = try b.declare(&.{}, try delayedResult(b, schema), &.{}, &.{});
    try b.define(thunk, try b.pure(value));
    return b.lambda(thunk, schema);
}

/// Constant hyperfunction; ignoring a pure peer does not force it.
pub fn base(b: *source.Builder, types: Pair, value: Id) source.Error!Id {
    const body = try b.declare(&.{types.peer_backward}, types.answer_forward, &.{}, &.{});
    try b.define(body, try b.pure(value));
    return make(b, body, types.forward);
}

/// transform is an ordinary checked source function Delayed<A> -> Delayed<B>.
/// It may ignore its argument. tail is Delayed<Hyper<A,B>>.
pub fn push(b: *source.Builder, types: Pair, transform: Id, tail: Id) source.Error!Id {
    const body = try b.declare(&.{types.peer_backward}, types.answer_forward, &.{}, &.{});
    const argument = try b.declare(&.{}, try delayedResult(b, types.answer_backward), &.{}, &.{});
    const peer = try b.variable(types.backward);
    const answer = try b.variable(types.answer_backward);
    const requested = try invoke(b, try b.reference(peer), tail);
    try b.define(
        argument,
        try b.bind(
            peer,
            try force(b, try b.reference(b.parameter(body, 0))),
            try b.bind(answer, requested, try force(b, try b.reference(answer))),
        ),
    );
    try b.define(body, try b.term(.{ .call = .{
        .function = transform,
        .arguments = &.{try b.lambda(argument, types.answer_backward)},
    } }));
    return make(b, body, types.forward);
}

/// Tie the recursive spine through finite code references. Calling the returned
/// construction never invokes transform or unfolds future participant instances.
pub fn lift(b: *source.Builder, types: Pair, transform: Id) source.Error!Id {
    const cache = try b.specialization(Id, "boundary.hyper.lift/v1", .{ types, transform });
    if (cache.cached) |function| return b.term(.{ .call = .{
        .function = function,
        .arguments = &.{},
    } });
    const maker = try b.declare(&.{}, types.forward, &.{}, &.{});
    const tail = try b.declare(&.{}, types.forward, &.{}, &.{});
    try b.define(tail, try b.term(.{ .call = .{ .function = maker, .arguments = &.{} } }));
    try b.define(
        maker,
        try b.pure(try push(b, types, transform, try b.lambda(tail, types.peer_forward))),
    );
    _ = try cache.finish(b, maker);
    return b.term(.{ .call = .{ .function = maker, .arguments = &.{} } });
}

/// Identity only exists at equal endpoint types. Its argument remains delayed.
pub fn identity(b: *source.Builder, types: Pair) source.Error!Id {
    const input = try delayedResult(b, types.answer_backward);
    const output = try delayedResult(b, types.answer_forward);
    if (input != output) return error.TypeMismatch;
    const cache = try b.specialization(Id, "boundary.hyper.identity/v1", .{types});
    const transform = if (cache.cached) |function| function else blk: {
        const function = try b.declare(&.{types.answer_backward}, types.answer_forward, &.{}, &.{});
        const thunk = try b.declare(&.{}, output, &.{}, &.{});
        try b.define(thunk, try force(b, try b.reference(b.parameter(function, 0))));
        try b.define(function, try b.pure(try b.lambda(thunk, types.answer_forward)));
        break :blk try cache.finish(b, function);
    };
    return lift(b, types, transform);
}

pub fn run(b: *source.Builder, types: Pair, participant: Id) source.Error!Id {
    const peer = try b.declare(&.{}, types.backward, &.{}, &.{});
    try b.define(peer, try identity(b, swap(types)));
    return invoke(b, participant, try b.lambda(peer, types.peer_backward));
}

pub fn project(b: *source.Builder, types: Pair, participant: Id, argument: Id) source.Error!Id {
    const peer = try b.declare(&.{}, types.backward, &.{}, &.{});
    try b.define(peer, try b.pure(try base(b, swap(types), argument)));
    return invoke(b, participant, try b.lambda(peer, types.peer_backward));
}

/// Shared monomorphic interfaces for a finite set of endpoint types. This lists
/// type pairs, never runtime states or interaction histories. Components use the
/// same declared group so composition's rotated reciprocal calls stay compatible.
pub const Group = struct {
    endpoints: []const Id,
    pairs: []const Pair,
    pub fn get(self: Group, from: usize, to: usize) source.Error!Pair {
        if (from >= self.endpoints.len or to >= self.endpoints.len) return error.InvalidReference;
        const offset = @import("std").math.mul(
            usize,
            from,
            self.endpoints.len,
        ) catch return error.InvalidReference;
        const index = @import("std").math.add(
            usize,
            offset,
            to,
        ) catch return error.InvalidReference;
        if (index >= self.pairs.len) return error.InvalidReference;
        return self.pairs[index];
    }
};

pub fn group(b: *source.Builder, endpoints: []const Id, captures: []const Id) source.Error!Group {
    const std = @import("std");
    if (endpoints.len == 0) return error.InvalidSchema;
    for (endpoints) |id| if (id >= b.schemas.items.len) return error.InvalidReference;
    for (captures) |id| if (id >= b.schemas.items.len) return error.InvalidReference;
    const cache = try b.specialization(Group, "boundary.hyper.group/v1", .{ endpoints, captures });
    if (cache.cached) |value| return value;
    const count = std.math.mul(usize, endpoints.len, endpoints.len) catch return error.Capacity;
    const doubled = std.math.mul(usize, count, 2) catch return error.Capacity;
    const nodes = std.math.add(usize, doubled, endpoints.len) catch return error.Capacity;
    if (nodes > @import("horos_data").component.max_catalog_entries) return error.Capacity;
    const with_endpoints = std.math.add(usize, nodes, endpoints.len) catch return error.Capacity;
    const bound_length = std.math.add(
        usize,
        with_endpoints,
        captures.len,
    ) catch return error.Capacity;
    const references = std.math.mul(usize, nodes, bound_length) catch return error.Capacity;
    if (references > @import("horos_data").component.max_catalog_entries) return error.Capacity;
    const ids = try b.allocator().alloc(Id, nodes);
    for (ids) |*id| id.* = try b.reserveSchema();
    const bound = try b.allocator().alloc(Id, bound_length);
    @memcpy(bound[0..nodes], ids);
    @memcpy(bound[nodes..][0..endpoints.len], endpoints);
    @memcpy(bound[nodes + endpoints.len ..], captures);
    const pairs = try b.allocator().alloc(Pair, count);
    for (endpoints, 0..) |_, from| for (endpoints, 0..) |_, to| {
        const index = from * endpoints.len + to;
        const reverse = to * endpoints.len + from;
        const hyper_id = ids[index];
        const peer = ids[count + index];
        try b.defineSchema(hyper_id, .{ .internal = .{ .computation = .{
            .parameters = &.{ids[count + reverse]},
            .result = ids[2 * count + to],
            .capture_bound = bound,
        } } });
        try b.defineSchema(peer, .{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = hyper_id,
            .capture_bound = bound,
        } } });
        pairs[index] = .{
            .forward = hyper_id,
            .backward = ids[reverse],
            .peer_forward = peer,
            .peer_backward = ids[count + reverse],
            .answer_forward = ids[2 * count + to],
            .answer_backward = ids[2 * count + from],
        };
    };
    for (
        endpoints,
        0..,
    ) |endpoint, index| try b.defineSchema(
        ids[2 * count + index],
        .{
            .internal = .{
                .computation = .{ .parameters = &.{}, .result = endpoint, .capture_bound = bound },
            },
        },
    );
    return cache.finish(b, .{ .endpoints = try b.allocator().dupe(Id, endpoints), .pairs = pairs });
}

/// compose(left: H(B,C), right: H(A,B)) -> H(A,C), with lazy reciprocal rotation.
pub fn compose(
    b: *source.Builder,
    interfaces: Group,
    a: usize,
    middle: usize,
    c: usize,
    left: Id,
    right: Id,
) source.Error!Id {
    const cache = try b.specialization(
        Id,
        "boundary.hyper.compose/v1",
        .{ interfaces, a, middle, c },
    );
    const maker = if (cache.cached) |function| function else blk: {
        const rotations = [_][3]usize{ .{ a, middle, c }, .{ c, a, middle }, .{ middle, c, a } };
        var makers: [3]Id = undefined;
        // Declare the finite cycle before defining any body. No recursive host expansion.
        for (rotations, &makers) |rotation, *function| {
            const ab = try interfaces.get(rotation[0], rotation[1]);
            const bc = try interfaces.get(rotation[1], rotation[2]);
            const ac = try interfaces.get(rotation[0], rotation[2]);
            function.* = try b.declare(&.{ bc.forward, ab.forward }, ac.forward, &.{}, &.{});
        }
        for (rotations, makers, 0..) |rotation, function, index|
            try composeBody(b, interfaces, rotation, function, makers[(index + 1) % 3]);
        break :blk try cache.finish(b, makers[0]);
    };
    return b.term(.{ .call = .{ .function = maker, .arguments = &.{ left, right } } });
}

fn composeBody(
    b: *source.Builder,
    interfaces: Group,
    rotation: [3]usize,
    maker: Id,
    rotated: Id,
) source.Error!void {
    const bc = try interfaces.get(rotation[1], rotation[2]);
    const ac = try interfaces.get(rotation[0], rotation[2]);
    const outer = try b.declare(&.{ac.peer_backward}, ac.answer_forward, &.{}, &.{});
    const inner = try b.declare(&.{}, bc.backward, &.{}, &.{});
    const peer = try b.variable(ac.backward);
    const combined = try b.term(.{ .call = .{ .function = rotated, .arguments = &.{
        try b.reference(b.parameter(maker, 1)), try b.reference(peer),
    } } });
    try b.define(
        inner,
        try b.bind(peer, try force(b, try b.reference(b.parameter(outer, 0))), combined),
    );
    try b.define(
        outer,
        try invoke(
            b,
            try b.reference(b.parameter(maker, 0)),
            try b.lambda(inner, bc.peer_backward),
        ),
    );
    try b.define(maker, try b.pure(try make(b, outer, ac.forward)));
}

/// Ordinary immutable product whose fields are individually delayed.
pub fn lazyProduct(b: *source.Builder, fields: []const Id) source.Error!Id {
    const schemas = try b.allocator().alloc(Id, fields.len);
    for (fields, schemas) |value, *schema| {
        if (value >= b.values.items.len) return error.InvalidReference;
        schema.* = b.values.items[@intCast(value)].schema;
        _ = try delayedResult(b, schema.*);
    }
    return b.primitive(try b.schema(.{ .product = schemas }), .product, fields, 0);
}

/// Inspecting this sum's tag does not force its selected payload.
pub fn lazySum(
    b: *source.Builder,
    alternatives: []const Id,
    tag: usize,
    payload: Id,
) source.Error!Id {
    if (tag >= alternatives.len) return error.TypeMismatch;
    for (alternatives) |schema| _ = try delayedResult(b, schema);
    return b.primitive(try b.schema(.{ .sum = alternatives }), .variant, &.{payload}, tag);
}

pub const Stream = struct { node: Id, cell: Id, element: Id, spine: Id };

/// Finite code can describe an unbounded stream. Both the element and successor
/// spine are pure delayed computations; observing a prefix need not demand either
/// an unused element or suffix. All captures retain ordinary ownership checking.
pub fn stream(b: *source.Builder, value: Id, captures: []const Id) source.Error!Stream {
    if (value >= b.schemas.items.len) return error.InvalidReference;
    for (captures) |id| if (id >= b.schemas.items.len) return error.InvalidReference;
    const cache = try b.specialization(Stream, "boundary.hyper.stream/v1", .{ value, captures });
    if (cache.cached) |definition| return definition;
    const node = try b.reserveSchema();
    const cell = try b.reserveSchema();
    const element = try b.reserveSchema();
    const spine = try b.reserveSchema();
    const bound = try b.allocator().alloc(Id, captures.len + 5);
    @memcpy(bound[0..captures.len], captures);
    @memcpy(bound[captures.len..], &[_]Id{ value, node, cell, element, spine });
    try b.defineSchema(node, .{ .sum = &.{ try b.scalar(void), cell } });
    try b.defineSchema(cell, .{ .product = &.{ element, spine } });
    try b.defineSchema(element, .{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = value,
        .capture_bound = bound,
    } } });
    try b.defineSchema(spine, .{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = node,
        .capture_bound = bound,
    } } });
    return cache.finish(b, .{ .node = node, .cell = cell, .element = element, .spine = spine });
}

pub fn emptyStream(b: *source.Builder, definition: Stream) source.Error!Id {
    return b.primitive(definition.node, .variant, &.{try b.constant(void, {})}, 0);
}
pub fn cons(b: *source.Builder, definition: Stream, head: Id, tail: Id) source.Error!Id {
    const cell = try b.primitive(definition.cell, .product, &.{ head, tail }, 0);
    return b.primitive(definition.node, .variant, &.{cell}, 1);
}

test "hyper group rejects invalid schemas and excessive graph expansion before reservation" {
    const std = @import("std");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const before = b.schemas.items.len;
    try std.testing.expectError(error.InvalidReference, group(&b, &.{before}, &.{}));
    try std.testing.expectError(error.InvalidReference, pairWith(&b, integer, before, &.{}));
    const repeated = @as([64]Id, @splat(integer));
    try std.testing.expectError(error.Capacity, group(&b, &repeated, &.{}));
    try std.testing.expectEqual(before, b.schemas.items.len);
}

test "hyper identity rejects distinct endpoint types" {
    const std = @import("std");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const interfaces = try pair(&b, try b.scalar(bool), try b.scalar(u64));
    try std.testing.expectError(error.TypeMismatch, identity(&b, interfaces));
}

test "ana emits each authored definition and start reuses its code" {
    const std = @import("std");
    const Step = struct {
        var value: u64 = 0;
        var calls: usize = 0;
        pub fn emit(b: *source.Builder, query: Query) source.Error!Id {
            calls += 1;
            return b.pure(try deferValue(
                b,
                query.types.answer_forward,
                try b.constant(u64, value),
            ));
        }
    };
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const types = try pair(&b, integer, integer);
    Step.calls = 0;
    Step.value = 19;
    const first = try ana(&b, types, integer, Step);
    Step.value = 23;
    const second = try ana(&b, types, integer, Step);
    try std.testing.expectEqual(@as(usize, 2), Step.calls);
    try std.testing.expect(first.function != second.function);
    const count = b.functions.items.len;
    for (0..100) |state| {
        _ = try start(&b, first, try b.constant(u64, state));
        _ = try start(&b, second, try b.constant(u64, state));
    }
    try std.testing.expectEqual(count, b.functions.items.len);
    try std.testing.expectEqual(@as(usize, 2), Step.calls);
}
