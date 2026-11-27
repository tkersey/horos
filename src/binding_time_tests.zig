const std = @import("std");
const source = @import("source.zig");
const a = @import("authoring.zig");
const stage = @import("library/stage.zig");
const data = @import("horos_data");
const testing = std.testing;
const Hint = data.binding_time.Hint;

const Staging = enum { plain, hinted, conflicting };

const Interpreter = struct {
    raw: source.Builder,
    context: *a.Context,
    module: source.Module,
    hints: ?source.Hints,

    fn deinit(self: *Interpreter) void {
        self.raw.deinit();
        self.* = undefined;
    }
};

fn hint(
    body: anytype,
    staging: Staging,
    kind: data.binding_time.Kind,
    value: anytype,
) !@TypeOf(value) {
    return switch (staging) {
        .plain => value,
        .hinted => switch (kind) {
            .context => stage.context(body, value),
            .residual => stage.residual(body, value),
        },
        .conflicting => stage.context(body, try stage.residual(body, value)),
    };
}

fn interpreter(allocator: std.mem.Allocator, staging: Staging) !Interpreter {
    var result: Interpreter = .{
        .raw = source.Builder.init(allocator),
        .context = undefined,
        .module = undefined,
        .hints = null,
    };
    errdefer result.raw.deinit();
    const c = try a.Context.init(&result.raw);
    const integer = try c.schema(u64);
    const fault = try c.literalFailure(u64, 1);
    const run = try c.function(
        "run",
        .{ .pc = integer, .limit = integer, .acc = integer },
        integer,
        .{},
    );
    const body = try c.body(run);
    const pc = try hint(body, staging, .context, try body.parameter("pc"));
    const limit = try body.parameter("limit");
    const acc = try hint(body, staging, .residual, try body.parameter("acc"));
    const step = try body.branch();
    const next = try hint(step, staging, .context, try step.checkedAdd(
        pc,
        try step.constant(u64, 1),
        fault,
    ));
    const total = try step.checkedAdd(acc, pc, fault);
    const recurse = try step.call(run, .{ .pc = next, .limit = limit, .acc = total });
    const done = try body.branch();
    try c.define(run, try body.ret(try body.conditional(
        try body.less(pc, limit),
        try step.ret(recurse),
        try done.ret(acc),
    )));
    const entry = try c.function("entry", .{}, integer, .{});
    const start = try c.body(entry);
    const zero = try start.constant(u64, 0);
    try c.define(entry, try start.ret(try start.call(run, .{
        .pc = zero,
        .limit = try start.constant(u64, 10),
        .acc = zero,
    })));
    result.context = c;
    result.module = try c.module(entry, integer);
    result.hints = c.hints();
    return result;
}

fn wide(allocator: std.mem.Allocator, staging: Staging) !Interpreter {
    var result: Interpreter = .{
        .raw = source.Builder.init(allocator),
        .context = undefined,
        .module = undefined,
        .hints = null,
    };
    errdefer result.raw.deinit();
    const c = try a.Context.init(&result.raw);
    const integer = try c.schema(u64);
    const fault = try c.literalFailure(u64, 1);
    const helper = try c.function("helper", .{ .x = integer }, integer, .{});
    const inner = try c.body(helper);
    try c.define(helper, try inner.ret(try inner.parameter("x")));
    const function = try c.function("wide", .{ .x = integer }, integer, .{});
    const body = try c.body(function);
    const x = try body.parameter("x");
    var chained = x;
    for (0..70) |_| chained = try body.checkedAdd(chained, try body.constant(u64, 1), fault);
    const first = try hint(body, staging, .context, try body.call(helper, .{ .x = chained }));
    const second = try hint(body, staging, .residual, try body.call(helper, .{ .x = x }));
    try c.define(function, try body.ret(try body.checkedAdd(first, second, fault)));
    const entry = try c.function("entry", .{}, integer, .{});
    const start = try c.body(entry);
    try c.define(entry, try start.ret(try start.call(function, .{
        .x = try start.constant(u64, 0),
    })));
    result.context = c;
    result.module = try c.module(entry, integer);
    result.hints = c.hints();
    return result;
}

fn executableBytes(allocator: std.mem.Allocator, program: data.activation.Program) ![]u8 {
    return data.program_image.encodeAlloc(allocator, .unhinted(program));
}

fn compileBuilt(
    construct: anytype,
    staging: Staging,
    options: source.CompileOptions,
) !source.Compiled {
    var built = try construct(testing.allocator, staging);
    defer built.deinit();
    var selected = options;
    selected.hints = built.hints;
    return source.lowerObserved(testing.allocator, built.module, selected);
}

fn compileInterpreter(staging: Staging, options: source.CompileOptions) !source.Compiled {
    return compileBuilt(interpreter, staging, options);
}

fn expectSameExecutable(left: source.Compiled, right: source.Compiled) !void {
    const left_bytes = try executableBytes(testing.allocator, left.program);
    defer testing.allocator.free(left_bytes);
    const right_bytes = try executableBytes(testing.allocator, right.program);
    defer testing.allocator.free(right_bytes);
    try testing.expectEqualSlices(u8, left_bytes, right_bytes);
}

fn interpreterFunction(program: data.activation.Program) !u64 {
    for (program.functions, 0..) |function, id| if (function.inputs.len == 3) return id;
    return error.TestExpectedInterpreter;
}

fn kindAt(hints: []const Hint, function: u64, slot: u64) ?data.binding_time.Kind {
    for (hints) |item| if (item.function == function and item.slot == slot) return item.kind;
    return null;
}

test "stage hints are identities over typed value handles" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const entry = try c.function("entry", .{ .x = integer }, integer, .{});
    const body = try c.body(entry);
    const x = try body.parameter("x");
    try testing.expect(try stage.context(body, x) == x);
    try testing.expect(try stage.residual(body, x) == x);
    try testing.expectEqual(2, raw.hints.items.len);
    try testing.expectEqual(data.binding_time.Kind.context, raw.hints.items[0].kind);
    try testing.expectEqual(data.binding_time.Kind.residual, raw.hints.items[1].kind);
    try testing.expectEqual(null, c.hints());
    try c.define(entry, try body.ret(x));
    const module = try c.module(entry, integer);
    try testing.expectEqualSlices(source.Hint, raw.hints.items, c.hints().?.table);
    try testing.expect(try c.hints().?.recordedAgainst(module));
    try testing.expectError(error.InvalidSource, raw.hint(raw.values.items.len, .context));
}

test "hinted and unhinted interpreters compile to identical executable records" {
    var plain = try compileInterpreter(.plain, .{});
    defer plain.deinit();
    var hinted = try compileInterpreter(.hinted, .{});
    defer hinted.deinit();
    try expectSameExecutable(plain, hinted);
    try testing.expectEqual(0, plain.hints.len);
    const plain_bytes = try plain.encode(testing.allocator);
    defer testing.allocator.free(plain_bytes);
    const hinted_bytes = try hinted.encode(testing.allocator);
    defer testing.allocator.free(hinted_bytes);
    try testing.expectEqualSlices(u8, plain_bytes[20..], hinted_bytes[20..plain_bytes.len]);
    var decoded = try data.program_image.decode(testing.allocator, hinted_bytes);
    defer decoded.deinit();
    try testing.expectEqualSlices(Hint, hinted.hints, decoded.hints);
    const erased = try executableBytes(testing.allocator, decoded.program);
    defer testing.allocator.free(erased);
    try testing.expectEqualSlices(u8, plain_bytes, erased);
    try testing.expect(!std.mem.eql(u8, &decoded.identity, &try data.program_image.identity(
        testing.allocator,
        .unhinted(decoded.program),
    )));
    try testing.expectEqual(decoded.identity, try data.program_image.identity(
        testing.allocator,
        hinted.image(),
    ));
}

test "stage hints name the interpreter bindings they annotate" {
    var hinted = try compileInterpreter(.hinted, .{});
    defer hinted.deinit();
    const function = try interpreterFunction(hinted.program);
    const run = hinted.program.functions[@intCast(function)];
    const context = data.binding_time.Kind.context;
    const residual = data.binding_time.Kind.residual;
    try testing.expectEqual(@as(?data.binding_time.Kind, context), kindAt(
        hinted.hints,
        function,
        run.inputs[0],
    ));
    try testing.expect(kindAt(hinted.hints, function, run.inputs[1]) == null);
    try testing.expectEqual(@as(?data.binding_time.Kind, residual), kindAt(
        hinted.hints,
        function,
        run.inputs[2],
    ));
    var computed: usize = 0;
    for (hinted.hints) |item| {
        try testing.expectEqual(function, item.function);
        const schema = hinted.program.schemas[@intCast(run.layout.slots[@intCast(item.slot)])];
        try testing.expect(schema == .u64);
        if (std.mem.indexOfScalar(u64, run.inputs, item.slot) == null) {
            try testing.expectEqual(context, item.kind);
            computed += 1;
        }
    }
    try testing.expectEqual(1, computed);
}

test "conflicting stage hints on one binding join to residual" {
    var conflicting = try compileInterpreter(.conflicting, .{});
    defer conflicting.deinit();
    var plain = try compileInterpreter(.plain, .{});
    defer plain.deinit();
    try expectSameExecutable(plain, conflicting);
    try testing.expectEqual(3, conflicting.hints.len);
    for (conflicting.hints) |item|
        try testing.expectEqual(data.binding_time.Kind.residual, item.kind);
}

test "recovery compilation transports hints beside recovery bindings" {
    var plain = try compileInterpreter(.plain, .{ .recovery = true });
    defer plain.deinit();
    var hinted = try compileInterpreter(.hinted, .{ .recovery = true });
    defer hinted.deinit();
    try expectSameExecutable(plain, hinted);
    try testing.expectEqual(plain.recovery.len, hinted.recovery.len);
    try testing.expectEqual(3, hinted.hints.len);
}

test "hints are rejected where no correspondence can place them" {
    try testing.expectError(
        error.InvalidCorrespondence,
        compileInterpreter(.hinted, .{ .contract = .semantic }),
    );
    var built = try interpreter(testing.allocator, .hinted);
    defer built.deinit();
    try testing.expectError(error.InvalidSource, source.lowerObserved(
        testing.allocator,
        built.module,
        .{ .hints = try source.Hints.bind(
            built.module,
            &.{.{ .value = built.module.values.len, .kind = .context }},
        ) },
    ));
    try testing.expectError(
        error.InvalidSource,
        @import("source/activation_lower.zig").lowerComponentObserved(
            testing.allocator,
            built.module,
            &.{},
            &.{},
            .{ .hints = built.hints },
        ),
    );
}

fn expectHintErasure(build: anytype) !void {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const module = try build(&raw);
    const hints = try testing.allocator.alloc(source.Hint, module.values.len);
    defer testing.allocator.free(hints);
    for (hints, 0..) |*item, id| item.* = .{
        .value = id,
        .kind = if (id % 2 == 0) .context else .residual,
    };
    var plain = try source.lower(testing.allocator, module);
    defer plain.deinit();
    var hinted = try source.lowerObserved(testing.allocator, module, .{
        .hints = try source.Hints.bind(module, hints),
    });
    defer hinted.deinit();
    try expectSameExecutable(plain, hinted);
    try testing.expect(hinted.hints.len != 0);
    const bytes = try hinted.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    var decoded = try data.program_image.decode(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqualSlices(Hint, hinted.hints, decoded.hints);
}

test "hinting every value of every example leaves its executable records unchanged" {
    const examples = source.examples;
    inline for (.{
        examples.lexical,                examples.deep,               examples.recursive,
        examples.choicesAll,             examples.choicesFirst,       examples.generator,
        examples.stateLocal,             examples.stateShared,        examples.resourceScalar,
        examples.resourcePair,           examples.answers,            examples.scopedReader,
        examples.writerRaise,            examples.schedulerFifo,      examples.queensDfs,
        examples.queensBfs,              examples.cellOrder,          examples.nested,
        examples.shallow,                examples.injection,          examples.indexed,
        examples.abortCustody,           examples.unwind,             examples.reentrant,
        examples.cloned,                 examples.clauseAbort,        examples.boundedValues,
        examples.scalarContracts,        examples.ownership,          examples.shallowResumptions,
        examples.shallowInjection,       examples.handleOperandOrder, examples.protectOperandOrder,
        examples.successorState,         examples.clausePayload,      examples.yieldingCleanup,
        examples.borrowOperands,         examples.productProjection,  examples.statefulService,
        examples.swappedServiceReplies,  examples.pairedServices,     examples.logicalContext,
        examples.logicalBranching,       examples.logicalQuery,       examples.retainedScope,
        examples.consumerComposition,    examples.branchingTail,      examples.blobCapture,
        examples.branchingTailProtected,
    }) |build| try expectHintErasure(build);
}

fn expectBinding(compiled: *const source.Compiled, variable: u64, item: Hint) !void {
    for ([_][]const source.RecoveryBinding{ compiled.recovery, compiled.parameters }) |bindings| {
        for (bindings) |binding| if (binding.variable == variable and
            binding.function == item.function and binding.slot == item.slot) return;
    }
    return error.TestExpectedHintedBinding;
}

fn expectPlacedHint(module: source.Module, value: usize) !void {
    var compiled = try source.lowerObserved(testing.allocator, module, .{
        .recovery = true,
        .hints = try source.Hints.bind(module, &.{.{ .value = value, .kind = .context }}),
    });
    defer compiled.deinit();
    const map = compiled.recovery_evidence.?.correspondence.maps;
    const schemas = map[@backingInt(data.relocation.Kind.schema)];
    const expected = schemas[@intCast(module.values[value].schema)];
    for (compiled.hints) |item| {
        const function = compiled.program.functions[@intCast(item.function)];
        try testing.expectEqual(expected, function.layout.slots[@intCast(item.slot)]);
        switch (module.values[value].expression) {
            .variable => |variable| try expectBinding(&compiled, variable, item),
            else => {},
        }
    }
}

fn expectPlacedHints(build: anytype) !void {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const module = try build(&raw);
    for (0..module.values.len) |value| try expectPlacedHint(module, value);
}

test "each single-value hint lands on a binding of that value's variable and schema" {
    const examples = source.examples;
    inline for (.{
        examples.lexical,       examples.deep,           examples.recursive,
        examples.stateLocal,    examples.choicesAll,     examples.scopedReader,
        examples.indexed,       examples.successorState, examples.productProjection,
        examples.boundedValues,
    }) |build| try expectPlacedHints(build);
    inline for (.{ interpreter, wide }) |construct| {
        var built = try construct(testing.allocator, .plain);
        defer built.deinit();
        for (0..built.module.values.len) |value| try expectPlacedHint(built.module, value);
    }
}

test "hints follow bindings that slot ordering moves" {
    var plain = try compileBuilt(wide, .plain, .{});
    defer plain.deinit();
    var hinted = try compileBuilt(wide, .hinted, .{});
    defer hinted.deinit();
    try expectSameExecutable(plain, hinted);
    try testing.expectEqual(2, hinted.hints.len);
    const function = hinted.program.functions[@intCast(hinted.hints[0].function)];
    try testing.expect(function.layout.slots.len > 128);
    try testing.expectEqual(data.binding_time.Kind.context, hinted.hints[0].kind);
    try testing.expectEqual(data.binding_time.Kind.residual, hinted.hints[1].kind);
    for (hinted.hints) |item| try testing.expect(item.slot < 64);
}

test "a hinted construction encodes exactly its image length" {
    var hinted = try compileInterpreter(.hinted, .{});
    defer hinted.deinit();
    const bytes = try hinted.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(try data.program_image.encodedLength(hinted.image()), bytes.len);
    try testing.expect(bytes.len > try data.program_image.encodedLength(.unhinted(hinted.program)));
    var decoded = try data.program_image.decode(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqualSlices(Hint, hinted.hints, decoded.hints);
}

test "the image size limit bounds the emitted hinted image" {
    var hinted = try compileInterpreter(.hinted, .{});
    defer hinted.deinit();
    const length = try data.program_image.encodedLength(hinted.image());
    try testing.expectError(
        error.Capacity,
        compileInterpreter(.hinted, .{ .max_image_bytes = length - 1 }),
    );
    var bounded = try compileInterpreter(.hinted, .{ .max_image_bytes = length });
    defer bounded.deinit();
    try testing.expectEqualSlices(Hint, hinted.hints, bounded.hints);
}

test "hints recorded against one module reject every other module" {
    var built = try interpreter(testing.allocator, .hinted);
    defer built.deinit();
    var other = try wide(testing.allocator, .plain);
    defer other.deinit();
    try testing.expectError(error.InvalidSource, source.lowerObserved(
        testing.allocator,
        other.module,
        .{ .hints = built.hints },
    ));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copied = try source.own(source.Module, arena.allocator(), built.module);
    var compiled = try source.lowerObserved(testing.allocator, copied, .{ .hints = built.hints });
    defer compiled.deinit();
    try testing.expectEqual(3, compiled.hints.len);
}

fn publishComponent(staging: Staging) !void {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const entry = try c.function("entry", .{ .x = integer }, integer, .{});
    const body = try c.body(entry);
    const x = try hint(body, staging, .context, try body.parameter("x"));
    try c.define(entry, try body.ret(x));
    const interface: source.component.Interface = .{
        .exports = &.{.{ .name = "entry", .reference = .{
            .kind = .function,
            .id = try a.interop.functionId(c, entry),
        } }},
    };
    _ = try a.interop.componentModule(c, entry, integer, interface);
}

test "the authoring component route rejects recorded hints" {
    try publishComponent(.plain);
    try testing.expectError(error.InvalidSource, publishComponent(.hinted));
}

fn defineIncrement(c: *a.Context, function: anytype, staging: Staging, fault: anytype) !void {
    const body = try c.body(function);
    const x = try hint(body, staging, .context, try body.parameter("x"));
    try c.define(function, try body.ret(try body.checkedAdd(
        x,
        try body.constant(u64, 1),
        fault,
    )));
}

fn twins(allocator: std.mem.Allocator, staging: Staging) !Interpreter {
    var result: Interpreter = .{
        .raw = source.Builder.init(allocator),
        .context = undefined,
        .module = undefined,
        .hints = null,
    };
    errdefer result.raw.deinit();
    const c = try a.Context.init(&result.raw);
    const integer = try c.schema(u64);
    const fault = try c.literalFailure(u64, 1);
    const hinted = try c.function("hinted", .{ .x = integer }, integer, .{});
    try defineIncrement(c, hinted, .hinted, fault);
    const twin = try c.function("twin", .{ .x = integer }, integer, .{});
    try defineIncrement(c, twin, staging, fault);
    const entry = try c.function("entry", .{}, integer, .{});
    const start = try c.body(entry);
    try c.define(entry, try start.ret(try start.checkedAdd(
        try start.call(hinted, .{ .x = try start.constant(u64, 1) }),
        try start.call(twin, .{ .x = try start.constant(u64, 2) }),
        fault,
    )));
    result.context = c;
    result.module = try c.module(entry, integer);
    result.hints = c.hints();
    return result;
}

test "a binding merged from hinted and unhinted twins keeps only a shared hint" {
    inline for (.{
        .{ Staging.plain, data.binding_time.Kind.residual },
        .{ Staging.hinted, data.binding_time.Kind.context },
    }) |case| {
        var merged = try compileBuilt(twins, case[0], .{});
        defer merged.deinit();
        var unary: usize = 0;
        for (merged.program.functions) |function| unary += @intFromBool(function.inputs.len == 1);
        try testing.expectEqual(1, unary);
        try testing.expectEqual(1, merged.hints.len);
        try testing.expectEqual(case[1], merged.hints[0].kind);
    }
}

fn clauseParameter(module: source.Module, index: usize) !u64 {
    const clause = module.handlers[0].clauses[0].function;
    const variable = module.functions[@intCast(clause)].parameters[index];
    for (module.values, 0..) |value, id| switch (value.expression) {
        .variable => |name| if (name == variable) return id,
        else => {},
    };
    return error.TestExpectedClauseParameter;
}

fn tailClause(program: data.activation.Program) !data.activation.Clause {
    for (program.handlers) |handler| for (handler.clauses) |clause|
        if (clause.strategy == .tail) return clause;
    return error.TestExpectedTailClause;
}

test "a tail clause keeps the hints of every binding its copy retains" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const module = try source.examples.branchingTail(&raw);
    var compiled = try source.lowerObserved(testing.allocator, module, .{
        .hints = try source.Hints.bind(module, &.{
            .{ .value = try clauseParameter(module, 0), .kind = .context },
            .{ .value = try clauseParameter(module, 1), .kind = .residual },
        }),
    });
    defer compiled.deinit();
    const clause = try tailClause(compiled.program);
    const tail = compiled.program.functions[@intCast(clause.function)];
    try testing.expectEqualSlices(Hint, &.{.{
        .function = clause.function,
        .slot = tail.inputs[0],
        .kind = .context,
    }}, compiled.hints);
}

const JoinedResume = struct { module: source.Module, resumed: u64, five: u64, joined: u64 };

fn joinedResume(raw: *source.Builder) !JoinedResume {
    const original = try source.examples.branchingTail(raw);
    const clause = original.handlers[0].clauses[0].function;
    const integer = original.functions[@intCast(clause)].result;
    const joined = try raw.variable(integer);
    const answer = try raw.variable(integer);
    const five = try raw.constant(u64, 5);
    const chosen = try raw.term(.{ .conditional = .{
        .condition = try raw.reference(raw.parameter(clause, 0)),
        .when_true = try raw.pure(five),
        .when_false = try raw.pure(try raw.constant(u64, 9)),
    } });
    const argument = try raw.reference(joined);
    const resume_joined = try raw.term(.{ .resume_value = .{
        .resumption = try raw.reference(raw.parameter(clause, 1)),
        .argument = argument,
    } });
    const resumed = try raw.reference(answer);
    raw.functions.items[@intCast(clause)].body = try raw.bind(
        joined,
        chosen,
        try raw.bind(answer, resume_joined, try raw.pure(resumed)),
    );
    return .{
        .module = raw.module(original.entry, original.failure),
        .resumed = resumed,
        .five = five,
        .joined = argument,
    };
}

test "a tail clause hints only the bindings its copy materializes" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const built = try joinedResume(&raw);
    var compiled = try source.lowerObserved(testing.allocator, built.module, .{
        .hints = try source.Hints.bind(built.module, &.{
            .{ .value = built.resumed, .kind = .context },
            .{ .value = built.five, .kind = .context },
            .{ .value = built.joined, .kind = .residual },
        }),
    });
    defer compiled.deinit();
    const clause = try tailClause(compiled.program);
    const tail = compiled.program.functions[@intCast(clause.function)];
    const branch = compiled.program.blocks[@intCast(tail.entry)].terminator.branch;
    const chosen = compiled.program.blocks[@intCast(branch.when_true.block)];
    const constant = chosen.instructions[0].destination;
    const joined = chosen.terminator.jump.assignments[0].destination;
    var expected = [_]Hint{
        .{ .function = clause.function, .slot = constant, .kind = .context },
        .{ .function = clause.function, .slot = joined, .kind = .residual },
    };
    try testing.expectEqualSlices(Hint, data.binding_time.normalize(&expected), compiled.hints);
}

fn Returned(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload;
}

test "only an owner that states its hints can name an image" {
    try testing.expect(!@hasField(data.coalescing.Owned, "hints"));
    try testing.expect(!@hasDecl(data.coalescing.Owned, "image"));
    inline for (.{
        Returned(data.closed_compilation.run),
        Returned(source.lowerObserved),
        data.program_image.Decoded,
    }) |Owner| {
        try testing.expect(@hasDecl(Owner, "image"));
        try testing.expect(std.meta.fieldInfo(Owner, .hints).attrs.default_value_ptr == null);
    }
}
