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

fn authored(b: *source.Builder, comptime swap_replies: bool, comptime paired: bool) a.Error!source.Module {
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
        .captures = .{ .continuation = &.{ unit, integer, request, command, reply, output, cell_type } },
        .owned_regions = &.{region},
        .residual = &.{release},
        .body_use = .reusable,
    });

    // A direct recursive worker owns no independent state authority. Its cell
    // and explicit capability exist only inside the generator's owned region.
    const work_type = try c.callable(.{ .command = command, .state = cell_type, .capability = service.capability() }, integer, &.{service.effect()}, .{
        .use = .reusable,
        .captures = &.{},
        .regions = &.{region},
    });
    const work_fn = try c.functionFor("service request", work_type);
    const work = try c.body(work_fn);
    const input = try work.parameter("command");
    const state = try work.parameter("state");
    const capability = try work.parameter("capability");
    const closing = try work.caseOf(input, "close");
    const serving = try work.caseOf(input, "serve");
    const turn = serving.body();
    const id = try turn.field(serving.payload(), "id");
    const delta = try turn.field(serving.payload(), "delta");
    const before = try turn.readCell(state);
    const after = try turn.checkedAdd(before, delta, try c.literalFailure(void, {}));
    _ = try turn.writeCell(state, after);
    // The driver has no package while this suffix is running or suspended.
    // A second command cannot enter until the reply returns its successor.
    _ = try turn.yieldNow();
    const reply_id = if (swap_replies) try turn.bitwise(.xor, id, try turn.constant(u64, 3)) else id;
    const response = try turn.product(reply, .{ .id = reply_id, .previous = before });
    const next = try turn.performLocal(service.effect(), capability, try turn.variant(output, "reply", response));
    const continued = try turn.call(work_fn, .{ .command = next, .state = state, .capability = capability });
    try c.define(work_fn, try work.ret(try work.match(input, .{
        .serve = try serving.ret(continued),
        .close = try closing.ret(try closing.body().readCell(state)),
    })));

    const producer_type = try c.handledSchema(service.handler());
    const producer_fn = try c.functionFor("service producer", producer_type);
    const producer = try c.body(producer_fn);
    const producer_cap = try producer.parameter("capability");
    const private_type = try c.regionBodySchema(region, .{}, integer, &.{ service.effect(), release }, .{
        .use = .reusable,
        .captures = &.{service.capability()},
    });
    const private_fn = try c.functionFor("service state", private_type);
    const private = try producer.closureBody(private_fn);
    const cell = try private.newCell(cell_type, try private.parameter("region"), try private.constant(u64, 0));
    const body_type = try c.callable(.{}, integer, &.{service.effect()}, .{
        .use = .reusable,
        .captures = &.{ service.capability(), cell_type },
        .regions = &.{region},
    });
    const body_fn = try c.functionFor("service exchange", body_type);
    const body = try private.closureBody(body_fn);
    const first = try body.performLocal(service.effect(), producer_cap, try body.variant(output, "ready", try body.constant(void, {})));
    try c.define(body_fn, try body.ret(try body.call(work_fn, .{ .command = first, .state = cell, .capability = producer_cap })));
    const cleanup_type = try c.callable(.{ .exit = try c.cleanupInfo(unit) }, unit, &.{release}, .{
        .use = .reusable,
        .captures = &.{cell_type},
        .regions = &.{region},
    });
    const cleanup_fn = try c.functionFor("service finalizer", cleanup_type);
    const cleanup = try private.closureBody(cleanup_fn);
    try c.define(cleanup_fn, try cleanup.ret(try cleanup.perform(release, try cleanup.readCell(cell))));
    try c.define(private_fn, try private.ret(try private.protect(try private.lambda(body_fn, body_type), try private.lambda(cleanup_fn, cleanup_type), .{})));
    try c.define(producer_fn, try producer.ret(try producer.withRegion(region, try producer.lambda(private_fn, private_type), .{})));

    const drive_fn = try c.function("service driver", .{ .answer = service.answer() }, integer, &.{ receive, send, release });
    const driver = try c.body(drive_fn);
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
        .reply = try replied.ret(try replied.body().perform(send, replied.payload())),
    });
    const incoming = try step.perform(receive, try step.constant(void, {}));
    const successor = try step.resumePackage(future, incoming);
    const result = try step.call(drive_fn, .{ .answer = successor });
    try c.define(drive_fn, try driver.ret(try driver.match(answer, .{ .done = try done.ret(done.payload()), .yielded = try yielded.ret(result) })));

    const main = try c.function("entry", .{}, integer, &.{ receive, send, release });
    const entry = try c.body(main);
    const initial = try entry.handleWith(service.handler(), try entry.lambda(producer_fn, producer_type), .{});
    const second = if (paired) try entry.handleWith(service.handler(), try entry.lambda(producer_fn, producer_type), .{}) else null;
    const first_result = try entry.call(drive_fn, .{ .answer = initial });
    const combined = if (paired) try entry.checkedAdd(first_result, try entry.call(drive_fn, .{ .answer = second }), try c.literalFailure(void, {})) else first_result;
    try c.define(main, try entry.ret(combined));
    return c.module(main, unit);
}
