// Copyright (c) 2026 Boundary contributors. MIT license.
//! FIFO policy is ordinary recursive code over an owned package queue.
const std = @import("std");
const source = @import("../../source.zig");
const a = @import("../../authoring/runtime.zig");
const generator = @import("generator.zig");
const p = @import("horos_data").program;
pub const Scheduler = struct {
    queue: *const a.Schema,
    enqueue: *const a.Function,
    drain: *const a.Function,
};
const CachedScheduler = struct { enqueue: p.Id, drain: p.Id };

fn regionIds(c: *a.Context, regions: []const *const a.Region) a.Error![]const p.Id {
    const ids = try a.interop.builder(c).allocator().alloc(p.Id, regions.len);
    for (regions, ids) |region, *id| id.* = try a.interop.regionId(c, region);
    return ids;
}
pub fn fifo(
    c: *a.Context,
    tasks: *const generator.Exchange,
    residual: []const *const a.Operation,
    regions: []const *const a.Region,
) a.Error!Scheduler {
    const b = a.interop.builder(c);
    const unit = try c.scalar(void);
    const unit_id = try a.interop.schemaId(c, unit);
    if (try a.interop.schemaId(c, tasks.input()) != unit_id or try a.interop.schemaId(
        c,
        tasks.result(),
    ) != unit_id) return error.TypeMismatch;
    const effects = try b.allocator().alloc(p.Id, residual.len);
    for (residual, effects) |effect, *id| id.* = try a.interop.operationId(c, effect);
    const instance = try b.specialization(
        CachedScheduler,
        "boundary.library.scheduler/fifo/typed-v1",
        .{ @intFromPtr(c), @intFromPtr(tasks), effects, try regionIds(c, regions) },
    );
    const queue = try c.sequence(tasks.package());
    if (instance.cached) |value| return .{
        .queue = queue,
        .enqueue = try a.interop.declaredFunction(c, value.enqueue),
        .drain = try a.interop.declaredFunction(c, value.drain),
    };
    const enqueue_schema = try c.callable(
        &.{ .{ .name = "step", .schema = tasks.answer() }, .{ .name = "queue", .schema = queue } },
        queue,
        &.{},
        .{ .use = .reusable, .captures = &.{}, .regions = regions },
    );
    const enqueue = try c.functionFor("enqueue", enqueue_schema);
    const push = try c.body(enqueue);
    const step = try push.parameter("step");
    const prior = try push.parameter("queue");
    const done = try push.caseOf(step, "done");
    const yielded = try push.caseOf(step, "yielded");
    const parts = try yielded.body().destructure(yielded.payload());
    const appended = try yielded.body().append(prior, try parts.get("future"));
    try c.define(
        enqueue,
        try push.ret(try push.match(step, &.{ try done.ret(prior), try yielded.ret(appended) })),
    );
    const drain_schema = try c.callable(
        &.{.{ .name = "queue", .schema = queue }},
        unit,
        residual,
        .{ .use = .reusable, .captures = &.{}, .regions = regions },
    );
    const drain = try c.functionFor("drain", drain_schema);
    const body = try c.body(drain);
    const popped = try body.pop(try body.parameter("queue"));
    const empty = try body.caseOf(popped, "empty");
    const ready = try body.caseOf(popped, "item");
    const item = try ready.body().destructure(ready.payload());
    const resumed = try ready.body().resumePackage(
        try item.get("head"),
        try ready.body().constant(void, {}),
    );
    const next_queue = try ready.body().call(
        enqueue,
        &.{
            .{ .name = "step", .value = resumed },
            .{ .name = "queue", .value = try item.get("tail") },
        },
    );
    const drained = try ready.body().call(drain, &.{.{ .name = "queue", .value = next_queue }});
    try c.define(
        drain,
        try body.ret(try body.match(
            popped,
            &.{ try empty.ret(try empty.body().constant(void, {})), try ready.ret(drained) },
        )),
    );
    _ = try instance.finish(
        b,
        .{
            .enqueue = try a.interop.functionId(c, enqueue),
            .drain = try a.interop.functionId(c, drain),
        },
    );
    return .{ .queue = queue, .enqueue = enqueue, .drain = drain };
}

pub const Join = opaque {
    pub fn state(self: *const Join) *const a.Schema {
        return joinData(self).state;
    }
    pub fn cell(self: *const Join) *const a.Schema {
        return joinData(self).cell;
    }
};
const JoinData = struct {
    owner: *a.Context,
    value: *const a.Schema,
    state: *const a.Schema,
    cell: *const a.Schema,
};
fn joinData(join: *const Join) *const JoinData {
    return @ptrCast(@alignCast(join));
}
pub fn joinType(
    c: *a.Context,
    result: *const a.Schema,
    region: *const a.Region,
) a.Error!*const Join {
    const state = try c.alternatives(&.{
        .{ .name = "pending", .schema = try c.scalar(void) },
        .{ .name = "done", .schema = result },
    });
    const cell = try c.cell(region, state);
    const saved = try a.interop.builder(c).allocator().create(JoinData);
    saved.* = .{ .owner = c, .value = result, .state = state, .cell = cell };
    return @ptrCast(saved);
}

pub fn awaiting(
    c: *a.Context,
    tasks: *const generator.Exchange,
    join: *const Join,
    regions: []const *const a.Region,
) a.Error!*const a.Function {
    const b = a.interop.builder(c);
    const j = joinData(join);
    if (j.owner != c) return error.ForeignHandle;
    if (try a.interop.schemaId(c, tasks.element()) != try a.interop.schemaId(c, try c.scalar(void))) return error.TypeMismatch;
    const instance = try b.specialization(
        p.Id,
        "boundary.library.scheduler/await/typed-v1",
        .{ @intFromPtr(c), @intFromPtr(tasks), @intFromPtr(j.cell), try regionIds(c, regions) },
    );
    if (instance.cached) |value| return a.interop.declaredFunction(c, value);
    const operation = tasks.effect();
    const schema = try c.callable(
        &.{
            .{ .name = "cell", .schema = j.cell },
            .{ .name = "capability", .schema = tasks.capability() },
        },
        j.value,
        &.{operation},
        .{ .use = .reusable, .captures = &.{}, .regions = regions },
    );
    const function = try c.functionFor("await join", schema);
    const body = try c.body(function);
    const target = try body.parameter("cell");
    const cap = try body.parameter("capability");
    const value = try body.readCell(target);
    const pending = try body.caseOf(value, "pending");
    const done = try body.caseOf(value, "done");
    _ = try pending.body().performLocal(operation, cap, try pending.body().constant(void, {}));
    const retry = try pending.body().call(
        function,
        &.{ .{ .name = "cell", .value = target }, .{ .name = "capability", .value = cap } },
    );
    try c.define(
        function,
        try body.ret(try body.match(
            value,
            &.{ try pending.ret(retry), try done.ret(done.payload()) },
        )),
    );
    _ = try instance.finish(b, try a.interop.functionId(c, function));
    return function;
}

pub fn complete(
    body: *a.Body,
    join: *const Join,
    cell: *const a.Value,
    result: *const a.Value,
) a.Error!*const a.Value {
    return body.writeCell(cell, try body.variant(join.state(), "done", result));
}

fn constructionCase(allocator: std.mem.Allocator) !void {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const unit = try c.scalar(void);
    const integer = try c.scalar(u64);
    const region = try c.region();
    const tasks = try generator.create(
        c,
        "scheduler/allocation",
        unit,
        unit,
        unit,
        .{ .captures = .{ .continuation = &.{ unit, integer } }, .borrowed_regions = &.{region} },
    );
    const join = try joinType(c, integer, region);
    const scheduler = try fifo(c, tasks, &.{}, &.{region});
    const waiter = try awaiting(c, tasks, join, &.{region});
    const count = b.functions.items.len;
    for (0..64) |_| {
        try std.testing.expectEqual(scheduler.drain, (try fifo(c, tasks, &.{}, &.{region})).drain);
        try std.testing.expectEqual(waiter, try awaiting(c, tasks, join, &.{region}));
        try std.testing.expectEqual(
            waiter,
            try awaiting(c, tasks, try joinType(c, integer, region), &.{region}),
        );
    }
    try std.testing.expectEqual(count, b.functions.items.len);
}
test "typed scheduler construction shares definitions" {
    try constructionCase(std.testing.allocator);
}
test "FIFO requires unit input and unit completion" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const unit = try c.scalar(void);
    const integer = try c.scalar(u64);
    const input = try generator.create(
        c,
        "scheduler/input",
        integer,
        unit,
        unit,
        .{ .captures = .{ .continuation = &.{} } },
    );
    const result = try generator.create(
        c,
        "scheduler/result",
        unit,
        unit,
        integer,
        .{ .captures = .{ .continuation = &.{} } },
    );
    try std.testing.expectError(error.TypeMismatch, fifo(c, input, &.{}, &.{}));
    try std.testing.expectError(error.TypeMismatch, fifo(c, result, &.{}, &.{}));
    const foreign = try a.Context.init(&b);
    try std.testing.expectError(error.ForeignHandle, fifo(foreign, input, &.{}, &.{}));
    const valid = try generator.create(
        c,
        "scheduler/valid",
        unit,
        unit,
        unit,
        .{ .captures = .{ .continuation = &.{} } },
    );
    try std.testing.expectError(
        error.ForeignHandle,
        fifo(c, valid, &.{}, &.{try foreign.region()}),
    );
}
