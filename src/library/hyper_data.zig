const bridge = @import("bridge.zig");
const a = bridge.a;
const native = bridge.native;
const hyper = @import("hyper.zig");
const runtime = @import("runtime/hyper_stream.zig");
const option_contract = @import("../authoring/option_contract.zig");

pub fn StreamNode(comptime E: type) type {
    return struct {
        pub const contract: native.Info = .{ .sum = native.Fields(
            &.{ "none", "some" },
            &.{ a.Shape(void), StreamCell(E) },
        ) };
    };
}

pub fn StreamCell(comptime E: type) type {
    return native.Contract(.{ .product = native.Fields(
        &.{ "head", "tail" },
        &.{ hyper.Delayed(E), hyper.Delayed(StreamNode(E)) },
    ) });
}

pub fn Stream(comptime E: type) type {
    return opaque {
        pub const Element = E;
        fn raw(self: *const @This()) *const runtime.Stream {
            return @ptrCast(self);
        }
        pub fn node(self: *const @This()) *const a.Schema(StreamNode(E)) {
            return @ptrCast(self.raw().node());
        }
        pub fn cell(self: *const @This()) *const a.Schema(StreamCell(E)) {
            return @ptrCast(self.raw().cell());
        }
        pub fn element(self: *const @This()) *const a.Schema(hyper.Delayed(E)) {
            return @ptrCast(self.raw().element());
        }
        pub fn spine(self: *const @This()) *const a.Schema(hyper.Delayed(StreamNode(E))) {
            return @ptrCast(self.raw().spine());
        }
    };
}

fn streamType(comptime T: type) type {
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
        @compileError("Horos hyper: expected a canonical stream");
    const Child = @typeInfo(T).pointer.child;
    if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "Element"))
        @compileError("Horos hyper: expected a canonical stream");
    if (T != *const Stream(Child.Element))
        @compileError("Horos hyper: expected a canonical stream");
    return Child;
}

pub fn stream(
    c: *a.Context,
    element: anytype,
    options: anytype,
) a.Error!*const Stream(bridge.schemaShape(@TypeOf(element))) {
    comptime option_contract.check("hyper.stream", @TypeOf(options), &.{"captures"});
    const captures = bridge.list(.schema, bridge.option(options, "captures", .{}));
    return @ptrCast(try runtime.create(
        bridge.context(c),
        bridge.schema(element),
        captures.slice(),
    ));
}

pub fn emptyStream(
    body: anytype,
    definition: anytype,
) a.Error!*const a.Value(StreamNode(streamType(@TypeOf(definition)).Element)) {
    return body.variant(definition.node(), "none", try body.constant(void, {}));
}

pub fn cons(
    body: anytype,
    definition: anytype,
    head: anytype,
    tail: anytype,
) a.Error!*const a.Value(StreamNode(streamType(@TypeOf(definition)).Element)) {
    const cell = try body.product(definition.cell(), .{ .head = head, .tail = tail });
    return body.variant(definition.node(), "some", cell);
}

fn ProductShape(comptime T: type) type {
    if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple)
        @compileError("Horos hyper.lazyProduct: expected named delayed values");
    const fields = @typeInfo(T).@"struct";
    var children: [fields.field_types.len]type = undefined;
    for (fields.field_types, &children) |Child, *S| {
        S.* = a.ShapeOf(Child);
        requireDelay(S.*);
    }
    return native.Contract(.{ .product = native.Fields(fields.field_names, &children) });
}

fn requireDelay(comptime S: type) void {
    if (S == a.Dynamic) return;
    if (!@hasDecl(S, "internal") or S.internal != .callable)
        @compileError("Horos hyper: expected a delayed shape");
    const Sig = S.internal.callable;
    if (Sig == a.Dynamic or Sig.parameters == a.Dynamic) return;
    if (@typeInfo(Sig.parameters).@"struct".field_types.len != 0)
        @compileError("Horos hyper: expected a delayed shape");
}

fn SchemaRow(comptime T: type) type {
    const fields = @typeInfo(T).@"struct";
    var children: [fields.field_types.len]type = undefined;
    for (fields.field_types, &children) |Child, *S| S.* = *const a.Schema(a.ShapeOf(Child));
    return native.Fields(fields.field_names, &children);
}

pub fn lazyProduct(
    body: anytype,
    fields: anytype,
) a.Error!*const a.Value(ProductShape(@TypeOf(fields))) {
    const c = try body.context();
    var schemas: SchemaRow(@TypeOf(fields)) = undefined;
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| {
        const schema = try body.schemaOf(@field(fields, name));
        try @import("runtime/hyper.zig").pureDelay(bridge.context(c), bridge.schema(schema));
        @field(schemas, name) = schema;
    }
    return body.product(try c.record(schemas), fields);
}

pub fn lazySum(
    body: anytype,
    alternatives: anytype,
    comptime name: []const u8,
    payload: anytype,
) a.Error!*const a.Value(bridge.schemaShape(@TypeOf(alternatives))) {
    const S = bridge.schemaShape(@TypeOf(alternatives));
    if (!@hasDecl(S, "contract") or S.contract != .sum)
        @compileError("Horos hyper.lazySum: expected a sum of delayed shapes");
    const c = try body.context();
    const fields = try alternatives.fields();
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
        const schema = @field(fields, field);
        comptime requireDelay(bridge.schemaShape(@TypeOf(schema)));
        try @import("runtime/hyper.zig").pureDelay(bridge.context(c), bridge.schema(schema));
    }
    return body.variant(alternatives, name, payload);
}
