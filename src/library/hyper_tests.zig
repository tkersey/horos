const std = @import("std");
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const hyper = @import("hyper.zig");
const native = @import("horos_data").schema.native;

test "typed hyper pair capture references retain their separate catalog meaning" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const count = @import("horos_data").component.max_catalog_entries / 6 + 1;
    const captures = try std.testing.allocator.alloc(*const a.Schema(a.Dynamic), count);
    defer std.testing.allocator.free(captures);
    @memset(captures, a.interop.erase(integer));
    const types = try hyper.pair(c, integer, integer, .{ .captures = captures });
    try std.testing.expect(types.swap().swap() == types);
    try std.testing.expectEqual(types, try hyper.pair(
        c,
        integer,
        integer,
        .{ .captures = captures },
    ));
}

test "typed hyper invoke checks actual peer delay effects even when the peer is ignored" {
    inline for (.{ false, true }) |effectful| try ignoredPeerDelay(effectful);
}

fn ignoredPeerDelay(comptime effectful: bool) !void {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const types = try hyper.pair(c, integer, integer, .{});
    const effect = try c.external("peer", integer, integer);
    const peer_schema = try c.callable(.{}, types.backward(), if (effectful) .{effect} else .{}, .{
        .use = .reusable,
        .captures = .{types.backward()},
    });
    const delayed = try c.declareSchema(.callable, hyper.Delayed(a.Shape(u64)));
    const participant_schema = try c.callable(.{ .peer = peer_schema }, delayed.schema(), .{}, .{
        .use = .reusable,
        .captures = .{delayed.schema()},
    });
    try c.defineCallable(delayed, .{}, integer, .{}, .{
        .use = .reusable,
        .captures = .{ participant_schema, peer_schema, integer },
    });
    const entry = try c.function("ignored peer", .{}, integer, .{});
    const body = try c.body(entry);
    const function = try c.functionFor("participant", participant_schema);
    const nested = try body.closureBody(function);
    try c.define(function, try nested.ret(try hyper.deferValue(
        nested,
        delayed.schema(),
        try nested.constant(u64, 42),
    )));
    const participant = try body.lambda(function, participant_schema);
    const answer = try hyper.deferValue(body, types.answerBackward(), try body.constant(u64, 23));
    const counterpart = try hyper.base(body, types.swap(), answer);
    const peer_function = try c.functionFor("peer", peer_schema);
    const peer_body = try body.closureBody(peer_function);
    try c.define(peer_function, try peer_body.ret(counterpart));
    const peer = try body.lambda(peer_function, peer_schema);
    if (effectful) return std.testing.expectError(
        error.SchemaMismatch,
        hyper.invoke(body, participant, peer),
    );
    const invoked = try hyper.invoke(body, participant, peer);
    try c.define(entry, try body.ret(try hyper.force(body, invoked)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper lazy products admit the canonical empty record" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const empty = try c.schema(struct {});
    const entry = try c.function("empty", .{}, empty, .{});
    const body = try c.body(entry);
    const value = try hyper.lazyProduct(body, .{});
    try std.testing.expect(@TypeOf(value) == *const a.Value(a.Shape(struct {})));
    try c.define(entry, try body.ret(value));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper runtime lazy rows preserve static emitted programs" {
    inline for (.{ false, true }) |sum| {
        const known = try lazyAggregateImage(false, sum);
        defer std.testing.allocator.free(known);
        const dynamic = try lazyAggregateImage(true, sum);
        defer std.testing.allocator.free(dynamic);
        try std.testing.expectEqualSlices(u8, known, dynamic);
    }
}

fn lazyAggregateImage(comptime runtime_rows: bool, comptime sum: bool) ![]u8 {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const entry = try c.function("lazy aggregate", .{}, integer, .{});
    const body = try c.body(entry);
    const good = try hyper.deferValue(body, delay, try body.constant(u64, 23));
    const failing = try c.functionFor("unforced", delay);
    const nested = try body.closureBody(failing);
    try c.define(failing, try nested.fail(integer, try nested.constant(void, {})));
    const bad = try body.lambda(failing, delay);
    const answer = if (sum) result: {
        const fields = if (runtime_rows) try a.interop.RuntimeNamed(.schema).init(c, &.{
            .{ .name = "good", .handle = a.interop.erase(delay) },
            .{ .name = "bad", .handle = a.interop.erase(delay) },
        }) else .{ .good = delay, .bad = delay };
        const value = try hyper.lazySum(body, try c.alternatives(fields), "bad", bad);
        try std.testing.expect((a.ShapeOf(@TypeOf(value)) == a.Dynamic) == runtime_rows);
        break :result try body.variantTag(value);
    } else result: {
        const fields = if (runtime_rows) try a.interop.RuntimeNamed(.value).init(c, &.{
            .{ .name = "good", .handle = a.interop.erase(good) },
            .{ .name = "bad", .handle = a.interop.erase(bad) },
        }) else .{ .good = good, .bad = bad };
        const value = try hyper.lazyProduct(body, fields);
        try std.testing.expect((a.ShapeOf(@TypeOf(value)) == a.Dynamic) == runtime_rows);
        break :result try hyper.force(body, try body.field(value, "good"));
    };
    try c.define(entry, try body.ret(answer));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
    const image = @import("horos_data").program_image;
    const bytes = try std.testing.allocator.alloc(u8, try image.encodedLength(compiled.program));
    errdefer std.testing.allocator.free(bytes);
    _ = try compiled.encode(std.testing.allocator, bytes);
    return bytes;
}

test "typed hyper lazy rows reject effectful unobserved members" {
    inline for (.{ false, true }) |runtime_rows| {
        inline for (.{ false, true }) |sum| try lazyAggregateEffects(runtime_rows, sum);
    }
}

fn lazyAggregateEffects(comptime runtime_rows: bool, comptime sum: bool) !void {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const effect = try c.external("effectful member", integer, integer);
    const task = try c.callable(.{}, integer, .{effect}, .{ .use = .reusable });
    const delay = try hyper.delayed(c, integer, .{});
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const good = try hyper.deferValue(body, delay, try body.constant(u64, 23));
    if (sum) {
        const fields = if (runtime_rows) try a.interop.RuntimeNamed(.schema).init(c, &.{
            .{ .name = "good", .handle = a.interop.erase(delay) },
            .{ .name = "bad", .handle = a.interop.erase(task) },
        }) else .{ .good = delay, .bad = task };
        const choices = try c.alternatives(fields);
        _ = try body.variant(choices, "good", good);
        try std.testing.expectError(
            error.SchemaMismatch,
            hyper.lazySum(body, choices, "good", good),
        );
    } else {
        const action = try c.functionFor("unobserved effect", task);
        const nested = try body.closureBody(action);
        try c.define(action, try nested.ret(try nested.constant(u64, 42)));
        const bad = try body.lambda(action, task);
        const fields = if (runtime_rows) try a.interop.RuntimeNamed(.value).init(c, &.{
            .{ .name = "good", .handle = a.interop.erase(good) },
            .{ .name = "bad", .handle = a.interop.erase(bad) },
        }) else .{ .good = good, .bad = bad };
        try std.testing.expectError(error.SchemaMismatch, hyper.lazyProduct(body, fields));
    }
}

test "typed hyper runtime lazy rows reject strict members" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const strict = try body.constant(u64, 23);
    const values = try a.interop.RuntimeNamed(.value).init(c, &.{
        .{ .name = "strict", .handle = a.interop.erase(strict) },
    });
    try std.testing.expectError(error.InvalidCategory, hyper.lazyProduct(body, values));
    const schemas = try a.interop.RuntimeNamed(.schema).init(c, &.{
        .{ .name = "good", .handle = a.interop.erase(delay) },
        .{ .name = "strict", .handle = a.interop.erase(integer) },
    });
    const good = try hyper.deferValue(body, delay, strict);
    try std.testing.expectError(error.InvalidCategory, hyper.lazySum(
        body,
        try c.alternatives(schemas),
        "good",
        good,
    ));
    try std.testing.expectError(
        error.InvalidCategory,
        hyper.lazySum(body, a.interop.erase(integer), "good", good),
    );
    const choices = try c.alternatives(try a.interop.RuntimeNamed(.schema).init(c, &.{
        .{ .name = "good", .handle = a.interop.erase(delay) },
    }));
    try std.testing.expectError(error.SchemaMismatch, hyper.lazySum(body, choices, "good", strict));
    try std.testing.expectError(error.UnknownName, hyper.lazySum(body, choices, "missing", good));
}

test "typed hyper runtime lazy rows preserve scope and lifecycle rejection" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const child = try c.function("child", .{}, delay, .{});
    const nested = try body.closureBody(child);
    const escaped = try hyper.deferValue(nested, delay, try nested.constant(u64, 23));
    const fields = try a.interop.RuntimeNamed(.value).init(c, &.{
        .{ .name = "escaped", .handle = a.interop.erase(escaped) },
    });
    try c.define(child, try nested.ret(escaped));
    try std.testing.expectError(error.OutOfScope, hyper.lazyProduct(body, fields));
    const schemas = try a.interop.RuntimeNamed(.schema).init(c, &.{
        .{ .name = "escaped", .handle = a.interop.erase(delay) },
    });
    const choices = try c.alternatives(schemas);
    try std.testing.expectError(error.OutOfScope, hyper.lazySum(body, choices, "escaped", escaped));
    const good = try hyper.deferValue(body, delay, try body.constant(u64, 42));
    const available = try a.interop.RuntimeNamed(.value).init(c, &.{
        .{ .name = "good", .handle = a.interop.erase(good) },
    });
    try c.define(entry, try body.ret(try body.constant(u64, 42)));
    try std.testing.expectError(error.ClosedBody, hyper.lazyProduct(body, available));
    try std.testing.expectError(error.ClosedBody, hyper.lazySum(body, choices, "escaped", good));
}

test "typed hyper runtime lazy products preserve empty rows and allocation failure cleanup" {
    try @import("../allocation_testing.zig").check(
        std.testing.allocator,
        runtimeLazyProductAllocation,
        .{},
    );
}

fn runtimeLazyProductAllocation(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const empty = try c.schema(struct {});
    const entry = try c.function("empty", .{}, empty, .{});
    const body = try c.body(entry);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const payload = try hyper.deferValue(body, delay, try body.constant(u64, 42));
    const populated = try a.interop.RuntimeNamed(.value).init(c, &.{
        .{ .name = "payload", .handle = a.interop.erase(payload) },
    });
    _ = try hyper.lazyProduct(body, populated);
    const fields = try a.interop.RuntimeNamed(.value).init(c, &.{});
    const value = try hyper.lazyProduct(body, fields);
    try std.testing.expect(@TypeOf(value) == *const a.Value(a.Dynamic));
    try c.define(entry, try body.ret(value));
}

test "typed hyper runtime lazy rows retain foreign and pending schema checks" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const delay = try hyper.delayed(c, integer, .{});
    const entry = try c.function("foreign", .{}, integer, .{});
    const body = try c.body(entry);
    const payload = try hyper.deferValue(body, delay, try body.constant(u64, 42));
    const values = try a.interop.RuntimeNamed(.value).init(c, &.{
        .{ .name = "payload", .handle = a.interop.erase(payload) },
    });
    const schemas = try a.interop.RuntimeNamed(.schema).init(c, &.{
        .{ .name = "payload", .handle = a.interop.erase(delay) },
    });
    const choices = try c.alternatives(schemas);
    var other_raw = source.Builder.init(std.testing.allocator);
    defer other_raw.deinit();
    const other = try a.Context.init(&other_raw);
    const other_entry = try other.function("entry", .{}, try other.schema(u64), .{});
    const other_body = try other.body(other_entry);
    try std.testing.expectError(error.ForeignHandle, hyper.lazyProduct(other_body, values));
    try std.testing.expectError(
        error.ForeignHandle,
        hyper.lazySum(other_body, choices, "payload", payload),
    );
    const pending = try c.declareSchema(.alternatives, a.Dynamic);
    try std.testing.expectError(
        error.UndefinedSchema,
        hyper.lazySum(body, pending.schema(), "payload", payload),
    );
}

test "typed hyper runtime lazy rows retain pure delays returning effectful tasks" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const effect = try c.external("task effect", integer, integer);
    const task = try c.callable(.{}, integer, .{effect}, .{ .use = .reusable });
    const delay = try hyper.delayed(c, task, .{ .captures = .{task} });
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const action = try c.functionFor("effectful task", task);
    const nested = try body.closureBody(action);
    try c.define(action, try nested.ret(try nested.perform(
        effect,
        try nested.constant(u64, 42),
    )));
    const payload = try hyper.deferValue(body, delay, try body.lambda(action, task));
    const fields = try a.interop.RuntimeNamed(.value).init(c, &.{
        .{ .name = "task", .handle = a.interop.erase(payload) },
    });
    const product = try hyper.lazyProduct(body, fields);
    const schemas = try a.interop.RuntimeNamed(.schema).init(c, &.{
        .{ .name = "task", .handle = a.interop.erase(delay) },
    });
    _ = try hyper.lazySum(body, try c.alternatives(schemas), "task", payload);
    const obtained = try hyper.force(body, try body.field(product, "task"));
    _ = try a.interop.refineValue(body, obtained, task);
    try c.define(entry, try body.ret(try body.constant(u64, 23)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper observations retain known answers through runtime pair selection" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const interfaces = try hyper.group(c, .{ .value = integer }, .{});
    const types = interfaces.get("value", "value");
    const from = try hyper.ir.from(interfaces, "value", "value");
    const selected = try hyper.ir.select(interfaces, "value", "value");
    const entry = try c.function("selected", .{}, integer, .{});
    const body = try c.body(entry);
    const answer = try hyper.deferValue(body, types.answerForward(), try body.constant(u64, 42));
    const participant = try hyper.base(body, types, answer);
    const Answer = *const a.Value(hyper.Delayed(a.Shape(u64)));
    const projected = try hyper.project(body, from, participant, answer);
    try std.testing.expect(@TypeOf(projected) == Answer);
    try std.testing.expect(
        @TypeOf(try hyper.project(body, selected, participant, answer)) == Answer,
    );
    try std.testing.expect(@TypeOf(try hyper.run(body, from, participant)) == Answer);
    try std.testing.expect(@TypeOf(try hyper.run(body, selected, participant)) == Answer);
    const erased = a.interop.erase(participant);
    const UnknownAnswer = *const a.Value(hyper.Delayed(a.Dynamic));
    try std.testing.expect(
        @TypeOf(try hyper.project(body, types, erased, answer)) == UnknownAnswer,
    );
    try std.testing.expect(@TypeOf(try hyper.run(body, types, erased)) == UnknownAnswer);
    const partial = try a.interop.refineValue(body, participant, from.forward());
    try std.testing.expect(
        @TypeOf(try hyper.project(body, types, partial, answer)) == UnknownAnswer,
    );
    try std.testing.expect(@TypeOf(try hyper.run(body, types, partial)) == UnknownAnswer);
    try c.define(entry, try body.ret(try hyper.force(body, projected)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

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

test "typed hyper Need resource states require ownership only when suspended for reuse" {
    inline for (.{ false, true }) |reusable| {
        var raw = source.Builder.init(std.testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const unit = try c.schema(void);
        const owned = try c.resource(unit);
        const need = try hyper.demand.family(c, "resource", owned, unit);
        if (reusable) _ = try hyper.delayed(c, need.state(), .{ .captures = .{need.state()} });
        const entry = try c.function("entry", .{}, unit, .{});
        const body = try c.body(entry);
        try c.define(entry, try body.ret(try body.constant(void, {})));
        if (reusable) {
            try std.testing.expectError(error.InvalidOwnership, c.compile(
                std.testing.allocator,
                entry,
                unit,
            ));
        } else {
            var compiled = try c.compile(std.testing.allocator, entry, unit);
            compiled.deinit();
        }
    }
}

test "typed hyper Need transfers linear callable states through ordinary handlers" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const task = try c.callable(.{}, unit, .{}, .{ .use = .linear });
    const need = try hyper.demand.family(c, "linear", task, unit);
    const handler = try c.handler(need.effect(), unit, unit, .{
        .use = .linear,
        .mode = .deep,
        .captures = .{need.capability()},
        .body_captures = .{task},
        .return_effects = .{},
    });
    const returns = try c.returnFunction(handler);
    const return_body = try c.body(returns);
    try c.define(returns, try return_body.ret(try return_body.parameter("result")));
    const clause = try c.clauseFunction(handler);
    const clause_body = try c.body(clause);
    const contribution = try clause_body.apply(try clause_body.parameter("payload"), .{});
    const resumed = try clause_body.resumeValue(
        try clause_body.parameter("resumption"),
        contribution,
    );
    try c.define(clause, try clause_body.ret(resumed));
    const thunk = try c.functionFor("payload", task);
    const thunk_body = try c.body(thunk);
    try c.define(thunk, try thunk_body.ret(try thunk_body.constant(void, {})));
    const entry = try c.function("entry", .{}, unit, .{});
    const body = try c.body(entry);
    const value = try body.lambda(thunk, task);
    const schema = try c.handledSchema(handler);
    const work = try c.functionFor("work", schema);
    const work_body = try body.closureBody(work);
    const result = try hyper.demand.request(
        work_body,
        need,
        try work_body.parameter("capability"),
        value,
    );
    try c.define(work, try work_body.ret(result));
    try c.define(entry, try body.ret(try body.handleWith(
        handler,
        try body.lambda(work, schema),
        .{},
    )));
    var compiled = try c.compile(std.testing.allocator, entry, unit);
    defer compiled.deinit();
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
    const interfaces = try hyper.group(c, .{
        .left = try c.schema(Left),
        .right = try c.schema(Right),
    }, .{});
    const types = interfaces.get("left", "right");
    const selected = try hyper.ir.select(interfaces, "left", "right");
    const entry = try c.function("aliases", .{}, try c.schema(Left), .{});
    const body = try c.body(entry);
    const value = try body.product(try c.schema(Left), .{
        .answer = try body.constant(u64, 42),
    });
    const answer = try hyper.deferValue(body, types.answerForward(), value);
    const participant = try hyper.base(body, types, answer);
    const input = try hyper.deferValue(body, types.answerBackward(), value);
    const projected = try hyper.project(body, selected, participant, input);
    try std.testing.expect(@TypeOf(projected) == *const a.Value(hyper.Delayed(a.Shape(Left))));
    const result = try hyper.force(body, projected);
    try c.define(entry, try body.ret(result));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper selected observations preserve effectful task answer layers" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const effect = try c.external("task", integer, integer);
    const task = try c.callable(.{}, integer, .{effect}, .{ .use = .reusable });
    const interfaces = try hyper.group(c, .{ .task = task }, .{});
    const types = interfaces.get("task", "task");
    const selected = try hyper.ir.select(interfaces, "task", "task");
    const function = try c.functionFor("task", task);
    const task_body = try c.body(function);
    try c.define(function, try task_body.ret(try task_body.perform(
        effect,
        try task_body.constant(u64, 42),
    )));
    const entry = try c.function("entry", .{}, integer, .{effect});
    const body = try c.body(entry);
    const value = try body.lambda(function, task);
    const answer = try hyper.deferValue(body, types.answerForward(), value);
    const participant = try hyper.base(body, types, answer);
    const projected = try hyper.project(body, selected, participant, answer);
    const run = try hyper.run(body, selected, participant);
    const Answer = *const a.Value(hyper.Delayed(a.ShapeOf(@TypeOf(task))));
    try std.testing.expect(@TypeOf(projected) == Answer);
    try std.testing.expect(@TypeOf(run) == Answer);
    const forced = try hyper.force(body, projected);
    try std.testing.expect(@TypeOf(forced) == @TypeOf(value));
    try c.define(entry, try body.ret(try body.apply(forced, .{})));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "typed hyper selected observations reject incompatible actual capture graphs" {
    inline for (.{ false, true }) |run| {
        var raw = source.Builder.init(std.testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const integer = try c.schema(u64);
        const narrow = try hyper.group(c, .{ .value = integer }, .{});
        const other = try hyper.group(c, .{ .value = integer }, .{
            .captures = .{try c.schema(bool)},
        });
        const types = narrow.get("value", "value");
        const selected = try hyper.ir.select(other, "value", "value");
        const entry = try c.function("entry", .{}, integer, .{});
        const body = try c.body(entry);
        const answer = try hyper.deferValue(
            body,
            types.answerForward(),
            try body.constant(u64, 42),
        );
        const participant = try hyper.base(body, types, answer);
        const observed = if (run)
            hyper.run(body, selected, participant)
        else
            hyper.project(body, selected, participant, answer);
        try std.testing.expectError(error.SchemaMismatch, observed);
    }
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
