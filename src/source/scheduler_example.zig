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
    return declareScheduledWork(.{
        .c = c,
        .unit = unit,
        .integer = integer,
        .region = region,
        .join = join,
        .logging = logging,
        .tasks = tasks,
        .fifo = fifo,
        .await_join = await_join,
        .written = written,
    });
}

fn declareScheduledWork(
    ctx: anytype,
) a.Error!source.Module {
    const main_fn = try ctx.c.function("entry", .{}, ctx.written.answer, &.{});
    const main_body = try ctx.c.body(main_fn);
    const inside_type = try ctx.c.regionBodySchema(
        ctx.region,
        .{},
        ctx.written.answer,
        &.{},
        .{ .use = .reusable, .captures = &.{} },
    );
    const inside_fn = try ctx.c.functionFor("scheduler region", inside_type);
    const inside = try ctx.c.body(inside_fn);
    const token = try inside.parameter("region");
    const body_type = try ctx.c.handledSchema(ctx.written.handler);
    const body_fn = try ctx.c.functionFor("scheduled work", body_type);
    const body = try inside.closureBody(body_fn);
    const log = try body.parameter("capability");
    const empty = try body.variant(ctx.join.state(), "pending", try body.constant(void, {}));
    const first_join = try body.newCell(ctx.join.cell(), token, empty);
    const second_join = try body.newCell(ctx.join.cell(), token, empty);
    const task_type = try ctx.c.handledSchema(ctx.tasks.handler());
    return defineTasks(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .region = ctx.region,
        .join = ctx.join,
        .logging = ctx.logging,
        .tasks = ctx.tasks,
        .fifo = ctx.fifo,
        .await_join = ctx.await_join,
        .written = ctx.written,
        .main_fn = main_fn,
        .main_body = main_body,
        .inside_type = inside_type,
        .inside_fn = inside_fn,
        .inside = inside,
        .token = token,
        .body_type = body_type,
        .body_fn = body_fn,
        .body = body,
        .log = log,
        .first_join = first_join,
        .second_join = second_join,
        .task_type = task_type,
    });
}

fn defineTasks(
    ctx: anytype,
) a.Error!source.Module {
    const first_fn = try ctx.c.functionFor("first task", ctx.task_type);
    const first = try ctx.body.closureBody(first_fn);
    const first_cap = try first.parameter("capability");
    _ = try first.performLocal(ctx.logging.effect(), ctx.log, try first.constant(u64, 1));
    _ = try first.performLocal(ctx.tasks.effect(), first_cap, try first.constant(void, {}));
    _ = try first.performLocal(ctx.logging.effect(), ctx.log, try first.constant(u64, 3));
    _ = try first.performLocal(ctx.tasks.effect(), first_cap, try first.constant(void, {}));
    try ctx.c.define(
        first_fn,
        try first.ret(try scheduler.complete(
            first,
            ctx.join,
            ctx.first_join,
            try first.constant(u64, 10),
        )),
    );
    const second_fn = try ctx.c.functionFor("second task", ctx.task_type);
    const second = try ctx.body.closureBody(second_fn);
    const second_cap = try second.parameter("capability");
    _ = try second.performLocal(ctx.logging.effect(), ctx.log, try second.constant(u64, 2));
    _ = try second.performLocal(ctx.tasks.effect(), second_cap, try second.constant(void, {}));
    const joined = try second.call(
        ctx.await_join,
        .{ .cell = ctx.first_join, .capability = second_cap },
    );
    _ = try second.performLocal(ctx.logging.effect(), ctx.log, try second.constant(u64, 4));
    const doubled = try second.checked(
        .multiply,
        joined,
        try second.constant(u64, 2),
        .{ .overflow = try ctx.c.literalFailure(void, {}) },
    );
    try ctx.c.define(
        second_fn,
        try second.ret(try scheduler.complete(second, ctx.join, ctx.second_join, doubled)),
    );
    return drainTasks(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .region = ctx.region,
        .join = ctx.join,
        .tasks = ctx.tasks,
        .fifo = ctx.fifo,
        .written = ctx.written,
        .main_fn = ctx.main_fn,
        .main_body = ctx.main_body,
        .inside_type = ctx.inside_type,
        .inside_fn = ctx.inside_fn,
        .inside = ctx.inside,
        .token = ctx.token,
        .body_type = ctx.body_type,
        .body_fn = ctx.body_fn,
        .body = ctx.body,
        .first_join = ctx.first_join,
        .second_join = ctx.second_join,
        .task_type = ctx.task_type,
        .first_fn = first_fn,
        .second_fn = second_fn,
    });
}

fn drainTasks(
    ctx: anytype,
) a.Error!source.Module {
    const first_step = try ctx.body.handleWith(
        ctx.tasks.handler(),
        try ctx.body.lambda(ctx.first_fn, ctx.task_type),
        .{},
    );
    const first_queue = try ctx.body.call(
        ctx.fifo.enqueue,
        .{ .step = first_step, .queue = try ctx.body.sequenceValue(ctx.fifo.queue, &.{}) },
    );
    const second_step = try ctx.body.handleWith(
        ctx.tasks.handler(),
        try ctx.body.lambda(ctx.second_fn, ctx.task_type),
        .{},
    );
    const queue = try ctx.body.call(
        ctx.fifo.enqueue,
        .{ .step = second_step, .queue = first_queue },
    );
    _ = try ctx.body.yieldNow();
    _ = try ctx.body.call(ctx.fifo.drain, .{ .queue = queue });
    const read_type = try ctx.c.callable(
        .{ .cell = ctx.join.cell() },
        ctx.integer,
        &.{},
        .{ .use = .reusable, .captures = &.{}, .regions = &.{ctx.region} },
    );
    const read_fn = try ctx.c.functionFor("read completed join", read_type);
    const read = try ctx.c.body(read_fn);
    const value = try read.readCell(try read.parameter("cell"));
    const pending = try read.caseOf(value, "pending");
    const done = try read.caseOf(value, "done");
    try ctx.c.define(
        read_fn,
        try read.ret(try read.match(
            value,
            .{
                .pending = try pending.fail(ctx.integer, try pending.body().constant(void, {})),
                .done = try done.ret(done.payload()),
            },
        )),
    );
    return finishScheduler(.{
        .c = ctx.c,
        .unit = ctx.unit,
        .region = ctx.region,
        .written = ctx.written,
        .main_fn = ctx.main_fn,
        .main_body = ctx.main_body,
        .inside_type = ctx.inside_type,
        .inside_fn = ctx.inside_fn,
        .inside = ctx.inside,
        .token = ctx.token,
        .body_type = ctx.body_type,
        .body_fn = ctx.body_fn,
        .body = ctx.body,
        .first_join = ctx.first_join,
        .second_join = ctx.second_join,
        .read_fn = read_fn,
    });
}

fn finishScheduler(
    ctx: anytype,
) a.Error!source.Module {
    const first_value = try ctx.body.call(ctx.read_fn, .{ .cell = ctx.first_join });
    const second_value = try ctx.body.call(ctx.read_fn, .{ .cell = ctx.second_join });
    try ctx.c.define(
        ctx.body_fn,
        try ctx.body.ret(try ctx.body.checkedAdd(
            first_value,
            second_value,
            try ctx.c.literalFailure(void, {}),
        )),
    );
    const log_cell = try ctx.inside.newCell(
        ctx.written.cell,
        ctx.token,
        try ctx.inside.sequenceValue(ctx.written.sequence, &.{}),
    );
    try ctx.c.define(
        ctx.inside_fn,
        try ctx.inside.ret(try ctx.inside.handleWith(
            ctx.written.handler,
            try ctx.inside.lambda(ctx.body_fn, ctx.body_type),
            .{ .log = log_cell },
        )),
    );
    try ctx.c.define(
        ctx.main_fn,
        try ctx.main_body.ret(try ctx.main_body.withRegion(
            ctx.region,
            try ctx.main_body.lambda(ctx.inside_fn, ctx.inside_type),
            .{},
        )),
    );
    return ctx.c.module(ctx.main_fn, ctx.unit);
}
