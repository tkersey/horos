const std = @import("std");
const b = @import("horos");
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
