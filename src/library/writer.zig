//! Shape-preserving interface over the shared checked library implementation.
const option_contract = @import("../authoring/option_contract.zig");
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/writer.zig");
fn Op(comptime S: type) type {
    return a.OperationSignature(S, bridge.Unit, bridge.Empty);
}
pub fn Family(comptime S: type) type {
    return opaque {
        pub const family_shape = S;
        pub fn effect(self: *const @This()) *const a.Operation(Op(S)) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).effect());
        }
        pub fn capability(self: *const @This()) *const a.Schema(
            a.Internal(.{ .capability = Op(S) }),
        ) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).capability());
        }
    };
}
fn familyShape(comptime T: type) type {
    if (@typeInfo(T) != .pointer or
        @typeInfo(T).pointer.size != .one)
        @compileError("Horos Writer: expected canonical family");
    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "family_shape")) @compileError("Horos Writer: expected canonical family");
    const S = Child.family_shape;
    if (T != *const Family(S)) @compileError("Horos Writer: expected canonical family");
    return S;
}
pub fn family(
    c: *a.Context,
    identity: []const u8,
    message: anytype,
) a.Error!*const Family(bridge.schemaShape(@TypeOf(message))) {
    return @ptrCast(try runtime.family(bridge.context(c), identity, bridge.schema(message)));
}
pub fn Writer(comptime S: type, comptime R: type) type {
    const Sequence = bridge.sequence(S);
    const Cell = a.Internal(.{ .cell = Sequence });
    const Answer = native.Contract(.{ .product = native.Fields(
        &.{ "value", "log" },
        &.{ R, Sequence },
    ) });
    const H = a.HandlerShape(
        native.Fields(&.{"capability"}, &.{Op(S)}),
        R,
        Answer,
        native.Fields(&.{"log"}, &.{Cell}),
        bridge.Empty,
        .deep,
    );
    return struct {
        answer: *const a.Schema(Answer),
        cell: *const a.Schema(Cell),
        sequence: *const a.Schema(Sequence),
        handler: *const a.Handler(H),
        resumption: *const a.Schema(bridge.resumption(bridge.Unit, Answer)),
    };
}
pub fn interpret(
    c: *a.Context,
    writer: anytype,
    result: anytype,
    region: *const a.Region,
    options: anytype,
) a.Error!Writer(familyShape(@TypeOf(writer)), bridge.schemaShape(@TypeOf(result))) {
    comptime option_contract.required(
        "writer.interpret",
        @TypeOf(options),
        &.{ "captures", "residual" },
    );
    comptime option_contract.captureBounds("writer.interpret", @TypeOf(options.captures));
    const bounds = bridge.captures(options.captures);
    const effects = bridge.list(.operation, options.residual);
    const value = try runtime.interpret(
        bridge.context(c),
        @ptrCast(writer),
        bridge.schema(result),
        region,
        bounds.value(),
        effects.slice(),
    );
    return .{
        .answer = @ptrCast(value.answer),
        .cell = @ptrCast(value.cell),
        .sequence = @ptrCast(value.sequence),
        .handler = @ptrCast(value.handler),
        .resumption = @ptrCast(value.resumption),
    };
}
