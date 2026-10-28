const std = @import("std");
const b = @import("horos");
test "imported callable contracts preserve use effects regions and capture allowances" {
    var raw = b.source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try b.authoring.Context.init(&raw);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const effect = try c.external("imported/effect", integer, integer);
    const region = try c.region();
    const other_region = try c.region();
    const expected = try c.callable(.{ .input = integer }, integer, .{effect}, .{
        .use = .linear,
        .captures = .{integer},
        .regions = .{region},
    });
    const id = try b.authoring.interop.schemaId(c, expected);
    const imported = try b.authoring.interop.schema(c, id);
    try std.testing.expectEqual(id, try b.authoring.interop.schemaId(c, imported));
    try std.testing.expectEqual(expected, try b.authoring.interop.mapSchema(c, imported, expected));
    const changed = .{
        try c.callable(.{ .input = integer }, integer, .{effect}, .{
            .use = .reusable,
            .captures = .{integer},
            .regions = .{region},
        }),
        try c.callable(.{ .input = integer }, integer, .{}, .{
            .use = .linear,
            .captures = .{integer},
            .regions = .{region},
        }),
        try c.callable(.{ .input = integer }, integer, .{effect}, .{
            .use = .linear,
            .captures = .{integer},
            .regions = .{other_region},
        }),
        try c.callable(.{ .input = integer }, integer, .{effect}, .{
            .use = .linear,
            .captures = .{boolean},
            .regions = .{region},
        }),
    };
    inline for (changed) |wrong| try std.testing.expectError(
        error.SchemaMismatch,
        b.authoring.interop.mapSchema(c, imported, wrong),
    );
}

test "ordinary libraries exclude raw constructors from the exported package" {
    try std.testing.expect(!@hasDecl(b.library, "cleanup"));
    inline for (.{
        "Generator", "Scope", "defineExchange", "next", "close", "start", "offer", "exchange",
    }) |name| try std.testing.expect(!@hasDecl(b.library.generator, name));
    try std.testing.expect(!@hasDecl(b.source.library.generator, "Scope"));
    try std.testing.expect(!@hasDecl(b.source.library.generator, "next"));
    try std.testing.expect(!@hasDecl(b.source.library.generator, "create"));
    var raw = b.source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const unit = try raw.scalar(void);
    const exchange = try b.source.library.generator.defineExchange(
        &raw,
        "package/source-exchange",
        unit,
        unit,
        unit,
        &.{},
        &.{},
        &.{},
        .{ .effects = &.{} },
    );
    try std.testing.expect(exchange.package < raw.schemas.items.len);
    const cleanup = try b.source.library.cleanup.exitInfo(&raw, unit);
    try std.testing.expect(cleanup < raw.schemas.items.len);
}

test "foreign effect rejects in public package while local binding succeeds" {
    var first = b.source.Builder.init(std.testing.allocator);
    defer first.deinit();
    var second = b.source.Builder.init(std.testing.allocator);
    defer second.deinit();
    const left = try b.authoring.Context.init(&first);
    const right = try b.authoring.Context.init(&second);
    const lu = try left.schema(void);
    const ru = try right.schema(void);
    const foreign = try left.external("same", lu, lu);
    const local = try right.external("same", ru, ru);
    const entry = try right.function("entry", .{}, ru, &.{local});
    const body = try right.body(entry);
    const payload = try body.constant(void, {});
    try std.testing.expectError(error.ForeignHandle, body.perform(foreign, payload));
    try right.define(entry, try body.ret(try body.perform(local, payload)));
    var compiled = try right.compile(std.testing.allocator, entry, ru);
    defer compiled.deinit();
}

test "foreign failure literal rejects through public package" {
    var first = b.source.Builder.init(std.testing.allocator);
    defer first.deinit();
    var second = b.source.Builder.init(std.testing.allocator);
    defer second.deinit();
    const left = try b.authoring.Context.init(&first);
    const right = try b.authoring.Context.init(&second);
    const integer = try left.schema(u64);
    const entry = try left.function("entry", .{}, integer, &.{});
    const body = try left.body(entry);
    const value = try body.constant(u64, 1);
    try std.testing.expectError(error.ForeignHandle, body.checkedAdd(
        value,
        value,
        try right.literalFailure(void, {}),
    ));
}

test "same-name local capabilities and sibling values remain distinct" {
    var raw = b.source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try b.authoring.Context.init(&raw);
    const unit = try c.schema(void);
    const first = try c.local("same", unit, unit, .linear);
    const second = try c.local("same", unit, unit, .linear);
    const cap = try c.capability(first);
    const entry = try c.function("entry", .{ .cap = cap }, unit, &.{second});
    const body = try c.body(entry);
    try std.testing.expectError(error.SchemaMismatch, body.performLocal(
        second,
        try body.parameter("cap"),
        try body.constant(void, {}),
    ));
    const left = try body.branch();
    const right = try body.branch();
    const local = try left.constant(void, {});
    try std.testing.expectError(error.OutOfScope, right.ret(local));
}
