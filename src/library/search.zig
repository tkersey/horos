//! Search exposes a finite recursive step and keeps DFS/BFS as runtime policy.
const option_contract = @import("../authoring/option_contract.zig");
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/search.zig");
pub const Order = runtime.Order;
const Pick = a.OperationSignature(bridge.Unit, a.Shape(bool), bridge.Empty);
const Reject = a.OperationSignature(bridge.Unit, bridge.Unit, bridge.Empty);
pub const Family = opaque {
    pub fn pick(self: *const Family) *const a.Operation(Pick) {
        return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).pick());
    }
    pub fn reject(self: *const Family) *const a.Operation(Reject) {
        return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).reject());
    }
    pub fn pickCapability(self: *const Family) *const a.Schema(
        a.Internal(.{ .capability = Pick }),
    ) {
        return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).pickCapability());
    }
    pub fn rejectCapability(self: *const Family) *const a.Schema(
        a.Internal(.{ .capability = Reject }),
    ) {
        return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).rejectCapability());
    }
};
pub fn Step(comptime S: type) type {
    return struct {
        pub const contract: native.Info = .{ .sum = native.Fields(
            &.{ "solution", "branch", "rejected" },
            &.{ S, bridge.resumption(a.Shape(bool), @This()), bridge.Unit },
        ) };
    };
}
pub fn Search(comptime S: type) type {
    const Current = Step(S);
    const Token = bridge.resumption(a.Shape(bool), Current);
    const Task = native.Contract(.{ .product = native.Fields(
        &.{ "template", "argument" },
        &.{ Token, a.Shape(bool) },
    ) });
    const Queue = bridge.sequence(Task);
    const Solutions = bridge.sequence(S);
    const H = a.HandlerShape(
        native.Fields(&.{ "pick", "reject" }, &.{ Pick, Reject }),
        S,
        Current,
        bridge.Empty,
        bridge.Empty,
        .deep,
    );
    return struct {
        step: *const a.Schema(Current),
        resumption: *const a.Schema(Token),
        handler: *const a.Handler(H),
        solutions: *const a.Schema(Solutions),
        queue: *const a.Schema(Queue),
        explore: *const a.Function(a.Signature(
            native.Fields(&.{ "step", "queue", "found" }, &.{ Current, Queue, Solutions }),
            Solutions,
        )),
    };
}
pub fn family(c: *a.Context, identity: []const u8) a.Error!*const Family {
    return @ptrCast(try runtime.family(bridge.context(c), identity));
}
pub fn interpret(
    c: *a.Context,
    family_handle: *const Family,
    element: anytype,
    options: anytype,
) a.Error!Search(bridge.schemaShape(@TypeOf(element))) {
    comptime option_contract.check(
        "Search.interpret",
        @TypeOf(options),
        &.{ "captures", "residual", "owned_regions", "borrowed_regions", "order" },
    );
    const captures = bridge.captures(options.captures);
    const residual = bridge.list(.operation, bridge.option(options, "residual", .{}));
    const owned = bridge.list(.region, bridge.option(options, "owned_regions", .{}));
    const borrowed = bridge.list(.region, bridge.option(options, "borrowed_regions", .{}));
    const value = try runtime.interpret(
        bridge.context(c),
        @ptrCast(family_handle),
        bridge.schema(element),
        .{
            .captures = captures.value(),
            .residual = residual.slice(),
            .owned_regions = owned.slice(),
            .borrowed_regions = borrowed.slice(),
            .order = options.order,
        },
    );
    return .{
        .step = @ptrCast(value.step),
        .resumption = @ptrCast(value.resumption),
        .handler = @ptrCast(value.handler),
        .solutions = @ptrCast(value.solutions),
        .queue = @ptrCast(value.queue),
        .explore = @ptrCast(value.explore),
    };
}
pub fn collect(
    body: anytype,
    search: anytype,
    step: anytype,
) a.Error!*const a.Value(a.ShapeOf(@TypeOf(search.solutions))) {
    return body.call(
        search.explore,
        .{
            .step = step,
            .queue = try body.sequenceValue(search.queue, .{}),
            .found = try body.sequenceValue(search.solutions, .{}),
        },
    );
}
