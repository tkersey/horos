//! FIFO and join interfaces preserve their exchange and completion contracts.
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const generator = @import("generator.zig");
const runtime = @import("runtime/scheduler.zig");
fn Queue(comptime S: type) type {
    return bridge.sequence(generator.Package(S.input, S.element, S.result));
}
pub fn Scheduler(comptime S: type) type {
    return struct {
        queue: *const a.Schema(Queue(S)),
        enqueue: *const a.Function(a.Signature(native.Fields(&.{ "step", "queue" }, &.{ generator.Answer(S.input, S.element, S.result), Queue(S) }), Queue(S))),
        drain: *const a.Function(a.Signature(native.Fields(&.{"queue"}, &.{Queue(S)}), bridge.Unit)),
    };
}
pub fn fifo(c: *a.Context, tasks: anytype, residual: anytype, regions: anytype) a.Error!Scheduler(generator.ExchangeShape(@TypeOf(tasks))) {
    const unit = try c.schema(void);
    _ = try a.interop.refineSchema(c, tasks.input(), unit);
    _ = try a.interop.refineSchema(c, tasks.result(), unit);
    const effects = bridge.list(.operation, residual);
    const borrowed = bridge.list(.region, regions);
    const value = try runtime.fifo(bridge.context(c), @ptrCast(tasks), effects.slice(), borrowed.slice());
    return .{ .queue = @ptrCast(value.queue), .enqueue = @ptrCast(value.enqueue), .drain = @ptrCast(value.drain) };
}
fn State(comptime S: type) type {
    return native.Contract(.{ .sum = native.Fields(&.{ "pending", "done" }, &.{ bridge.Unit, S }) });
}
fn Cell(comptime S: type) type {
    return a.Internal(.{ .cell = State(S) });
}
pub fn Join(comptime S: type) type {
    return opaque {
        pub const join_shape = S;
        pub fn state(self: *const @This()) *const a.Schema(State(S)) {
            return @ptrCast(@as(*const runtime.Join, @ptrCast(self)).state());
        }
        pub fn cell(self: *const @This()) *const a.Schema(Cell(S)) {
            return @ptrCast(@as(*const runtime.Join, @ptrCast(self)).cell());
        }
    };
}
fn joinShape(comptime T: type) type {
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one) @compileError("Horos Scheduler: expected canonical join");
    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "join_shape")) @compileError("Horos Scheduler: expected canonical join");
    const S = Child.join_shape;
    if (T != *const Join(S)) @compileError("Horos Scheduler: expected canonical join");
    return S;
}
pub fn joinType(c: *a.Context, result: anytype, region: *const a.Region) a.Error!*const Join(bridge.schemaShape(@TypeOf(result))) {
    return @ptrCast(try runtime.joinType(bridge.context(c), bridge.schema(result), region));
}
fn AwaitSignature(comptime Task: type, comptime S: type) type {
    return a.Signature(native.Fields(&.{ "cell", "capability" }, &.{ Cell(S), a.Internal(.{ .capability = generator.Op(Task) }) }), S);
}
pub fn awaiting(c: *a.Context, tasks: anytype, join: anytype, regions: anytype) a.Error!*const a.Function(AwaitSignature(generator.ExchangeShape(@TypeOf(tasks)), joinShape(@TypeOf(join)))) {
    _ = try a.interop.refineSchema(c, tasks.element(), try c.schema(void));
    const borrowed = bridge.list(.region, regions);
    return @ptrCast(try runtime.awaiting(bridge.context(c), @ptrCast(tasks), @ptrCast(join), borrowed.slice()));
}
pub fn complete(body: anytype, join: anytype, cell: anytype, result: anytype) a.Error!*const a.Value(bridge.Unit) {
    _ = comptime joinShape(@TypeOf(join));
    return body.writeCell(cell, try body.variant(join.state(), "done", result));
}
