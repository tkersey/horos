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
pub const Error = source.Error || error{
    SpecializationLimit,
    UnsupportedSpecialization,
    InvalidSpecialization,
};
pub const Context = struct {
    core: [32]u8,
    guest: [32]u8,
    observation: [32]u8,
    base_profile: [32]u8,
    admission_profile: [32]u8,
    compiler_policy: [32]u8,
};
pub const Policy = struct {
    work: u64 = 1_000_000,
    keys_per_function: usize = 32,
    depth: usize = 512,
};
pub const Request = struct {
    context: Context,
    function: p.Id,
    arguments: []const Knowledge,
    policy: Policy = .{},
};
pub const ValueProof = struct {
    before: p.Id,
    after: p.Id,
    folded: bool = false,
    children: []const usize = &.{},
};
pub const TermProof = struct {
    before: p.Id,
    after: p.Id,
    values: []const usize = &.{},
    children: []const usize = &.{},
    selected: ?usize = null,
    callee: ?usize = null,
};
pub const FunctionProof = struct {
    before: p.Id,
    after: p.Id,
    arguments: []const Knowledge,
    body: ?usize = null,
};
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
pub fn identity(a: std.mem.Allocator, m: ast.Module, request: Request) Error![32]u8 {
    return identityWithWork(a, m, request, null);
}
pub fn identityWithWork(
    a: std.mem.Allocator,
    m: ast.Module,
    request: Request,
    work: ?*u64,
) Error![32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var writer: data.wire.Writer = .{ .hasher = &digest, .remaining = work };
    try writer.put("horos.source-specialization/1\x00");
    try data.record.write(ast.Module, m, &writer);
    try data.record.writeAlloc(Request, a, request, &writer);
    return digest.finalResult();
}
fn checkRequestEncoding(a: std.mem.Allocator) !void {
    const request: Request = .{
        .context = .{
            .core = @splat(0),
            .guest = @splat(0),
            .observation = @splat(0),
            .base_profile = @splat(0),
            .admission_profile = @splat(0),
            .compiler_policy = @splat(0),
        },
        .function = 7,
        .arguments = &.{
            .dynamic,
            .{ .known = .{ .schema = 5, .bytes = &.{ 0xaa, 0xbb } } },
            .{ .product = .{ .schema = 9, .fields = &.{
                .dynamic,
                .{ .known = .{ .schema = 3, .bytes = &.{} } },
            } } },
            .dynamic,
        },
        .policy = .{ .work = 128, .keys_per_function = 32, .depth = 512 },
    };
    var bytes: [256]u8 = undefined;
    var writer: data.wire.Writer = .{ .output = &bytes };
    try data.record.writeAlloc(Request, a, request, &writer);
    const expected = @as([192]u8, @splat(0)) ++ [_]u8{
        7, 4, 0, 1, 5, 2, 0xaa, 0xbb, 2, 9, 2, 0, 1, 3, 0, 0, 128, 1, 32, 128, 4,
    };
    try std.testing.expectEqualSlices(u8, &expected, bytes[0..writer.position]);
}

test "specialization request encoding preserves field order and allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRequestEncoding, .{});
}

/// A policy limit rejects this candidate; the unchanged source remains usable.
/// No effect is performed and no unchecked partial result is returned.
pub fn specialize(a: std.mem.Allocator, original: ast.Module, requested: Request) Error!Output {
    var out: Output = .{
        .builder = source.Builder.init(a),
        .original = undefined,
        .request = undefined,
        .entry = undefined,
        .key = undefined,
    };
    errdefer out.deinit();
    const storage = out.builder.allocator();
    out.original = try source.own(ast.Module, storage, original);
    out.request = try source.own(Request, storage, requested);
    const m = out.original;
    inline for (.{
        "schemas",
        "constants",
        "effects",
        "handlers",
        "resources",
        "variables",
        "values",
        "terms",
        "functions",
    }) |name| {
        try @field(out.builder, name).appendSlice(storage, @field(m, name));
    }
    out.builder.region_count = m.region_count;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    try retainEmittedConstants(a, &out);
    const checked = try @import("check.zig").analyze(scratch.allocator(), m);
    const schema_facts = try data.admission.schemas(storage, m.schemas);
    if (requested.function >= m.functions.len) return error.InvalidReference;
    const f = m.functions[@intCast(requested.function)];
    if (requested.arguments.len != f.parameters.len) return error.TypeMismatch;
    for (
        requested.arguments,
        f.parameters,
    ) |k, param| try values.validate(storage, m, schema_facts, m.variables[@intCast(param)], k);
    var engine: Engine = .{
        .out = &out,
        .captures = checked.functions,
        .left = requested.policy.work,
        .reads = .{ .module = m, .facts = schema_facts },
    };
    defer engine.reads.deinit(storage);
    const root = try engine.request(
        requested.function,
        out.request.arguments,
    ) orelse return error.UnsupportedSpecialization;
    out.entry = out.functions.items[root].after;
    var cursor: usize = 0;
    while (cursor < out.functions.items.len) : (cursor += 1) try engine.function(cursor);
    out.key = try identity(a, original, requested);
    try validate(a, original, requested, &out);
    return out;
}
fn retainEmittedConstants(a: std.mem.Allocator, out: *Output) Error!void {
    var admitted = try source.lower(a, out.original);
    defer admitted.deinit();
    const storage = out.builder.allocator();
    try out.builder.constants.appendSlice(storage, try source.own(
        []const p.Literal,
        storage,
        admitted.program.constants[out.original.constants.len..],
    ));
}
const Engine = struct {
    out: *Output,
    captures: []const @import("check.zig").Set,
    left: u64,
    reads: values.ReadCache,
    fn a(self: *Engine) std.mem.Allocator {
        return self.out.builder.allocator();
    }
    fn spend(self: *Engine, depth: usize) Error!void {
        if (self.left == 0 or
            depth > self.out.request.policy.depth)
            return error.SpecializationLimit;
        self.left -= 1;
    }
    const SupportedTask = struct { id: p.Id, depth: usize };
    fn supported(self: *Engine, id: p.Id, depth: usize) Error!bool {
        var pending: std.ArrayList(SupportedTask) = .empty;
        defer pending.deinit(self.a());
        try pending.append(self.a(), .{ .id = id, .depth = depth });
        while (pending.pop()) |task| {
            try self.spend(task.depth);
            const next = task.depth + 1;
            switch (self.out.original.terms[@intCast(task.id)]) {
                .value, .perform, .fail => {},
                .call => |v| if (self.captures[@intCast(v.function)].items.len != 0) return false,
                .bind => |v| {
                    try pending.append(self.a(), .{ .id = v.next, .depth = next });
                    try pending.append(self.a(), .{ .id = v.value, .depth = next });
                },
                .conditional => |v| {
                    try pending.append(self.a(), .{ .id = v.when_false, .depth = next });
                    try pending.append(self.a(), .{ .id = v.when_true, .depth = next });
                },
                .yield_then => |v| try pending.append(self.a(), .{ .id = v, .depth = next }),
                .unpack_product => |v| try pending.append(
                    self.a(),
                    .{ .id = v.body, .depth = next },
                ),
                .match_sum => |v| {
                    var i = v.cases.len;
                    while (i > 0) {
                        i -= 1;
                        try pending.append(self.a(), .{ .id = v.cases[i].body, .depth = next });
                    }
                },
                else => return false,
            }
        }
        return true;
    }
    fn request(self: *Engine, id: p.Id, raw_arguments: []const Knowledge) Error!?usize {
        try self.spend(0);
        const arguments = try self.a().alloc(Knowledge, raw_arguments.len);
        for (
            raw_arguments,
            arguments,
        ) |raw, *canonical| canonical.* = try values.normalize(self.a(), raw, &self.left);
        var count: usize = 0;
        for (self.out.functions.items, 0..) |f, i| if (f.before == id) {
            count += 1;
            var same = f.arguments.len == arguments.len;
            if (same) for (f.arguments, arguments) |x, y| {
                if (!try values.equal(self.a(), x, y)) {
                    same = false;
                    break;
                }
            };
            if (same) return i;
        };
        // Changing static recursion becomes an ordinary call to the original
        // function. This bounds compiler search without limiting guest recursion.
        if (count >= self.out.request.policy.keys_per_function or self.captures[
            @intCast(id)
        ].items.len != 0) return null;
        // Resource permissions name function identities. Keep their owners
        // generic rather than cloning code without its nominal authority.
        for (self.out.original.resources) |resource| {
            for ([_][]const p.Id{ resource.introducers, resource.eliminators }) |authorities| {
                for (authorities) |function_id| {
                    try self.spend(0);
                    if (function_id == id) return null;
                }
            }
        }
        const original = self.out.original.functions[@intCast(id)];
        if (original.body == null or !try self.supported(original.body.?, 0)) return null;
        var parameters: std.ArrayList(p.Id) = .empty;
        for (
            original.parameters,
            arguments,
        ) |param, k| if (k != .known) try parameters.append(
            self.a(),
            self.out.original.variables[@intCast(param)],
        );
        const residual = try self.out.builder.declare(
            parameters.items,
            original.result,
            original.effects,
            original.regions,
        );
        const index = self.out.functions.items.len;
        try self.out.functions.append(
            self.a(),
            .{
                .before = id,
                .after = residual,
                .arguments = arguments,
            },
        );
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
    const ValueFrame = struct {
        before: p.Id,
        expression: ast.Value,
        knowledge: Knowledge = .dynamic,
        total: bool = true,
        children: std.ArrayList(usize) = .empty,
        args: []p.Id = &.{},
        known: []Knowledge = &.{},
        cursor: usize = 0,
    };
    fn valueFrame(self: *Engine, id: p.Id, env: Env, depth: usize) Error!ValueFrame {
        try self.spend(depth);
        const before = self.out.original.values[@intCast(id)];
        var frame: ValueFrame = .{ .before = id, .expression = before };
        switch (before.expression) {
            .variable => |v| {
                const bound = try binding(env, v);
                frame.expression.expression = .{ .variable = bound.after };
                frame.knowledge = bound.knowledge;
            },
            .literal => |v| {
                frame.knowledge = .{ .known = self.out.original.constants[@intCast(v)] };
            },
            .lambda => |v| {
                if (self.captures[@intCast(v)].items.len != 0) {
                    return error.UnsupportedSpecialization;
                }
                frame.total = false;
            },
            .primitive => |op| {
                frame.args = try self.a().alloc(p.Id, op.operands.len);
                frame.known = try self.a().alloc(Knowledge, op.operands.len);
            },
        }
        return frame;
    }
    fn finishValue(self: *Engine, frame: *ValueFrame) Error!Value {
        if (frame.expression.expression == .primitive) {
            const before = frame.expression;
            frame.expression.expression.primitive.operands = frame.args;
            frame.knowledge = try values.normalize(self.a(), try self.reads.primitive(
                self.a(),
                before,
                frame.known,
                &self.left,
            ), &self.left);
            frame.total = frame.total and frame.knowledge == .known;
        }
        const folded = frame.total and frame.knowledge == .known;
        const residual = if (folded) try self.out.builder.literal(
            frame.knowledge.known,
        ) else try self.out.builder.value(frame.expression);
        const proof = self.out.value_proofs.items.len;
        try self.out.value_proofs.append(self.a(), .{
            .before = frame.before,
            .after = residual,
            .folded = folded,
            .children = frame.children.items,
        });
        return .{
            .id = residual,
            .knowledge = frame.knowledge,
            .total = frame.total,
            .proof = proof,
        };
    }
    fn value(self: *Engine, id: p.Id, env: Env, depth: usize) Error!Value {
        var pending: std.ArrayList(ValueFrame) = .empty;
        defer pending.deinit(self.a());
        try pending.append(self.a(), try self.valueFrame(id, env, depth));
        while (pending.items.len > 0) {
            const frame = &pending.items[pending.items.len - 1];
            if (frame.expression.expression == .primitive and frame.cursor < frame.args.len) {
                const operand = frame.expression.expression.primitive.operands[frame.cursor];
                const child = try self.valueFrame(operand, env, depth + pending.items.len);
                try pending.append(self.a(), child);
                continue;
            }
            const result = try self.finishValue(frame);
            _ = pending.pop();
            if (pending.items.len == 0) return result;
            const parent = &pending.items[pending.items.len - 1];
            parent.args[parent.cursor] = result.id;
            parent.known[parent.cursor] = result.knowledge;
            parent.total = parent.total and result.total;
            parent.cursor += 1;
            try parent.children.append(self.a(), result.proof);
        }
        unreachable;
    }
    const TermInput = struct { id: p.Id, env: Env, depth: usize };
    const Case = std.meta.Elem(@FieldType(@FieldType(ast.Term, "match_sum"), "cases"));
    const TermFrame = struct {
        input: TermInput,
        original: ast.Term,
        residual: ast.Term,
        phase: usize = 0,
        vp: std.ArrayList(usize) = .empty,
        tp: std.ArrayList(usize) = .empty,
        knowledge: Knowledge = .dynamic,
        selected: ?usize = null,
        callee: ?usize = null,
        alias: ?p.Id = null,
        first: Term = undefined,
        condition: Value = undefined,
        variable: p.Id = undefined,
        payload: Knowledge = undefined,
        cases: []Case = &.{},
    };
    fn termFrame(self: *Engine, input: TermInput) Error!TermFrame {
        try self.spend(input.depth);
        const original = self.out.original.terms[@intCast(input.id)];
        return .{ .input = input, .original = original, .residual = original };
    }
    fn childInput(frame: *const TermFrame, id: p.Id, env: Env) TermInput {
        return .{ .id = id, .env = env, .depth = frame.input.depth + 1 };
    }
    fn term(self: *Engine, id: p.Id, env: Env, depth: usize) Error!Term {
        var pending: std.ArrayList(TermFrame) = .empty;
        defer pending.deinit(self.a());
        try pending.append(self.a(), try self.termFrame(.{ .id = id, .env = env, .depth = depth }));
        var result: Term = .{ .id = 0, .proof = 0 };
        while (pending.items.len > 0) {
            const frame = &pending.items[pending.items.len - 1];
            if (try self.stepTerm(frame, result)) |child| {
                try pending.append(self.a(), try self.termFrame(child));
            } else {
                result = try self.finishTerm(frame);
                _ = pending.pop();
            }
        }
        return result;
    }
    fn finishTerm(self: *Engine, frame: *TermFrame) Error!Term {
        const after = frame.alias orelse try self.out.builder.term(frame.residual);
        const proof = self.out.term_proofs.items.len;
        try self.out.term_proofs.append(self.a(), .{
            .before = frame.input.id,
            .after = after,
            .values = frame.vp.items,
            .children = frame.tp.items,
            .selected = frame.selected,
            .callee = frame.callee,
        });
        return .{ .id = after, .knowledge = frame.knowledge, .proof = proof };
    }
    fn termValue(self: *Engine, frame: *TermFrame, id: p.Id) Error!Value {
        const result = try self.value(id, frame.input.env, frame.input.depth + 1);
        try frame.vp.append(self.a(), result.proof);
        return result;
    }
    fn stepTerm(self: *Engine, frame: *TermFrame, result: Term) Error!?TermInput {
        switch (frame.original) {
            .value, .fail => |v| {
                const x = try self.termValue(frame, v);
                frame.residual = if (frame.original == .value)
                    .{ .value = x.id }
                else
                    .{ .fail = x.id };
                if (frame.original == .value) frame.knowledge = x.knowledge;
            },
            .bind => return self.stepBind(frame, result),
            .conditional => return self.stepConditional(frame, result),
            .call => try self.stepCall(frame),
            .perform => try self.stepPerform(frame),
            .yield_then => |v| {
                if (frame.phase == 0) {
                    frame.phase = 1;
                    return childInput(frame, v, frame.input.env);
                }
                try frame.tp.append(self.a(), result.proof);
                frame.residual = .{ .yield_then = result.id };
                frame.knowledge = result.knowledge;
            },
            .unpack_product => return self.stepUnpack(frame, result),
            .match_sum => return self.stepMatch(frame, result),
            else => return error.UnsupportedSpecialization,
        }
        return null;
    }
    fn stepBind(self: *Engine, frame: *TermFrame, result: Term) Error!?TermInput {
        const v = frame.original.bind;
        if (frame.phase == 0) {
            frame.phase = 1;
            return childInput(frame, v.value, frame.input.env);
        }
        try frame.tp.append(self.a(), result.proof);
        if (frame.phase == 1) {
            frame.first = result;
            frame.variable = try self.out.builder.variable(
                self.out.original.variables[@intCast(v.variable)],
            );
            const env = try extend(self.a(), frame.input.env, .{
                .before = v.variable,
                .after = frame.variable,
                .knowledge = result.knowledge,
            });
            frame.phase = 2;
            return childInput(frame, v.next, env);
        }
        frame.residual = .{ .bind = .{
            .variable = frame.variable,
            .value = frame.first.id,
            .next = result.id,
        } };
        frame.knowledge = result.knowledge;
        return null;
    }
    fn stepConditional(self: *Engine, frame: *TermFrame, result: Term) Error!?TermInput {
        const v = frame.original.conditional;
        if (frame.phase == 0) {
            frame.condition = try self.termValue(frame, v.condition);
            if (frame.condition.total and frame.condition.knowledge == .known) {
                frame.selected = if (frame.condition.knowledge.known.bytes[0] == 1) 0 else 1;
            }
            frame.phase = 1;
            return childInput(
                frame,
                if (frame.selected == 1) v.when_false else v.when_true,
                frame.input.env,
            );
        }
        try frame.tp.append(self.a(), result.proof);
        if (frame.selected != null) {
            frame.alias = result.id;
            frame.knowledge = result.knowledge;
            return null;
        }
        if (frame.phase == 1) {
            frame.first = result;
            frame.phase = 2;
            return childInput(frame, v.when_false, frame.input.env);
        }
        frame.residual = .{ .conditional = .{
            .condition = frame.condition.id,
            .when_true = frame.first.id,
            .when_false = result.id,
        } };
        if (try values.equal(self.a(), frame.first.knowledge, result.knowledge)) {
            frame.knowledge = frame.first.knowledge;
        }
        return null;
    }
    fn stepCall(self: *Engine, frame: *TermFrame) Error!void {
        const v = frame.original.call;
        const args = try self.a().alloc(p.Id, v.arguments.len);
        const ks = try self.a().alloc(Knowledge, v.arguments.len);
        for (v.arguments, args, ks) |arg, *to, *known| {
            const x = try self.termValue(frame, arg);
            to.* = x.id;
            known.* = if (x.knowledge == .known and !x.total) .dynamic else x.knowledge;
        }
        frame.callee = try self.request(v.function, ks);
        if (frame.callee) |index| {
            var dynamic: std.ArrayList(p.Id) = .empty;
            for (args, self.out.functions.items[index].arguments) |arg, known| {
                if (known != .known) try dynamic.append(self.a(), arg);
            }
            frame.residual = .{ .call = .{
                .function = self.out.functions.items[index].after,
                .arguments = dynamic.items,
            } };
        } else frame.residual = .{ .call = .{ .function = v.function, .arguments = args } };
    }
    fn stepPerform(self: *Engine, frame: *TermFrame) Error!void {
        const v = frame.original.perform;
        var operation = v;
        operation.payload = (try self.termValue(frame, v.payload)).id;
        if (v.capability) |cap| operation.capability = (try self.termValue(frame, cap)).id;
        inline for (.{ "bodies", "use_site_capabilities" }) |name| {
            const args = try self.a().alloc(p.Id, @field(v, name).len);
            for (@field(v, name), args) |arg, *to| to.* = (try self.termValue(frame, arg)).id;
            @field(operation, name) = args;
        }
        frame.residual = .{ .perform = operation };
    }
    fn stepUnpack(self: *Engine, frame: *TermFrame, result: Term) Error!?TermInput {
        const v = frame.original.unpack_product;
        if (frame.phase == 0) {
            const x = try self.termValue(frame, v.value);
            const vars = try self.a().alloc(p.Id, v.variables.len);
            var env = frame.input.env;
            for (v.variables, vars, 0..) |before, *after, i| {
                after.* = try self.out.builder.variable(
                    self.out.original.variables[@intCast(before)],
                );
                env = try extend(self.a(), env, .{
                    .before = before,
                    .after = after.*,
                    .knowledge = try self.reads.field(
                        self.a(),
                        x.knowledge,
                        i,
                        &self.left,
                    ),
                });
            }
            frame.residual = .{ .unpack_product = .{
                .value = x.id,
                .variables = vars,
                .body = undefined,
            } };
            frame.phase = 1;
            return childInput(frame, v.body, env);
        }
        try frame.tp.append(self.a(), result.proof);
        frame.residual.unpack_product.body = result.id;
        frame.knowledge = result.knowledge;
        return null;
    }
    fn stepMatch(self: *Engine, frame: *TermFrame, result: Term) Error!?TermInput {
        const v = frame.original.match_sum;
        if (frame.phase == 0) {
            frame.condition = try self.termValue(frame, v.value);
            if (frame.condition.total and frame.condition.knowledge == .known) {
                var reader: data.wire.Reader = .{ .input = frame.condition.knowledge.known.bytes };
                frame.selected = try reader.count();
            } else frame.cases = try self.a().alloc(Case, v.cases.len);
        } else {
            try frame.tp.append(self.a(), result.proof);
            if (frame.selected != null) {
                frame.knowledge = result.knowledge;
                frame.residual = .{ .bind = .{
                    .variable = frame.variable,
                    .value = try self.out.builder.pure(
                        try self.out.builder.literal(frame.payload.known),
                    ),
                    .next = result.id,
                } };
                return null;
            }
            frame.cases[frame.phase - 1] = .{ .variable = frame.variable, .body = result.id };
        }
        if (frame.selected == null and frame.phase == v.cases.len) {
            frame.residual = .{ .match_sum = .{
                .value = frame.condition.id,
                .cases = frame.cases,
            } };
            return null;
        }
        const branch = v.cases[frame.selected orelse frame.phase];
        const schema = self.out.original.variables[@intCast(branch.variable)];
        frame.payload = if (frame.selected != null)
            (try values.payload(frame.condition.knowledge, schema)).value
        else
            .dynamic;
        frame.variable = try self.out.builder.variable(schema);
        const env = try extend(self.a(), frame.input.env, .{
            .before = branch.variable,
            .after = frame.variable,
            .knowledge = frame.payload,
        });
        frame.phase += 1;
        return childInput(frame, branch.body, env);
    }
};

pub const validate = @import("specialize_validate.zig").validate;

pub fn requestEqual(a: std.mem.Allocator, lhs: Request, rhs: Request) Error!bool {
    return data.record.equalAlloc(Request, a, lhs, rhs);
}

pub fn requestEqualWithWork(
    a: std.mem.Allocator,
    lhs: Request,
    rhs: Request,
    work: ?*u64,
) Error!bool {
    try data.admission.spend(work, 1);
    if (lhs.function != rhs.function or lhs.arguments.len != rhs.arguments.len or
        !data.record.equal(Context, lhs.context, rhs.context) or
        !data.record.equal(Policy, lhs.policy, rhs.policy)) return false;
    for (lhs.arguments, rhs.arguments) |left, right| {
        if (!try values.equalWithWork(a, left, right, work)) return false;
    }
    return true;
}

test "specialization traverses deep value and term derivations" {
    const a = std.testing.allocator;
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const unit = try builder.scalar(void);
    var value_id = try builder.constant(void, {});
    for (0..1024) |_| value_id = try builder.primitive(unit, .move, &.{value_id}, 0);
    var term_id = try builder.pure(value_id);
    for (0..1024) |_| term_id = try builder.term(.{ .yield_then = term_id });
    const function_id = try builder.declare(&.{}, unit, &.{}, &.{});
    try builder.define(function_id, term_id);
    const request: Request = .{
        .context = std.mem.zeroes(Context),
        .function = function_id,
        .arguments = &.{},
        .policy = .{ .depth = 4096 },
    };
    var result = try specialize(a, builder.module(function_id, unit), request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1025), result.term_proofs.items.len);
    try std.testing.expectEqual(@as(usize, 1025), result.value_proofs.items.len);
    for (result.value_proofs.items) |proof| try std.testing.expect(proof.folded);
    var limited = request;
    limited.policy.depth = 1024;
    try std.testing.expectError(
        error.SpecializationLimit,
        specialize(a, builder.module(function_id, unit), limited),
    );
}
