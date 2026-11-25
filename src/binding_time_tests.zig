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
    hints: []const source.Hint,

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
        .hints = &.{},
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
        .hints = &.{},
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
    const bytes = try allocator.alloc(u8, try data.program_image.encodedLength(program));
    errdefer allocator.free(bytes);
    _ = try data.program_image.encode(allocator, program, bytes);
    return bytes;
}

fn compiledBytes(allocator: std.mem.Allocator, compiled: *const source.Compiled) ![]u8 {
    const bytes = try allocator.alloc(u8, try compiled.encodedLength());
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
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
    try testing.expectEqual(2, c.hints().len);
    try testing.expectEqual(data.binding_time.Kind.context, c.hints()[0].kind);
    try testing.expectEqual(data.binding_time.Kind.residual, c.hints()[1].kind);
    try testing.expectError(error.InvalidSource, raw.hint(raw.values.items.len, .context));
}

test "hinted and unhinted interpreters compile to identical executable records" {
    var plain = try compileInterpreter(.plain, .{});
    defer plain.deinit();
    var hinted = try compileInterpreter(.hinted, .{});
    defer hinted.deinit();
    try expectSameExecutable(plain, hinted);
    try testing.expectEqual(0, plain.hints.len);
    const plain_bytes = try compiledBytes(testing.allocator, &plain);
    defer testing.allocator.free(plain_bytes);
    const hinted_bytes = try compiledBytes(testing.allocator, &hinted);
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
        decoded.program,
    )));
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
        .{ .hints = &.{.{ .value = built.module.values.len, .kind = .context }} },
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
    var hinted = try source.lowerObserved(testing.allocator, module, .{ .hints = hints });
    defer hinted.deinit();
    try expectSameExecutable(plain, hinted);
    try testing.expect(hinted.hints.len != 0);
    const bytes = try compiledBytes(testing.allocator, &hinted);
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
        .hints = &.{.{ .value = value, .kind = .context }},
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
