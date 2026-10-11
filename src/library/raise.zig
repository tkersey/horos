//! Shape-preserving interface over the shared checked library implementation.
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/raise.zig");
fn Op(comptime S: type) type {
    return a.OperationSignature(S, bridge.Unit, bridge.Empty);
}
pub fn Family(comptime S: type) type {
    return opaque {
        pub const family_shape = S;
        pub fn effect(self: *const @This()) *const a.Operation(Op(S)) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).effect());
        }
        pub fn capability(self: *const @This()) *const a.Schema(a.Internal(.{ .capability = Op(S) })) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).capability());
        }
    };
}
fn familyShape(comptime T: type) type {
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one) @compileError("Horos Raise: expected canonical family");
    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "family_shape")) @compileError("Horos Raise: expected canonical family");
    const S = Child.family_shape;
    if (T != *const Family(S)) @compileError("Horos Raise: expected canonical family");
    return S;
}
pub fn family(c: *a.Context, identity: []const u8, failure: anytype) a.Error!*const Family(bridge.schemaShape(@TypeOf(failure))) {
    return @ptrCast(try runtime.family(bridge.context(c), identity, bridge.schema(failure)));
}
pub fn Raise(comptime S: type, comptime R: type) type {
    const Answer = native.Contract(.{ .sum = native.Fields(&.{ "failure", "value" }, &.{ S, R }) });
    const H = a.HandlerShape(native.Fields(&.{"capability"}, &.{Op(S)}), R, Answer, bridge.Empty, bridge.Empty, .deep);
    return struct { answer: *const a.Schema(Answer), resumption: *const a.Schema(bridge.resumption(bridge.Unit, Answer)), handler: *const a.Handler(H) };
}
pub fn catching(c: *a.Context, raised: anytype, result: anytype, capture_bounds: anytype, residual: anytype, regions: anytype) a.Error!Raise(familyShape(@TypeOf(raised)), bridge.schemaShape(@TypeOf(result))) {
    const bounds = bridge.captures(capture_bounds);
    const effects = bridge.list(.operation, residual);
    const borrowed = bridge.list(.region, regions);
    const value = try runtime.catching(bridge.context(c), @ptrCast(raised), bridge.schema(result), bounds.value(), effects.slice(), borrowed.slice());
    return .{ .answer = @ptrCast(value.answer), .handler = @ptrCast(value.handler), .resumption = @ptrCast(value.resumption) };
}
