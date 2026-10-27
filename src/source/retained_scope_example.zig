// Copyright (c) 2026 Boundary contributors. MIT license.
//! A higher-order operation runs retained work under a new interpretation while
//! its definition-site capability remains independently meaningful.
const source = @import("../source.zig");
const p = @import("horos_data").program;
const cleanup = @import("library/cleanup.zig");
const Error = source.Error;
const Context = struct {
    b: *source.Builder,
    unit: p.Id,
    integer: p.Id,
    pair: p.Id,
    read: p.Id,
    release: p.Id,
    scoped: p.Id,
    capability: p.Id,
    scope_capability: p.Id,
    inside_type: p.Id,
    work_type: p.Id,
    thunk_type: p.Id,
    cleanup_type: p.Id,
    tokens: [3]p.Id,
    captures: []const p.Id,

    fn arithmetic(c: Context, opcode: p.Opcode, left: p.Id, right: p.Id) Error!p.Id {
        return c.b.value(.{ .schema = c.integer, .expression = .{ .primitive = .{
            .opcode = opcode,
            .operands = &.{ left, right },
            .failures = &.{.{
                .kind = .arithmetic_overflow,
                .value = try c.b.failureLiteral(try c.b.constant(void, {})),
            }},
        } } });
    }
};

fn context(b: *source.Builder) Error!Context {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const read = try b.effect(.{
        .identity = "retained-scope/read",
        .payload = unit,
        .result = integer,
        .external = false,
    });
    const release = try b.effect(.{
        .identity = "retained-scope/release",
        .payload = integer,
        .result = unit,
    });
    const capability = try b.schema(.{ .internal = .{ .capability = read } });
    const inside_type = try b.reserveSchema();
    const scoped = try b.effect(.{
        .identity = "retained-scope/run",
        .payload = unit,
        .result = integer,
        .bodies = &.{inside_type},
        .external = false,
    });
    const scope_capability = try b.schema(.{ .internal = .{ .capability = scoped } });
    try b.defineSchema(inside_type, .{ .internal = .{ .computation = .{
        .parameters = &.{capability},
        .result = integer,
        .effects = &.{ read, release },
        .capture_bound = &.{capability},
        .use = .linear,
    } } });
    const work_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .effects = &.{read},
        .capture_bound = &.{capability},
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{try cleanup.exitInfo(b, unit)},
        .result = unit,
        .effects = &.{release},
    } } });
    return captureContext(b, .{
        .unit = unit,
        .integer = integer,
        .pair = pair,
        .read = read,
        .release = release,
        .capability = capability,
        .inside_type = inside_type,
        .scoped = scoped,
        .scope_capability = scope_capability,
        .work_type = work_type,
        .cleanup_type = cleanup_type,
    });
}

fn captureContext(
    b: *source.Builder,
    ctx: anytype,
) Error!Context {
    var tokens: [3]p.Id = undefined;
    for (&tokens) |*token| token.* = try b.reserveSchema();
    const captures = try b.allocator().dupe(
        p.Id,
        &.{
            ctx.unit,
            ctx.integer,
            ctx.pair,
            ctx.capability,
            ctx.scope_capability,
            ctx.inside_type,
            ctx.work_type,
            ctx.cleanup_type,
            tokens[0],
            tokens[1],
            tokens[2],
        },
    );
    return .{
        .b = b,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .pair = ctx.pair,
        .read = ctx.read,
        .release = ctx.release,
        .scoped = ctx.scoped,
        .capability = ctx.capability,
        .scope_capability = ctx.scope_capability,
        .inside_type = ctx.inside_type,
        .work_type = ctx.work_type,
        .thunk_type = ctx.work_type,
        .cleanup_type = ctx.cleanup_type,
        .tokens = tokens,
        .captures = captures,
    };
}

fn readHandler(c: Context, outer: bool) Error!p.Id {
    const b = c.b;
    const answer = if (outer) c.pair else c.integer;
    const token = c.tokens[if (outer) 0 else 1];
    const effects: []const p.Id = if (outer) &.{c.release} else &.{ c.read, c.release };
    try b.defineSchema(token, .{ .internal = .{ .resumption = .{
        .effect = c.read,
        .input = c.integer,
        .answer = answer,
        .effects = effects,
        .capture_bound = c.captures,
        .handled = &.{c.read},
        .mode = .deep,
        .use = .linear,
        .obligations = true,
    } } });
    const returns = try b.declare(&.{ c.integer, c.integer }, answer, &.{}, &.{});
    const value = try b.reference(b.parameter(returns, 1));
    try b.define(returns, try b.pure(if (outer)
        try b.primitive(c.pair, .product, &.{ value, try b.constant(u64, 99) }, 0)
    else
        value));
    const clause = try b.declare(&.{ c.integer, c.unit, token }, answer, effects, &.{});
    try b.define(clause, try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(clause, 2)),
        .argument = try b.reference(b.parameter(clause, 0)),
    } }));
    return b.handler(.{
        .mode = .deep,
        .input = c.integer,
        .answer = answer,
        .state = &.{c.integer},
        .effects = effects,
        .return_function = returns,
        .clauses = &.{.{ .effect = c.read, .function = clause, .resumption = token }},
    });
}

fn scopeHandler(c: Context, interpretation: p.Id) Error!p.Id {
    const b = c.b;
    const token = c.tokens[2];
    const effects = &.{ c.read, c.release };
    try b.defineSchema(token, .{ .internal = .{ .resumption = .{
        .effect = c.scoped,
        .input = c.integer,
        .answer = c.integer,
        .effects = effects,
        .capture_bound = c.captures,
        .handled = &.{c.scoped},
        .mode = .deep,
        .use = .linear,
        .obligations = true,
    } } });
    const returns = try b.declare(&.{c.integer}, c.integer, &.{}, &.{});
    try b.define(
        returns,
        try b.pure(try c.arithmetic(
            .integer_add,
            try b.reference(b.parameter(returns, 0)),
            try b.constant(u64, 100),
        )),
    );
    const clause = try b.declare(&.{ c.unit, c.inside_type, token }, c.integer, effects, &.{});
    const result = try b.variable(c.integer);
    const run = try b.term(.{ .handle = .{
        .handler = interpretation,
        .body = try b.reference(b.parameter(clause, 1)),
        .state = &.{try b.constant(u64, 20)},
    } });
    try b.define(clause, try b.bind(result, run, try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(clause, 2)),
        .argument = try b.reference(result),
    } })));
    return b.handler(.{
        .mode = .deep,
        .input = c.integer,
        .answer = c.integer,
        .return_function = returns,
        .effects = effects,
        .clauses = &.{.{ .effect = c.scoped, .function = clause, .resumption = token }},
    });
}

fn retainedBody(c: Context, definition_capability: p.Id) Error!p.Id {
    const b = c.b;
    const inside = try b.declare(&.{c.capability}, c.integer, &.{ c.read, c.release }, &.{});
    const thunk = try b.declare(&.{}, c.integer, &.{c.read}, &.{});
    const defined = try b.variable(c.integer);
    const supplied = try b.variable(c.integer);
    const read_definition = try b.term(.{ .perform = .{
        .effect = c.read,
        .capability = try b.reference(definition_capability),
        .payload = try b.constant(void, {}),
    } });
    const read_use = try b.term(.{ .perform = .{
        .effect = c.read,
        .capability = try b.reference(b.parameter(inside, 0)),
        .payload = try b.constant(void, {}),
    } });
    const result = try c.arithmetic(
        .integer_add,
        try c.arithmetic(.integer_mul, try b.reference(defined), try b.constant(u64, 100)),
        try b.reference(supplied),
    );
    try b.define(
        thunk,
        try b.bind(defined, read_definition, try b.bind(supplied, read_use, try b.pure(result))),
    );
    const work = try b.declare(&.{}, c.integer, &.{c.read}, &.{});
    const saved = try b.variable(c.thunk_type);
    const later = try b.term(.{ .apply = .{
        .computation = try b.reference(saved),
        .arguments = &.{},
    } });
    try b.define(
        work,
        try b.bind(
            saved,
            try b.pure(try b.lambda(thunk, c.thunk_type)),
            try b.term(.{ .yield_then = later }),
        ),
    );
    const finalizer = try b.declare(
        &.{try cleanup.exitInfo(b, c.unit)},
        c.unit,
        &.{c.release},
        &.{},
    );
    try b.define(
        finalizer,
        try b.term(.{ .perform = .{ .effect = c.release, .payload = try b.constant(u64, 77) } }),
    );
    try b.define(inside, try b.term(.{ .protect = .{
        .body = try b.lambda(work, c.work_type),
        .cleanup = try b.lambda(finalizer, c.cleanup_type),
    } }));
    return inside;
}

pub fn build(b: *source.Builder) Error!source.Module {
    const c = try context(b);
    const outer = try readHandler(c, true);
    const inner = try readHandler(c, false);
    const scoped = try scopeHandler(c, inner);
    const main = try b.declare(&.{}, c.pair, &.{c.release}, &.{});
    const definition = try b.declare(&.{c.capability}, c.integer, &.{ c.read, c.release }, &.{});
    const inside = try retainedBody(c, b.parameter(definition, 0));
    const runner = try b.declare(
        &.{c.scope_capability},
        c.integer,
        &.{ c.read, c.release, c.scoped },
        &.{},
    );
    const performed = try b.term(.{ .perform = .{
        .effect = c.scoped,
        .capability = try b.reference(b.parameter(runner, 0)),
        .payload = try b.constant(void, {}),
        .bodies = &.{try b.lambda(inside, c.inside_type)},
    } });
    const value = try b.variable(c.integer);
    try b.define(
        runner,
        try b.bind(
            value,
            performed,
            try b.pure(try c.arithmetic(
                .integer_add,
                try b.reference(value),
                try b.constant(u64, 1),
            )),
        ),
    );
    const runner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{c.scope_capability},
        .result = c.integer,
        .effects = &.{ c.read, c.release, c.scoped },
        .capture_bound = &.{c.capability},
    } } });
    try b.define(definition, try b.term(.{ .handle = .{
        .handler = scoped,
        .body = try b.lambda(runner, runner_type),
    } }));
    const definition_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{c.capability},
        .result = c.integer,
        .effects = &.{ c.read, c.release },
    } } });
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = outer,
            .body = try b.lambda(definition, definition_type),
            .state = &.{try b.constant(u64, 10)},
        } }),
    );
    return b.module(main, c.unit);
}
