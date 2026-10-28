const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const ast = source.ast;
const pe = source.specialize;
const bindings = @import("constructor_bindings.zig");
pub const Error = pe.Error || error{ InvalidRelation, UnsupportedRelation, RelationLimit };
pub const Layout = struct { schema: u64, coordinates: []const u64 };
pub const Scalar = struct { value: u64, rule: enum { fold, identity, projection } };
pub const Specialization = struct {
    request: pe.Request,
    entry: u64,
    functions: []const pe.FunctionProof,
    values: []const pe.ValueProof,
    terms: []const pe.TermProof,
};
pub const Relocation = @import("relation_relocate.zig");
pub const Rule = union(enum) {
    relocation: Relocation.Maps,
    identity,
    scalar: Scalar,
    inline_call: u64,
    product_layout: []const Layout,
    specialization: Specialization,
};
pub const Step = struct { successor: ast.Module, rule: Rule };
pub const RecordRule = @import("relation_record.zig").Rule;
pub const RecordStep = @import("relation_record.zig").Step;
pub const decodeRecordStep = @import("relation_record.zig").decode;
pub const encodeRecordStep = @import("relation_record.zig").encode;
pub const StaticScope = struct { predecessor: [32]u8, request: pe.Request };
pub const Policy = struct {
    static_scopes: []const StaticScope = &.{},
    work: u64 = 1_000_000,
    private_schemas: []const u64 = &.{},
    fixed_schemas: []const u64 = &.{},
    protected_functions: []const u64 = &.{},
};
pub const Context = struct {
    a: std.mem.Allocator,
    before: ast.Module,
    expected: ast.Module,
    policy: Policy,
    left: *u64,
    constructors: []const bindings.Binding = &.{},
    constants: []const data.program.Literal = &.{},
    successor_constructors: []const bindings.Binding = &.{},
    successor_constants: []const data.program.Literal = &.{},
    pub fn spend(self: *Context, count: usize) Error!void {
        if (count > self.left.*) return error.RelationLimit;
        self.left.* -= @intCast(count);
    }
    pub fn require(ok: bool) Error!void {
        if (!ok) return error.InvalidRelation;
    }
};
pub fn validate(
    a: std.mem.Allocator,
    approved: ast.Module,
    candidate: ast.Module,
    steps: []const Step,
    policy: Policy,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    var left = policy.work;
    var before = approved;
    var current_policy = policy;
    try chargeModule(approved, &left);
    var before_catalog = try bindings.admitCatalog(a, storage, approved, &left);
    for (steps) |step| {
        try chargeModule(step.successor, &left);
        try chargeModule(before, &left);
        var ctx: Context = .{
            .a = storage,
            .before = before,
            .expected = try source.own(ast.Module, storage, before),
            .policy = current_policy,
            .left = &left,
            .constructors = before_catalog.constructors,
            .constants = before_catalog.constants,
        };
        try ctx.spend(before.values.len);
        try ctx.spend(before.terms.len);
        try ctx.spend(before.schemas.len);
        switch (step.rule) {
            .identity => {},
            .relocation => |maps| {
                try chargeRecord(Relocation.Maps, maps, &left);
                try Relocation.validateMapsWithWork(storage, before, maps, true, 0, &left);
                ctx.expected = try Relocation.relocateCatalogWithWork(
                    storage,
                    before,
                    before_catalog.constants,
                    maps,
                    .{},
                    &left,
                );
                try fixedSchemas(&ctx, maps);
                current_policy = try relocatePolicy(storage, current_policy, maps, &left);
            },
            .scalar => |rule| try @import("relation_scalar.zig").apply(&ctx, rule),
            .inline_call => |term| try @import("relation_inline.zig").apply(&ctx, term),
            .product_layout => |layouts| try @import("relation_layout.zig").apply(&ctx, layouts),
            .specialization => |proof| {
                try specialization(&ctx, step.successor, proof);
                current_policy = try specializedPolicy(&ctx, proof);
            },
        }
        before_catalog = try finishStep(a, &ctx, step);
        before = step.successor;
    }
    try Context.require(data.record.equal(ast.Module, before, candidate));
}

fn finishStep(a: std.mem.Allocator, ctx: *Context, step: Step) Error!bindings.Catalog {
    try Context.require(data.record.equal(ast.Module, ctx.expected, step.successor));
    const catalog = try bindings.admitCatalog(a, ctx.a, step.successor, ctx.left);
    const constructors = catalog.constructors;
    ctx.successor_constructors = constructors;
    ctx.successor_constants = catalog.constants;
    if (step.rule == .specialization) try @import("relation_specialization.zig").coverage(
        ctx,
        step.successor,
        step.rule.specialization,
    );
    const transport = if (step.rule == .relocation)
        Relocation.transport(step.rule.relocation)
    else
        bindings.Transport{};
    try bindings.validate(ctx.before, ctx.constructors, constructors, transport, ctx.left);
    return catalog;
}

fn specialization(ctx: *Context, successor: ast.Module, proof: Specialization) Error!void {
    try Context.require(successor.entry == proof.entry);
    try Context.require(proof.request.function == ctx.before.entry);
    try validateStaticScope(ctx, proof.request);
    var out: pe.Output = .{
        .builder = source.Builder.init(ctx.a),
        .original = ctx.before,
        .request = proof.request,
        .entry = proof.entry,
        .key = try pe.identityWithWork(ctx.a, ctx.before, proof.request, ctx.left),
        .functions = .fromOwnedSlice(@constCast(proof.functions)),
        .value_proofs = .fromOwnedSlice(@constCast(proof.values)),
        .term_proofs = .fromOwnedSlice(@constCast(proof.terms)),
    };
    defer out.builder.deinit();
    inline for (.{
        "schemas",   "constants", "effects", "handlers",  "resources",
        "variables", "values",    "terms",   "functions",
    }) |name|
        try @field(out.builder, name).appendSlice(out.builder.allocator(), @field(successor, name));
    out.builder.region_count = successor.region_count;
    try Context.require(successor.failure == ctx.before.failure);
    @import("specialize_validate.zig").validateWithWork(
        ctx.a,
        ctx.before,
        proof.request,
        &out,
        ctx.left,
    ) catch |err| return if (err == error.SpecializationLimit or err == error.ValueWorkLimit)
        error.RelationLimit
    else
        err;
    ctx.expected = successor;
}

fn relocateIds(
    a: std.mem.Allocator,
    ids: []const u64,
    map: []const ?u64,
    work: *u64,
) Error![]const u64 {
    try data.admission.spend(work, ids.len);
    const result = try a.alloc(u64, ids.len);
    for (ids, result) |id, *next| {
        try Context.require(id < map.len);
        next.* = map[@intCast(id)] orelse return error.InvalidRelation;
    }
    return result;
}
fn relocatePolicy(
    a: std.mem.Allocator,
    policy: Policy,
    maps: Relocation.Maps,
    work: *u64,
) Error!Policy {
    var result = policy;
    result.private_schemas = try relocateIds(a, policy.private_schemas, maps.schemas, work);
    result.fixed_schemas = try relocateIds(a, policy.fixed_schemas, maps.schemas, work);
    result.protected_functions = try relocateIds(
        a,
        policy.protected_functions,
        maps.functions,
        work,
    );
    return result;
}
pub fn transportFunctions(
    a: std.mem.Allocator,
    roots: []const u64,
    steps: []const Step,
) Error![]u64 {
    const result = try a.dupe(u64, roots);
    errdefer a.free(result);
    for (steps) |step| if (step.rule == .relocation) {
        for (result) |*id| {
            const map = step.rule.relocation.functions;
            try Context.require(id.* < map.len);
            id.* = map[@intCast(id.*)] orelse return error.InvalidRelation;
        }
    };
    return result;
}

pub fn identity(module: ast.Module) Error![32]u8 {
    return identityWithWork(module, null);
}
pub fn identityWithWork(module: ast.Module, work: ?*u64) Error![32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var writer: data.wire.Writer = .{ .hasher = &digest, .remaining = work };
    try writer.put("horos.source-relation/1\x00");
    try data.record.write(ast.Module, module, &writer);
    return digest.finalResult();
}
fn chargeModule(module: ast.Module, left: *u64) Error!void {
    return chargeRecord(ast.Module, module, left);
}
fn chargeRecord(comptime T: type, value: T, left: *u64) Error!void {
    var measure: data.wire.Writer = .{ .remaining = left };
    try data.record.write(T, value, &measure);
}
fn validateStaticScope(ctx: *Context, request: pe.Request) Error!void {
    try ctx.spend(request.arguments.len);
    var has_static = false;
    for (request.arguments) |argument| has_static = has_static or argument != .dynamic;
    if (!has_static) return;
    const digest = try identityWithWork(ctx.before, ctx.left);
    for (ctx.policy.static_scopes) |scope| {
        try ctx.spend(1);
        if (std.mem.eql(u8, &digest, &scope.predecessor) and
            try pe.requestEqualWithWork(ctx.a, request, scope.request, ctx.left)) return;
    }
    return error.InvalidRelation;
}

fn fixedSchemas(ctx: *Context, maps: Relocation.Maps) Error!void {
    try ctx.spend(ctx.before.schemas.len);
    const seen = try ctx.a.alloc(bool, ctx.before.schemas.len);
    @memset(seen, false);
    var pending: std.ArrayList(Relocation.Reference) = .empty;
    try ctx.spend(ctx.policy.fixed_schemas.len);
    for (ctx.policy.fixed_schemas) |id|
        try pending.append(ctx.a, .{ .kind = .schema, .id = id });
    while (pending.pop()) |ref| {
        if (ref.kind != .schema) continue;
        try ctx.spend(1);
        try Context.require(ref.id < seen.len);
        if (seen[@intCast(ref.id)]) continue;
        seen[@intCast(ref.id)] = true;
        try Context.require(maps.schemas[@intCast(ref.id)] == ref.id);
        try Context.require(data.record.equal(
            data.program.Schema,
            ctx.before.schemas[@intCast(ref.id)],
            ctx.expected.schemas[@intCast(ref.id)],
        ));
        try Relocation.visitReferencesWithWork(
            ctx.a,
            ctx.before,
            ctx.constructors,
            .schema,
            ref.id,
            &pending,
            ctx.left,
        );
    }
}

fn specializedPolicy(ctx: *Context, proof: Specialization) Error!Policy {
    const policy = ctx.policy;
    try ctx.spend(ctx.before.functions.len);
    const selected = try ctx.a.alloc(bool, ctx.before.functions.len);
    @memset(selected, false);
    try ctx.spend(policy.protected_functions.len);
    for (policy.protected_functions) |function| {
        if (function < selected.len) selected[@intCast(function)] = true;
    }
    const capacity = std.math.add(usize, policy.protected_functions.len, proof.functions.len) catch
        return error.RelationLimit;
    try ctx.spend(capacity);
    const protected = try ctx.a.alloc(u64, capacity);
    @memcpy(protected[0..policy.protected_functions.len], policy.protected_functions);
    var count = policy.protected_functions.len;
    for (proof.functions) |function| {
        try ctx.spend(1);
        if (!selected[@intCast(function.before)]) continue;
        protected[count] = function.after;
        count += 1;
    }
    var result = policy;
    result.protected_functions = protected[0..count];
    return result;
}
