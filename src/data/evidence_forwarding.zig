// Copyright (c) 2026 Boundary contributors. MIT license.
//! Coalesce immutable capability parameters only when every direct caller
//! supplies the same actual slot. Equal effect descriptors are not evidence of
//! equal dynamic installations. Public and indirectly callable entries stay open.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const contexts = @import("call_contexts.zig");
const access = @import("slot_access.zig");
const equal = @import("record_equal.zig").equal;
const arguments = @import("dead_arguments.zig");
const p01 = @import("coalescing.zig");
pub const Error = arguments.Error || error{ InvalidEvidenceForwarding, EvidenceWorkLimit };
pub const Options = struct { work_limit: usize = 10_000_000, coalescing: p01.Options = .{} };
pub const Pair = struct { function: p.Id, keep: usize, remove: usize };
pub const Statistics = struct { parameters_coalesced: usize = 0, call_arguments_removed: usize = 0, work_limit: bool = false };
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    pairs: []const Pair,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: usize,
    fn take(self: *Budget, amount: usize) Error!void {
        if (amount > self.left) return error.EvidenceWorkLimit;
        self.left -= amount;
    }
    fn record(self: *Budget, comptime T: type, value: T) Error!void {
        try self.take(1);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.field_names, info.field_types) |field_name, FieldType| try self.record(FieldType, @field(value, field_name)),
            .@"union" => switch (value) {
                inline else => |payload| try self.record(@TypeOf(payload), payload),
            },
            .optional => |info| if (value) |payload| {
                try self.record(info.child, payload);
            },
            .pointer => |info| for (value) |item| try self.record(info.child, item),
            else => {},
        }
    }
};
fn admissiblePair(program: ir.Program, pair: Pair, permissions: traits.Facts, budget: *Budget) Error!bool {
    try budget.take(1);
    if (pair.function >= program.functions.len or contexts.unknownEntry(program, pair.function)) return false;
    const function = program.functions[@intCast(pair.function)];
    if (pair.keep >= pair.remove or pair.remove >= function.inputs.len) return false;
    const keep = function.inputs[pair.keep];
    const remove = function.inputs[pair.remove];
    const schema = function.layout.slots[@intCast(keep)];
    if (schema != function.layout.slots[@intCast(remove)] or program.schemas[@intCast(schema)] != .internal or
        program.schemas[@intCast(schema)].internal != .capability or !permissions.copy[@intCast(schema)] or !permissions.drop[@intCast(schema)]) return false;
    var callers: usize = 0;
    var kept_reads: usize = 0;
    var removed_reads: usize = 0;
    for (program.blocks) |block| {
        try budget.take(1);
        if (block.terminator == .call and block.terminator.call.function == pair.function) {
            callers += 1;
            const actual = block.terminator.call.arguments;
            if (actual[pair.keep] != actual[pair.remove]) return false;
        }
        if (block.function != pair.function) continue;
        for (block.instructions) |op| {
            try budget.take(1 + op.operands.len);
            if (op.destination == keep or op.destination == remove) return false;
            if (std.mem.indexOfScalar(p.Id, op.operands, remove) != null) return false;
            kept_reads += std.mem.count(p.Id, op.operands, &.{keep});
        }
        try budget.record(ir.Terminator, block.terminator);
        try budget.record(ir.Terminator, block.terminator);
        const kept = access.terminator(block.terminator, keep);
        const removed = access.terminator(block.terminator, remove);
        if (kept.writes != 0 or removed.writes != 0) return false;
        kept_reads += kept.reads;
        var allowed: usize = 0;
        if (block.terminator == .perform) {
            const op = block.terminator.perform;
            try budget.take(op.use_site_capabilities.len);
            allowed = @as(usize, @intFromBool(op.capability == remove)) + std.mem.count(p.Id, op.use_site_capabilities, &.{remove});
        }
        if (removed.reads != allowed) return false;
        removed_reads += allowed;
    }
    return callers != 0 and kept_reads != 0 and removed_reads != 0;
}
pub fn possible(program: ir.Program) bool {
    for (program.functions, 0..) |function, id| {
        if (contexts.unknownEntry(program, id)) continue;
        var count: usize = 0;
        for (function.inputs) |slot| {
            const schema = program.schemas[@intCast(function.layout.slots[@intCast(slot)])];
            if (schema == .internal and schema.internal == .capability) count += 1;
        }
        if (count >= 2) return true;
    }
    return false;
}
pub fn construct(allocator: std.mem.Allocator, original: ir.Program, options: Options) Error!?Candidate {
    var admitted = try own.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep_arena = false;
    defer if (!keep_arena) arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    var pairs: std.ArrayList(Pair) = .empty;
    for (original.functions, 0..) |function, id| {
        try budget.take(1);
        if (contexts.unknownEntry(original, id)) continue;
        for (function.inputs, 0..) |_, remove| {
            for (0..remove) |kept| {
                var already_removed = false;
                for (pairs.items) |pair| {
                    try budget.take(1);
                    if (pair.function == id and pair.remove == kept) {
                        already_removed = true;
                        break;
                    }
                }
                if (already_removed) continue;
                const pair: Pair = .{ .function = id, .keep = kept, .remove = remove };
                if (!try admissiblePair(original, pair, permissions, &budget)) continue;
                try pairs.append(a, pair);
                break;
            }
        }
    }
    if (pairs.items.len == 0) return null;
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (blocks) |*block| {
        try budget.take(1);
        if (block.terminator != .perform) continue;
        var op = &block.terminator.perform;
        const capabilities = try a.dupe(p.Id, op.use_site_capabilities);
        op.use_site_capabilities = capabilities;
        for (pairs.items) |pair| {
            try budget.take(1);
            if (pair.function != block.function) continue;
            const function = original.functions[@intCast(pair.function)];
            const old = function.inputs[pair.remove];
            const kept = function.inputs[pair.keep];
            if (op.capability == old) op.capability = kept;
            for (capabilities) |*slot| {
                try budget.take(1);
                if (slot.* == old) slot.* = kept;
            }
        }
    }
    var program = original;
    program.blocks = blocks;
    const selected = try pairs.toOwnedSlice(a);
    keep_arena = true;
    return .{ .arena = arena, .program = program, .pairs = selected };
}
pub fn validate(allocator: std.mem.Allocator, original: ir.Program, candidate: ir.Program, pairs: []const Pair, limit: usize) Error!void {
    return validateObserved(allocator, original, candidate, pairs, limit, null);
}
fn validateObserved(allocator: std.mem.Allocator, original: ir.Program, candidate: ir.Program, pairs: []const Pair, limit: usize, observer: ?own.CaptureObserver) Error!void {
    var before = try own.analyzeObserved(allocator, original, null, observer);
    defer before.deinit();
    var after = try own.analyzeObserved(allocator, candidate, null, observer);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const permissions = try traits.derive(arena.allocator(), original.schemas);
    var rest = candidate;
    rest.blocks = original.blocks;
    if (pairs.len == 0 or !equal(ir.Program, original, rest) or original.blocks.len != candidate.blocks.len) return error.InvalidEvidenceForwarding;
    var budget: Budget = .{ .left = limit };
    for (pairs, 0..) |pair, index| {
        // Reconstruct all callers and immutable uses from original records.
        if (!try admissiblePair(original, pair, permissions, &budget)) return error.InvalidEvidenceForwarding;
        for (pairs[0..index]) |prior| if (prior.function == pair.function and
            (prior.remove == pair.remove or prior.keep == pair.remove or prior.remove == pair.keep)) return error.InvalidEvidenceForwarding;
    }
    for (original.blocks, candidate.blocks) |old, new| {
        try budget.record(ir.Block, old);
        try budget.record(ir.Block, new);
        if (old.terminator != .perform) {
            if (!equal(ir.Block, old, new)) return error.InvalidEvidenceForwarding;
            continue;
        }
        if (new.terminator != .perform) return error.InvalidEvidenceForwarding;
        var metadata = new;
        metadata.terminator = old.terminator;
        if (!equal(ir.Block, old, metadata)) return error.InvalidEvidenceForwarding;
        const old_op = old.terminator.perform;
        const new_op = new.terminator.perform;
        var op_metadata = new_op;
        op_metadata.capability = old_op.capability;
        op_metadata.use_site_capabilities = old_op.use_site_capabilities;
        if (!equal(ir.Perform, old_op, op_metadata) or old_op.use_site_capabilities.len != new_op.use_site_capabilities.len) return error.InvalidEvidenceForwarding;
        var expected = old_op.capability;
        for (pairs) |pair| if (pair.function == old.function) {
            try budget.take(1);
            const function = original.functions[@intCast(pair.function)];
            if (old_op.capability == function.inputs[pair.remove]) expected = function.inputs[pair.keep];
        };
        if (new_op.capability != expected) return error.InvalidEvidenceForwarding;
        for (old_op.use_site_capabilities, new_op.use_site_capabilities) |old_slot, new_slot| {
            var expected_slot = old_slot;
            for (pairs) |pair| if (pair.function == old.function) {
                try budget.take(1);
                const function = original.functions[@intCast(pair.function)];
                if (old_slot == function.inputs[pair.remove]) expected_slot = function.inputs[pair.keep];
            };
            if (new_slot != expected_slot) return error.InvalidEvidenceForwarding;
        }
    }
}
pub fn run(allocator: std.mem.Allocator, original: ir.Program, statistics: ?*Statistics, options: Options) Error!p01.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var candidate = (construct(allocator, original, options) catch |err| switch (err) {
        error.EvidenceWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validate(allocator, original, candidate.program, candidate.pairs, options.work_limit) catch |err| switch (err) {
        error.EvidenceWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    var removed: arguments.Statistics = .{};
    const result = try arguments.run(allocator, candidate.program, &removed, options.coalescing);
    stats.parameters_coalesced = candidate.pairs.len;
    stats.call_arguments_removed = removed.call_arguments_removed;
    return result;
}

/// Optional qualification on the actual candidate before dead-argument removal
/// and P01 relocation. The existing record validator remains authoritative.
/// Pair monitors retain site order; nominal targets are compared independently.
/// Agreement is evidence only for this projection, never value equivalence.
pub const InteractionObservation = struct {
    status: enum { established, inconclusive } = .established,
    monitors: usize = 0,
    relations: usize = 0,
    opaque_sites: usize = 0,
    finite_states: usize = 0,
    control_states: usize = 0,
    iterations: usize = 0,
};
pub fn observeInteractions(allocator: std.mem.Allocator, original: ir.Program, candidate: ir.Program, pairs: []const Pair, limit: usize) (Error || @import("interactions.zig").Error)!InteractionObservation {
    const interactions = @import("interactions.zig");
    const provenance = @import("control_provenance.zig");
    const ObserveError = Error || interactions.Error;
    const Collector = struct {
        allocator: std.mem.Allocator,
        pass: usize = 0,
        failure: ?ObserveError = null,
        targets: std.ArrayList([]const provenance.Target) = .empty,
        knowledge: std.ArrayList(provenance.Knowledge) = .empty,
        roots: std.ArrayList(interactions.Summary) = .empty,
        observation: InteractionObservation = .{},
        fn capture(_: *anyopaque, _: p.Id, _: *const own.CaptureSite, _: p.Id) void {}
        fn analyzed(raw: *anyopaque, owner: *const provenance.Analysis) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.failure != null) return;
            self.collect(owner) catch |err| {
                self.failure = err;
            };
            self.pass += 1;
        }
        fn collect(self: *@This(), owner: *const provenance.Analysis) ObserveError!void {
            const program = owner.program();
            var session: interactions.Session = .{ .allocator = self.allocator, .owner = owner };
            defer session.deinit();
            var sites: std.ArrayList(p.Id) = .empty;
            for (program.blocks, 0..) |block, id| if (block.terminator == .perform) {
                const selected = try owner.select(.{ .block = id, .role = .operation }, block.terminator.perform.effect);
                const index = sites.items.len;
                try sites.append(self.allocator, id);
                if (self.pass == 0) {
                    try self.targets.append(self.allocator, try self.allocator.dupe(provenance.Target, selected.targets()));
                    try self.knowledge.append(self.allocator, selected.knowledge());
                } else if (index >= self.targets.items.len or !equal([]const provenance.Target, self.targets.items[index], selected.targets()) or !std.meta.eql(self.knowledge.items[index], selected.knowledge())) {
                    self.observation.status = .inconclusive;
                }
            };
            if (self.pass != 0 and sites.items.len != self.targets.items.len) self.observation.status = .inconclusive;
            const Binding = struct {
                first: p.Id,
                second: p.Id,
                fn project(raw: *const anyopaque, _: ir.Program, site: interactions.Site, _: usize) interactions.Mask {
                    const self_: *const @This() = @ptrCast(@alignCast(raw));
                    if (site.phase != .operation) return 0;
                    return if (site.block == self_.first) 1 else if (site.block == self_.second) 2 else 0;
                }
            };
            var root_index: usize = 0;
            for (sites.items, 0..) |first, index| for (sites.items[index + 1 ..]) |second| {
                const binding = try self.allocator.create(Binding);
                binding.* = .{ .first = first, .second = second };
                const monitor: interactions.Monitor = .{ .binding = binding, .states = 5, .alphabet = 2, .bad = interactions.bit(4), .transitions = &.{ 1, 2, 1, 3, 4, 2, 4, 3, 4, 4 }, .project = Binding.project };
                const result = try session.analyze(monitor);
                if (self.pass == 0) self.observation.monitors += 1;
                self.observation.relations += result.statistics.relations;
                self.observation.opaque_sites += result.statistics.opaque_sites;
                self.observation.finite_states += result.summaries.len;
                self.observation.control_states += result.statistics.control_states;
                self.observation.iterations += result.statistics.iterations;
                for (0..monitor.states) |state| {
                    const root = result.get(program.roots.entry, 0, state);
                    if (root.widened) self.observation.status = .inconclusive;
                    if (self.pass == 0) {
                        try self.roots.append(self.allocator, root);
                    } else if (root_index >= self.roots.items.len or !std.meta.eql(root, self.roots.items[root_index])) {
                        self.observation.status = .inconclusive;
                    }
                    root_index += 1;
                }
            };
            if (self.pass != 0 and root_index != self.roots.items.len) self.observation.status = .inconclusive;
        }
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var collector: Collector = .{ .allocator = arena.allocator() };
    // Admission owns each analysis. Copy only observations needed after its
    // callback; never retain an owner or rederive targets for the property.
    try validateObserved(allocator, original, candidate, pairs, limit, .{ .context = &collector, .capture = Collector.capture, .analyzed = Collector.analyzed });
    if (collector.failure) |err| return err;
    return collector.observation;
}
