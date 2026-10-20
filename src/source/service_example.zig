//! A non-reentrant counter service built from the existing owned exchange.
//! The environment supplies FIFO commands; only the driver owns the next turn.
//! There is no batch-size bound. Completion requires a finite batch ending in close.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const gen = @import("../library/generator.zig");

pub fn build(b: *source.Builder) source.Error!source.Module {
    return authored(b, false, false) catch |err| return a.sourceError(err);
}

/// Same state transitions, but IDs 1 and 2 receive each other's replies.
/// This deliberately invalid contract remains a well-typed ordinary program.
pub fn swappedReplies(b: *source.Builder) source.Error!source.Module {
    return authored(b, true, false) catch |err| return a.sourceError(err);
}

pub fn twoInstances(b: *source.Builder) source.Error!source.Module {
    return authored(b, false, true) catch |err| return a.sourceError(err);
}

fn authored(
    b: *source.Builder,
    comptime swap_replies: bool,
    comptime paired: bool,
) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const request = try c.record(.{ .id = integer, .delta = integer });
    const command = try c.alternatives(.{ .serve = request, .close = unit });
    const reply = try c.record(.{ .id = integer, .previous = integer });
    const output = try c.alternatives(.{ .ready = unit, .reply = reply });
    const region = try c.region();
    const cell_type = try c.cell(region, integer);
    const receive = try c.external("example/service-command", unit, command);
    const send = try c.external("example/service-reply", reply, unit);
    const release = try c.external("example/service-finalize", integer, unit);
    const service = try gen.create(c, "example/service-turn", command, output, integer, .{
        .captures = .{ .continuation = &.{
            unit,
            integer,
            request,
            command,
            reply,
            output,
            cell_type,
        } },
        .owned_regions = &.{region},
        .residual = &.{release},
        .body_use = .reusable,
    });

    return defineRequestWorker(swap_replies, paired, .{
        .c = c,
        .unit = unit,
        .integer = integer,
        .command = command,
        .reply = reply,
        .output = output,
        .region = region,
        .cell_type = cell_type,
        .receive = receive,
        .send = send,
        .release = release,
        .service = service,
    });
}

fn defineRequestWorker(
    comptime swap_replies: bool,
    comptime paired: bool,
    ctx: anytype,
) a.Error!source.Module {
    // A direct recursive worker owns no independent state authority. Its cell
    // and explicit capability exist only inside the generator's owned region.
    const work_type = try ctx.c.callable(.{
        .command = ctx.command,
        .state = ctx.cell_type,
        .capability = ctx.service.capability(),
    }, ctx.integer, &.{ctx.service.effect()}, .{
        .use = .reusable,
        .captures = &.{},
        .regions = &.{ctx.region},
    });
    const work_fn = try ctx.c.functionFor("service request", work_type);
    const work = try ctx.c.body(work_fn);
    const input = try work.parameter("command");
    const state = try work.parameter("state");
    const capability = try work.parameter("capability");
    const closing = try work.caseOf(input, "close");
    const serving = try work.caseOf(input, "serve");
    const turn = serving.body();
    const id = try turn.field(serving.payload(), "id");
    const delta = try turn.field(serving.payload(), "delta");
    const before = try turn.readCell(state);
    const after = try turn.checkedAdd(before, delta, try ctx.c.literalFailure(void, {}));
    _ = try turn.writeCell(state, after);
    // The driver has no package while this suffix is running or suspended.
    // A second command cannot enter until the reply returns its successor.
    _ = try turn.yieldNow();
    const reply_id = if (swap_replies) try turn.bitwise(
        .xor,
        id,
        try turn.constant(u64, 3),
    ) else id;
    const response = try turn.product(ctx.reply, .{ .id = reply_id, .previous = before });
    const next = try turn.performLocal(
        ctx.service.effect(),
        capability,
        try turn.variant(ctx.output, "reply", response),
    );
    const continued = try turn.call(
        work_fn,
        .{ .command = next, .state = state, .capability = capability },
    );
    try ctx.c.define(work_fn, try work.ret(try work.match(input, .{
        .serve = try serving.ret(continued),
        .close = try closing.ret(try closing.body().readCell(state)),
    })));

    return defineProducer(paired, .{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .output = ctx.output,
        .region = ctx.region,
        .cell_type = ctx.cell_type,
        .receive = ctx.receive,
        .send = ctx.send,
        .release = ctx.release,
        .service = ctx.service,
        .work_fn = work_fn,
    });
}

fn defineProducer(
    comptime paired: bool,
    ctx: anytype,
) a.Error!source.Module {
    const producer_type = try ctx.c.handledSchema(ctx.service.handler());
    const producer_fn = try ctx.c.functionFor("service producer", producer_type);
    const producer = try ctx.c.body(producer_fn);
    const producer_cap = try producer.parameter("capability");
    const private_type = try ctx.c.regionBodySchema(ctx.region, .{}, ctx.integer, &.{
        ctx.service.effect(),
        ctx.release,
    }, .{ .use = .reusable, .captures = &.{ctx.service.capability()} });
    const private_fn = try ctx.c.functionFor("service state", private_type);
    const private = try producer.closureBody(private_fn);
    const cell = try private.newCell(
        ctx.cell_type,
        try private.parameter("region"),
        try private.constant(u64, 0),
    );
    const body_type = try ctx.c.callable(.{}, ctx.integer, &.{ctx.service.effect()}, .{
        .use = .reusable,
        .captures = &.{ ctx.service.capability(), ctx.cell_type },
        .regions = &.{ctx.region},
    });
    const body_fn = try ctx.c.functionFor("service exchange", body_type);
    const body = try private.closureBody(body_fn);
    const first = try body.performLocal(
        ctx.service.effect(),
        producer_cap,
        try body.variant(ctx.output, "ready", try body.constant(void, {})),
    );
    try ctx.c.define(
        body_fn,
        try body.ret(try body.call(
            ctx.work_fn,
            .{ .command = first, .state = cell, .capability = producer_cap },
        )),
    );
    return protectProducer(paired, .{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .region = ctx.region,
        .cell_type = ctx.cell_type,
        .receive = ctx.receive,
        .send = ctx.send,
        .release = ctx.release,
        .service = ctx.service,
        .producer_type = producer_type,
        .producer_fn = producer_fn,
        .producer = producer,
        .private_type = private_type,
        .private_fn = private_fn,
        .private = private,
        .cell = cell,
        .body_type = body_type,
        .body_fn = body_fn,
    });
}

fn protectProducer(
    comptime paired: bool,
    ctx: anytype,
) a.Error!source.Module {
    const cleanup_type = try ctx.c.callable(
        .{ .exit = try ctx.c.cleanupInfo(ctx.unit) },
        ctx.unit,
        &.{ctx.release},
        .{
            .use = .reusable,
            .captures = &.{ctx.cell_type},
            .regions = &.{ctx.region},
        },
    );
    const cleanup_fn = try ctx.c.functionFor("service finalizer", cleanup_type);
    const cleanup = try ctx.private.closureBody(cleanup_fn);
    try ctx.c.define(
        cleanup_fn,
        try cleanup.ret(try cleanup.perform(ctx.release, try cleanup.readCell(ctx.cell))),
    );
    try ctx.c.define(
        ctx.private_fn,
        try ctx.private.ret(try ctx.private.protect(
            try ctx.private.lambda(ctx.body_fn, ctx.body_type),
            try ctx.private.lambda(cleanup_fn, cleanup_type),
            .{},
        )),
    );
    try ctx.c.define(
        ctx.producer_fn,
        try ctx.producer.ret(try ctx.producer.withRegion(
            ctx.region,
            try ctx.producer.lambda(ctx.private_fn, ctx.private_type),
            .{},
        )),
    );

    return defineDriver(paired, .{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .receive = ctx.receive,
        .send = ctx.send,
        .release = ctx.release,
        .service = ctx.service,
        .producer_type = ctx.producer_type,
        .producer_fn = ctx.producer_fn,
    });
}

fn defineDriver(
    comptime paired: bool,
    ctx: anytype,
) a.Error!source.Module {
    const drive_fn = try ctx.c.function(
        "service driver",
        .{ .answer = ctx.service.answer() },
        ctx.integer,
        &.{ ctx.receive, ctx.send, ctx.release },
    );
    const driver = try ctx.c.body(drive_fn);
    const answer = try driver.parameter("answer");
    const done = try driver.caseOf(answer, "done");
    const yielded = try driver.caseOf(answer, "yielded");
    const step = yielded.body();
    const parts = try step.destructure(yielded.payload());
    const message = try parts.get("value");
    const future = try parts.get("future");
    const ready = try step.caseOf(message, "ready");
    const replied = try step.caseOf(message, "reply");
    _ = try step.match(message, .{
        .ready = try ready.ret(try ready.body().constant(void, {})),
        .reply = try replied.ret(try replied.body().perform(ctx.send, replied.payload())),
    });
    const incoming = try step.perform(ctx.receive, try step.constant(void, {}));
    const successor = try step.resumePackage(future, incoming);
    const result = try step.call(drive_fn, .{ .answer = successor });
    try ctx.c.define(
        drive_fn,
        try driver.ret(try driver.match(
            answer,
            .{ .done = try done.ret(done.payload()), .yielded = try yielded.ret(result) },
        )),
    );

    return startService(paired, .{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .receive = ctx.receive,
        .send = ctx.send,
        .release = ctx.release,
        .service = ctx.service,
        .producer_type = ctx.producer_type,
        .producer_fn = ctx.producer_fn,
        .drive_fn = drive_fn,
    });
}

fn startService(
    comptime paired: bool,
    ctx: anytype,
) a.Error!source.Module {
    const main = try ctx.c.function(
        "entry",
        .{},
        ctx.integer,
        &.{ ctx.receive, ctx.send, ctx.release },
    );
    const entry = try ctx.c.body(main);
    const initial = try entry.handleWith(
        ctx.service.handler(),
        try entry.lambda(ctx.producer_fn, ctx.producer_type),
        .{},
    );
    const second = if (paired) try entry.handleWith(
        ctx.service.handler(),
        try entry.lambda(ctx.producer_fn, ctx.producer_type),
        .{},
    ) else null;
    const first_result = try entry.call(ctx.drive_fn, .{ .answer = initial });
    const combined = if (paired) try entry.checkedAdd(
        first_result,
        try entry.call(ctx.drive_fn, .{ .answer = second }),
        try ctx.c.literalFailure(void, {}),
    ) else first_result;
    try ctx.c.define(main, try entry.ret(combined));
    return ctx.c.module(main, ctx.unit);
}
