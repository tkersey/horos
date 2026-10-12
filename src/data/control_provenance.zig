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
    image: ir.Program,
    boundary: Boundary,
    effect: p.Id,
    targets: []const Target,
    knowledge: Knowledge,
};
pub const Knowledge = struct { conservative: bool, environmental: bool = false };

/// Borrowed for the admission invocation. An observer retaining a selection
/// must copy it through this owner; copying retains its original boundary and
/// exact program, rather than reconstructing relevance from an effect number.
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
};
const CallTargets = struct { role: Role = .callee, effect: p.Id, targets: []const Target, environmental: bool = false };

pub const Analysis = opaque {
    fn data(self: *const Analysis) *const Storage {
        return @ptrCast(@alignCast(self));
    }
    /// Query only the immutable image used for derivation. No replacement image
    /// or caller-supplied weaker target map enters this API.
    pub fn targets(self: *const Analysis, boundary: Boundary, effect: p.Id) []const Target {
        if (boundary.role == .operation) if (self.data().operations[@intCast(boundary.block)]) |known| {
            if (self.data().image.blocks[@intCast(boundary.block)].terminator.perform.effect == effect) return known;
        };
        for (self.data().calls[@intCast(boundary.block)]) |known| {
            if (known.role == boundary.role and known.effect == effect) return known.targets;
        }
        return self.data().conservative[@intCast(effect)];
    }
    pub fn select(self: *const Analysis, boundary: Boundary, effect: p.Id) Error!*const Selection {
        const stored = try self.data().allocator.create(SelectionData);
        var knowledge: Knowledge = .{ .conservative = true };
        if (boundary.role == .operation and self.data().operations[@intCast(boundary.block)] != null and self.data().image.blocks[@intCast(boundary.block)].terminator.perform.effect == effect)
            knowledge = .{ .conservative = false, .environmental = self.data().image.blocks[@intCast(boundary.block)].terminator.perform.capability == null };
        for (self.data().calls[@intCast(boundary.block)]) |known| {
            if (known.role == boundary.role and known.effect == effect) knowledge = .{ .conservative = false, .environmental = known.environmental };
        }
        stored.* = .{ .image = self.data().image, .boundary = boundary, .effect = effect, .targets = self.targets(boundary, effect), .knowledge = knowledge };
        return @ptrCast(stored);
    }
    pub fn capturesRegion(self: *const Analysis, boundary: Boundary, effects: []const p.Id, region: p.Id) Error!void {
        for (effects) |effect| for (self.targets(boundary, effect)) |target| {
            if (!target.retains) continue;
            const signature = try contracts.resumption(self.data().image, target.resumption);
            if (std.mem.indexOfScalar(p.Id, signature.owned_regions, region) == null) return error.InvalidOwnership;
        };
    }
    pub fn capturesCleanup(self: *const Analysis, boundary: Boundary, effects: []const p.Id) Error!void {
        for (effects) |effect| {
            // Intrinsic multi-shot prohibition is independent of relevance.
            if (self.data().image.effects[@intCast(effect)].control_use == .multi) return error.InvalidOwnership;
            for (self.targets(boundary, effect)) |target|
                if (!(try contracts.resumption(self.data().image, target.resumption)).obligations) return error.InvalidOwnership;
        }
    }

    /// After ordinary graph/type/custody admission, qualify concrete values
    /// against the same abstract bindings that justified reduced target sets.
    /// Restoring bytes is a second constructor of execution state; schema
    /// equality alone cannot establish this relation.
    pub fn validateState(self: *const Analysis, allocator: std.mem.Allocator, nodes: []const @import("graph.zig").Node, activations: []const ?@import("process_state.zig").Activation) Error!void {
        const values = self.data().values orelse return;
        const g = @import("graph.zig");
        const Pending = struct { value: g.Value, allowed: *const Set };
        var pending: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(struct { node: p.Id, allowed: *const Set }, void) = .empty;
        for (nodes, activations) |node, activation| {
            if (activation) |frame| {
                const block = if (node == .control) node.control.block else node.continuation.source_block;
                const row = try values.at(allocator, @intCast(block), @intCast(frame.position));
                for (frame.bindings) |binding| try pending.append(allocator, .{ .value = binding.value, .allowed = &row[@intCast(binding.slot)] });
            }
            if (node == .computation) {
                const closure = node.computation;
                const fields = nodes[@intCast(closure.environment.id)].environment.values;
                for (fields, values.captures[@intCast(closure.constructor)]) |value, *allowed|
                    try pending.append(allocator, .{ .value = value, .allowed = allowed });
            }
        }
        while (pending.pop()) |item| {
            const allowed = item.allowed.items;
            if (contains(allowed, .unknown)) continue;
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
                .computation => |closure| if (!contains(allowed, .{ .constructor = closure.constructor })) return error.InvalidOwnership,
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
                    if (!contains(allowed, .{ .resumption = definition })) return error.InvalidOwnership;
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
        var flow = try Values.init(allocator, image, false);
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
            const origins = flow.exits[id][@intCast(op.capability.?)].items;
            if (origins.len == 0 or contains(origins, .unknown)) continue;
            var selected: std.ArrayList(Target) = .empty;
            for (stored.conservative[@intCast(op.effect)]) |target| {
                if (flow.receives(origins, target.handler)) try selected.append(allocator, target);
            }
            stored.operations[id] = try selected.toOwnedSlice(allocator);
        };
        var relative = try Values.init(allocator, image, true);
        try relative.solve();
        for (image.blocks, 0..) |block, id| if (block.terminator == .call) {
            const call = block.terminator.call;
            var rows: std.ArrayList(CallTargets) = .empty;
            for (image.functions[@intCast(call.function)].effects) |effect| {
                var actual: Set = .empty;
                try substitute(allocator, &actual, relative.suspensions[@intCast(call.function)][@intCast(effect)].items, call.arguments, flow.exits[id]);
                if (contains(actual.items, .unknown)) continue;
                var selected: std.ArrayList(Target) = .empty;
                for (stored.conservative[@intCast(effect)]) |target|
                    if (flow.receives(actual.items, target.handler)) try selected.append(allocator, target);
                try rows.append(allocator, .{ .effect = effect, .targets = try selected.toOwnedSlice(allocator), .environmental = contains(actual.items, .environmental) });
            }
            stored.calls[id] = try rows.toOwnedSlice(allocator);
        };
        for (image.blocks, 0..) |block, id| {
            var rows: std.ArrayList(CallTargets) = .empty;
            switch (block.terminator) {
                .apply => |v| try closureTargets(stored, &flow, &relative, &rows, id, .callee, v.computation, v.arguments, 0, null),
                .handle => |v| try closureTargets(stored, &flow, &relative, &rows, id, .body, v.body, v.arguments, image.handlers[@intCast(v.handler)].clauses.len, v.handler),
                .with_region => |v| try closureTargets(stored, &flow, &relative, &rows, id, .body, v.body, v.arguments, 1, null),
                .protect => |v| {
                    try closureTargets(stored, &flow, &relative, &rows, id, .body, v.body, v.arguments, @intFromBool(v.resource != null), null);
                    try closureTargets(stored, &flow, &relative, &rows, id, .cleanup, v.cleanup, &.{}, 1 + @as(usize, @intFromBool(v.resource != null)), null);
                },
                else => continue,
            }
            stored.calls[id] = try rows.toOwnedSlice(allocator);
        }
    }
    return @ptrCast(stored);
}

fn closureTargets(stored: *Storage, flow: *const Values, relative: *const Values, rows: *std.ArrayList(CallTargets), block: usize, role: Role, slot: p.Id, arguments: []const p.Id, supplied: usize, installed: ?p.Id) Error!void {
    const values = flow.exits[block];
    const origins = values[@intCast(slot)].items;
    if (origins.len == 0 or contains(origins, .unknown)) return;
    const image = stored.image;
    const schema = image.functions[@intCast(image.blocks[block].function)].layout.slots[@intCast(slot)];
    const signature = try contracts.computation(image, schema);
    for (signature.effects) |effect| {
        var actual: Set = .empty;
        var found = false;
        for (image.constructors, 0..) |constructor, id| {
            if (constructor.schema != schema or !contains(origins, .{ .constructor = id })) continue;
            found = true;
            const captures = flow.captures[id];
            for (relative.suspensions[@intCast(constructor.function)][@intCast(effect)].items) |origin| {
                if (origin == .environmental) {
                    if (!contains(actual.items, .environmental)) try actual.append(stored.allocator, .environmental);
                    continue;
                }
                var source: []const Origin = &unknown;
                if (origin == .input) {
                    const index = origin.input;
                    if (index < captures.len) {
                        source = captures[index].items;
                    } else if (index < captures.len + supplied) {
                        // Only these formal parameters are supplied by this fresh
                        // installation. Captured outer capabilities with the same
                        // abstract handler ID are deliberately not discharged.
                        if (installed != null) continue;
                    } else source = values[@intCast(arguments[index - captures.len - supplied])].items;
                }
                for (source) |value| if (!contains(actual.items, value)) try actual.append(stored.allocator, value);
            }
        }
        if (!found or contains(actual.items, .unknown)) continue;
        var selected: std.ArrayList(Target) = .empty;
        for (stored.conservative[@intCast(effect)]) |target|
            if (flow.receives(actual.items, target.handler)) try selected.append(stored.allocator, target);
        try rows.append(stored.allocator, .{ .role = role, .effect = effect, .targets = try selected.toOwnedSlice(stored.allocator), .environmental = contains(actual.items, .environmental) });
    }
}

// A deliberately finite value abstraction: aggregate members share a union,
// closure environments have one row per constructor, and mutable/opaque reads
// are unknown. No type equality establishes a capability's recipient.
// The same transfer computes input-relative return/suspension summaries. Direct
// calls and known closure boundaries instantiate them. Unrepresented saved
// contexts retain the conservative upper bound.
const Origin = union(enum) { unknown, environmental, handler: p.Id, resumption: p.Id, constructor: p.Id, input: usize };
const Set = std.ArrayList(Origin);
fn contains(set: []const Origin, value: Origin) bool {
    for (set) |item| if (std.meta.eql(item, value)) return true;
    return false;
}
const unknown = [_]Origin{.unknown};

fn substitute(a: std.mem.Allocator, into: *Set, summary: []const Origin, arguments: []const p.Id, values: []const Set) Error!void {
    for (summary) |origin| {
        const singleton = [_]Origin{origin};
        const source = if (origin == .input) values[@intCast(arguments[origin.input])].items else &singleton;
        for (source) |value| if (!contains(into.items, value)) try into.append(a, value);
    }
}

const Values = struct {
    allocator: std.mem.Allocator,
    image: ir.Program,
    entries: [][]Set,
    exits: [][]Set,
    returns: []Set,
    captures: [][]Set,
    bindings: [][]bool,
    relative: bool,
    suspensions: [][]Set,
    changed: bool = false,

    fn sets(a: std.mem.Allocator, count: usize) Error![]Set {
        const result = try a.alloc(Set, count);
        @memset(result, .empty);
        return result;
    }
    fn init(a: std.mem.Allocator, image: ir.Program, relative: bool) Error!Values {
        var self: Values = .{ .allocator = a, .image = image, .entries = try a.alloc([]Set, image.blocks.len), .exits = try a.alloc([]Set, image.blocks.len), .returns = try sets(a, image.functions.len), .captures = try a.alloc([]Set, image.constructors.len), .bindings = try a.alloc([]bool, image.handlers.len), .relative = relative, .suspensions = try a.alloc([]Set, if (relative) image.functions.len else 0) };
        for (self.bindings, 0..) |*row, id| {
            row.* = try a.alloc(bool, image.handlers.len);
            @memset(row.*, false);
            row.*[id] = true;
        }
        for (image.blocks, 0..) |block, id| {
            const count = image.functions[@intCast(block.function)].layout.slots.len;
            self.entries[id] = try sets(a, count);
            self.exits[id] = try sets(a, count);
        }
        for (image.constructors, 0..) |constructor, id|
            self.captures[id] = try sets(a, image.scopes.captures[@intCast(constructor.capture)].fields.len);
        if (relative) {
            for (image.functions, 0..) |function, id| {
                self.suspensions[id] = try sets(a, image.effects.len);
                for (function.inputs, 0..) |_, index| try self.input(id, index, &.{.{ .input = index }});
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
                        try self.input(clause.function, index, &.{.{ .resumption = handler_id }});
                    } else try self.input(clause.function, index, &unknown);
                }
            }
        }
        return self;
    }
    fn join(self: *Values, into: *Set, source: []const Origin) Error!void {
        for (source) |origin| if (!contains(into.items, origin)) {
            try into.append(self.allocator, origin);
            self.changed = true;
        };
    }
    fn input(self: *Values, function: p.Id, index: usize, value: []const Origin) Error!void {
        const f = self.image.functions[@intCast(function)];
        if (f.entry == @import("relocation.zig").missing) return;
        try self.join(&self.entries[@intCast(f.entry)][@intCast(f.inputs[index])], value);
    }
    fn unknownInputs(self: *Values, function: p.Id) Error!void {
        for (self.image.functions[@intCast(function)].inputs, 0..) |_, index| try self.input(function, index, &unknown);
    }
    fn solve(self: *Values) Error!void {
        try self.converge();
        if (self.relative) return;
        // A declaration without a witnessed binding is not an empty-target
        // proof. Its inputs remain independently checkable under unknown values.
        for (self.image.functions, 0..) |function, id| {
            if (function.entry == @import("relocation.zig").missing) continue;
            for (function.inputs, 0..) |slot, index|
                if (self.entries[@intCast(function.entry)][@intCast(slot)].items.len == 0) try self.input(id, index, &unknown);
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
            const origins = self.exits[id][@intCast(operation.resumption)].items;
            for (self.bindings, 0..) |row, handler_id| {
                if (origins.len == 0 or contains(origins, .unknown) or contains(origins, .{ .resumption = handler_id }))
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
    fn receives(self: *const Values, origins: []const Origin, handler: p.Id) bool {
        for (origins) |origin| if (origin == .handler and self.bindings[@intCast(origin.handler)][@intCast(handler)]) return true;
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
        const origins = values[@intCast(slot)].items;
        const schema = self.image.functions[@intCast(self.image.blocks[block_id].function)].layout.slots[@intCast(slot)];
        for (self.image.constructors, 0..) |constructor, id| {
            if (constructor.schema != schema) continue;
            const uncertain = contains(origins, .unknown);
            if (!contains(origins, .{ .constructor = id }) and !uncertain) continue;
            for (self.captures[id], 0..) |capture, index| try self.input(constructor.function, index, if (uncertain) &unknown else capture.items);
            const prefix = self.captures[id].len;
            for (0..supplied) |index| {
                const fresh = [_]Origin{if (handler) |h| .{ .handler = h } else .unknown};
                try self.input(constructor.function, prefix + index, &fresh);
            }
            for (arguments, 0..) |argument, index| try self.input(constructor.function, prefix + supplied + index, values[@intCast(argument)].items);
        }
    }
    fn edge(self: *Values, id: usize, next: ir.Edge, returned: []const Origin, unpack: ?ir.Terminator) Error!void {
        const source = self.exits[id];
        for (self.entries[@intCast(next.block)], 0..) |*destination, slot| {
            var value: []const Origin = source[slot].items;
            if (unpack) |term| switch (term) {
                .unpack_product => |v| if (std.mem.indexOfScalar(p.Id, v.destinations, slot) != null) {
                    value = source[@intCast(v.value)].items;
                },
                else => {},
            };
            // Every source reads the same predecessor, including permutations.
            for (next.assignments) |assignment| if (assignment.destination == slot) {
                value = switch (assignment.source) {
                    .slot => |from| if (unpack != null and std.mem.indexOfScalar(p.Id, unpack.?.unpack_product.destinations, from) != null) source[@intCast(unpack.?.unpack_product.value)].items else source[@intCast(from)].items,
                    .returned => returned,
                };
            };
            try self.join(destination, value);
        }
    }
    fn at(self: *const Values, allocator: std.mem.Allocator, block_id: usize, position: usize) Error![]Set {
        var reader = self.*;
        reader.allocator = allocator;
        const row = try sets(allocator, self.entries[block_id].len);
        for (row, self.entries[block_id]) |*value, entry| try value.appendSlice(allocator, entry.items);
        for (self.image.blocks[block_id].instructions[0..position]) |instruction| try reader.transferInstruction(row, instruction, false);
        return row;
    }
    fn transferInstruction(self: *Values, values: []Set, instruction: ir.Instruction, record_captures: bool) Error!void {
        var result: Set = .empty;
        defer result.deinit(self.allocator);
        switch (instruction.opcode) {
            .computation => {
                if (self.relative) {
                    try result.append(self.allocator, .unknown);
                } else {
                    if (record_captures) for (instruction.operands, 0..) |operand, index| try self.join(&self.captures[@intCast(instruction.immediate)][index], values[@intCast(operand)].items);
                    try result.append(self.allocator, .{ .constructor = instruction.immediate });
                }
            },
            .move, .product, .field, .variant, .variant_payload, .sequence, .sequence_get, .sequence_append, .sequence_concat, .sequence_pop, .sequence_set, .sequence_take, .sequence_pop_last, .resource_pack, .resource_unpack, .clone_resumption, .package, .unpack => {
                for (instruction.operands) |operand| for (values[@intCast(operand)].items) |origin|
                    if (!contains(result.items, origin)) try result.append(self.allocator, origin);
            },
            .select => for (instruction.operands[1..]) |operand| {
                for (values[@intCast(operand)].items) |origin| if (!contains(result.items, origin)) try result.append(self.allocator, origin);
            },
            // Cells and opaque representations deliberately lose precision.
            // Their reads cannot turn an untracked write into an empty set.
            else => try result.appendSlice(self.allocator, &unknown),
        }
        const destination = &values[@intCast(instruction.destination)];
        destination.clearRetainingCapacity();
        try destination.appendSlice(self.allocator, result.items);
    }
    fn transferBlock(self: *Values, id: usize, block_value: ir.Block) Error!void {
        const values = self.exits[id];
        // Re-evaluate this straight-line transfer from its monotone entry. Exit
        // rows are retained between rounds, but each instruction is a strong
        // assignment within this one activation view.
        for (values, self.entries[id]) |*value, entry| {
            value.clearRetainingCapacity();
            try value.appendSlice(self.allocator, entry.items);
        }
        for (block_value.instructions) |operation| try self.transferInstruction(values, operation, true);
        const term = block_value.terminator;
        switch (term) {
            .return_value => |slot| try self.join(&self.returns[@intCast(block_value.function)], values[@intCast(slot)].items),
            .call => |v| if (!self.relative) {
                for (v.arguments, 0..) |slot, index| try self.input(v.function, index, values[@intCast(slot)].items);
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
        var mapped: Set = .empty;
        defer mapped.deinit(self.allocator);
        if (self.relative and term == .call) try substitute(self.allocator, &mapped, self.returns[@intCast(term.call.function)].items, term.call.arguments, values);
        const returned: []const Origin = if (term == .call) (if (self.relative) mapped.items else self.returns[@intCast(term.call.function)].items) else &unknown;
        if (self.relative) {
            const summary = self.suspensions[@intCast(block_value.function)];
            switch (term) {
                .perform => |v| {
                    if (v.capability) |slot| {
                        try self.join(&summary[@intCast(v.effect)], values[@intCast(slot)].items);
                    } else try self.join(&summary[@intCast(v.effect)], &.{.environmental});
                    for (self.image.effects[@intCast(v.effect)].use_site_effects) |effect| try self.join(&summary[@intCast(effect)], &unknown);
                },
                .call => |v| for (self.image.functions[@intCast(v.function)].effects) |effect| {
                    var targets: Set = .empty;
                    defer targets.deinit(self.allocator);
                    try substitute(self.allocator, &targets, self.suspensions[@intCast(v.function)][@intCast(effect)].items, v.arguments, values);
                    try self.join(&summary[@intCast(effect)], targets.items);
                },
                .return_value, .jump, .branch, .switch_variant, .unpack_product, .yield_value, .fail => {},
                else => for (self.image.functions[@intCast(block_value.function)].effects) |effect| {
                    try self.join(&summary[@intCast(effect)], &unknown);
                },
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
