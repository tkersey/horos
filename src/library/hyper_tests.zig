const std = @import("std");
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const hyper = @import("hyper.zig");
const native = @import("horos_data").schema.native;

test "typed hyper pair completes around a promised effectful task endpoint" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const Task = a.Internal(.{ .callable = a.Signature(native.Fields(&.{}, &.{}), a.Shape(u64)) });
    const task = try c.declareSchema(.callable, Task);
    const types = try hyper.pair(c, task.schema(), task.schema(), .{ .captures = .{integer} });
    const effect = try c.external("task", integer, integer);
    try c.defineCallable(task, .{}, integer, .{effect}, .{
        .use = .reusable,
        .captures = .{ integer, types.peerForward(), types.peerBackward() },
    });
    const f = try c.function("entry", .{}, integer, .{});
    const b = try c.body(f);
    try c.define(f, try b.ret(try b.constant(u64, 42)));
    var compiled = try c.compile(std.testing.allocator, f, try c.schema(void));
    defer compiled.deinit();
    try std.testing.expect(types.swap().swap() == types);
    try std.testing.expectEqual(types, try hyper.pair(
        c,
        task.schema(),
        task.schema(),
        .{ .captures = .{integer} },
    ));
}

test "typed hyper constant compiles with a delayed answer and a diverging peer" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const f = try c.function("entry", .{}, integer, .{});
    const b = try c.body(f);
    const answer = try hyper.deferValue(b, types.answerForward(), try b.constant(u64, 42));
    const participant = try hyper.base(b, types, answer);
    const never = try c.functionFor("diverging peer", types.peerBackward());
    const never_body = try b.closureBody(never);
    try c.define(never, try never_body.ret(try never_body.call(never, .{})));
    const peer = try b.lambda(never, types.peerBackward());
    try c.define(f, try b.ret(try hyper.force(b, try hyper.invoke(b, participant, peer))));
    var compiled = try c.compile(std.testing.allocator, f, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper demand boundary fixtures compile through ordinary source admission" {
    const cases = @import("../hyper_cases.zig");
    for (std.enums.values(cases.Kind)) |kind| {
        var raw = source.Builder.init(std.testing.allocator);
        defer raw.deinit();
        const module = try cases.build(&raw, kind);
        var compiled = try source.lower(std.testing.allocator, module);
        defer compiled.deinit();
    }
}

test "typed hyper task and Need fixtures preserve checked construction and admission" {
    const cases = @import("../hyper_task_cases.zig");
    for (std.enums.values(cases.Kind)) |kind| {
        var raw = source.Builder.init(std.testing.allocator);
        defer raw.deinit();
        const module = try cases.build(&raw, kind);
        var compiled = try source.lower(std.testing.allocator, module);
        defer compiled.deinit();
    }
}

test "typed hyper force rejects effectful same shaped callables" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const effect = try c.external("not pure", integer, integer);
    const task = try c.callable(.{}, integer, .{effect}, .{ .use = .reusable });
    const function = try c.function("effectful", .{}, integer, .{effect});
    const task_body = try c.body(function);
    try c.define(function, try task_body.ret(try task_body.perform(
        effect,
        try task_body.constant(u64, 1),
    )));
    const entry = try c.function("entry", .{}, integer, .{effect});
    const body = try c.body(entry);
    const callable = try body.lambda(function, task);
    try std.testing.expectError(error.SchemaMismatch, hyper.force(body, callable));
}

test "typed hyper values cannot escape lexical scope or revive a closed body" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const branch = try body.branch();
    const escaped = try hyper.deferValue(branch, delay, try branch.constant(u64, 42));
    try std.testing.expectError(error.OutOfScope, hyper.force(body, escaped));
    branch.abandon();
    const value = try hyper.deferValue(body, delay, try body.constant(u64, 42));
    try c.define(entry, try body.ret(try body.constant(u64, 42)));
    try std.testing.expectError(error.ClosedBody, hyper.force(body, value));
}

test "typed hyper reusable recursion cannot hide exclusive captures" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const owned = try c.resource(integer);
    _ = try hyper.pair(c, integer, integer, .{ .captures = .{owned} });
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(u64, 42)));
    try std.testing.expectError(error.InvalidOwnership, c.compile(
        std.testing.allocator,
        entry,
        try c.schema(void),
    ));
}

test "typed hyper Need capabilities remain nominal under equal display names" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const left = try hyper.demand.family(c, "same", integer, integer);
    const right = try hyper.demand.family(c, "same", integer, integer);
    try std.testing.expect(left.effect() != right.effect());
    try std.testing.expect(left.capability() != right.capability());
    const function = try c.function("request", .{
        .capability = left.capability(),
    }, integer, .{right.effect()});
    const body = try c.body(function);
    try std.testing.expectError(error.SchemaMismatch, hyper.demand.request(
        body,
        right,
        try body.parameter("capability"),
        try body.constant(u64, 1),
    ));
}

test "typed hyper nested same named Need families admit lexical routing" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const module = try @import("../hyper_need_cases.zig").nested(&raw);
    var compiled = try source.lower(std.testing.allocator, module);
    defer compiled.deinit();
}

test "typed hyper pair shares its finite checked schema declarations" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const first = try hyper.pair(c, integer, boolean, .{});
    const count = raw.schemas.items.len;
    for (0..100) |_| {
        try std.testing.expectEqual(first, try hyper.pair(c, integer, boolean, .{}));
        try std.testing.expectEqual(count, raw.schemas.items.len);
    }
}

test "typed hyper endpoints compare normalized structures across native names" {
    const Left = struct { answer: u64 };
    const Right = struct { answer: u64 };
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const types = try hyper.pair(c, try c.schema(Left), try c.schema(Right), .{});
    const entry = try c.function("aliases", .{}, try c.schema(Left), .{});
    const body = try c.body(entry);
    const value = try body.product(try c.schema(Left), .{
        .answer = try body.constant(u64, 42),
    });
    const answer = try hyper.deferValue(body, types.answerForward(), value);
    const participant = try hyper.base(body, types, answer);
    const input = try hyper.deferValue(body, types.answerBackward(), value);
    const result = try hyper.force(body, try hyper.project(body, types, participant, input));
    try c.define(entry, try body.ret(result));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper recursive descriptors release every failed construction allocation" {
    try @import("../allocation_testing.zig").check(
        std.testing.allocator,
        descriptorAllocation,
        .{},
    );
}

fn descriptorAllocation(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const pair = try hyper.pair(c, integer, integer, .{});
    const group = try hyper.group(c, .{ .integer = integer }, .{});
    const stream = try hyper.stream(c, integer, .{});
    try std.testing.expect(pair == try hyper.pair(c, integer, integer, .{}));
    try std.testing.expect(group == try hyper.group(c, .{ .integer = integer }, .{}));
    try std.testing.expect(stream == try hyper.stream(c, integer, .{}));
    const entry = try c.function("allocation", .{}, integer, .{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(u64, 42)));
    var compiled = try c.compile(allocator, entry, try c.schema(void));
    defer compiled.deinit();
}
