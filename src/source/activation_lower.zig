// Copyright (c) 2026 Boundary contributors. MIT license.
//! Direct lowering into function-local stable slots. No block-parameter program
//! is built. The returned construction owns admitted records and flow facts;
//! encoding checks the current records again before producing canonical BPI3.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ir = data.activation;
const ast = @import("ast.zig");
const source = @import("../source.zig");
const check = @import("check.zig");
const Error = source.Error || data.activation_flow.Error || data.activation_types.Error;
const scope = @import("binding_scope.zig");
const none = scope.empty;

/// A binding can have several locations after source control duplication.
/// Presence here does not assert liveness at every cut; inspect the admitted
/// activation binding at the selected final function and slot.
pub const RecoveryBinding = struct {
    source_function: p.Id,
    variable: p.Id,
    source_schema: p.Id,
    function: p.Id,
    slot: p.Id,
    schema: p.Id,
};
pub const RecoveryEvidence = struct {
    input: ir.Program,
    correspondence: data.coalescing.Correspondence,
};

pub const Construction = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    flow: data.activation_flow.Facts,
    recovery: []const RecoveryBinding = &.{},
    /// Independently checked parameter locations. These do not promise that a
    /// parameter remains live at every instruction in its function.
    parameters: []const RecoveryBinding = &.{},
    recovery_evidence: ?RecoveryEvidence = null,

    pub fn encode(self: *const Construction, allocator: std.mem.Allocator, output: []u8) data.program_image.Error![]const u8 {
        return data.program_image.encode(allocator, self.program, output);
    }

    pub fn deinit(self: *Construction) void {
        self.flow.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Borrow source only during the call; own the resulting records independently.
/// No analysis scratch or authoring AST survives in the result arena. This
/// construction does not grant executable/trusted status.
pub fn lower(allocator: std.mem.Allocator, input: ast.Module) Error!Construction {
    return lowerObserved(allocator, input, .{});
}

pub fn lowerObserved(allocator: std.mem.Allocator, input: ast.Module, options: source.CompileOptions) Error!Construction {
    return lowerInternal(allocator, input, &.{}, false, &.{}, options);
}

pub fn lowerComponent(
    allocator: std.mem.Allocator,
    input: ast.Module,
    imports: []const p.Id,
    borrows: []const data.borrow_contract.Summary,
) Error!Construction {
    return lowerComponentObserved(allocator, input, imports, borrows, .{});
}
pub fn lowerComponentObserved(
    allocator: std.mem.Allocator,
    input: ast.Module,
    imports: []const p.Id,
    borrows: []const data.borrow_contract.Summary,
    options: source.CompileOptions,
) Error!Construction {
    return lowerInternal(allocator, input, imports, true, borrows, options);
}
fn lowerInternal(
    allocator: std.mem.Allocator,
    input: ast.Module,
    imports: []const p.Id,
    component: bool,
    borrows: []const data.borrow_contract.Summary,
    options: source.CompileOptions,
) Error!Construction {
    options.resetObservations();
    if (component and options.recovery) return error.InvalidSource;
    return lowerBody(allocator, input, imports, component, borrows, options) catch |err| {
        if (options.diagnostic) |diagnostic| diagnostic.code = err;
        return err;
    };
}
fn lowerBody(
    allocator: std.mem.Allocator,
    input: ast.Module,
    imports: []const p.Id,
    component: bool,
    borrows: []const data.borrow_contract.Summary,
    options: source.CompileOptions,
) Error!Construction {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owned = input;
    // The source checker is independent of both lowering representations.
    // Only genuine captures are enumerated; intermediate free sets share roots.
    options.stage(.source_check);
    const facts = try check.analyzeComponent(a, owned, imports, options.diagnostic);
    const traits = try data.traits.derive(a, owned.schemas);
    options.stage(.lowering);
    var compiler: Compiler = .{
        .allocator = a,
        .source = owned,
        .facts = facts,
        .capture_observer = options.captures,
        .slot_variables = if (options.captures != null) try a.alloc([]const ?p.Id, owned.functions.len) else &.{},
        .cacheable = try @import("value_cache.zig").derive(a, owned, traits),
        .uses = traits,
        .recovery_enabled = options.recovery,
    };
    try compiler.constants.appendSlice(a, owned.constants);
    const functions = try a.alloc(ir.Function, owned.functions.len);
    for (functions, 0..) |*function, id| {
        if (options.diagnostic) |diagnostic| diagnostic.function = id;
        var lowering: Function = .{
            .compiler = &compiler,
            .id = id,
            .bindings = .{ .allocator = a, .name_count = owned.variables.len },
        };
        function.* = try lowering.lower();
    }
    const program: ir.Program = .{
        .roots = .{
            .entry = owned.entry,
            .result = owned.functions[@intCast(owned.entry)].result,
            .failure = owned.failure,
        },
        .schemas = owned.schemas,
        .constants = compiler.constants.items,
        .effects = owned.effects,
        .functions = functions,
        .blocks = compiler.blocks.items,
        .handlers = try stableHandlers(a, owned.handlers),
        .scopes = .{
            .captures = compiler.captures.items,
            .region_count = owned.region_count,
            .resources = owned.resources,
        },
        .constructors = compiler.constructors.items,
    };
    if (options.diagnostic) |diagnostic| diagnostic.function = null;
    options.stage(.target_check);
    var original_facts = try checkTarget(allocator, &compiler, program, imports, component, borrows, null, options);
    original_facts.deinit();
    options.stage(.direct_optimization);
    const threaded = try @import("thread_jumps.zig").optimize(a, program);
    const selected = try data.tail_clauses.optimize(a, threaded, traits);
    const ordered = try @import("slot_order.zig").optimizeObserved(a, selected, if (options.recovery) .{ .context = &compiler, .receive = Compiler.reorderBindings } else null);
    if (!component) return coalesce(allocator, ordered, &compiler, options);
    if (options.semantic_statistics) |stats| stats.outcome = .deferred_open_component;
    if (options.coalescing.statistics) |stats| stats.* = .{
        .rounds = stats.rounds,
        .outcome = .deferred_open_component,
    };
    var output = std.heap.ArenaAllocator.init(allocator);
    errdefer output.deinit();
    options.stage(.source_copy);
    const result = try source.own(ir.Program, output.allocator(), ordered);
    options.stage(.target_check);
    const flow = try checkTarget(allocator, &compiler, result, imports, true, borrows, null, options);
    options.stage(.complete);
    if (options.diagnostic) |diagnostic| diagnostic.* = .{ .phase = .complete };
    return .{ .arena = output, .program = result, .flow = flow };
}

const CompilationObserver = struct {
    options: source.CompileOptions,
    compiler: *Compiler,
    fn correspondence(context: *anyopaque, trace: *const data.coalescing.OriginsTrace) data.coalescing.Error!void {
        const self: *CompilationObserver = @ptrCast(@alignCast(context));
        self.compiler.correspondence = try data.coalescing.Correspondence.copy(self.compiler.allocator, trace);
        for (self.compiler.recovery_bindings.items) |binding| {
            const function = trace.resolve(.function, binding.function) orelse continue;
            const schema = trace.resolve(.schema, binding.schema) orelse return error.InvalidCorrespondence;
            const local = trace.locals[@intCast(binding.function)];
            if (binding.slot >= local.slots.len) return error.InvalidCorrespondence;
            var final = binding;
            final.function = function;
            final.schema = schema;
            final.slot = local.slots[@intCast(binding.slot)];
            try self.compiler.final_bindings.append(self.compiler.allocator, final);
        }
        if (self.options.coalescing.correspondence) |observer| try observer.receive(observer.context, trace);
    }
    fn service(context: *anyopaque, report: ?data.closed_compilation.ServiceObservation.Report) void {
        const self: *CompilationObserver = @ptrCast(@alignCast(context));
        const observer = self.options.compilation_observer.?;
        observer.service.?.receive(observer.context, report);
    }
    fn enter(context: *anyopaque, stage: data.closed_compilation.Stage) void {
        const self: *CompilationObserver = @ptrCast(@alignCast(context));
        self.options.stage(if (stage == .p01) .coalescing else .semantic_optimization);
        if (self.options.compilation_observer) |observer| observer.enter(observer.context, stage);
    }
};
fn coalesce(allocator: std.mem.Allocator, program: ir.Program, compiler: *Compiler, options: source.CompileOptions) Error!Construction {
    var observation: CompilationObserver = .{ .options = options, .compiler = compiler };
    var statistics: data.closed_compilation.Statistics = .{};
    defer if (options.semantic_statistics) |out| {
        out.* = statistics;
    };
    var detail: data.coalescing.Diagnostic = .{};
    var selected = options.coalescing;
    if (options.recovery) selected.correspondence = .{ .context = &observation, .receive = CompilationObserver.correspondence };
    if (options.diagnostic) |diagnostic| {
        diagnostic.target = .{};
        diagnostic.function = null;
        diagnostic.variable = null;
        diagnostic.origins = .{};
        selected.diagnostic = &detail;
    }
    defer {
        if (options.diagnostic != null) if (options.coalescing.diagnostic) |out| {
            out.* = detail;
        };
    }
    var result = data.closed_compilation.run(allocator, program, .{
        .contract = options.contract,
        .objective = options.objective,
        .image_growth_bytes = options.image_growth_bytes,
        .max_image_bytes = options.max_image_bytes,
        .profile = options.profile,
        .work_limit = options.semantic_work_limit,
        .round_limit = options.semantic_round_limit,
        .statistics = &statistics,
        .observer = .{ .context = &observation, .enter = CompilationObserver.enter, .service = if (options.compilation_observer) |observer| if (observer.service) |service| .{ .contract = service.contract, .receive = CompilationObserver.service } else null else null },
        .coalescing = selected,
    }) catch |err| {
        if (options.diagnostic) |diagnostic| {
            if (statistics.stages_run != 0 or (statistics.failed_stage != null and statistics.failed_stage != .p01)) {
                // Semantic records no longer use the source's original indices.
                diagnostic.target = .{};
                diagnostic.origins = .{ .ambiguous = true };
                diagnostic.function = null;
                diagnostic.variable = null;
                return err;
            }
            diagnostic.target = detail.target;
            diagnostic.origins = detail.origins;
            if (detail.origins.count != 0) {
                const function = detail.origins.functions[0];
                diagnostic.function = function;
                if (!detail.origins.ambiguous and detail.target.capture != null) {
                    if (detail.target.field) |field| {
                        const free = compiler.facts.functions[@intCast(function)].items;
                        if (field < free.len) diagnostic.variable = free[@intCast(field)];
                    }
                }
            }
        }
        return err;
    };
    errdefer result.deinit();
    const recovery = try result.arena.allocator().dupe(RecoveryBinding, compiler.final_bindings.items);
    for (recovery) |binding| {
        if (binding.function >= result.program.functions.len) return error.InvalidSource;
        const slots = result.program.functions[@intCast(binding.function)].layout.slots;
        if (binding.slot >= slots.len or slots[@intCast(binding.slot)] != binding.schema) return error.InvalidSource;
    }
    var parameters: std.ArrayList(RecoveryBinding) = .empty;
    const evidence: ?RecoveryEvidence = if (options.recovery) try source.own(RecoveryEvidence, result.arena.allocator(), .{
        .input = program,
        .correspondence = compiler.correspondence orelse return error.InvalidCorrespondence,
    }) else null;
    if (evidence) |proof| {
        for (compiler.source.functions, 0..) |function, index| {
            const target = proof.correspondence.maps[@backingInt(data.relocation.Kind.function)][index];
            if (target == data.relocation.missing) continue;
            if (compiler.facts.functions[index].items.len != 0) return error.InvalidCorrespondence;
            const emitted = result.program.functions[@intCast(target)];
            if (function.parameters.len != emitted.inputs.len) return error.InvalidCorrespondence;
            for (function.parameters, emitted.inputs) |variable, slot| try parameters.append(result.arena.allocator(), .{
                .source_function = index,
                .variable = variable,
                .source_schema = compiler.source.variables[@intCast(variable)],
                .function = target,
                .slot = slot,
                .schema = emitted.layout.slots[@intCast(slot)],
            });
        }
    }
    const constructed: Construction = .{ .arena = result.arena, .program = result.program, .flow = result.flow, .recovery = recovery, .parameters = parameters.items, .recovery_evidence = evidence };
    if (options.recovery) try @import("recovery.zig").validate(allocator, compiler.source, &constructed);
    options.stage(.complete);
    if (options.diagnostic) |diagnostic| diagnostic.* = .{ .phase = .complete };
    return constructed;
}

fn checkTarget(allocator: std.mem.Allocator, compiler: *Compiler, program: ir.Program, imports: []const p.Id, component: bool, borrows: []const data.borrow_contract.Summary, origins: ?[]const p.Id, options: source.CompileOptions) Error!data.activation_flow.Facts {
    if (component) return data.activation_ownership.analyzeComponent(allocator, program, imports, borrows);
    // Admission can fail before setting a location (notably on allocation).
    // A previous pass's function ID belongs to a different, unprojected catalog.
    if (options.diagnostic) |diagnostic| {
        diagnostic.target = .{};
        diagnostic.function = null;
        diagnostic.variable = null;
        diagnostic.origins = .{};
    }
    return data.activation_ownership.analyzeObserved(allocator, program, if (options.diagnostic) |diagnostic| &diagnostic.target else null, if (origins == null and compiler.capture_observer != null) .{ .context = compiler, .capture = Compiler.observeCapture, .explanation = if (compiler.capture_observer.?.explanation != null) Compiler.observeExplanation else null } else null) catch |err|
        {
            if (options.diagnostic) |diagnostic| {
                @import("diagnostic_origins.zig").translate(diagnostic, program, origins, compiler.facts.functions);
            }
            return err;
        };
}

const ConstructorKey = struct { function: p.Id, schema: p.Id };
const Compiler = struct {
    allocator: std.mem.Allocator,
    source: ast.Module,
    facts: check.Facts,
    capture_observer: ?@import("diagnostic.zig").CaptureObserver,
    slot_variables: [][]const ?p.Id,
    recovery_enabled: bool = false,
    recovery_bindings: std.ArrayList(RecoveryBinding) = .empty,
    final_bindings: std.ArrayList(RecoveryBinding) = .empty,
    correspondence: ?data.coalescing.Correspondence = null,
    cacheable: []const bool,
    uses: data.traits.Facts,
    constants: std.ArrayList(p.Literal) = .empty,
    blocks: std.ArrayList(ir.Block) = .empty,
    captures: std.ArrayList(p.Capture) = .empty,
    constructors: std.ArrayList(p.Constructor) = .empty,
    constructor_ids: std.AutoHashMapUnmanaged(ConstructorKey, p.Id) = .empty,

    fn rememberBinding(self: *Compiler, function: p.Id, variable: p.Id, slot: p.Id) Error!void {
        if (!self.recovery_enabled) return;
        const schema = self.source.variables[@intCast(variable)];
        try self.recovery_bindings.append(self.allocator, .{ .source_function = function, .variable = variable, .source_schema = schema, .function = function, .slot = slot, .schema = schema });
    }
    fn reorderBindings(context: *anyopaque, maps: []const ?[]const p.Id) std.mem.Allocator.Error!void {
        const self: *Compiler = @ptrCast(@alignCast(context));
        for (self.recovery_bindings.items) |*binding| if (maps[@intCast(binding.function)]) |slots| {
            binding.slot = slots[@intCast(binding.slot)];
        };
    }

    fn observeCapture(pointer: *anyopaque, function: p.Id, selected: *const data.activation_ownership.CaptureSite, slot: p.Id) void {
        const self: *Compiler = @ptrCast(@alignCast(pointer));
        if (self.slot_variables[@intCast(function)][@intCast(slot)]) |variable|
            self.capture_observer.?.capture(self.capture_observer.?.context, selected, variable);
    }

    fn observeExplanation(pointer: *anyopaque, function: p.Id, selected: *const data.activation_ownership.CaptureSite, slot: p.Id, explanation: ?data.activation_ownership.CaptureExplanation) void {
        const self: *Compiler = @ptrCast(@alignCast(pointer));
        const variable = self.slot_variables[@intCast(function)][@intCast(slot)] orelse return;
        var mapped = explanation;
        if (mapped) |*present| {
            const reasons = self.allocator.dupe(data.activation_ownership.CaptureExplanation.Reason, present.reasons) catch {
                self.capture_observer.?.explanation.?(self.capture_observer.?.context, selected, variable, null);
                return;
            };
            for (reasons) |*reason| if (reason.location.function) |origin_function| {
                if (reason.location.slot) |origin_slot|
                    reason.location.source_variable = self.slot_variables[@intCast(origin_function)][@intCast(origin_slot)];
            };
            present.reasons = reasons;
        }
        self.capture_observer.?.explanation.?(self.capture_observer.?.context, selected, variable, mapped);
    }

    fn constructor(self: *Compiler, function: p.Id, schema: p.Id, value_id: p.Id) Error!p.Id {
        if (self.capture_observer) |observer| for (self.facts.functions[@intCast(function)].items) |variable|
            observer.closure(observer.context, value_id, variable);
        const key: ConstructorKey = .{ .function = function, .schema = schema };
        if (self.constructor_ids.get(key)) |id| return id;
        const shape = self.source.schemas[@intCast(schema)];
        if (shape != .internal or shape.internal != .computation) return error.TypeMismatch;
        const free = self.facts.functions[@intCast(function)].items;
        const fields = try self.allocator.alloc(p.Id, free.len);
        for (fields, free) |*field, name| field.* = self.source.variables[@intCast(name)];
        const capture = self.captures.items.len;
        try self.captures.append(self.allocator, .{
            .fields = fields,
            .use = shape.internal.computation.use,
        });
        const id = self.constructors.items.len;
        try self.constructors.append(self.allocator, .{
            .function = function,
            .schema = schema,
            .capture = capture,
        });
        try self.constructor_ids.put(self.allocator, key, id);
        return id;
    }

    fn unit(self: *Compiler) Error!p.Id {
        for (self.constants.items, 0..) |literal, id| {
            if (self.source.schemas[@intCast(literal.schema)] == .unit) return id;
        }
        for (self.source.schemas, 0..) |shape, schema| {
            if (shape != .unit) continue;
            const id = self.constants.items.len;
            try self.constants.append(self.allocator, .{ .schema = schema, .bytes = &.{} });
            return id;
        }
        return error.TypeMismatch;
    }
};

fn stableHandlers(allocator: std.mem.Allocator, input: []const p.Handler) Error![]const ir.Handler {
    const output = try allocator.alloc(ir.Handler, input.len);
    for (output, input) |*target, handler| {
        const clauses = try allocator.alloc(ir.Clause, handler.clauses.len);
        for (clauses, handler.clauses) |*clause, original| {
            clause.* = .{ .effect = original.effect, .function = original.function, .resumption = original.resumption };
        }
        target.* = .{ .mode = handler.mode, .input = handler.input, .answer = handler.answer, .return_function = handler.return_function, .clauses = clauses, .state = handler.state, .effects = handler.effects };
    }
    return output;
}

const Continuation = struct { block: p.Id, destination: p.Id };
const Task = struct { block: p.Id, term: p.Id, environment: p.Id, next: ?Continuation, custody: p.Id };
const TaskKey = struct { term: p.Id, environment: p.Id, next: p.Id, destination: p.Id, custody: p.Id };

const Function = struct {
    compiler: *Compiler,
    id: p.Id,
    slots: std.ArrayList(p.Id) = .empty,
    slot_variables: std.ArrayList(?p.Id) = .empty,
    custody: std.ArrayList(ir.CustodyScope) = .empty,
    bindings: scope.Scopes,
    tasks: std.ArrayList(Task) = .empty,
    memo: std.AutoHashMapUnmanaged(TaskKey, p.Id) = .empty,
    returned: ?Continuation = null,

    fn lower(self: *Function) Error!ir.Function {
        const compiler = self.compiler;
        const definition = compiler.source.functions[@intCast(self.id)];
        try self.custody.append(compiler.allocator, .{});
        const free = compiler.facts.functions[@intCast(self.id)].items;
        const inputs = try compiler.allocator.alloc(p.Id, free.len + definition.parameters.len);
        var environment: p.Id = none;
        for (free, 0..) |name, index| {
            environment = try self.bind(environment, name);
            inputs[index] = try self.resolve(environment, name);
        }
        for (definition.parameters, 0..) |name, index| {
            environment = try self.bind(environment, name);
            inputs[free.len + index] = try self.resolve(environment, name);
        }
        const entry = if (definition.body) |body| try self.schedule(body, environment, null, 0) else data.relocation.missing;
        while (self.tasks.pop()) |task| try self.emit(task);
        if (compiler.capture_observer != null) compiler.slot_variables[@intCast(self.id)] = self.slot_variables.items;
        return .{
            .entry = entry,
            .inputs = inputs,
            .layout = .{ .slots = self.slots.items },
            .custody = self.custody.items,
            .result = definition.result,
            .effects = definition.effects,
            .regions = definition.regions,
        };
    }

    fn slot(self: *Function, schema: p.Id) Error!p.Id {
        const id = self.slots.items.len;
        try self.slots.append(self.compiler.allocator, schema);
        if (self.compiler.capture_observer != null) try self.slot_variables.append(self.compiler.allocator, null);
        return id;
    }

    fn bind(self: *Function, parent: p.Id, name: p.Id) Error!p.Id {
        const destination = try self.slot(self.compiler.source.variables[@intCast(name)]);
        try self.compiler.rememberBinding(self.id, name, destination);
        if (self.compiler.capture_observer != null) self.slot_variables.items[@intCast(destination)] = name;
        return self.bindings.bind(parent, name, destination);
    }

    fn bindingCustody(self: *Function, parent: p.Id, names: []const p.Id) Error!p.Id {
        for (names) |name| {
            const schema = self.compiler.source.variables[@intCast(name)];
            if (self.compiler.uses.copy[@intCast(schema)]) continue;
            const id = self.custody.items.len;
            try self.custody.append(self.compiler.allocator, .{ .parent = parent });
            return id;
        }
        return parent;
    }

    fn resolve(self: *const Function, environment: p.Id, name: p.Id) Error!p.Id {
        return self.bindings.resolve(environment, name);
    }

    fn reserveBlock(self: *Function) Error!p.Id {
        const id = self.compiler.blocks.items.len;
        try self.compiler.blocks.append(self.compiler.allocator, .{
            .function = self.id,
            .instructions = &.{},
            .terminator = .{ .return_value = none },
        });
        return id;
    }

    fn schedule(self: *Function, term_id: p.Id, env: p.Id, next: ?Continuation, custody: p.Id) Error!p.Id {
        const key: TaskKey = .{
            .term = term_id,
            .environment = env,
            .custody = custody,
            .next = if (next) |n| n.block else none,
            .destination = if (next) |n| n.destination else none,
        };
        if (self.memo.get(key)) |id| return id;
        const block = try self.reserveBlock();
        try self.memo.put(self.compiler.allocator, key, block);
        try self.tasks.append(self.compiler.allocator, .{
            .block = block,
            .term = term_id,
            .environment = env,
            .custody = custody,
            .next = next,
        });
        return block;
    }

    fn returnSite(self: *Function) Error!Continuation {
        if (self.returned) |next| return next;
        const result = self.compiler.source.functions[@intCast(self.id)].result;
        const destination = try self.slot(result);
        const block = try self.reserveBlock();
        self.compiler.blocks.items[@intCast(block)].terminator = .{ .return_value = destination };
        const next: Continuation = .{ .block = block, .destination = destination };
        self.returned = next;
        return next;
    }

    fn edge(self: *Function, next: Continuation, value: ir.Source) Error!ir.Edge {
        if (value == .slot and value.slot == next.destination) return .{ .block = next.block };
        const assignments = try self.compiler.allocator.alloc(ir.Assignment, 1);
        assignments[0] = .{ .destination = next.destination, .source = value };
        return .{ .block = next.block, .assignments = assignments };
    }

    fn emit(self: *Function, task: Task) Error!void {
        var block: Block = .{ .function = self, .environment = task.environment };
        const terminator = try self.term(&block, task);
        self.compiler.blocks.items[@intCast(task.block)] = .{
            .function = self.id,
            .custody = task.custody,
            .instructions = block.instructions.items,
            .terminator = terminator,
        };
    }

    fn term(self: *Function, block: *Block, task: Task) Error!ir.Terminator {
        var current = task;
        var traversed: usize = 0;
        while (true) {
            const expression = self.compiler.source.terms[@intCast(current.term)];
            if (expression != .bind) break;
            const binding = expression.bind;
            const value_term = self.compiler.source.terms[@intCast(binding.value)];
            const schema = self.compiler.source.variables[@intCast(binding.variable)];
            // Owned bindings introduce custody scopes and keep their original
            // boundaries. A copyable value has no such scope transition.
            if (value_term != .value or !self.compiler.uses.copy[@intCast(schema)]) break;
            if (traversed >= self.compiler.source.terms.len) return error.InvalidSource;
            traversed += 1;
            const first_fresh = self.slots.items.len;
            const value = try block.value(value_term.value);
            if (value < first_fresh) {
                // Preserve distinct named-variable provenance for aliases.
                const environment = try self.bind(current.environment, binding.variable);
                const rest = try self.schedule(binding.next, environment, current.next, current.custody);
                return .{ .jump = try self.edge(.{ .block = rest, .destination = try self.resolve(environment, binding.variable) }, .{ .slot = value }) };
            }
            if (self.compiler.capture_observer != null) self.slot_variables.items[@intCast(value)] = binding.variable;
            try self.compiler.rememberBinding(self.id, binding.variable, value);
            current.environment = try self.bindings.bind(current.environment, binding.variable, value);
            current.term = binding.next;
            block.environment = current.environment;
            // Staging remains eager. A repeated cell read after a write must
            // execute again, even when source expressions share an ID.
            block.computed.clearRetainingCapacity();
            block.products.clearRetainingCapacity();
        }
        return self.termAfterValues(block, current);
    }

    fn termAfterValues(self: *Function, block: *Block, task: Task) Error!ir.Terminator {
        const expression = self.compiler.source.terms[@intCast(task.term)];
        switch (expression) {
            .bind => |binding| {
                const env = try self.bind(task.environment, binding.variable);
                const custody = try self.bindingCustody(task.custody, &.{binding.variable});
                const rest = try self.schedule(binding.next, env, task.next, custody);
                const next: Continuation = .{
                    .block = rest,
                    .destination = try self.resolve(env, binding.variable),
                };
                // A control operation ends this block in the same custody
                // scope. Its result still enters the binding's successor scope.
                // Do not add an empty edge after eagerly staged operands.
                const value_term = self.compiler.source.terms[@intCast(binding.value)];
                switch (value_term) {
                    .call,
                    .apply,
                    .perform,
                    .handle,
                    .with_region,
                    .protect,
                    .resume_value,
                    .resume_with,
                    .resume_computation,
                    => return self.control(block, value_term, next),
                    else => {},
                }
                return .{ .jump = .{
                    .block = try self.schedule(binding.value, task.environment, next, task.custody),
                } };
            },
            .value => |value| {
                const result = try block.value(value);
                return if (task.next) |next|
                    .{ .jump = try self.edge(next, .{ .slot = result }) }
                else
                    .{ .return_value = result };
            },
            .fail => |value| return .{ .fail = try block.value(value) },
            .yield_then => |body| return .{ .yield_value = .{
                .block = try self.schedule(body, task.environment, task.next, task.custody),
            } },
            .conditional => |branch| return .{ .branch = .{
                .condition = try block.value(branch.condition),
                .when_true = .{
                    .block = try self.schedule(branch.when_true, task.environment, task.next, task.custody),
                },
                .when_false = .{
                    .block = try self.schedule(branch.when_false, task.environment, task.next, task.custody),
                },
            } },
            .match_sum => return self.match(block, task),
            .unpack_product => return self.unpack(block, task),
            .dispose => return self.dispose(block, task),
            else => return self.control(block, expression, task.next),
        }
    }

    fn match(self: *Function, block: *Block, task: Task) Error!ir.Terminator {
        const selected = self.compiler.source.terms[@intCast(task.term)].match_sum;
        const value = try block.value(selected.value);
        const cases = try self.compiler.allocator.alloc(ir.Edge, selected.cases.len);
        for (cases, selected.cases) |*edge_value, case| {
            const env = try self.bind(task.environment, case.variable);
            const custody = try self.bindingCustody(task.custody, &.{case.variable});
            edge_value.* = try self.edge(.{
                .block = try self.schedule(case.body, env, task.next, custody),
                .destination = try self.resolve(env, case.variable),
            }, .returned);
        }
        return .{ .switch_variant = .{ .value = value, .cases = cases } };
    }

    fn unpack(self: *Function, block: *Block, task: Task) Error!ir.Terminator {
        const unpacking = self.compiler.source.terms[@intCast(task.term)].unpack_product;
        const value = try block.value(unpacking.value);
        const destinations = try self.compiler.allocator.alloc(p.Id, unpacking.variables.len);
        var env = task.environment;
        for (destinations, unpacking.variables) |*destination, name| {
            env = try self.bind(env, name);
            destination.* = try self.resolve(env, name);
        }
        const custody = try self.bindingCustody(task.custody, unpacking.variables);
        return .{ .unpack_product = .{
            .value = value,
            .destinations = destinations,
            .next = .{ .block = try self.schedule(unpacking.body, env, task.next, custody) },
        } };
    }

    fn dispose(self: *Function, block: *Block, task: Task) Error!ir.Terminator {
        const owned = try block.value(self.compiler.source.terms[@intCast(task.term)].dispose);
        const next = task.next orelse try self.returnSite();
        var adapter: Block = .{ .function = self, .environment = task.environment };
        const literal = try self.compiler.unit();
        const schema = self.compiler.constants.items[@intCast(literal)].schema;
        const unit = try adapter.instruction(schema, .{
            .opcode = .constant,
            .immediate = literal,
        });
        const id = try self.reserveBlock();
        self.compiler.blocks.items[@intCast(id)] = .{
            .function = self.id,
            .custody = task.custody,
            .instructions = adapter.instructions.items,
            .terminator = .{ .jump = try self.edge(next, .{ .slot = unit }) },
        };
        return .{ .dispose = .{ .owned = owned, .next = .{ .block = id } } };
    }

    fn control(
        self: *Function,
        block: *Block,
        expression: ast.Term,
        continuation: ?Continuation,
    ) Error!ir.Terminator {
        const next = try self.edge(continuation orelse try self.returnSite(), .returned);
        return switch (expression) {
            .call => |call| .{ .call = .{
                .function = call.function,
                .arguments = try block.callArguments(call.function, call.arguments),
                .next = next,
            } },
            .apply => |apply| try block.application(apply, next),
            .perform => |perform| .{ .perform = .{
                .effect = perform.effect,
                .capability = try block.optional(perform.capability),
                .payload = try block.value(perform.payload),
                .bodies = try block.values(perform.bodies),
                .use_site_capabilities = try block.values(perform.use_site_capabilities),
                .next = next,
            } },
            .handle => |handle| try block.handler(handle, next),
            else => return self.retainedControl(block, expression, next),
        };
    }

    fn retainedControl(
        self: *Function,
        block: *Block,
        expression: ast.Term,
        next: ir.Edge,
    ) Error!ir.Terminator {
        _ = self;
        return switch (expression) {
            .resume_value => |resume_value| .{ .resume_value = .{
                .resumption = try block.value(resume_value.resumption),
                .argument = try block.value(resume_value.argument),
                .next = next,
            } },
            .resume_with => |resume_with| .{ .resume_with = .{
                .resumption = try block.value(resume_with.resumption),
                .argument = try block.value(resume_with.argument),
                .handler = resume_with.handler,
                .state = try block.values(resume_with.state),
                .next = next,
            } },
            .resume_computation => |resume_computation| .{ .resume_computation = .{
                .resumption = try block.value(resume_computation.resumption),
                .computation = try block.value(resume_computation.computation),
                .next = next,
            } },
            .protect => |protect| .{ .protect = .{
                .body = try block.value(protect.body),
                .cleanup = try block.value(protect.cleanup),
                .arguments = try block.values(protect.arguments),
                .resource = try block.optional(protect.resource),
                .loan_region = protect.loan_region,
                .next = next,
            } },
            .with_region => |region| .{ .with_region = .{
                .region = region.region,
                .body = try block.value(region.body),
                .arguments = try block.values(region.arguments),
                .next = next,
            } },
            else => return error.InvalidSource,
        };
    }
};

const Block = struct {
    function: *Function,
    environment: p.Id,
    instructions: std.ArrayList(ir.Instruction) = .empty,
    computed: std.AutoHashMapUnmanaged(p.Id, p.Id) = .empty,
    products: std.AutoHashMapUnmanaged(p.Id, []const p.Id) = .empty,

    fn handler(self: *Block, handle: @FieldType(ast.Term, "handle"), next: ir.Edge) Error!ir.Terminator {
        const compiler = self.function.compiler;
        const body_value = compiler.source.values[@intCast(handle.body)];
        const shape = compiler.source.schemas[@intCast(body_value.schema)];
        // A reusable closed lambda reads no operand and has no authored effect
        // or fault. Place only that construction next to its immediate use;
        // all argument/state evaluation keeps its original relative order.
        const closed = body_value.expression == .lambda and
            compiler.facts.functions[@intCast(body_value.expression.lambda)].items.len == 0 and
            shape == .internal and shape.internal == .computation and shape.internal.computation.use == .reusable;
        const early_body: ?p.Id = if (closed) null else try self.value(handle.body);
        const arguments = try self.values(handle.arguments);
        const state = try self.values(handle.state);
        const body = early_body orelse try self.value(handle.body);
        return .{ .handle = .{ .handler = handle.handler, .body = body, .arguments = arguments, .state = state, .next = next } };
    }

    const Operation = struct {
        opcode: p.Opcode,
        operands: []const p.Id = &.{},
        immediate: p.Id = 0,
        failures: []const p.InstructionFailure = &.{},
    };

    fn instruction(self: *Block, schema: p.Id, operation: Operation) Error!p.Id {
        // Slots written in this block are fresh. A copyable product therefore
        // still contains these exact operand values, even after later mutable
        // operations. Keep its construction and all operand evaluation; only
        // the redundant projection is omitted. Never forward a consumed owner.
        const compiler = self.function.compiler;
        if (operation.opcode == .field and operation.operands.len == 1 and
            operation.failures.len == 0 and compiler.uses.copy[@intCast(schema)])
        {
            if (self.products.get(operation.operands[0])) |fields| {
                const product = compiler.source.schemas[@intCast(self.function.slots.items[@intCast(operation.operands[0])])].product;
                // Full target admission follows lowering. Leave malformed source
                // projections intact for that owner to reject, rather than
                // erasing their invalid type, index, arity or failure mapping.
                if (operation.immediate < fields.len and operation.immediate < product.len and
                    product[@intCast(operation.immediate)] == schema)
                    return fields[@intCast(operation.immediate)];
            }
        }
        const destination = try self.function.slot(schema);
        try self.instructions.append(self.function.compiler.allocator, .{
            .destination = destination,
            .opcode = operation.opcode,
            .operands = operation.operands,
            .immediate = operation.immediate,
            .failures = operation.failures,
        });
        if (operation.opcode == .product and compiler.source.schemas[@intCast(schema)] == .product and
            compiler.uses.copy[@intCast(schema)] and compiler.uses.drop[@intCast(schema)])
            try self.products.put(compiler.allocator, destination, operation.operands);
        return destination;
    }

    const ValueTask = struct { id: p.Id, operands: []p.Id, next: usize = 0 };
    fn value(self: *Block, id: p.Id) Error!p.Id {
        if (self.computed.get(id)) |slot| return slot;
        const compiler = self.function.compiler;
        var tasks: std.ArrayList(ValueTask) = .empty;
        defer tasks.deinit(compiler.allocator);
        try tasks.append(compiler.allocator, try self.valueTask(id));
        while (tasks.items.len != 0) {
            const task = &tasks.items[tasks.items.len - 1];
            const expression = compiler.source.values[@intCast(task.id)].expression;
            if (expression == .primitive and task.next < task.operands.len) {
                const child = expression.primitive.operands[task.next];
                if (self.computed.get(child)) |slot| {
                    task.operands[task.next] = slot;
                    task.next += 1;
                } else try tasks.append(compiler.allocator, try self.valueTask(child));
                continue;
            }
            const result = try self.emitValue(task.id, task.operands);
            if (compiler.cacheable[@intCast(task.id)])
                try self.computed.put(compiler.allocator, task.id, result);
            _ = tasks.pop();
            if (tasks.items.len == 0) return result;
            const parent = &tasks.items[tasks.items.len - 1];
            parent.operands[parent.next] = result;
            parent.next += 1;
        }
        return error.InvalidSource;
    }

    fn valueTask(self: *Block, id: p.Id) Error!ValueTask {
        const compiler = self.function.compiler;
        const expression = compiler.source.values[@intCast(id)].expression;
        const count = if (expression == .primitive) expression.primitive.operands.len else 0;
        return .{ .id = id, .operands = try compiler.allocator.alloc(p.Id, count) };
    }

    fn emitValue(self: *Block, id: p.Id, operands: []const p.Id) Error!p.Id {
        const compiler = self.function.compiler;
        const definition = compiler.source.values[@intCast(id)];
        const operation: Operation = switch (definition.expression) {
            .variable => |name| return self.function.resolve(self.environment, name),
            .literal => |literal| .{
                .opcode = .constant,
                .immediate = literal,
            },
            .primitive => |primitive| .{
                .opcode = primitive.opcode,
                .operands = operands,
                .immediate = primitive.immediate,
                .failures = primitive.failures,
            },
            .lambda => |function| .{
                .opcode = .computation,
                .operands = try self.captures(function),
                .immediate = try compiler.constructor(function, definition.schema, id),
            },
        };
        return self.instruction(definition.schema, operation);
    }

    fn captures(self: *Block, function: p.Id) Error![]const p.Id {
        const compiler = self.function.compiler;
        const free = compiler.facts.functions[@intCast(function)].items;
        const result = try compiler.allocator.alloc(p.Id, free.len);
        for (result, free) |*slot, name| {
            slot.* = try self.function.resolve(self.environment, name);
        }
        return result;
    }

    fn callArguments(self: *Block, function: p.Id, supplied: []const p.Id) Error![]const p.Id {
        const captured = try self.captures(function);
        const arguments = try self.values(supplied);
        return std.mem.concat(self.function.compiler.allocator, p.Id, &.{ captured, arguments });
    }

    fn application(self: *Block, apply: anytype, next: ir.Edge) Error!ir.Terminator {
        const compiler = self.function.compiler;
        const value_definition = compiler.source.values[@intCast(apply.computation)];
        if (value_definition.expression == .lambda) direct: {
            const function = value_definition.expression.lambda;
            // Moving an owner into a closure precedes argument evaluation. Keep
            // that custody boundary unless all captures can remain in the caller.
            for (compiler.facts.functions[@intCast(function)].items) |name| {
                const schema = compiler.source.variables[@intCast(name)];
                if (!compiler.uses.copy[@intCast(schema)]) break :direct;
            }
            // Keep the source callable's signature/capture contract in target
            // admission even though execution needs no closure object.
            _ = try compiler.constructor(function, value_definition.schema, apply.computation);
            return .{ .call = .{
                .function = function,
                .arguments = try self.callArguments(function, apply.arguments),
                .next = next,
            } };
        }
        return .{ .apply = .{
            .computation = try self.value(apply.computation),
            .arguments = try self.values(apply.arguments),
            .next = next,
        } };
    }

    fn values(self: *Block, supplied: []const p.Id) Error![]const p.Id {
        const result = try self.function.compiler.allocator.alloc(p.Id, supplied.len);
        for (result, supplied) |*slot, id| slot.* = try self.value(id);
        return result;
    }

    fn optional(self: *Block, supplied: ?p.Id) Error!?p.Id {
        return if (supplied) |id| try self.value(id) else null;
    }
};
