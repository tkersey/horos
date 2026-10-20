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
const CheckedValue = struct { id: p.Id, fact: V };
const CheckedTerm = struct { id: p.Id, knowledge: pe.Knowledge };
const Case = @FieldType(@FieldType(ast.Term, "match_sum"), "cases");
const CaseItem = @typeInfo(Case).pointer.child;

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
    try validateEnvelope(storage, original, request, out);
    // Source admission precedes primitive evaluation; malformed operand shapes
    // cannot reach constant rules through a forged derivation.
    var admitted_original = try source.lower(a, original);
    admitted_original.deinit();
    const original_facts = try @import("check.zig").analyze(storage, original);
    const schema_facts = try data.admission.schemas(storage, original.schemas);
    try require(request.function < original.functions.len);
    const requested_function = original.functions[@intCast(request.function)];
    try require(request.arguments.len == requested_function.parameters.len);
    for (request.arguments, requested_function.parameters) |fact, parameter| try k.validate(
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
    for (out.functions.items, 0..) |f, i| try checker.function(f, i);
    var admitted_residual = try source.lower(a, residual);
    admitted_residual.deinit();
}
fn validateEnvelope(
    storage: std.mem.Allocator,
    original: ast.Module,
    request: pe.Request,
    out: *const pe.Output,
) Error!void {
    const residual = out.module();
    try require(std.mem.eql(u8, &out.key, &try pe.identity(storage, original, request)));
    try require(try pe.requestEqual(storage, request, out.request));
    try require(data.record.equal(ast.Module, original, out.original));
    try require(
        original.failure == residual.failure and original.region_count == residual.region_count,
    );
    inline for (.{ "schemas", "effects", "handlers", "resources" }) |field| try require(
        data.record.equal(
            @TypeOf(@field(original, field)),
            @field(original, field),
            @field(residual, field),
        ),
    );
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
    for (request.arguments, out.functions.items[0].arguments) |raw, canonical| try require(
        try k.equal(storage, try k.normalize(storage, raw, &normalization_work), canonical),
    );
}
const Visit = struct {
    proof_id: usize,
    before: p.Id,
    after: p.Id,
    env: Env,
    depth: usize,
    parent: usize,
};
const ValueFrame = struct {
    visit: Visit,
    expected: ast.Value,
    knowledge: pe.Knowledge = .dynamic,
    total: bool = true,
    cursor: usize = 0,
    args: []p.Id = &.{},
    known: []pe.Knowledge = &.{},
};
const TermFrame = struct {
    visit: Visit,
    expected: ast.Term,
    knowledge: pe.Knowledge = .dynamic,
    cursor: usize = 0,
    first: CheckedTerm = undefined,
    value: CheckedValue = undefined,
    cases: []CaseItem = &.{},
};
const Action = union(enum) { child: Visit, done: pe.Knowledge };
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
    fn function(self: *Checker, f: pe.FunctionProof, i: usize) Error!void {
        try require(f.before < self.before.functions.len and
            f.after == self.before.functions.len + i);
        try require(self.captures[@intCast(f.before)].items.len == 0);
        const b = self.before.functions[@intCast(f.before)];
        const r = self.after.functions[@intCast(f.after)];
        try require(f.arguments.len == b.parameters.len and
            b.body != null and r.body != null and f.body != null);
        try require(b.result == r.result and std.mem.eql(p.Id, b.effects, r.effects) and
            std.mem.eql(p.Id, b.regions, r.regions));
        var env: Env = &.{};
        var cursor: usize = 0;
        for (b.parameters, f.arguments) |v, fact| {
            try k.validate(
                self.a,
                self.before,
                self.facts,
                self.before.variables[@intCast(v)],
                fact,
            );
            var target = v;
            if (fact != .known) {
                try require(cursor < r.parameters.len);
                target = r.parameters[cursor];
                cursor += 1;
                try self.variable(v, target);
            }
            env = try extend(self.a, env, .{ .before = v, .after = target, .knowledge = fact });
        }
        try require(cursor == r.parameters.len);
        _ = try self.term(.{
            .proof_id = f.body.?,
            .before = b.body.?,
            .after = r.body.?,
            .env = env,
            .depth = 0,
            .parent = self.out.term_proofs.items.len,
        });
    }
    fn variable(self: *Checker, before: p.Id, after: p.Id) Error!void {
        try require(after >= self.before.variables.len and
            self.before.variables[@intCast(before)] == self.after.variables[@intCast(after)]);
    }
    fn valueFrame(self: *Checker, visit: Visit) Error!ValueFrame {
        try self.spend(visit.depth);
        try require(visit.proof_id < visit.parent and
            visit.proof_id < self.out.value_proofs.items.len and
            visit.before < self.before.values.len and visit.after < self.after.values.len);
        const proof = self.out.value_proofs.items[visit.proof_id];
        try require(proof.before == visit.before and proof.after == visit.after);
        const b = self.before.values[@intCast(visit.before)];
        try require(b.schema == self.after.values[@intCast(visit.after)].schema);
        var frame: ValueFrame = .{ .visit = visit, .expected = b };
        switch (b.expression) {
            .literal => |v| {
                try require(proof.children.len == 0);
                frame.knowledge = .{ .known = self.before.constants[@intCast(v)] };
            },
            .variable => |v| {
                try require(proof.children.len == 0);
                const bound = try lookup(visit.env, v);
                frame.knowledge = bound.knowledge;
                frame.expected.expression = .{ .variable = bound.after };
            },
            .lambda => |function_id| {
                try require(self.captures[@intCast(function_id)].items.len == 0);
                try require(proof.children.len == 0);
                frame.total = false;
            },
            .primitive => |op| {
                try require(proof.children.len == op.operands.len);
                frame.args = try self.a.alloc(p.Id, op.operands.len);
                frame.known = try self.a.alloc(pe.Knowledge, op.operands.len);
            },
        }
        return frame;
    }
    fn finishValue(self: *Checker, frame: *ValueFrame) Error!V {
        const visit = frame.visit;
        const b = self.before.values[@intCast(visit.before)];
        const r = self.after.values[@intCast(visit.after)];
        if (b.expression == .primitive) {
            frame.expected.expression.primitive.operands = frame.args;
            frame.knowledge = try k.normalize(
                self.a,
                try k.primitive(self.a, self.before, self.facts, b, frame.known, &self.left),
                &self.left,
            );
            frame.total = frame.total and frame.knowledge == .known;
        }
        if (self.out.value_proofs.items[visit.proof_id].folded) {
            try require(frame.total and frame.knowledge == .known and r.expression == .literal);
            try require(data.record.equal(
                p.Literal,
                frame.knowledge.known,
                self.after.constants[@intCast(r.expression.literal)],
            ));
        } else try require(data.record.equal(ast.Value, frame.expected, r));
        return .{ .knowledge = frame.knowledge, .total = frame.total };
    }
    fn value(self: *Checker, root: Visit) Error!V {
        var stack: std.ArrayList(ValueFrame) = .empty;
        defer stack.deinit(self.a);
        try stack.append(self.a, try self.valueFrame(root));
        var result: V = undefined;
        while (stack.items.len != 0) {
            const frame = &stack.items[stack.items.len - 1];
            const visit = frame.visit;
            const b = self.before.values[@intCast(visit.before)];
            if (b.expression == .primitive and frame.cursor < frame.args.len) {
                const index = frame.cursor;
                const child_id = self.out.value_proofs.items[visit.proof_id].children[index];
                try require(child_id < visit.proof_id);
                frame.args[index] = self.out.value_proofs.items[child_id].after;
                const child_visit: Visit = .{
                    .proof_id = child_id,
                    .before = b.expression.primitive.operands[index],
                    .after = frame.args[index],
                    .env = visit.env,
                    .depth = visit.depth + 1,
                    .parent = visit.proof_id,
                };
                try stack.append(self.a, try self.valueFrame(child_visit));
                continue;
            }
            result = try self.finishValue(frame);
            _ = stack.pop();
            if (stack.items.len != 0) {
                const parent = &stack.items[stack.items.len - 1];
                parent.known[parent.cursor] = result.knowledge;
                parent.total = parent.total and result.total;
                parent.cursor += 1;
            }
        }
        return result;
    }
    fn checkedValue(
        self: *Checker,
        frame: *const TermFrame,
        index: usize,
        before: p.Id,
    ) Error!CheckedValue {
        const visit = frame.visit;
        const proofs = self.out.term_proofs.items[visit.proof_id].values;
        try require(index < proofs.len and proofs[index] < self.out.value_proofs.items.len);
        const id = self.out.value_proofs.items[proofs[index]].after;
        return .{ .id = id, .fact = try self.value(.{
            .proof_id = proofs[index],
            .before = before,
            .after = id,
            .env = visit.env,
            .depth = visit.depth + 1,
            .parent = self.out.value_proofs.items.len,
        }) };
    }
    fn child(
        self: *Checker,
        frame: *const TermFrame,
        index: usize,
        before: p.Id,
        env: Env,
    ) Error!Action {
        const visit = frame.visit;
        const proofs = self.out.term_proofs.items[visit.proof_id].children;
        try require(index < proofs.len and proofs[index] < visit.proof_id);
        return .{ .child = .{
            .proof_id = proofs[index],
            .before = before,
            .after = self.out.term_proofs.items[proofs[index]].after,
            .env = env,
            .depth = visit.depth + 1,
            .parent = visit.proof_id,
        } };
    }
    fn term(self: *Checker, root: Visit) Error!pe.Knowledge {
        var stack: std.ArrayList(TermFrame) = .empty;
        defer stack.deinit(self.a);
        try stack.append(self.a, .{ .visit = root, .expected = undefined });
        var result: ?CheckedTerm = null;
        while (stack.items.len != 0) {
            const frame = &stack.items[stack.items.len - 1];
            const action = if (result) |previous|
                try self.resumeTerm(frame, previous)
            else
                try self.begin(frame);
            result = null;
            switch (action) {
                .child => |visit| try stack.append(self.a, .{
                    .visit = visit,
                    .expected = undefined,
                }),
                .done => |knowledge| {
                    result = .{ .id = frame.visit.after, .knowledge = knowledge };
                    _ = stack.pop();
                },
            }
        }
        return result.?.knowledge;
    }
    fn finish(self: *Checker, frame: *const TermFrame) Error!Action {
        try require(data.record.equal(
            ast.Term,
            frame.expected,
            self.after.terms[@intCast(frame.visit.after)],
        ));
        return .{ .done = frame.knowledge };
    }
    fn begin(self: *Checker, frame: *TermFrame) Error!Action {
        const visit = frame.visit;
        try self.spend(visit.depth);
        try require(visit.proof_id < visit.parent and
            visit.proof_id < self.out.term_proofs.items.len and
            visit.before < self.before.terms.len and visit.after < self.after.terms.len);
        const proof = self.out.term_proofs.items[visit.proof_id];
        try require(proof.before == visit.before and proof.after == visit.after);
        const b = self.before.terms[@intCast(visit.before)];
        const r = self.after.terms[@intCast(visit.after)];
        frame.expected = b;
        if (b != .conditional and b != .match_sum) try require(proof.selected == null);
        if (b != .call) try require(proof.callee == null);
        switch (b) {
            .value, .fail => |v| {
                try require(proof.values.len == 1 and proof.children.len == 0);
                const x = try self.checkedValue(frame, 0, v);
                frame.expected = if (b == .value) .{ .value = x.id } else .{ .fail = x.id };
                if (b == .value) frame.knowledge = x.fact.knowledge;
            },
            .bind => |v| {
                try require(r == .bind and proof.values.len == 0 and proof.children.len == 2);
                return self.child(frame, 0, v.value, visit.env);
            },
            .conditional => return self.beginConditional(frame),
            .call => try self.call(frame),
            .perform => try self.perform(frame),
            .yield_then => |v| {
                try require(proof.values.len == 0 and proof.children.len == 1);
                return self.child(frame, 0, v, visit.env);
            },
            .unpack_product => return self.unpack(frame),
            .match_sum => return self.match(frame),
            else => return error.InvalidSpecialization,
        }
        return self.finish(frame);
    }
    fn beginConditional(self: *Checker, frame: *TermFrame) Error!Action {
        const visit = frame.visit;
        const proof = self.out.term_proofs.items[visit.proof_id];
        const v = self.before.terms[@intCast(visit.before)].conditional;
        try require(proof.values.len == 1);
        frame.value = try self.checkedValue(frame, 0, v.condition);
        const condition = frame.value;
        if (proof.selected) |chosen| {
            try require(chosen < 2 and proof.children.len == 1 and condition.fact.total and
                condition.fact.knowledge == .known);
            try require(chosen == (if (condition.fact.knowledge.known.bytes[0] == 1)
                @as(usize, 0)
            else
                1));
            return self.child(frame, 0, if (chosen == 0) v.when_true else v.when_false, visit.env);
        }
        try require(proof.children.len == 2);
        return self.child(frame, 0, v.when_true, visit.env);
    }
    fn call(self: *Checker, frame: *TermFrame) Error!void {
        const visit = frame.visit;
        const proof = self.out.term_proofs.items[visit.proof_id];
        const v = self.before.terms[@intCast(visit.before)].call;
        try require(proof.values.len == v.arguments.len and proof.children.len == 0);
        var args: std.ArrayList(p.Id) = .empty;
        const target: ?pe.FunctionProof = if (proof.callee) |i| blk: {
            try require(i < self.out.functions.items.len);
            break :blk self.out.functions.items[i];
        } else null;
        if (target) |f| try require(f.before == v.function and f.arguments.len == v.arguments.len);
        for (v.arguments, 0..) |arg, i| {
            const x = try self.checkedValue(frame, i, arg);
            if (target) |f| {
                const justified: pe.Knowledge = if (x.fact.knowledge == .known and !x.fact.total)
                    .dynamic
                else
                    x.fact.knowledge;
                try require(try k.equal(
                    self.a,
                    try k.normalize(self.a, justified, &self.left),
                    f.arguments[i],
                ));
                if (f.arguments[i] == .known) continue;
            }
            try args.append(self.a, x.id);
        }
        frame.expected = .{ .call = .{
            .function = if (target) |f| f.after else v.function,
            .arguments = args.items,
        } };
    }
    fn perform(self: *Checker, frame: *TermFrame) Error!void {
        const proof = self.out.term_proofs.items[frame.visit.proof_id];
        const v = self.before.terms[@intCast(frame.visit.before)].perform;
        try require(proof.children.len == 0 and proof.values.len ==
            1 + @intFromBool(v.capability != null) + v.bodies.len + v.use_site_capabilities.len);
        var op = v;
        op.payload = (try self.checkedValue(frame, 0, v.payload)).id;
        var i: usize = 1;
        if (v.capability) |cap| {
            op.capability = (try self.checkedValue(frame, i, cap)).id;
            i += 1;
        }
        inline for (.{ "bodies", "use_site_capabilities" }) |name| {
            const args = try self.a.alloc(p.Id, @field(v, name).len);
            for (@field(v, name), args) |arg, *to| {
                to.* = (try self.checkedValue(frame, i, arg)).id;
                i += 1;
            }
            @field(op, name) = args;
        }
        frame.expected = .{ .perform = op };
    }
    fn unpack(self: *Checker, frame: *TermFrame) Error!Action {
        const visit = frame.visit;
        const proof = self.out.term_proofs.items[visit.proof_id];
        const v = self.before.terms[@intCast(visit.before)].unpack_product;
        const r = self.after.terms[@intCast(visit.after)];
        try require(r == .unpack_product and proof.values.len == 1 and
            proof.children.len == 1 and r.unpack_product.variables.len == v.variables.len);
        frame.value = try self.checkedValue(frame, 0, v.value);
        var next_env = visit.env;
        for (v.variables, r.unpack_product.variables, 0..) |v1, v2, i| {
            try self.variable(v1, v2);
            next_env = try extend(self.a, next_env, .{
                .before = v1,
                .after = v2,
                .knowledge = try k.field(
                    self.a,
                    self.before,
                    self.facts,
                    frame.value.fact.knowledge,
                    i,
                    &self.left,
                ),
            });
        }
        return self.child(frame, 0, v.body, next_env);
    }
    fn match(self: *Checker, frame: *TermFrame) Error!Action {
        const visit = frame.visit;
        const proof = self.out.term_proofs.items[visit.proof_id];
        const v = self.before.terms[@intCast(visit.before)].match_sum;
        const r = self.after.terms[@intCast(visit.after)];
        try require(proof.values.len == 1);
        frame.value = try self.checkedValue(frame, 0, v.value);
        if (proof.selected) |tag| return self.selectedMatch(frame, tag);
        try require(r == .match_sum and proof.children.len == v.cases.len and
            r.match_sum.cases.len == v.cases.len);
        frame.cases = try self.a.alloc(CaseItem, v.cases.len);
        return self.matchCase(frame);
    }
    fn selectedMatch(self: *Checker, frame: *TermFrame, tag: usize) Error!Action {
        const visit = frame.visit;
        const proof = self.out.term_proofs.items[visit.proof_id];
        const v = self.before.terms[@intCast(visit.before)].match_sum;
        const r = self.after.terms[@intCast(visit.after)];
        const x = frame.value;
        try require(x.fact.total and x.fact.knowledge == .known and tag < v.cases.len and
            proof.children.len == 1 and r == .bind);
        const branch = v.cases[tag];
        const schema = self.before.variables[@intCast(branch.variable)];
        const payload_fact = try k.payload(x.fact.knowledge, schema);
        try require(payload_fact.tag == tag and r.bind.variable >= self.before.variables.len and
            self.after.variables[@intCast(r.bind.variable)] == schema);
        const first = self.after.terms[@intCast(r.bind.value)];
        try require(first == .value);
        const literal = self.after.values[@intCast(first.value)];
        try require(literal.schema == schema and literal.expression == .literal and
            data.record.equal(
                p.Literal,
                payload_fact.value.known,
                self.after.constants[@intCast(literal.expression.literal)],
            ));
        const next_env = try extend(self.a, visit.env, .{
            .before = branch.variable,
            .after = r.bind.variable,
            .knowledge = payload_fact.value,
        });
        return self.child(frame, 0, branch.body, next_env);
    }
    fn matchCase(self: *Checker, frame: *TermFrame) Error!Action {
        const visit = frame.visit;
        const v = self.before.terms[@intCast(visit.before)].match_sum;
        const r = self.after.terms[@intCast(visit.after)].match_sum;
        if (frame.cursor == v.cases.len) {
            frame.expected = .{ .match_sum = .{ .value = frame.value.id, .cases = frame.cases } };
            return self.finish(frame);
        }
        const left = v.cases[frame.cursor];
        const right = r.cases[frame.cursor];
        try self.variable(left.variable, right.variable);
        const next_env = try extend(self.a, visit.env, .{
            .before = left.variable,
            .after = right.variable,
            .knowledge = .dynamic,
        });
        return self.child(frame, frame.cursor, left.body, next_env);
    }
    fn resumeTerm(self: *Checker, frame: *TermFrame, result: CheckedTerm) Error!Action {
        const visit = frame.visit;
        const b = self.before.terms[@intCast(visit.before)];
        const r = self.after.terms[@intCast(visit.after)];
        switch (b) {
            .bind => return self.resumeBind(frame, result),
            .conditional => return self.resumeConditional(frame, result),
            .yield_then => {
                frame.expected = .{ .yield_then = result.id };
                frame.knowledge = result.knowledge;
            },
            .unpack_product => {
                frame.expected = .{ .unpack_product = .{
                    .value = frame.value.id,
                    .variables = r.unpack_product.variables,
                    .body = result.id,
                } };
                frame.knowledge = result.knowledge;
            },
            .match_sum => {
                if (self.out.term_proofs.items[visit.proof_id].selected != null) {
                    frame.expected = .{ .bind = .{
                        .variable = r.bind.variable,
                        .value = r.bind.value,
                        .next = result.id,
                    } };
                    frame.knowledge = result.knowledge;
                } else {
                    frame.cases[frame.cursor] = .{
                        .variable = r.match_sum.cases[frame.cursor].variable,
                        .body = result.id,
                    };
                    frame.cursor += 1;
                    return self.matchCase(frame);
                }
            },
            else => unreachable,
        }
        return self.finish(frame);
    }
    fn resumeBind(self: *Checker, frame: *TermFrame, result: CheckedTerm) Error!Action {
        const visit = frame.visit;
        const b = self.before.terms[@intCast(visit.before)].bind;
        const r = self.after.terms[@intCast(visit.after)].bind;
        if (frame.cursor == 0) {
            frame.first = result;
            frame.cursor = 1;
            try self.variable(b.variable, r.variable);
            const next_env = try extend(self.a, visit.env, .{
                .before = b.variable,
                .after = r.variable,
                .knowledge = result.knowledge,
            });
            return self.child(frame, 1, b.next, next_env);
        }
        frame.expected = .{ .bind = .{
            .variable = r.variable,
            .value = frame.first.id,
            .next = result.id,
        } };
        frame.knowledge = result.knowledge;
        return self.finish(frame);
    }
    fn resumeConditional(self: *Checker, frame: *TermFrame, result: CheckedTerm) Error!Action {
        const visit = frame.visit;
        const proof = self.out.term_proofs.items[visit.proof_id];
        const b = self.before.terms[@intCast(visit.before)].conditional;
        if (proof.selected != null) {
            try require(visit.after == result.id);
            return .{ .done = result.knowledge };
        }
        if (frame.cursor == 0) {
            frame.first = result;
            frame.cursor = 1;
            return self.child(frame, 1, b.when_false, visit.env);
        }
        frame.expected = .{ .conditional = .{
            .condition = frame.value.id,
            .when_true = frame.first.id,
            .when_false = result.id,
        } };
        if (try k.equal(self.a, frame.first.knowledge, result.knowledge))
            frame.knowledge = frame.first.knowledge;
        return self.finish(frame);
    }
};
