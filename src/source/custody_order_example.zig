// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independent owned suspensions expose lexical cleanup order.
const source = @import("../source.zig");
const gen = @import("../library/generator.zig");
const a = @import("../authoring.zig");
const p = @import("horos_data").program;

pub const count = 10;
pub const Fixtures = struct { package: p.Id, queue: p.Id, factory: p.Id, release: p.Id };

pub fn define(b: *source.Builder, release: p.Id) source.Error!Fixtures {
    return defineTyped(b, release) catch |err| return a.sourceError(err);
}
fn defineTyped(b: *source.Builder, release_id: p.Id) a.Error!Fixtures {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const release = try a.interop.operation(c, release_id);
    const generator = try gen.create(c, "custody/suspend", unit, integer, unit, .{
        .captures = .{ .continuation = &.{ unit, integer } },
        .residual = &.{release},
        .parameters = .{ .label = integer },
        .body_use = .reusable,
    });
    const start_type = try c.handledSchema(generator.handler());
    const start_fn = try c.functionFor("custody producer", start_type);
    const start = try c.body(start_fn);
    const label = try start.parameter("label");
    const capability = try start.parameter("capability");
    const body_type = try c.callable(
        .{},
        unit,
        &.{generator.effect()},
        .{ .use = .reusable, .captures = &.{ generator.capability(), integer } },
    );
    const body_fn = try c.functionFor("custody suspension", body_type);
    const body = try start.closureBody(body_fn);
    _ = try body.performLocal(generator.effect(), capability, label);
    try c.define(body_fn, try body.ret(try body.constant(void, {})));
    const cleanup_type = try c.callable(
        .{ .exit = try c.cleanupInfo(integer) },
        unit,
        &.{release},
        .{ .use = .reusable, .captures = &.{integer} },
    );
    const cleanup_fn = try c.functionFor("custody release", cleanup_type);
    const cleanup = try start.closureBody(cleanup_fn);
    try c.define(cleanup_fn, try cleanup.ret(try cleanup.perform(release, label)));
    try c.define(
        start_fn,
        try start.ret(try start.protect(
            try start.lambda(body_fn, body_type),
            try start.lambda(cleanup_fn, cleanup_type),
            .{},
        )),
    );
    const factory_fn = try c.function(
        "custody factory",
        .{ .label = integer },
        generator.package(),
        &.{release},
    );
    const factory = try c.body(factory_fn);
    const answer = try factory.handleWithArguments(
        generator.handler(),
        try factory.lambda(start_fn, start_type),
        .{ .label = try factory.parameter("label") },
        .{},
    );
    const done = try factory.caseOf(answer, "done");
    const yielded = try factory.caseOf(answer, "yielded");
    const parts = try yielded.body().destructure(yielded.payload());
    try c.define(
        factory_fn,
        try factory.ret(try factory.match(
            answer,
            .{
                .done = try done.fail(generator.package(), try done.body().constant(u64, 99)),
                .yielded = try yielded.ret(try parts.get("future")),
            },
        )),
    );
    return .{
        .package = try a.interop.schemaId(c, generator.package()),
        .queue = try a.interop.schemaId(c, try c.sequence(generator.package())),
        .factory = try a.interop.functionId(c, factory_fn),
        .release = release_id,
    };
}

// These expert-IR fixtures intentionally vary lexical custody scopes and value
// observations. Keep those shapes explicit for independent cleanup-order tests.

pub fn build(b: *source.Builder, fixtures: Fixtures, mode: u8) source.Error!p.Id {
    const integer = try b.scalar(u64);
    const queue = fixtures.queue;
    const release = fixtures.release;
    const helper = try b.declare(&.{ queue, queue }, integer, &.{release}, &.{});
    const length = try observation(b, helper, queue, mode);
    const failure = try b.term(.{ .fail = try b.constant(u64, 8) });
    const fails = if (mode == 7) failure else try b.bind(
        try b.variable(integer),
        failure,
        try b.term(.{ .fail = try b.primitive(
            integer,
            .sequence_length,
            &.{try b.reference(b.parameter(helper, if (mode == 2) 0 else 1))},
            0,
        ) }),
    );
    const outer = try b.bind(try b.variable(integer), try b.pure(length), fails);
    const inner = try b.bind(
        try b.variable(queue),
        try b.pure(try b.reference(b.parameter(helper, 1))),
        try b.term(.{ .fail = try b.constant(u64, 8) }),
    );
    const held = try b.variable(queue);
    const condition = try b.primitive(
        try b.scalar(bool),
        .equal,
        &.{ length, try b.primitive(integer, .sequence_length, &.{try b.reference(held)}, 0) },
        0,
    );
    const branches = try b.term(.{ .conditional = .{
        .condition = condition,
        .when_true = try b.term(.{ .fail = try b.constant(u64, 8) }),
        .when_false = try b.term(.{ .fail = try b.constant(u64, 9) }),
    } });
    const live_inner = try b.bind(
        held,
        try b.pure(try b.reference(b.parameter(helper, 1))),
        branches,
    );
    const returned_inner = try b.bind(
        held,
        try b.pure(try b.reference(b.parameter(helper, 1))),
        try b.pure(try b.constant(u64, 3)),
    );
    const after_inner = try b.bind(try b.variable(integer), returned_inner, failure);
    try b.define(
        helper,
        try b.term(
            .{
                .yield_then = if (mode == 9)
                    after_inner
                else if (mode == 4)
                    live_inner
                else if (mode == 1)
                    inner
                else
                    outer,
            },
        ),
    );
    const entry = try b.declare(&.{}, integer, &.{release}, &.{});
    const first = try b.variable(fixtures.package);
    const second = try b.variable(fixtures.package);
    const called = try b.term(.{ .call = .{ .function = helper, .arguments = &.{
        try b.primitive(queue, .sequence, &.{try b.reference(if (mode == 3) second else first)}, 0),
        try b.primitive(queue, .sequence, &.{try b.reference(if (mode == 3) first else second)}, 0),
    } } });
    const with_second = try b.bind(
        second,
        try b.term(.{ .call = .{
            .function = fixtures.factory,
            .arguments = &.{try b.constant(u64, 2)},
        } }),
        called,
    );
    try b.define(
        entry,
        try b.bind(
            first,
            try b.term(.{ .call = .{
                .function = fixtures.factory,
                .arguments = &.{try b.constant(u64, 1)},
            } }),
            with_second,
        ),
    );
    return entry;
}

fn observation(b: *source.Builder, helper: p.Id, queue: p.Id, mode: u8) source.Error!p.Id {
    const integer = try b.scalar(u64);
    const first = try b.reference(b.parameter(helper, 0));
    const second = try b.reference(b.parameter(helper, 1));
    const items = switch (mode) {
        2 => second,
        5 => try b.primitive(try b.schema(.{ .seq = queue }), .sequence, &.{first}, 0),
        6 => try b.primitive(queue, .move, &.{first}, 0),
        7 => try b.primitive(queue, .sequence_concat, &.{ second, first }, 0),
        8 => {
            const captured = try b.declare(&.{}, queue, &.{}, &.{});
            try b.define(captured, try b.pure(first));
            const signature = try b.schema(.{ .internal = .{ .computation = .{
                .parameters = &.{},
                .result = queue,
                .effects = &.{},
                .capture_bound = &.{queue},
                .use = .linear,
            } } });
            const sum = try b.schema(.{ .sum = &.{ try b.scalar(void), signature } });
            const variant = try b.primitive(
                sum,
                .variant,
                &.{try b.lambda(captured, signature)},
                1,
            );
            return b.primitive(integer, .variant_tag, &.{variant}, 0);
        },
        else => first,
    };
    return b.primitive(integer, .sequence_length, &.{items}, 0);
}
