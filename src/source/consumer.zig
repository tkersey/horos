const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const check = @import("check.zig");
const inline_relation = @import("relation_inline.zig");
const relation = source.relation;
const Id = source.Id;
pub const Error = relation.Error;
pub const Site = struct { function: Id, binding: Id };
pub const Blocker = union(enum) {
    not_function_body,
    not_bound_call,
    not_direct_consumer,
    missing_consumer_argument,
    multiple_consumer_arguments,
    indirect_consumer_argument,
    protected_enclosing_function,
    producer: inline_relation.Blocker,
    consumer: inline_relation.Blocker,
};
pub const Boundary = struct {
    site: Site,
    producer_call: Id,
    consumer_call: Id,
    producer: Id,
    consumer: Id,
    binding: Id,
    argument_position: Id,
    producer_arguments: []const Id,
    consumer_arguments: []const Id,
    retained_variables: []const Id,
    producer_result: Id,
    consumer_input: Id,
    answer: Id,
    other_producer_calls: u64,
    producer_value_references: u64,
    producer_is_entry: bool,
    blocker: ?Blocker,
};
pub const Inspection = struct {
    arena: std.heap.ArenaAllocator,
    subject: [32]u8,
    outcome: union(enum) { boundary: Boundary, blocked: Blocker },

    pub fn deinit(self: *Inspection) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    predecessor: [32]u8,
    module: source.Module,
    steps: []const relation.Step,

    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn inspect(
    a: std.mem.Allocator,
    module: source.Module,
    site: Site,
    policy: relation.Policy,
) Error!Inspection {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var left = policy.work;
    const storage = arena.allocator();
    const owned = try snapshot(storage, module, &left);
    _ = try source.constructor_bindings.admit(a, storage, owned, &left);
    var ctx: relation.Context = .{
        .a = storage,
        .before = owned,
        .expected = owned,
        .policy = policy,
        .left = &left,
    };
    const subject = try relation.identity(owned);
    const outcome = try derive(&ctx, site);
    return .{ .arena = arena, .subject = subject, .outcome = outcome };
}

fn snapshot(a: std.mem.Allocator, module: source.Module, work: *u64) Error!source.Module {
    var measure: data.wire.Writer = .{ .remaining = work };
    try data.record.write(source.Module, module, &measure);
    return source.own(source.Module, a, module);
}

fn derive(ctx: *relation.Context, site: Site) Error!@FieldType(Inspection, "outcome") {
    const module = ctx.before;
    if (site.function >= module.functions.len or site.binding >= module.terms.len)
        return error.InvalidRelation;
    if (module.functions[@intCast(site.function)].body != site.binding)
        return .{ .blocked = .not_function_body };
    const term = module.terms[@intCast(site.binding)];
    if (term != .bind) return .{ .blocked = .not_bound_call };
    const binding = term.bind;
    const producer = module.terms[@intCast(binding.value)];
    if (producer != .call) return .{ .blocked = .not_bound_call };
    const consumer = module.terms[@intCast(binding.next)];
    if (consumer != .call) return .{ .blocked = .not_direct_consumer };
    const facts = try check.analyzeWithWork(ctx.a, module, ctx.left);
    const position = try argumentPosition(ctx, facts, binding.variable, consumer.call.arguments);
    if (position == .blocked) return .{ .blocked = position.blocked };
    return .{ .boundary = try describe(ctx, site, position.position, facts) };
}

fn argumentPosition(
    ctx: *relation.Context,
    facts: check.Facts,
    variable: Id,
    arguments: []const Id,
) Error!union(enum) { position: Id, blocked: Blocker } {
    var selected: ?Id = null;
    for (arguments, 0..) |id, position| {
        try ctx.spend(1);
        if (!facts.sets.contains(facts.values[@intCast(id)], variable)) continue;
        const value = ctx.before.values[@intCast(id)];
        if (value.expression != .variable or value.expression.variable != variable)
            return .{ .blocked = .indirect_consumer_argument };
        if (selected != null) return .{ .blocked = .multiple_consumer_arguments };
        selected = @intCast(position);
    }
    return if (selected) |position|
        .{ .position = position }
    else
        .{ .blocked = .missing_consumer_argument };
}

fn describe(
    ctx: *relation.Context,
    site: Site,
    position: Id,
    facts: check.Facts,
) Error!Boundary {
    const module = ctx.before;
    const binding = module.terms[@intCast(site.binding)].bind;
    const producer = module.terms[@intCast(binding.value)].call;
    const consumer = module.terms[@intCast(binding.next)].call;
    const input = module.functions[@intCast(consumer.function)].parameters[@intCast(position)];
    var blocker: ?Blocker = null;
    if (try inline_relation.eligibility(ctx, producer.function)) |reason|
        blocker = .{ .producer = reason }
    else if (try inline_relation.eligibility(ctx, consumer.function)) |reason|
        blocker = .{ .consumer = reason };
    for (ctx.policy.protected_functions) |function| {
        try ctx.spend(1);
        if (function == site.function) blocker = .protected_enclosing_function;
    }
    var other_calls: u64 = 0;
    for (module.terms, 0..) |term, id| {
        try ctx.spend(1);
        if (id != binding.value and term == .call and term.call.function == producer.function)
            other_calls += 1;
    }
    var value_references: u64 = 0;
    for (module.values) |value| {
        try ctx.spend(1);
        if (value.expression == .lambda and value.expression.lambda == producer.function)
            value_references += 1;
    }
    const retained = try facts.sets.remove(facts.terms[@intCast(binding.next)], binding.variable);
    try ctx.spend(@intCast(facts.sets.count(retained)));
    return .{
        .site = site,
        .producer_call = binding.value,
        .consumer_call = binding.next,
        .producer = producer.function,
        .consumer = consumer.function,
        .binding = binding.variable,
        .argument_position = position,
        .producer_arguments = producer.arguments,
        .consumer_arguments = consumer.arguments,
        .retained_variables = try facts.sets.materialize(ctx.a, retained),
        .producer_result = module.functions[@intCast(producer.function)].result,
        .consumer_input = module.variables[@intCast(input)],
        .answer = module.functions[@intCast(site.function)].result,
        .other_producer_calls = other_calls,
        .producer_value_references = value_references,
        .producer_is_entry = module.entry == producer.function,
        .blocker = blocker,
    };
}

pub fn compose(
    a: std.mem.Allocator,
    module: source.Module,
    site: Site,
    policy: relation.Policy,
) Error!Candidate {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const storage = arena.allocator();
    var left = policy.work;
    const original = try snapshot(storage, module, &left);
    var inspection = try inspect(a, original, site, policy);
    defer inspection.deinit();
    if (inspection.outcome != .boundary) return error.UnsupportedRelation;
    const boundary = inspection.outcome.boundary;
    if (boundary.blocker != null) return error.UnsupportedRelation;
    const steps = try storage.alloc(relation.Step, 2);
    const first = @max(boundary.producer_call, boundary.consumer_call);
    const second = @min(boundary.producer_call, boundary.consumer_call);
    steps[0] = try inlineStep(storage, original, first, policy, &left);
    steps[1] = try inlineStep(storage, steps[0].successor, second, policy, &left);
    try relation.validate(a, original, steps[1].successor, steps, policy);
    return .{
        .arena = arena,
        .predecessor = inspection.subject,
        .module = steps[1].successor,
        .steps = steps,
    };
}

fn inlineStep(
    a: std.mem.Allocator,
    before: source.Module,
    call: Id,
    policy: relation.Policy,
    left: *u64,
) Error!relation.Step {
    var ctx: relation.Context = .{
        .a = a,
        .before = before,
        .expected = try snapshot(a, before, left),
        .policy = policy,
        .left = left,
    };
    try inline_relation.apply(&ctx, call);
    return .{ .successor = ctx.expected, .rule = .{ .inline_call = call } };
}
