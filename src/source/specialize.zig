// Copyright (c) 2026 Boundary contributors. MIT license.
//! Bounded first-order partial evaluation with independently checked derivations.
//! Original functions remain available for conservative generic calls.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const source = @import("../source.zig");
const ast = source.ast;
pub const values = @import("static_value.zig");
pub const Knowledge = values.Knowledge;
pub const Error = source.Error || error{ SpecializationLimit, UnsupportedSpecialization, InvalidSpecialization };
pub const Context = struct {
    core: [32]u8,
    guest: [32]u8,
    observation: [32]u8,
    base_profile: [32]u8,
    admission_profile: [32]u8,
    compiler_policy: [32]u8,
};
pub const Policy = struct { work: u64 = 1_000_000, keys_per_function: usize = 32, depth: usize = 512 };
pub const Request = struct { context: Context, function: p.Id, arguments: []const Knowledge, policy: Policy = .{} };
pub const ValueProof = struct { before: p.Id, after: p.Id, folded: bool = false, children: []const usize = &.{} };
pub const TermProof = struct {
    before: p.Id,
    after: p.Id,
    values: []const usize = &.{},
    children: []const usize = &.{},
    selected: ?usize = null,
    callee: ?usize = null,
};
pub const FunctionProof = struct { before: p.Id, after: p.Id, arguments: []const Knowledge, body: ?usize = null };
pub const Output = struct {
    builder: source.Builder,
    original: ast.Module,
    request: Request,
    entry: p.Id,
    key: [32]u8,
    functions: std.ArrayList(FunctionProof) = .empty,
    value_proofs: std.ArrayList(ValueProof) = .empty,
    term_proofs: std.ArrayList(TermProof) = .empty,
    pub fn deinit(self: *Output) void {
        self.builder.deinit();
        self.* = undefined;
    }
    pub fn module(self: *const Output) ast.Module {
        return self.builder.module(self.entry, self.original.failure);
    }
};
const Binding = struct { before: p.Id, after: p.Id, knowledge: Knowledge };
const Env = []const Binding;
const Value = struct { id: p.Id, knowledge: Knowledge, total: bool, proof: usize };
const Term = struct { id: p.Id, knowledge: Knowledge = .dynamic, proof: usize };
fn binding(env: Env, id: p.Id) Error!Binding {
    var i = env.len;
    while (i > 0) {
        i -= 1;
        if (env[i].before == id) return env[i];
    }
    return error.UnboundVariable;
}
fn extend(a: std.mem.Allocator, env: Env, item: Binding) !Env {
    const result = try a.alloc(Binding, env.len + 1);
    @memcpy(result[0..env.len], env);
    result[env.len] = item;
    return result;
}
pub fn identity(m: ast.Module, request: Request) Error![32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var writer: data.wire.Writer = .{ .hasher = &digest };
    try writer.put("horos.source-specialization/1\x00");
    try data.record.write(ast.Module, m, &writer);
    try data.record.write(Request, request, &writer);
    return digest.finalResult();
}
/// A policy limit rejects this candidate; the unchanged source remains usable.
/// No effect is performed and no unchecked partial result is returned.
pub fn specialize(a: std.mem.Allocator, original: ast.Module, requested: Request) Error!Output {
    var out: Output = .{ .builder = source.Builder.init(a), .original = undefined, .request = undefined, .entry = undefined, .key = undefined };
    errdefer out.deinit();
    const storage = out.builder.allocator();
    out.original = try source.own(ast.Module, storage, original);
    out.request = try source.own(Request, storage, requested);
    const m = out.original;
    inline for (.{ "schemas", "constants", "effects", "handlers", "resources", "variables", "values", "terms", "functions" }) |name| {
        try @field(out.builder, name).appendSlice(storage, @field(m, name));
    }
    out.builder.region_count = m.region_count;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var admitted_source = try source.lower(a, m);
    admitted_source.deinit();
    const checked = try @import("check.zig").analyze(scratch.allocator(), m);
    const schema_facts = try data.admission.schemas(storage, m.schemas);
    if (requested.function >= m.functions.len) return error.InvalidReference;
    const f = m.functions[@intCast(requested.function)];
    if (requested.arguments.len != f.parameters.len) return error.TypeMismatch;
    for (requested.arguments, f.parameters) |k, param| try values.validate(storage, m, schema_facts, m.variables[@intCast(param)], k);
    var engine: Engine = .{ .out = &out, .facts = schema_facts, .captures = checked.functions, .left = requested.policy.work };
    const root = try engine.request(requested.function, requested.arguments) orelse return error.UnsupportedSpecialization;
    out.entry = out.functions.items[root].after;
    var cursor: usize = 0;
    while (cursor < out.functions.items.len) : (cursor += 1) try engine.function(cursor);
    out.key = try identity(original, requested);
    try validate(a, original, requested, &out);
    return out;
}
const Engine = struct {
    out: *Output,
    facts: data.admission.SchemaFacts,
    captures: []const @import("check.zig").Set,
    left: u64,
    fn a(self: *Engine) std.mem.Allocator {
        return self.out.builder.allocator();
    }
    fn spend(self: *Engine, depth: usize) Error!void {
        if (self.left == 0 or depth > self.out.request.policy.depth) return error.SpecializationLimit;
        self.left -= 1;
    }
    fn supported(self: *Engine, id: p.Id, depth: usize) Error!bool {
        try self.spend(depth);
        const t = self.out.original.terms[@intCast(id)];
        return switch (t) {
            .value, .call, .perform, .fail => true,
            .bind => |v| try self.supported(v.value, depth + 1) and try self.supported(v.next, depth + 1),
            .conditional => |v| try self.supported(v.when_true, depth + 1) and try self.supported(v.when_false, depth + 1),
            .yield_then => |v| self.supported(v, depth + 1),
            .unpack_product => |v| self.supported(v.body, depth + 1),
            .match_sum => |v| blk: {
                for (v.cases) |c| if (!try self.supported(c.body, depth + 1)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }
    fn request(self: *Engine, id: p.Id, raw_arguments: []const Knowledge) Error!?usize {
        try self.spend(0);
        const arguments = try self.a().alloc(Knowledge, raw_arguments.len);
        for (raw_arguments, arguments) |raw, *canonical| canonical.* = try values.normalize(self.a(), raw, &self.left);
        var count: usize = 0;
        for (self.out.functions.items, 0..) |f, i| if (f.before == id) {
            count += 1;
            var same = f.arguments.len == arguments.len;
            if (same) for (f.arguments, arguments) |x, y| {
                if (!values.equal(x, y)) {
                    same = false;
                    break;
                }
            };
            if (same) return i;
        };
        // Changing static recursion becomes an ordinary call to the original
        // function. This bounds compiler search without limiting guest recursion.
        if (count >= self.out.request.policy.keys_per_function or self.captures[@intCast(id)].items.len != 0) return null;
        const original = self.out.original.functions[@intCast(id)];
        if (original.body == null or !try self.supported(original.body.?, 0)) return null;
        var parameters: std.ArrayList(p.Id) = .empty;
        for (original.parameters, arguments) |param, k| if (k != .known) try parameters.append(self.a(), self.out.original.variables[@intCast(param)]);
        const residual = try self.out.builder.declare(parameters.items, original.result, original.effects, original.regions);
        const index = self.out.functions.items.len;
        try self.out.functions.append(self.a(), .{ .before = id, .after = residual, .arguments = try source.own([]const Knowledge, self.a(), arguments) });
        return index;
    }
    fn function(self: *Engine, index: usize) Error!void {
        const proof = self.out.functions.items[index];
        const original = self.out.original.functions[@intCast(proof.before)];
        const residual = self.out.builder.functions.items[@intCast(proof.after)];
        var env: Env = &.{};
        var cursor: usize = 0;
        for (original.parameters, proof.arguments) |before, k| {
            const after = if (k == .known) before else residual.parameters[cursor];
            if (k != .known) cursor += 1;
            env = try extend(self.a(), env, .{ .before = before, .after = after, .knowledge = k });
        }
        const body = try self.term(original.body.?, env, 0);
        try self.out.builder.define(proof.after, body.id);
        self.out.functions.items[index].body = body.proof;
    }
    fn value(self: *Engine, id: p.Id, env: Env, depth: usize) Error!Value {
        try self.spend(depth);
        const before = self.out.original.values[@intCast(id)];
        var expression = before;
        var knowledge: Knowledge = .dynamic;
        var total = true;
        var children: std.ArrayList(usize) = .empty;
        switch (before.expression) {
            .variable => |v| {
                const b = try binding(env, v);
                expression.expression = .{ .variable = b.after };
                knowledge = b.knowledge;
            },
            .literal => |v| knowledge = .{ .known = self.out.original.constants[@intCast(v)] },
            .lambda => |v| {
                if (self.captures[@intCast(v)].items.len != 0) return error.UnsupportedSpecialization;
                total = false;
            },
            .primitive => |op| {
                const args = try self.a().alloc(p.Id, op.operands.len);
                const known = try self.a().alloc(Knowledge, op.operands.len);
                for (op.operands, args, known) |operand, *arg, *k| {
                    const result = try self.value(operand, env, depth + 1);
                    arg.* = result.id;
                    k.* = result.knowledge;
                    total = total and result.total;
                    try children.append(self.a(), result.proof);
                }
                expression.expression.primitive.operands = args;
                knowledge = try values.normalize(self.a(), try values.primitive(self.a(), self.out.original, self.facts, before, known, &self.left), &self.left);
                // Only a fully evaluated ordinary result proves a primitive total.
                // Partial record fields cannot erase a potentially failing sibling.
                total = total and knowledge == .known;
            },
        }
        const folded = total and knowledge == .known;
        const residual = if (folded) try self.out.builder.literal(knowledge.known) else try self.out.builder.value(expression);
        const proof = self.out.value_proofs.items.len;
        try self.out.value_proofs.append(self.a(), .{ .before = id, .after = residual, .folded = folded, .children = children.items });
        return .{ .id = residual, .knowledge = knowledge, .total = total, .proof = proof };
    }
    fn term(self: *Engine, id: p.Id, env: Env, depth: usize) Error!Term {
        try self.spend(depth);
        const original = self.out.original.terms[@intCast(id)];
        var residual = original;
        var vp: std.ArrayList(usize) = .empty;
        var tp: std.ArrayList(usize) = .empty;
        var knowledge: Knowledge = .dynamic;
        var selected: ?usize = null;
        var callee: ?usize = null;
        var alias: ?p.Id = null;
        switch (original) {
            .value, .fail => |v| {
                const x = try self.value(v, env, depth + 1);
                try vp.append(self.a(), x.proof);
                residual = if (original == .value) .{ .value = x.id } else .{ .fail = x.id };
                if (original == .value) knowledge = x.knowledge;
            },
            .bind => |v| {
                const first = try self.term(v.value, env, depth + 1);
                const variable = try self.out.builder.variable(self.out.original.variables[@intCast(v.variable)]);
                const next_env = try extend(self.a(), env, .{ .before = v.variable, .after = variable, .knowledge = first.knowledge });
                const next = try self.term(v.next, next_env, depth + 1);
                try tp.appendSlice(self.a(), &.{ first.proof, next.proof });
                residual = .{ .bind = .{ .variable = variable, .value = first.id, .next = next.id } };
                knowledge = next.knowledge;
            },
            .conditional => |v| {
                const condition = try self.value(v.condition, env, depth + 1);
                try vp.append(self.a(), condition.proof);
                if (condition.total and condition.knowledge == .known) {
                    selected = if (condition.knowledge.known.bytes[0] == 1) 0 else 1;
                    const child = try self.term(if (selected.? == 0) v.when_true else v.when_false, env, depth + 1);
                    alias = child.id;
                    knowledge = child.knowledge;
                    try tp.append(self.a(), child.proof);
                } else {
                    const yes = try self.term(v.when_true, env, depth + 1);
                    const no = try self.term(v.when_false, env, depth + 1);
                    try tp.appendSlice(self.a(), &.{ yes.proof, no.proof });
                    residual = .{ .conditional = .{ .condition = condition.id, .when_true = yes.id, .when_false = no.id } };
                    if (values.equal(yes.knowledge, no.knowledge)) knowledge = yes.knowledge;
                }
            },
            .call => |v| {
                const args = try self.a().alloc(p.Id, v.arguments.len);
                const ks = try self.a().alloc(Knowledge, v.arguments.len);
                for (v.arguments, args, ks) |arg, *to, *k| {
                    const x = try self.value(arg, env, depth + 1);
                    to.* = x.id;
                    // Dropping a static argument must not erase its evaluation.
                    k.* = if (x.knowledge == .known and !x.total) .dynamic else x.knowledge;
                    try vp.append(self.a(), x.proof);
                }
                callee = try self.request(v.function, ks);
                if (callee) |index| {
                    var dynamic: std.ArrayList(p.Id) = .empty;
                    for (args, self.out.functions.items[index].arguments) |arg, k| if (k != .known) try dynamic.append(self.a(), arg);
                    residual = .{ .call = .{ .function = self.out.functions.items[index].after, .arguments = dynamic.items } };
                } else residual = .{ .call = .{ .function = v.function, .arguments = args } };
            },
            .perform => |v| {
                var operation = v;
                const payload = try self.value(v.payload, env, depth + 1);
                operation.payload = payload.id;
                try vp.append(self.a(), payload.proof);
                if (v.capability) |cap| {
                    const x = try self.value(cap, env, depth + 1);
                    operation.capability = x.id;
                    try vp.append(self.a(), x.proof);
                }
                inline for (.{ "bodies", "use_site_capabilities" }) |name| {
                    const args = try self.a().alloc(p.Id, @field(v, name).len);
                    for (@field(v, name), args) |arg, *to| {
                        const x = try self.value(arg, env, depth + 1);
                        to.* = x.id;
                        try vp.append(self.a(), x.proof);
                    }
                    @field(operation, name) = args;
                }
                residual = .{ .perform = operation };
            },
            .yield_then => |v| {
                const x = try self.term(v, env, depth + 1);
                try tp.append(self.a(), x.proof);
                residual = .{ .yield_then = x.id };
                knowledge = x.knowledge;
            },
            .unpack_product => |v| {
                const x = try self.value(v.value, env, depth + 1);
                try vp.append(self.a(), x.proof);
                const vars = try self.a().alloc(p.Id, v.variables.len);
                var next_env = env;
                for (v.variables, vars, 0..) |before, *after, i| {
                    after.* = try self.out.builder.variable(self.out.original.variables[@intCast(before)]);
                    next_env = try extend(self.a(), next_env, .{ .before = before, .after = after.*, .knowledge = try values.field(self.a(), self.out.original, self.facts, x.knowledge, i, &self.left) });
                }
                const body = try self.term(v.body, next_env, depth + 1);
                try tp.append(self.a(), body.proof);
                residual = .{ .unpack_product = .{ .value = x.id, .variables = vars, .body = body.id } };
                knowledge = body.knowledge;
            },
            .match_sum => |v| {
                const x = try self.value(v.value, env, depth + 1);
                try vp.append(self.a(), x.proof);
                if (x.total and x.knowledge == .known) {
                    var reader: data.wire.Reader = .{ .input = x.knowledge.known.bytes };
                    const tag = try reader.count();
                    const branch = v.cases[tag];
                    const schema = self.out.original.variables[@intCast(branch.variable)];
                    const payload_fact = (try values.payload(x.knowledge, schema)).value;
                    const variable = try self.out.builder.variable(schema);
                    const next_env = try extend(self.a(), env, .{ .before = branch.variable, .after = variable, .knowledge = payload_fact });
                    const body = try self.term(branch.body, next_env, depth + 1);
                    try tp.append(self.a(), body.proof);
                    selected = tag;
                    knowledge = body.knowledge;
                    residual = .{ .bind = .{ .variable = variable, .value = try self.out.builder.pure(try self.out.builder.literal(payload_fact.known)), .next = body.id } };
                } else {
                    const Case = @typeInfo(@TypeOf(v.cases)).pointer.child;
                    const cases = try self.a().alloc(Case, v.cases.len);
                    for (v.cases, cases) |before, *after| {
                        const variable = try self.out.builder.variable(self.out.original.variables[@intCast(before.variable)]);
                        const next_env = try extend(self.a(), env, .{ .before = before.variable, .after = variable, .knowledge = .dynamic });
                        const body = try self.term(before.body, next_env, depth + 1);
                        try tp.append(self.a(), body.proof);
                        after.* = .{ .variable = variable, .body = body.id };
                    }
                    residual = .{ .match_sum = .{ .value = x.id, .cases = cases } };
                }
            },
            else => return error.UnsupportedSpecialization,
        }
        const after = alias orelse try self.out.builder.term(residual);
        const proof = self.out.term_proofs.items.len;
        try self.out.term_proofs.append(self.a(), .{ .before = id, .after = after, .values = vp.items, .children = tp.items, .selected = selected, .callee = callee });
        return .{ .id = after, .knowledge = knowledge, .proof = proof };
    }
};

pub const validate = @import("specialize_validate.zig").validate;
