// Copyright (c) 2026 Boundary contributors. MIT license.
//! Two private representations satisfy one unchanged typed resource client.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
pub fn scalar(b: *source.Builder) source.Error!source.Module {
    return build(b, false);
}
pub fn pair(b: *source.Builder) source.Error!source.Module {
    return build(b, true);
}
const native = @import("horos_data").schema.native;
pub fn Interface(comptime structured: bool) type {
    const Representation = if (structured) a.Shape(struct {
        number: u64,
        active: bool,
    }) else a.Shape(u64);
    const Owned = a.Internal(.{ .resource = Representation });
    const Borrowed = a.Internal(.{ .borrowed = Owned });
    const Empty = native.Fields(&.{}, &.{});
    return struct {
        owned: *const a.Schema(Owned),
        borrowed: *const a.Schema(Borrowed),
        acquire: *const a.Function(a.Signature(Empty, Owned)),
        read: *const a.Function(a.Signature(
            native.Fields(&.{"resource"}, &.{Borrowed}),
            a.Shape(u64),
        )),
        release: *const a.Function(a.Signature(
            native.Fields(&.{"resource"}, &.{Owned}),
            a.Shape(void),
        )),
        acquire_effect: *const a.Operation(a.OperationSignature(
            a.Shape(void),
            a.Shape(u64),
            Empty,
        )),
        release_effect: *const a.Operation(a.OperationSignature(
            a.Shape(u64),
            a.Shape(void),
            Empty,
        )),
        loan: *const a.Region,
    };
}
fn implementation(c: *a.Context, comptime structured: bool) a.Error!Interface(structured) {
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const representation = if (structured) try c.record(.{
        .number = integer,
        .active = try c.schema(bool),
    }) else integer;
    const owned = try c.resource(representation);
    const loan = try c.region();
    const borrowed = try c.borrowed(owned, loan);
    const acquiring = try c.external("example/resource-acquire", unit, integer);
    const releasing = try c.external("example/resource-release", integer, unit);
    const acquire = try c.function("acquire", .{}, owned, &.{acquiring});
    const read_type = try c.callable(
        .{ .resource = borrowed },
        integer,
        &.{},
        .{ .use = .reusable, .captures = &.{}, .regions = &.{loan} },
    );
    const read = try c.functionFor("read", read_type);
    const release = try c.function("release", .{ .resource = owned }, unit, &.{releasing});
    try c.resourceAuthority(owned, &.{acquire}, &.{ read, release });
    const acquire_body = try c.body(acquire);
    const raw = try acquire_body.perform(acquiring, try acquire_body.constant(void, {}));
    const contents = if (structured) try acquire_body.product(
        representation,
        .{ .number = raw, .active = try acquire_body.constant(bool, true) },
    ) else raw;
    try c.define(acquire, try acquire_body.ret(try acquire_body.packResource(owned, contents)));
    inline for (.{ read, release }, 0..) |function, index| {
        const body = try c.body(function);
        const internal = try body.unpackResource(try body.parameter("resource"));
        const number = if (structured) try body.field(internal, "number") else internal;
        try c.define(
            function,
            try body.ret(if (index == 0) number else try body.perform(releasing, number)),
        );
    }
    return .{
        .owned = owned,
        .borrowed = borrowed,
        .acquire = acquire,
        .read = read,
        .release = release,
        .acquire_effect = acquiring,
        .release_effect = releasing,
        .loan = loan,
    };
}
fn client(c: *a.Context, interface: anytype) a.Error!source.Module {
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const inspecting = try c.external("example/resource-use", integer, unit);
    const body_type = try c.callable(
        .{ .loan = interface.borrowed },
        integer,
        &.{inspecting},
        .{ .use = .linear, .captures = &.{}, .regions = &.{interface.loan} },
    );
    const body_fn = try c.functionFor("resource client", body_type);
    const body = try c.body(body_fn);
    const loan = try body.parameter("loan");
    const read = try body.call(interface.read, .{ .resource = loan });
    _ = try body.perform(inspecting, read);
    const reread = try body.call(interface.read, .{ .resource = loan });
    try c.define(
        body_fn,
        try body.ret(try body.checkedAdd(
            reread,
            try body.constant(u64, 1),
            try c.literalFailure(void, {}),
        )),
    );
    const cleanup_type = try c.callable(
        .{ .exit = try c.cleanupInfo(unit), .resource = interface.owned },
        unit,
        &.{interface.release_effect},
        .{ .use = .linear, .captures = &.{} },
    );
    const cleanup_fn = try c.functionFor("release owner", cleanup_type);
    const cleanup = try c.body(cleanup_fn);
    try c.define(
        cleanup_fn,
        try cleanup.ret(try cleanup.call(
            interface.release,
            .{ .resource = try cleanup.parameter("resource") },
        )),
    );
    const main = try c.function(
        "entry",
        .{},
        integer,
        &.{ interface.acquire_effect, interface.release_effect, inspecting },
    );
    const entry = try c.body(main);
    const resource = try entry.call(interface.acquire, .{});
    try c.define(
        main,
        try entry.ret(try entry.bracket(
            resource,
            interface.loan,
            try entry.lambda(body_fn, body_type),
            try entry.lambda(cleanup_fn, cleanup_type),
            .{},
        )),
    );
    return c.module(main, unit);
}
fn build(b: *source.Builder, comptime structured: bool) source.Error!source.Module {
    return authored(b, structured) catch |err| return a.sourceError(err);
}
fn authored(b: *source.Builder, comptime structured: bool) a.Error!source.Module {
    const c = try a.Context.init(b);
    return client(c, try implementation(c, structured));
}
