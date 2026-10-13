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
    relative: ?*const Values = null,
    positions: std.ArrayList(PositionSources) = .empty,
};
const CallTargets = struct { role: Role = .callee, effect: p.Id, targets: []const Target, environmental: bool = false };
pub const SuspensionSources = struct { slots: []const p.Id = &.{}, conservative: bool = false };
const PositionSources = struct { block: p.Id, position: usize, returned: bool, effects: []const SuspensionSources };

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
    /// Sources are stable slots at this exact position, never callee input
    /// ordinals. A saved continuation starts after its awaited invocation;
    /// the returned value is unknown until its child actually returns.
    pub fn suspensionSources(self: *const Analysis, block: p.Id, position: usize, returned: bool, effect: p.Id) Error!SuspensionSources {
        const stored: *Storage = @ptrCast(@alignCast(@constCast(self)));
        const relative = stored.relative orelse return .{ .conservative = true };
        for (stored.positions.items) |query| if (query.block == block and query.position == position and query.returned == returned)
            return query.effects[@intCast(effect)];
        const summaries = try relative.fromPosition(block, position, returned);
        const effects = try stored.allocator.alloc(SuspensionSources, summaries.len);
        for (summaries, effects) |summary, *sources| {
            sources.* = .{};
            var slots: std.ArrayList(p.Id) = .empty;
            var iterator = relative.origins.iterator(summary);
            while (iterator.next()) |origin| switch (origin) {
                .input => |slot| try slots.append(stored.allocator, slot),
                .environmental => {},
                else => sources.conservative = true,
            };
            sources.slots = try slots.toOwnedSlice(stored.allocator);
        }
        try stored.positions.append(stored.allocator, .{ .block = block, .position = position, .returned = returned, .effects = effects });
        return effects[@intCast(effect)];
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
            for (image.functions[@intCast(call.function)].effects) |effect| {
                const actual = try origins.substitute(relative.suspensions[@intCast(call.function)][@intCast(effect)], call.arguments, flow.exits[id]);
                if (origins.contains(actual, .unknown)) continue;
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
    const origin_set = values.get(@intCast(slot));
    const origins = flow.origins;
    if (origin_set == empty or origins.contains(origin_set, .unknown)) return;
    const image = stored.image;
    const schema = image.functions[@intCast(image.blocks[block].function)].layout.slots[@intCast(slot)];
    const signature = try contracts.computation(image, schema);
    for (signature.effects) |effect| {
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
        if (!found or origins.contains(actual, .unknown)) continue;
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
const Origin = union(enum) { unknown, environmental, handler: p.Id, resumption: p.Id, constructor: p.Id, input: usize };
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
        const resumptions = std.math.add(u64, 2, image.handlers.len) catch return error.Capacity;
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
            .handler => |id| 2 + id,
            .resumption => |id| self.resumptions + id,
            .constructor => |id| self.constructors + id,
            .input => |id| self.inputs + id,
        };
    }
    fn origin(self: *const Origins, id: u64) Origin {
        if (id == 0) return .unknown;
        if (id == 1) return .environmental;
        if (id < self.resumptions) return .{ .handler = id - 2 };
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
    try std.testing.expectEqual(input1, before[0]);
    try std.testing.expectEqual(try origins.unite(input0, input1), after[0]);
    try std.testing.expectEqual(input1, returned[0]);
}

test "position suspension sources substitute callee inputs and preserve an unknown delivery" {
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
    try std.testing.expectEqual(try origins.one(.{ .input = 0 }), (try relative.fromPosition(0, 0, false))[0]);
    try std.testing.expectEqual(try origins.one(.unknown), (try relative.fromPosition(0, 0, true))[0]);
}

const Values = struct {
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

    const PositionQuery = struct { reachable: []bool, suspensions: []Set };

    fn fromPosition(self: *const Values, start: p.Id, position: usize, returned: bool) Error![]const Set {
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
                inline .call, .perform, .apply, .handle, .resume_value, .resume_with, .resume_computation, .dispose, .protect, .with_region => |v| try reader.edge(@intCast(start), v.next, try self.origins.one(.unknown), null),
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
        return query.suspensions;
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
            for (image.functions, 0..) |function, id| {
                self.suspensions[id] = try sets(a, image.effects.len);
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
            for (function.inputs, 0..) |slot, index|
                if (self.entries[@intCast(function.entry)].get(@intCast(slot)) == empty) try self.input(id, index, try self.origins.one(.unknown));
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
    fn transferBlockFrom(self: *Values, id: usize, block_value: ir.Block, entry_row: Row) Error!void {
        const values = &self.exits[id];
        // Re-evaluate this straight-line transfer from its monotone entry. Exit
        // rows are retained between rounds, but each instruction is a strong
        // assignment within this one activation view.
        values.copyFrom(entry_row);
        for (block_value.instructions) |operation| try self.transferInstruction(values, operation, true);
        const term = block_value.terminator;
        switch (term) {
            .return_value => |slot| if (self.position_query == null)
                try self.join(&self.returns[@intCast(block_value.function)], values.get(@intCast(slot))),
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
                .call => |v| for (self.image.functions[@intCast(v.function)].effects) |effect| {
                    const targets = try self.origins.substitute(self.suspensions[@intCast(v.function)][@intCast(effect)], v.arguments, values.*);
                    try self.join(&summary[@intCast(effect)], targets);
                },
                .return_value, .jump, .branch, .switch_variant, .unpack_product, .yield_value, .fail => {},
                else => for (self.image.functions[@intCast(block_value.function)].effects) |effect| {
                    try self.join(&summary[@intCast(effect)], try self.origins.one(.unknown));
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
