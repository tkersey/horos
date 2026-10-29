// Copyright (c) 2026 Boundary contributors. MIT license.
//! Source scopes and result types, including mutually recursive lexical captures.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ast = @import("ast.zig");
const reference_roles = @import("reference_roles.zig");
const Error = @import("../source.zig").Error;
pub const Set = std.ArrayList(p.Id);
const compact = data.analysis_sets;
/// Analysis storage is owned by the caller's arena. Only genuine function
/// captures are enumerated; term/value sets remain shared roots.
pub const Facts = struct {
    work: ?*u64 = null,
    sets: *compact.Pool,
    values: []compact.Root,
    terms: []compact.Root,
    functions: []Set,
    results: []?p.Id,
};

fn roots(allocator: std.mem.Allocator, length: usize) Error![]compact.Root {
    const result = try allocator.alloc(compact.Root, length);
    @memset(result, compact.empty);
    return result;
}

pub fn add(allocator: std.mem.Allocator, target: *Set, id: p.Id) Error!bool {
    if (std.mem.indexOfScalar(p.Id, target.items, id) != null) return false;
    try target.append(allocator, id);
    return true;
}
pub fn merge(
    allocator: std.mem.Allocator,
    target: *Set,
    source: []const p.Id,
    excluded: []const p.Id,
) Error!bool {
    var changed = false;
    for (source) |id| if (std.mem.indexOfScalar(p.Id, excluded, id) == null) {
        changed = try add(allocator, target, id) or changed;
    };
    return changed;
}
fn sets(allocator: std.mem.Allocator, length: usize) Error![]Set {
    const result = try allocator.alloc(Set, length);
    for (result) |*set| set.* = .empty;
    return result;
}
fn computation(source: ast.Module, value_id: p.Id) Error!p.ComputationType {
    if (value_id >= source.values.len) return error.InvalidReference;
    const schema = try data.admission.schemaAt(
        source.schemas,
        source.values[@intCast(value_id)].schema,
    );
    if (schema != .internal or schema.internal != .computation) return error.TypeMismatch;
    return schema.internal.computation;
}
fn resumption(source: ast.Module, value_id: p.Id) Error!p.ResumptionType {
    if (value_id >= source.values.len) return error.InvalidReference;
    const schema = try data.admission.schemaAt(
        source.schemas,
        source.values[@intCast(value_id)].schema,
    );
    if (schema != .internal or schema.internal != .resumption) return error.TypeMismatch;
    return schema.internal.resumption;
}
fn compatible(left: ?p.Id, right: ?p.Id) Error!?p.Id {
    if (left != null and right != null and left.? != right.?) return error.TypeMismatch;
    return left orelse right;
}

pub fn analyze(allocator: std.mem.Allocator, source: ast.Module) Error!Facts {
    return analyzeDiagnosed(allocator, source, null);
}

pub fn analyzeWithWork(
    allocator: std.mem.Allocator,
    source: ast.Module,
    work: ?*u64,
) Error!Facts {
    return analyzeComponentWithWork(allocator, source, &.{}, null, work);
}

pub fn analyzeDiagnosed(
    allocator: std.mem.Allocator,
    source: ast.Module,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
) Error!Facts {
    return analyzeComponent(allocator, source, &.{}, diagnostic);
}

pub fn analyzeComponent(
    allocator: std.mem.Allocator,
    source: ast.Module,
    imports: []const p.Id,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
) Error!Facts {
    return analyzeComponentWithWork(allocator, source, imports, diagnostic, null);
}

pub fn analyzeComponentWithWork(
    allocator: std.mem.Allocator,
    source: ast.Module,
    imports: []const p.Id,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
    work: ?*u64,
) Error!Facts {
    try sourceWork(source, work);
    for (imports, 0..) |id, at| {
        try data.admission.spend(work, at);
        if (id >= source.functions.len or std.mem.indexOfScalar(
            p.Id,
            imports[0..at],
            id,
        ) != null) return error.InvalidReference;
        if (source.functions[@intCast(id)].body != null) return error.InvalidSource;
    }
    if (source.entry >= source.functions.len) return error.InvalidReference;
    _ = try data.admission.schemasWithWork(allocator, source.schemas, work);
    try declarationSchemas(source, diagnostic);
    const pool = try allocator.create(compact.Pool);
    pool.* = .{ .allocator = allocator, .limit = source.variables.len, .work = work };
    const function_roots = try roots(allocator, source.functions.len);
    const facts: Facts = .{
        .work = work,
        .sets = pool,
        .values = try roots(allocator, source.values.len),
        .terms = try roots(allocator, source.terms.len),
        .functions = try sets(allocator, source.functions.len),
        .results = try allocator.alloc(?p.Id, source.terms.len),
    };
    @memset(facts.results, null);
    try checkValues(source, diagnostic);
    const term_references = try checkTerms(allocator, source, facts, diagnostic);
    try checkFunctions(source, imports, facts, diagnostic);
    try deriveCaptures(allocator, source, facts, term_references, function_roots);
    if (facts.functions[@intCast(source.entry)].items.len != 0) {
        if (diagnostic) |d| {
            d.function = source.entry;
            d.term = source.functions[@intCast(source.entry)].body;
            d.variable = facts.functions[@intCast(source.entry)].items[0];
        }
        return error.UnboundVariable;
    }
    for (source.handlers) |handler| {
        try checkHandlerCapture(source, facts, handler.return_function, diagnostic);
        for (handler.clauses) |clause| try checkHandlerCapture(
            source,
            facts,
            clause.function,
            diagnostic,
        );
    }
    if (diagnostic) |d| {
        d.function = null;
        d.term = null;
        d.value = null;
        d.variable = null;
    }
    return facts;
}

fn sourceWork(source: ast.Module, work: ?*u64) Error!void {
    inline for (.{
        "schemas",   "constants", "effects", "handlers",  "resources",
        "variables", "values",    "terms",   "functions",
    }) |field| try data.admission.spend(work, @field(source, field).len);
    for (source.effects) |effect| try data.admission.spend(work, effect.bodies.len);
    for (source.handlers) |handler| {
        try data.admission.spend(work, handler.state.len);
        try data.admission.spend(work, handler.clauses.len);
    }
    for (source.values) |value| if (value.expression == .primitive) {
        try data.admission.spend(work, value.expression.primitive.operands.len);
    };
}

fn valueVariables(source: ast.Module, facts: Facts, function_roots: []compact.Root) Error!bool {
    const pool = facts.sets;
    var changed = false;
    for (source.values, 0..) |value, id| {
        try data.admission.spend(facts.work, 1);
        switch (value.expression) {
            .variable => |variable| {
                const next = try pool.insert(facts.values[id], variable);
                changed = next != facts.values[id] or changed;
                facts.values[id] = next;
            },
            .literal => {},
            .primitive => |primitive| for (primitive.operands) |operand| {
                try data.admission.spend(facts.work, 1);
                changed = try pool.merge(
                    &facts.values[id],
                    facts.values[@intCast(operand)],
                    &.{},
                ) or changed;
            },
            .lambda => |function| {
                changed = try pool.merge(
                    &facts.values[id],
                    function_roots[@intCast(function)],
                    &.{},
                ) or changed;
            },
        }
    }
    return changed;
}

fn termVariables(
    source: ast.Module,
    facts: Facts,
    references: []const References,
    function_roots: []compact.Root,
) Error!bool {
    const pool = facts.sets;
    var changed = false;
    for (source.terms, 0..) |term, id| {
        try data.admission.spend(facts.work, 1);
        const refs = references[id];
        for (refs.values.items) |value_id| {
            try data.admission.spend(facts.work, 1);
            changed = try pool.merge(
                &facts.terms[id],
                facts.values[@intCast(value_id)],
                &.{},
            ) or changed;
        }
        switch (term) {
            .bind => |bind| {
                changed = try pool.merge(
                    &facts.terms[id],
                    facts.terms[@intCast(bind.value)],
                    &.{},
                ) or changed;
                changed = try pool.merge(
                    &facts.terms[id],
                    facts.terms[@intCast(bind.next)],
                    &.{bind.variable},
                ) or changed;
            },
            .match_sum => |match| for (match.cases) |case| {
                try data.admission.spend(facts.work, 1);
                changed = try pool.merge(
                    &facts.terms[id],
                    facts.terms[@intCast(case.body)],
                    &.{case.variable},
                ) or changed;
            },
            .unpack_product => |unpack| {
                changed = try pool.merge(
                    &facts.terms[id],
                    facts.terms[@intCast(unpack.body)],
                    unpack.variables,
                ) or changed;
            },
            else => for (refs.terms.items) |term_id| {
                try data.admission.spend(facts.work, 1);
                changed = try pool.merge(
                    &facts.terms[id],
                    facts.terms[@intCast(term_id)],
                    &.{},
                ) or changed;
            },
        }
        if (term == .call) {
            changed = try pool.merge(
                &facts.terms[id],
                function_roots[@intCast(term.call.function)],
                &.{},
            ) or changed;
        }
    }
    return changed;
}

fn declarationSchemas(
    source: ast.Module,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
) Error!void {
    _ = try data.admission.schemaAt(source.schemas, source.failure);
    for (source.variables) |schema| _ = try data.admission.schemaAt(source.schemas, schema);
    for (source.constants) |constant| _ = try data.admission.schemaAt(
        source.schemas,
        constant.schema,
    );
    for (source.resources) |resource| _ = try data.admission.schemaAt(
        source.schemas,
        resource.representation,
    );
    for (source.effects) |effect| {
        _ = try data.admission.schemaAt(source.schemas, effect.payload);
        _ = try data.admission.schemaAt(source.schemas, effect.result);
        for (effect.bodies) |schema| _ = try data.admission.schemaAt(source.schemas, schema);
    }
    for (source.handlers) |handler| {
        _ = try data.admission.schemaAt(source.schemas, handler.input);
        _ = try data.admission.schemaAt(source.schemas, handler.answer);
        for (handler.state) |schema| _ = try data.admission.schemaAt(source.schemas, schema);
        for (handler.clauses) |clause| _ = try data.admission.schemaAt(
            source.schemas,
            clause.resumption,
        );
    }
    for (source.functions, 0..) |function, id| {
        if (diagnostic) |d| {
            d.function = id;
            d.term = function.body;
        }
        _ = try data.admission.schemaAt(source.schemas, function.result);
    }
    if (diagnostic) |d| {
        d.function = null;
        d.term = null;
    }
}

fn checkHandlerCapture(
    source: ast.Module,
    facts: Facts,
    function: p.Id,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
) Error!void {
    if (diagnostic) |d| {
        d.function = function;
        d.term = if (function < source.functions.len) source.functions[
            @intCast(function)
        ].body else null;
        d.variable = null;
    }
    if (function >= source.functions.len) return error.UnboundVariable;
    const free = facts.functions[@intCast(function)].items;
    if (free.len != 0) {
        if (diagnostic) |d| d.variable = free[0];
        return error.UnboundVariable;
    }
}

pub const References = struct {
    work: ?*u64 = null,
    allocator: std.mem.Allocator,
    values: Set = .empty,
    terms: Set = .empty,
    bound: Set = .empty,
    pub const VisitError = Error;
    pub fn reference(
        self: *References,
        comptime role: reference_roles.Role,
        comptime cardinality: reference_roles.Cardinality,
        value: anytype,
    ) Error!void {
        try data.admission.spend(self.work, if (cardinality == .list) value.len else 1);
        if (comptime role == .match_case) {
            for (value) |case| try reference_roles.visitMatchCase(case, self);
            return;
        }
        const set = switch (role) {
            .value => &self.values,
            .term => &self.terms,
            .bound => &self.bound,
            .function, .effect, .handler, .region, .nonreference => return,
            .match_case => unreachable,
        };
        switch (cardinality) {
            .one => try set.append(self.allocator, value),
            .list => try set.appendSlice(self.allocator, value),
            .optional => if (value) |present| try set.append(self.allocator, present),
        }
    }
    pub fn collect(self: *References, term: ast.Term) Error!void {
        return reference_roles.visitTerm(term, self);
    }
};

fn checkValues(source: ast.Module, diagnostic: ?*@import("diagnostic.zig").Diagnostic) Error!void {
    for (source.values, 0..) |value, id| {
        if (diagnostic) |d| {
            d.value = id;
            d.variable = if (value.expression == .variable) value.expression.variable else null;
        }
        _ = try data.admission.schemaAt(source.schemas, value.schema);
        switch (value.expression) {
            .variable => |variable| if (variable >= source.variables.len or source.variables[
                @intCast(variable)
            ] != value.schema) return error.TypeMismatch,
            .literal => |literal| if (literal >= source.constants.len or source.constants[
                @intCast(literal)
            ].schema != value.schema) return error.TypeMismatch,
            .primitive => |primitive| for (primitive.operands) |operand| {
                if (operand >= id) return error.InvalidSource;
            },
            .lambda => |function| {
                if (function >= source.functions.len) return error.InvalidReference;
                _ = try computation(source, id);
            },
        }
    }
    if (diagnostic) |d| {
        d.value = null;
        d.variable = null;
    }
}

pub fn selectUnit(
    schemas: []const p.Schema,
    constants: []const p.Literal,
    work: ?*u64,
) Error!?struct { schema: p.Id, constant: ?p.Id } {
    for (constants, 0..) |literal, id| {
        try data.admission.spend(work, 1);
        if (literal.schema >= schemas.len) return error.InvalidSchema;
        if (schemas[@intCast(literal.schema)] == .unit)
            return .{ .schema = literal.schema, .constant = id };
    }
    for (schemas, 0..) |schema, id| {
        try data.admission.spend(work, 1);
        if (schema == .unit) return .{ .schema = id, .constant = null };
    }
    return null;
}

fn checkTerms(
    allocator: std.mem.Allocator,
    source: ast.Module,
    facts: Facts,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
) Error![]References {
    const selected = try selectUnit(source.schemas, source.constants, facts.work);
    const unit = if (selected) |literal| literal.schema else null;
    const term_references = try allocator.alloc(References, source.terms.len);
    for (source.terms, 0..) |term, id| {
        if (diagnostic) |d| d.term = id;
        const references = &term_references[id];
        references.* = .{ .allocator = allocator, .work = facts.work };
        try references.collect(term);
        for (references.values.items) |value_id|
            if (value_id >= source.values.len)
                return error.InvalidReference;
        for (references.terms.items) |term_id| if (term_id >= id) return error.InvalidSource;
        for (references.bound.items) |variable|
            if (variable >= source.variables.len)
                return error.InvalidReference;
        facts.results[id] = termResult(source, facts, term, unit) catch |err| {
            if (term == .bind and err == error.TypeMismatch) answerDiagnostic(
                source,
                term.bind.value,
                source.variables[@intCast(term.bind.variable)],
                facts.results[@intCast(term.bind.value)],
                diagnostic,
            );
            return err;
        };
    }
    return term_references;
}

fn termResult(source: ast.Module, facts: Facts, term: ast.Term, unit: ?p.Id) Error!?p.Id {
    return switch (term) {
        .value => |value_id| source.values[@intCast(value_id)].schema,
        .bind => |bind| try bindingResult(source, facts, bind),
        .conditional => |conditional| blk: {
            if (source.schemas[
                @intCast(source.values[
                    @intCast(conditional.condition)
                ].schema)
            ] != .boolean) return error.TypeMismatch;
            break :blk try compatible(
                facts.results[@intCast(conditional.when_true)],
                facts.results[@intCast(conditional.when_false)],
            );
        },
        .call => |call| blk: {
            if (call.function >= source.functions.len) return error.InvalidReference;
            break :blk source.functions[@intCast(call.function)].result;
        },
        .apply => |apply| (try computation(source, apply.computation)).result,
        .perform => |perform| blk: {
            if (perform.effect >= source.effects.len) return error.InvalidReference;
            break :blk source.effects[@intCast(perform.effect)].result;
        },
        .handle => |handle| blk: {
            if (handle.handler >= source.handlers.len) return error.InvalidReference;
            break :blk source.handlers[@intCast(handle.handler)].answer;
        },
        .resume_value => |resuming| (try resumption(source, resuming.resumption)).answer,
        .resume_with => |resuming| blk: {
            if (resuming.handler >= source.handlers.len) return error.InvalidReference;
            break :blk source.handlers[@intCast(resuming.handler)].answer;
        },
        .resume_computation => |resuming| (try resumption(source, resuming.resumption)).answer,
        .protect => |protection| (try computation(source, protection.body)).result,
        .with_region => |region| (try computation(source, region.body)).result,
        .dispose => unit orelse return error.TypeMismatch,
        .fail => |value| blk: {
            if (source.values[
                @intCast(value)
            ].schema != source.failure) return error.TypeMismatch;
            break :blk null;
        },
        .yield_then => |next| facts.results[@intCast(next)],
        .match_sum => |match| try matchResult(source, facts, match),
        .unpack_product => |unpack| try unpackResult(source, facts, unpack),
    };
}

fn bindingResult(source: ast.Module, facts: Facts, bind: @FieldType(ast.Term, "bind")) Error!?p.Id {
    _ = try compatible(
        facts.results[@intCast(bind.value)],
        source.variables[@intCast(bind.variable)],
    );
    return if (facts.results[
        @intCast(bind.value)
    ] == null) null else facts.results[
        @intCast(bind.next)
    ];
}

fn matchResult(
    source: ast.Module,
    facts: Facts,
    match: @FieldType(ast.Term, "match_sum"),
) Error!?p.Id {
    const shape = source.schemas[@intCast(source.values[@intCast(match.value)].schema)];
    if (shape != .sum or shape.sum.len != match.cases.len) return error.TypeMismatch;
    var result: ?p.Id = null;
    for (match.cases, shape.sum) |case, schema| {
        if (source.variables[
            @intCast(case.variable)
        ] != schema) return error.TypeMismatch;
        result = try compatible(result, facts.results[@intCast(case.body)]);
    }
    return result;
}

fn unpackResult(
    source: ast.Module,
    facts: Facts,
    unpack: @FieldType(ast.Term, "unpack_product"),
) Error!?p.Id {
    const shape = source.schemas[
        @intCast(source.values[
            @intCast(unpack.value)
        ].schema)
    ];
    if (shape != .product or
        shape.product.len != unpack.variables.len)
        return error.TypeMismatch;
    for (unpack.variables, shape.product, 0..) |variable, schema, index| {
        try data.admission.spend(facts.work, index);
        if (std.mem.indexOfScalar(p.Id, unpack.variables[0..index], variable) != null)
            return error.InvalidSource;
        if (source.variables[@intCast(variable)] != schema) return error.TypeMismatch;
    }
    return facts.results[@intCast(unpack.body)];
}

fn checkFunctions(
    source: ast.Module,
    imports: []const p.Id,
    facts: Facts,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
) Error!void {
    for (source.functions, 0..) |function, id| {
        if (diagnostic) |d| {
            d.function = id;
            d.term = function.body;
        }
        if (function.body == null) try data.admission.spend(facts.work, imports.len);
        if (function.body == null and std.mem.indexOfScalar(
            p.Id,
            imports,
            id,
        ) == null) return error.UndefinedFunction;
        if (function.body) |body| if (body >= source.terms.len) return error.InvalidReference;
        for (function.parameters, 0..) |variable, index| {
            try data.admission.spend(facts.work, index + 1);
            if (variable >= source.variables.len or std.mem.indexOfScalar(
                p.Id,
                function.parameters[0..index],
                variable,
            ) != null) return error.InvalidSource;
        }
        if (function.body) |body| _ = compatible(
            facts.results[@intCast(body)],
            function.result,
        ) catch |err| {
            answerDiagnostic(
                source,
                body,
                function.result,
                facts.results[@intCast(body)],
                diagnostic,
            );
            return err;
        };
    }
}

fn answerDiagnostic(
    source: ast.Module,
    root: p.Id,
    expected: p.Id,
    actual: ?p.Id,
    diagnostic: ?*@import("diagnostic.zig").Diagnostic,
) void {
    const d = diagnostic orelse return;
    var cursor = root;
    for (0..source.terms.len) |_| {
        const term = source.terms[@intCast(cursor)];
        const next = switch (term) {
            .bind => |bind| bind.next,
            .yield_then => |body| body,
            .resume_value, .resume_with, .resume_computation => {
                d.continuation = .{ .dimension = .answer, .expected = expected, .actual = actual };
                d.term = cursor;
                return;
            },
            else => return,
        };
        if (next >= cursor) return;
        cursor = next;
    }
}

fn deriveCaptures(
    allocator: std.mem.Allocator,
    source: ast.Module,
    facts: Facts,
    term_references: []const References,
    function_roots: []compact.Root,
) Error!void {
    const pool = facts.sets;
    // Monotone least fixed point: every changed root adds a member.
    var changed = true;
    while (changed) {
        changed = try valueVariables(source, facts, function_roots);
        changed = try termVariables(source, facts, term_references, function_roots) or changed;
        for (source.functions, 0..) |function, id| {
            try data.admission.spend(facts.work, 1);
            if (function.body) |body| changed = try pool.merge(
                &function_roots[id],
                facts.terms[@intCast(body)],
                function.parameters,
            ) or changed;
        }
    }
    for (facts.functions, function_roots) |*set, root| {
        set.items = try pool.materialize(allocator, root);
        set.capacity = set.items.len;
    }
}
