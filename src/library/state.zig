const option_contract = @import("../authoring/option_contract.zig");
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/state.zig");
pub const Answer = runtime.Answer;
fn Get(comptime S: type) type {
    return a.OperationSignature(bridge.Unit, S, bridge.Empty);
}
fn Put(comptime S: type) type {
    return a.OperationSignature(S, bridge.Unit, bridge.Empty);
}
pub fn Family(comptime S: type) type {
    return opaque {
        pub const family_shape = S;
        pub fn get(self: *const @This()) *const a.Operation(Get(S)) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).get());
        }
        pub fn put(self: *const @This()) *const a.Operation(Put(S)) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).put());
        }
        pub fn getCapability(self: *const @This()) *const a.Schema(
            a.Internal(.{ .capability = Get(S) }),
        ) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).getCapability());
        }
        pub fn putCapability(self: *const @This()) *const a.Schema(
            a.Internal(.{ .capability = Put(S) }),
        ) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).putCapability());
        }
    };
}
fn familyShape(comptime T: type) type {
    if (@typeInfo(T) != .pointer or
        @typeInfo(T).pointer.size != .one)
        @compileError("Horos State: expected canonical family");
    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "family_shape")) @compileError("Horos State: expected canonical family");
    const S = Child.family_shape;
    if (T != *const Family(S)) @compileError("Horos State: expected canonical family");
    return S;
}
fn answerShape(comptime S: type, comptime R: type, comptime policy: Answer) type {
    return switch (policy) {
        .value => R,
        .with_state => native.Contract(.{ .product = native.Fields(
            &.{ "value", "state" },
            &.{ R, S },
        ) }),
        .optional => bridge.optional(R),
    };
}
pub fn Interpretation(comptime S: type, comptime R: type, comptime policy: Answer) type {
    const Result = answerShape(S, R, policy);
    const Cell = a.Internal(.{ .cell = S });
    const H = a.HandlerShape(
        native.Fields(&.{ "get", "put" }, &.{ Get(S), Put(S) }),
        R,
        Result,
        native.Fields(&.{"state"}, &.{Cell}),
        bridge.Empty,
        .deep,
    );
    return struct {
        handler: *const a.Handler(H),
        answer: *const a.Schema(Result),
        cell: *const a.Schema(Cell),
    };
}
pub fn Selected(comptime S: type, comptime R: type) type {
    return union(Answer) {
        value: Interpretation(S, R, .value),
        with_state: Interpretation(S, R, .with_state),
        optional: Interpretation(S, R, .optional),
    };
}
pub fn family(
    c: *a.Context,
    identity: []const u8,
    element: anytype,
) a.Error!*const Family(bridge.schemaShape(@TypeOf(element))) {
    return @ptrCast(try runtime.family(bridge.context(c), identity, bridge.schema(element)));
}
fn InterpretationResult(comptime S: type, comptime R: type, comptime Options: type) type {
    option_contract.required(
        "state.interpret",
        Options,
        &.{ "captures", "residual", "answer" },
    );
    option_contract.captureBounds("state.interpret", @FieldType(Options, "captures"));
    if (option_contract.knownEnum(Options, "answer", Answer)) |policy|
        return Interpretation(S, R, policy);
    return Selected(S, R);
}
pub fn interpret(
    c: *a.Context,
    state: anytype,
    result: anytype,
    region: *const a.Region,
    options: anytype,
) a.Error!InterpretationResult(
    familyShape(@TypeOf(state)),
    bridge.schemaShape(@TypeOf(result)),
    @TypeOf(options),
) {
    const bounds = bridge.captures(options.captures);
    const effects = bridge.list(.operation, options.residual);
    const raw = try runtime.interpret(
        bridge.context(c),
        @ptrCast(state),
        bridge.schema(result),
        region,
        bounds.value(),
        effects.slice(),
        options.answer,
    );
    if (comptime option_contract.knownEnum(@TypeOf(options), "answer", Answer) != null)
        return .{
            .handler = @ptrCast(raw.handler),
            .answer = @ptrCast(raw.answer),
            .cell = @ptrCast(raw.cell),
        };
    return switch (options.answer) {
        inline else => |policy| @unionInit(
            Selected(familyShape(@TypeOf(state)), bridge.schemaShape(@TypeOf(result))),
            @tagName(policy),
            .{
                .handler = @ptrCast(raw.handler),
                .answer = @ptrCast(raw.answer),
                .cell = @ptrCast(raw.cell),
            },
        ),
    };
}
