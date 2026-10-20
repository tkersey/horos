// Copyright (c) 2026 Boundary contributors. MIT license.
//! Public source construction examples; no target blocks or runtime callbacks.
const source = @import("../source.zig");
const data = @import("horos_data");
const p = data.program;
const Error = source.Error;

fn binary(
    builder: *source.Builder,
    opcode: p.Opcode,
    schema: p.Id,
    left: p.Id,
    right: p.Id,
    fault: p.Id,
) Error!p.Id {
    return builder.value(.{
        .schema = schema,
        .expression = .{ .primitive = .{
            .opcode = opcode,
            .operands = &.{ left, right },
            .failures = if (opcode == .equal or opcode == .less) &.{} else &.{.{
                .kind = .arithmetic_overflow,
                .value = try builder.failureLiteral(fault),
            }},
        } },
    });
}

pub const ownership = @import("ownership_example.zig").build;
pub const generator = @import("generator_example.zig").build;
pub const stateLocal = @import("state_choice_example.zig").local;
pub const stateShared = @import("state_choice_example.zig").shared;
pub const resourceScalar = @import("resource_example.zig").scalar;
pub const resourcePair = @import("resource_example.zig").pair;
pub const answers = @import("answer_example.zig").build;
pub const scopedReader = @import("scoped_reader_example.zig").build;
pub const retainedScope = @import("retained_scope_example.zig").build;
pub const writerRaise = @import("writer_raise_example.zig").build;
pub const schedulerFifo = @import("scheduler_example.zig").build;
pub const pairedServices = @import("service_example.zig").twoInstances;
pub const statefulService = @import("service_example.zig").build;
pub const swappedServiceReplies = @import("service_example.zig").swappedReplies;
pub const scalarContracts = @import("scalar_contract_example.zig").build;
pub const yieldingCleanup = @import("unwind_example.zig").yielding;
pub const productProjection = @import("projection_example.zig").build;

pub const borrowOperands = @import("borrow_operand_example.zig").build;

pub fn custodyOrder(builder: *source.Builder, mode: u8) Error!source.Module {
    const example = @import("custody_order_example.zig");
    const integer = try builder.scalar(u64);
    const release = try builder.effect(.{
        .identity = "custody/release",
        .payload = integer,
        .result = try builder.scalar(void),
    });
    const fixtures = try example.define(builder, release);
    const entry = try example.build(builder, fixtures, mode);
    return builder.module(entry, integer);
}

pub fn boundedValues(builder: *source.Builder) Error!source.ast.Module {
    const byte = try builder.scalar(u8);
    const enumeration = try builder.schema(.{ .enumeration = &.{ 2, 7 } });
    const never = try builder.schema(.{ .enumeration = &.{} });
    const array = try builder.schema(.{ .array = .{ .element = byte, .length = 2 } });
    const text = try builder.schema(.{ .bounded_text = 2 });
    const bytes = try builder.schema(.{ .bounded_bytes = 2 });
    const result = try builder.schema(.{ .product = &.{ enumeration, array, text, bytes } });
    const main = try builder.declare(&.{}, result, &.{}, &.{});
    const selected = try builder.literal(.{ .schema = enumeration, .bytes = &.{ 7, 0, 0, 0 } });
    const elements = try builder.primitive(
        array,
        .sequence,
        &.{ try builder.constant(u8, 9), try builder.constant(u8, 8) },
        0,
    );
    const label = try builder.literal(.{ .schema = text, .bytes = &.{ 2, 0xc3, 0xa9 } });
    const payload = try builder.literal(.{ .schema = bytes, .bytes = &.{ 2, 0xff, 0 } });
    try builder.define(
        main,
        try builder.pure(try builder.primitive(
            result,
            .product,
            &.{ selected, elements, label, payload },
            0,
        )),
    );
    return builder.module(main, never);
}

pub fn lexical(builder: *source.Builder) Error!source.ast.Module {
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const fault = try builder.constant(void, {});
    const main = try builder.declare(&.{integer}, integer, &.{}, &.{});
    const inner = try builder.declare(&.{integer}, integer, &.{}, &.{});
    const x = try builder.reference(builder.parameter(main, 0));
    const y = try builder.reference(builder.parameter(inner, 0));
    try builder.define(
        inner,
        try builder.pure(try binary(builder, .integer_add, integer, x, y, fault)),
    );
    const function_type = try builder.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{integer},
        .result = integer,
        .capture_bound = &.{integer},
    } } });
    const closure = try builder.lambda(inner, function_type);
    const retained = try builder.variable(function_type);
    const use = try builder.term(.{ .apply = .{
        .computation = try builder.reference(retained),
        .arguments = &.{try builder.constant(u64, 2)},
    } });
    try builder.define(main, try builder.bind(retained, try builder.pure(closure), use));
    return builder.module(main, unit);
}

pub fn deep(builder: *source.Builder) Error!source.ast.Module {
    const unit = try builder.scalar(void);
    const integer = try builder.scalar(u64);
    const fault = try builder.constant(void, {});
    const operation = try builder.effect(.{
        .identity = "example/ask",
        .payload = unit,
        .result = integer,
        .external = false,
    });
    const capability = try builder.schema(.{ .internal = .{ .capability = operation } });
    const resumption = try builder.schema(.{ .internal = .{ .resumption = .{
        .effect = operation,
        .input = integer,
        .answer = integer,
        .handled = &.{operation},
        .mode = .deep,
        .use = .linear,
    } } });
    const computation = try builder.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{capability},
        .result = integer,
        .effects = &.{operation},
    } } });
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    const body = try builder.declare(&.{capability}, integer, &.{operation}, &.{});
    const returns = try builder.declare(&.{integer}, integer, &.{}, &.{});
    const clause = try builder.declare(&.{ unit, resumption }, integer, &.{}, &.{});
    const x = try builder.variable(integer);
    const performed = try builder.term(.{ .perform = .{
        .effect = operation,
        .capability = try builder.reference(builder.parameter(body, 0)),
        .payload = fault,
    } });
    try builder.define(
        body,
        try builder.bind(
            x,
            performed,
            try builder.pure(try binary(
                builder,
                .integer_add,
                integer,
                try builder.reference(x),
                try builder.constant(u64, 1),
                fault,
            )),
        ),
    );
    try builder.define(
        returns,
        try builder.pure(try binary(
            builder,
            .integer_mul,
            integer,
            try builder.reference(builder.parameter(returns, 0)),
            try builder.constant(u64, 10),
            fault,
        )),
    );
    const answer = try builder.variable(integer);
    const resumed = try builder.term(.{ .resume_value = .{
        .resumption = try builder.reference(builder.parameter(clause, 1)),
        .argument = try builder.constant(u64, 5),
    } });
    try builder.define(
        clause,
        try builder.bind(
            answer,
            resumed,
            try builder.pure(try binary(
                builder,
                .integer_add,
                integer,
                try builder.reference(answer),
                try builder.constant(u64, 7),
                fault,
            )),
        ),
    );
    const handler = try builder.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .return_function = returns,
        .clauses = &.{.{ .effect = operation, .function = clause, .resumption = resumption }},
    });
    try builder.define(
        main,
        try builder.term(.{ .handle = .{
            .handler = handler,
            .body = try builder.lambda(body, computation),
        } }),
    );
    return builder.module(main, unit);
}

/// A total branching clause resumes exactly once; body and return still do
/// checked arithmetic after that resumption, preserving their failure positions.
pub fn branchingTail(b: *source.Builder) Error!source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const integer = try b.scalar(u64);
    const fault = try b.constant(void, {});
    const effect = try b.effect(.{
        .identity = "example/branching-tail",
        .payload = boolean,
        .result = integer,
        .external = false,
    });
    const capability = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = integer,
        .answer = integer,
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const main = try b.declare(&.{boolean}, integer, &.{}, &.{});
    const body = try b.declare(&.{capability}, integer, &.{effect}, &.{});
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    const clause = try b.declare(&.{ boolean, token }, integer, &.{}, &.{});
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{capability},
        .result = integer,
        .effects = &.{effect},
        .capture_bound = &.{boolean},
    } } });
    const performed = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.reference(b.parameter(main, 0)),
    } });
    const result = try b.variable(integer);
    try b.define(
        body,
        try b.bind(
            result,
            performed,
            try b.pure(try binary(
                b,
                .integer_add,
                integer,
                try b.reference(result),
                try b.constant(u64, 1),
                fault,
            )),
        ),
    );
    try b.define(
        returns,
        try b.pure(try binary(
            b,
            .integer_mul,
            integer,
            try b.reference(b.parameter(returns, 0)),
            try b.constant(u64, 10),
            fault,
        )),
    );
    const resumption = try b.reference(b.parameter(clause, 1));
    try b.define(clause, try b.term(.{ .conditional = .{
        .condition = try b.reference(b.parameter(clause, 0)),
        .when_true = try b.term(.{ .resume_value = .{
            .resumption = resumption,
            .argument = try b.constant(u64, 5),
        } }),
        .when_false = try b.term(.{ .resume_value = .{
            .resumption = resumption,
            .argument = try b.constant(u64, 9),
        } }),
    } }));
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handler,
            .body = try b.lambda(body, computation),
        } }),
    );
    return b.module(main, unit);
}

/// The selected delimiter contains an unfinished cleanup obligation.
pub fn branchingTailProtected(b: *source.Builder) Error!source.Module {
    const original = try branchingTail(b);
    const integer = b.functions.items[@intCast(original.entry)].result;
    const unit = original.failure;
    const cleanup_effect = try b.effect(.{
        .identity = "example/tail-cleanup",
        .payload = unit,
        .result = unit,
    });
    const main_body = b.functions.items[@intCast(original.entry)].body.?;
    const body_value = b.terms.items[@intCast(main_body)].handle.body;
    const body = b.values.items[@intCast(body_value)].expression.lambda;
    const body_type = b.values.items[@intCast(body_value)].schema;
    const old = b.functions.items[@intCast(body)];
    const inner = try b.declare(&.{}, integer, old.effects, &.{});
    try b.define(inner, old.body.?);
    const boolean = b.variables.items[@intCast(b.parameter(original.entry, 0))];
    const capability = b.variables.items[@intCast(b.parameter(body, 0))];
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .effects = old.effects,
        .capture_bound = &.{ boolean, capability },
    } } });
    const exit_info = try @import("../library/cleanup.zig").exitInfo(b, unit);
    const cleanup = try b.declare(&.{exit_info}, unit, &.{cleanup_effect}, &.{});
    try b.define(
        cleanup,
        try b.term(.{ .perform = .{
            .effect = cleanup_effect,
            .payload = try b.constant(void, {}),
        } }),
    );
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{exit_info},
        .result = unit,
        .effects = &.{cleanup_effect},
    } } });
    b.functions.items[@intCast(body)].body = try b.term(.{ .protect = .{
        .body = try b.lambda(inner, inner_type),
        .cleanup = try b.lambda(cleanup, cleanup_type),
    } });
    const effects = try b.allocator().dupe(p.Id, &.{ old.effects[0], cleanup_effect });
    b.functions.items[@intCast(body)].effects = effects;
    b.schemas.items[@intCast(body_type)].internal.computation.effects = effects;
    const cleanup_effects = try b.allocator().dupe(p.Id, &.{cleanup_effect});
    b.functions.items[@intCast(original.entry)].effects = cleanup_effects;
    const token = b.handlers.items[0].clauses[0].resumption;
    b.schemas.items[@intCast(token)].internal.resumption.effects = cleanup_effects;
    b.schemas.items[@intCast(token)].internal.resumption.obligations = true;
    const clause = b.handlers.items[0].clauses[0].function;
    b.functions.items[@intCast(clause)].effects = cleanup_effects;
    b.handlers.items[0].effects = cleanup_effects;
    return b.module(original.entry, original.failure);
}

pub fn recursive(builder: *source.Builder) Error!source.ast.Module {
    const integer = try builder.scalar(u64);
    const boolean = try builder.scalar(bool);
    const unit = try builder.scalar(void);
    const fault = try builder.constant(void, {});
    const main = try builder.declare(&.{integer}, boolean, &.{}, &.{});
    const even = try builder.declare(&.{integer}, boolean, &.{}, &.{});
    const odd = try builder.declare(&.{integer}, boolean, &.{}, &.{});
    for ([_]p.Id{ even, odd }, 0..) |function, index| {
        const n = try builder.reference(builder.parameter(function, 0));
        const condition = try binary(
            builder,
            .equal,
            boolean,
            n,
            try builder.constant(u64, 0),
            fault,
        );
        const decrement = try binary(
            builder,
            .integer_sub,
            integer,
            n,
            try builder.constant(u64, 1),
            fault,
        );
        const recurse = try builder.term(.{ .call = .{
            .function = if (index == 0) odd else even,
            .arguments = &.{decrement},
        } });
        try builder.define(
            function,
            try builder.term(.{ .conditional = .{
                .condition = condition,
                .when_true = try builder.pure(try builder.constant(bool, index == 0)),
                .when_false = recurse,
            } }),
        );
    }
    try builder.define(
        main,
        try builder.term(.{ .call = .{
            .function = even,
            .arguments = &.{try builder.reference(builder.parameter(main, 0))},
        } }),
    );
    return builder.module(main, unit);
}

pub fn choicesAll(builder: *source.Builder) Error!source.ast.Module {
    return choices(builder, true);
}
pub fn choicesFirst(builder: *source.Builder) Error!source.ast.Module {
    return choices(builder, false);
}

fn choices(builder: *source.Builder, comptime every: bool) Error!source.ast.Module {
    return typedChoices(
        builder,
        every,
    ) catch |err| return @import("../authoring.zig").sourceError(err);
}
fn typedChoices(
    builder: *source.Builder,
    comptime every: bool,
) @import("../authoring.zig").Error!source.Module {
    const typed = @import("../authoring.zig");
    const library = @import("../library/choice.zig");
    const c = try typed.Context.init(builder);
    const boolean = try c.schema(bool);
    const pair = try c.record(.{ .first = boolean, .second = boolean });
    const family = try library.family(c, "example/boolean-choice");
    const options = .{
        .captures = .{ .continuation = &.{ boolean, family.capability() } },
        .residual = &.{},
    };
    const answer = if (every) try library.all(c, family, pair, options) else try library.first(c, family, pair, options);
    const schema = try c.handledSchema(answer.handler);
    const body_fn = try c.functionFor("two choices", schema);
    const body = try c.body(body_fn);
    const capability = try body.parameter("capability");
    const first = try body.performLocal(family.effect(), capability, try body.constant(void, {}));
    const second = try body.performLocal(family.effect(), capability, try body.constant(void, {}));
    try c.define(
        body_fn,
        try body.ret(try body.product(pair, .{ .first = first, .second = second })),
    );
    const main = try c.function("entry", .{}, answer.answer, &.{});
    const entry = try c.body(main);
    try c.define(
        main,
        try entry.ret(try entry.handleWith(
            answer.handler,
            try entry.lambda(body_fn, schema),
            .{},
        )),
    );
    return c.module(main, try c.schema(void));
}
pub const queensDfs = @import("queens_example.zig").dfs;
pub const queensBfs = @import("queens_example.zig").bfs;
pub const cellOrder = @import("cell_order_example.zig").build;
pub const nested = @import("control_examples.zig").nested;
pub const shallow = @import("control_examples.zig").shallow;
pub const injection = @import("injection_example.zig").build;
pub const indexed = @import("indexed_example.zig").build;
pub const abortCustody = @import("abort_example.zig").build;
pub const unwind = @import("unwind_example.zig").build;
pub const reentrant = @import("reentrant_example.zig").build;
pub const cloned = @import("reentrant_example.zig").cloned;
pub const reentrantWithResult = @import("reentrant_example.zig").withResult;
pub const shallowResumptions = @import("shallow_resume_example.zig").build;
pub const shallowInjection = @import("injection_example.zig").shallow;
pub const handleOperandOrder = @import("operand_order_example.zig").handle;
pub const protectOperandOrder = @import("operand_order_example.zig").protect;
pub const successorState = @import("successor_state_example.zig").build;
pub const clausePayload = @import("clause_payload_example.zig").build;
pub const clauseAbort = @import("clause_abort_example.zig").build;
pub const installations = @import("economy_examples.zig").installations;
pub const blobCapture = @import("economy_examples.zig").blobCapture;

/// Local capture precision with an unrelated narrow declaration. The producer
/// runs before capture; repeated deep resumes replay only the captured suffix.
pub fn localContinuation(b: *source.Builder, multi: bool) Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const fault = try b.constant(void, {});
    const produce = try b.effect(.{
        .identity = "local/producer",
        .payload = unit,
        .result = integer,
    });
    const observe = try b.effect(.{
        .identity = "local/branch",
        .payload = integer,
        .result = unit,
    });
    const ask = try b.effect(.{
        .identity = "local/ask",
        .payload = unit,
        .result = integer,
        .external = false,
        .control_use = if (multi) .multi else .linear,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = ask } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = ask,
        .input = integer,
        .answer = integer,
        .effects = &.{observe},
        .handled = &.{ask},
        .capture_bound = &.{integer},
        .mode = .deep,
        .use = if (multi) .multi else .linear,
    } } });
    const narrow = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = ask,
        .input = integer,
        .answer = integer,
        .effects = &.{observe},
        .handled = &.{ask},
        .mode = .deep,
        .use = if (multi) .multi else .linear,
    } } });
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{ observe, ask },
        .capture_bound = &.{integer},
    } } });
    const main = try b.declare(&.{}, integer, &.{ produce, observe }, &.{});
    const body = try b.declare(&.{cap}, integer, &.{ observe, ask }, &.{});
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    const clause = try b.declare(&.{ unit, token }, integer, &.{observe}, &.{});
    const unused = try b.declare(&.{ unit, narrow }, integer, &.{observe}, &.{});
    const produced = try b.variable(integer);
    const answer = try b.variable(integer);
    const total = try b.variable(integer);
    const ignored = try b.variable(unit);
    const perform = try b.term(.{ .perform = .{
        .effect = ask,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = fault,
    } });
    const sum = try binary(
        b,
        .integer_add,
        integer,
        try b.reference(produced),
        try b.reference(answer),
        fault,
    );
    const observed = try b.term(.{ .perform = .{
        .effect = observe,
        .payload = try b.reference(total),
    } });
    const suffix = try b.bind(
        total,
        try b.pure(sum),
        try b.bind(ignored, observed, try b.pure(try b.reference(total))),
    );
    try b.define(body, try b.bind(answer, perform, try b.term(.{ .yield_then = suffix })));
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const first = try b.variable(integer);
    const resume_first = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(clause, 1)),
        .argument = try b.constant(u64, 5),
    } });
    const tail = if (multi) blk: {
        const second = try b.variable(integer);
        const resume_second = try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(clause, 1)),
            .argument = try b.constant(u64, 7),
        } });
        break :blk try b.bind(
            second,
            resume_second,
            try b.pure(try binary(
                b,
                .integer_add,
                integer,
                try b.reference(first),
                try b.reference(second),
                fault,
            )),
        );
    } else try b.pure(try b.reference(first));
    try b.define(clause, try b.bind(first, resume_first, tail));
    // An unused linear token still has to be consumed by its declaration.
    const unused_resume = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(unused, 1)),
        .argument = try b.constant(u64, 0),
    } });
    try b.define(unused, unused_resume);
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .effects = &.{observe},
        .return_function = returns,
        .clauses = &.{.{ .effect = ask, .function = clause, .resumption = token }},
    });
    _ = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .effects = &.{observe},
        .return_function = returns,
        .clauses = &.{.{ .effect = ask, .function = unused, .resumption = narrow }},
    });
    const produced_once = try b.term(.{ .perform = .{ .effect = produce, .payload = fault } });
    const handled = try b.term(.{ .handle = .{
        .handler = handler,
        .body = try b.lambda(body, computation),
    } });
    try b.define(main, try b.bind(produced, produced_once, handled));
    return b.module(main, unit);
}
