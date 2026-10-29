// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;
const pe = source.specialize;
const context: pe.Context = .{
    .core = @splat(1),
    .guest = @splat(2),
    .observation = @splat(3),
    .base_profile = @splat(4),
    .admission_profile = @splat(5),
    .compiler_policy = @splat(6),
};

fn compositionSites(module: source.Module) ![2]source.consumer.Site {
    var result: [2]source.consumer.Site = undefined;
    var count: usize = 0;
    for (module.functions, 0..) |function, id| {
        const body = function.body orelse continue;
        if (module.terms[@intCast(body)] != .bind) continue;
        const binding = module.terms[@intCast(body)].bind;
        if (module.terms[@intCast(binding.value)] != .call or
            module.terms[@intCast(binding.next)] != .call) continue;
        try std.testing.expect(count < result.len);
        result[count] = .{ .function = id, .binding = body };
        count += 1;
    }
    try std.testing.expectEqual(result.len, count);
    return result;
}

fn targetCalls(program: @import("horos_data").activation.Program) usize {
    var count: usize = 0;
    for (program.blocks) |block| {
        if (block.terminator == .call) count += 1;
    }
    return count;
}

fn checkComposition(module: source.Module) !void {
    const a = std.testing.allocator;
    const sites = try compositionSites(module);
    var baseline = try source.lowerObserved(a, module, .{ .recovery = true });
    defer baseline.deinit();
    for (sites, 0..) |site, index| {
        var inspection = try source.consumer.inspect(a, module, site, .{});
        defer inspection.deinit();
        const boundary = inspection.outcome.boundary;
        try std.testing.expect(boundary.blocker == null);
        try std.testing.expectEqual(boundary.producer_result, boundary.consumer_input);
        try std.testing.expect(boundary.answer != boundary.producer_result);
        try std.testing.expectEqual(@as(u64, 1), boundary.other_producer_calls);
        try std.testing.expectEqual(@as(usize, 1), boundary.retained_variables.len);
        var candidate = try source.consumer.compose(a, module, site, .{});
        defer candidate.deinit();
        try std.testing.expectEqual(inspection.subject, candidate.predecessor);
        try source.relation.validate(a, module, candidate.module, candidate.steps, .{});
        var compiled = try source.lowerObserved(a, candidate.module, .{ .recovery = true });
        defer compiled.deinit();
        try source.recovery.validate(a, candidate.module, &compiled);
        try std.testing.expect(targetCalls(compiled.program) < targetCalls(baseline.program));
        const other = sites[1 - index].function;
        var preserved = try source.consumer.inspect(a, candidate.module, .{
            .function = other,
            .binding = candidate.module.functions[@intCast(other)].body.?,
        }, .{});
        defer preserved.deinit();
        try std.testing.expectEqual(boundary.producer, preserved.outcome.boundary.producer);
        try std.testing.expectEqualSlices(u64, module.functions[
            @intCast(boundary.producer)
        ].parameters, candidate.module.functions[@intCast(boundary.producer)].parameters);
    }
}

test "consumer composition derives two dynamic sites and survives alpha relocation" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const module = try source.examples.consumerComposition(&b);
    try checkComposition(module);
    const maps = try identitySourceMaps(b.allocator(), module);
    for (@constCast(maps.functions), 0..) |*id, index| id.* = maps.functions.len - index - 1;
    for (@constCast(maps.variables), 0..) |*id, index| id.* = maps.variables.len - index - 1;
    const renamed = try source.relation.Relocation.relocate(b.allocator(), module, maps);
    try source.relation.validate(std.testing.allocator, module, renamed, &.{.{
        .successor = renamed,
        .rule = .{ .relocation = maps },
    }}, .{});
    try checkComposition(renamed);
}

fn sharedComposition(b: *source.Builder) !source.Module {
    const word = try b.scalar(u64);
    const unit = try b.scalar(void);
    const increment = try b.declare(&.{word}, word, &.{}, &.{});
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const addition = try b.value(.{ .schema = word, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ try b.reference(b.parameter(increment, 0)), try b.constant(u64, 1) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
    } } });
    try b.define(increment, try b.pure(addition));
    const entry = try b.declare(&.{word}, word, &.{}, &.{});
    const variable = b.parameter(entry, 0);
    const call = try b.term(.{ .call = .{
        .function = increment,
        .arguments = &.{try b.reference(variable)},
    } });
    try b.define(entry, try b.bind(variable, call, call));
    return b.module(entry, unit);
}

test "consumer composition rewrites a shared call once with lexical shadowing" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try sharedComposition(&b);
    const site: source.consumer.Site = .{
        .function = module.entry,
        .binding = module.functions[@intCast(module.entry)].body.?,
    };
    var inspection = try source.consumer.inspect(a, module, site, .{});
    defer inspection.deinit();
    const boundary = inspection.outcome.boundary;
    try std.testing.expectEqual(boundary.producer_call, boundary.consumer_call);
    try std.testing.expect(boundary.blocker == null);
    var candidate = try source.consumer.compose(a, module, site, .{});
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 1), candidate.steps.len);
    try std.testing.expectEqual(boundary.producer_call, candidate.steps[0].rule.inline_call);
    try std.testing.expectEqual(try source.relation.identity(module), candidate.predecessor);
    try source.relation.validate(a, module, candidate.module, candidate.steps, .{});
    var compiled = try source.lowerObserved(a, candidate.module, .{ .recovery = true });
    defer compiled.deinit();
    try source.recovery.validate(a, candidate.module, &compiled);
}

test "consumer inspection counts callable references using admitted constructor identity" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const initial = try sharedComposition(&b);
    const entry = initial.entry;
    const failure = initial.failure;
    const binding = initial.functions[@intCast(entry)].body.?;
    const call = initial.terms[@intCast(binding)].bind.value;
    const producer = initial.terms[@intCast(call)].call.function;
    const word = initial.functions[@intCast(producer)].result;
    const other = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(other, try b.pure(try b.reference(b.parameter(other, 0))));
    const schema = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{word},
        .result = word,
    } } });
    for ([_]u64{ producer, other }) |function| {
        const getter = try b.declare(&.{}, schema, &.{}, &.{});
        try b.define(getter, try b.pure(try b.lambda(function, schema)));
    }
    var work: u64 = 1_000_000;
    const constructors = try source.constructor_bindings.admit(
        a,
        b.allocator(),
        b.module(entry, failure),
        &work,
    );
    for (constructors, 0..) |constructor, id| {
        if (constructor.function != producer and constructor.function != other) continue;
        const getter = try b.declare(&.{}, schema, &.{}, &.{});
        const raw = try b.primitive(schema, .computation, &.{}, id);
        try b.define(getter, try b.pure(raw));
    }
    const module = b.module(entry, failure);
    const site: source.consumer.Site = .{ .function = entry, .binding = binding };
    var inspection = try source.consumer.inspect(a, module, site, .{});
    defer inspection.deinit();
    try std.testing.expectEqual(@as(u64, 2), inspection.outcome.boundary.producer_value_references);
    var candidate = try source.consumer.compose(a, module, site, .{});
    defer candidate.deinit();
    try source.relation.validate(a, module, candidate.module, candidate.steps, .{});
}

const ConsumerWork = enum { inspect, validate };

fn consumerFitsWork(
    module: source.Module,
    site: source.consumer.Site,
    candidate: source.consumer.Candidate,
    operation: ConsumerWork,
    work: u64,
) !bool {
    const a = std.testing.allocator;
    switch (operation) {
        .inspect => {
            var inspection = source.consumer.inspect(
                a,
                module,
                site,
                .{ .work = work },
            ) catch |err| {
                if (err == error.RelationLimit) return false;
                return err;
            };
            inspection.deinit();
        },
        .validate => source.relation.validate(
            a,
            module,
            candidate.module,
            candidate.steps,
            .{ .work = work },
        ) catch |err| {
            if (err == error.RelationLimit) return false;
            return err;
        },
    }
    return true;
}

fn consumerMinimumWork(
    module: source.Module,
    site: source.consumer.Site,
    candidate: source.consumer.Candidate,
    operation: ConsumerWork,
) !u64 {
    var low: u64 = 0;
    var high: u64 = 1_000_000;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try consumerFitsWork(module, site, candidate, operation, middle))
            high = middle
        else
            low = middle + 1;
    }
    return low;
}

test "consumer composition shares inspection construction and validation work" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try source.examples.consumerComposition(&b);
    const site = (try compositionSites(module))[0];
    var candidate = try source.consumer.compose(a, module, site, .{});
    defer candidate.deinit();
    const inspection = try consumerMinimumWork(module, site, candidate, .inspect);
    const validation = try consumerMinimumWork(module, site, candidate, .validate);
    const insufficient = try std.math.add(u64, inspection, validation) - 1;
    try std.testing.expectError(error.RelationLimit, source.consumer.compose(
        a,
        module,
        site,
        .{ .work = insufficient },
    ));
}

test "consumer composition reports protected roots and rejects stale identities" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try source.examples.consumerComposition(&b);
    const site = (try compositionSites(module))[0];
    var inspected = try source.consumer.inspect(a, module, site, .{});
    defer inspected.deinit();
    const producer = inspected.outcome.boundary.producer;
    const policy: source.relation.Policy = .{ .protected_functions = &.{producer} };
    var protected = try source.consumer.inspect(a, module, site, policy);
    defer protected.deinit();
    try std.testing.expectEqual(
        .protected_function,
        protected.outcome.boundary.blocker.?.producer,
    );
    try std.testing.expectError(error.UnsupportedRelation, source.consumer.compose(
        a,
        module,
        site,
        policy,
    ));
    var protected_caller = try source.consumer.inspect(a, module, site, .{
        .protected_functions = &.{site.function},
    });
    defer protected_caller.deinit();
    try std.testing.expectEqual(
        .protected_enclosing_function,
        std.meta.activeTag(protected_caller.outcome.boundary.blocker.?),
    );
    var candidate = try source.consumer.compose(a, module, site, .{});
    defer candidate.deinit();
    const changed = try source.own(source.Module, b.allocator(), module);
    const call = inspected.outcome.boundary.producer_call;
    const arguments = try b.allocator().dupe(u64, changed.terms[@intCast(call)].call.arguments);
    std.mem.swap(u64, &arguments[0], &arguments[1]);
    @constCast(changed.terms)[@intCast(call)].call.arguments = arguments;
    try std.testing.expectError(error.InvalidRelation, source.relation.validate(
        a,
        changed,
        candidate.module,
        candidate.steps,
        .{},
    ));
    try std.testing.expectError(error.RelationLimit, source.consumer.compose(
        a,
        module,
        site,
        .{ .work = 0 },
    ));
}

fn rejectCompositionMutation(
    module: source.Module,
    candidate: source.consumer.Candidate,
    mutated: source.Module,
) !void {
    const steps = [_]source.relation.Step{
        candidate.steps[0],
        .{ .successor = mutated, .rule = candidate.steps[1].rule },
    };
    try std.testing.expectError(error.InvalidRelation, source.relation.validate(
        std.testing.allocator,
        module,
        mutated,
        &steps,
        .{},
    ));
}

test "consumer composition rejects changed values argument duplication and same typed capture" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const module = try source.examples.consumerComposition(&b);
    const sites = try compositionSites(module);
    var candidate = try source.consumer.compose(std.testing.allocator, module, sites[0], .{});
    defer candidate.deinit();
    for (0..3) |mutation| {
        const changed = try source.own(source.Module, b.allocator(), candidate.module);
        if (mutation == 0) {
            for (@constCast(changed.values)) |*value| {
                if (value.expression != .primitive or
                    value.expression.primitive.opcode != .less) continue;
                value.expression.primitive.opcode = .equal;
                break;
            }
        } else {
            const other = changed.functions[@intCast(sites[1].function)].body.?;
            const binding = changed.terms[@intCast(other)].bind;
            const call = &@constCast(changed.terms)[@intCast(binding.value)].call;
            const arguments = try b.allocator().dupe(u64, call.arguments);
            if (mutation == 1) {
                arguments[1] = arguments[0];
            } else {
                const variable = changed.functions[@intCast(sites[1].function)].parameters[2];
                const values = @constCast(changed.values);
                values[@intCast(arguments[0])].expression = .{ .variable = variable };
            }
            call.arguments = arguments;
        }
        var work: u64 = 1_000_000;
        try source.admitWithWork(std.testing.allocator, changed, &work);
        try rejectCompositionMutation(module, candidate, changed);
    }
}

test "consumer composition cannot inherit another equal signature consumer identity" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    var module = try source.examples.consumerComposition(&b);
    const site = (try compositionSites(module))[0];
    var inspection = try source.consumer.inspect(a, module, site, .{});
    defer inspection.deinit();
    const boundary = inspection.outcome.boundary;
    const original = module.functions[@intCast(boundary.consumer)];
    const parameters = try b.allocator().alloc(u64, original.parameters.len);
    for (original.parameters, parameters) |variable, *schema|
        schema.* = module.variables[@intCast(variable)];
    const replacement = try b.declare(parameters, original.result, &.{}, &.{});
    try b.define(replacement, try b.pure(try b.constant(bool, true)));
    module = b.module(module.entry, module.failure);
    var candidate = try source.consumer.compose(a, module, site, .{});
    defer candidate.deinit();
    const changed = try source.own(source.Module, b.allocator(), module);
    @constCast(changed.terms)[@intCast(boundary.consumer_call)].call.function = replacement;
    var work: u64 = 1_000_000;
    try source.admitWithWork(a, changed, &work);
    try std.testing.expectError(error.InvalidRelation, source.relation.validate(
        a,
        changed,
        candidate.module,
        candidate.steps,
        .{},
    ));
}

fn capturedCapabilitySubstitution(
    a: std.mem.Allocator,
    module: source.Module,
) !struct { term: u64, local: u64 } {
    const facts = try @import("check.zig").analyze(a, module);
    for (module.functions, facts.functions) |function, captures| {
        for (captures.items) |captured| {
            const schema = module.variables[@intCast(captured)];
            const shape = module.schemas[@intCast(schema)];
            if (shape != .internal or shape.internal != .capability) continue;
            for (function.parameters) |local| {
                if (module.variables[@intCast(local)] != schema) continue;
                var next = function.body orelse continue;
                for (0..module.terms.len) |_| {
                    const term = module.terms[@intCast(next)];
                    const operation_id = if (term == .bind) term.bind.value else next;
                    const operation = module.terms[@intCast(operation_id)];
                    if (operation == .perform) {
                        if (operation.perform.capability) |capability| {
                            const value = module.values[@intCast(capability)];
                            if (value.expression == .variable and
                                value.expression.variable == captured)
                                return .{ .term = operation_id, .local = local };
                        }
                    }
                    if (term != .bind) break;
                    next = term.bind.next;
                }
            }
        }
    }
    return error.MissingCapabilitySubstitution;
}

test "logical context relocation rejects same schema local capability substitution" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    var module = try source.examples.logicalContext(&b);
    const substitution = try capturedCapabilitySubstitution(b.allocator(), module);
    const local = try b.reference(substitution.local);
    module = b.module(module.entry, module.failure);
    const maps = try identitySourceMaps(b.allocator(), module);
    const original = try source.relation.Relocation.relocate(b.allocator(), module, maps);
    try source.relation.validate(a, module, original, &.{.{
        .successor = original,
        .rule = .{ .relocation = maps },
    }}, .{});
    const changed = try source.own(source.Module, b.allocator(), original);
    @constCast(changed.terms)[@intCast(substitution.term)].perform.capability = local;
    var work: u64 = 1_000_000;
    try source.admitWithWork(a, changed, &work);
    try std.testing.expectError(error.InvalidRelation, source.relation.validate(
        a,
        module,
        changed,
        &.{.{ .successor = changed, .rule = .{ .relocation = maps } }},
        .{},
    ));
}

test "consumer composition retains dynamic faults and explicit yields" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    var module = try source.examples.consumerComposition(&b);
    const sites = try compositionSites(module);
    var inspection = try source.consumer.inspect(a, module, sites[0], .{});
    defer inspection.deinit();
    const producer = inspection.outcome.boundary.producer;
    const failure = try b.failureLiteral(try b.constant(void, {}));
    for (b.values.items) |*value| {
        if (value.expression != .primitive or
            value.expression.primitive.opcode != .integer_bit_xor) continue;
        value.expression.primitive.opcode = .integer_div;
        value.expression.primitive.failures = &.{
            .{ .kind = .arithmetic_overflow, .value = failure },
            .{ .kind = .division_by_zero, .value = failure },
        };
    }
    const body = b.functions.items[@intCast(producer)].body.?;
    b.functions.items[@intCast(producer)].body = try b.term(.{ .yield_then = body });
    module = b.module(module.entry, module.failure);
    var candidate = try source.consumer.compose(a, module, sites[0], .{});
    defer candidate.deinit();
    for ([_]bool{ false, true }) |remove_yield| {
        const changed = try source.own(source.Module, b.allocator(), candidate.module);
        if (remove_yield) {
            for (@constCast(changed.terms)) |*term| {
                if (term.* != .yield_then) continue;
                term.* = changed.terms[@intCast(term.yield_then)];
                break;
            }
        } else {
            for (@constCast(changed.values)) |*value| {
                if (value.expression != .primitive or
                    value.expression.primitive.opcode != .integer_div) continue;
                value.* = changed.values[@intCast(value.expression.primitive.operands[0])];
                break;
            }
        }
        var work: u64 = 1_000_000;
        try source.admitWithWork(a, changed, &work);
        try rejectCompositionMutation(module, candidate, changed);
    }
}

test "consumer composition rejects candidate only recursion without executing it" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try source.examples.consumerComposition(&b);
    const sites = try compositionSites(module);
    var candidate = try source.consumer.compose(a, module, sites[0], .{});
    defer candidate.deinit();
    const changed = try source.own(source.Module, b.allocator(), candidate.module);
    const entry = changed.functions[@intCast(changed.entry)].body.?;
    const branch = changed.terms[@intCast(entry)].conditional;
    const call = changed.terms[@intCast(branch.when_true)].call;
    const function = &@constCast(changed.functions)[@intCast(call.function)];
    const arguments = try b.allocator().alloc(u64, function.parameters.len);
    for (function.parameters, arguments) |parameter, *argument| {
        for (changed.values, 0..) |value, id| {
            if (value.expression == .variable and value.expression.variable == parameter) {
                argument.* = id;
                break;
            }
        } else return error.TestUnexpectedResult;
    }
    @constCast(changed.terms)[@intCast(function.body.?)] = .{ .call = .{
        .function = call.function,
        .arguments = arguments,
    } };
    var work: u64 = 1_000_000;
    try source.admitWithWork(a, changed, &work);
    try rejectCompositionMutation(module, candidate, changed);
}

test "consumer composition never discards an unused pure recursive computation" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    var module = try source.examples.consumerComposition(&b);
    const site = (try compositionSites(module))[0];
    var inspection = try source.consumer.inspect(a, module, site, .{});
    defer inspection.deinit();
    const producer = inspection.outcome.boundary.producer;
    const word = module.variables[@intCast(module.functions[@intCast(producer)].parameters[0])];
    const recursive = try b.declare(&.{}, word, &.{}, &.{});
    const call = try b.term(.{ .call = .{ .function = recursive, .arguments = &.{} } });
    try b.define(recursive, call);
    const retained = b.functions.items[@intCast(producer)].body.?;
    b.functions.items[@intCast(producer)].body = try b.bind(try b.variable(word), call, retained);
    module = b.module(module.entry, module.failure);
    var candidate = try source.consumer.compose(a, module, site, .{});
    defer candidate.deinit();
    const changed = try source.own(source.Module, b.allocator(), candidate.module);
    const reached = try b.allocator().alloc(bool, changed.terms.len);
    @memset(reached, false);
    reached[@intCast(changed.functions[@intCast(site.function)].body.?)] = true;
    var cursor = changed.terms.len;
    var deleted = false;
    while (cursor > 0) {
        cursor -= 1;
        if (!reached[cursor] or changed.terms[cursor] != .bind) continue;
        const binding = changed.terms[cursor].bind;
        const value = changed.terms[@intCast(binding.value)];
        if (value == .call and value.call.function == recursive) {
            @constCast(changed.terms)[cursor] = changed.terms[@intCast(binding.next)];
            deleted = true;
            break;
        }
        reached[@intCast(binding.value)] = true;
        reached[@intCast(binding.next)] = true;
    }
    try std.testing.expect(deleted);
    var work: u64 = 1_000_000;
    try source.admitWithWork(a, changed, &work);
    try rejectCompositionMutation(module, candidate, changed);
}

test "consumer composition inspection and candidates own their source storage" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    const module = try source.examples.consumerComposition(&b);
    const site = (try compositionSites(module))[0];
    var inspection = try source.consumer.inspect(a, module, site, .{});
    defer inspection.deinit();
    var candidate = try source.consumer.compose(a, module, site, .{});
    defer candidate.deinit();
    b.deinit();
    try std.testing.expectEqual(@as(usize, 2), inspection.outcome.boundary.producer_arguments.len);
    try std.testing.expectEqual(@as(usize, 1), inspection.outcome.boundary.retained_variables.len);
    var work: u64 = 1_000_000;
    try source.admitWithWork(a, candidate.module, &work);
}

test "consumer composition releases partial construction after allocation failures" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try source.examples.consumerComposition(&b);
    const site = (try compositionSites(module))[0];
    var counter = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    var complete = try source.consumer.compose(counter.allocator(), module, site, .{});
    complete.deinit();
    const count = counter.alloc_index;
    for ([_]usize{ 0, 1, count / 4, count / 2, count - 1 }) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{
            .fail_index = index,
            .resize_fail_index = 0,
        });
        if (source.consumer.compose(
            failing.allocator(),
            module,
            site,
            .{},
        )) |value| {
            var unexpected = value;
            defer unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "consumer composition declines ambiguous or intervening consumer routes" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    var module = try source.examples.consumerComposition(&b);
    const site = (try compositionSites(module))[0];
    var inspection = try source.consumer.inspect(a, module, site, .{});
    defer inspection.deinit();
    const boundary = inspection.outcome.boundary;
    const duplicate = try b.declare(
        &.{ boundary.producer_result, boundary.producer_result },
        boundary.answer,
        &.{},
        &.{},
    );
    try b.define(duplicate, try b.pure(try b.constant(bool, true)));
    const value = boundary.consumer_arguments[@intCast(boundary.argument_position)];
    b.terms.items[@intCast(boundary.consumer_call)] = .{ .call = .{
        .function = duplicate,
        .arguments = &.{ value, value },
    } };
    module = b.module(module.entry, module.failure);
    var ambiguous = try source.consumer.inspect(a, module, site, .{});
    defer ambiguous.deinit();
    try std.testing.expectEqual(
        .multiple_consumer_arguments,
        std.meta.activeTag(ambiguous.outcome.blocked),
    );
    b.terms.items[@intCast(boundary.consumer_call)] = .{ .value = try b.constant(bool, true) };
    module = b.module(module.entry, module.failure);
    var indirect = try source.consumer.inspect(a, module, site, .{});
    defer indirect.deinit();
    try std.testing.expectEqual(.not_direct_consumer, std.meta.activeTag(indirect.outcome.blocked));
}
fn known(value: u64, storage: *[8]u8, schema: p.Id) pe.Knowledge {
    std.mem.writeInt(u64, storage, value, .little);
    return .{ .known = .{ .schema = schema, .bytes = storage } };
}

fn retainedKnowledge(a: std.mem.Allocator) !void {
    var bytes: [8]u8 = undefined;
    var output = blk: {
        var b = source.Builder.init(a);
        defer b.deinit();
        const word = try b.scalar(u64);
        const f = try b.declare(&.{word}, word, &.{}, &.{});
        try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
        break :blk try pe.specialize(a, b.module(f, try b.scalar(void)), .{
            .context = context,
            .function = f,
            .arguments = &.{known(17, &bytes, word)},
        });
    };
    defer output.deinit();
    @memset(&bytes, 0);
    const fact = output.functions.items[0].arguments[0].known;
    try std.testing.expect(fact.bytes.ptr != &bytes);
    try std.testing.expect(fact.bytes.ptr == output.request.arguments[0].known.bytes.ptr);
    try std.testing.expectEqual(@as(u64, 17), std.mem.readInt(u64, fact.bytes[0..8], .little));
    try pe.validate(a, output.original, output.request, &output);
}

test "specialization shares owned static facts after caller storage is released" {
    try @import("../allocation_testing.zig").check(
        std.testing.allocator,
        retainedKnowledge,
        .{},
    );
}

test "specialization checks raw callee facts before reusing verified arguments" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const word = try b.scalar(u64);
    const callee = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(callee, try b.pure(try b.reference(b.parameter(callee, 0))));
    const caller = try b.declare(&.{word}, word, &.{}, &.{});
    const call = try b.term(.{ .call = .{
        .function = callee,
        .arguments = &.{try b.reference(b.parameter(caller, 0))},
    } });
    try b.define(caller, try b.bind(try b.variable(word), call, call));
    var bytes: [8]u8 = undefined;
    var output = try pe.specialize(a, b.module(caller, try b.scalar(void)), .{
        .context = context,
        .function = caller,
        .arguments = &.{known(17, &bytes, word)},
    });
    defer output.deinit();
    for (output.functions.items) |*proof| proof.arguments = try pe.values.ownMany(
        output.builder.allocator(),
        proof.arguments,
    );
    try pe.validate(a, output.original, output.request, &output);
    try std.testing.expectEqual(@as(usize, 2), output.functions.items.len);
    output.functions.items[1].arguments = try pe.values.ownMany(
        output.builder.allocator(),
        &.{known(18, &bytes, word)},
    );
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, output.original, output.request, &output),
    );
}

test "specialization reconstructs verified argument sharing after proof copies" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const word = try b.scalar(u64);
    const sequence = try b.schema(.{ .seq = try b.scalar(u8) });
    const pair = try b.schema(.{ .product = &.{ sequence, word } });
    var functions: [8]source.Id = undefined;
    for (&functions) |*function| function.* = try b.declare(&.{pair}, word, &.{}, &.{});
    for (functions, 0..) |function, index| {
        const parameter = try b.reference(b.parameter(function, 0));
        const field = try b.primitive(word, .field, &.{parameter}, 1);
        const body = if (index + 1 == functions.len) try b.pure(field) else try b.bind(
            try b.variable(word),
            try b.pure(field),
            try b.term(.{ .call = .{
                .function = functions[index + 1],
                .arguments = &.{parameter},
            } }),
        );
        try b.define(function, body);
    }
    var bytes: [4106]u8 = @splat(7);
    var writer: @import("horos_data").wire.Writer = .{ .output = &bytes };
    try writer.natural(4096);
    std.mem.writeInt(u64, bytes[4098..][0..8], 17, .little);
    var output = try pe.specialize(a, b.module(functions[0], try b.scalar(void)), .{
        .context = context,
        .function = functions[0],
        .arguments = &.{.{ .known = .{ .schema = pair, .bytes = &bytes } }},
        .policy = .{ .work = 10_000 },
    });
    defer output.deinit();
    try std.testing.expectEqual(functions.len, output.functions.items.len);
    for (output.functions.items) |*proof| proof.arguments = try pe.values.ownMany(
        output.builder.allocator(),
        proof.arguments,
    );
    try pe.validate(a, output.original, output.request, &output);
    try std.testing.expect(try literalProofWork(&output) >= functions.len * bytes.len);
}

fn literalProof(a: std.mem.Allocator, bytes: []const u8, selected: bool) !pe.Output {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const sequence = try b.schema(.{ .seq = try b.scalar(u8) });
    var length: @import("horos_data").wire.Writer = .{};
    try @import("horos_data").record.write([]const u8, bytes, &length);
    const encoded_value = try b.allocator().alloc(u8, length.position);
    var writer: @import("horos_data").wire.Writer = .{ .output = encoded_value };
    try @import("horos_data").record.write([]const u8, bytes, &writer);
    const value = try b.literal(.{ .schema = sequence, .bytes = encoded_value });
    const f = try b.declare(&.{}, if (selected) unit else sequence, &.{}, &.{});
    var scrutinee = value;
    if (selected) {
        const sum = try b.schema(.{ .sum = &.{sequence} });
        const literal_id = b.values.items[@intCast(value)].expression.literal;
        const literal = b.constants.items[@intCast(literal_id)];
        const encoded = try std.mem.concat(b.allocator(), u8, &.{ &.{0}, literal.bytes });
        scrutinee = try b.literal(.{ .schema = sum, .bytes = encoded });
        try b.define(f, try b.term(.{ .match_sum = .{
            .value = scrutinee,
            .cases = &.{.{
                .variable = try b.variable(sequence),
                .body = try b.pure(try b.constant(void, {})),
            }},
        } }));
    } else try b.define(f, try b.pure(value));
    var output = try pe.specialize(a, b.module(f, unit), .{
        .context = context,
        .function = f,
        .arguments = &.{},
    });
    errdefer output.deinit();
    for (output.value_proofs.items) |*proof| if (proof.before == scrutinee) {
        proof.after = proof.before;
        proof.folded = !selected;
    };
    if (!selected) {
        const body = b.functions.items[@intCast(f)].body.?;
        output.builder.functions.items[@intCast(output.entry)].body = body;
        output.term_proofs.items[output.functions.items[0].body.?].after = body;
    }
    return output;
}

fn duplicateLiteralProof(output: *pe.Output, count: usize) !void {
    const proof = output.functions.items[0];
    const function = output.module().functions[@intCast(proof.after)];
    const value_count = output.value_proofs.items.len;
    const term_count = output.term_proofs.items.len;
    for (1..count) |_| {
        const after = try output.builder.declare(&.{}, function.result, &.{}, &.{});
        try output.builder.define(after, function.body.?);
        var copy = proof;
        copy.after = after;
        const storage = output.builder.allocator();
        const value_offset = output.value_proofs.items.len;
        const term_offset = output.term_proofs.items.len;
        for (0..value_count) |index| {
            var value = output.value_proofs.items[index];
            const children = try storage.dupe(usize, value.children);
            for (children) |*child| child.* += value_offset;
            value.children = children;
            try output.value_proofs.append(storage, value);
        }
        for (0..term_count) |index| {
            var term = output.term_proofs.items[index];
            const children = try storage.dupe(usize, term.children);
            for (children) |*child| child.* += term_offset;
            term.children = children;
            const values = try storage.dupe(usize, term.values);
            for (values) |*value| value.* += value_offset;
            term.values = values;
            try output.term_proofs.append(storage, term);
        }
        copy.body = proof.body.? + term_offset;
        try output.functions.append(storage, copy);
    }
}

fn literalProofWork(output: *const pe.Output) !u64 {
    var remaining: u64 = 1_000_000_000;
    try @import("specialize_validate.zig").validateWithWork(
        std.testing.allocator,
        output.original,
        output.request,
        output,
        &remaining,
    );
    return 1_000_000_000 - remaining;
}

fn rejectLiteralProofWork(output: *const pe.Output, budget: u64) !void {
    var remaining = budget;
    try std.testing.expectError(
        error.RelationLimit,
        @import("specialize_validate.zig").validateWithWork(
            std.testing.allocator,
            output.original,
            output.request,
            output,
            &remaining,
        ),
    );
}

test "distinct folded literal proofs charge every content comparison" {
    const bytes: [4096]u8 = @splat(7);
    var output = try literalProof(std.testing.allocator, &bytes, false);
    defer output.deinit();
    try duplicateLiteralProof(&output, 8);
    const folded = try literalProofWork(&output);
    for (output.value_proofs.items) |*proof| proof.folded = false;
    const unfolded = try literalProofWork(&output);
    try std.testing.expect(folded - unfolded >= 8 * bytes.len);
    for (output.value_proofs.items) |*proof| proof.folded = true;
    try rejectLiteralProofWork(&output, unfolded + 8 * bytes.len - 1);
}

test "distinct selected match proofs charge every payload comparison" {
    const bytes: [4096]u8 = @splat(7);
    var output = try literalProof(std.testing.allocator, &bytes, true);
    defer output.deinit();
    const single = try literalProofWork(&output);
    try duplicateLiteralProof(&output, 8);
    const shared = try literalProofWork(&output);
    try std.testing.expect(shared - single >= 7 * bytes.len);
    try rejectLiteralProofWork(&output, single + 7 * bytes.len - 1);
}

fn resourceAuthorityCaller(b: *source.Builder, resource: p.Resource) !source.Id {
    // Exercise the authorized effectful helpers through an ordinary
    // first-order caller, independently of the example's protection.
    const acquire = resource.introducers[0];
    const release = resource.eliminators[resource.eliminators.len - 1];
    const effects = try std.mem.concat(
        b.allocator(),
        p.Id,
        &.{
            b.functions.items[@intCast(acquire)].effects,
            b.functions.items[@intCast(release)].effects,
        },
    );
    const function = try b.declare(
        &.{},
        b.functions.items[@intCast(release)].result,
        effects,
        &.{},
    );
    const owned = try b.variable(b.functions.items[@intCast(acquire)].result);
    const acquired = try b.term(.{ .call = .{ .function = acquire, .arguments = &.{} } });
    const released = try b.term(.{ .call = .{
        .function = release,
        .arguments = &.{try b.reference(owned)},
    } });
    try b.define(function, try b.bind(owned, acquired, released));
    return function;
}

fn rejectAuthoritySpecialization(
    b: *source.Builder,
    module: source.Module,
    resource: p.Resource,
    result: *pe.Output,
) !void {
    for ([_][]const p.Id{
        resource.introducers,
        resource.eliminators,
    }) |authorities| for (authorities) |function| {
        for (result.functions.items) |proof| try std.testing.expect(proof.before != function);
        const inputs = try b.allocator().alloc(
            pe.Knowledge,
            module.functions[@intCast(function)].parameters.len,
        );
        @memset(inputs, .dynamic);
        try std.testing.expectError(
            error.UnsupportedSpecialization,
            pe.specialize(
                std.testing.allocator,
                module,
                .{ .context = context, .function = function, .arguments = inputs },
            ),
        );
    };
}

test "specialization retains nominal resource authority in generic callees" {
    const a = std.testing.allocator;
    inline for (.{ "abortCustody", "resourceScalar", "resourcePair" }) |name| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const original = try @field(source.examples, name)(&b);
        const resource = original.resources[0];
        const entry = if (comptime std.mem.eql(u8, name, "abortCustody"))
            original.entry
        else
            try resourceAuthorityCaller(&b, resource);
        const module = b.module(entry, original.failure);
        var admitted = try source.lower(a, module);
        defer admitted.deinit();
        const arguments = try b.allocator().alloc(
            pe.Knowledge,
            module.functions[@intCast(entry)].parameters.len,
        );
        @memset(arguments, .dynamic);
        const request: pe.Request = .{
            .context = context,
            .function = entry,
            .arguments = arguments,
        };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        try pe.validate(a, module, request, &result);
        var lowered = try source.lower(a, result.module());
        defer lowered.deinit();
        try std.testing.expect(@import("horos_data").record.equal(
            []const p.Resource,
            module.resources,
            result.module().resources,
        ));
        try std.testing.expect(@import("horos_data").record.equal(
            []const source.ast.Function,
            module.functions,
            result.module().functions[0..module.functions.len],
        ));
        try rejectAuthoritySpecialization(&b, module, resource, &result);
        // Ordinary admission permits an explicit extra permission. The
        // independent translation checker must reject granting it to a clone.
        const extra = try std.mem.concat(
            result.builder.allocator(),
            p.Id,
            &.{ resource.introducers, &.{result.entry} },
        );
        result.builder.resources.items[0].introducers = extra;
        var forged = try source.lower(a, result.module());
        defer forged.deinit();
        try std.testing.expectError(
            error.InvalidSpecialization,
            pe.validate(a, module, request, &result),
        );
    }
}

fn specializeExample(build: *const fn (*source.Builder) source.Error!source.Module) !bool {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try build(&b);
    var original = try source.lower(a, module);
    defer original.deinit();
    const arguments = try b.allocator().alloc(
        pe.Knowledge,
        module.functions[@intCast(module.entry)].parameters.len,
    );
    @memset(arguments, .dynamic);
    var result = pe.specialize(
        a,
        module,
        .{ .context = context, .function = module.entry, .arguments = arguments },
    ) catch |err| switch (err) {
        error.UnsupportedSpecialization, error.SpecializationLimit => return false,
        else => return err,
    };
    defer result.deinit();
    var residual = try source.lower(a, result.module());
    defer residual.deinit();
    return true;
}

test "specialization admits or precisely declines existing public examples" {
    var attempted: usize = 0;
    var specialized: usize = 0;
    inline for (comptime std.meta.declarations(source.examples)) |name| {
        const build = @field(source.examples, name);
        if (comptime @TypeOf(build) == fn (*source.Builder) source.Error!source.Module) {
            attempted += 1;
            specialized += @intFromBool(try specializeExample(build));
        }
    }
    try std.testing.expect(attempted > 0);
    try std.testing.expect(specialized > 0);
}

fn capturedCallModule(b: *source.Builder, kind: usize) !struct {
    module: source.Module,
    word: p.Id,
    entry: p.Id,
    outer: p.Id,
    callee: p.Id,
} {
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const entry = try b.declare(&.{word}, word, &.{}, &.{});
    const outer = try b.declare(&.{word}, word, &.{}, &.{});
    const captured = if (kind == 1) try b.variable(word) else b.parameter(outer, 0);
    const inner = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(inner, try b.pure(try b.reference(captured)));
    const callee = if (kind == 2) blk: {
        const indirect = try b.declare(&.{}, word, &.{}, &.{});
        try b.define(
            indirect,
            try b.term(.{ .call = .{ .function = inner, .arguments = &.{} } }),
        );
        break :blk indirect;
    } else inner;
    const call = try b.term(.{ .call = .{ .function = callee, .arguments = &.{} } });
    try b.define(outer, if (kind == 1 or kind == 3)
        try b.bind(captured, try b.pure(try b.constant(u64, 42)), call)
    else
        call);
    try b.define(
        entry,
        try b.term(.{ .call = .{
            .function = outer,
            .arguments = &.{try b.reference(b.parameter(entry, 0))},
        } }),
    );
    const module = b.module(entry, unit);
    return .{ .module = module, .word = word, .entry = entry, .outer = outer, .callee = callee };
}

test "specialization keeps captured calls inside their closed generic function" {
    const a = std.testing.allocator;
    for (0..4) |kind| for ([_]bool{ false, true }) |static_input| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const fixture = try capturedCallModule(&b, kind);
        const module = fixture.module;
        const word = fixture.word;
        const entry = fixture.entry;
        const outer = fixture.outer;
        const callee = fixture.callee;
        var admitted = try source.lower(a, module);
        defer admitted.deinit();
        var bytes: [8]u8 = undefined;
        const arguments = [_]pe.Knowledge{if (static_input) known(41, &bytes, word) else .dynamic};

        // This root needs its original lexical scope. Decline it before
        // constructing a residual with fresh binders and dangling captures.
        try std.testing.expectError(
            error.UnsupportedSpecialization,
            pe.specialize(
                a,
                module,
                .{ .context = context, .function = outer, .arguments = &arguments },
            ),
        );

        // Its closed caller can still specialize: the complete original
        // callee retains its parameter/local/shadowed/transitive captures.
        const request: pe.Request = .{
            .context = context,
            .function = entry,
            .arguments = &arguments,
        };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.functions.items.len);
        const residual = result.module();
        try std.testing.expect(@import("horos_data").record.equal(
            []const source.ast.Function,
            module.functions,
            residual.functions[0..module.functions.len],
        ));
        const function = residual.functions[@intCast(result.entry)];
        try std.testing.expectEqual(
            @as(usize, if (static_input) 0 else 1),
            function.parameters.len,
        );
        const retained_call = residual.terms[@intCast(function.body.?)].call;
        try std.testing.expectEqual(outer, retained_call.function);
        try std.testing.expectEqual(@as(usize, 1), retained_call.arguments.len);
        try pe.validate(a, module, request, &result);
        var lowered = try source.lower(a, residual);
        defer lowered.deinit();

        // The independent scope checker must still reject the old broken
        // boundary: calling the captured function from the renamed caller.
        result.builder.terms.items[@intCast(function.body.?)] = .{ .call = .{
            .function = callee,
            .arguments = &.{},
        } };
        try std.testing.expectError(
            error.UnboundVariable,
            pe.validate(a, module, request, &result),
        );
    };
}

test "specialization renaming preserves lexical shadowing and rejects capture" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |shadows_source| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const word = try b.scalar(u64);
        const f = try b.declare(&.{word}, word, &.{}, &.{});
        const x = b.parameter(f, 0);
        const y = if (shadows_source) x else try b.variable(word);
        try b.define(
            f,
            try b.bind(y, try b.pure(try b.constant(u64, 42)), try b.pure(try b.reference(x))),
        );
        const module = b.module(f, unit);
        const request: pe.Request = .{
            .context = context,
            .function = f,
            .arguments = &.{.dynamic},
        };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        const residual = result.module().functions[@intCast(result.entry)];
        result.builder.terms.items[
            @intCast(residual.body.?)
        ].bind.variable = residual.parameters[0];
        // Both candidates are legal source. Only the first changes which
        // source binding the final reference denotes.
        var admitted = try source.lower(a, result.module());
        defer admitted.deinit();
        if (shadows_source) {
            try pe.validate(a, module, request, &result);
        } else try std.testing.expectError(
            error.InvalidSpecialization,
            pe.validate(a, module, request, &result),
        );
    }
}

test "specialization rejects capture through unpack and both sum branch forms" {
    const a = std.testing.allocator;
    for (0..3) |kind| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const word = try b.scalar(u64);
        const shape = try b.schema(if (kind == 0) .{ .product = &.{word} } else .{ .sum = &.{
            word,
            word,
        } });
        const f = try b.declare(&.{ word, shape }, word, &.{}, &.{});
        const x = b.parameter(f, 0);
        const input = try b.reference(b.parameter(f, 1));
        const y = try b.variable(word);
        const finish = try b.pure(try b.reference(x));
        try b.define(f, try b.term(if (kind == 0)
            .{ .unpack_product = .{ .value = input, .variables = &.{y}, .body = finish } }
        else
            .{ .match_sum = .{
                .value = input,
                .cases = &.{
                    .{ .variable = y, .body = finish },
                    .{ .variable = try b.variable(word), .body = finish },
                },
            } }));
        const module = b.module(f, unit);
        const arguments = [_]pe.Knowledge{
            .dynamic,
            if (kind == 2) .{ .known = .{
                .schema = shape,
                .bytes = &.{ 0, 42, 0, 0, 0, 0, 0, 0, 0 },
            } } else .dynamic,
        };
        const request: pe.Request = .{ .context = context, .function = f, .arguments = &arguments };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        const residual = result.module().functions[@intCast(result.entry)];
        const term = &result.builder.terms.items[@intCast(residual.body.?)];
        switch (kind) {
            0 => @constCast(term.unpack_product.variables)[0] = residual.parameters[0],
            1 => @constCast(term.match_sum.cases)[0].variable = residual.parameters[0],
            else => term.bind.variable = residual.parameters[0],
        }
        var admitted = try source.lower(a, result.module());
        defer admitted.deinit();
        try std.testing.expectError(
            error.InvalidSpecialization,
            pe.validate(a, module, request, &result),
        );
    }
}

test "specialization preserves ordered dynamic parameter identity" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{ word, word }, word, &.{}, &.{});
    try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
    const module = b.module(f, unit);
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{ .dynamic, .dynamic },
    };
    var result = try pe.specialize(a, module, request);
    defer result.deinit();
    const parameters = @constCast(
        result.builder.functions.items[
            @intCast(result.entry)
        ].parameters,
    );
    std.mem.swap(p.Id, &parameters[0], &parameters[1]);
    var admitted = try source.lower(a, result.module());
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, module, request, &result),
    );
    std.mem.swap(p.Id, &parameters[0], &parameters[1]);
    parameters[1] = parameters[0];
    // Duplicate formals are already rejected by ordinary source admission.
    try std.testing.expectError(error.InvalidSource, pe.validate(a, module, request, &result));
}

test "non-exportable aggregate constructors remain residual" {
    const a = std.testing.allocator;
    for (0..3) |kind| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const word = try b.scalar(u64);
        const closure = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = unit,
        } } });
        const aggregate = try b.schema(switch (kind) {
            0 => .{ .sum = &.{ unit, closure } },
            1 => .{ .seq = closure },
            else => .{ .array = .{ .element = closure, .length = 0 } },
        });
        const f = try b.declare(&.{}, word, &.{}, &.{});
        const value = if (kind == 0)
            try b.primitive(aggregate, .variant, &.{try b.constant(void, {})}, 0)
        else
            try b.primitive(aggregate, .sequence, &.{}, 0);
        try b.define(
            f,
            try b.pure(try b.primitive(
                word,
                if (kind == 0) .variant_tag else .sequence_length,
                &.{value},
                0,
            )),
        );
        const module = b.module(f, unit);
        var original = try source.lower(a, module);
        defer original.deinit();
        const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{} };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        var seen = false;
        for (result.value_proofs.items) |proof| if (proof.before == value) {
            seen = true;
            try std.testing.expect(!proof.folded);
            try std.testing.expectEqual(
                .primitive,
                std.meta.activeTag(result.module().values[@intCast(proof.after)].expression),
            );
        };
        try std.testing.expect(seen);
        var residual = try source.lower(a, result.module());
        defer residual.deinit();
    }
}

test "source specialization reserves recursive keys and retains dynamic arithmetic" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const u64_type = try b.scalar(u64);
    const bool_type = try b.scalar(bool);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const f = try b.declare(&.{ u64_type, u64_type }, u64_type, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const factor = try b.reference(b.parameter(f, 1));
    const zero = try b.constant(u64, 0);
    const one = try b.constant(u64, 1);
    const stop = try b.primitive(bool_type, .equal, &.{ x, zero }, 0);
    const reduced = try b.value(.{
        .schema = u64_type,
        .expression = .{ .primitive = .{
            .opcode = .integer_sub,
            .operands = &.{ x, one },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } },
    });
    const recurse = try b.term(.{ .call = .{ .function = f, .arguments = &.{ reduced, factor } } });
    const finish = try b.pure(factor);
    try b.define(
        f,
        try b.term(.{ .conditional = .{
            .condition = stop,
            .when_true = finish,
            .when_false = recurse,
        } }),
    );
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{ .dynamic, known(7, &bytes, u64_type) },
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.functions.items.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        result.module().functions[@intCast(result.entry)].parameters.len,
    );
    var compiled = try source.lower(a, result.module());
    defer compiled.deinit();
    const proof = &result.value_proofs.items[result.value_proofs.items.len - 1];
    const saved = proof.before;
    proof.before = 0;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
    proof.before = saved;
    var changed = request;
    changed.context.guest[0] ^= 1;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), changed, &result),
    );
}
test "source specialization selects known condition and checks forged literal" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{boolean}, word, &.{}, &.{});
    const condition = try b.reference(b.parameter(f, 0));
    const yes = try b.pure(try b.constant(u64, 11));
    const no = try b.pure(try b.constant(u64, 19));
    try b.define(
        f,
        try b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = yes,
            .when_false = no,
        } }),
    );
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{.{ .known = .{ .schema = boolean, .bytes = &.{1} } }},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = &result.term_proofs.items[result.term_proofs.items.len - 1];
    try std.testing.expectEqual(@as(?usize, 0), last.selected);
    last.selected = 1;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
    last.selected = 0;
    var small = request;
    small.policy.work = 0;
    try std.testing.expectError(
        error.SpecializationLimit,
        pe.specialize(a, b.module(f, unit), small),
    );
}

test "partly known record folds bound fields without dropping a failing sibling" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const input = try b.reference(b.parameter(f, 0));
    const one = try b.constant(u64, 1);
    const seven = try b.constant(u64, 7);
    const divide = try b.value(.{
        .schema = word,
        .expression = .{ .primitive = .{
            .opcode = .integer_div,
            .operands = &.{ one, input },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = failure },
                .{ .kind = .division_by_zero, .value = failure },
            },
        } },
    });
    const product = try b.primitive(pair, .product, &.{ divide, seven }, 0);
    const projection = try b.primitive(word, .field, &.{product}, 1);
    try b.define(f, try b.pure(projection));
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{.dynamic} };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = result.value_proofs.items[result.value_proofs.items.len - 1];
    try std.testing.expect(!last.folded);
    try std.testing.expectEqual(
        .field,
        result.module().values[@intCast(last.after)].expression.primitive.opcode,
    );
    // A bound record has already evaluated every sibling; its static field is
    // then safe to substitute while the original binding remains in the code.
    const bound = try b.variable(pair);
    const read = try b.reference(bound);
    const field = try b.primitive(word, .field, &.{read}, 1);
    const body = try b.bind(bound, try b.pure(product), try b.pure(field));
    b.functions.items[@intCast(f)].body = body;
    var bound_result = try pe.specialize(a, b.module(f, unit), request);
    defer bound_result.deinit();
    const folded = bound_result.value_proofs.items[bound_result.value_proofs.items.len - 1];
    try std.testing.expect(folded.folded);
    try std.testing.expectEqual(
        .bind,
        std.meta.activeTag(
            bound_result.module().terms[
                @intCast(bound_result.module().functions[
                    @intCast(bound_result.entry)
                ].body.?)
            ],
        ),
    );
}

test "specialization retains effects and rejects an effect substitution" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "specialize/test",
        .payload = word,
        .result = word,
        .external = true,
        .control_use = .linear,
    });
    const f = try b.declare(&.{word}, word, &.{effect}, &.{});
    const argument = try b.reference(b.parameter(f, 0));
    try b.define(f, try b.term(.{ .perform = .{ .effect = effect, .payload = argument } }));
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{known(41, &bytes, word)},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const term = result.module().terms[
        @intCast(result.module().functions[
            @intCast(result.entry)
        ].body.?)
    ];
    try std.testing.expectEqual(effect, term.perform.effect);
    // The checker rejects an effect substitution even if a caller recomputes
    // the content digest; the local derivation binds the actual source effect.
    const at = result.module().functions[@intCast(result.entry)].body.?;
    result.builder.terms.items[@intCast(at)] = .{ .value = term.perform.payload };
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
}

test "static tag selection and normalized structured keys have checked payloads" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const sum = try b.schema(.{ .sum = &.{ unit, word } });
    const f = try b.declare(&.{sum}, word, &.{}, &.{});
    const tag = try b.reference(b.parameter(f, 0));
    const none = try b.variable(unit);
    const some = try b.variable(word);
    const empty = try b.pure(try b.constant(u64, 0));
    const full = try b.pure(try b.reference(some));
    try b.define(
        f,
        try b.term(.{ .match_sum = .{
            .value = tag,
            .cases = &.{
                .{ .variable = none, .body = empty },
                .{ .variable = some, .body = full },
            },
        } }),
    );
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{.{ .known = .{
            .schema = sum,
            .bytes = &.{ 1, 7, 0, 0, 0, 0, 0, 0, 0 },
        } }},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = &result.term_proofs.items[result.term_proofs.items.len - 1];
    try std.testing.expectEqual(@as(?usize, 1), last.selected);
    last.selected = 0;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var work: u64 = 100;
    var bytes: [8]u8 = undefined;
    const structured: pe.Knowledge = .{ .product = .{
        .schema = 4,
        .fields = &.{known(17, &bytes, word)},
    } };
    const normal = try pe.values.normalize(arena.allocator(), structured, &work);
    try std.testing.expectEqualSlices(u8, &bytes, normal.known.bytes);
}

test "static recursion generalizes at the compiler key allowance" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const zero = try b.constant(u64, 0);
    const one = try b.constant(u64, 1);
    const condition = try b.primitive(boolean, .equal, &.{ x, zero }, 0);
    const reduced = try b.value(.{
        .schema = word,
        .expression = .{ .primitive = .{
            .opcode = .integer_sub,
            .operands = &.{ x, one },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } },
    });
    const recurse = try b.term(.{ .call = .{ .function = f, .arguments = &.{reduced} } });
    const end = try b.pure(zero);
    try b.define(
        f,
        try b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = end,
            .when_false = recurse,
        } }),
    );
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{known(20, &bytes, word)},
        .policy = .{ .keys_per_function = 2 },
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.functions.items.len);
    var generic_calls: usize = 0;
    for (result.term_proofs.items) |proof| {
        const t = result.module().terms[@intCast(proof.after)];
        if (t == .call and t.call.function == f) generic_calls += 1;
    }
    try std.testing.expect(generic_calls > 0);
}

test "constant lookup of huge zero-width sequence does not enumerate its length" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const sequence = try b.schema(.{ .seq = unit });
    const option = try b.schema(.{ .sum = &.{ unit, unit } });
    const f = try b.declare(&.{sequence}, option, &.{}, &.{});
    const items = try b.reference(b.parameter(f, 0));
    const index = try b.constant(u64, 999999999);
    try b.define(f, try b.pure(try b.primitive(option, .sequence_get, &.{ items, index }, 0)));
    var encoded: [10]u8 = undefined;
    var writer: @import("horos_data").wire.Writer = .{ .output = &encoded };
    try writer.natural(1000000000);
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{.{ .known = .{
            .schema = sequence,
            .bytes = encoded[0..writer.position],
        } }},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const value = result.module().values[
        @intCast(result.value_proofs.items[result.value_proofs.items.len - 1].after)
    ];
    try std.testing.expectEqualSlices(
        u8,
        &.{1},
        result.module().constants[@intCast(value.expression.literal)].bytes,
    );
    _ = word;
}

test "finite source relation checks scalar composition and rejects unexplained changes" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const moved = try b.primitive(word, .move, &.{x}, 0);
    try b.define(f, try b.pure(moved));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(moved)] = before.values[@intCast(x)];
    const steps = [_]relation.Step{.{
        .successor = after,
        .rule = .{ .scalar = .{ .value = moved, .rule = .identity } },
    }};
    try relation.validate(a, before, after, &steps, .{});
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &.{}, .{}),
    );
    @constCast(after.values)[@intCast(moved)].expression = .{ .primitive = .{
        .opcode = .integer_bit_not,
        .operands = &.{x},
    } };
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &steps, .{}),
    );
}

test "private product relation transports literals constructors projections and unpack bindings" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const product = try b.schema(.{ .product = &.{ word, boolean } });
    const f = try b.declare(&.{ word, boolean }, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const y = try b.reference(b.parameter(f, 1));
    const pair = try b.primitive(product, .product, &.{ x, y }, 0);
    const projected = try b.primitive(word, .field, &.{pair}, 0);
    _ = try b.literal(.{ .schema = product, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0, 1 } });
    const first = try b.variable(word);
    const second = try b.variable(boolean);
    const body = try b.pure(projected);
    try b.define(f, try b.term(.{ .unpack_product = .{
        .value = pair,
        .variables = &.{ first, second },
        .body = body,
    } }));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.schemas)[@intCast(product)].product = &.{ boolean, word };
    @constCast(after.values)[@intCast(pair)].expression.primitive.operands = &.{ y, x };
    @constCast(after.values)[@intCast(projected)].expression.primitive.immediate = 1;
    @constCast(after.constants)[0].bytes = &.{ 1, 7, 0, 0, 0, 0, 0, 0, 0 };
    @constCast(after.terms)[after.terms.len - 1].unpack_product.variables = &.{ second, first };
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = product,
        .coordinates = &.{ 1, 0 },
    }} } }};
    const policy: relation.Policy = .{ .private_schemas = &.{product} };
    try relation.validate(a, before, after, &steps, policy);
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{
            .private_schemas = &.{product},
            .fixed_schemas = &.{product},
        },
    ));
    @constCast(after.values)[@intCast(projected)].expression.primitive.immediate = 0;
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &steps, policy),
    );
}

test "closed pure inlining evaluates arguments once and protects source recovery roots" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const helper = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(helper, try b.pure(try b.reference(b.parameter(helper, 0))));
    const entry = try b.declare(&.{word}, word, &.{}, &.{});
    const argument = try b.reference(b.parameter(entry, 0));
    const call = try b.term(.{ .call = .{
        .function = helper,
        .arguments = &.{argument},
    } });
    try b.define(entry, call);
    const before = b.module(entry, unit);
    const fresh = try b.variable(word);
    const value = try b.reference(fresh);
    const after = try source.own(source.ast.Module, b.allocator(), b.module(entry, unit));
    const terms = [_]source.ast.Term{
        before.terms[0],
        .{ .value = value },
        .{ .value = argument },
        .{ .bind = .{ .variable = fresh, .value = 2, .next = 1 } },
    };
    var candidate = after;
    candidate.terms = &terms;
    @constCast(candidate.functions)[@intCast(entry)].body = 3;
    const steps = [_]relation.Step{.{ .successor = candidate, .rule = .{ .inline_call = call } }};
    try relation.validate(a, before, candidate, &steps, .{});
    try std.testing.expectError(error.UnsupportedRelation, relation.validate(
        a,
        before,
        candidate,
        &steps,
        .{ .protected_functions = &.{helper} },
    ));
    try std.testing.expectError(error.RelationLimit, relation.validate(
        a,
        before,
        candidate,
        &steps,
        .{ .work = 0 },
    ));
}

test "source relation specialization binds owner selected immutable static inputs" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
    const before = b.module(f, unit);
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{known(5, &bytes, word)},
    };
    var output = try pe.specialize(a, before, request);
    defer output.deinit();
    const after = output.module();
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .specialization = .{
        .request = request,
        .entry = output.entry,
        .functions = output.functions.items,
        .values = output.value_proofs.items,
        .terms = output.term_proofs.items,
    } } }};
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{},
    ));
    const policy: relation.Policy = .{
        .static_scopes = &.{.{
            .predecessor = try relation.identity(before),
            .request = request,
        }},
        .protected_functions = &.{ f, f, std.math.maxInt(u64) },
    };
    try relation.validate(a, before, after, &steps, policy);
    const decoded = try roundTripRelationStep(b.allocator(), steps[0]);
    try relation.validate(a, before, after, &.{decoded}, policy);
    var unproved = after;
    unproved.terms = try std.mem.concat(
        b.allocator(),
        source.ast.Term,
        &.{ after.terms, &.{after.terms[0]} },
    );
    var changed_steps = steps;
    changed_steps[0].successor = unproved;
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        unproved,
        &changed_steps,
        policy,
    ));
}

test "private layout transports recursive literal graphs without changing scalar identities" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const node = try b.reserveSchema();
    const pair = try b.schema(.{ .product = &.{ word, node } });
    try b.defineSchema(node, .{ .sum = &.{ unit, pair } });
    const original_bytes = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0 };
    const transported_bytes = [_]u8{ 1, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 };
    const value = try b.literal(.{ .schema = node, .bytes = &original_bytes });
    const entry = try b.declare(&.{}, node, &.{}, &.{});
    try b.define(entry, try b.pure(value));
    const before = b.module(entry, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.schemas)[@intCast(pair)].product = &.{ node, word };
    @constCast(after.constants)[0].bytes = &transported_bytes;
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = pair,
        .coordinates = &.{ 1, 0 },
    }} } }};
    const policy: relation.Policy = .{ .private_schemas = &.{pair} };
    try relation.validate(a, before, after, &steps, policy);
    @constCast(after.constants)[0].bytes = &original_bytes;
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        policy,
    ));
}

test "source relocation preserves fixed schema endpoints and exact function correspondence" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
    const other = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(other, try b.pure(try b.reference(b.parameter(other, 0))));
    const before = b.module(f, unit);
    const maps: relation.Relocation.Maps = .{
        .schemas = &.{ 1, 0 },
        .variables = &.{ 1, 0 },
        .values = &.{ 1, 0 },
        .terms = &.{ 1, 0 },
        .functions = &.{ 1, 0 },
    };
    const after = try relation.Relocation.relocate(b.allocator(), before, maps);
    try std.testing.expectEqual(@as(u64, 1), after.entry);
    try std.testing.expectEqual(@as(u64, 0), after.functions[1].result);
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .relocation = maps } }};
    try relation.validate(a, before, after, &steps, .{});
    var nominal = before;
    nominal.region_count = 2;
    var collapsed = maps;
    collapsed.region_count = 2;
    collapsed.regions = &.{.{ .old = 1, .new = 0 }};
    try std.testing.expectError(
        error.InvalidRelation,
        relation.Relocation.validateMaps(a, nominal, collapsed, false),
    );
    const roots = try relation.transportFunctions(a, &.{f}, &steps);
    defer a.free(roots);
    try std.testing.expectEqualSlices(u64, &.{1}, roots);
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{ .fixed_schemas = &.{word} },
    ));
}

test "specialization local allowance excludes admission while relation allowance includes it" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const f = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(f, try b.pure(try b.constant(void, {})));
    const before = b.module(f, unit);
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{},
        .policy = .{ .work = 32 },
    };
    var output = try pe.specialize(a, before, request);
    defer output.deinit();
    try pe.validate(a, before, request, &output);
    const after = output.module();
    const step: relation.Step = .{ .successor = after, .rule = .{ .specialization = .{
        .request = request,
        .entry = output.entry,
        .functions = output.functions.items,
        .values = output.value_proofs.items,
        .terms = output.term_proofs.items,
    } } };
    var policy: relation.Policy = .{ .static_scopes = &.{.{
        .predecessor = try relation.identity(before),
        .request = request,
    }} };
    try relation.validate(a, before, after, &.{step}, policy);
    policy.work = request.policy.work;
    try std.testing.expectError(
        error.RelationLimit,
        relation.validate(a, before, after, &.{step}, policy),
    );
}

test "specialization literal validation retains independent semantic allowances" {
    const checker = @import("specialize_validate.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const sequence = try b.schema(.{ .seq = try b.scalar(u8) });
    const f = try b.declare(&.{sequence}, sequence, &.{}, &.{});
    try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
    var bytes: [4098]u8 = @splat(7);
    var writer: @import("horos_data").wire.Writer = .{ .output = &bytes };
    try writer.natural(4096);
    const before = b.module(f, unit);
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{.{ .known = .{ .schema = sequence, .bytes = &bytes } }},
        .policy = .{ .work = 32 },
    };
    var output = try pe.specialize(a, before, request);
    defer output.deinit();
    output.request.policy.work = 2;
    output.key = try pe.identity(a, before, output.request);
    try pe.validate(a, before, output.request, &output);
    var remaining: u64 = 64;
    try std.testing.expectError(
        error.RelationLimit,
        checker.validateWithWork(a, before, output.request, &output, &remaining),
    );
    remaining = 1_000_000;
    try checker.validateWithWork(a, before, output.request, &output, &remaining);
    try std.testing.expect(1_000_000 - remaining > bytes.len);
    output.request.policy.work = 1;
    output.key = try pe.identity(a, before, output.request);
    try std.testing.expectError(
        error.SpecializationLimit,
        pe.validate(a, before, output.request, &output),
    );
    output.request.policy.work = 2;
    output.request.policy.depth = 0;
    output.key = try pe.identity(a, before, output.request);
    try std.testing.expectError(
        error.SpecializationLimit,
        pe.validate(a, before, output.request, &output),
    );
}

test "specialization verification exhaustion remains distinct from an invalid derivation" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const f = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(f, try b.pure(try b.constant(void, {})));
    const before = b.module(f, unit);
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{} };
    var output = try pe.specialize(a, before, request);
    defer output.deinit();
    output.request.policy.work = 0;
    output.key = try pe.identity(a, before, output.request);
    try std.testing.expectError(
        error.SpecializationLimit,
        pe.validate(a, before, output.request, &output),
    );
    output.request = request;
    output.key = try pe.identity(a, before, request);
    output.term_proofs.items[0].before = std.math.maxInt(u64);
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, before, request, &output),
    );
}

test "private layout preserves nonstable evaluation order and shared pure prefixes" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const triple = try b.schema(.{ .product = &.{ word, word, word } });
    const f = try b.declare(&.{ word, word }, triple, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const y = try b.reference(b.parameter(f, 1));
    const first = try b.primitive(pair, .product, &.{ x, y }, 0);
    const second = try b.primitive(pair, .product, &.{ y, x }, 0);
    const left = try b.primitive(word, .field, &.{first}, 0);
    const right = try b.primitive(word, .field, &.{first}, 1);
    const other = try b.primitive(word, .field, &.{second}, 0);
    const result = try b.primitive(triple, .product, &.{ left, right, x }, 0);
    try b.define(f, try b.pure(result));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(result)].expression.primitive.operands = &.{ x, left, right };
    var steps = [_]relation.Step{.{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = triple,
        .coordinates = &.{ 2, 0, 1 },
    }} } }};
    const policy: relation.Policy = .{ .private_schemas = &.{triple} };
    try relation.validate(a, before, after, &steps, policy);
    @constCast(after.values)[@intCast(result)].expression.primitive.operands = &.{ right, left, x };
    steps[0].rule.product_layout = &.{.{ .schema = triple, .coordinates = &.{ 1, 0, 2 } }};
    try relation.validate(a, before, after, &steps, policy);
    b.values.items[@intCast(result)].expression.primitive.operands = &.{ left, other, x };
    @constCast(after.values)[@intCast(result)].expression.primitive.operands = &.{ other, left, x };
    try std.testing.expectError(error.UnsupportedRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        policy,
    ));
}

test "scalar relation removes xor zero while retaining dynamic operand evaluation" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const zero = try b.constant(u64, 0);
    const xor = try b.primitive(word, .integer_bit_xor, &.{ x, zero }, 0);
    try b.define(f, try b.pure(xor));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(xor)] = before.values[@intCast(x)];
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .scalar = .{
        .value = xor,
        .rule = .identity,
    } } }};
    try relation.validate(a, before, after, &steps, .{});
}

fn roundTripRelationStep(
    a: std.mem.Allocator,
    step: @import("relation.zig").Step,
) !@import("relation.zig").Step {
    const relation = @import("relation.zig");
    const data = @import("horos_data");
    var record = try relation.encodeRecordStep(a, step);
    var measure: data.wire.Writer = .{};
    try data.record.write(relation.RecordStep, record, &measure);
    var remaining: usize = 100_000;
    const decoded = try relation.decodeRecordStep(a, record, &remaining);
    const original_bytes = record.rule.specialization;
    record.rule.specialization = try std.mem.concat(a, u8, &.{
        record.rule.specialization, &.{0},
    });
    try std.testing.expectError(
        error.NonCanonical,
        relation.decodeRecordStep(a, record, &remaining),
    );
    @memset(@constCast(original_bytes), 0);
    return decoded;
}

test "source relation record budgets include every rule and successor ownership" {
    const relation = @import("relation.zig");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u8);
    const function = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(function, try b.pure(try b.constant(u8, 7)));
    const rules = [_]relation.Rule{
        .identity,
        .{ .scalar = .{ .value = 0, .rule = .identity } },
        .{ .inline_call = 0 },
        .{ .relocation = .{ .schemas = &.{ 1, 0 }, .values = &.{0} } },
        .{ .product_layout = &.{.{ .schema = 0, .coordinates = &.{ 1, 0 } }} },
        .{ .specialization = .{
            .request = .{ .context = context, .function = function, .arguments = &.{.dynamic} },
            .entry = function,
            .functions = &.{},
            .values = &.{.{ .before = 0, .after = 0, .children = &.{0} }},
            .terms = &.{},
        } },
    };
    for (rules) |rule| try checkRelationRecordBudget(b.allocator(), .{
        .successor = b.module(function, unit),
        .rule = rule,
    });
}

fn checkRelationRecordBudget(a: std.mem.Allocator, step: @import("relation.zig").Step) !void {
    const relation = @import("relation.zig");
    const data = @import("horos_data");
    const record = try relation.encodeRecordStep(a, step);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var meter = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var remaining: usize = 100_000;
    const decoded = try relation.decodeRecordStep(meter.allocator(), record, &remaining);
    try std.testing.expect(try data.record.equalAlloc(relation.Step, a, step, decoded));
    try std.testing.expectEqual(meter.allocated_bytes, 100_000 - remaining);
    try std.testing.expect(meter.allocated_bytes > 0);
    remaining = 0;
    const prior = meter.allocated_bytes;
    try std.testing.expectError(
        error.Capacity,
        relation.decodeRecordStep(meter.allocator(), record, &remaining),
    );
    try std.testing.expectEqual(prior, meter.allocated_bytes);
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 0 });
    remaining = 100_000;
    try std.testing.expectError(
        error.OutOfMemory,
        relation.decodeRecordStep(failing.allocator(), record, &remaining),
    );
    try std.testing.expectEqual(@as(usize, 100_000), remaining);
    var small = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const budget = prior / 2;
    remaining = budget;
    try std.testing.expectError(
        error.Capacity,
        relation.decodeRecordStep(small.allocator(), record, &remaining),
    );
    try std.testing.expectEqual(small.allocated_bytes, budget - remaining);
    try std.testing.expect(small.allocated_bytes <= budget);
}

test "source relation rejects malformed unused primitives through catalog admission" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u8);
    const pair = try b.schema(.{ .product = &.{ unit, unit } });
    const sequence = try b.schema(.{ .seq = word });
    const empty = try b.primitive(sequence, .sequence, &.{}, 0);
    const literal = try b.constant(u8, 7);
    const f = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(f, try b.pure(try b.constant(void, {})));
    const unused = try b.primitive(word, .move, &.{literal}, 0);
    const module = b.module(f, unit);
    const cases = [_]struct {
        opcode: p.Opcode,
        operands: []const u64,
        schema: u64,
        expected: anyerror,
    }{
        .{ .opcode = .move, .operands = &.{}, .schema = word, .expected = error.InvalidProgram },
        .{ .opcode = .field, .operands = &.{}, .schema = unit, .expected = error.TypeMismatch },
        .{ .opcode = .product, .operands = &.{}, .schema = pair, .expected = error.TypeMismatch },
        .{
            .opcode = .sequence_pop,
            .operands = &.{empty},
            .schema = unit,
            .expected = error.TypeMismatch,
        },
        .{
            .opcode = .integer_add,
            .operands = &.{ literal, literal },
            .schema = word,
            .expected = error.InvalidProgram,
        },
    };
    for (cases) |case| {
        b.values.items[@intCast(unused)] = .{ .schema = case.schema, .expression = .{
            .primitive = .{ .opcode = case.opcode, .operands = case.operands },
        } };
        try std.testing.expectError(case.expected, source.relation.validate(
            a,
            module,
            module,
            &.{.{ .successor = module, .rule = .{ .product_layout = &.{} } }},
            .{},
        ));
    }
}

test "source relation admits unused computations against actual generated constructors" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = unit,
        .effects = &.{},
        .regions = &.{},
    } } });
    const inner = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(inner, try b.pure(try b.constant(void, {})));
    const entry = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(entry, try b.term(.{ .apply = .{
        .computation = try b.lambda(inner, computation),
        .arguments = &.{},
    } }));
    const unused = try b.primitive(computation, .computation, &.{}, 0);
    const module = b.module(entry, unit);
    try source.relation.validate(a, module, module, &.{}, .{});
    const maps = try identitySourceMaps(b.allocator(), module);
    const relocated = try source.relation.Relocation.relocate(b.allocator(), module, maps);
    const steps = [_]source.relation.Step{.{
        .successor = relocated,
        .rule = .{ .relocation = maps },
    }};
    try source.relation.validate(a, module, relocated, &steps, .{});
    b.values.items[@intCast(unused)].expression.primitive.immediate = 1;
    try std.testing.expectError(
        error.InvalidReference,
        source.relation.validate(a, module, module, &.{}, .{}),
    );
}

fn identitySourceMaps(
    allocator: std.mem.Allocator,
    module: source.Module,
) !source.relation.Relocation.Maps {
    var maps: source.relation.Relocation.Maps = .{ .region_count = module.region_count };
    inline for (.{
        "schemas",   "constants", "effects", "handlers",  "resources",
        "variables", "values",    "terms",   "functions",
    }) |name| {
        const entries = try allocator.alloc(?u64, @field(module, name).len);
        for (entries, 0..) |*entry, index| entry.* = index;
        @field(maps, name) = entries;
    }
    return maps;
}

test "source relocation transports raw constructor indices across registration order" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u8);
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = word,
    } } });
    const generator_a = try b.declare(&.{}, computation, &.{}, &.{});
    const generator_b = try b.declare(&.{}, computation, &.{}, &.{});
    const target_a = try b.declare(&.{}, word, &.{}, &.{});
    const target_b = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(target_a, try b.pure(try b.constant(u8, 11)));
    try b.define(target_b, try b.pure(try b.constant(u8, 22)));
    try b.define(generator_a, try b.pure(try b.lambda(target_a, computation)));
    try b.define(generator_b, try b.pure(try b.lambda(target_b, computation)));
    const entry = try b.declare(&.{}, word, &.{}, &.{});
    const raw = try b.primitive(computation, .computation, &.{}, 0);
    try b.define(entry, try b.term(.{ .apply = .{ .computation = raw, .arguments = &.{} } }));
    const before = b.module(entry, unit);
    var work: u64 = 1_000_000;
    const bindings = source.constructor_bindings;
    const derived = try bindings.derive(a, b.allocator(), before, &work);
    try std.testing.expectEqualDeep(try bindings.admit(a, b.allocator(), before, &work), derived);
    try std.testing.expectEqual(target_a, derived[0].function);
    try std.testing.expectEqual(target_b, derived[1].function);
    var maps = try identitySourceMaps(b.allocator(), before);
    std.mem.swap(?u64, &@constCast(maps.functions)[0], &@constCast(maps.functions)[1]);
    const untransported = try source.relation.Relocation.relocate(b.allocator(), before, maps);
    try std.testing.expectError(error.InvalidRelation, source.relation.validate(
        a,
        before,
        untransported,
        &.{.{ .successor = untransported, .rule = .{ .relocation = maps } }},
        .{},
    ));
    maps.constructors = &.{ 1, 0 };
    const after = try source.relation.Relocation.relocate(b.allocator(), before, maps);
    const reordered = try bindings.derive(a, b.allocator(), after, &work);
    try std.testing.expectEqual(target_b, reordered[0].function);
    try std.testing.expectEqual(target_a, reordered[1].function);
    try std.testing.expectEqual(
        @as(u64, 1),
        after.values[@intCast(raw)].expression.primitive.immediate,
    );
    try source.relation.validate(a, before, after, &.{.{
        .successor = after,
        .rule = .{ .relocation = maps },
    }}, .{});
}

test "source relation rejects constructor rebinding through scalar handler simplification" {
    const bindings = @import("constructor_bindings.zig");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u8);
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = word,
    } } });
    const generator = try b.declare(&.{}, word, &.{}, &.{});
    const first = try b.declare(&.{}, word, &.{}, &.{});
    const second = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(first, try b.pure(try b.constant(u8, 7)));
    try b.define(second, try b.pure(try b.constant(u8, 9)));
    const returned = try b.declare(&.{ computation, word }, word, &.{}, &.{});
    try b.define(returned, try b.pure(try b.reference(b.parameter(returned, 1))));
    const handler = try b.handler(.{
        .mode = .deep,
        .input = word,
        .answer = word,
        .return_function = returned,
        .clauses = &.{},
        .state = &.{computation},
    });
    const lambda = try b.lambda(first, computation);
    const moved = try b.primitive(computation, .move, &.{lambda}, 0);
    try b.define(generator, try b.term(.{ .handle = .{
        .handler = handler,
        .body = moved,
        .state = &.{try b.lambda(second, computation)},
    } }));
    const entry = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(entry, try b.term(.{ .apply = .{
        .computation = try b.primitive(computation, .computation, &.{}, 0),
        .arguments = &.{},
    } }));
    const before = b.module(entry, unit);
    const after = try source.own(source.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(moved)] = before.values[@intCast(lambda)];
    var work: u64 = 1_000_000;
    const original = try bindings.admit(std.testing.allocator, b.allocator(), before, &work);
    const changed = try bindings.admit(std.testing.allocator, b.allocator(), after, &work);
    try std.testing.expectEqual(first, original[0].function);
    try std.testing.expectEqual(second, changed[0].function);
    const steps = [_]source.relation.Step{.{ .successor = after, .rule = .{ .scalar = .{
        .value = moved,
        .rule = .identity,
    } } }};
    try std.testing.expectError(
        error.InvalidRelation,
        source.relation.validate(std.testing.allocator, before, after, &steps, .{}),
    );
}

test "source reference traversal releases temporary ownership on success and allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, referenceTraversal, .{});
}

fn referenceTraversal(a: std.mem.Allocator) !void {
    const relocation = source.relation.Relocation;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ unit, unit } });
    var references: std.ArrayList(relocation.Reference) = .empty;
    defer references.deinit(a);
    try relocation.visitReferences(a, b.module(0, unit), .schema, pair, &references);
    try std.testing.expectEqualSlices(relocation.Reference, &.{
        .{ .kind = .schema, .id = unit },
        .{ .kind = .schema, .id = unit },
    }, references.items);
}

test "source relation charges explicit nominal mappings before expanding them" {
    const relation = source.relation;
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const f = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(f, try b.pure(try b.constant(void, {})));
    var before = b.module(f, unit);
    before.region_count = 100_000;
    const regions = try b.allocator().alloc(relation.Relocation.Region, 100_000);
    for (regions, 0..) |*region, index| region.* = .{ .old = index, .new = index };
    var maps: relation.Relocation.Maps = .{
        .schemas = &.{0},
        .constants = &.{0},
        .values = &.{0},
        .terms = &.{0},
        .functions = &.{0},
        .region_count = before.region_count,
    };
    try relation.validate(a, before, before, &.{.{
        .successor = before,
        .rule = .{ .relocation = maps },
    }}, .{});
    maps.regions = regions;
    try std.testing.expectError(error.RelationLimit, relation.validate(a, before, before, &.{.{
        .successor = before,
        .rule = .{ .relocation = maps },
    }}, .{ .work = 500 }));
}

test "private product relation transports primitive constant loads" {
    const relation = source.relation;
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u8);
    const boolean = try b.scalar(bool);
    const pair = try b.schema(.{ .product = &.{ word, boolean } });
    const literal = try b.literal(.{ .schema = pair, .bytes = &.{ 7, 1 } });
    const loaded = try b.primitive(
        pair,
        .constant,
        &.{},
        b.values.items[@intCast(literal)].expression.literal,
    );
    const projected = try b.primitive(word, .field, &.{loaded}, 0);
    const f = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(f, try b.pure(projected));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.schemas)[@intCast(pair)].product = &.{ boolean, word };
    @constCast(after.constants)[0].bytes = &.{ 1, 7 };
    @constCast(after.values)[@intCast(projected)].expression.primitive.immediate = 1;
    try relation.validate(a, before, after, &.{.{
        .successor = after,
        .rule = .{ .product_layout = &.{.{ .schema = pair, .coordinates = &.{ 1, 0 } }} },
    }}, .{ .private_schemas = &.{pair} });
}

test "projection discards total nested products but preserves potentially failing operands" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const one = try b.constant(u64, 1);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const failing = try b.value(.{ .schema = word, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ x, one },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
    } } });
    const nested = try b.primitive(pair, .product, &.{ x, x }, 0);
    const field = try b.primitive(word, .field, &.{nested}, 1);
    const product = try b.primitive(pair, .product, &.{ x, field }, 0);
    const projection = try b.primitive(word, .field, &.{product}, 0);
    try b.define(f, try b.pure(projection));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(projection)] = before.values[@intCast(x)];
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .scalar = .{
        .value = projection,
        .rule = .projection,
    } } }};
    try relation.validate(a, before, after, &steps, .{});
    b.values.items[@intCast(product)].expression.primitive.operands = &.{ x, failing };
    @constCast(after.values)[@intCast(product)] = before.values[@intCast(product)];
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{},
    ));
    b.values.items[@intCast(projection)].expression.primitive.immediate = 1;
    @constCast(after.values)[@intCast(projection)] = before.values[@intCast(failing)];
    try relation.validate(a, before, after, &steps, .{});
}

test "private layouts check wide inverses and reject invalid coordinate maps" {
    const relation = source.relation;
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const byte = try b.scalar(u8);
    const fields: [1024]u64 = @splat(byte);
    const product = try b.schema(.{ .product = &fields });
    const f = try b.declare(&.{ byte, byte }, byte, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const y = try b.reference(b.parameter(f, 1));
    const operands = try b.allocator().alloc(u64, fields.len);
    @memset(operands, x);
    operands[operands.len - 1] = y;
    const tuple = try b.primitive(product, .product, operands, 0);
    const field = try b.primitive(byte, .field, &.{tuple}, 0);
    try b.define(f, try b.pure(field));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    const reversed = try b.allocator().dupe(u64, operands);
    std.mem.reverse(u64, reversed);
    @constCast(after.values)[@intCast(tuple)].expression.primitive.operands = reversed;
    @constCast(after.values)[@intCast(field)].expression.primitive.immediate = fields.len - 1;
    const coordinates = try b.allocator().alloc(u64, fields.len);
    for (coordinates, 0..) |*coordinate, i| coordinate.* = fields.len - i - 1;
    const layout: relation.Layout = .{ .schema = product, .coordinates = coordinates };
    var step: relation.Step = .{ .successor = after, .rule = .{ .product_layout = &.{layout} } };
    const policy: relation.Policy = .{
        .private_schemas = &.{ product, product, std.math.maxInt(u64) },
    };
    try relation.validate(a, before, after, &.{step}, policy);
    var limited = policy;
    limited.work = try relationModuleCharges(before, after) + 100;
    try std.testing.expectError(
        error.RelationLimit,
        relation.validate(a, before, after, &.{step}, limited),
    );
    coordinates[0] = coordinates[1];
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &.{step}, policy),
    );
    coordinates[0] = coordinates.len;
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &.{step}, policy),
    );
    coordinates[0] = coordinates.len - 1;
    step.rule.product_layout = &.{ layout, layout };
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &.{step}, policy),
    );
    step.rule.product_layout = &.{.{ .schema = product, .coordinates = coordinates[1..] }};
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &.{step}, policy),
    );
}

fn relationModuleCharges(before: source.ast.Module, after: source.ast.Module) !u64 {
    const data = @import("horos_data");
    var measure: data.wire.Writer = .{};
    try data.record.write(source.ast.Module, before, &measure);
    try data.record.write(source.ast.Module, after, &measure);
    return measure.position + before.values.len + before.terms.len + before.schemas.len;
}

test "private layout empty permutations remain present and closure edges spend work" {
    const relation = source.relation;
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const empty = try b.schema(.{ .product = &.{} });
    const fields: [1024]u64 = @splat(unit);
    _ = try b.schema(.{ .product = &fields });
    const f = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(f, try b.pure(try b.constant(void, {})));
    const before = b.module(f, unit);
    const layout: relation.Layout = .{ .schema = empty, .coordinates = &.{} };
    const policy: relation.Policy = .{ .private_schemas = &.{empty} };
    var step: relation.Step = .{ .successor = before, .rule = .{ .product_layout = &.{layout} } };
    try relation.validate(a, before, before, &.{step}, policy);
    step.rule.product_layout = &.{ layout, layout };
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, before, &.{step}, policy),
    );
    step.rule.product_layout = &.{};
    var limited = policy;
    limited.work = try relationModuleCharges(before, before) + 100;
    try std.testing.expectError(
        error.RelationLimit,
        relation.validate(a, before, before, &.{step}, limited),
    );
}

test "private layout charges repeated nested literal traversal through zero width fields" {
    const relation = source.relation;
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const byte = try b.scalar(u8);
    var fields: [32]u64 = @splat(unit);
    fields[fields.len - 1] = byte;
    const inner = try b.schema(.{ .product = &fields });
    var outer = inner;
    for (0..15) |_| {
        fields[fields.len - 1] = outer;
        outer = try b.schema(.{ .product = &fields });
    }
    const f = try b.declare(&.{}, outer, &.{}, &.{});
    try b.define(f, try b.pure(try b.literal(.{ .schema = outer, .bytes = &.{7} })));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    fields[0] = byte;
    fields[fields.len - 1] = unit;
    @constCast(after.schemas)[@intCast(inner)].product = &fields;
    var coordinates: [32]u64 = undefined;
    for (&coordinates, 0..) |*coordinate, i| coordinate.* = i;
    coordinates[0] = coordinates.len - 1;
    coordinates[coordinates.len - 1] = 0;
    const step: relation.Step = .{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = inner,
        .coordinates = &coordinates,
    }} } };
    var policy: relation.Policy = .{ .private_schemas = &.{inner} };
    try relation.validate(a, before, after, &.{step}, policy);
    policy.work = try relationModuleCharges(before, after) + 5_000;
    try std.testing.expectError(
        error.RelationLimit,
        relation.validate(a, before, after, &.{step}, policy),
    );
}

test "bounded source literal reader charges enum and text scans without changing bytes" {
    const data = @import("horos_data");
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const schemas = [_]data.program.Schema{ .text, .{ .enumeration = &.{ 1, 2, 3, 4 } } };
    const facts = try data.admission.schemas(scratch, &schemas);
    for ([_][]const u8{ &.{ 4, 't', 'e', 's', 't' }, &.{ 4, 0, 0, 0 } }, 0..) |bytes, schema| {
        var reader: data.wire.Reader = .{ .input = bytes };
        const original = try data.admission.readValue(scratch, &schemas, facts, schema, &reader);
        try reader.finish();
        reader.position = 0;
        var low: u64 = 5;
        try std.testing.expectError(error.ValueWorkLimit, data.admission.readValueWithWork(
            scratch,
            &schemas,
            facts,
            schema,
            &reader,
            &low,
        ));
        reader.position = 0;
        var enough: u64 = 6;
        const bounded = try data.admission.readValueWithWork(
            scratch,
            &schemas,
            facts,
            schema,
            &reader,
            &enough,
        );
        try reader.finish();
        try std.testing.expectEqualSlices(u8, original, bounded);
        try std.testing.expectEqual(@as(u64, 0), enough);
    }
}

fn sharedDerivation(a: std.mem.Allocator, value_depth: usize, term_depth: usize) !pe.Output {
    var b = source.Builder.init(a);
    defer b.deinit();
    const word = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const unit = try b.scalar(void);
    const function = try b.declare(&.{ word, boolean }, word, &.{}, &.{});
    const condition = try b.reference(b.parameter(function, 1));
    var value = try b.reference(b.parameter(function, 0));
    for (0..value_depth) |_| value = try b.primitive(word, .integer_bit_xor, &.{ value, value }, 0);
    var body = try b.pure(value);
    for (0..term_depth) |_| body = try b.term(.{ .conditional = .{
        .condition = condition,
        .when_true = body,
        .when_false = body,
    } });
    try b.define(function, body);
    var out: pe.Output = .{
        .builder = source.Builder.init(a),
        .original = undefined,
        .request = .{
            .context = context,
            .function = function,
            .arguments = &.{ .dynamic, .dynamic },
            .policy = .{ .work = 1000 },
        },
        .entry = undefined,
        .key = undefined,
    };
    errdefer out.deinit();
    const storage = out.builder.allocator();
    out.original = try source.own(source.ast.Module, storage, b.module(function, unit));
    inline for (.{ "schemas", "constants", "variables", "values", "terms", "functions" }) |name|
        try @field(out.builder, name).appendSlice(storage, @field(out.original, name));
    out.entry = try out.builder.declare(&.{ word, boolean }, word, &.{}, &.{});
    try sharedValueProofs(&out);
    try sharedTermProofs(&out);
    const root = out.term_proofs.items.len - 1;
    try out.builder.define(out.entry, out.term_proofs.items[root].after);
    try out.functions.append(storage, .{
        .before = function,
        .after = out.entry,
        .arguments = out.request.arguments,
        .body = root,
    });
    out.key = try pe.identity(a, out.original, out.request);
    return out;
}

fn sharedValueProofs(out: *pe.Output) !void {
    const storage = out.builder.allocator();
    for (out.original.values, 0..) |original, index| {
        var value = original;
        var children: []const usize = &.{};
        switch (value.expression) {
            .variable => |variable| value.expression = .{
                .variable = out.builder.parameter(out.entry, @intCast(variable)),
            },
            .primitive => |op| {
                const operands = try storage.alloc(p.Id, op.operands.len);
                const proofs = try storage.alloc(usize, op.operands.len);
                for (op.operands, operands, proofs) |operand, *next, *proof| {
                    next.* = out.value_proofs.items[@intCast(operand)].after;
                    proof.* = @intCast(operand);
                }
                value.expression.primitive.operands = operands;
                children = proofs;
            },
            else => unreachable,
        }
        try out.value_proofs.append(storage, .{
            .before = @intCast(index),
            .after = try out.builder.value(value),
            .children = children,
        });
    }
}

fn sharedTermProofs(out: *pe.Output) !void {
    const storage = out.builder.allocator();
    for (out.original.terms, 0..) |original, index| {
        var term = original;
        var values: []const usize = undefined;
        var children: []const usize = &.{};
        switch (term) {
            .value => |value| {
                term = .{ .value = out.value_proofs.items[@intCast(value)].after };
                values = try storage.dupe(usize, &.{@intCast(value)});
            },
            .conditional => |branch| {
                term = .{ .conditional = .{
                    .condition = out.value_proofs.items[@intCast(branch.condition)].after,
                    .when_true = out.term_proofs.items[@intCast(branch.when_true)].after,
                    .when_false = out.term_proofs.items[@intCast(branch.when_false)].after,
                } };
                values = try storage.dupe(usize, &.{@intCast(branch.condition)});
                children = try storage.dupe(usize, &.{
                    @intCast(branch.when_true), @intCast(branch.when_false),
                });
            },
            else => unreachable,
        }
        try out.term_proofs.append(storage, .{
            .before = @intCast(index),
            .after = try out.builder.term(term),
            .values = values,
            .children = children,
        });
    }
}

fn validateSharedDerivation(a: std.mem.Allocator) !void {
    var out = try sharedDerivation(a, 4, 4);
    defer out.deinit();
    try pe.validate(a, out.original, out.request, &out);
}

test "specialization checks shared value and term DAGs within finite allowances" {
    const a = std.testing.allocator;
    var out = try sharedDerivation(a, 24, 24);
    defer out.deinit();
    const key = out.key;
    const value_count = out.value_proofs.items.len;
    const term_count = out.term_proofs.items.len;
    const expected = try source.own(source.ast.Module, out.builder.allocator(), out.module());
    try pe.validate(a, out.original, out.request, &out);
    try std.testing.expectEqual(key, out.key);
    try std.testing.expectEqual(value_count, out.value_proofs.items.len);
    try std.testing.expectEqual(term_count, out.term_proofs.items.len);
    try std.testing.expect(@import("horos_data").record.equal(
        source.ast.Module,
        expected,
        out.module(),
    ));
    var remaining: u64 = 1_000_000;
    try @import("specialize_validate.zig").validateWithWork(
        a,
        out.original,
        out.request,
        &out,
        &remaining,
    );
    try rejectLiteralProofWork(&out, 1_000_000 - remaining - 1);
    try @import("../allocation_testing.zig").check(a, validateSharedDerivation, .{});
}

fn rejectSharedDerivation(out: *pe.Output) !void {
    out.key = try pe.identity(std.testing.allocator, out.original, out.request);
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(std.testing.allocator, out.original, out.request, out),
    );
}

test "specialization shared facts preserve every source and parent edge" {
    var out = try sharedDerivation(std.testing.allocator, 2, 2);
    defer out.deinit();
    const values = out.value_proofs.items;
    const terms = out.term_proofs.items;
    const operands = @constCast(out.original.values[3].expression.primitive.operands);
    operands[1] = 1;
    try rejectSharedDerivation(&out);
    operands[1] = 2;
    const value_children = @constCast(values[3].children);
    value_children[1] = 3;
    try rejectSharedDerivation(&out);
    value_children[1] = 2;
    @constCast(out.original.terms)[2].conditional.when_false = 0;
    out.builder.terms.items[2].conditional.when_false = 0;
    try rejectSharedDerivation(&out);
    @constCast(out.original.terms)[2].conditional.when_false = 1;
    out.builder.terms.items[2].conditional.when_false = 1;
    @constCast(terms[2].children)[1] = 2;
    try rejectSharedDerivation(&out);
    @constCast(terms[2].children)[1] = 1;
    try pe.validate(std.testing.allocator, out.original, out.request, &out);
}

test "specialization shared facts retain residual root identities" {
    const a = std.testing.allocator;
    var out = try literalProof(a, &.{ 1, 2, 3 }, false);
    defer out.deinit();
    const proof = out.functions.items[0];
    const original = out.builder.functions.items[@intCast(out.entry)];
    const next = try out.builder.declare(&.{}, original.result, &.{}, &.{});
    try out.builder.define(next, original.body.?);
    var copy = proof;
    copy.after = next;
    try out.functions.append(out.builder.allocator(), copy);
    try pe.validate(a, out.original, out.request, &out);
    const body = out.builder.terms.items[@intCast(original.body.?)];
    const alternate = try out.builder.term(body);
    out.builder.functions.items[@intCast(next)].body = alternate;
    try rejectSharedDerivation(&out);
}

fn sharedDepth(out: *pe.Output, values: bool) !void {
    const storage = out.builder.allocator();
    const original = @constCast(out.original.terms);
    const proofs = out.term_proofs.items;
    original[2].conditional.when_true = 0;
    out.builder.terms.items[2] = original[2];
    @constCast(proofs[2].children)[0] = 0;
    out.builder.terms.items[@intCast(proofs[2].after)].conditional.when_true = proofs[0].after;
    if (values) {
        for (0..2) |index| {
            original[index] = .{ .value = @intCast(index + 2) };
            out.builder.terms.items[index] = original[index];
            proofs[index].values = try storage.dupe(usize, &.{index + 2});
            proofs[index].children = &.{};
            out.builder.terms.items[@intCast(proofs[index].after)] = .{
                .value = out.value_proofs.items[index + 2].after,
            };
        }
    }
}

test "specialization cached value and term heights preserve deeper depth failures" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |values| {
        var out = try sharedDerivation(a, if (values) 2 else 0, 2);
        defer out.deinit();
        try sharedDepth(&out, values);
        out.request.policy.depth = if (values) 4 else 3;
        out.key = try pe.identity(a, out.original, out.request);
        try pe.validate(a, out.original, out.request, &out);
        out.request.policy.depth -= 1;
        out.key = try pe.identity(a, out.original, out.request);
        try std.testing.expectError(
            error.SpecializationLimit,
            pe.validate(a, out.original, out.request, &out),
        );
    }
}

test "specialization completed facts do not conflate changed binding knowledge" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const word = try b.scalar(u64);
    const x = try b.variable(word);
    const y = try b.variable(word);
    const first = try b.pure(try b.constant(u64, 17));
    const second = try b.pure(try b.constant(u64, 18));
    const read = try b.pure(try b.reference(x));
    const changed = try b.bind(x, second, read);
    const function = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(function, try b.bind(x, first, try b.bind(y, read, changed)));
    var out = try pe.specialize(a, b.module(function, try b.scalar(void)), .{
        .context = context,
        .function = function,
        .arguments = &.{},
    });
    defer out.deinit();
    var prior: ?usize = null;
    for (out.term_proofs.items, 0..) |proof, index| {
        if (proof.before == read and prior == null) prior = index;
        if (proof.before != changed) continue;
        const shared = prior.?;
        @constCast(proof.children)[1] = shared;
        out.builder.terms.items[@intCast(proof.after)].bind.next =
            out.term_proofs.items[shared].after;
    }
    try std.testing.expect(prior != null);
    try rejectSharedDerivation(&out);
}
