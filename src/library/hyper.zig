const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/hyper.zig");
const option_contract = @import("../authoring/option_contract.zig");
pub const Group = @import("hyper_group.zig").Group;
pub const group = @import("hyper_group.zig").group;
pub const compose = @import("hyper_group.zig").compose;
pub const Stream = @import("hyper_data.zig").Stream;
pub const StreamNode = @import("hyper_data.zig").StreamNode;
pub const StreamCell = @import("hyper_data.zig").StreamCell;
pub const stream = @import("hyper_data.zig").stream;
pub const emptyStream = @import("hyper_data.zig").emptyStream;
pub const cons = @import("hyper_data.zig").cons;
pub const lazyProduct = @import("hyper_data.zig").lazyProduct;
pub const lazySum = @import("hyper_data.zig").lazySum;

pub const ir = @import("hyper_group.zig").interop;
pub const demand = @import("hyper_need.zig").API(QueryAccess);

pub fn Delayed(comptime R: type) type {
    return a.Internal(.{ .callable = a.Signature(bridge.Empty, R) });
}

pub fn Hyper(comptime A: type, comptime B: type) type {
    return struct {
        pub const internal: a.InternalInfo = .{ .callable = a.Signature(
            native.Fields(&.{"peer"}, &.{Delayed(Hyper(B, A))}),
            Delayed(B),
        ) };
    };
}

pub fn Pair(comptime A: type, comptime B: type) type {
    return opaque {
        pub const Input = A;
        pub const Output = B;
        fn raw(self: *const @This()) *const runtime.Pair {
            return @ptrCast(self);
        }
        pub fn input(self: *const @This()) *const a.Schema(A) {
            return @ptrCast(self.raw().input());
        }
        pub fn output(self: *const @This()) *const a.Schema(B) {
            return @ptrCast(self.raw().output());
        }
        pub fn forward(self: *const @This()) *const a.Schema(Hyper(A, B)) {
            return @ptrCast(self.raw().forward());
        }
        pub fn backward(self: *const @This()) *const a.Schema(Hyper(B, A)) {
            return @ptrCast(self.raw().backward());
        }
        pub fn peerForward(self: *const @This()) *const a.Schema(Delayed(Hyper(A, B))) {
            return @ptrCast(self.raw().peerForward());
        }
        pub fn peerBackward(self: *const @This()) *const a.Schema(Delayed(Hyper(B, A))) {
            return @ptrCast(self.raw().peerBackward());
        }
        pub fn answerForward(self: *const @This()) *const a.Schema(Delayed(B)) {
            return @ptrCast(self.raw().answerForward());
        }
        pub fn answerBackward(self: *const @This()) *const a.Schema(Delayed(A)) {
            return @ptrCast(self.raw().answerBackward());
        }
        pub fn swap(self: *const @This()) *const Pair(B, A) {
            return @ptrCast(self.raw().swap());
        }
    };
}

fn pairType(comptime T: type) type {
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
        @compileError("Horos hyper: expected a canonical pair");
    const Child = @typeInfo(T).pointer.child;
    if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "Input") or
        !@hasDecl(Child, "Output")) @compileError("Horos hyper: expected a canonical pair");
    if (T != *const Pair(Child.Input, Child.Output))
        @compileError("Horos hyper: expected a canonical pair");
    return Child;
}

pub fn pair(
    c: *a.Context,
    input: anytype,
    output: anytype,
    options: anytype,
) a.Error!*const Pair(bridge.schemaShape(@TypeOf(input)), bridge.schemaShape(@TypeOf(output))) {
    comptime option_contract.check("hyper.pair", @TypeOf(options), &.{"captures"});
    const captures = bridge.list(.schema, bridge.option(options, "captures", .{}));
    return @ptrCast(try runtime.pair(
        bridge.context(c),
        bridge.schema(input),
        bridge.schema(output),
        captures.slice(),
    ));
}

pub fn delayed(
    c: *a.Context,
    result: anytype,
    options: anytype,
) a.Error!*const a.Schema(Delayed(bridge.schemaShape(@TypeOf(result)))) {
    comptime option_contract.check("hyper.delayed", @TypeOf(options), &.{"captures"});
    return c.callable(.{}, result, .{}, .{
        .use = .reusable,
        .captures = bridge.option(options, "captures", .{}),
    });
}

fn delayedResult(comptime S: type) type {
    if (S == a.Dynamic) return a.Dynamic;
    if (!@hasDecl(S, "internal") or S.internal != .callable)
        @compileError("Horos hyper: expected a delayed shape");
    const Sig = S.internal.callable;
    if (Sig == a.Dynamic) return a.Dynamic;
    if (Sig.parameters != a.Dynamic and @typeInfo(Sig.parameters).@"struct".field_types.len != 0)
        @compileError("Horos hyper: expected a delayed shape");
    return Sig.result;
}

pub fn force(
    body: anytype,
    value: anytype,
) a.Error!*const a.Value(delayedResult(a.ShapeOf(@TypeOf(value)))) {
    _ = try body.schemaOf(value);
    return @ptrCast(try runtime.force(bridge.body(body), @ptrCast(value)));
}

pub fn deferValue(
    body: anytype,
    schema: anytype,
    value: anytype,
) a.Error!*const a.Value(bridge.schemaShape(@TypeOf(schema))) {
    _ = comptime delayedResult(bridge.schemaShape(@TypeOf(schema)));
    const c = try body.context();
    try runtime.pureDelay(bridge.context(c), bridge.schema(schema));
    const function = try c.functionFor("hyper.defer", schema);
    const nested = try body.closureBody(function);
    try c.define(function, try nested.ret(value));
    return body.lambda(function, schema);
}

pub fn make(
    body: anytype,
    types: anytype,
    function: anytype,
) a.Error!*const a.Value(Hyper(pairType(@TypeOf(types)).Input, pairType(@TypeOf(types)).Output)) {
    return body.lambda(function, types.forward());
}

pub fn base(
    body: anytype,
    types: anytype,
    value: anytype,
) a.Error!*const a.Value(Hyper(pairType(@TypeOf(types)).Input, pairType(@TypeOf(types)).Output)) {
    const c = try body.context();
    const function = try c.functionFor("hyper.base", types.forward());
    const nested = try body.closureBody(function);
    try c.define(function, try nested.ret(value));
    return make(body, types, function);
}

pub fn invoke(
    body: anytype,
    participant: anytype,
    peer: anytype,
) @TypeOf(@as(*a.Body(a.Dynamic), undefined).apply(participant, .{ .peer = peer })) {
    comptime a.interop.requireCompatibleShapes(
        Hyper(participantInput(@TypeOf(participant)), participantAnswer(@TypeOf(participant))),
        a.ShapeOf(@TypeOf(participant)),
        "hyper.invoke participant",
    );
    const interface = try body.schemaOf(participant);
    const reciprocal = try a.interop.refineValue(body, peer, try interface.fieldSchema("peer"));
    return @ptrCast(try runtime.invoke(
        bridge.body(body),
        @ptrCast(participant),
        @ptrCast(reciprocal),
    ));
}

pub fn push(
    body: anytype,
    types: anytype,
    transform: anytype,
    tail: anytype,
) a.Error!*const a.Value(Hyper(pairType(@TypeOf(types)).Input, pairType(@TypeOf(types)).Output)) {
    const c = try body.context();
    const function = try c.functionFor("hyper.push", types.forward());
    const nested = try body.closureBody(function);
    const argument_function = try c.functionFor("hyper.argument", types.answerBackward());
    const argument_body = try nested.closureBody(argument_function);
    const peer = try force(argument_body, try nested.parameter("peer"));
    const answer = try invoke(argument_body, peer, tail);
    try c.define(argument_function, try argument_body.ret(try force(argument_body, answer)));
    const argument = try nested.lambda(argument_function, types.answerBackward());
    try c.define(function, try nested.ret(try nested.call(transform, .{ .argument = argument })));
    return make(body, types, function);
}

pub fn lift(
    body: anytype,
    types: anytype,
    transform: anytype,
) a.Error!*const a.Value(Hyper(pairType(@TypeOf(types)).Input, pairType(@TypeOf(types)).Output)) {
    const c = try body.context();
    const maker = try c.function("hyper.lift", .{}, types.forward(), .{});
    const maker_body = try body.closureBody(maker);
    const tail = try c.functionFor("hyper.lift.tail", types.peerForward());
    const tail_body = try maker_body.closureBody(tail);
    try c.define(tail, try tail_body.ret(try tail_body.call(maker, .{})));
    const delayed_tail = try maker_body.lambda(tail, types.peerForward());
    try c.define(maker, try maker_body.ret(try push(maker_body, types, transform, delayed_tail)));
    return body.call(maker, .{});
}

pub fn identity(
    body: anytype,
    types: anytype,
) a.Error!*const a.Value(Hyper(pairType(@TypeOf(types)).Input, pairType(@TypeOf(types)).Output)) {
    const c = try body.context();
    const transform = try c.function(
        "hyper.identity",
        .{ .argument = types.answerBackward() },
        types.answerForward(),
        .{},
    );
    const nested = try body.closureBody(transform);
    const thunk = try c.functionFor("hyper.identity.answer", types.answerForward());
    const thunk_body = try nested.closureBody(thunk);
    const argument = try force(thunk_body, try nested.parameter("argument"));
    try c.define(thunk, try thunk_body.ret(argument));
    try c.define(transform, try nested.ret(try nested.lambda(thunk, types.answerForward())));
    return lift(body, types, transform);
}

fn participantAnswer(comptime T: type) type {
    const S = a.ShapeOf(T);
    if (S == a.Dynamic) return a.Dynamic;
    if (!@hasDecl(S, "internal") or S.internal != .callable)
        @compileError("Horos hyper: expected a participant shape");
    if (S.internal.callable == a.Dynamic) return a.Dynamic;
    return delayedResult(S.internal.callable.result);
}

fn participantInput(comptime T: type) type {
    const Schema = a.Schema(a.ShapeOf(T));
    const Peer = @typeInfo(@TypeOf(@as(*const Schema, undefined).fieldSchema("peer")))
        .error_union.payload;
    return participantAnswer(*const a.Value(delayedResult(a.ShapeOf(Peer))));
}

fn observationAnswer(comptime V: type) type {
    return Delayed(participantAnswer(V));
}

pub fn run(
    body: anytype,
    types: anytype,
    participant: anytype,
) a.Error!*const a.Value(observationAnswer(@TypeOf(participant))) {
    const c = try body.context();
    const interface = try body.schemaOf(participant);
    const reciprocal = try (try interface.fieldSchema("peer")).requiredResultSchema();
    const input = try reciprocal.requiredResultSchema();
    const output = try interface.requiredResultSchema();
    _ = try a.interop.refineSchema(
        c,
        try input.requiredResultSchema(),
        try output.requiredResultSchema(),
    );
    const peer = try c.functionFor("hyper.run.peer", types.peerBackward());
    const nested = try body.closureBody(peer);
    try c.define(peer, try nested.ret(try identity(nested, types.swap())));
    return @ptrCast(try invoke(body, participant, try body.lambda(peer, types.peerBackward())));
}

pub fn project(
    body: anytype,
    types: anytype,
    participant: anytype,
    argument: anytype,
) a.Error!*const a.Value(observationAnswer(@TypeOf(participant))) {
    const c = try body.context();
    const interface = try body.schemaOf(participant);
    const reciprocal = try (try interface.fieldSchema("peer")).requiredResultSchema();
    _ = try a.interop.refineSchema(
        c,
        try body.schemaOf(argument),
        try reciprocal.requiredResultSchema(),
    );
    const peer = try c.functionFor("hyper.project.peer", types.peerBackward());
    const nested = try body.closureBody(peer);
    try c.define(peer, try nested.ret(try base(nested, types.swap(), argument)));
    return @ptrCast(try invoke(body, participant, try body.lambda(peer, types.peerBackward())));
}

fn AnaData(comptime S: type, comptime A: type, comptime B: type) type {
    return struct {
        types: *const Pair(A, B),
        state: *const a.Schema(S),
        maker: *const a.Function(a.Signature(native.Fields(&.{"state"}, &.{S}), Hyper(A, B))),
    };
}

pub fn Ana(comptime S: type, comptime A: type, comptime B: type) type {
    return opaque {
        pub const State = S;
        pub const Input = A;
        pub const Output = B;
        fn data(self: *const @This()) *const AnaData(S, A, B) {
            return @ptrCast(@alignCast(self));
        }
        pub fn stateSchema(self: *const @This()) *const a.Schema(S) {
            return self.data().state;
        }
        pub fn types(self: *const @This()) *const Pair(A, B) {
            return self.data().types;
        }
    };
}

fn anaType(comptime T: type) type {
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
        @compileError("Horos hyper: expected a canonical ana definition");
    const Child = @typeInfo(T).pointer.child;
    if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "State") or
        !@hasDecl(Child, "Input") or !@hasDecl(Child, "Output"))
        @compileError("Horos hyper: expected a canonical ana definition");
    if (T != *const Ana(Child.State, Child.Input, Child.Output))
        @compileError("Horos hyper: expected a canonical ana definition");
    return Child;
}

fn QueryData(comptime S: type, comptime A: type, comptime B: type) type {
    return struct {
        definition: *const Ana(S, A, B),
        state: *const a.Value(S),
        peer: *const a.Value(Delayed(Hyper(B, A))),
    };
}

pub fn Query(comptime S: type, comptime A: type, comptime B: type) type {
    return opaque {
        pub const State = S;
        pub const Input = A;
        pub const Output = B;
        fn data(self: *const @This()) *const QueryData(S, A, B) {
            return @ptrCast(@alignCast(self));
        }
        pub fn state(self: *const @This()) *const a.Value(S) {
            return self.data().state;
        }
        pub fn types(self: *const @This()) *const Pair(A, B) {
            return self.data().definition.types();
        }
        pub fn ask(
            self: *const @This(),
            body: anytype,
            next_state: anytype,
        ) a.Error!*const a.Value(Delayed(A)) {
            const c = try body.context();
            const types_value = self.types();
            _ = try body.schemaOf(self.data().peer);
            const function = try c.functionFor("hyper.query", types_value.answerBackward());
            const nested = try body.closureBody(function);
            const tail = try c.functionFor("hyper.successor", types_value.peerForward());
            const tail_body = try nested.closureBody(tail);
            const next = try force(tail_body, next_state);
            const successor = try start(tail_body, self.data().definition, next);
            try c.define(tail, try tail_body.ret(successor));
            const peer = try force(nested, self.data().peer);
            const delayed_tail = try nested.lambda(tail, types_value.peerForward());
            const answer = try invoke(nested, peer, delayed_tail);
            try c.define(function, try nested.ret(try force(nested, answer)));
            return body.lambda(function, types_value.answerBackward());
        }
    };
}

const QueryAccess = struct {
    pub fn Shape(comptime T: type) type {
        if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
            @compileError("Horos hyper: expected a canonical query");
        const Child = @typeInfo(T).pointer.child;
        if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "State") or
            !@hasDecl(Child, "Input") or !@hasDecl(Child, "Output"))
            @compileError("Horos hyper: expected a canonical query");
        if (T != *const Query(Child.State, Child.Input, Child.Output))
            @compileError("Horos hyper: expected a canonical query");
        return Child;
    }

    pub fn peer(
        query: anytype,
    ) *const a.Value(Delayed(Hyper(Shape(@TypeOf(query)).Output, Shape(@TypeOf(query)).Input))) {
        return query.data().peer;
    }
};

pub fn ana(body: anytype, types: anytype, state: anytype, emitter: anytype) a.Error!*const Ana(
    bridge.schemaShape(@TypeOf(state)),
    pairType(@TypeOf(types)).Input,
    pairType(@TypeOf(types)).Output,
) {
    const c = try body.context();
    const S = bridge.schemaShape(@TypeOf(state));
    const P = pairType(@TypeOf(types));
    const maker = try c.function("hyper.ana", .{ .state = state }, types.forward(), .{});
    const stored = try bridge.raw.interop.namedStorage(
        bridge.context(c),
        AnaData(S, P.Input, P.Output),
        .{ .types = types, .state = state, .maker = maker },
    );
    const definition: *const Ana(S, P.Input, P.Output) = @ptrCast(stored);
    const maker_body = try body.closureBody(maker);
    const function = try c.functionFor("hyper.step", types.forward());
    const step_body = try maker_body.closureBody(function);
    const query_data = try bridge.raw.interop.namedStorage(
        bridge.context(c),
        QueryData(S, P.Input, P.Output),
        .{
            .definition = definition,
            .state = try maker_body.parameter("state"),
            .peer = try step_body.parameter("peer"),
        },
    );
    const query: *const Query(S, P.Input, P.Output) = @ptrCast(query_data);
    try c.define(function, try emitter.emit(step_body, query));
    try c.define(maker, try maker_body.ret(try make(maker_body, types, function)));
    return definition;
}

pub fn start(
    body: anytype,
    definition: anytype,
    state: anytype,
) a.Error!*const a.Value(Hyper(
    anaType(@TypeOf(definition)).Input,
    anaType(@TypeOf(definition)).Output,
)) {
    return body.call(definition.data().maker, .{ .state = state });
}

test {
    _ = @import("hyper_tests.zig");
    _ = @import("hyper_partial_tests.zig");
    _ = @import("hyper_need_capture_tests.zig");
    _ = @import("hyper_group.zig");
}
