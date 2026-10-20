// Copyright (c) 2026 Boundary contributors. MIT license.
//! Two tasks, an actual pending join, and FIFO execution use typed authoring.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const generator = @import("../library/generator.zig");
const scheduler = @import("../library/scheduler.zig");
const writer = @import("../library/writer.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    return authored(b) catch |err| return a.sourceError(err);
}
fn authored(b: *source.Builder) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const region = try c.region();
    const join = try scheduler.joinType(c, integer, region);
    const logging = try writer.family(c, "example/task-log", integer);
    const tasks = try generator.create(c, "example/task-yield", unit, unit, unit, .{
        .captures = .{
            .continuation = &.{ unit, integer, join.cell(), logging.capability() },
            .body = &.{ join.cell(), logging.capability() },
        },
        .borrowed_regions = &.{region},
        .residual = &.{logging.effect()},
        .body_use = .reusable,
    });
    const fifo = try scheduler.fifo(c, tasks, &.{logging.effect()}, &.{region});
    const await_join = try scheduler.awaiting(c, tasks, join, &.{region});
    const written = try writer.interpret(c, logging, integer, region, .{
        .continuation = &.{
            unit,
            integer,
            join.cell(),
            tasks.capability(),
            tasks.package(),
            tasks.answer(),
            tasks.yielded(),
            fifo.queue,
        },
        .body = &.{try c.regionSchema(region)},
    }, &.{});
    const main_fn = try c.function("entry", .{}, written.answer, &.{});
    const main_body = try c.body(main_fn);
    const inside_type = try c.regionBodySchema(
        region,
        .{},
        written.answer,
        &.{},
        .{ .use = .reusable, .captures = &.{} },
    );
    const inside_fn = try c.functionFor("scheduler region", inside_type);
    const inside = try c.body(inside_fn);
    const token = try inside.parameter("region");
    const body_type = try c.handledSchema(written.handler);
    const body_fn = try c.functionFor("scheduled work", body_type);
    const body = try inside.closureBody(body_fn);
    const log = try body.parameter("capability");
    const empty = try body.variant(join.state(), "pending", try body.constant(void, {}));
    const first_join = try body.newCell(join.cell(), token, empty);
    const second_join = try body.newCell(join.cell(), token, empty);
    const task_type = try c.handledSchema(tasks.handler());
    const first_fn = try c.functionFor("first task", task_type);
    const first = try body.closureBody(first_fn);
    const first_cap = try first.parameter("capability");
    _ = try first.performLocal(logging.effect(), log, try first.constant(u64, 1));
    _ = try first.performLocal(tasks.effect(), first_cap, try first.constant(void, {}));
    _ = try first.performLocal(logging.effect(), log, try first.constant(u64, 3));
    _ = try first.performLocal(tasks.effect(), first_cap, try first.constant(void, {}));
    try c.define(
        first_fn,
        try first.ret(try scheduler.complete(
            first,
            join,
            first_join,
            try first.constant(u64, 10),
        )),
    );
    const second_fn = try c.functionFor("second task", task_type);
    const second = try body.closureBody(second_fn);
    const second_cap = try second.parameter("capability");
    _ = try second.performLocal(logging.effect(), log, try second.constant(u64, 2));
    _ = try second.performLocal(tasks.effect(), second_cap, try second.constant(void, {}));
    const joined = try second.call(await_join, .{ .cell = first_join, .capability = second_cap });
    _ = try second.performLocal(logging.effect(), log, try second.constant(u64, 4));
    const doubled = try second.checked(
        .multiply,
        joined,
        try second.constant(u64, 2),
        .{ .overflow = try c.literalFailure(void, {}) },
    );
    try c.define(
        second_fn,
        try second.ret(try scheduler.complete(second, join, second_join, doubled)),
    );
    const first_step = try body.handleWith(
        tasks.handler(),
        try body.lambda(first_fn, task_type),
        .{},
    );
    const first_queue = try body.call(
        fifo.enqueue,
        .{ .step = first_step, .queue = try body.sequenceValue(fifo.queue, &.{}) },
    );
    const second_step = try body.handleWith(
        tasks.handler(),
        try body.lambda(second_fn, task_type),
        .{},
    );
    const queue = try body.call(fifo.enqueue, .{ .step = second_step, .queue = first_queue });
    _ = try body.yieldNow();
    _ = try body.call(fifo.drain, .{ .queue = queue });
    const read_type = try c.callable(
        .{ .cell = join.cell() },
        integer,
        &.{},
        .{ .use = .reusable, .captures = &.{}, .regions = &.{region} },
    );
    const read_fn = try c.functionFor("read completed join", read_type);
    const read = try c.body(read_fn);
    const value = try read.readCell(try read.parameter("cell"));
    const pending = try read.caseOf(value, "pending");
    const done = try read.caseOf(value, "done");
    try c.define(
        read_fn,
        try read.ret(try read.match(
            value,
            .{
                .pending = try pending.fail(integer, try pending.body().constant(void, {})),
                .done = try done.ret(done.payload()),
            },
        )),
    );
    const first_value = try body.call(read_fn, .{ .cell = first_join });
    const second_value = try body.call(read_fn, .{ .cell = second_join });
    try c.define(
        body_fn,
        try body.ret(try body.checkedAdd(
            first_value,
            second_value,
            try c.literalFailure(void, {}),
        )),
    );
    const log_cell = try inside.newCell(
        written.cell,
        token,
        try inside.sequenceValue(written.sequence, &.{}),
    );
    try c.define(
        inside_fn,
        try inside.ret(try inside.handleWith(
            written.handler,
            try inside.lambda(body_fn, body_type),
            .{ .log = log_cell },
        )),
    );
    try c.define(
        main_fn,
        try main_body.ret(try main_body.withRegion(
            region,
            try main_body.lambda(inside_fn, inside_type),
            .{},
        )),
    );
    return c.module(main_fn, unit);
}
