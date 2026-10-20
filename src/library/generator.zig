//! Owned exchanges retain their recursive answer and pipeline signatures.
const option_contract = @import("../authoring/option_contract.zig");
const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const runtime = @import("runtime/generator.zig");
const p = @import("horos_data").program;
// Deliberate raw component construction remains a distinct compiler boundary.
pub const Generator = runtime.Generator;
pub const Scope = runtime.Scope;
pub const defineExchange = runtime.defineExchange;
pub const next = runtime.next;
pub const close = runtime.close;
pub const start = runtime.start;
pub const offer = runtime.offer;
pub const exchange = runtime.exchange;

pub fn Signature(comptime I: type, comptime E: type, comptime R: type, comptime P: type) type {
    return struct {
        pub const input = I;
        pub const element = E;
        pub const result = R;
        pub const parameters = P;
    };
}
pub fn Answer(comptime I: type, comptime E: type, comptime R: type) type {
    return struct {
        pub const contract: native.Info = .{ .sum = native.Fields(
            &.{ "done", "yielded" },
            &.{ R, Yielded(I, E, R) },
        ) };
    };
}
pub fn Resumption(comptime I: type, comptime E: type, comptime R: type) type {
    return bridge.resumption(I, Answer(I, E, R));
}
pub fn Package(comptime I: type, comptime E: type, comptime R: type) type {
    return a.Internal(.{ .package = Resumption(I, E, R) });
}
pub fn Yielded(comptime I: type, comptime E: type, comptime R: type) type {
    return native.Contract(.{ .product = native.Fields(
        &.{ "value", "future" },
        &.{ E, Package(I, E, R) },
    ) });
}
pub fn Op(comptime S: type) type {
    return a.OperationSignature(S.element, S.input, bridge.Empty);
}
fn H(comptime S: type) type {
    return a.HandlerShape(
        native.Fields(&.{"capability"}, &.{Op(S)}),
        S.result,
        Answer(S.input, S.element, S.result),
        bridge.Empty,
        S.parameters,
        .deep,
    );
}
pub fn Exchange(comptime S: type) type {
    return opaque {
        pub const exchange_shape = S;
        fn raw(self: *const @This()) *const runtime.Exchange {
            return @ptrCast(self);
        }
        pub fn input(self: *const @This()) *const a.Schema(S.input) {
            return @ptrCast(self.raw().input());
        }
        pub fn element(self: *const @This()) *const a.Schema(S.element) {
            return @ptrCast(self.raw().element());
        }
        pub fn result(self: *const @This()) *const a.Schema(S.result) {
            return @ptrCast(self.raw().result());
        }
        pub fn effect(self: *const @This()) *const a.Operation(Op(S)) {
            return @ptrCast(self.raw().effect());
        }
        pub fn capability(self: *const @This()) *const a.Schema(
            a.Internal(.{ .capability = Op(S) }),
        ) {
            return @ptrCast(self.raw().capability());
        }
        pub fn answer(self: *const @This()) *const a.Schema(Answer(S.input, S.element, S.result)) {
            return @ptrCast(self.raw().answer());
        }
        pub fn yielded(self: *const @This()) *const a.Schema(Yielded(
            S.input,
            S.element,
            S.result,
        )) {
            return @ptrCast(self.raw().yielded());
        }
        pub fn package(self: *const @This()) *const a.Schema(Package(
            S.input,
            S.element,
            S.result,
        )) {
            return @ptrCast(self.raw().package());
        }
        pub fn resumption(self: *const @This()) *const a.Schema(Resumption(
            S.input,
            S.element,
            S.result,
        )) {
            return @ptrCast(self.raw().resumption());
        }
        pub fn handler(self: *const @This()) *const a.Handler(H(S)) {
            return @ptrCast(self.raw().handler());
        }
    };
}
pub fn ExchangeShape(comptime T: type) type {
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one) @compileError("Horos Generator: expected canonical exchange");
    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(
        Child,
        "exchange_shape",
    )) @compileError("Horos Generator: expected canonical exchange");
    const S = Child.exchange_shape;
    if (T != *const Exchange(S)) @compileError("Horos Generator: expected canonical exchange");
    return S;
}
fn OptionsParameters(comptime T: type) type {
    return bridge.namedShape(if (@hasField(T, "parameters")) @FieldType(T, "parameters") else @TypeOf(.{}));
}
pub fn create(
    c: *a.Context,
    identity: []const u8,
    input: anytype,
    element: anytype,
    result: anytype,
    options: anytype,
) a.Error!*const Exchange(Signature(
    bridge.schemaShape(@TypeOf(input)),
    bridge.schemaShape(@TypeOf(element)),
    bridge.schemaShape(@TypeOf(result)),
    OptionsParameters(@TypeOf(options)),
)) {
    comptime option_contract.check(
        "Generator.create",
        @TypeOf(options),
        &.{
            "captures",
            "residual",
            "owned_regions",
            "borrowed_regions",
            "parameters",
            "body_use",
        },
    );
    const captures = bridge.captures(options.captures);
    const residual = bridge.list(.operation, bridge.option(options, "residual", .{}));
    const owned = bridge.list(.region, bridge.option(options, "owned_regions", .{}));
    const borrowed = bridge.list(.region, bridge.option(options, "borrowed_regions", .{}));
    const parameters = try bridge.named(c, bridge.option(options, "parameters", .{}));
    return @ptrCast(try runtime.create(
        bridge.context(c),
        identity,
        bridge.schema(input),
        bridge.schema(element),
        bridge.schema(result),
        .{
            .captures = captures.value(),
            .residual = residual.slice(),
            .owned_regions = owned.slice(),
            .borrowed_regions = borrowed.slice(),
            .parameters = parameters.slice(),
            .body_use = bridge.option(options, "body_use", p.Use.linear),
        },
    ));
}
fn PipelineParameters(comptime L: type, comptime R: type) type {
    return native.Fields(
        &.{ "left", "right", "input" },
        &.{
            Package(L.input, L.element, L.result),
            Package(R.input, R.element, R.result),
            L.input,
        },
    );
}
pub fn Pipeline(comptime L: type, comptime R: type) type {
    const S = Signature(L.input, R.element, L.result, PipelineParameters(L, R));
    return struct {
        generator: *const Exchange(S),
        start: *const a.Function(a.Signature(S.parameters, Answer(S.input, S.element, S.result))),
    };
}
pub fn pipeline(
    c: *a.Context,
    identity: []const u8,
    left: anytype,
    right: anytype,
) a.Error!Pipeline(ExchangeShape(@TypeOf(left)), ExchangeShape(@TypeOf(right))) {
    _ = try a.interop.refineSchema(c, left.element(), right.input());
    _ = try a.interop.refineSchema(c, left.result(), right.result());
    const value = try runtime.pipeline(
        bridge.context(c),
        identity,
        @ptrCast(left),
        @ptrCast(right),
    );
    return .{ .generator = @ptrCast(value.generator), .start = @ptrCast(value.start) };
}
