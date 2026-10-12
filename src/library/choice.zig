//! Boolean choice keeps the original captured multi-shot continuation.
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/choice.zig");
const Op = a.OperationSignature(bridge.Unit, a.Shape(bool), bridge.Empty);
pub const Family = opaque {
    pub fn effect(self: *const Family) *const a.Operation(Op) {
        return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).effect());
    }
    pub fn capability(self: *const Family) *const a.Schema(a.Internal(.{ .capability = Op })) {
        return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).capability());
    }
};
pub fn Interpretation(comptime S: type) type {
    const Answer = bridge.sequence(S);
    const H = a.HandlerShape(native.Fields(&.{"capability"}, &.{Op}), S, Answer, bridge.Empty, bridge.Empty, .deep);
    return struct { handler: *const a.Handler(H), answer: *const a.Schema(Answer), resumption: *const a.Schema(bridge.resumption(a.Shape(bool), Answer)) };
}
pub fn family(c: *a.Context, identity: []const u8) a.Error!*const Family {
    return @ptrCast(try runtime.family(bridge.context(c), identity));
}
pub fn all(c: *a.Context, choice: *const Family, element: anytype, options: anytype) a.Error!Interpretation(bridge.schemaShape(@TypeOf(element))) {
    return interpret(c, choice, element, options, true);
}
pub fn first(c: *a.Context, choice: *const Family, element: anytype, options: anytype) a.Error!Interpretation(bridge.schemaShape(@TypeOf(element))) {
    return interpret(c, choice, element, options, false);
}
fn interpret(c: *a.Context, choice: *const Family, element: anytype, options: anytype, comptime every: bool) a.Error!Interpretation(bridge.schemaShape(@TypeOf(element))) {
    const bounds = bridge.captures(options.captures);
    const residual = bridge.list(.operation, bridge.option(options, "residual", .{}));
    const owned = bridge.list(.region, bridge.option(options, "owned_regions", .{}));
    const borrowed = bridge.list(.region, bridge.option(options, "borrowed_regions", .{}));
    const opts: runtime.Options = .{ .captures = bounds.value(), .residual = residual.slice(), .owned_regions = owned.slice(), .borrowed_regions = borrowed.slice() };
    const value = if (every) try runtime.all(bridge.context(c), @ptrCast(choice), bridge.schema(element), opts) else try runtime.first(bridge.context(c), @ptrCast(choice), bridge.schema(element), opts);
    return .{ .handler = @ptrCast(value.handler), .answer = @ptrCast(value.answer), .resumption = @ptrCast(value.resumption) };
}
