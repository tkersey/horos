//! Emit one source term tree or its compiled data, without linking an evaluator.
const std = @import("std");
const horos = @import("horos");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const example = try std.fmt.parseInt(usize, args.next() orelse return error.MissingExample, 10);
    const format = args.next() orelse return error.MissingFormat;
    const emit_source = std.mem.eql(u8, format, "json");
    if (args.next() != null or (!emit_source and !std.mem.eql(u8, format, "bpi3")))
        return error.InvalidArguments;
    var builder = horos.source.Builder.init(init.gpa);
    defer builder.deinit();
    const module = try switch (example) {
        0 => horos.source.examples.lexical(&builder),
        1 => horos.source.examples.deep(&builder),
        2 => horos.source.examples.recursive(&builder),
        3 => horos.source.examples.choicesAll(&builder),
        4 => horos.source.examples.choicesFirst(&builder),
        5 => horos.source.examples.generator(&builder),
        6 => horos.source.examples.stateLocal(&builder),
        7 => horos.source.examples.stateShared(&builder),
        8 => horos.source.examples.resourceScalar(&builder),
        9 => horos.source.examples.resourcePair(&builder),
        10 => horos.source.examples.answers(&builder),
        11 => horos.source.examples.scopedReader(&builder),
        12 => horos.source.examples.writerRaise(&builder),
        13 => horos.source.examples.schedulerFifo(&builder),
        14 => horos.source.examples.queensDfs(&builder),
        15 => horos.source.examples.queensBfs(&builder),
        16 => horos.source.examples.cellOrder(&builder),
        17 => horos.source.examples.nested(&builder),
        18 => horos.source.examples.shallow(&builder),
        19 => horos.source.examples.injection(&builder),
        20 => horos.source.examples.indexed(&builder),
        21 => horos.source.examples.abortCustody(&builder),
        22 => horos.source.examples.unwind(&builder),
        23 => horos.source.examples.reentrant(&builder),
        24 => horos.source.examples.cloned(&builder),
        25 => horos.source.examples.clauseAbort(&builder),
        26 => horos.source.examples.boundedValues(&builder),
        27 => horos.source.examples.scalarContracts(&builder),
        28 => horos.source.examples.ownership(&builder),
        29 => horos.source.examples.shallowResumptions(&builder),
        30 => horos.source.examples.shallowInjection(&builder),
        31 => horos.source.examples.handleOperandOrder(&builder),
        32 => horos.source.examples.protectOperandOrder(&builder),
        33 => horos.source.examples.successorState(&builder),
        34 => horos.source.examples.clausePayload(&builder),
        35 => horos.source.examples.yieldingCleanup(&builder),
        36 => horos.source.examples.borrowOperands(&builder),
        37 => CleanupDisposal.build(&builder, .always),
        38 => CleanupDisposal.build(&builder, .running),
        39 => CleanupDisposal.build(&builder, .failure),
        40 => CleanupDisposal.ownedResult(&builder),
        41 => horos.source.examples.productProjection(&builder),
        42 => horos.source.examples.localContinuation(&builder, false),
        43 => horos.source.examples.localContinuation(&builder, true),
        else => error.UnknownExample,
    };
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    if (emit_source) {
        try std.json.Stringify.value(module, .{ .emit_strings_as_arrays = true }, &output.interface);
        try output.interface.writeByte('\n');
    } else {
        var compiled = try horos.program.compile(init.gpa, module);
        defer compiled.deinit();
        const bytes = try init.gpa.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
        defer init.gpa.free(bytes);
        _ = try compiled.encode(init.gpa, bytes);
        try output.interface.writeAll(bytes);
    }
    try output.interface.flush();
}

// Kept in the shipped emitter so its archive has no unlisted source dependency.
const CleanupDisposal = struct {
    const source = horos.source;
    const p = horos.data.program;

    pub const Mode = enum { always, running, failure };

    fn handlerFor(b: *source.Builder, identity: []const u8) source.Error!p.Handler {
        for (b.handlers.items) |handler| {
            if (handler.clauses.len == 1 and std.mem.eql(u8, b.effects.items[@intCast(handler.clauses[0].effect)].identity, identity)) return handler;
        }
        return error.InvalidSource;
    }

    fn appendLog(b: *source.Builder, cell: p.Id, message: p.Id) source.Error!p.Id {
        const cell_type = b.schemas.items[@intCast(b.values.items[@intCast(cell)].schema)].internal.cell;
        const before = try b.primitive(cell_type.element, .cell_get, &.{cell}, 0);
        const after = try b.primitive(cell_type.element, .sequence_append, &.{ before, message }, 0);
        return b.pure(try b.primitive(try b.scalar(void), .cell_set, &.{ cell, after }, 0));
    }

    fn lambdaFunction(b: *source.Builder, initial: p.Id) source.Error!p.Id {
        var value = initial;
        for (0..b.terms.items.len + 1) |_| {
            const expression = b.values.items[@intCast(value)].expression;
            if (expression == .lambda) return expression.lambda;
            if (expression != .variable) return error.InvalidSource;
            var found = false;
            for (b.terms.items) |term| {
                if (term == .bind and term.bind.variable == expression.variable) {
                    const bound = b.terms.items[@intCast(term.bind.value)];
                    if (bound != .value) return error.InvalidSource;
                    value = bound.value;
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidSource;
        }
        return error.InvalidSource;
    }

    pub fn build(b: *source.Builder, mode: Mode) source.Error!source.ast.Module {
        const original = try source.examples.writerRaise(b);
        const handler = try handlerFor(b, "example/writer");
        const clause = handler.clauses[0].function;
        const unit = try b.scalar(void);
        const cell = try b.reference(b.parameter(clause, 0));
        const message = try b.reference(b.parameter(clause, 1));
        const token = try b.reference(b.parameter(clause, 2));
        const result = try b.primitive(handler.input, .variant, &.{message}, 1);
        const answer = try b.term(.{ .call = .{
            .function = handler.return_function,
            .arguments = &.{ cell, result },
        } });
        const marked = try b.bind(try b.variable(unit), try appendLog(b, cell, try b.constant(u64, 99)), answer);
        const disposed = try b.bind(try b.variable(unit), try b.term(.{ .dispose = token }), marked);
        const selected = if (mode == .always) disposed else selected: {
            const condition = try b.primitive(try b.scalar(bool), .equal, &.{ message, try b.constant(u64, 3) }, 0);
            break :selected try b.term(.{ .conditional = .{
                .condition = condition,
                .when_true = disposed,
                .when_false = try b.term(.{ .resume_value = .{ .resumption = token, .argument = try b.constant(void, {}) } }),
            } });
        };
        b.functions.items[@intCast(clause)].body = try b.bind(try b.variable(unit), try appendLog(b, cell, message), selected);
        if (mode == .failure) {
            const raised = try handlerFor(b, "example/raise");
            const failure = try b.constant(void, {});
            for (b.terms.items) |*term| {
                if (term.* == .perform and term.perform.effect == raised.clauses[0].effect)
                    term.* = .{ .fail = failure };
            }
            for (b.terms.items) |term| {
                if (term != .protect) continue;
                const finalizer = try lambdaFunction(b, term.protect.cleanup);
                const previous = b.functions.items[@intCast(finalizer)].body.?;
                b.functions.items[@intCast(finalizer)].body = try b.term(.{ .yield_then = previous });
                break;
            }
        }
        return b.module(original.entry, original.failure);
    }

    /// The protected body returns an owned generator. Abandoning its cleanup must
    /// close that generator and execute its pending finalizer before the clause ends.
    pub fn ownedResult(b: *source.Builder) source.Error!source.ast.Module {
        return ownedResultTyped(b) catch |err| return horos.authoring.sourceError(err);
    }
    fn ownedResultTyped(b: *source.Builder) horos.authoring.Error!source.ast.Module {
        const a = horos.authoring;
        const c = try a.Context.init(b);
        const writer = horos.library.writer;
        const generator = horos.library.generator;
        const cleanup = horos.library.cleanup;
        const unit = try b.scalar(void);
        const integer = try b.scalar(u64);
        const region = b.region();
        const region_type = try b.schema(.{ .internal = .{ .region = region } });
        const logging_family = try writer.family(c, "example/cleanup-owner-writer", try c.schema(u64));
        const w = .{ .effect = try a.interop.operationId(c, logging_family.effect()), .capability = try a.interop.schemaId(c, logging_family.capability()) };
        const definition = try generator.create(c, "example/cleanup-owned-yield", try c.schema(void), try c.schema(u64), try c.schema(void), .{
            .captures = .{ .continuation = &.{ try c.schema(void), try c.schema(u64), logging_family.capability() } },
            .borrowed_regions = &.{try a.interop.region(c, region)},
            .residual = &.{logging_family.effect()},
        });
        // This fixture varies cleanup/disposal IR around one checked family.
        const g = .{
            .capability = try a.interop.schemaId(c, definition.capability()),
            .effect = try a.interop.operationId(c, definition.effect()),
            .handler = try a.interop.handlerId(c, definition.handler()),
            .answer = try a.interop.schemaId(c, definition.answer()),
            .yielded = try a.interop.schemaId(c, definition.yielded()),
            .package = try a.interop.schemaId(c, definition.package()),
            .resumption = try a.interop.schemaId(c, definition.resumption()),
        };
        const capture_ids = [_]horos.data.program.Id{ unit, integer, g.capability, g.answer, g.resumption, g.package, g.yielded };
        var captures: [capture_ids.len]*const a.Schema(a.Dynamic) = undefined;
        for (capture_ids, &captures) |id, *schema| schema.* = try a.interop.schema(c, id);
        const logging_handler = try writer.interpret(c, logging_family, try c.schema(u64), try a.interop.region(c, region), .{ .continuation = &captures }, &.{});
        const written = .{ .answer = try a.interop.schemaId(c, logging_handler.answer), .cell = try a.interop.schemaId(c, logging_handler.cell), .sequence = try a.interop.schemaId(c, logging_handler.sequence), .handler = try a.interop.handlerId(c, logging_handler.handler) };
        const fixture_entry = try b.declare(&.{}, written.answer, &.{}, &.{});
        const inside = try b.declare(&.{region_type}, written.answer, &.{}, &.{region});
        const written_body = try b.declare(&.{w.capability}, integer, &.{w.effect}, &.{region});
        const write_capability = try b.reference(b.parameter(written_body, 0));
        const info = try cleanup.exitInfo(b, unit);
        const start = try b.declare(&.{g.capability}, unit, &.{ w.effect, g.effect }, &.{region});
        const generated_body = try b.declare(&.{}, unit, &.{g.effect}, &.{region});
        const generated_cleanup = try b.declare(&.{info}, unit, &.{w.effect}, &.{region});
        try b.define(generated_body, try b.term(.{ .perform = .{
            .effect = g.effect,
            .capability = try b.reference(b.parameter(start, 0)),
            .payload = try b.constant(u64, 1),
        } }));
        try b.define(generated_cleanup, try b.term(.{ .perform = .{
            .effect = w.effect,
            .capability = write_capability,
            .payload = try b.constant(u64, 7),
        } }));
        const generated_body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = unit,
            .effects = &.{g.effect},
            .capture_bound = &.{g.capability},
            .regions = &.{region},
        } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{info},
            .result = unit,
            .effects = &.{w.effect},
            .capture_bound = &.{w.capability},
            .regions = &.{region},
        } } });
        try b.define(start, try b.term(.{ .protect = .{
            .body = try b.lambda(generated_body, generated_body_type),
            .cleanup = try b.lambda(generated_cleanup, cleanup_type),
        } }));
        const start_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{g.capability},
            .result = unit,
            .effects = &.{ w.effect, g.effect },
            .capture_bound = &.{w.capability},
            .regions = &.{region},
        } } });
        const body = try b.declare(&.{}, g.answer, &.{w.effect}, &.{region});
        try b.define(body, try b.term(.{ .handle = .{ .handler = g.handler, .body = try b.lambda(start, start_type) } }));
        const finalizer = try b.declare(&.{info}, unit, &.{w.effect}, &.{region});
        try b.define(finalizer, try b.term(.{ .perform = .{
            .effect = w.effect,
            .capability = write_capability,
            .payload = try b.constant(u64, 3),
        } }));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = g.answer,
            .effects = &.{w.effect},
            .capture_bound = &.{w.capability},
            .regions = &.{region},
        } } });
        const protected = try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(finalizer, cleanup_type) } });
        const answer = try b.variable(g.answer);
        const done = try b.variable(unit);
        const yielded = try b.variable(g.yielded);
        const element = try b.variable(integer);
        const package = try b.variable(g.package);
        const result = try b.pure(try b.constant(u64, 42));
        const closed = try b.bind(try b.variable(unit), try b.term(.{ .dispose = try b.primitive(g.resumption, .unpack, &.{try b.reference(package)}, 0) }), result);
        const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(yielded), .variables = &.{ element, package }, .body = closed } });
        const matched = try b.term(.{ .match_sum = .{ .value = try b.reference(answer), .cases = &.{ .{ .variable = done, .body = result }, .{ .variable = yielded, .body = unpack } } } });
        try b.define(written_body, try b.bind(answer, protected, matched));
        const written_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{w.capability},
            .result = integer,
            .effects = &.{w.effect},
            .regions = &.{region},
        } } });
        const cell = try b.variable(written.cell);
        const installed = try b.term(.{ .handle = .{
            .handler = written.handler,
            .body = try b.lambda(written_body, written_type),
            .state = &.{try b.reference(cell)},
        } });
        const empty = try b.primitive(written.sequence, .sequence, &.{}, 0);
        try b.define(inside, try b.bind(cell, try b.pure(try b.primitive(written.cell, .cell_new, &.{ try b.reference(b.parameter(inside, 0)), empty }, 0)), installed));
        const inside_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{region_type},
            .result = written.answer,
            .regions = &.{region},
        } } });
        try b.define(fixture_entry, try b.term(.{ .with_region = .{ .region = region, .body = try b.lambda(inside, inside_type) } }));
        const handler = b.handlers.items[@intCast(written.handler)];
        const clause = handler.clauses[0].function;
        const log = try b.reference(b.parameter(clause, 0));
        const message = try b.reference(b.parameter(clause, 1));
        const token = try b.reference(b.parameter(clause, 2));
        const returned = try b.term(.{ .call = .{ .function = handler.return_function, .arguments = &.{ log, message } } });
        const marked = try b.bind(try b.variable(unit), try appendLog(b, log, try b.constant(u64, 99)), returned);
        const disposed = try b.bind(try b.variable(unit), try b.term(.{ .dispose = token }), marked);
        const condition = try b.primitive(try b.scalar(bool), .equal, &.{ message, try b.constant(u64, 3) }, 0);
        const resumed = try b.term(.{ .resume_value = .{ .resumption = token, .argument = try b.constant(void, {}) } });
        b.functions.items[@intCast(clause)].body = try b.bind(try b.variable(unit), try appendLog(b, log, message), try b.term(.{ .conditional = .{ .condition = condition, .when_true = disposed, .when_false = resumed } }));
        return b.module(fixture_entry, unit);
    }
};
