//! Reader retains finite recursive callable relationships without expanding them.
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/reader.zig");
fn Shapes(comptime E: type, comptime R: type) type {
    return struct {
        pub const environment = E;
        pub const inside_result = R;
        pub const Ask = a.OperationSignature(bridge.Unit, E, bridge.Empty);
        pub const Local = a.OperationSignature(E, R, native.Fields(&.{"inside"}, &.{Inside}));
        pub const Operations = native.Fields(&.{ "ask", "local" }, &.{ Ask, Local });
        pub const Inside = struct {
            pub const internal: a.InternalInfo = .{ .callable = a.Signature(
                native.Fields(
                    &.{ "ask", "local" },
                    &.{ a.Internal(.{ .capability = Ask }), a.Internal(.{ .capability = Local }) },
                ),
                R,
            ) };
        };
        pub fn Handler(comptime Result: type) type {
            return a.HandlerShape(
                Operations,
                Result,
                Result,
                native.Fields(&.{"environment"}, &.{E}),
                bridge.Empty,
                .deep,
            );
        }
    };
}
pub fn Family(comptime E: type, comptime R: type) type {
    const S = Shapes(E, R);
    return opaque {
        pub const family_shape = S;
        pub fn ask(self: *const @This()) *const a.Operation(S.Ask) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).ask());
        }
        pub fn local(self: *const @This()) *const a.Operation(S.Local) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).local());
        }
        pub fn askCapability(self: *const @This()) *const a.Schema(
            a.Internal(.{ .capability = S.Ask }),
        ) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).askCapability());
        }
        pub fn localCapability(self: *const @This()) *const a.Schema(
            a.Internal(.{ .capability = S.Local }),
        ) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).localCapability());
        }
        pub fn inside(self: *const @This()) *const a.Schema(S.Inside) {
            return @ptrCast(@as(*const runtime.Family, @ptrCast(self)).inside());
        }
    };
}
fn familyShape(comptime T: type) type {
    if (@typeInfo(T) != .pointer or
        @typeInfo(T).pointer.size != .one)
        @compileError("Horos Reader: expected canonical family");
    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "family_shape")) @compileError("Horos Reader: expected canonical family");
    const S = Child.family_shape;
    if (T != *const Family(
        S.environment,
        S.inside_result,
    )) @compileError("Horos Reader: expected canonical family");
    return S;
}
pub fn Reader(comptime S: type, comptime R: type) type {
    return struct {
        handler: *const a.Handler(S.Handler(R)),
        inside_handler: *const a.Handler(S.Handler(S.inside_result)),
        /// Runtime-sized heterogeneous identity row for capture bounds. Each
        /// clause's precise resumption is available through resumptionSchemaFor.
        resumptions: []const *const a.Schema(a.Dynamic),
    };
}
pub fn family(
    c: *a.Context,
    identity: []const u8,
    environment: anytype,
    inside_result: anytype,
    inside_captures: anytype,
    residual: anytype,
    regions: anytype,
) a.Error!*const Family(
    bridge.schemaShape(@TypeOf(environment)),
    bridge.schemaShape(@TypeOf(inside_result)),
) {
    const captures = bridge.list(.schema, inside_captures);
    const effects = bridge.list(.operation, residual);
    const borrowed = bridge.list(.region, regions);
    return @ptrCast(try runtime.family(
        bridge.context(c),
        identity,
        bridge.schema(environment),
        bridge.schema(inside_result),
        captures.slice(),
        effects.slice(),
        borrowed.slice(),
    ));
}
pub fn interpret(
    c: *a.Context,
    reader: anytype,
    result: anytype,
    capture_bounds: anytype,
) a.Error!Reader(familyShape(@TypeOf(reader)), bridge.schemaShape(@TypeOf(result))) {
    const captures = bridge.captures(capture_bounds);
    const value = try runtime.interpret(
        bridge.context(c),
        @ptrCast(reader),
        bridge.schema(result),
        captures.value(),
    );
    return .{
        .handler = @ptrCast(value.handler),
        .inside_handler = @ptrCast(value.inside_handler),
        .resumptions = @as(
            [*]const *const a.Schema(a.Dynamic),
            @ptrCast(value.resumptions.ptr),
        )[0..value.resumptions.len],
    };
}
