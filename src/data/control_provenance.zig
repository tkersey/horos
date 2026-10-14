// Copyright (c) 2026 Boundary contributors. MIT license.
//! Program-bound control relevance. Only this owner expands uncertainty to the
//! conservative clause set. A selection cannot be constructed from caller facts.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const contracts = @import("contracts.zig");
pub const Error = @import("admission.zig").Error;
pub const Role = enum { operation, callee, body, cleanup, resumed, injected, handler };
pub const Boundary = struct { block: p.Id, role: Role };
pub const Target = struct { handler: p.Id, clause: usize, effect: p.Id, function: p.Id, resumption: p.Id, retains: bool };
pub const Context = struct { analysis: *const Analysis, block: p.Id };
const SelectionData = struct {
    owner: ?*const Analysis,
    image: ir.Program,
    boundary: Boundary,
    effect: p.Id,
    targets: []const Target,
    knowledge: Knowledge,
};
pub const Knowledge = struct { conservative: bool, environmental: bool = false };

/// Presentation facts, never admission evidence. All references are indices in
/// this finite graph; cycles describe summary dependencies, not dynamic runs.
pub const Explanation = struct {
    boundary: Boundary,
    effect: p.Id,
    knowledge: Knowledge,
    targets: []const Target,
    reasons: []const Reason,
    root: usize,
    capture_constraint: ?struct { slot: p.Id, schema: p.Id, satisfied: bool } = null,

    pub const Rule = enum {
        selection,
        environmental,
        fresh_installation,
        direct_argument,
        direct_return,
        closure_capture,
        closure_application,
        aggregate_union,
        aggregate_projection,
        branch_join,
        opaque_cell,
        scoped_input,
        successor_binding,
        owned_cleanup,
        unknown_input,
        summary_dependency,
        conservative_expansion,
    };
    pub const Location = struct { function: ?p.Id = null, block: ?p.Id = null, position: ?usize = null, slot: ?p.Id = null, source_variable: ?p.Id = null };
    pub const Reason = struct {
        rule: Rule,
        location: Location = .{},
        inputs: []const usize = &.{},
        origins: []const Origin = &.{},
        handler: ?p.Id = null,
        /// This node describes a may-union or a loss of precision.
        approximation: bool = false,
    };

    /// Copies presentation only: no slice or pointer into the compiler or input
    /// program survives. Numeric locations retain their original meaning.
    pub fn copy(self: Explanation, allocator: std.mem.Allocator) Error!Explanation {
        var result = self;
        result.targets = try allocator.dupe(Target, self.targets);
        errdefer allocator.free(result.targets);
        const reasons = try allocator.alloc(Reason, self.reasons.len);
        var initialized: usize = 0;
        errdefer {
            for (reasons[0..initialized]) |reason| {
                allocator.free(reason.inputs);
                allocator.free(reason.origins);
            }
            allocator.free(reasons);
        }
        for (self.reasons, reasons) |reason, *destination| {
            destination.* = reason;
            destination.inputs = try allocator.dupe(usize, reason.inputs);
            errdefer allocator.free(destination.inputs);
            destination.origins = try allocator.dupe(Origin, reason.origins);
            initialized += 1;
        }
        result.reasons = reasons;
        return result;
    }
    pub fn deinit(self: Explanation, allocator: std.mem.Allocator) void {
        for (self.reasons) |reason| {
            allocator.free(reason.inputs);
            allocator.free(reason.origins);
        }
        allocator.free(self.reasons);
        allocator.free(self.targets);
    }
};

/// Borrowed for the admission invocation. An observer retaining a selection
/// must copy it through this owner; copying retains its original boundary and
/// exact program, rather than reconstructing relevance from an effect number.
/// A copied selection still borrows that immutable program for its lifetime.
pub const Selection = opaque {
    fn data(self: *const Selection) *const SelectionData {
        return @ptrCast(@alignCast(self));
    }
    pub fn boundary(self: *const Selection) Boundary {
        return self.data().boundary;
    }
    pub fn effect(self: *const Selection) p.Id {
        return self.data().effect;
    }
    pub fn targets(self: *const Selection) []const Target {
        return self.data().targets;
    }
    pub fn knowledge(self: *const Selection) Knowledge {
        return self.data().knowledge;
    }
    pub fn copy(self: *const Selection, allocator: std.mem.Allocator) Error!*const Selection {
        const stored = try allocator.create(SelectionData);
        errdefer allocator.destroy(stored);
        stored.* = self.data().*;
        stored.owner = null;
        stored.targets = try allocator.dupe(Target, stored.targets);
        return @ptrCast(stored);
    }
    /// Only for a selection returned by copy, using the same allocator.
    pub fn destroyCopy(self: *const Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.data().targets);
        allocator.destroy(self.data());
    }
    pub fn captureAllowed(self: *const Selection, uses: @import("traits.zig").Facts, schema: p.Id) Error!bool {
        const stored = self.data();
        if (stored.image.effects[@intCast(stored.effect)].control_use == .multi and !uses.clone[@intCast(schema)]) return false;
        for (stored.targets) |target| {
            const signature = try contracts.resumption(stored.image, target.resumption);
            if (std.mem.indexOfScalar(p.Id, signature.capture_bound, schema) == null) return false;
        }
        return true;
    }
};

const Storage = struct {
    allocator: std.mem.Allocator,
    image: ir.Program,
    conservative: [][]const Target,
    operations: []?[]const Target,
    calls: [][]const CallTargets,
    values: ?*const Values = null,
    relative: ?*const Values = null,
    positions: std.ArrayList(PositionSources) = .empty,
    explanations: std.ArrayList(Explanation) = .empty,
    disposal_query: ?DisposalExecution = null,
    constructor_queries: std.ArrayList(ConstructorQuery) = .empty,
};
const ConstructorQuery = struct { block: p.Id, slot: p.Id, result: Analysis.Constructors };
const CallTargets = struct { role: Role = .callee, effect: p.Id, targets: ?[]const Target, environmental: bool = false };
pub const SuspensionSources = struct { slots: []const p.Id = &.{}, pending_return: bool = false, conservative: bool = false };
pub const InvocationSources = struct { inputs: []const p.Id = &.{}, conservative: bool = false };
const PositionSources = struct { block: p.Id, position: usize, returned: bool, effects: []const SuspensionSources, returns: SuspensionSources };

pub const Analysis = opaque {
    fn data(self: *const Analysis) *const Storage {
        return @ptrCast(@alignCast(self));
    }
    /// Private analysis consumers share this exact immutable subject and solver.
    pub fn program(self: *const Analysis) ir.Program {
        return self.data().image;
    }
    pub const Constructors = struct { ids: []const p.Id, conservative: bool };
    pub fn constructorsAt(self: *const Analysis, block: p.Id, slot: p.Id) Error!Constructors {
        const stored: *Storage = @ptrCast(@alignCast(@constCast(self)));
        for (stored.constructor_queries.items) |known| if (known.block == block and known.slot == slot) return known.result;
        const result = try self.deriveConstructors(block, slot);
        try stored.constructor_queries.append(stored.allocator, .{ .block = block, .slot = slot, .result = result });
        return result;
    }
    fn deriveConstructors(self: *const Analysis, block: p.Id, slot: p.Id) Error!Constructors {
        const stored = self.data();
        const values = stored.values orelse {
            // The full target solver is unnecessary for handler-free images.
            // A final local constructor assignment is nevertheless exact.
            const instructions = stored.image.blocks[@intCast(block)].instructions;
            var position = instructions.len;
            while (position != 0) {
                position -= 1;
                const instruction = instructions[position];
                if (instruction.destination != slot) continue;
                if (instruction.opcode != .computation) break;
                return .{ .ids = try stored.allocator.dupe(p.Id, &.{instruction.immediate}), .conservative = false };
            }
            return .{ .ids = &.{}, .conservative = true };
        };
        const origins = values.exits[@intCast(block)].get(@intCast(slot));
        var ids: std.ArrayList(p.Id) = .empty;
        var conservative = origins == empty;
        var iterator = values.origins.iterator(origins);
        while (iterator.next()) |origin| switch (origin) {
            .constructor => |id| try ids.append(stored.allocator, id),
            else => conservative = true,
        };
        return .{ .ids = ids.items, .conservative = conservative };
    }
    /// Build a presentation from final fixed-point facts, never worklist history.
    /// The invocation arena owns it; use Explanation.copy to retain it.
    pub fn explain(self: *const Analysis, selection: *const Selection) Error!Explanation {
        if (selection.data().owner != self) return error.InvalidReference;
        if (self.data().values) |values| if (values.seeds == null) return error.InvalidReference;
        for (self.data().explanations.items) |known| {
            if (std.meta.eql(known.boundary, selection.boundary()) and known.effect == selection.effect()) return known;
        }
        var builder: ExplanationBuilder = .{ .stored = self.data() };
        const root = try builder.selection(selection);
        const result: Explanation = .{ .boundary = selection.boundary(), .effect = selection.effect(), .knowledge = selection.knowledge(), .targets = selection.targets(), .reasons = builder.reasons.items, .root = root };
        const stored: *Storage = @ptrCast(@alignCast(@constCast(self)));
        try stored.explanations.append(stored.allocator, result);
        return result;
    }
    /// Query only the immutable image used for derivation. No replacement image
    /// or caller-supplied weaker target map enters this API.
    pub fn targets(self: *const Analysis, boundary: Boundary, effect: p.Id) []const Target {
        if (boundary.role == .operation) if (self.data().operations[@intCast(boundary.block)]) |known| {
            if (self.data().image.blocks[@intCast(boundary.block)].terminator.perform.effect == effect) return known;
        };
        for (self.data().calls[@intCast(boundary.block)]) |known| {
            if (known.role == boundary.role and known.effect == effect) if (known.targets) |targets_| return targets_;
        }
        return self.data().conservative[@intCast(effect)];
    }
    pub fn select(self: *const Analysis, boundary: Boundary, effect: p.Id) Error!*const Selection {
        const stored = try self.data().allocator.create(SelectionData);
        var knowledge: Knowledge = .{ .conservative = true };
        if (boundary.role == .operation and self.data().operations[@intCast(boundary.block)] != null and self.data().image.blocks[@intCast(boundary.block)].terminator.perform.effect == effect)
            knowledge = .{ .conservative = false, .environmental = self.data().image.blocks[@intCast(boundary.block)].terminator.perform.capability == null };
        for (self.data().calls[@intCast(boundary.block)]) |known| {
            if (known.role == boundary.role and known.effect == effect and known.targets != null) knowledge = .{ .conservative = false, .environmental = known.environmental };
        }
        stored.* = .{ .owner = self, .image = self.data().image, .boundary = boundary, .effect = effect, .targets = self.targets(boundary, effect), .knowledge = knowledge };
        return @ptrCast(stored);
    }
    /// Declared rows describe ordinary invocation. Discarding owned values can
    /// additionally execute captured cleanup, even in a failing pure helper.
    pub fn effectRow(self: *const Analysis, boundary: Boundary, declared: []const p.Id) Error![]const p.Id {
        var result: std.ArrayList(p.Id) = .empty;
        for (self.data().calls[@intCast(boundary.block)]) |known| {
            if (known.role != boundary.role or contracts.containsEffect(declared, known.effect)) continue;
            if (result.items.len == 0) try result.appendSlice(self.data().allocator, declared);
            try result.append(self.data().allocator, known.effect);
        }
        return if (result.items.len == 0) declared else result.items;
    }
    /// Qualify concrete disposal origins with the same program-derived effects
    /// used for caller capture admission. A retained capability is not itself
    /// executable cleanup. Callers supply an already validated schema/effect.
    pub fn disposalEffect(self: *const Analysis, schema: p.Id, effect: p.Id) bool {
        const relative = self.data().relative orelse return true;
        const disposal = relative.disposal orelse return true;
        return disposal.contains(schema, @intCast(effect));
    }
    /// Disposal can execute protected cleanup even when its escaping effect
    /// row is empty. Use the owned-value traversal and admitted obligation bit,
    /// not effect membership, for an arbitrary interaction projection.
    pub fn mayRunDisposal(self: *const Analysis, schema: p.Id) Error!bool {
        const stored: *Storage = @ptrCast(@alignCast(@constCast(self)));
        if (stored.disposal_query == null) stored.disposal_query = try DisposalExecution.derive(stored.allocator, stored.image);
        return stored.disposal_query.?.contains(schema);
    }
    /// Instantiate this immutable constructor's suspension summary with its
    /// concrete environment and supplied arguments. These are formal input
    /// ordinals, not activation slots or all capabilities retained by a value.
    pub fn constructorSources(self: *const Analysis, constructor: p.Id, effect: p.Id) Error!InvocationSources {
        const stored = self.data();
        const relative = stored.relative orelse return .{ .conservative = true };
        const function = stored.image.constructors[@intCast(constructor)].function;
        var result: InvocationSources = .{};
        var inputs: std.ArrayList(p.Id) = .empty;
        var iterator = relative.origins.iterator(relative.suspensions[@intCast(function)][@intCast(effect)]);
        while (iterator.next()) |origin| switch (origin) {
            .input => |input| try inputs.append(stored.allocator, @intCast(input)),
            .environmental => {},
            else => result.conservative = true,
        };
        result.inputs = try inputs.toOwnedSlice(stored.allocator);
        return result;
    }
    /// Position summaries retain an awaited result as a separate source. The
    /// validated saved child, not stale caller arguments, supplies its origins.
    pub fn suspensionSources(self: *const Analysis, block: p.Id, position: usize, returned: bool, effect: p.Id) Error!SuspensionSources {
        return (try self.positionSources(block, position, returned)).effects[@intCast(effect)];
    }
    pub fn returnSources(self: *const Analysis, block: p.Id, position: usize, returned: bool) Error!SuspensionSources {
        return (try self.positionSources(block, position, returned)).returns;
    }
    fn positionSources(self: *const Analysis, block: p.Id, position: usize, returned: bool) Error!PositionSources {
        const stored: *Storage = @ptrCast(@alignCast(@constCast(self)));
        for (stored.positions.items) |query| if (query.block == block and query.position == position and query.returned == returned)
            return query;
        const effects = try stored.allocator.alloc(SuspensionSources, stored.image.effects.len);
        var result: PositionSources = .{ .block = block, .position = position, .returned = returned, .effects = effects, .returns = .{ .conservative = true } };
        if (stored.relative) |relative| {
            const query = try relative.fromPosition(block, position, returned);
            for (query.suspensions, effects) |summary, *sources|
                sources.* = try positionSource(stored, relative, summary);
            result.returns = try positionSource(stored, relative, query.returns);
        } else @memset(effects, .{ .conservative = true });
        try stored.positions.append(stored.allocator, result);
        return result;
    }
    fn positionSource(stored: *Storage, relative: *const Values, summary: Set) Error!SuspensionSources {
        var sources: SuspensionSources = .{};
        var slots: std.ArrayList(p.Id) = .empty;
        var iterator = relative.origins.iterator(summary);
        while (iterator.next()) |origin| switch (origin) {
            .input => |slot| try slots.append(stored.allocator, slot),
            .returned => sources.pending_return = true,
            .environmental => {},
            else => sources.conservative = true,
        };
        sources.slots = try slots.toOwnedSlice(stored.allocator);
        return sources;
    }
    pub fn capturesRegion(self: *const Analysis, boundary: Boundary, effects: []const p.Id, region: p.Id) Error!void {
        for (try self.effectRow(boundary, effects)) |effect| try self.captureRegion(boundary, effect, region);
    }
    fn captureRegion(self: *const Analysis, boundary: Boundary, effect: p.Id, region: p.Id) Error!void {
        for (self.targets(boundary, effect)) |target| {
            if (!target.retains) continue;
            const signature = try contracts.resumption(self.data().image, target.resumption);
            if (std.mem.indexOfScalar(p.Id, signature.owned_regions, region) == null) return error.InvalidOwnership;
        }
    }
    pub fn capturesCleanup(self: *const Analysis, boundary: Boundary, effects: []const p.Id) Error!void {
        for (try self.effectRow(boundary, effects)) |effect| try self.captureCleanup(boundary, effect);
    }
    fn captureCleanup(self: *const Analysis, boundary: Boundary, effect: p.Id) Error!void {
        // Intrinsic multi-shot prohibition is independent of relevance.
        if (self.data().image.effects[@intCast(effect)].control_use == .multi) return error.InvalidOwnership;
        for (self.targets(boundary, effect)) |target|
            if (!(try contracts.resumption(self.data().image, target.resumption)).obligations) return error.InvalidOwnership;
    }
    /// An injected closure can dispose owned captures before the saved body
    /// resumes. Additional effects must cover that body's retained state too,
    /// not just the continuation outside resume_computation.
    pub fn capturesInjected(self: *const Analysis, boundary: Boundary, token: p.ResumptionType, uses: @import("traits.zig").Facts) Error!void {
        const admitted = self.data().image.effects[@intCast(token.effect)].use_site_effects;
        for (try self.effectRow(boundary, admitted)) |effect| {
            // Declared injection effects were checked when the token captured
            // its continuation. Its broader resume row is not that witness.
            if (contracts.containsEffect(admitted, effect)) continue;
            const selected = try self.select(boundary, effect);
            for (token.capture_bound) |schema| if (!try selected.captureAllowed(uses, schema)) return error.InvalidOwnership;
            for (token.owned_regions) |region| try self.captureRegion(boundary, effect, region);
            if (token.obligations) try self.captureCleanup(boundary, effect);
        }
    }
    /// After ordinary graph/type/custody admission, qualify concrete values
    /// against the same abstract bindings that justified reduced target sets.
    /// Restoring bytes is a second constructor of execution state; schema
    /// equality alone cannot establish this relation.
    pub fn validateState(self: *const Analysis, allocator: std.mem.Allocator, nodes: []const @import("graph.zig").Node, activations: []const ?@import("process_state.zig").Activation) Error!void {
        const values = self.data().values orelse return;
        const g = @import("graph.zig");
        const Pending = struct { value: g.Value, allowed: Set };
        var pending: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(struct { node: p.Id, allowed: Set }, void) = .empty;
        for (nodes, activations) |node, activation| {
            if (activation) |frame| {
                const block = if (node == .control) node.control.block else node.continuation.source_block;
                const row = try values.at(allocator, @intCast(block), @intCast(frame.position));
                for (frame.bindings) |binding| try pending.append(allocator, .{ .value = binding.value, .allowed = row.get(@intCast(binding.slot)) });
            }
            if (node == .computation) {
                const closure = node.computation;
                const fields = nodes[@intCast(closure.environment.id)].environment.values;
                for (fields, values.captures[@intCast(closure.constructor)]) |value, allowed|
                    try pending.append(allocator, .{ .value = value, .allowed = allowed });
            }
        }
        while (pending.pop()) |item| {
            const allowed = item.allowed;
            if (values.origins.contains(allowed, .unknown)) continue;
            const ref = switch (item.value.body) {
                .reference => |ref| ref,
                .owned => |owned| owned.node,
                .scalar, .blob => continue,
            };
            const node = nodes[@intCast(ref.id)];
            if (node == .attachment) {
                const definition = nodes[@intCast(node.attachment.handler.id)].handler.definition;
                if (!values.receives(allowed, definition)) return error.InvalidOwnership;
                continue;
            }
            if ((try seen.getOrPut(allocator, .{ .node = ref.id, .allowed = item.allowed })).found_existing) continue;
            switch (node) {
                .computation => |closure| if (!values.origins.contains(allowed, .{ .constructor = closure.constructor })) return error.InvalidOwnership,
                .aggregate => |aggregate| for (aggregate.fields) |field| {
                    try pending.append(allocator, .{ .value = field, .allowed = item.allowed });
                },
                .resource => |resource| try pending.append(allocator, .{ .value = resource.value, .allowed = item.allowed }),
                .package => |package| try pending.append(allocator, .{ .value = package.continuation, .allowed = item.allowed }),
                .one_shot, .multi_template => |token| {
                    const attachment = nodes[@intCast(token.delimiter.id)].attachment;
                    const definition = nodes[@intCast(attachment.handler.id)].handler.definition;
                    // A token names the receiving clause's delimiter at capture.
                    // Successors belong to fresh resumed views, not the template.
                    if (!values.origins.contains(allowed, .{ .resumption = definition })) return error.InvalidOwnership;
                },
                // These opaque/mutable values have conservative transfers. Their
                // concrete capture, lifetime and cleanup checks remain mandatory.
                else => {},
            }
        }
    }
};

/// The invocation allocator owns all facts; callers keep the input immutable
/// for their complete lifetime. Open components retain conservative uncertainty.
pub fn derive(allocator: std.mem.Allocator, image: ir.Program, imports: []const p.Id, component: bool) Error!*const Analysis {
    return deriveObserved(allocator, image, imports, component, false);
}

pub fn deriveObserved(allocator: std.mem.Allocator, image: ir.Program, imports: []const p.Id, component: bool, explanations: bool) Error!*const Analysis {
    const stored = try allocator.create(Storage);
    stored.* = .{ .allocator = allocator, .image = image, .conservative = try allocator.alloc([]const Target, image.effects.len), .operations = try allocator.alloc(?[]const Target, image.blocks.len), .calls = try allocator.alloc([]const CallTargets, image.blocks.len) };
    @memset(stored.operations, null);
    @memset(stored.calls, &.{});
    for (image.blocks, 0..) |block, id| if (block.terminator == .perform and block.terminator.perform.capability == null) {
        stored.operations[id] = &.{};
    };
    for (stored.conservative, 0..) |*row, effect| {
        var targets: std.ArrayList(Target) = .empty;
        for (image.handlers, 0..) |handler, handler_id| for (handler.clauses, 0..) |clause, index| {
            if (clause.effect != effect) continue;
            try targets.append(allocator, .{ .handler = handler_id, .clause = index, .effect = effect, .function = clause.function, .resumption = clause.resumption, .retains = contracts.retainsResumption(clause) });
        };
        row.* = try targets.toOwnedSlice(allocator);
    }
    if (!component and imports.len == 0 and image.handlers.len != 0) {
        const origins = try Origins.init(allocator, image);
        var flow = try Values.init(allocator, image, origins, false);
        if (explanations) flow.seeds = try allocator.dupe(Row, flow.entries);
        try flow.solve();
        const concrete = try allocator.create(Values);
        concrete.* = flow;
        stored.values = concrete;
        for (image.blocks, 0..) |block, id| if (block.terminator == .perform) {
            const op = block.terminator.perform;
            if (op.capability == null) {
                stored.operations[id] = &.{}; // Environmental, never nearest-handler dispatch.
                continue;
            }
            const targets = flow.exits[id].get(@intCast(op.capability.?));
            if (targets == empty or origins.contains(targets, .unknown)) continue;
            var selected: std.ArrayList(Target) = .empty;
            for (stored.conservative[@intCast(op.effect)]) |target| {
                if (flow.receives(targets, target.handler)) try selected.append(allocator, target);
            }
            stored.operations[id] = try selected.toOwnedSlice(allocator);
        };
        var relative = try Values.init(allocator, image, origins, true);
        try relative.solve();
        const retained_relative = try allocator.create(Values);
        retained_relative.* = relative;
        stored.relative = retained_relative;
        for (image.blocks, 0..) |block, id| if (block.terminator == .call) {
            const call = block.terminator.call;
            var rows: std.ArrayList(CallTargets) = .empty;
            for (image.effects, 0..) |_, effect| {
                if (!contracts.containsEffect(image.functions[@intCast(call.function)].effects, effect) and relative.suspensions[@intCast(call.function)][effect] == empty) continue;
                const actual = try origins.substitute(relative.suspensions[@intCast(call.function)][@intCast(effect)], call.arguments, flow.exits[id]);
                if (origins.contains(actual, .unknown)) {
                    try rows.append(allocator, .{ .effect = effect, .targets = null });
                    continue;
                }
                var selected: std.ArrayList(Target) = .empty;
                for (stored.conservative[@intCast(effect)]) |target|
                    if (flow.receives(actual, target.handler)) try selected.append(allocator, target);
                try rows.append(allocator, .{ .effect = effect, .targets = try selected.toOwnedSlice(allocator), .environmental = origins.contains(actual, .environmental) });
            }
            stored.calls[id] = try rows.toOwnedSlice(allocator);
        };
        for (image.blocks, 0..) |block, id| {
            var rows: std.ArrayList(CallTargets) = .empty;
            switch (block.terminator) {
                .apply => |v| try closureTargets(stored, &flow, &relative, &rows, id, .callee, v.computation, v.arguments, 0, null),
                .handle => |v| {
                    try closureTargets(stored, &flow, &relative, &rows, id, .body, v.body, v.arguments, image.handlers[@intCast(v.handler)].clauses.len, v.handler);
                    try handlerTargets(stored, &relative, &rows, v.handler);
                },
                .resume_value, .dispose => {},
                .resume_with => |v| try handlerTargets(stored, &relative, &rows, v.handler),
                .resume_computation => |v| {
                    const slots = image.functions[@intCast(block.function)].layout.slots;
                    const thunk = try contracts.computation(image, slots[@intCast(v.computation)]);
                    const token = try contracts.resumption(image, slots[@intCast(v.resumption)]);
                    var injected: std.ArrayList(CallTargets) = .empty;
                    try closureTargets(stored, &flow, &relative, &injected, id, .injected, v.computation, &.{}, thunk.parameters.len, null);
                    // The token's ordinary execution keeps its conservative
                    // recipients. Injection can add disposal effects outside
                    // that row without replacing any of those recipients.
                    for (injected.items) |row| {
                        try rows.append(allocator, row);
                        if (!contracts.containsEffect(token.effects, row.effect)) {
                            var resumed = row;
                            resumed.role = .resumed;
                            try rows.append(allocator, resumed);
                        }
                    }
                },
                .with_region => |v| try closureTargets(stored, &flow, &relative, &rows, id, .body, v.body, v.arguments, 1, null),
                .protect => |v| {
                    try closureTargets(stored, &flow, &relative, &rows, id, .body, v.body, v.arguments, @intFromBool(v.resource != null), null);
                    try closureTargets(stored, &flow, &relative, &rows, id, .cleanup, v.cleanup, &.{}, 1 + @as(usize, @intFromBool(v.resource != null)), null);
                },
                else => continue,
            }
            try resumptionTargets(stored, &relative, &rows, block);
            stored.calls[id] = try rows.toOwnedSlice(allocator);
        }
    }
    return @ptrCast(stored);
}

fn resumptionTargets(stored: *Storage, relative: *const Values, rows: *std.ArrayList(CallTargets), block: ir.Block) Error!void {
    const slot = switch (block.terminator) {
        inline .resume_value, .resume_computation, .resume_with => |v| v.resumption,
        .dispose => |v| v.owned,
        else => return,
    };
    const schema = stored.image.functions[@intCast(block.function)].layout.slots[@intCast(slot)];
    const signature = try contracts.resumption(stored.image, schema);
    for (stored.image.effects, 0..) |_, effect| {
        if (contracts.containsEffect(signature.effects, effect) or !relative.disposal.?.contains(schema, effect)) continue;
        var present = false;
        for (rows.items) |*row| {
            if (row.role != .resumed or row.effect != effect) continue;
            // A closure's known origin cannot restrict separate captured
            // values whose cleanup may run during disposal or cancellation.
            row.targets = null;
            row.environmental = false;
            present = true;
            break;
        }
        if (!present) try rows.append(stored.allocator, .{ .role = .resumed, .effect = effect, .targets = null });
    }
}

fn handlerTargets(stored: *Storage, relative: *const Values, rows: *std.ArrayList(CallTargets), id: p.Id) Error!void {
    const handler = stored.image.handlers[@intCast(id)];
    for (stored.image.effects, 0..) |_, effect| {
        if (contracts.containsEffect(handler.effects, effect)) continue;
        var possible = relative.suspensions[@intCast(handler.return_function)][effect] != empty;
        for (handler.clauses) |clause| possible = possible or relative.suspensions[@intCast(clause.function)][effect] != empty;
        if (possible) try rows.append(stored.allocator, .{ .role = .handler, .effect = effect, .targets = null });
    }
}

fn closureTargets(stored: *Storage, flow: *const Values, relative: *const Values, rows: *std.ArrayList(CallTargets), block: usize, role: Role, slot: p.Id, arguments: []const p.Id, supplied: usize, installed: ?p.Id) Error!void {
    const values = flow.exits[block];
    const origin_set = values.get(@intCast(slot));
    const origins = flow.origins;
    const image = stored.image;
    const schema = image.functions[@intCast(image.blocks[block].function)].layout.slots[@intCast(slot)];
    const signature = try contracts.computation(image, schema);
    for (image.effects, 0..) |_, effect| {
        var possible = contracts.containsEffect(signature.effects, effect);
        for (image.constructors) |constructor| {
            if (constructor.schema == schema and relative.suspensions[@intCast(constructor.function)][effect] != empty) possible = true;
        }
        if (!possible) continue;
        if (origin_set == empty or origins.contains(origin_set, .unknown)) {
            try rows.append(stored.allocator, .{ .role = role, .effect = effect, .targets = null });
            continue;
        }
        var actual: Set = empty;
        var found = false;
        for (image.constructors, 0..) |constructor, id| {
            if (constructor.schema != schema or !origins.contains(origin_set, .{ .constructor = id })) continue;
            found = true;
            const captures = flow.captures[id];
            var iter = origins.iterator(relative.suspensions[@intCast(constructor.function)][@intCast(effect)]);
            while (iter.next()) |origin| {
                if (origin == .environmental) {
                    actual = try origins.unite(actual, try origins.one(.environmental));
                    continue;
                }
                var source = try origins.one(.unknown);
                if (origin == .input) {
                    const index = origin.input;
                    if (index < captures.len) {
                        source = captures[index];
                    } else if (index < captures.len + supplied) {
                        // Only these formal parameters are supplied by this fresh
                        // installation. Captured outer capabilities with the same
                        // abstract handler ID are deliberately not discharged.
                        if (installed != null) continue;
                    } else source = values.get(@intCast(arguments[index - captures.len - supplied]));
                }
                actual = try origins.unite(actual, source);
            }
        }
        if (!found or origins.contains(actual, .unknown)) {
            try rows.append(stored.allocator, .{ .role = role, .effect = effect, .targets = null });
            continue;
        }
        if (actual == empty and !contracts.containsEffect(signature.effects, effect)) continue;
        var selected: std.ArrayList(Target) = .empty;
        for (stored.conservative[@intCast(effect)]) |target|
            if (flow.receives(actual, target.handler)) try selected.append(stored.allocator, target);
        try rows.append(stored.allocator, .{ .role = role, .effect = effect, .targets = try selected.toOwnedSlice(stored.allocator), .environmental = origins.contains(actual, .environmental) });
    }
}

// A deliberately finite value abstraction: aggregate members share a union,
// closure environments have one row per constructor, and mutable/opaque reads
// are unknown. No type equality establishes a capability's recipient.
// The same transfer computes input-relative return/suspension summaries. Direct
// calls and known closure boundaries instantiate them. Unrepresented saved
// contexts retain the conservative upper bound.
const Origin = union(enum) { unknown, environmental, returned, handler: p.Id, resumption: p.Id, constructor: p.Id, input: usize };
const set_pool = @import("analysis_sets.zig");
const Set = set_pool.Root;
const empty = set_pool.empty;

// Disjoint finite ranges retain every origin distinction. Rows hold canonical
// roots, so copying a slot never copies or allocates its origin membership.
const Origins = struct {
    pool: set_pool.Pool,
    resumptions: u64,
    constructors: u64,
    inputs: u64,

    fn init(allocator: std.mem.Allocator, image: ir.Program) Error!*Origins {
        const resumptions = std.math.add(u64, 3, image.handlers.len) catch return error.Capacity;
        const constructors = std.math.add(u64, resumptions, image.handlers.len) catch return error.Capacity;
        const inputs = std.math.add(u64, constructors, image.constructors.len) catch return error.Capacity;
        var count: usize = 0;
        for (image.functions) |function| count = @max(count, function.layout.slots.len);
        const limit = std.math.add(u64, inputs, count) catch return error.Capacity;
        const self = try allocator.create(Origins);
        self.* = .{ .pool = .{ .allocator = allocator, .limit = limit }, .resumptions = resumptions, .constructors = constructors, .inputs = inputs };
        return self;
    }
    fn member(self: *const Origins, value: Origin) u64 {
        return switch (value) {
            .unknown => 0,
            .environmental => 1,
            .returned => 2,
            .handler => |id| 3 + id,
            .resumption => |id| self.resumptions + id,
            .constructor => |id| self.constructors + id,
            .input => |id| self.inputs + id,
        };
    }
    fn origin(self: *const Origins, id: u64) Origin {
        if (id == 0) return .unknown;
        if (id == 1) return .environmental;
        if (id == 2) return .returned;
        if (id < self.resumptions) return .{ .handler = id - 3 };
        if (id < self.constructors) return .{ .resumption = id - self.resumptions };
        if (id < self.inputs) return .{ .constructor = id - self.constructors };
        return .{ .input = @intCast(id - self.inputs) };
    }
    fn one(self: *Origins, value: Origin) Error!Set {
        return self.pool.insert(empty, self.member(value));
    }
    fn contains(self: *const Origins, set: Set, value: Origin) bool {
        return self.pool.contains(set, self.member(value));
    }
    fn unite(self: *Origins, left: Set, right: Set) Error!Set {
        return self.pool.unite(left, right);
    }
    const Iterator = struct {
        owner: *const Origins,
        members: set_pool.Iterator,
        fn next(self: *Iterator) ?Origin {
            return self.owner.origin(self.members.next() orelse return null);
        }
    };
    fn iterator(self: *const Origins, set: Set) Iterator {
        return .{ .owner = self, .members = self.pool.iterator(set) };
    }
    fn substitute(self: *Origins, summary: Set, arguments: []const p.Id, values: Row) Error!Set {
        var result: Set = empty;
        var iter = self.iterator(summary);
        while (iter.next()) |value| {
            const source = if (value == .input) values.get(@intCast(arguments[value.input])) else try self.one(value);
            result = try self.unite(result, source);
        }
        return result;
    }
};

// Immutable slot vectors share unchanged ranges across predecessor copies.
// Splits follow the finite slot interval, so lookup and update depth are bounded
// by the machine index width, not the number of predecessor versions.
const Row = struct {
    len: usize,
    root: View = .{ .uniform = empty },
    const Pair = struct { left: View, right: View };
    const View = union(enum) { uniform: Set, split: *const Pair };

    fn get(self: Row, index: usize) Set {
        std.debug.assert(index < self.len);
        var view = self.root;
        var offset = index;
        var length = self.len;
        while (view == .split) {
            const middle = length / 2;
            if (offset < middle) {
                view = view.split.left;
                length = middle;
            } else {
                view = view.split.right;
                offset -= middle;
                length -= middle;
            }
        }
        return view.uniform;
    }
    fn updated(allocator: std.mem.Allocator, view: View, length: usize, index: usize, value: Set) Error!View {
        if (view == .uniform and view.uniform == value) return view;
        if (length == 1) return .{ .uniform = value };
        const middle = length / 2;
        var left = if (view == .split) view.split.left else view;
        var right = if (view == .split) view.split.right else view;
        if (index < middle) {
            left = try updated(allocator, left, middle, index, value);
        } else {
            right = try updated(allocator, right, length - middle, index - middle, value);
        }
        if (left == .uniform and right == .uniform and left.uniform == right.uniform) return left;
        const pair = try allocator.create(Pair);
        pair.* = .{ .left = left, .right = right };
        return .{ .split = pair };
    }
    fn set(self: *Row, allocator: std.mem.Allocator, index: usize, value: Set) Error!void {
        std.debug.assert(index < self.len);
        if (self.get(index) == value) return;
        self.root = try updated(allocator, self.root, self.len, index, value);
    }
    fn same(left: View, right: View) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .uniform => |value| value == right.uniform,
            .split => |pair| pair == right.split,
        };
    }
    fn merged(allocator: std.mem.Allocator, pool: *set_pool.Pool, left: View, right: View) Error!View {
        if (same(left, right) or (right == .uniform and right.uniform == empty)) return left;
        if (left == .uniform and left.uniform == empty) return right;
        if (left == .uniform and right == .uniform) return .{ .uniform = try pool.unite(left.uniform, right.uniform) };
        const lower = try merged(allocator, pool, if (left == .split) left.split.left else left, if (right == .split) right.split.left else right);
        const upper = try merged(allocator, pool, if (left == .split) left.split.right else left, if (right == .split) right.split.right else right);
        if (lower == .uniform and upper == .uniform and lower.uniform == upper.uniform) return lower;
        if (left == .split and same(lower, left.split.left) and same(upper, left.split.right)) return left;
        if (right == .split and same(lower, right.split.left) and same(upper, right.split.right)) return right;
        const pair = try allocator.create(Pair);
        pair.* = .{ .left = lower, .right = upper };
        return .{ .split = pair };
    }
    fn join(self: *Row, allocator: std.mem.Allocator, pool: *set_pool.Pool, source: Row) Error!bool {
        std.debug.assert(self.len == source.len);
        const joined = try merged(allocator, pool, self.root, source.root);
        const changed = !same(joined, self.root);
        self.root = joined;
        return changed;
    }
    fn copyFrom(self: *Row, source: Row) void {
        std.debug.assert(self.len == source.len);
        self.root = source.root;
    }
};

// The oracle is an ordinary dense vector, independent of shared tree updates.
test "control provenance slot rows preserve exact values and independent copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var row: Row = .{ .len = 64 };
    var copied: Row = .{ .len = 64 };
    var dense: [64]Set = @splat(empty);
    var seed: u64 = 37;
    for (0..2048) |round| {
        seed = seed *% 6364136223846793005 +% 1;
        const index: usize = @intCast((seed >> 32) % dense.len);
        const value: Set = @intCast((seed >> 48) % 5);
        try row.set(allocator, index, value);
        dense[index] = value;
        for (dense, 0..) |expected, slot| try std.testing.expectEqual(expected, row.get(slot));
        if (round % 31 == 0) {
            copied.copyFrom(row);
            try row.set(allocator, index, empty);
            for (dense, 0..) |expected, slot| try std.testing.expectEqual(expected, copied.get(slot));
            dense[index] = empty;
        }
    }
    for (0..dense.len) |index| try row.set(allocator, index, 3);
    try std.testing.expect(row.root == .uniform);
    try std.testing.expectEqual(3, row.root.uniform);
}

test "control provenance row joins agree with dense unions and retain prior views" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var pool: set_pool.Pool = .{ .allocator = allocator, .limit = 8 };
    for ([_]usize{ 1, 7, 33, 64 }) |length| {
        var left: Row = .{ .len = length };
        var right: Row = .{ .len = length };
        var expected: [64]u64 = @splat(0);
        for (0..length) |slot| {
            const a = try pool.run(slot % 8, slot % 8 + 1);
            const b = try pool.run((slot * 3) % 8, (slot * 3) % 8 + 1);
            try left.set(allocator, slot, a);
            if (slot % 3 != 0) try right.set(allocator, slot, b);
            expected[slot] = pool.lowWord(a) | (if (slot % 3 != 0) pool.lowWord(b) else @as(u64, 0));
        }
        const saved = left;
        _ = try left.join(allocator, &pool, right);
        for (0..length) |slot| {
            try std.testing.expectEqual(expected[slot], pool.lowWord(left.get(slot)));
            try std.testing.expectEqual(@as(u64, 1) << @intCast(slot % 8), pool.lowWord(saved.get(slot)));
        }
        try std.testing.expect(!try left.join(allocator, &pool, right));
        var copied: Row = .{ .len = length };
        _ = try copied.join(allocator, &pool, left);
        try std.testing.expect(Row.same(left.root, copied.root));
    }
}

test "position suspension sources distinguish a suffix from its full-block backedge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const image: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{ .unit, .boolean, .{ .internal = .{ .capability = 0 } } },
        .constants = &.{},
        .effects = &.{.{ .identity = "position/source", .payload = 0, .result = 0 }},
        .functions = &.{.{ .entry = 0, .inputs = &.{ 0, 1, 2, 3 }, .layout = .{ .slots = &.{ 2, 2, 1, 0 } }, .result = 0, .effects = &.{0} }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{.{ .opcode = .move, .destination = 0, .operands = &.{1} }}, .terminator = .{ .perform = .{ .effect = 0, .capability = 0, .payload = 3, .next = .{ .block = 1 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{ .condition = 2, .when_true = .{ .block = 0 }, .when_false = .{ .block = 2 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        },
    };
    const origins = try Origins.init(allocator, image);
    var relative = try Values.init(allocator, image, origins, true);
    try relative.solve();
    const before = try relative.fromPosition(0, 0, false);
    const after = try relative.fromPosition(0, 1, false);
    const returned = try relative.fromPosition(0, 1, true);
    const input0 = try origins.one(.{ .input = 0 });
    const input1 = try origins.one(.{ .input = 1 });
    try std.testing.expectEqual(input1, before.suspensions[0]);
    try std.testing.expectEqual(try origins.unite(input0, input1), after.suspensions[0]);
    try std.testing.expectEqual(input1, returned.suspensions[0]);
}

test "position suspension sources substitute callee inputs and preserve an awaited delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const image: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{ .unit, .{ .internal = .{ .capability = 0 } } },
        .constants = &.{},
        .effects = &.{.{ .identity = "position/delivery", .payload = 0, .result = 0 }},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{ 0, 1, 2 }, .layout = .{ .slots = &.{ 1, 1, 0 } }, .result = 0, .effects = &.{0} },
            .{ .entry = 3, .inputs = &.{ 1, 0, 2 }, .layout = .{ .slots = &.{ 1, 1, 0 } }, .result = 1, .effects = &.{0} },
        },
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{ .function = 1, .arguments = &.{ 1, 0, 2 }, .next = .{ .block = 1, .assignments = &.{.{ .destination = 0, .source = .returned }} } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .capability = 0, .payload = 2, .next = .{ .block = 2 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
            .{ .function = 1, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .capability = 0, .payload = 2, .next = .{ .block = 4 } } } },
            .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        },
    };
    const origins = try Origins.init(allocator, image);
    var relative = try Values.init(allocator, image, origins, true);
    try relative.solve();
    try std.testing.expectEqual(try origins.one(.{ .input = 0 }), (try relative.fromPosition(0, 0, false)).suspensions[0]);
    try std.testing.expectEqual(try origins.one(.returned), (try relative.fromPosition(0, 0, true)).suspensions[0]);
}

/// The schema projection of Kosmos's owned-value disposal traversal. Copied
/// capabilities, cells and resources do not invoke user code when discarded;
/// containers recurse into owned contents and one-shot captures run cleanup.
const DisposalExecution = struct {
    bits: []bool,
    fn contains(self: DisposalExecution, schema: p.Id) bool {
        return self.bits[@intCast(schema)];
    }
    fn any(self: DisposalExecution, schemas: []const p.Id) bool {
        for (schemas) |schema| if (self.contains(schema)) return true;
        return false;
    }
    fn derive(allocator: std.mem.Allocator, image: ir.Program) Error!DisposalExecution {
        const result: DisposalExecution = .{ .bits = try allocator.alloc(bool, image.schemas.len) };
        @memset(result.bits, false);
        var changed = true;
        while (changed) {
            changed = false;
            for (image.schemas, 0..) |schema, id| {
                if (result.bits[id]) continue;
                const present = switch (schema) {
                    .product, .sum => |fields| result.any(fields),
                    .seq => |element| result.contains(element),
                    inline .vector, .array => |value| result.contains(value.element),
                    .internal => |internal| switch (internal) {
                        .computation => |value| result.any(value.capture_bound),
                        .suspension_package => |token| result.contains(token),
                        // Admission requires this bit whenever a capture retains
                        // protection. Other owned captured values recurse even
                        // without a directly retained protection frame.
                        .resumption => |value| value.use != .multi and (value.obligations or result.any(value.capture_bound)),
                        .capability, .cell, .region, .abstract_resource, .borrowed => false,
                    },
                    .unit, .boolean, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .bytes, .text, .bounded_bytes, .bounded_text, .enumeration => false,
                };
                if (present) {
                    result.bits[id] = true;
                    changed = true;
                }
            }
        }
        return result;
    }
};
const DisposalEffects = struct {
    bits: []bool,
    width: usize,

    fn contains(self: DisposalEffects, schema: p.Id, effect: usize) bool {
        return self.bits[@as(usize, @intCast(schema)) * self.width + effect];
    }
    fn any(self: DisposalEffects, schemas: []const p.Id, effect: usize) bool {
        for (schemas) |schema| if (self.contains(schema, effect)) return true;
        return false;
    }
    fn derive(allocator: std.mem.Allocator, image: ir.Program) Error!DisposalEffects {
        // First overapproximate every nested disposal. Local discharge must be
        // proved against that relation, never against its own masked result.
        const unmasked = try solve(allocator, image, null);
        const local = try allocator.alloc(bool, unmasked.bits.len);
        @memset(local, true);
        const produced = try allocator.alloc(bool, image.schemas.len);
        @memset(produced, false);
        const scope = try @import("effect_scope.zig").derive(allocator, image);
        for (image.functions) |function| if (function.entry == @import("relocation.zig").missing)
            @memset(local, false);
        for (image.blocks) |block| switch (block.terminator) {
            .handle => |handle| {
                const handler = image.handlers[@intCast(handle.handler)];
                const slots = image.functions[@intCast(block.function)].layout.slots;
                const body = try contracts.computation(image, slots[@intCast(handle.body)]);
                for (handler.clauses) |clause| {
                    produced[@intCast(clause.resumption)] = true;
                    for (image.effects, 0..) |_, effect| {
                        var confined = @import("effect_scope.zig").discharged(image, scope, handler, body, effect);
                        for (body.capture_bound) |schema| confined = confined and !unmasked.contains(schema, effect);
                        for (body.parameters[handler.clauses.len..]) |schema| confined = confined and !unmasked.contains(schema, effect);
                        for (handler.state) |schema| confined = confined and !scope.contains(schema, effect) and !unmasked.contains(schema, effect);
                        local[@as(usize, @intCast(clause.resumption)) * unmasked.width + effect] =
                            local[@as(usize, @intCast(clause.resumption)) * unmasked.width + effect] and confined;
                    }
                }
            },
            // A successor receives an existing capture, not a fresh body's
            // correlated capability parameters.
            .resume_with => |resume_| for (image.handlers[@intCast(resume_.handler)].clauses) |clause| {
                for (image.effects, 0..) |_, effect| local[@as(usize, @intCast(clause.resumption)) * unmasked.width + effect] = false;
            },
            else => {},
        };
        for (produced, 0..) |known, schema| if (!known) {
            for (image.effects, 0..) |_, effect| local[schema * unmasked.width + effect] = false;
        };
        return solve(allocator, image, local);
    }
    fn solve(allocator: std.mem.Allocator, image: ir.Program, local: ?[]const bool) Error!DisposalEffects {
        const result: DisposalEffects = .{
            .bits = try allocator.alloc(bool, std.math.mul(usize, image.schemas.len, image.effects.len) catch return error.Capacity),
            .width = image.effects.len,
        };
        @memset(result.bits, false);
        var changed = true;
        while (changed) {
            changed = false;
            for (image.schemas, 0..) |schema, id| for (image.effects, 0..) |_, effect| {
                const index = id * result.width + effect;
                if (result.bits[index]) continue;
                const present = switch (schema) {
                    .product, .sum => |fields| result.any(fields, effect),
                    .seq => |element| result.contains(element, effect),
                    .vector => |v| result.contains(v.element, effect),
                    .array => |v| result.contains(v.element, effect),
                    .internal => |internal| switch (internal) {
                        .computation => |v| result.any(v.capture_bound, effect),
                        .suspension_package => |v| result.contains(v, effect),
                        .resumption => |v| blk: {
                            if (v.use == .multi) break :blk false;
                            const escapes = !contracts.containsEffect(v.handled, effect) or contracts.containsEffect(v.escaping, effect);
                            // A deep token lists same-family effects only when
                            // they can select outside its own delimiter. Shallow
                            // rows also list local effects, so require escaping.
                            // A nested token retains its own recipient. Mask it
                            // only when every producer proves confinement to the
                            // fresh delimiter, including its owned inputs.
                            const confined = if (local) |facts| facts[index] else false;
                            break :blk (contracts.containsEffect(v.effects, effect) and (v.mode == .deep or escapes)) or
                                ((!confined or escapes) and result.any(v.capture_bound, effect));
                        },
                        .capability, .cell, .region, .abstract_resource, .borrowed => false,
                    },
                    else => false,
                };
                if (present) {
                    result.bits[index] = true;
                    changed = true;
                }
            };
        }
        return result;
    }
};

const Values = struct {
    /// Only requested diagnostics retain input seeds. These distinguish actual
    /// unknown-input introduction from unknown propagated around a cycle.
    seeds: ?[]Row = null,
    disposal: ?DisposalEffects = null,
    allocator: std.mem.Allocator,
    origins: *Origins,
    image: ir.Program,
    entries: []Row,
    exits: []Row,
    returns: []Set,
    captures: [][]Set,
    bindings: [][]bool,
    relative: bool,
    suspensions: [][]Set,
    position_query: ?*PositionQuery = null,
    changed: bool = false,

    const PositionQuery = struct { reachable: []bool, suspensions: []Set, returns: Set = empty };

    fn fromPosition(self: *const Values, start: p.Id, position: usize, returned: bool) Error!PositionQuery {
        const code = self.image.blocks[@intCast(start)];
        var reader = self.*;
        reader.entries = try self.allocator.alloc(Row, self.image.blocks.len);
        reader.exits = try self.allocator.alloc(Row, self.image.blocks.len);
        for (self.image.blocks, reader.entries, reader.exits) |block, *entry_row, *exit_row| {
            entry_row.* = .{ .len = self.image.functions[@intCast(block.function)].layout.slots.len };
            exit_row.* = entry_row.*;
        }
        var query: PositionQuery = .{
            .reachable = try self.allocator.alloc(bool, self.image.blocks.len),
            .suspensions = try sets(self.allocator, self.image.effects.len),
        };
        @memset(query.reachable, false);
        reader.position_query = &query;
        var seed: Row = .{ .len = self.image.functions[@intCast(code.function)].layout.slots.len };
        for (0..seed.len) |slot| try seed.set(self.allocator, slot, try self.origins.one(.{ .input = slot }));
        if (returned) {
            reader.exits[@intCast(start)] = seed;
            switch (code.terminator) {
                inline .call, .perform, .apply, .handle, .resume_value, .resume_with, .resume_computation, .dispose, .protect, .with_region => |v| try reader.edge(@intCast(start), v.next, try self.origins.one(.returned), null),
                else => return error.InvalidReference,
            }
        } else {
            var suffix = code;
            suffix.instructions = code.instructions[position..];
            try reader.transferBlockFrom(@intCast(start), suffix, seed);
        }
        // The initial suffix is distinct from a later backedge to its block:
        // a loop executes that block's full instruction sequence.
        while (true) {
            reader.changed = false;
            for (self.image.blocks, 0..) |block, id| if (query.reachable[id])
                try reader.transferBlock(id, block);
            if (!reader.changed) break;
        }
        return query;
    }

    fn sets(a: std.mem.Allocator, count: usize) Error![]Set {
        const result = try a.alloc(Set, count);
        @memset(result, empty);
        return result;
    }
    fn init(a: std.mem.Allocator, image: ir.Program, origins: *Origins, relative: bool) Error!Values {
        var self: Values = .{ .allocator = a, .origins = origins, .image = image, .entries = try a.alloc(Row, image.blocks.len), .exits = try a.alloc(Row, image.blocks.len), .returns = try sets(a, image.functions.len), .captures = try a.alloc([]Set, image.constructors.len), .bindings = try a.alloc([]bool, image.handlers.len), .relative = relative, .suspensions = try a.alloc([]Set, if (relative) image.functions.len else 0) };
        for (self.bindings, 0..) |*row, id| {
            row.* = try a.alloc(bool, image.handlers.len);
            @memset(row.*, false);
            row.*[id] = true;
        }
        for (image.blocks, 0..) |block, id| {
            const count = image.functions[@intCast(block.function)].layout.slots.len;
            self.entries[id] = .{ .len = count };
            self.exits[id] = .{ .len = count };
        }
        for (image.constructors, 0..) |constructor, id|
            self.captures[id] = try sets(a, image.scopes.captures[@intCast(constructor.capture)].fields.len);
        if (relative) {
            const disposal = try DisposalEffects.derive(a, image);
            self.disposal = disposal;
            for (image.functions, 0..) |function, id| {
                self.suspensions[id] = try sets(a, image.effects.len);
                // Cancellation can discard an owned slot at any execution
                // position. This also covers authored failure and instruction
                // faults without treating a normal terminator as a proof that
                // captured cleanup cannot run. Position queries use concrete
                // state custody separately and do not inherit this whole-layout
                // approximation for their own activation.
                for (function.layout.slots) |schema| for (image.effects, 0..) |_, effect| {
                    if (disposal.contains(schema, effect)) self.suspensions[id][effect] = try origins.one(.unknown);
                };
                for (function.inputs, 0..) |_, index| try self.input(id, index, try origins.one(.{ .input = index }));
            }
            return self;
        }
        try self.unknownInputs(image.roots.entry);
        for (image.handlers, 0..) |handler, handler_id| {
            try self.unknownInputs(handler.return_function);
            for (handler.clauses) |clause| {
                const function = image.functions[@intCast(clause.function)];
                for (function.inputs, 0..) |_, index| {
                    if (contracts.retainsResumption(clause) and index == function.inputs.len - 1) {
                        try self.input(clause.function, index, try origins.one(.{ .resumption = handler_id }));
                    } else try self.input(clause.function, index, try self.origins.one(.unknown));
                }
            }
        }
        return self;
    }
    fn join(self: *Values, into: *Set, source: Set) Error!void {
        const merged = try self.origins.unite(into.*, source);
        if (merged != into.*) {
            into.* = merged;
            self.changed = true;
        }
    }
    fn joinSlot(self: *Values, row: *Row, slot: usize, source: Set) Error!void {
        const original = row.get(slot);
        const merged = try self.origins.unite(original, source);
        if (merged != original) {
            try row.set(self.allocator, slot, merged);
            self.changed = true;
        }
    }
    fn input(self: *Values, function: p.Id, index: usize, value: Set) Error!void {
        const f = self.image.functions[@intCast(function)];
        if (f.entry == @import("relocation.zig").missing) return;
        try self.joinSlot(&self.entries[@intCast(f.entry)], @intCast(f.inputs[index]), value);
    }
    fn unknownInputs(self: *Values, function: p.Id) Error!void {
        for (self.image.functions[@intCast(function)].inputs, 0..) |_, index| try self.input(function, index, try self.origins.one(.unknown));
    }
    fn solve(self: *Values) Error!void {
        try self.converge();
        if (self.relative) return;
        // A declaration without a witnessed binding is not an empty-target
        // proof. Its inputs remain independently checkable under unknown values.
        for (self.image.functions, 0..) |function, id| {
            if (function.entry == @import("relocation.zig").missing) continue;
            for (function.inputs, 0..) |slot, index| {
                if (self.entries[@intCast(function.entry)].get(@intCast(slot)) == empty) {
                    const unknown = try self.origins.one(.unknown);
                    try self.input(id, index, unknown);
                    if (self.seeds) |seeds| try seeds[@intCast(function.entry)].set(self.allocator, @intCast(slot), unknown);
                }
            }
        }
        try self.converge();
        try self.deriveBindings();
    }

    // Each row retains the original binding and every successor reachable from
    // it. This is a may-rebind relation, never a strong update of an allocation
    // site. Distinct branch views can therefore keep independent handlers.
    fn deriveBindings(self: *Values) Error!void {
        for (self.image.blocks, 0..) |block, id| {
            if (block.terminator != .resume_with) continue;
            const operation = block.terminator.resume_with;
            const origins = self.exits[id].get(@intCast(operation.resumption));
            for (self.bindings, 0..) |row, handler_id| {
                if (origins == empty or self.origins.contains(origins, .unknown) or self.origins.contains(origins, .{ .resumption = handler_id }))
                    row[@intCast(operation.handler)] = true;
            }
        }
        // Finite transitive closure: a successor can capture a new token that
        // is itself resumed with another successor. No branch/path IDs grow.
        for (0..self.bindings.len) |via| for (self.bindings) |row| {
            if (row[via]) for (self.bindings[via], 0..) |reachable, destination| {
                row[destination] = row[destination] or reachable;
            };
        };
    }
    fn receives(self: *const Values, origins: Set, handler: p.Id) bool {
        var iter = self.origins.iterator(origins);
        while (iter.next()) |origin| if (origin == .handler and self.bindings[@intCast(origin.handler)][@intCast(handler)]) return true;
        return false;
    }
    fn converge(self: *Values) Error!void {
        while (true) {
            self.changed = false;
            for (self.image.blocks, 0..) |block, id| try self.transferBlock(id, block);
            if (!self.changed) break;
        }
    }
    fn body(self: *Values, block_id: usize, slot: p.Id, arguments: []const p.Id, supplied: usize, handler: ?p.Id) Error!void {
        if (self.relative) return;
        const values = self.exits[block_id];
        const origin_set = values.get(@intCast(slot));
        const schema = self.image.functions[@intCast(self.image.blocks[block_id].function)].layout.slots[@intCast(slot)];
        for (self.image.constructors, 0..) |constructor, id| {
            if (constructor.schema != schema) continue;
            const uncertain = self.origins.contains(origin_set, .unknown);
            if (!self.origins.contains(origin_set, .{ .constructor = id }) and !uncertain) continue;
            for (self.captures[id], 0..) |capture, index| try self.input(constructor.function, index, if (uncertain) try self.origins.one(.unknown) else capture);
            const prefix = self.captures[id].len;
            for (0..supplied) |index| {
                const fresh = try self.origins.one(if (handler) |h| .{ .handler = h } else .unknown);
                try self.input(constructor.function, prefix + index, fresh);
            }
            for (arguments, 0..) |argument, index| try self.input(constructor.function, prefix + supplied + index, values.get(@intCast(argument)));
        }
    }
    fn edge(self: *Values, id: usize, next: ir.Edge, returned: Set, unpack: ?ir.Terminator) Error!void {
        if (self.position_query) |query| if (!query.reachable[@intCast(next.block)]) {
            query.reachable[@intCast(next.block)] = true;
            self.changed = true;
        };
        const source = self.exits[id];
        var incoming = source;
        if (unpack) |term| switch (term) {
            .unpack_product => |v| for (v.destinations) |destination| {
                try incoming.set(self.allocator, @intCast(destination), source.get(@intCast(v.value)));
            },
            else => {},
        };
        // Every assignment reads the same predecessor, including permutations.
        for (next.assignments) |assignment| {
            const value = switch (assignment.source) {
                .slot => |from| if (unpack != null and std.mem.indexOfScalar(p.Id, unpack.?.unpack_product.destinations, from) != null) source.get(@intCast(unpack.?.unpack_product.value)) else source.get(@intCast(from)),
                .returned => returned,
            };
            try incoming.set(self.allocator, @intCast(assignment.destination), value);
        }
        const destination = &self.entries[@intCast(next.block)];
        if (try destination.join(self.allocator, &self.origins.pool, incoming)) self.changed = true;
    }
    fn at(self: *const Values, allocator: std.mem.Allocator, block_id: usize, position: usize) Error!Row {
        var reader = self.*;
        reader.allocator = allocator;
        var row: Row = .{ .len = self.entries[block_id].len };
        row.copyFrom(self.entries[block_id]);
        for (self.image.blocks[block_id].instructions[0..position]) |instruction| try reader.transferInstruction(&row, instruction, false);
        return row;
    }
    fn transferInstruction(self: *Values, values: *Row, instruction: ir.Instruction, record_captures: bool) Error!void {
        var result: Set = empty;
        switch (instruction.opcode) {
            .computation => {
                if (self.relative) {
                    result = try self.origins.one(.unknown);
                } else {
                    if (record_captures) for (instruction.operands, 0..) |operand, index| try self.join(&self.captures[@intCast(instruction.immediate)][index], values.get(@intCast(operand)));
                    result = try self.origins.one(.{ .constructor = instruction.immediate });
                }
            },
            .move, .product, .field, .variant, .variant_payload, .sequence, .sequence_get, .sequence_append, .sequence_concat, .sequence_pop, .sequence_set, .sequence_take, .sequence_pop_last, .resource_pack, .resource_unpack, .clone_resumption, .package, .unpack => {
                for (instruction.operands) |operand| result = try self.origins.unite(result, values.get(@intCast(operand)));
            },
            .select => for (instruction.operands[1..]) |operand| {
                result = try self.origins.unite(result, values.get(@intCast(operand)));
            },
            // Cells and opaque representations deliberately lose precision.
            // Their reads cannot turn an untracked write into an empty set.
            else => result = try self.origins.one(.unknown),
        }
        try values.set(self.allocator, @intCast(instruction.destination), result);
    }
    fn transferBlock(self: *Values, id: usize, block_value: ir.Block) Error!void {
        return self.transferBlockFrom(id, block_value, self.entries[id]);
    }
    fn implicitCallable(self: *Values, summary: []Set, schema: p.Id) Error!void {
        const signature = try contracts.computation(self.image, schema);
        for (self.image.constructors) |constructor| {
            if (constructor.schema != schema) continue;
            for (self.suspensions[@intCast(constructor.function)], 0..) |targets_, effect| {
                if (targets_ != empty and !contracts.containsEffect(signature.effects, effect))
                    try self.join(&summary[effect], try self.origins.one(.unknown));
            }
        }
    }
    fn implicitHandler(self: *Values, summary: []Set, id: p.Id) Error!void {
        const handler = self.image.handlers[@intCast(id)];
        for (self.image.effects, 0..) |_, effect| {
            if (contracts.containsEffect(handler.effects, effect)) continue;
            var possible = self.suspensions[@intCast(handler.return_function)][effect] != empty;
            for (handler.clauses) |clause| possible = possible or self.suspensions[@intCast(clause.function)][effect] != empty;
            if (possible) try self.join(&summary[effect], try self.origins.one(.unknown));
        }
    }
    fn transferBlockFrom(self: *Values, id: usize, block_value: ir.Block, entry_row: Row) Error!void {
        const values = &self.exits[id];
        // Re-evaluate this straight-line transfer from its monotone entry. Exit
        // rows are retained between rounds, but each instruction is a strong
        // assignment within this one activation view.
        values.copyFrom(entry_row);
        for (block_value.instructions) |operation| try self.transferInstruction(values, operation, true);
        const term = block_value.terminator;
        switch (term) {
            .return_value => |slot| if (self.position_query) |query| {
                try self.join(&query.returns, values.get(@intCast(slot)));
            } else try self.join(&self.returns[@intCast(block_value.function)], values.get(@intCast(slot))),
            .call => |v| if (!self.relative) {
                for (v.arguments, 0..) |slot, index| try self.input(v.function, index, values.get(@intCast(slot)));
            },
            .apply => |v| try self.body(id, v.computation, v.arguments, 0, null),
            .handle => |v| try self.body(id, v.body, v.arguments, self.image.handlers[@intCast(v.handler)].clauses.len, v.handler),
            .with_region => |v| try self.body(id, v.body, v.arguments, 1, null),
            .protect => |v| {
                try self.body(id, v.body, v.arguments, @intFromBool(v.resource != null), null);
                try self.body(id, v.cleanup, &.{}, 1 + @as(usize, @intFromBool(v.resource != null)), null);
            },
            .resume_computation => |v| {
                const schema = self.image.functions[@intCast(block_value.function)].layout.slots[@intCast(v.computation)];
                try self.body(id, v.computation, &.{}, (try contracts.computation(self.image, schema)).parameters.len, null);
            },
            .perform => |v| for (v.bodies) |slot| {
                const schema = self.image.functions[@intCast(block_value.function)].layout.slots[@intCast(slot)];
                try self.body(id, slot, &.{}, (try contracts.computation(self.image, schema)).parameters.len, null);
            },
            else => {},
        }
        const returned: Set = if (term == .call)
            (if (self.relative) try self.origins.substitute(self.returns[@intCast(term.call.function)], term.call.arguments, values.*) else self.returns[@intCast(term.call.function)])
        else
            try self.origins.one(.unknown);
        if (self.relative) {
            const summary = if (self.position_query) |query| query.suspensions else self.suspensions[@intCast(block_value.function)];
            switch (term) {
                .perform => |v| {
                    if (v.capability) |slot| {
                        try self.join(&summary[@intCast(v.effect)], values.get(@intCast(slot)));
                    } else try self.join(&summary[@intCast(v.effect)], try self.origins.one(.environmental));
                    for (self.image.effects[@intCast(v.effect)].use_site_effects) |effect| try self.join(&summary[@intCast(effect)], try self.origins.one(.unknown));
                },
                .call => |v| for (self.image.effects, 0..) |_, effect| {
                    const targets = try self.origins.substitute(self.suspensions[@intCast(v.function)][@intCast(effect)], v.arguments, values.*);
                    try self.join(&summary[@intCast(effect)], targets);
                },
                .return_value, .jump, .branch, .switch_variant, .unpack_product, .yield_value, .fail => {},
                else => for (self.image.functions[@intCast(block_value.function)].effects) |effect| {
                    try self.join(&summary[@intCast(effect)], try self.origins.one(.unknown));
                },
            }
            const slots = self.image.functions[@intCast(block_value.function)].layout.slots;
            switch (term) {
                .apply => |v| try self.implicitCallable(summary, slots[@intCast(v.computation)]),
                .handle => |v| {
                    try self.implicitCallable(summary, slots[@intCast(v.body)]);
                    try self.implicitHandler(summary, v.handler);
                },
                .resume_with => |v| try self.implicitHandler(summary, v.handler),
                .with_region => |v| try self.implicitCallable(summary, slots[@intCast(v.body)]),
                .protect => |v| {
                    try self.implicitCallable(summary, slots[@intCast(v.body)]);
                    try self.implicitCallable(summary, slots[@intCast(v.cleanup)]);
                },
                .resume_computation => |v| try self.implicitCallable(summary, slots[@intCast(v.computation)]),
                .perform => |v| for (v.bodies) |slot| try self.implicitCallable(summary, slots[@intCast(slot)]),
                else => {},
            }
        }
        switch (term) {
            .jump, .yield_value => |v| try self.edge(id, v, returned, null),
            .branch => |v| {
                try self.edge(id, v.when_true, returned, null);
                try self.edge(id, v.when_false, returned, null);
            },
            .switch_variant => |v| for (v.cases) |next| {
                try self.edge(id, next, returned, null);
            },
            .unpack_product => |v| try self.edge(id, v.next, returned, term),
            inline .call, .perform, .apply, .handle, .resume_value, .resume_with, .resume_computation, .dispose, .protect, .with_region => |v| try self.edge(id, v.next, returned, null),
            .return_value, .fail => {},
        }
    }
};

// This is a readback of the existing equations. Memoization names static facts,
// not paths, so recursive argument/return dependencies have finite backreferences.
const ExplanationBuilder = struct {
    stored: *const Storage,
    reasons: std.ArrayList(Explanation.Reason) = .empty,
    memo: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    const Key = struct { kind: enum { slot, returned, capture, suspension }, relative: bool = false, a: usize, b: usize = 0, c: usize = 0 };
    const List = std.ArrayList(usize);

    fn add(self: *ExplanationBuilder, reason: Explanation.Reason) Error!usize {
        const id = self.reasons.items.len;
        try self.reasons.append(self.stored.allocator, reason);
        return id;
    }
    fn push(self: *ExplanationBuilder, list: *List, id: usize) Error!void {
        if (std.mem.indexOfScalar(usize, list.items, id) == null) try list.append(self.stored.allocator, id);
    }
    fn leaf(self: *ExplanationBuilder, list: *List, rule: Explanation.Rule, location: Explanation.Location, approximation: bool) Error!void {
        try self.push(list, try self.add(.{ .rule = rule, .location = location, .approximation = approximation }));
    }
    fn members(self: *ExplanationBuilder, set: Set) Error![]const Origin {
        var result: std.ArrayList(Origin) = .empty;
        var iterator = self.stored.values.?.origins.iterator(set);
        while (iterator.next()) |origin| try result.append(self.stored.allocator, origin);
        return result.items;
    }
    fn slot(self: *ExplanationBuilder, relative: bool, block: usize, position: usize, value: p.Id) Error!usize {
        return self.fact(.{ .kind = .slot, .relative = relative, .a = block, .b = position, .c = @intCast(value) });
    }
    fn fact(self: *ExplanationBuilder, key: Key) Error!usize {
        if (self.memo.get(key)) |existing| return existing;
        const id = try self.add(.{ .rule = .summary_dependency });
        try self.memo.put(self.stored.allocator, key, id);
        const flow = (if (key.relative) self.stored.relative else self.stored.values).?;
        const image = self.stored.image;
        var inputs: List = .empty;
        var reason: Explanation.Reason = .{ .rule = .summary_dependency };
        switch (key.kind) {
            .slot => {
                const block = image.blocks[key.a];
                const row = try flow.at(self.stored.allocator, key.a, key.b);
                reason.origins = try self.members(row.get(key.c));
                reason.location = .{ .function = block.function, .block = key.a, .position = key.b, .slot = key.c };
                if (key.b > 0) {
                    const instruction = block.instructions[key.b - 1];
                    if (instruction.destination != key.c) {
                        try self.push(&inputs, try self.slot(key.relative, key.a, key.b - 1, key.c));
                    } else switch (instruction.opcode) {
                        .computation => {
                            reason.rule = .closure_capture;
                            reason.approximation = key.relative;
                            for (instruction.operands) |operand| try self.push(&inputs, try self.slot(key.relative, key.a, key.b - 1, operand));
                        },
                        .move, .product, .variant, .sequence, .sequence_append, .sequence_concat, .sequence_set, .resource_pack, .clone_resumption, .package => {
                            reason.rule = .aggregate_union;
                            for (instruction.operands) |operand| try self.push(&inputs, try self.slot(key.relative, key.a, key.b - 1, operand));
                        },
                        .field, .variant_payload, .sequence_get, .sequence_pop, .sequence_take, .sequence_pop_last, .resource_unpack, .unpack => {
                            reason.rule = .aggregate_projection;
                            reason.approximation = true; // The solver keeps the full aggregate union.
                            for (instruction.operands) |operand| try self.push(&inputs, try self.slot(key.relative, key.a, key.b - 1, operand));
                        },
                        .select => {
                            reason.rule = .branch_join;
                            reason.approximation = true;
                            for (instruction.operands[1..]) |operand| try self.push(&inputs, try self.slot(key.relative, key.a, key.b - 1, operand));
                        },
                        else => {
                            reason.rule = .opaque_cell;
                            reason.approximation = true;
                        },
                    }
                } else {
                    reason.rule = .branch_join;
                    reason.approximation = true;
                    if (key.relative and image.functions[@intCast(block.function)].entry == key.a) {
                        if (std.mem.indexOfScalar(p.Id, image.functions[@intCast(block.function)].inputs, key.c) != null)
                            try self.leaf(&inputs, .scoped_input, reason.location, false);
                    } else if (flow.seeds) |seeds| {
                        const seed = seeds[key.a].get(key.c);
                        if (seed != empty) try self.push(&inputs, try self.add(.{ .rule = if (flow.origins.contains(seed, .unknown)) .unknown_input else .scoped_input, .location = reason.location, .origins = try self.members(seed), .approximation = flow.origins.contains(seed, .unknown) }));
                    }
                    for (image.blocks, 0..) |predecessor, predecessor_id| {
                        if (predecessor.function == block.function) switch (predecessor.terminator) {
                            .jump, .yield_value => |edge_| try self.edge(&inputs, key, predecessor_id, edge_),
                            .branch => |v| {
                                try self.edge(&inputs, key, predecessor_id, v.when_true);
                                try self.edge(&inputs, key, predecessor_id, v.when_false);
                            },
                            .switch_variant => |v| for (v.cases) |edge_| {
                                try self.edge(&inputs, key, predecessor_id, edge_);
                            },
                            inline .call, .perform, .apply, .handle, .resume_value, .resume_with, .resume_computation, .dispose, .protect, .with_region, .unpack_product => |v| try self.edge(&inputs, key, predecessor_id, v.next),
                            .return_value, .fail => {},
                        };
                        if (!key.relative and image.functions[@intCast(block.function)].entry == key.a) {
                            if (std.mem.indexOfScalar(p.Id, image.functions[@intCast(block.function)].inputs, key.c)) |index| {
                                if (predecessor.terminator == .call and predecessor.terminator.call.function == block.function) {
                                    const dependency = try self.slot(false, predecessor_id, predecessor.instructions.len, predecessor.terminator.call.arguments[index]);
                                    try self.push(&inputs, try self.add(.{ .rule = .direct_argument, .location = .{ .function = predecessor.function, .block = predecessor_id }, .inputs = try self.stored.allocator.dupe(usize, &.{dependency}) }));
                                }
                                try self.bodyInput(&inputs, predecessor_id, block.function, index);
                            }
                        }
                    }
                }
            },
            .returned => {
                reason.rule = .direct_return;
                reason.location.function = key.a;
                reason.origins = try self.members(flow.returns[key.a]);
                for (image.blocks, 0..) |block, block_id| if (block.function == key.a and block.terminator == .return_value) {
                    try self.push(&inputs, try self.slot(key.relative, block_id, block.instructions.len, block.terminator.return_value));
                };
            },
            .capture => {
                reason.rule = .closure_capture;
                reason.location.function = image.constructors[key.a].function;
                reason.origins = try self.members(flow.captures[key.a][key.b]);
                for (image.blocks, 0..) |block, block_id| for (block.instructions, 0..) |instruction, position| {
                    if (instruction.opcode == .computation and instruction.immediate == key.a)
                        try self.push(&inputs, try self.slot(false, block_id, position, instruction.operands[key.b]));
                };
            },
            .suspension => {
                reason.location.function = key.a;
                reason.origins = try self.members(flow.suspensions[key.a][key.b]);
                for (image.functions[key.a].layout.slots, 0..) |schema, slot_id| if (flow.disposal.?.contains(schema, key.b)) {
                    try self.leaf(&inputs, .owned_cleanup, .{ .function = key.a, .slot = slot_id }, true);
                };
                for (image.blocks, 0..) |block, block_id| {
                    if (block.function != key.a) continue;
                    const location: Explanation.Location = .{ .function = key.a, .block = block_id, .position = block.instructions.len };
                    switch (block.terminator) {
                        .perform => |v| {
                            if (v.effect == key.b) {
                                if (v.capability) |slot_id| try self.push(&inputs, try self.slot(true, block_id, block.instructions.len, slot_id)) else try self.leaf(&inputs, .environmental, location, false);
                            }
                            if (contracts.containsEffect(image.effects[@intCast(v.effect)].use_site_effects, key.b)) try self.leaf(&inputs, .scoped_input, location, true);
                        },
                        .call => |v| {
                            if (flow.suspensions[@intCast(v.function)][key.b] != empty) {
                                try self.push(&inputs, try self.fact(.{ .kind = .suspension, .relative = true, .a = @intCast(v.function), .b = key.b }));
                                var iterator = flow.origins.iterator(flow.suspensions[@intCast(v.function)][key.b]);
                                while (iterator.next()) |origin| if (origin == .input) {
                                    try self.push(&inputs, try self.slot(true, block_id, block.instructions.len, v.arguments[origin.input]));
                                };
                            }
                        },
                        .return_value, .jump, .branch, .switch_variant, .unpack_product, .yield_value, .fail => {},
                        else => if (contracts.containsEffect(image.functions[key.a].effects, key.b)) try self.leaf(&inputs, .scoped_input, location, true),
                    }
                    // Implicit disposal is intentionally wider than declared rows.
                    // The equation owner has already included it in this final fact.
                    if (flow.origins.contains(flow.suspensions[key.a][key.b], .unknown))
                        try self.implicitSources(&inputs, block_id, key.b);
                }
            },
        }
        reason.inputs = inputs.items;
        self.reasons.items[id] = reason;
        return id;
    }

    fn edge(self: *ExplanationBuilder, inputs: *List, key: Key, predecessor: usize, edge_: ir.Edge) Error!void {
        if (edge_.block != key.a) return;
        const block = self.stored.image.blocks[predecessor];
        var source: ir.Source = .{ .slot = key.c };
        for (edge_.assignments) |assignment| if (assignment.destination == key.c) {
            source = assignment.source;
            break;
        };
        switch (source) {
            .slot => |slot_id| {
                const actual = if (block.terminator == .unpack_product and std.mem.indexOfScalar(p.Id, block.terminator.unpack_product.destinations, slot_id) != null) block.terminator.unpack_product.value else slot_id;
                try self.push(inputs, try self.slot(key.relative, predecessor, block.instructions.len, actual));
            },
            .returned => {
                if (block.terminator == .call) {
                    const call = block.terminator.call;
                    try self.push(inputs, try self.fact(.{ .kind = .returned, .relative = key.relative, .a = @intCast(call.function) }));
                    if (key.relative) {
                        var iterator = self.stored.relative.?.origins.iterator(self.stored.relative.?.returns[@intCast(call.function)]);
                        while (iterator.next()) |origin| if (origin == .input) {
                            try self.push(inputs, try self.slot(true, predecessor, block.instructions.len, call.arguments[origin.input]));
                        };
                    }
                } else try self.leaf(inputs, .opaque_cell, .{ .function = block.function, .block = predecessor, .position = block.instructions.len }, true);
            },
        }
    }

    fn bodyInput(self: *ExplanationBuilder, inputs: *List, block_id: usize, function: p.Id, index: usize) Error!void {
        const block = self.stored.image.blocks[block_id];
        switch (block.terminator) {
            .apply => |v| try self.boundInput(inputs, block_id, function, index, v.computation, v.arguments, 0, null),
            .handle => |v| try self.boundInput(inputs, block_id, function, index, v.body, v.arguments, self.stored.image.handlers[@intCast(v.handler)].clauses.len, v.handler),
            .with_region => |v| try self.boundInput(inputs, block_id, function, index, v.body, v.arguments, 1, null),
            .protect => |v| {
                try self.boundInput(inputs, block_id, function, index, v.body, v.arguments, @intFromBool(v.resource != null), null);
                try self.boundInput(inputs, block_id, function, index, v.cleanup, &.{}, 1 + @as(usize, @intFromBool(v.resource != null)), null);
            },
            .resume_computation => |v| try self.boundInput(inputs, block_id, function, index, v.computation, &.{}, (try contracts.computation(self.stored.image, self.stored.image.functions[@intCast(block.function)].layout.slots[@intCast(v.computation)])).parameters.len, null),
            .perform => |v| for (v.bodies) |body_slot| {
                try self.boundInput(inputs, block_id, function, index, body_slot, &.{}, (try contracts.computation(self.stored.image, self.stored.image.functions[@intCast(block.function)].layout.slots[@intCast(body_slot)])).parameters.len, null);
            },
            else => {},
        }
    }
    fn boundInput(self: *ExplanationBuilder, inputs: *List, block_id: usize, function: p.Id, index: usize, slot_id: p.Id, arguments: []const p.Id, supplied: usize, handler: ?p.Id) Error!void {
        const flow = self.stored.values.?;
        const image = self.stored.image;
        const block = image.blocks[block_id];
        const origins = flow.exits[block_id].get(@intCast(slot_id));
        const schema = image.functions[@intCast(block.function)].layout.slots[@intCast(slot_id)];
        for (image.constructors, 0..) |constructor, constructor_id| {
            if (constructor.function != function or constructor.schema != schema) continue;
            const unknown = flow.origins.contains(origins, .unknown);
            if (!unknown and !flow.origins.contains(origins, .{ .constructor = constructor_id })) continue;
            var dependencies: List = .empty;
            try self.push(&dependencies, try self.slot(false, block_id, block.instructions.len, slot_id));
            const captures = flow.captures[constructor_id].len;
            var rule: Explanation.Rule = .closure_application;
            if (index < captures) {
                if (!unknown) try self.push(&dependencies, try self.fact(.{ .kind = .capture, .a = constructor_id, .b = index }));
            } else if (index < captures + supplied) {
                rule = if (handler != null) .fresh_installation else .scoped_input;
            } else try self.push(&dependencies, try self.slot(false, block_id, block.instructions.len, arguments[index - captures - supplied]));
            try self.push(inputs, try self.add(.{ .rule = rule, .location = .{ .function = block.function, .block = block_id }, .inputs = dependencies.items, .handler = handler, .approximation = unknown or (rule == .scoped_input) }));
        }
    }

    fn implicitSources(self: *ExplanationBuilder, inputs: *List, block_id: usize, effect: usize) Error!void {
        const block = self.stored.image.blocks[block_id];
        switch (block.terminator) {
            .apply => |v| try self.implicitClosure(inputs, block_id, v.computation, effect),
            .handle => |v| {
                try self.implicitClosure(inputs, block_id, v.body, effect);
                try self.implicitHandler(inputs, block_id, v.handler, effect);
            },
            .with_region => |v| try self.implicitClosure(inputs, block_id, v.body, effect),
            .protect => |v| {
                try self.implicitClosure(inputs, block_id, v.body, effect);
                try self.implicitClosure(inputs, block_id, v.cleanup, effect);
            },
            .resume_computation => |v| try self.implicitClosure(inputs, block_id, v.computation, effect),
            .resume_with => |v| try self.implicitHandler(inputs, block_id, v.handler, effect),
            .perform => |v| for (v.bodies) |slot_id| {
                try self.implicitClosure(inputs, block_id, slot_id, effect);
            },
            else => {},
        }
    }
    fn implicitClosure(self: *ExplanationBuilder, inputs: *List, block_id: usize, slot_id: p.Id, effect: usize) Error!void {
        const image = self.stored.image;
        const block = image.blocks[block_id];
        const schema = image.functions[@intCast(block.function)].layout.slots[@intCast(slot_id)];
        if (contracts.containsEffect((try contracts.computation(image, schema)).effects, effect)) return;
        for (image.constructors) |constructor| {
            if (constructor.schema != schema or self.stored.relative.?.suspensions[@intCast(constructor.function)][effect] == empty) continue;
            const dependency = try self.fact(.{ .kind = .suspension, .relative = true, .a = @intCast(constructor.function), .b = effect });
            try self.push(inputs, try self.add(.{ .rule = .owned_cleanup, .location = .{ .function = block.function, .block = block_id, .slot = slot_id }, .inputs = try self.stored.allocator.dupe(usize, &.{dependency}), .approximation = true }));
        }
    }
    fn implicitHandler(self: *ExplanationBuilder, inputs: *List, block_id: usize, handler_id: p.Id, effect: usize) Error!void {
        const handler = self.stored.image.handlers[@intCast(handler_id)];
        if (contracts.containsEffect(handler.effects, effect)) return;
        var dependencies: List = .empty;
        if (self.stored.relative.?.suspensions[@intCast(handler.return_function)][effect] != empty)
            try self.push(&dependencies, try self.fact(.{ .kind = .suspension, .relative = true, .a = @intCast(handler.return_function), .b = effect }));
        for (handler.clauses) |clause| {
            if (self.stored.relative.?.suspensions[@intCast(clause.function)][effect] != empty)
                try self.push(&dependencies, try self.fact(.{ .kind = .suspension, .relative = true, .a = @intCast(clause.function), .b = effect }));
        }
        if (dependencies.items.len != 0) try self.push(inputs, try self.add(.{ .rule = .owned_cleanup, .location = .{ .function = self.stored.image.blocks[block_id].function, .block = block_id }, .inputs = dependencies.items, .handler = handler_id, .approximation = true }));
    }

    fn selection(self: *ExplanationBuilder, selected: *const Selection) Error!usize {
        const boundary = selected.boundary();
        const block_id: usize = @intCast(boundary.block);
        const block = self.stored.image.blocks[block_id];
        const location: Explanation.Location = .{ .function = block.function, .block = block_id, .position = block.instructions.len };
        var inputs: List = .empty;
        if (boundary.role == .operation and block.terminator == .perform and block.terminator.perform.capability == null) {
            try self.leaf(&inputs, .environmental, location, false);
        } else if (self.stored.values == null) {
            try self.leaf(&inputs, .unknown_input, location, true);
        } else if (boundary.role == .operation and block.terminator == .perform) {
            if (block.terminator.perform.capability) |slot_id| try self.push(&inputs, try self.slot(false, block_id, block.instructions.len, slot_id)) else try self.leaf(&inputs, .environmental, location, false);
        } else if (boundary.role == .callee and block.terminator == .call) {
            const call = block.terminator.call;
            try self.push(&inputs, try self.fact(.{ .kind = .suspension, .relative = true, .a = @intCast(call.function), .b = @intCast(selected.effect()) }));
            var iterator = self.stored.relative.?.origins.iterator(self.stored.relative.?.suspensions[@intCast(call.function)][@intCast(selected.effect())]);
            while (iterator.next()) |origin| if (origin == .input) {
                try self.push(&inputs, try self.slot(false, block_id, block.instructions.len, call.arguments[origin.input]));
            };
        } else {
            const slot_id: ?p.Id = switch (block.terminator) {
                .apply => |v| v.computation,
                inline .handle, .with_region => |v| v.body,
                .protect => |v| if (boundary.role == .cleanup) v.cleanup else v.body,
                .resume_computation => |v| if (boundary.role == .injected) v.computation else null,
                else => null,
            };
            if (slot_id) |value| {
                try self.push(&inputs, try self.slot(false, block_id, block.instructions.len, value));
                const flow = self.stored.values.?;
                const origins = flow.exits[block_id].get(@intCast(value));
                for (self.stored.image.constructors, 0..) |constructor, id| {
                    if (!flow.origins.contains(origins, .{ .constructor = id })) continue;
                    try self.push(&inputs, try self.fact(.{ .kind = .suspension, .relative = true, .a = @intCast(constructor.function), .b = @intCast(selected.effect()) }));
                    for (flow.captures[id], 0..) |_, index| try self.push(&inputs, try self.fact(.{ .kind = .capture, .a = id, .b = index }));
                }
            } else try self.leaf(&inputs, if (boundary.role == .cleanup or boundary.role == .resumed or boundary.role == .handler) .owned_cleanup else .scoped_input, location, true);
        }
        if (selected.knowledge().conservative) try self.leaf(&inputs, .conservative_expansion, location, true);
        // Show the may-rebind edges that can contribute recipients. These are
        // alternatives, never a claim that branches execute together.
        if (self.stored.values) |flow| for (self.stored.image.blocks, 0..) |candidate, id| {
            if (candidate.terminator != .resume_with) continue;
            const operation = candidate.terminator.resume_with;
            var relevant = false;
            for (selected.targets()) |target| relevant = relevant or flow.bindings[@intCast(operation.handler)][@intCast(target.handler)];
            if (!relevant) continue;
            const source = try self.slot(false, id, candidate.instructions.len, operation.resumption);
            try self.push(&inputs, try self.add(.{ .rule = .successor_binding, .location = .{ .function = candidate.function, .block = id }, .handler = operation.handler, .inputs = try self.stored.allocator.dupe(usize, &.{source}), .approximation = true }));
        };
        return self.add(.{ .rule = .selection, .location = location, .inputs = inputs.items, .approximation = selected.knowledge().conservative });
    }
};
