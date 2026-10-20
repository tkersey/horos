// Copyright (c) 2026 Boundary contributors. MIT license.
//! Translation checker. Walks submitted local derivations against both modules;
//! does not call the partial evaluator or select specialization candidates.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const source = @import("../source.zig");
const ast = source.ast;
const pe = @import("specialize.zig");
const k = pe.values;
const Error = pe.Error;
const Binding = struct { before: p.Id, after: p.Id, knowledge: pe.Knowledge };
const Env = []const Binding;
const V = struct { knowledge: pe.Knowledge, total: bool };
fn require(ok: bool) Error!void {
    if (!ok) return error.InvalidSpecialization;
}
fn extend(a: std.mem.Allocator, env: Env, item: Binding) Error!Env {
    // An environment is a capture-avoiding renaming of the current source
    // scope. Shadowing retires the old source binding; every other binding
    // must keep a distinct target variable. All binder forms extend here.
    var retained: usize = 0;
    for (env) |binding| if (binding.before != item.before) {
        try require(binding.after != item.after);
        retained += 1;
    };
    const result = try a.alloc(Binding, retained + 1);
    var cursor: usize = 0;
    for (env) |binding| if (binding.before != item.before) {
        result[cursor] = binding;
        cursor += 1;
    };
    result[retained] = item;
    return result;
}
fn lookup(env: Env, id: p.Id) Error!Binding {
    var i = env.len;
    while (i != 0) {
        i -= 1;
        if (env[i].before == id) return env[i];
    }
    return error.InvalidSpecialization;
}
pub fn validate(
    a: std.mem.Allocator,
    original: ast.Module,
    request: pe.Request,
    out: *const pe.Output,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const residual = out.module();
    try require(std.mem.eql(u8, &out.key, &try pe.identity(original, request)));
    try require(data.record.equal(pe.Request, request, out.request));
    try require(data.record.equal(ast.Module, original, out.original));
    try require(
        original.failure == residual.failure and original.region_count == residual.region_count,
    );
    inline for (.{
        "schemas",
        "effects",
        "handlers",
        "resources",
    }) |field| try require(data.record.equal(
        @TypeOf(@field(original, field)),
        @field(original, field),
        @field(residual, field),
    ));
    inline for (.{ "constants", "variables", "values", "terms", "functions" }) |field| {
        const before = @field(original, field);
        const after = @field(residual, field);
        try require(after.len >= before.len);
        try require(data.record.equal(@TypeOf(before), before, after[0..before.len]));
    }
    try require(
        out.functions.items.len > 0 and
            out.functions.items.len + original.functions.len == residual.functions.len,
    );
    try require(
        out.functions.items[0].before == request.function and
            out.entry == out.functions.items[0].after,
    );
    try require(request.arguments.len == out.functions.items[0].arguments.len);
    var normalization_work = request.policy.work;
    for (
        request.arguments,
        out.functions.items[0].arguments,
    ) |raw, canonical| try require(k.equal(
        try k.normalize(storage, raw, &normalization_work),
        canonical,
    ));
    // Source admission precedes primitive evaluation; malformed operand shapes
    // cannot reach constant rules through a forged derivation.
    var admitted_original = try source.lower(a, original);
    admitted_original.deinit();
    const original_facts = try @import("check.zig").analyze(storage, original);
    const schema_facts = try data.admission.schemas(storage, original.schemas);
    try require(request.function < original.functions.len);
    const requested_function = original.functions[@intCast(request.function)];
    try require(request.arguments.len == requested_function.parameters.len);
    for (
        request.arguments,
        requested_function.parameters,
    ) |fact, parameter| try k.validate(
        storage,
        original,
        schema_facts,
        original.variables[@intCast(parameter)],
        fact,
    );
    // Source type/scope checking is additional to the semantic derivation.
    _ = try @import("check.zig").analyze(storage, residual);
    var checker: Checker = .{
        .a = storage,
        .before = original,
        .after = residual,
        .out = out,
        .facts = schema_facts,
        .left = request.policy.work,
        .captures = original_facts.functions,
        .max_depth = request.policy.depth,
    };
    for (out.functions.items, 0..) |f, i| {
        try require(f.before < original.functions.len and f.after == original.functions.len + i);
        try require(original_facts.functions[@intCast(f.before)].items.len == 0);
        const b = original.functions[@intCast(f.before)];
        const r = residual.functions[@intCast(f.after)];
        try require(
            f.arguments.len == b.parameters.len and
                b.body != null and
                r.body != null and
                f.body != null,
        );
        try require(b.result == r.result and std.mem.eql(
            p.Id,
            b.effects,
            r.effects,
        ) and std.mem.eql(p.Id, b.regions, r.regions));
        var env: Env = &.{};
        var cursor: usize = 0;
        for (b.parameters, f.arguments) |v, fact| {
            try k.validate(storage, original, checker.facts, original.variables[@intCast(v)], fact);
            var target = v;
            if (fact != .known) {
                try require(cursor < r.parameters.len);
                target = r.parameters[cursor];
                cursor += 1;
                try require(
                    target >= original.variables.len and residual.variables[
                        @intCast(target)
                    ] == original.variables[
                        @intCast(v)
                    ],
                );
            }
            env = try extend(storage, env, .{ .before = v, .after = target, .knowledge = fact });
        }
        try require(cursor == r.parameters.len);
        _ = try checker.term(f.body.?, b.body.?, r.body.?, env, 0, out.term_proofs.items.len);
    }
    var admitted_residual = try source.lower(a, residual);
    admitted_residual.deinit();
}
const Checker = struct {
    a: std.mem.Allocator,
    before: ast.Module,
    after: ast.Module,
    out: *const pe.Output,
    captures: []const @import("check.zig").Set,
    facts: data.admission.SchemaFacts,
    left: u64,
    max_depth: usize,
    fn spend(self: *Checker, depth: usize) Error!void {
        try require(self.left > 0 and depth <= self.max_depth);
        self.left -= 1;
    }
    fn value(
        self: *Checker,
        proof_id: usize,
        before: p.Id,
        after: p.Id,
        env: Env,
        depth: usize,
        parent: usize,
    ) Error!V {
        try self.spend(depth);
        try require(
            proof_id < parent and
                proof_id < self.out.value_proofs.items.len and
                before < self.before.values.len and
                after < self.after.values.len,
        );
        const proof = self.out.value_proofs.items[proof_id];
        try require(proof.before == before and proof.after == after);
        const b = self.before.values[@intCast(before)];
        const r = self.after.values[@intCast(after)];
        try require(b.schema == r.schema);
        var expected = b;
        var knowledge: pe.Knowledge = .dynamic;
        var total = true;
        switch (b.expression) {
            .literal => |v| {
                try require(proof.children.len == 0);
                knowledge = .{ .known = self.before.constants[@intCast(v)] };
            },
            .variable => |v| {
                try require(proof.children.len == 0);
                const bound = try lookup(env, v);
                knowledge = bound.knowledge;
                expected.expression = .{ .variable = bound.after };
            },
            .lambda => |function| {
                try require(self.captures[@intCast(function)].items.len == 0);
                try require(proof.children.len == 0);
                total = false;
            },
            .primitive => |op| {
                try require(proof.children.len == op.operands.len);
                const args = try self.a.alloc(p.Id, op.operands.len);
                const known = try self.a.alloc(pe.Knowledge, op.operands.len);
                for (op.operands, proof.children, args, known) |operand, child, *arg, *fact| {
                    try require(child < proof_id);
                    arg.* = self.out.value_proofs.items[child].after;
                    const result = try self.value(child, operand, arg.*, env, depth + 1, proof_id);
                    fact.* = result.knowledge;
                    total = total and result.total;
                }
                expected.expression.primitive.operands = args;
                knowledge = try k.normalize(
                    self.a,
                    try k.primitive(self.a, self.before, self.facts, b, known, &self.left),
                    &self.left,
                );
                total = total and knowledge == .known;
            },
        }
        if (proof.folded) {
            try require(total and knowledge == .known and r.expression == .literal);
            try require(data.record.equal(
                p.Literal,
                knowledge.known,
                self.after.constants[@intCast(r.expression.literal)],
            ));
        } else try require(data.record.equal(ast.Value, expected, r));
        return .{ .knowledge = knowledge, .total = total };
    }
    fn checkedValue(
        self: *Checker,
        proofs: []const usize,
        index: usize,
        before: p.Id,
        env: Env,
        depth: usize,
    ) Error!struct {
        id: p.Id,
        fact: V,
    } {
        try require(index < proofs.len and proofs[index] < self.out.value_proofs.items.len);
        const id = self.out.value_proofs.items[proofs[index]].after;
        return .{
            .id = id,
            .fact = try self.value(
                proofs[index],
                before,
                id,
                env,
                depth + 1,
                self.out.value_proofs.items.len,
            ),
        };
    }
    fn checkedTerm(
        self: *Checker,
        proofs: []const usize,
        index: usize,
        before: p.Id,
        env: Env,
        depth: usize,
        parent: usize,
    ) Error!struct {
        id: p.Id,
        knowledge: pe.Knowledge,
    } {
        try require(index < proofs.len and proofs[index] < parent);
        const id = self.out.term_proofs.items[proofs[index]].after;
        return .{
            .id = id,
            .knowledge = try self.term(proofs[index], before, id, env, depth + 1, parent),
        };
    }
    fn term(
        self: *Checker,
        proof_id: usize,
        before: p.Id,
        after: p.Id,
        env: Env,
        depth: usize,
        parent: usize,
    ) Error!pe.Knowledge {
        try self.spend(depth);
        try require(
            proof_id < parent and
                proof_id < self.out.term_proofs.items.len and
                before < self.before.terms.len and
                after < self.after.terms.len,
        );
        const proof = self.out.term_proofs.items[proof_id];
        try require(proof.before == before and proof.after == after);
        const b = self.before.terms[@intCast(before)];
        const r = self.after.terms[@intCast(after)];
        var expected = b;
        var knowledge: pe.Knowledge = .dynamic;
        if (b != .conditional and b != .match_sum) try require(proof.selected == null);
        if (b != .call) try require(proof.callee == null);
        switch (b) {
            .value, .fail => |v0| {
                try require(proof.values.len == 1 and proof.children.len == 0);
                const x = try self.checkedValue(proof.values, 0, v0, env, depth);
                expected = if (b == .value) .{ .value = x.id } else .{ .fail = x.id };
                if (b == .value) knowledge = x.fact.knowledge;
            },
            .bind => |v0| {
                try require(r == .bind and proof.values.len == 0 and proof.children.len == 2);
                const first = try self.checkedTerm(
                    proof.children,
                    0,
                    v0.value,
                    env,
                    depth,
                    proof_id,
                );
                try require(
                    r.bind.variable >= self.before.variables.len and self.before.variables[
                        @intCast(v0.variable)
                    ] == self.after.variables[
                        @intCast(r.bind.variable)
                    ],
                );
                const next_env = try extend(
                    self.a,
                    env,
                    .{
                        .before = v0.variable,
                        .after = r.bind.variable,
                        .knowledge = first.knowledge,
                    },
                );
                const next = try self.checkedTerm(
                    proof.children,
                    1,
                    v0.next,
                    next_env,
                    depth,
                    proof_id,
                );
                expected = .{ .bind = .{
                    .variable = r.bind.variable,
                    .value = first.id,
                    .next = next.id,
                } };
                knowledge = next.knowledge;
            },
            .conditional => |v0| {
                try require(proof.values.len == 1);
                const condition = try self.checkedValue(proof.values, 0, v0.condition, env, depth);
                if (proof.selected) |chosen| {
                    try require(
                        chosen < 2 and
                            proof.children.len == 1 and
                            condition.fact.total and
                            condition.fact.knowledge == .known,
                    );
                    try require(chosen == (if (condition.fact.knowledge.known.bytes[0] == 1) @as(
                        usize,
                        0,
                    ) else 1));
                    const child = try self.checkedTerm(
                        proof.children,
                        0,
                        if (chosen == 0) v0.when_true else v0.when_false,
                        env,
                        depth,
                        proof_id,
                    );
                    try require(after == child.id);
                    return child.knowledge;
                }
                try require(proof.children.len == 2);
                const yes = try self.checkedTerm(
                    proof.children,
                    0,
                    v0.when_true,
                    env,
                    depth,
                    proof_id,
                );
                const no = try self.checkedTerm(
                    proof.children,
                    1,
                    v0.when_false,
                    env,
                    depth,
                    proof_id,
                );
                expected = .{ .conditional = .{
                    .condition = condition.id,
                    .when_true = yes.id,
                    .when_false = no.id,
                } };
                if (k.equal(yes.knowledge, no.knowledge)) knowledge = yes.knowledge;
            },
            .call => |v0| {
                try require(proof.values.len == v0.arguments.len and proof.children.len == 0);
                var args: std.ArrayList(p.Id) = .empty;
                const target: ?pe.FunctionProof = if (proof.callee) |i| blk: {
                    try require(i < self.out.functions.items.len);
                    break :blk self.out.functions.items[i];
                } else null;
                if (target) |f| try require(
                    f.before == v0.function and f.arguments.len == v0.arguments.len,
                );
                for (v0.arguments, 0..) |arg, i| {
                    const x = try self.checkedValue(proof.values, i, arg, env, depth);
                    if (target) |f| {
                        const justified: pe.Knowledge = if (x.fact.knowledge == .known and
                            !x.fact.total)
                            .dynamic
                        else
                            x.fact.knowledge;
                        try require(k.equal(
                            try k.normalize(self.a, justified, &self.left),
                            f.arguments[i],
                        ));
                        if (f.arguments[i] == .known) continue;
                    }
                    try args.append(self.a, x.id);
                }
                expected = .{ .call = .{
                    .function = if (target) |f| f.after else v0.function,
                    .arguments = args.items,
                } };
            },
            .perform => |v0| {
                try require(
                    proof.children.len == 0 and proof.values.len == 1 + @intFromBool(
                        v0.capability != null,
                    ) + v0.bodies.len + v0.use_site_capabilities.len,
                );
                var op = v0;
                op.payload = (try self.checkedValue(proof.values, 0, v0.payload, env, depth)).id;
                var i: usize = 1;
                if (v0.capability) |cap| {
                    op.capability = (try self.checkedValue(proof.values, i, cap, env, depth)).id;
                    i += 1;
                }
                inline for (.{ "bodies", "use_site_capabilities" }) |name| {
                    const args = try self.a.alloc(p.Id, @field(v0, name).len);
                    for (@field(v0, name), args) |arg, *to| {
                        to.* = (try self.checkedValue(proof.values, i, arg, env, depth)).id;
                        i += 1;
                    }
                    @field(op, name) = args;
                }
                expected = .{ .perform = op };
            },
            .yield_then => |v0| {
                try require(proof.values.len == 0 and proof.children.len == 1);
                const next = try self.checkedTerm(proof.children, 0, v0, env, depth, proof_id);
                expected = .{ .yield_then = next.id };
                knowledge = next.knowledge;
            },
            .unpack_product => |v0| {
                try require(
                    r == .unpack_product and
                        proof.values.len == 1 and
                        proof.children.len == 1 and
                        r.unpack_product.variables.len == v0.variables.len,
                );
                const x = try self.checkedValue(proof.values, 0, v0.value, env, depth);
                var next_env = env;
                for (v0.variables, r.unpack_product.variables, 0..) |v1, v2, i| {
                    try require(
                        v2 >= self.before.variables.len and self.before.variables[
                            @intCast(v1)
                        ] == self.after.variables[
                            @intCast(v2)
                        ],
                    );
                    next_env = try extend(
                        self.a,
                        next_env,
                        .{
                            .before = v1,
                            .after = v2,
                            .knowledge = try k.field(
                                self.a,
                                self.before,
                                self.facts,
                                x.fact.knowledge,
                                i,
                                &self.left,
                            ),
                        },
                    );
                }
                const body = try self.checkedTerm(
                    proof.children,
                    0,
                    v0.body,
                    next_env,
                    depth,
                    proof_id,
                );
                expected = .{ .unpack_product = .{
                    .value = x.id,
                    .variables = r.unpack_product.variables,
                    .body = body.id,
                } };
                knowledge = body.knowledge;
            },
            .match_sum => |v0| {
                try require(proof.values.len == 1);
                const x = try self.checkedValue(proof.values, 0, v0.value, env, depth);
                if (proof.selected) |tag| {
                    try require(
                        x.fact.total and
                            x.fact.knowledge == .known and
                            tag < v0.cases.len and
                            proof.children.len == 1 and
                            r == .bind,
                    );
                    const branch = v0.cases[tag];
                    const schema = self.before.variables[@intCast(branch.variable)];
                    const payload_fact = try k.payload(x.fact.knowledge, schema);
                    try require(
                        payload_fact.tag == tag and
                            r.bind.variable >= self.before.variables.len and
                            self.after.variables[
                                @intCast(r.bind.variable)
                            ] == schema,
                    );
                    const first = self.after.terms[@intCast(r.bind.value)];
                    try require(first == .value);
                    const literal = self.after.values[@intCast(first.value)];
                    try require(
                        literal.schema == schema and
                            literal.expression == .literal and
                            data.record.equal(
                                p.Literal,
                                payload_fact.value.known,
                                self.after.constants[@intCast(literal.expression.literal)],
                            ),
                    );
                    const next_env = try extend(
                        self.a,
                        env,
                        .{
                            .before = branch.variable,
                            .after = r.bind.variable,
                            .knowledge = payload_fact.value,
                        },
                    );
                    const child = try self.checkedTerm(
                        proof.children,
                        0,
                        branch.body,
                        next_env,
                        depth,
                        proof_id,
                    );
                    expected = .{ .bind = .{
                        .variable = r.bind.variable,
                        .value = r.bind.value,
                        .next = child.id,
                    } };
                    knowledge = child.knowledge;
                } else {
                    try require(
                        r == .match_sum and
                            proof.children.len == v0.cases.len and
                            r.match_sum.cases.len == v0.cases.len,
                    );
                    const Case = @typeInfo(@TypeOf(v0.cases)).pointer.child;
                    const cases = try self.a.alloc(Case, v0.cases.len);
                    for (v0.cases, r.match_sum.cases, cases, 0..) |left, right, *to, i| {
                        try require(
                            right.variable >= self.before.variables.len and self.before.variables[
                                @intCast(left.variable)
                            ] == self.after.variables[
                                @intCast(right.variable)
                            ],
                        );
                        const next_env = try extend(
                            self.a,
                            env,
                            .{
                                .before = left.variable,
                                .after = right.variable,
                                .knowledge = .dynamic,
                            },
                        );
                        const body = try self.checkedTerm(
                            proof.children,
                            i,
                            left.body,
                            next_env,
                            depth,
                            proof_id,
                        );
                        to.* = .{ .variable = right.variable, .body = body.id };
                    }
                    expected = .{ .match_sum = .{ .value = x.id, .cases = cases } };
                }
            },
            else => return error.InvalidSpecialization,
        }
        try require(data.record.equal(ast.Term, expected, r));
        return knowledge;
    }
};
