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
const V = struct { knowledge: pe.Knowledge, total: bool, height: usize = 0 };
const CheckedValue = struct { id: p.Id, fact: V };
const TermFact = struct { knowledge: pe.Knowledge, height: usize };
const CheckedTerm = struct { id: p.Id, fact: TermFact };
const Case = @FieldType(@FieldType(ast.Term, "match_sum"), "cases");
const CaseItem = @typeInfo(Case).pointer.child;

fn nextDepth(depth: usize) Error!usize {
    return std.math.add(usize, depth, 1) catch return error.SpecializationLimit;
}

fn require(ok: bool) Error!void {
    if (!ok) return error.InvalidSpecialization;
}
fn extend(a: std.mem.Allocator, env: Env, left: ?*u64, item: Binding) Error!Env {
    // An environment is a capture-avoiding renaming of the current source
    // scope. Shadowing retires the old source binding; every other binding
    // must keep a distinct target variable. All binder forms extend here.
    try data.admission.spend(left, env.len);
    var retained: usize = 0;
    for (env) |binding| if (binding.before != item.before) {
        try require(binding.after != item.after);
        retained += 1;
    };
    const count = std.math.add(usize, retained, 1) catch return error.RelationLimit;
    try data.admission.spend(left, count);
    try data.admission.spend(left, env.len);
    const result = try a.alloc(Binding, count);
    var cursor: usize = 0;
    for (env) |binding| if (binding.before != item.before) {
        result[cursor] = binding;
        cursor += 1;
    };
    result[retained] = item;
    return result;
}
fn lookup(env: Env, id: p.Id, left: ?*u64) Error!Binding {
    var i = env.len;
    while (i != 0) {
        try data.admission.spend(left, 1);
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
    return validateBody(a, original, request, out, null) catch |err|
        return if (err == error.RelationLimit) error.SpecializationLimit else err;
}

pub fn validateWithWork(
    a: std.mem.Allocator,
    original: ast.Module,
    request: pe.Request,
    out: *const pe.Output,
    remaining: *u64,
) Error!void {
    return validateBody(a, original, request, out, remaining);
}

fn validateBody(
    a: std.mem.Allocator,
    original: ast.Module,
    request: pe.Request,
    out: *const pe.Output,
    work: ?*u64,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    const residual = out.module();
    const root_arguments = try validateEnvelope(storage, original, request, out, work);
    // Source admission precedes primitive evaluation; malformed operand shapes
    // cannot reach constant rules through a forged derivation.
    try admit(a, original, work);
    const original_facts = try @import("check.zig").analyzeWithWork(storage, original, work);
    const schema_facts = try data.admission.schemasWithWork(storage, original.schemas, work);
    try require(request.function < original.functions.len);
    const requested_function = original.functions[@intCast(request.function)];
    try require(request.arguments.len == requested_function.parameters.len);
    for (request.arguments, requested_function.parameters) |fact, parameter| try k.validateWithWork(
        storage,
        original,
        schema_facts,
        original.variables[@intCast(parameter)],
        fact,
        work,
    );
    // Source type/scope checking is additional to the semantic derivation.
    _ = try @import("check.zig").analyzeWithWork(storage, residual, work);
    try data.admission.spend(work, out.functions.items.len);
    const arguments = try storage.alloc(?[]const pe.Knowledge, out.functions.items.len);
    @memset(arguments, null);
    arguments[0] = root_arguments;
    var checker: Checker = .{
        .a = storage,
        .before = original,
        .after = residual,
        .out = out,
        .facts = schema_facts,
        .left = request.policy.work,
        .work = work,
        .captures = original_facts.functions,
        .max_depth = request.policy.depth,
        .reads = .{ .module = original, .facts = schema_facts },
        .arguments = arguments,
    };
    defer checker.reads.deinit(storage);
    for (out.functions.items, 0..) |f, i| try checker.function(f, i);
    try admit(a, residual, work);
}
fn admit(a: std.mem.Allocator, module: ast.Module, work: ?*u64) Error!void {
    if (work) |remaining| return source.admitWithWork(a, module, remaining);
    var admitted = try source.lower(a, module);
    admitted.deinit();
}
fn validateEnvelope(
    storage: std.mem.Allocator,
    original: ast.Module,
    request: pe.Request,
    out: *const pe.Output,
    work: ?*u64,
) Error![]const pe.Knowledge {
    const residual = out.module();
    const identity = try pe.identityWithWork(storage, original, request, work);
    try require(std.mem.eql(u8, &out.key, &identity));
    try require(try pe.requestEqualWithWork(storage, request, out.request, work));
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
    return validateCanonicalArguments(storage, request, out, work);
}
fn validateCanonicalArguments(
    storage: std.mem.Allocator,
    request: pe.Request,
    out: *const pe.Output,
    work: ?*u64,
) Error![]const pe.Knowledge {
    var left = request.policy.work;
    try data.admission.spend(work, request.arguments.len);
    const arguments = try storage.alloc(pe.Knowledge, request.arguments.len);
    for (
        request.arguments,
        out.functions.items[0].arguments,
        arguments,
    ) |raw, canonical, *argument| {
        argument.* = try normalize(storage, raw, &left, work);
        try require(try k.equalWithWork(storage, argument.*, canonical, work));
    }
    return arguments;
}
const EvaluationWork = struct {
    local: *u64,
    global: ?*u64,
    available: u64,
    left: u64,

    fn init(local: *u64, global: ?*u64) EvaluationWork {
        const available = if (global) |remaining| @min(local.*, remaining.*) else local.*;
        return .{ .local = local, .global = global, .available = available, .left = available };
    }
    fn finish(self: *EvaluationWork) void {
        const spent = self.available - self.left;
        self.local.* -= spent;
        if (self.global) |remaining| remaining.* -= spent;
    }
};
fn normalize(
    a: std.mem.Allocator,
    value: pe.Knowledge,
    local: *u64,
    global: ?*u64,
) Error!pe.Knowledge {
    var evaluation = EvaluationWork.init(local, global);
    defer evaluation.finish();
    return k.normalize(a, value, &evaluation.left);
}
const Visit = struct {
    proof_id: usize,
    before: p.Id,
    after: p.Id,
    env: Env,
    depth: usize,
    parent: usize,
};
const FactKey = struct {
    proof_id: usize,
    env_address: usize,
    env_length: usize,

    fn of(visit: Visit) FactKey {
        return .{
            .proof_id = visit.proof_id,
            .env_address = @intFromPtr(visit.env.ptr),
            .env_length = visit.env.len,
        };
    }
};
const ValueFrame = struct {
    visit: Visit,
    expected: ast.Value,
    checked: ?V = null,
    height: usize = 0,
    knowledge: pe.Knowledge = .dynamic,
    total: bool = true,
    cursor: usize = 0,
    args: []p.Id = &.{},
    known: []pe.Knowledge = &.{},
};
const TermFrame = struct {
    visit: Visit,
    expected: ast.Term,
    height: usize = 0,
    cached: bool = false,
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
    work: ?*u64,
    max_depth: usize,
    reads: k.ReadCache,
    arguments: []?[]const pe.Knowledge,
    value_facts: std.AutoHashMapUnmanaged(FactKey, V) = .empty,
    term_facts: std.AutoHashMapUnmanaged(FactKey, TermFact) = .empty,

    fn spend(self: *Checker, depth: usize) Error!void {
        if (self.left == 0 or depth > self.max_depth) return error.SpecializationLimit;
        try data.admission.spend(self.work, 1);
        self.left -= 1;
    }
    fn checkHeight(self: *Checker, visit: Visit, height: usize) Error!void {
        const deepest = std.math.add(usize, visit.depth, height) catch
            return error.SpecializationLimit;
        if (deepest > self.max_depth) return error.SpecializationLimit;
    }
    fn function(self: *Checker, f: pe.FunctionProof, i: usize) Error!void {
        try data.admission.spend(self.work, 1);
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
        for (b.parameters, self.arguments[i] orelse f.arguments) |v, fact| {
            try k.validateWithWork(
                self.a,
                self.before,
                self.facts,
                self.before.variables[@intCast(v)],
                fact,
                self.work,
            );
            var target = v;
            if (fact != .known) {
                try require(cursor < r.parameters.len);
                target = r.parameters[cursor];
                cursor += 1;
                try self.variable(v, target);
            }
            env = try extend(self.a, env, self.work, .{
                .before = v,
                .after = target,
                .knowledge = fact,
            });
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
    fn primitive(
        self: *Checker,
        expression: ast.Value,
        args: []const pe.Knowledge,
    ) Error!pe.Knowledge {
        var evaluation = EvaluationWork.init(&self.left, self.work);
        defer evaluation.finish();
        return k.normalize(
            self.a,
            try self.reads.primitive(self.a, expression, args, &evaluation.left),
            &evaluation.left,
        );
    }
    fn field(self: *Checker, knowledge: pe.Knowledge, index: usize) Error!pe.Knowledge {
        var evaluation = EvaluationWork.init(&self.left, self.work);
        defer evaluation.finish();
        return self.reads.field(self.a, knowledge, index, &evaluation.left);
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
        if (self.value_facts.get(FactKey.of(visit))) |fact| {
            try self.checkHeight(visit, fact.height);
            frame.checked = fact;
            return frame;
        }
        switch (b.expression) {
            .literal => |v| {
                try require(proof.children.len == 0);
                frame.knowledge = .{ .known = self.before.constants[@intCast(v)] };
            },
            .variable => |v| {
                try require(proof.children.len == 0);
                const bound = try lookup(visit.env, v, self.work);
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
                try data.admission.spend(self.work, op.operands.len);
                frame.args = try self.a.alloc(p.Id, op.operands.len);
                frame.known = try self.a.alloc(pe.Knowledge, op.operands.len);
            },
        }
        return frame;
    }
    fn finishValue(self: *Checker, frame: *ValueFrame) Error!V {
        if (frame.checked) |fact| return fact;
        const visit = frame.visit;
        const b = self.before.values[@intCast(visit.before)];
        const r = self.after.values[@intCast(visit.after)];
        if (b.expression == .primitive) {
            frame.expected.expression.primitive.operands = frame.args;
            frame.knowledge = try self.primitive(b, frame.known);
            frame.total = frame.total and frame.knowledge == .known;
        }
        if (self.out.value_proofs.items[visit.proof_id].folded) {
            try require(frame.total and frame.knowledge == .known and r.expression == .literal);
            try require(try k.literalEqualWithWork(
                frame.knowledge.known,
                self.after.constants[@intCast(r.expression.literal)],
                self.work,
            ));
        } else try require(data.record.equal(ast.Value, frame.expected, r));
        const fact: V = .{
            .knowledge = frame.knowledge,
            .total = frame.total,
            .height = frame.height,
        };
        try self.value_facts.put(self.a, FactKey.of(visit), fact);
        return fact;
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
            if (frame.checked == null and b.expression == .primitive and
                frame.cursor < frame.args.len)
            {
                const index = frame.cursor;
                const child_id = self.out.value_proofs.items[visit.proof_id].children[index];
                try require(child_id < visit.proof_id);
                frame.args[index] = self.out.value_proofs.items[child_id].after;
                const child_visit: Visit = .{
                    .proof_id = child_id,
                    .before = b.expression.primitive.operands[index],
                    .after = frame.args[index],
                    .env = visit.env,
                    .depth = try nextDepth(visit.depth),
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
                parent.height = @max(parent.height, try nextDepth(result.height));
                parent.cursor += 1;
            }
        }
        return result;
    }
    fn checkedValue(
        self: *Checker,
        frame: *TermFrame,
        index: usize,
        before: p.Id,
    ) Error!CheckedValue {
        const visit = frame.visit;
        const proofs = self.out.term_proofs.items[visit.proof_id].values;
        try require(index < proofs.len and proofs[index] < self.out.value_proofs.items.len);
        const id = self.out.value_proofs.items[proofs[index]].after;
        const fact = try self.value(.{
            .proof_id = proofs[index],
            .before = before,
            .after = id,
            .env = visit.env,
            .depth = try nextDepth(visit.depth),
            .parent = self.out.value_proofs.items.len,
        });
        frame.height = @max(frame.height, try nextDepth(fact.height));
        return .{ .id = id, .fact = fact };
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
            .depth = try nextDepth(visit.depth),
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
                    const fact: TermFact = .{ .knowledge = knowledge, .height = frame.height };
                    if (!frame.cached)
                        try self.term_facts.put(self.a, FactKey.of(frame.visit), fact);
                    result = .{ .id = frame.visit.after, .fact = fact };
                    _ = stack.pop();
                },
            }
        }
        return result.?.fact.knowledge;
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
        if (self.term_facts.get(FactKey.of(visit))) |fact| {
            try self.checkHeight(visit, fact.height);
            frame.height = fact.height;
            frame.cached = true;
            return .{ .done = fact.knowledge };
        }
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
        const arguments = if (target != null and self.arguments[proof.callee.?] == null) blk: {
            try data.admission.spend(self.work, v.arguments.len);
            break :blk try self.a.alloc(pe.Knowledge, v.arguments.len);
        } else null;
        for (v.arguments, 0..) |arg, i| {
            const x = try self.checkedValue(frame, i, arg);
            if (target) |f| {
                const justified: pe.Knowledge = if (x.fact.knowledge == .known and !x.fact.total)
                    .dynamic
                else
                    x.fact.knowledge;
                const normalized = try normalize(self.a, justified, &self.left, self.work);
                try require(try k.equalWithWork(self.a, normalized, f.arguments[i], self.work));
                if (arguments) |retained| retained[i] = normalized;
                if (f.arguments[i] == .known) continue;
            }
            try args.append(self.a, x.id);
        }
        if (arguments) |retained| self.arguments[proof.callee.?] = retained;
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
            try data.admission.spend(self.work, @field(v, name).len);
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
            next_env = try extend(self.a, next_env, self.work, .{
                .before = v1,
                .after = v2,
                .knowledge = try self.field(frame.value.fact.knowledge, i),
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
        try data.admission.spend(self.work, v.cases.len);
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
            try k.literalEqualWithWork(
                payload_fact.value.known,
                self.after.constants[@intCast(literal.expression.literal)],
                self.work,
            ));
        const next_env = try extend(self.a, visit.env, self.work, .{
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
        const next_env = try extend(self.a, visit.env, self.work, .{
            .before = left.variable,
            .after = right.variable,
            .knowledge = .dynamic,
        });
        return self.child(frame, frame.cursor, left.body, next_env);
    }
    fn resumeTerm(self: *Checker, frame: *TermFrame, result: CheckedTerm) Error!Action {
        frame.height = @max(frame.height, try nextDepth(result.fact.height));
        const visit = frame.visit;
        const b = self.before.terms[@intCast(visit.before)];
        const r = self.after.terms[@intCast(visit.after)];
        switch (b) {
            .bind => return self.resumeBind(frame, result),
            .conditional => return self.resumeConditional(frame, result),
            .yield_then => {
                frame.expected = .{ .yield_then = result.id };
                frame.knowledge = result.fact.knowledge;
            },
            .unpack_product => {
                frame.expected = .{ .unpack_product = .{
                    .value = frame.value.id,
                    .variables = r.unpack_product.variables,
                    .body = result.id,
                } };
                frame.knowledge = result.fact.knowledge;
            },
            .match_sum => {
                if (self.out.term_proofs.items[visit.proof_id].selected != null) {
                    frame.expected = .{ .bind = .{
                        .variable = r.bind.variable,
                        .value = r.bind.value,
                        .next = result.id,
                    } };
                    frame.knowledge = result.fact.knowledge;
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
            const next_env = try extend(self.a, visit.env, self.work, .{
                .before = b.variable,
                .after = r.variable,
                .knowledge = result.fact.knowledge,
            });
            return self.child(frame, 1, b.next, next_env);
        }
        frame.expected = .{ .bind = .{
            .variable = r.variable,
            .value = frame.first.id,
            .next = result.id,
        } };
        frame.knowledge = result.fact.knowledge;
        return self.finish(frame);
    }
    fn resumeConditional(self: *Checker, frame: *TermFrame, result: CheckedTerm) Error!Action {
        const visit = frame.visit;
        const proof = self.out.term_proofs.items[visit.proof_id];
        const b = self.before.terms[@intCast(visit.before)].conditional;
        if (proof.selected != null) {
            try require(visit.after == result.id);
            return .{ .done = result.fact.knowledge };
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
        const first = frame.first.fact.knowledge;
        if (try k.equalWithWork(self.a, first, result.fact.knowledge, self.work))
            frame.knowledge = first;
        return self.finish(frame);
    }
};

test "specialization evaluator intersection stops before unpaid allocation" {
    const value: pe.Knowledge = .{ .product = .{ .schema = 0, .fields = &.{
        .dynamic, .dynamic,
    } } };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var local: u64 = 10;
    var global: u64 = 2;
    try std.testing.expectError(
        error.SpecializationLimit,
        normalize(failing.allocator(), value, &local, &global),
    );
    try std.testing.expectEqual(@as(u64, 9), local);
    try std.testing.expectEqual(@as(u64, 1), global);
    try std.testing.expect(!failing.has_induced_failure);
    local = 2;
    global = 10;
    try std.testing.expectError(
        error.SpecializationLimit,
        normalize(failing.allocator(), value, &local, &global),
    );
    try std.testing.expectEqual(@as(u64, 1), local);
    try std.testing.expectEqual(@as(u64, 9), global);
    try std.testing.expect(!failing.has_induced_failure);
}
