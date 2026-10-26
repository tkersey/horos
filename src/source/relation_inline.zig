const std = @import("std");
const ast = @import("ast.zig");
const check = @import("check.zig");
const relation = @import("relation.zig");
const Error = relation.Error;
const Id = ast.Id;
const absent = std.math.maxInt(Id);
const Kind = enum { function, term, value, schema };
const Item = struct { kind: Kind, id: Id };

fn flags(ctx: *relation.Context, n: usize) Error![]bool {
    try ctx.spend(n);
    const result = try ctx.a.alloc(bool, n);
    @memset(result, false);
    return result;
}

test "closed pure inlining charges empty authority catalogs" {
    const source = @import("../source.zig");
    for ([_]bool{ false, true }) |handlers| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const entry = try b.declare(&.{}, unit, &.{}, &.{});
        try b.define(entry, try b.pure(try b.constant(void, {})));
        const returned = try b.declare(&.{unit}, unit, &.{}, &.{});
        try b.define(returned, try b.pure(try b.reference(b.parameter(returned, 0))));
        for (0..64) |_| {
            if (handlers) {
                _ = try b.handler(.{
                    .mode = .deep,
                    .input = unit,
                    .answer = unit,
                    .return_function = returned,
                    .clauses = &.{},
                });
            } else {
                _ = try b.resource(unit);
            }
        }
        const module = b.module(entry, unit);
        var left: u64 = 1_000_000;
        try source.admitWithWork(std.testing.allocator, module, &left);
        var ctx: relation.Context = .{
            .a = b.allocator(),
            .before = module,
            .expected = module,
            .policy = .{},
            .left = &left,
        };
        var pure: Pure = .{
            .ctx = &ctx,
            .facts = try check.analyze(ctx.a, module),
            .seen = .{
                try flags(&ctx, module.functions.len), try flags(&ctx, module.terms.len),
                try flags(&ctx, module.values.len),    try flags(&ctx, module.schemas.len),
            },
        };
        left = 63;
        try std.testing.expectError(error.RelationLimit, pure.checkFunction(entry));
        left = 128;
        try pure.checkFunction(entry);
    }
}

fn referenceExpansionModule(b: *@import("../source.zig").Builder, sum: bool) Error!ast.Module {
    const unit = try b.scalar(void);
    const members: [8]Id = @splat(unit);
    const aggregate = try b.schema(if (sum) .{ .sum = &members } else .{ .product = &members });
    const entry = try b.declare(&.{aggregate}, unit, &.{}, &.{});
    const input = try b.reference(b.parameter(entry, 0));
    const returned = try b.pure(try b.constant(void, {}));
    var variables: [members.len]Id = undefined;
    for (&variables) |*variable| variable.* = try b.variable(unit);
    const Case = std.meta.Elem(@FieldType(@FieldType(ast.Term, "match_sum"), "cases"));
    var cases: [members.len]Case = undefined;
    for (&cases, variables) |*case, variable| case.* = .{ .variable = variable, .body = returned };
    const body = try b.term(if (sum) .{ .match_sum = .{
        .value = input,
        .cases = &cases,
    } } else .{ .unpack_product = .{
        .value = input,
        .variables = &variables,
        .body = returned,
    } });
    try b.define(entry, body);
    return b.module(entry, unit);
}

test "closed pure inlining reserves reference expansion before allocation" {
    const source = @import("../source.zig");
    for ([_]bool{ false, true }) |sum| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try referenceExpansionModule(&b, sum);
        var left: u64 = 1_000_000;
        try source.admitWithWork(std.testing.allocator, module, &left);
        var ctx: relation.Context = .{
            .a = b.allocator(),
            .before = module,
            .expected = module,
            .policy = .{},
            .left = &left,
        };
        var pure: Pure = .{
            .ctx = &ctx,
            .facts = try check.analyze(ctx.a, module),
            .seen = .{
                try flags(&ctx, module.functions.len), try flags(&ctx, module.terms.len),
                try flags(&ctx, module.values.len),    try flags(&ctx, module.schemas.len),
            },
        };
        var clone = try Clone.init(&ctx);
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = 0 },
        );
        ctx.a = failing.allocator();
        const root = module.functions[@intCast(module.entry)].body.?;
        left = 0;
        try std.testing.expectError(error.RelationLimit, pure.checkTerm(root));
        left = 1;
        try std.testing.expectError(error.RelationLimit, clone.select(root));
        try std.testing.expect(!failing.has_induced_failure);
        ctx.a = b.allocator();
        left = 1_000;
        try pure.checkTerm(root);
        try clone.select(root);
    }
}

const Pure = struct {
    ctx: *relation.Context,
    facts: check.Facts,
    seen: [4][]bool,
    pending: std.ArrayList(Item) = .empty,

    fn push(self: *Pure, kind: Kind, id: Id) Error!void {
        try self.ctx.spend(1);
        const seen = self.seen[@backingInt(kind)];
        if (id >= seen.len) return error.InvalidRelation;
        if (seen[@intCast(id)]) return;
        seen[@intCast(id)] = true;
        try self.pending.append(self.ctx.a, .{ .kind = kind, .id = id });
    }

    fn run(self: *Pure, function: Id) Error!void {
        try self.push(.function, function);
        while (self.pending.pop()) |item| switch (item.kind) {
            .function => try self.checkFunction(item.id),
            .term => try self.checkTerm(item.id),
            .value => try self.checkValue(item.id),
            .schema => try self.schema(item.id),
        };
    }

    fn checkFunction(self: *Pure, id: Id) Error!void {
        const ctx = self.ctx;
        const f = ctx.before.functions[@intCast(id)];
        if (f.effects.len != 0 or f.regions.len != 0 or f.body == null or
            self.facts.functions[@intCast(id)].items.len != 0)
            return error.UnsupportedRelation;
        for (ctx.policy.protected_functions) |root| {
            try ctx.spend(1);
            if (root == id) return error.UnsupportedRelation;
        }
        for (ctx.before.resources) |resource| {
            try ctx.spend(1);
            for ([_][]const Id{ resource.introducers, resource.eliminators }) |owners| {
                for (owners) |owner| {
                    try ctx.spend(1);
                    if (owner == id) return error.UnsupportedRelation;
                }
            }
        }
        for (ctx.before.handlers) |handler| {
            try ctx.spend(1);
            if (handler.return_function == id) return error.UnsupportedRelation;
            for (handler.clauses) |clause| {
                try ctx.spend(1);
                if (clause.function == id) return error.UnsupportedRelation;
            }
        }
        try self.push(.schema, f.result);
        for (f.parameters) |variable| try self.push(
            .schema,
            ctx.before.variables[@intCast(variable)],
        );
        try self.push(.term, f.body.?);
    }

    fn checkTerm(self: *Pure, id: Id) Error!void {
        const term = self.ctx.before.terms[@intCast(id)];
        switch (term) {
            .value, .bind, .conditional, .fail, .match_sum, .unpack_product, .yield_then => {},
            .call => |call| try self.push(.function, call.function),
            else => return error.UnsupportedRelation,
        }
        var refs: check.References = .{ .allocator = self.ctx.a, .work = self.ctx.left };
        try refs.collect(term);
        for (refs.terms.items) |child| try self.push(.term, child);
        for (refs.values.items) |child| try self.push(.value, child);
        for (refs.bound.items) |variable| try self.push(
            .schema,
            self.ctx.before.variables[@intCast(variable)],
        );
    }

    fn checkValue(self: *Pure, id: Id) Error!void {
        const value = self.ctx.before.values[@intCast(id)];
        try self.push(.schema, value.schema);
        switch (value.expression) {
            .variable, .literal => {},
            .lambda => return error.UnsupportedRelation,
            .primitive => |p| {
                switch (p.opcode) {
                    .computation,
                    .cell_new,
                    .cell_get,
                    .cell_set,
                    .clone_resumption,
                    .package,
                    .unpack,
                    .resource_pack,
                    .resource_unpack,
                    => return error.UnsupportedRelation,
                    else => {},
                }
                for (p.operands) |operand| try self.push(.value, operand);
            },
        }
    }

    fn schema(self: *Pure, id: Id) Error!void {
        switch (self.ctx.before.schemas[@intCast(id)]) {
            .internal => return error.UnsupportedRelation,
            .product, .sum => |members| for (members) |member| try self.push(.schema, member),
            .seq => |member| try self.push(.schema, member),
            .vector => |v| try self.push(.schema, v.element),
            .array => |v| try self.push(.schema, v.element),
            else => {},
        }
    }
};

const Clone = struct {
    ctx: *relation.Context,
    variables: []Id,
    values: []Id,
    terms: []Id,
    selected_terms: []bool,
    selected_values: []bool,
    output_variables: std.ArrayList(Id) = .empty,
    output_values: std.ArrayList(ast.Value) = .empty,
    output_terms: std.ArrayList(ast.Term) = .empty,

    fn init(ctx: *relation.Context) Error!Clone {
        return .{
            .ctx = ctx,
            .variables = try mapping(ctx, ctx.before.variables.len),
            .values = try mapping(ctx, ctx.before.values.len),
            .terms = try mapping(ctx, ctx.before.terms.len),
            .selected_terms = try flags(ctx, ctx.before.terms.len),
            .selected_values = try flags(ctx, ctx.before.values.len),
        };
    }

    fn variable(self: *Clone, id: Id) Error!Id {
        if (self.variables[@intCast(id)] == absent) {
            try self.ctx.spend(1);
            self.variables[@intCast(id)] = @intCast(self.output_variables.items.len);
            try self.output_variables.append(self.ctx.a, self.ctx.before.variables[@intCast(id)]);
        }
        return self.variables[@intCast(id)];
    }

    fn select(self: *Clone, root: Id) Error!void {
        self.selected_terms[@intCast(root)] = true;
        var at = self.ctx.before.terms.len;
        while (at > 0) {
            at -= 1;
            try self.ctx.spend(1);
            if (!self.selected_terms[at]) continue;
            var refs: check.References = .{ .allocator = self.ctx.a, .work = self.ctx.left };
            try refs.collect(self.ctx.before.terms[at]);
            try self.ctx.spend(refs.terms.items.len + refs.values.items.len + refs.bound.items.len);
            for (refs.terms.items) |child| self.selected_terms[@intCast(child)] = true;
            for (refs.values.items) |child| self.selected_values[@intCast(child)] = true;
            for (refs.bound.items) |bound| _ = try self.variable(bound);
        }
        at = self.ctx.before.values.len;
        while (at > 0) {
            at -= 1;
            try self.ctx.spend(1);
            if (!self.selected_values[at]) continue;
            const value = self.ctx.before.values[at];
            if (value.expression == .primitive) {
                try self.ctx.spend(value.expression.primitive.operands.len);
                for (value.expression.primitive.operands) |child|
                    self.selected_values[@intCast(child)] = true;
            }
        }
    }

    fn copyValues(self: *Clone) Error!void {
        for (self.ctx.before.values, 0..) |original, id| {
            try self.ctx.spend(1);
            if (!self.selected_values[id]) continue;
            var value = original;
            switch (value.expression) {
                .variable => |v| value.expression.variable = try self.variable(v),
                .primitive => |p| {
                    value.expression.primitive.operands = try self.mapValues(p.operands);
                },
                .literal => {},
                .lambda => return error.UnsupportedRelation,
            }
            self.values[id] = @intCast(self.output_values.items.len);
            try self.output_values.append(self.ctx.a, value);
        }
    }

    fn mapValues(self: *Clone, ids: []const Id) Error![]const Id {
        try self.ctx.spend(ids.len);
        const result = try self.ctx.a.alloc(Id, ids.len);
        for (ids, result) |id, *out| out.* = self.values[@intCast(id)];
        return result;
    }

    fn copyTerm(self: *Clone, original: ast.Term) Error!ast.Term {
        var term = try mapTerms(self.ctx, original, self.terms);
        switch (term) {
            .value => |id| term.value = self.values[@intCast(id)],
            .fail => |id| term.fail = self.values[@intCast(id)],
            .yield_then => {},
            .bind => |v| term.bind.variable = try self.variable(v.variable),
            .conditional => |v| term.conditional.condition = self.values[@intCast(v.condition)],
            .call => |v| term.call.arguments = try self.mapValues(v.arguments),
            .match_sum => |v| {
                term.match_sum.value = self.values[@intCast(v.value)];
                for (@constCast(term.match_sum.cases)) |*case|
                    case.variable = try self.variable(case.variable);
            },
            .unpack_product => |v| {
                term.unpack_product.value = self.values[@intCast(v.value)];
                try self.ctx.spend(v.variables.len);
                const variables = try self.ctx.a.alloc(Id, v.variables.len);
                for (v.variables, variables) |id, *out| out.* = try self.variable(id);
                term.unpack_product.variables = variables;
            },
            else => return error.UnsupportedRelation,
        }
        return term;
    }

    fn appendTerm(self: *Clone, term: ast.Term) Error!Id {
        try self.ctx.spend(1);
        const id: Id = @intCast(self.output_terms.items.len);
        try self.output_terms.append(self.ctx.a, term);
        return id;
    }
};

fn mapping(ctx: *relation.Context, n: usize) Error![]Id {
    try ctx.spend(n);
    const result = try ctx.a.alloc(Id, n);
    @memset(result, absent);
    return result;
}

fn mapTerms(ctx: *relation.Context, original: ast.Term, map: []const Id) Error!ast.Term {
    var term = original;
    switch (term) {
        .bind => |v| {
            term.bind.value = map[@intCast(v.value)];
            term.bind.next = map[@intCast(v.next)];
        },
        .conditional => |v| {
            term.conditional.when_true = map[@intCast(v.when_true)];
            term.conditional.when_false = map[@intCast(v.when_false)];
        },
        .yield_then => |id| term.yield_then = map[@intCast(id)],
        .match_sum => |v| {
            try ctx.spend(v.cases.len);
            const cases = try ctx.a.dupe(@typeInfo(@TypeOf(v.cases)).pointer.child, v.cases);
            for (cases) |*case| case.body = map[@intCast(case.body)];
            term.match_sum.cases = cases;
        },
        .unpack_product => |v| term.unpack_product.body = map[@intCast(v.body)],
        else => {},
    }
    return term;
}

pub fn apply(ctx: *relation.Context, call_term: u64) Error!void {
    if (call_term >= ctx.before.terms.len) return error.InvalidRelation;
    const term = ctx.before.terms[@intCast(call_term)];
    if (term != .call) return error.InvalidRelation;
    const call = term.call;
    var pure: Pure = .{
        .ctx = ctx,
        .facts = try check.analyzeWithWork(ctx.a, ctx.before, ctx.left),
        .seen = .{
            try flags(ctx, ctx.before.functions.len), try flags(ctx, ctx.before.terms.len),
            try flags(ctx, ctx.before.values.len),    try flags(ctx, ctx.before.schemas.len),
        },
    };
    try pure.run(call.function);
    const function = ctx.before.functions[@intCast(call.function)];
    if (function.parameters.len != call.arguments.len) return error.InvalidRelation;
    var clone = try Clone.init(ctx);
    try ctx.spend(ctx.expected.variables.len);
    try ctx.spend(ctx.expected.values.len);
    try ctx.spend(@intCast(call_term));
    try clone.output_variables.appendSlice(ctx.a, ctx.expected.variables);
    try clone.output_values.appendSlice(ctx.a, ctx.expected.values);
    try clone.output_terms.appendSlice(ctx.a, ctx.expected.terms[0..@intCast(call_term)]);
    for (function.parameters) |parameter| _ = try clone.variable(parameter);
    try clone.select(function.body.?);
    try clone.copyValues();
    for (ctx.before.terms, 0..) |original, id| {
        try ctx.spend(1);
        if (clone.selected_terms[id]) clone.terms[id] = try clone.appendTerm(
            try clone.copyTerm(original),
        );
    }
    var next = clone.terms[@intCast(function.body.?)];
    try ctx.spend(call.arguments.len);
    const arguments = try ctx.a.alloc(Id, call.arguments.len);
    for (call.arguments, arguments) |argument, *out|
        out.* = try clone.appendTerm(.{ .value = argument });
    var at = function.parameters.len;
    while (at > 0) {
        at -= 1;
        next = try clone.appendTerm(.{ .bind = .{
            .variable = clone.variables[@intCast(function.parameters[at])],
            .value = arguments[at],
            .next = next,
        } });
    }
    try finish(&clone, call_term, next);
}

fn finish(clone: *Clone, call_term: Id, next: Id) Error!void {
    const ctx = clone.ctx;
    const shifted = try mapping(ctx, ctx.before.terms.len);
    const delta = clone.output_terms.items.len - @as(usize, @intCast(call_term)) - 1;
    for (shifted, 0..) |*id, index| {
        id.* = if (index < call_term)
            @intCast(index)
        else if (index == call_term)
            next
        else
            @intCast(index + delta);
    }
    for (ctx.expected.terms[@intCast(call_term + 1)..]) |original|
        _ = try clone.appendTerm(try mapTerms(ctx, original, shifted));
    const functions = @constCast(ctx.expected.functions);
    for (functions) |*function| {
        try ctx.spend(1);
        if (function.body) |body| function.body = shifted[@intCast(body)];
    }
    ctx.expected.variables = clone.output_variables.items;
    ctx.expected.values = clone.output_values.items;
    ctx.expected.terms = clone.output_terms.items;
}
