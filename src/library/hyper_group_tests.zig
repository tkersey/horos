const std = @import("std");
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const hyper = @import("hyper.zig");
const groups = @import("hyper_group.zig");
const native = @import("horos_data").schema.native;

test "typed hyper group composes three named distinguishable endpoints" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const byte = try c.schema(u8);
    const boolean = try c.schema(bool);
    const integer = try c.schema(u64);
    const endpoints = .{ .input = byte, .middle = boolean, .output = integer };
    const interfaces = try groups.group(c, endpoints, .{});
    try std.testing.expectEqual(interfaces, try groups.group(c, endpoints, .{}));
    const ab = interfaces.get("input", "middle");
    const bc = interfaces.get("middle", "output");
    const ac = interfaces.get("input", "output");
    try std.testing.expectEqual(ab.swap(), interfaces.get("middle", "input"));
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const left = try hyper.base(body, bc, try hyper.deferValue(
        body,
        bc.answerForward(),
        try body.constant(u64, 42),
    ));
    const right = try hyper.base(body, ab, try hyper.deferValue(
        body,
        ab.answerForward(),
        try body.constant(bool, true),
    ));
    const combined = try groups.compose(body, interfaces, "input", "middle", "output", left, right);
    const count = raw.functions.items.len;
    _ = try groups.compose(body, interfaces, "input", "middle", "output", left, right);
    try std.testing.expectEqual(count, raw.functions.items.len);
    try std.testing.expect(
        @TypeOf(combined) == *const a.Value(hyper.Hyper(a.Shape(u8), a.Shape(u64))),
    );
    const peer = try hyper.base(body, ac.swap(), try hyper.deferValue(
        body,
        ac.answerBackward(),
        try body.constant(u8, 7),
    ));
    const delayed_peer = try hyper.deferValue(body, ac.peerBackward(), peer);
    const answer = try hyper.force(body, try hyper.invoke(body, combined, delayed_peer));
    try c.define(entry, try body.ret(answer));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper group runtime selection preserves its known endpoint" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const interfaces = try groups.group(c, .{
        .input = try c.schema(u8),
        .output = try c.schema(u64),
    }, .{});
    const from = try groups.interop.from(interfaces, "input", "output");
    const to = try groups.interop.to(interfaces, "input", "output");
    const selected = try groups.interop.select(interfaces, "input", "output");
    try std.testing.expect(@TypeOf(from) == *const hyper.Pair(a.Shape(u8), a.Dynamic));
    try std.testing.expect(@TypeOf(to) == *const hyper.Pair(a.Dynamic, a.Shape(u64)));
    try std.testing.expect(@TypeOf(selected) == *const hyper.Pair(a.Dynamic, a.Dynamic));
    try std.testing.expectEqual(
        try a.interop.schemaId(c, interfaces.get("input", "output").forward()),
        try a.interop.schemaId(c, selected.forward()),
    );
    try std.testing.expectError(
        error.UnknownName,
        groups.interop.from(interfaces, "input", "absent"),
    );
}

test "typed hyper group admits demanding heterogeneous reciprocal rotations" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    var compiled = try source.lower(
        std.testing.allocator,
        try @import("../hyper_composition_cases.zig").build(&raw),
    );
    defer compiled.deinit();
}

test "typed hyper group rejects foreign schema handles and foreign composition" {
    var first_raw = source.Builder.init(std.testing.allocator);
    defer first_raw.deinit();
    var second_raw = source.Builder.init(std.testing.allocator);
    defer second_raw.deinit();
    const first = try a.Context.init(&first_raw);
    const second = try a.Context.init(&second_raw);
    const integer = try first.schema(u64);
    try std.testing.expectError(
        error.ForeignHandle,
        groups.group(second, .{ .input = integer }, .{}),
    );
    const interfaces = try groups.group(first, .{ .input = integer }, .{});
    const types = interfaces.get("input", "input");
    const entry = try first.function("first", .{}, integer, .{});
    const body = try first.body(entry);
    const participant = try hyper.base(body, types, try hyper.deferValue(
        body,
        types.answerForward(),
        try body.constant(u64, 42),
    ));
    const other = try second.function("second", .{}, try second.schema(u64), .{});
    try std.testing.expectError(error.ForeignHandle, groups.compose(
        try second.body(other),
        interfaces,
        "input",
        "input",
        "input",
        participant,
        participant,
    ));
}

test "typed hyper group rejects same shaped incompatible capture graphs" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const narrow = try groups.group(c, .{ .value = integer }, .{});
    const other = try groups.group(c, .{ .value = integer }, .{
        .captures = .{try c.schema(bool)},
    });
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const types = other.get("value", "value");
    const participant = try hyper.base(body, types, try hyper.deferValue(
        body,
        types.answerForward(),
        try body.constant(u64, 42),
    ));
    try std.testing.expectError(error.SchemaMismatch, groups.compose(
        body,
        narrow,
        "value",
        "value",
        "value",
        participant,
        participant,
    ));
}

test "typed hyper group retains a promised task until checked publication" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const Task = a.Internal(.{ .callable = a.Signature(native.Fields(&.{}, &.{}), a.Shape(u64)) });
    const task = try c.declareSchema(.callable, Task);
    const interfaces = try groups.group(c, .{ .task = task.schema(), .answer = integer }, .{});
    const types = interfaces.get("task", "task");
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(u64, 42)));
    const unit = try c.schema(void);
    try std.testing.expectError(error.UndefinedSchema, c.module(entry, unit));
    const lookup = try c.external("task", integer, integer);
    try c.defineCallable(task, .{}, integer, .{lookup}, .{
        .use = .reusable,
        .captures = .{ types.peerForward(), types.peerBackward() },
    });
    var compiled = try c.compile(std.testing.allocator, entry, unit);
    defer compiled.deinit();
}

test "typed hyper group rejects excessive graph references before reservation" {
    const runtime = @import("runtime/hyper_group.zig");
    const owner = @import("../authoring/runtime.zig");
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    var names: [32][2]u8 = undefined;
    var endpoints: [32]owner.Field = undefined;
    for (&names, &endpoints, 0..) |*name, *endpoint, i| {
        endpoint.* = .{
            .name = try std.fmt.bufPrint(name, "{d}", .{i}),
            .schema = @ptrCast(integer),
        };
    }
    const before = raw.schemas.items.len;
    try std.testing.expectError(error.Capacity, runtime.group(@ptrCast(c), &endpoints, &.{}));
    try std.testing.expectEqual(before, raw.schemas.items.len);
}
