//! Executable public-surface acceptance cases, also compiled by the authoring suite.
const std = @import("std");
const source = @import("source.zig");
const a = @import("authoring.zig");
const data = @import("horos_data");
const p = data.program;
pub const Kind = enum {
    deep,
    shallow,
    transform_deep,
    transform_shallow,
    bypass,
    twice,
    cleanup,
    shared_cleanup,
    lazy,
    demanded,
    failure_before,
    failure_after,
    match,
    configuration,
    arithmetic,
    arithmetic_fail,
    dispose,
    region,
    reusable_body,
    imported_scoped,
    cleanup_named,
    imported_sequence,
    obligations,
    cells_independent,
    cells_shared,
    memo_independent,
    memo_shared,
    state_local,
    state_shared,
    state_recursive_local,
    state_recursive_shared,
    hyper_duplicate,
    hyper_configured,
    hyper_lazy,
    capture_order,
    handler_duplicate,
    handler_mixed_mode,
    handler_effect_duplicate,
    borrow_contexts,
};

pub fn build(raw: *source.Builder, kind: Kind) !source.Module {
    return switch (kind) {
        inline .deep,
        .shallow,
        .transform_deep,
        .transform_shallow,
        .bypass,
        .dispose,
        .reusable_body,
        => |selected| handlerCase(raw, selected),
        .twice => twiceCase(raw),
        .cleanup => cleanupCase(raw),
        .shared_cleanup => sharedCleanupCase(raw),
        .obligations => obligationsCase(raw, true),
        .lazy, .demanded => delayedCase(raw, kind == .demanded),
        .failure_before, .failure_after => failureCase(raw, kind == .failure_after),
        .match => matchCase(raw),
        .configuration => configurationCase(raw),
        .region => regionCase(raw),
        .imported_scoped => importedScopedCase(raw),
        .cleanup_named => cleanupNamedCase(raw),
        .imported_sequence => importedSequenceCase(raw),
        inline .arithmetic, .arithmetic_fail => |selected| arithmeticCase(
            raw,
            selected == .arithmetic_fail,
        ),
        .cells_independent => @import("coalescing_state_cases.zig").build(raw, .cells_independent),
        .cells_shared => @import("coalescing_state_cases.zig").build(raw, .cells_shared),
        .memo_independent => @import("coalescing_state_cases.zig").build(raw, .memo_independent),
        .memo_shared => @import("coalescing_state_cases.zig").build(raw, .memo_shared),
        .state_local => @import("source/state_choice_example.zig").local(raw),
        .state_shared => @import("source/state_choice_example.zig").shared(raw),
        .state_recursive_local => @import("source/state_choice_example.zig").recursiveLocal(raw),
        .state_recursive_shared => @import("source/state_choice_example.zig").recursiveShared(raw),
        .hyper_duplicate => @import("coalescing_hyper_cases.zig").build(raw, .duplicate),
        .hyper_configured => @import("coalescing_hyper_cases.zig").build(raw, .configured),
        .hyper_lazy => @import("coalescing_hyper_cases.zig").build(raw, .lazy),
        .capture_order => @import("coalescing_capture_case.zig").build(raw),
        .handler_duplicate => @import("coalescing_handler_cases.zig").build(raw, .duplicate),
        .handler_mixed_mode => @import("coalescing_handler_cases.zig").build(raw, .mixed_mode),
        .handler_effect_duplicate => @import("coalescing_handler_cases.zig").build(
            raw,
            .effect_duplicate,
        ),
        .borrow_contexts => @import("coalescing_borrow_cases.zig").build(raw, false),
    };
}
fn handlerCase(raw: *source.Builder, comptime kind: Kind) !source.Module {
    const c = try a.Context.init(raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const transformed = kind == .transform_deep or kind == .transform_shallow;
    const answer = if (transformed) try c.record(.{ .answer = integer }) else integer;
    const mode: p.Mode = if (kind == .shallow or kind == .transform_shallow) .shallow else .deep;
    const use: p.Use = if (kind == .bypass) .affine else .linear;
    const question = try c.local("case/question", unit, unit, use);
    const cap = try c.capability(question);
    const h = try c.handler(question, integer, answer, .{
        .mode = mode,
        .use = use,
        .residual = if (mode == .shallow) &.{question} else &.{},
        .captures = &.{ integer, cap, unit },
        .body_use = if (kind == .reusable_body) .reusable else .linear,
    });
    const returns_fn = try c.returnFunction(h);
    const returns = try c.body(returns_fn);
    const returned = try returns.constant(u64, 99);
    try c.define(returns_fn, try returns.ret(if (transformed)
        try returns.product(answer, .{ .answer = returned })
    else
        returned));
    try defineHandlerClause(c, kind, transformed, mode, h, answer);
    const body_schema = try c.handledSchema(h);
    const work = try c.functionFor("work", body_schema);
    const body = try c.body(work);
    _ = try body.performLocal(
        question,
        try body.parameter("capability"),
        try body.constant(void, {}),
    );
    try c.define(work, try body.ret(try body.constant(u64, 42)));
    const entry = try c.function(
        "entry",
        .{},
        answer,
        if (mode == .shallow) &.{question} else &.{},
    );
    const entry_body = try c.body(entry);
    const callable_value = try entry_body.lambda(work, body_schema);
    const first = try entry_body.handleWith(h, callable_value, .{});
    const result = if (kind == .reusable_body) try entry_body.checkedAdd(
        first,
        try entry_body.handleWith(h, callable_value, .{}),
        try c.literalFailure(void, {}),
    ) else first;
    try c.define(entry, try entry_body.ret(result));
    return c.module(entry, unit);
}
fn twiceCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const lookup = try c.external("case/lookup", integer, integer);
    const schema = try c.callable(
        .{},
        integer,
        &.{lookup},
        .{ .use = .reusable, .captures = &.{} },
    );
    const work = try c.functionFor("request", schema);
    const body = try c.body(work);
    try c.define(work, try body.ret(try body.perform(lookup, try body.constant(u64, 19))));
    const twice = try c.twice(schema);
    const pair = try c.record(.{ .first = integer, .second = integer });
    const entry = try c.function("entry", .{}, pair, &.{lookup});
    const entry_body = try c.body(entry);
    try c.define(
        entry,
        try entry_body.ret(try entry_body.call(
            twice,
            .{ .callable = try entry_body.lambda(work, schema) },
        )),
    );
    return c.module(entry, unit);
}
/// A local resumption must be allowed to retain its pending protected cleanup.
pub fn obligationsCase(raw: *source.Builder, allowed: bool) !source.Module {
    const c = try a.Context.init(raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const question = try c.local("case/question", unit, unit, .linear);
    const cap = try c.capability(question);
    const release = try c.external("case/release", unit, unit);
    const responder = try c.function("reply", .{ .payload = unit }, unit, &.{});
    const response = try c.body(responder);
    try c.define(responder, try response.ret(try response.parameter("payload")));
    const h = try c.responder(question, integer, responder, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{release},
        .captures = &.{ integer, unit, cap },
        .obligations = allowed,
    });
    const handled = try c.handledSchema(h);
    const work = try c.functionFor("handled work", handled);
    const body = try c.body(work);
    const capability = try body.parameter("capability");
    const inside = try c.callable(.{}, integer, &.{question}, .{
        .use = .linear,
        .captures = &.{cap},
    });
    const inner = try c.functionFor("protected question", inside);
    const inner_body = try body.closureBody(inner);
    _ = try inner_body.performLocal(question, capability, try inner_body.constant(void, {}));
    try c.define(inner, try inner_body.ret(try inner_body.constant(u64, 42)));
    const cleanup_schema = try c.callable(
        .{ .exit = try c.cleanupInfo(unit) },
        unit,
        &.{release},
        .{ .use = .linear, .captures = &.{} },
    );
    const cleanup = try c.functionFor("release", cleanup_schema);
    const finalizer = try c.body(cleanup);
    const released = try finalizer.perform(release, try finalizer.constant(void, {}));
    try c.define(cleanup, try finalizer.ret(released));
    const protected = try body.protect(
        try body.lambda(inner, inside),
        try body.lambda(cleanup, cleanup_schema),
        .{},
    );
    try c.define(work, try body.ret(protected));
    const entry = try c.function("entry", .{}, integer, &.{release});
    const entry_body = try c.body(entry);
    const result = try entry_body.handleWith(h, try entry_body.lambda(work, handled), .{});
    try c.define(entry, try entry_body.ret(result));
    return c.module(entry, unit);
}
fn sharedCleanupCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const lookup = try c.external("case/lookup", integer, integer);
    const release = try c.external("case/release", integer, unit);
    const entry = try c.function(
        "entry",
        .{ .outer = integer, .inner = integer },
        integer,
        &.{ lookup, release },
    );
    const root = try c.body(entry);
    const cleanup_shape = try c.callable(
        .{ .exit = try c.cleanupInfo(unit) },
        unit,
        &.{release},
        .{ .use = .linear, .captures = &.{integer} },
    );
    var cleanups: [2]@TypeOf(try c.functionFor("", cleanup_shape)) = undefined;
    inline for (.{ "outer", "inner" }, 0..) |name, index| {
        const cleanup = &cleanups[index];
        cleanup.* = try c.functionFor(name, cleanup_shape);
        const body = try root.closureBody(cleanup.*);
        try c.define(cleanup.*, try body.ret(try body.perform(release, try root.parameter(name))));
    }
    const work_shape = try c.callable(
        .{},
        integer,
        &.{lookup},
        .{ .use = .linear, .captures = &.{} },
    );
    const work = try c.functionFor("work", work_shape);
    const body = try c.body(work);
    const reply = try body.perform(lookup, try body.constant(u64, 19));
    try c.define(
        work,
        try body.ret(try body.checkedAdd(
            reply,
            try body.constant(u64, 1),
            try c.literalFailure(void, {}),
        )),
    );
    const inside_shape = try c.callable(
        .{},
        integer,
        &.{ lookup, release },
        .{ .use = .linear, .captures = &.{integer} },
    );
    const inside = try c.functionFor("inner protection", inside_shape);
    const nested = try root.closureBody(inside);
    try c.define(inside, try nested.ret(try nested.protect(
        try nested.lambda(work, work_shape),
        try nested.lambda(cleanups[1], cleanup_shape),
        .{},
    )));
    try c.define(entry, try root.ret(try root.protect(
        try root.lambda(inside, inside_shape),
        try root.lambda(cleanups[0], cleanup_shape),
        .{},
    )));
    return c.module(entry, unit);
}

fn cleanupCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const lookup = try c.external("case/lookup", integer, integer);
    const release = try c.external("case/release", unit, unit);
    const work_schema = try c.callable(
        .{},
        integer,
        &.{lookup},
        .{ .use = .linear, .captures = &.{} },
    );
    const work = try c.functionFor("protected work", work_schema);
    const body = try c.body(work);
    try c.define(work, try body.ret(try body.perform(lookup, try body.constant(u64, 19))));
    const cleanup_schema = try c.callable(
        .{ .exit = try c.cleanupInfo(unit) },
        unit,
        &.{release},
        .{ .use = .linear, .captures = &.{} },
    );
    const cleanup = try c.functionFor("local cleanup", cleanup_schema);
    const finalizer = try c.body(cleanup);
    try c.define(
        cleanup,
        try finalizer.ret(try finalizer.perform(release, try finalizer.constant(void, {}))),
    );
    const entry = try c.function("entry", .{}, integer, &.{ lookup, release });
    const entry_body = try c.body(entry);
    const result = try entry_body.protect(
        try entry_body.lambda(work, work_schema),
        try entry_body.lambda(cleanup, cleanup_schema),
        .{},
    );
    const after = try entry_body.checkedAdd(
        result,
        try entry_body.constant(u64, 1),
        try c.literalFailure(void, {}),
    );
    try c.define(entry, try entry_body.ret(after));
    return c.module(entry, unit);
}
fn delayedCase(raw: *source.Builder, demanded: bool) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const delay = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{} });
    const failure = try c.functionFor("delayed overflow", delay);
    const delayed = try c.body(failure);
    const result = try delayed.checkedAdd(
        try delayed.constant(u64, std.math.maxInt(u64)),
        try delayed.constant(u64, 1),
        try c.literalFailure(void, {}),
    );
    try c.define(failure, try delayed.ret(result));
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    const thunk = try body.lambda(failure, delay);
    try c.define(
        entry,
        try body.ret(if (demanded) try body.apply(thunk, .{}) else try body.constant(u64, 42)),
    );
    return c.module(entry, unit);
}
fn failureCase(raw: *source.Builder, after: bool) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const lookup = try c.external("case/lookup", integer, integer);
    const entry = try c.function("entry", .{}, integer, &.{lookup});
    const body = try c.body(entry);
    if (after) _ = try body.perform(lookup, try body.constant(u64, 19));
    const failed = try body.checkedAdd(
        try body.constant(u64, std.math.maxInt(u64)),
        try body.constant(u64, 1),
        try c.literalFailure(void, {}),
    );
    if (!after) _ = try body.perform(lookup, try body.constant(u64, 19));
    try c.define(entry, try body.ret(failed));
    return c.module(entry, unit);
}
fn matchCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const sum = try c.alternatives(.{ .left = integer, .right = integer });
    const entry = try c.function("entry", .{ .choice = sum }, integer, &.{});
    const body = try c.body(entry);
    const choice = try body.parameter("choice");
    const left = try body.caseOf(try body.parameter("choice"), "left");
    const right = try body.caseOf(try body.parameter("choice"), "right");
    const plus = try right.body().checkedAdd(
        right.payload(),
        try right.body().constant(u64, 1),
        try c.literalFailure(void, {}),
    );
    const result = try body.match(
        choice,
        .{ .right = try right.ret(plus), .left = try left.ret(left.payload()) },
    );
    try c.define(entry, try body.ret(result));
    return c.module(entry, try c.schema(void));
}
fn regionCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const region = try c.region();
    const schema = try c.regionBodySchema(
        region,
        .{ .value = integer },
        integer,
        &.{},
        .{ .use = .linear, .captures = &.{} },
    );
    const work = try c.functionFor("scoped region", schema);
    const inner = try c.body(work);
    try c.define(work, try inner.ret(try inner.parameter("value")));
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    const value = try body.withRegion(
        region,
        try body.lambda(work, schema),
        .{ .value = try body.constant(u64, 42) },
    );
    try c.define(entry, try body.ret(value));
    return c.module(entry, try c.schema(void));
}
fn arithmeticCase(raw: *source.Builder, comptime fail: bool) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const fields = .{
        .add = integer,
        .subtract = integer,
        .multiply = integer,
        .divide = integer,
        .remainder = integer,
    };
    const result_schema = if (fail) integer else try c.record(fields);
    const entry = try c.function("entry", .{}, result_schema, &.{});
    const body = try c.body(entry);
    const left = try body.constant(u64, 5);
    const right = try body.constant(u64, if (fail) 0 else 2);
    const failure = try c.literalFailure(void, {});
    if (fail) {
        const result = try body.checked(
            .divide,
            left,
            right,
            .{ .overflow = failure, .division_by_zero = failure },
        );
        try c.define(entry, try body.ret(result));
    } else {
        var values: struct {
            add: *const a.Value(a.Shape(u64)),
            subtract: *const a.Value(a.Shape(u64)),
            multiply: *const a.Value(a.Shape(u64)),
            divide: *const a.Value(a.Shape(u64)),
            remainder: *const a.Value(a.Shape(u64)),
        } = undefined;
        inline for (std.enums.values(a.Arithmetic)) |op| @field(
            values,
            @tagName(op),
        ) = try body.checked(
            op,
            left,
            right,
            .{
                .overflow = failure,
                .division_by_zero = if (op == .divide or op == .remainder) failure else null,
            },
        );
        try c.define(entry, try body.ret(try body.product(result_schema, values)));
    }
    return c.module(entry, try c.schema(void));
}
const Configured = struct {
    value: u64,
    fn define(
        self: Configured,
        c: *a.Context,
        integer: *const a.Schema(a.Shape(u64)),
    ) !*const a.Function(a.Signature(
        @import("horos_data").schema.native.Fields(&.{}, &.{}),
        a.Shape(u64),
    )) {
        const function = try c.function("configured", .{}, integer, &.{});
        const body = try c.body(function);
        try c.define(function, try body.ret(try body.constant(u64, self.value)));
        return function;
    }
};
fn configurationCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const pair = try c.record(.{ .first = integer, .second = integer });
    const first = try (Configured{ .value = 7 }).define(c, integer);
    const second = try (Configured{ .value = 11 }).define(c, integer);
    const entry = try c.function("entry", .{}, pair, &.{});
    const body = try c.body(entry);
    const result = try body.product(
        pair,
        .{ .first = try body.call(first, .{}), .second = try body.call(second, .{}) },
    );
    try c.define(entry, try body.ret(result));
    return c.module(entry, try c.schema(void));
}
fn importedScopedCase(raw: *source.Builder) !source.Module {
    const unit_id = try raw.scalar(void);
    const integer_id = try raw.scalar(u64);
    const inside_id = try raw.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer_id,
        .use = .linear,
    } } });
    const operation_id = try raw.effect(.{
        .identity = "imported/scoped",
        .payload = unit_id,
        .result = integer_id,
        .external = false,
        .bodies = &.{inside_id},
    });
    const c = try a.Context.init(raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const inside = try a.interop.schema(c, inside_id);
    const operation = try a.interop.operation(c, operation_id);
    const h = try c.handler(
        operation,
        integer,
        integer,
        .{ .mode = .deep, .use = .linear, .residual = &.{}, .captures = &.{} },
    );
    const returns_fn = try c.returnFunction(h);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
    const clause_fn = try c.clauseFunction(h);
    const clause = try c.body(clause_fn);
    const reply = try clause.apply(try clause.parameter("0"), .{});
    try c.define(
        clause_fn,
        try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), reply)),
    );
    const helper = try c.functionFor("inside", inside);
    const helper_body = try c.body(helper);
    try c.define(helper, try helper_body.ret(try helper_body.constant(u64, 42)));
    const work_schema = try c.handledSchema(h);
    const work = try c.functionFor("work", work_schema);
    const work_body = try c.body(work);
    const result = try work_body.performScoped(
        operation,
        try work_body.parameter("capability"),
        try work_body.constant(void, {}),
        .{ .@"0" = try work_body.lambda(helper, inside) },
    );
    try c.define(work, try work_body.ret(result));
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    try c.define(
        entry,
        try body.ret(try body.handleWith(h, try body.lambda(work, work_schema), .{})),
    );
    return c.module(entry, unit);
}
fn cleanupNamedCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const failure = try c.record(.{ .code = integer });
    const info = try c.cleanupInfo(failure);
    const entry = try c.function("inspect cleanup", .{ .exit = info }, integer, &.{});
    const body = try c.body(entry);
    const primary = try body.field(try body.parameter("exit"), "0");
    const normal = try body.caseOf(primary, "0");
    const failed = try body.caseOf(primary, "1");
    const cancelled = try body.caseOf(primary, "2");
    const disposed = try body.caseOf(primary, "3");
    try c.define(entry, try body.ret(try body.match(primary, .{
        .@"0" = try normal.ret(try normal.body().constant(u64, 0)),
        .@"1" = try failed.ret(try failed.body().field(failed.payload(), "code")),
        .@"2" = try cancelled.ret(try cancelled.body().constant(u64, 0)),
        .@"3" = try disposed.ret(try disposed.body().constant(u64, 0)),
    })));
    return c.module(entry, try c.schema(void));
}
fn importedSequenceCase(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const unit = try c.schema(void);
    const sequence = try c.sequence(unit);
    const imported = try a.interop.schema(c, try a.interop.schemaId(c, sequence));
    const entry = try c.function("compatible sequence", .{ .items = imported }, sequence, &.{});
    const body = try c.body(entry);
    const result = try body.concat(
        try body.parameter("items"),
        try body.sequenceValue(sequence, &.{}),
        .{},
    );
    try c.define(entry, try body.ret(result));
    return c.module(entry, unit);
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const kind = std.meta.stringToEnum(Kind, args.next() orelse return error.MissingKind) orelse
        return error.InvalidKind;
    const format = args.next() orelse "bpi3";
    if (args.next() != null) return error.UnexpectedArgument;
    var raw = source.Builder.init(init.gpa);
    defer raw.deinit();
    const module = try build(&raw, kind);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    if (std.mem.eql(u8, format, "json")) {
        try std.json.Stringify.value(
            module,
            .{ .emit_strings_as_arrays = true },
            &output.interface,
        );
    } else {
        var compiled = try source.lowerObserved(init.gpa, module, .{});
        defer compiled.deinit();
        const bytes = try init.gpa.alloc(
            u8,
            try data.program_image.encodedLength(compiled.program),
        );
        defer init.gpa.free(bytes);
        _ = try compiled.encode(init.gpa, bytes);
        try output.interface.writeAll(bytes);
    }
    try output.interface.flush();
}

fn defineHandlerClause(
    c: *a.Context,
    comptime kind: Kind,
    comptime transformed: bool,
    comptime mode: p.Mode,
    h: anytype,
    answer: anytype,
) a.Error!void {
    const clause_fn = try c.clauseFunction(h);
    const clause = try c.body(clause_fn);
    if (kind == .dispose) _ = try clause.dispose(try clause.parameter("resumption"));
    const resumed = if (kind == .bypass or kind == .dispose) try clause.constant(
        u64,
        17,
    ) else try clause.resumeValue(
        try clause.parameter("resumption"),
        try clause.constant(void, {}),
    );
    const scalar = if (transformed and mode == .deep) try clause.field(
        resumed,
        "answer",
    ) else resumed;
    const plus = try clause.checkedAdd(
        scalar,
        try clause.constant(u64, 1),
        try c.literalFailure(void, {}),
    );
    try c.define(clause_fn, try clause.ret(if (transformed)
        try clause.product(answer, .{ .answer = plus })
    else
        plus));
}
