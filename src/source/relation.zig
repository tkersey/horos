const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const ast = source.ast;
const pe = source.specialize;
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
    var original = try source.lower(a, approved);
    original.deinit();
    for (steps) |step| {
        try chargeModule(step.successor, &left);
        var ctx: Context = .{
            .a = storage,
            .before = before,
            .expected = try source.own(ast.Module, storage, before),
            .policy = current_policy,
            .left = &left,
        };
        try ctx.spend(before.values.len + before.terms.len + before.schemas.len);
        switch (step.rule) {
            .identity => {},
            .relocation => |maps| {
                try chargeRecord(Relocation.Maps, maps, &left);
                try Relocation.validateMaps(storage, before, maps, true);
                ctx.expected = try Relocation.relocate(storage, before, maps);
                try fixedSchemas(&ctx, maps);
                current_policy = try relocatePolicy(storage, current_policy, maps);
            },
            .scalar => |rule| try @import("relation_scalar.zig").apply(&ctx, rule),
            .inline_call => |term| try @import("relation_inline.zig").apply(&ctx, term),
            .product_layout => |layouts| try @import("relation_layout.zig").apply(&ctx, layouts),
            .specialization => |proof| {
                try specialization(&ctx, step.successor, proof);
                current_policy = try specializedPolicy(storage, current_policy, proof);
            },
        }
        try Context.require(data.record.equal(ast.Module, ctx.expected, step.successor));
        var admitted = try source.lower(a, step.successor);
        admitted.deinit();
        before = step.successor;
    }
    try Context.require(data.record.equal(ast.Module, before, candidate));
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
        .key = try pe.identity(ctx.a, ctx.before, proof.request),
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
    try @import("specialize_validate.zig").validateWithWork(
        ctx.a,
        ctx.before,
        proof.request,
        &out,
        ctx.left,
    );
    try @import("relation_specialization.zig").coverage(ctx, successor, proof);
    ctx.expected = successor;
}

fn relocateIds(a: std.mem.Allocator, ids: []const u64, map: []const ?u64) Error![]const u64 {
    const result = try a.alloc(u64, ids.len);
    for (ids, result) |id, *next| {
        try Context.require(id < map.len);
        next.* = map[@intCast(id)] orelse return error.InvalidRelation;
    }
    return result;
}
fn relocatePolicy(a: std.mem.Allocator, policy: Policy, maps: Relocation.Maps) Error!Policy {
    var result = policy;
    result.private_schemas = try relocateIds(a, policy.private_schemas, maps.schemas);
    result.fixed_schemas = try relocateIds(a, policy.fixed_schemas, maps.schemas);
    result.protected_functions = try relocateIds(a, policy.protected_functions, maps.functions);
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
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var writer: data.wire.Writer = .{ .hasher = &digest };
    try writer.put("horos.source-relation/1\x00");
    try data.record.write(ast.Module, module, &writer);
    return digest.finalResult();
}
fn chargeModule(module: ast.Module, left: *u64) Error!void {
    return chargeRecord(ast.Module, module, left);
}
fn chargeRecord(comptime T: type, value: T, left: *u64) Error!void {
    var measure: data.wire.Writer = .{};
    try data.record.write(T, value, &measure);
    if (measure.position > left.*) return error.RelationLimit;
    left.* -= @intCast(measure.position);
}
fn validateStaticScope(ctx: *Context, request: pe.Request) Error!void {
    var has_static = false;
    for (request.arguments) |argument| has_static = has_static or argument != .dynamic;
    if (!has_static) return;
    const digest = try identity(ctx.before);
    for (ctx.policy.static_scopes) |scope| {
        if (std.mem.eql(u8, &digest, &scope.predecessor) and
            try pe.requestEqual(ctx.a, request, scope.request)) return;
    }
    return error.InvalidRelation;
}

fn fixedSchemas(ctx: *Context, maps: Relocation.Maps) Error!void {
    const seen = try ctx.a.alloc(bool, ctx.before.schemas.len);
    @memset(seen, false);
    var pending: std.ArrayList(Relocation.Reference) = .empty;
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
        try Relocation.visitReferences(ctx.a, ctx.before, .schema, ref.id, &pending);
    }
}

fn specializedPolicy(a: std.mem.Allocator, policy: Policy, proof: Specialization) Error!Policy {
    var protected: std.ArrayList(u64) = .empty;
    try protected.appendSlice(a, policy.protected_functions);
    for (proof.functions) |function| {
        if (std.mem.indexOfScalar(u64, policy.protected_functions, function.before) != null)
            try protected.append(a, function.after);
    }
    var result = policy;
    result.protected_functions = protected.items;
    return result;
}
