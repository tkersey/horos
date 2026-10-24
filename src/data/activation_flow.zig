// Copyright (c) 2026 Boundary contributors. MIT license.
//! Derive initialization, availability and liveness from actual stable-slot code.
//! Roots are private analysis indexes, never supplied certificates. This layer
//! does not yet establish lexical disposal, capture bounds or region safety.
const std = @import("std");
const admission = @import("admission.zig");
const p = @import("program.zig");
const ir = @import("activation.zig");
const sets = @import("analysis_sets.zig");
const structure = @import("activation_structure.zig");
const traits = @import("traits.zig");
pub const Error = structure.Error || @import("admission.zig").Error || error{
    UnavailableSlot,
    OverwrittenOwner,
};

pub const State = struct {
    initialized: sets.Root = sets.empty,
    available: sets.Root = sets.empty,
    /// Nondroppable custody present on any incoming path. This is not permission
    /// to read a slot; only definite availability grants that permission.
    obligations: sets.Root = sets.empty,
};

pub const Facts = struct {
    arena: *std.heap.ArenaAllocator,
    parent_allocator: std.mem.Allocator,
    pool: *sets.Pool,
    entries: []const ?State,
    block_visits: usize,
    /// Entries before each instruction and the terminator; empty if unreachable.
    positions: []const []const State,
    /// Required values plus nondroppable custody at those same code positions.
    live: []const []const sets.Root,
    liveness_visits: usize,

    pub fn view(self: *Facts) View {
        return .{ .pool = self.pool, .positions = self.positions, .live = self.live };
    }

    pub fn deinit(self: *Facts) void {
        self.pool.deinit();
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const View = struct {
    pool: *sets.Pool,
    positions: []const []const State,
    live: []const []const sets.Root,
};

pub fn analyze(allocator: std.mem.Allocator, image: ir.Program) Error!Facts {
    return analyzeComponent(allocator, image, &.{});
}

/// Executable reads required before redefining an input, including transfers
/// whose destinations have no downstream demand. Compiler deletion eligibility only;
/// this must not replace capture/retention liveness.
pub fn analyzeInputDemand(allocator: std.mem.Allocator, image: ir.Program) Error!Facts {
    return analyzeComponentDemand(allocator, image, &.{}, true, null);
}

pub fn analyzeComponent(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
) Error!Facts {
    return analyzeComponentWithWork(allocator, image, imports, null);
}

pub fn analyzeComponentWithWork(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    work: ?*u64,
) Error!Facts {
    return analyzeComponentDemand(allocator, image, imports, false, work);
}

fn analyzeComponentDemand(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    comptime require_edge_sources: bool,
    allowance: ?*u64,
) Error!Facts {
    try structure.validateComponentWithWork(allocator, image, imports, allowance);
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();
    // Work queues, reverse edges and temporary traits die with this analysis.
    // Only returned entries/positions and their set pool belong to Facts.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const pool = try a.create(sets.Pool);
    var limit: usize = 0;
    for (image.functions) |function| {
        try admission.spend(allowance, 1);
        limit = @max(limit, function.layout.slots.len);
    }
    pool.* = .{ .allocator = allocator, .limit = limit, .work = allowance };
    errdefer pool.deinit();
    try admission.spend(allowance, image.blocks.len);
    var analysis: Analysis = .{
        .allowance = allowance,
        .allocator = temporary,
        .retained = a,
        .image = image,
        .pool = pool,
        .uses = try traits.deriveWithWork(temporary, image.schemas, allowance),
        .entries = try a.alloc(?State, image.blocks.len),
        .queued = try temporary.alloc(bool, image.blocks.len),
        .work = try Queue.init(temporary, image.blocks.len),
        .positions = try a.alloc([]State, image.blocks.len),
    };
    @memset(analysis.entries, null);
    @memset(analysis.positions, &.{});
    @memset(analysis.queued, false);
    const index = try analysis.solve(imports);
    const liveness = try Liveness.derive(&analysis, require_edge_sources);
    pool.work = null;
    return .{
        .positions = analysis.positions,
        .live = liveness.positions,
        .liveness_visits = liveness.visits,
        .arena = arena,
        .parent_allocator = allocator,
        .pool = pool,
        .entries = analysis.entries,
        .block_visits = index,
    };
}

const Analysis = struct {
    allowance: ?*u64 = null,
    allocator: std.mem.Allocator,
    retained: std.mem.Allocator,
    image: ir.Program,
    pool: *sets.Pool,
    uses: traits.Facts,
    entries: []?State,
    positions: [][]State,
    queued: []bool,
    work: Queue,

    fn solve(self: *Analysis, imports: []const p.Id) Error!usize {
        try admission.spend(self.allowance, 1);
        for (self.image.functions, 0..) |function, id| {
            try admission.spend(self.allowance, 1);
            try admission.spend(self.allowance, imports.len);
            if (std.mem.indexOfScalar(p.Id, imports, id) != null) continue;
            var inputs = sets.empty;
            var obligations = sets.empty;
            for (function.inputs) |input| {
                try admission.spend(self.allowance, 1);
                inputs = try self.pool.insert(inputs, input);
                const schema = function.layout.slots[@intCast(input)];
                if (!self.uses.drop[@intCast(schema)])
                    obligations = try self.pool.insert(obligations, input);
            }
            try self.merge(function.entry, .{
                .initialized = inputs,
                .available = inputs,
                .obligations = obligations,
            });
        }
        var index: usize = 0;
        while (self.work.pop()) |block_id| {
            try admission.spend(self.allowance, 1);
            index += 1;
            self.queued[@intCast(block_id)] = false;
            try self.block(block_id, false);
        }
        for (self.entries, 0..) |entry, block_id| {
            try admission.spend(self.allowance, 1);
            // A source failure can make a syntactically constructed continuation
            // unreachable. Its references are checked, but it has no entry state.
            if (entry != null) try self.block(block_id, true);
        }
        return index;
    }

    fn merge(self: *Analysis, id: p.Id, incoming: State) Error!void {
        try admission.spend(self.allowance, 1);
        const index: usize = @intCast(id);
        const old = self.entries[index];
        const next: State = if (old) |previous| .{
            .initialized = try self.pool.intersect(previous.initialized, incoming.initialized),
            .available = try self.pool.intersect(previous.available, incoming.available),
            .obligations = try self.pool.unite(previous.obligations, incoming.obligations),
        } else incoming;
        if (old != null and std.meta.eql(old.?, next)) return;
        self.entries[index] = next;
        if (!self.queued[index]) {
            self.work.push(id);
            self.queued[index] = true;
        }
    }

    fn block(self: *Analysis, id: p.Id, checking: bool) Error!void {
        try admission.spend(self.allowance, 1);
        const code = self.image.blocks[@intCast(id)];
        var flow: Flow = .{
            .analysis = self,
            .layout = self.image.functions[@intCast(code.function)].layout.slots,
            .state = self.entries[@intCast(id)].?,
            .checking = checking,
        };
        const position_count = std.math.add(usize, code.instructions.len, 1) catch
            return error.OutOfMemory;
        try admission.spend(self.allowance, position_count);
        if (!checking) {
            if (self.positions[@intCast(id)].len == 0)
                self.positions[@intCast(id)] = try self.retained.alloc(
                    State,
                    position_count,
                );
            self.positions[@intCast(id)][0] = flow.state;
        }
        for (code.instructions, 0..) |instruction, position| {
            try admission.spend(self.allowance, 1);
            for (instruction.operands) |operand| {
                try admission.spend(self.allowance, 1);
                try flow.read(operand, !instruction.opcode.borrowsOperands());
            }
            if (checking) {
                if (self.pool.contains(flow.state.obligations, instruction.destination))
                    return error.OverwrittenOwner;
                // The worklist recorded this transition from the final entry.
                // Reads are still checked/consumed above in the original order.
                flow.state = self.positions[@intCast(id)][position + 1];
            } else {
                try flow.write(instruction.destination);
                self.positions[@intCast(id)][position + 1] = flow.state;
            }
        }
        try controlReads(&flow, code.terminator);
        var next: Successors = .{ .image = self.image, .code = code };
        while (next.next()) |successor| {
            try admission.spend(self.allowance, 1);
            var branch = flow;
            if (code.terminator == .unpack_product) {
                for (code.terminator.unpack_product.destinations) |destination| {
                    try admission.spend(self.allowance, 1);
                    try branch.write(destination);
                }
            }
            try branch.edge(successor.edge, successor.returned);
            if (!checking) try self.merge(successor.edge.block, branch.state);
        }
    }
};

// `queued` admits each block at most once at a time. A FIFO needs one cell per
// block, regardless of the number of fixed-point visits; processed history dies.
const Queue = struct {
    items: []p.Id,
    first: usize = 0,
    next: usize = 0,
    length: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) Error!Queue {
        return .{ .items = try allocator.alloc(p.Id, capacity) };
    }
    fn push(self: *Queue, id: p.Id) void {
        std.debug.assert(self.length < self.items.len);
        self.items[self.next] = id;
        self.next = if (self.next + 1 == self.items.len) 0 else self.next + 1;
        self.length += 1;
    }
    fn pop(self: *Queue) ?p.Id {
        if (self.length == 0) return null;
        const id = self.items[self.first];
        self.first = if (self.first + 1 == self.items.len) 0 else self.first + 1;
        self.length -= 1;
        return id;
    }
};

const Flow = struct {
    analysis: *Analysis,
    layout: []const p.Id,
    state: State,
    checking: bool,

    fn read(self: *Flow, slot: p.Id, consuming: bool) Error!void {
        try admission.spend(self.analysis.allowance, 1);
        const pool = self.analysis.pool;
        if (self.checking and (!pool.contains(self.state.initialized, slot) or
            (self.state.available != self.state.initialized and !pool.contains(
                self.state.available,
                slot,
            )))) return error.UnavailableSlot;
        if (consuming and !self.analysis.uses.copy[@intCast(self.layout[@intCast(slot)])]) {
            const available = self.state.available;
            self.state.available = try pool.remove(available, slot);
            self.state.obligations = if (self.state.obligations == available)
                self.state.available
            else
                try pool.remove(self.state.obligations, slot);
        }
    }

    fn readAll(self: *Flow, slots: []const p.Id) Error!void {
        try admission.spend(self.analysis.allowance, 1);
        for (slots) |slot| {
            try admission.spend(self.analysis.allowance, 1);
            try self.read(slot, true);
        }
    }

    fn write(self: *Flow, slot: p.Id) Error!void {
        try admission.spend(self.analysis.allowance, 1);
        const pool = self.analysis.pool;
        if (self.checking and pool.contains(self.state.obligations, slot))
            return error.OverwrittenOwner;
        const before = self.state;
        self.state.initialized = try pool.insert(before.initialized, slot);
        self.state.available = if (before.available == before.initialized)
            self.state.initialized
        else
            try pool.insert(before.available, slot);
        if (!self.analysis.uses.drop[@intCast(self.layout[@intCast(slot)])])
            self.state.obligations = if (before.obligations == before.initialized)
                self.state.initialized
            else if (before.obligations == before.available)
                self.state.available
            else
                try pool.insert(before.obligations, slot);
    }

    fn edge(self: *Flow, next: ir.Edge, returned: ?p.Id) Error!void {
        try admission.spend(self.analysis.allowance, 1);
        // All sources are consumed/read in the predecessor view before any
        // destination is established. This admits swaps without sequential writes.
        var returned_used = false;
        for (next.assignments) |assignment| {
            try admission.spend(self.analysis.allowance, 1);
            switch (assignment.source) {
                .slot => |slot| try self.read(slot, true),
                .returned => {
                    if (self.checking and returned_used and
                        !self.analysis.uses.copy[@intCast(returned.?)])
                        return error.InvalidOwnership;
                    returned_used = true;
                },
            }
        }
        if (self.checking and !returned_used) {
            if (returned) |schema| if (!self.analysis.uses.drop[@intCast(schema)])
                return error.InvalidOwnership;
        }
        for (next.assignments) |assignment| {
            try admission.spend(self.analysis.allowance, 1);
            try self.write(assignment.destination);
        }
    }
};

fn controlReads(self: anytype, control: ir.Terminator) Error!void {
    switch (control) {
        .return_value => |slot| try self.read(slot, true),
        .fail => |slot| try self.read(slot, false),
        .jump, .yield_value => {},
        .branch => |branch| try self.read(branch.condition, true),
        .switch_variant => |selected| try self.read(selected.value, true),
        .unpack_product => |unpack| try self.read(unpack.value, true),
        .call => |call| try self.readAll(call.arguments),
        .perform => |operation| {
            try self.read(operation.payload, true);
            try self.readAll(operation.bodies);
            if (operation.capability) |slot| try self.read(slot, true);
            try self.readAll(operation.use_site_capabilities);
        },
        .apply => |apply| {
            try self.read(apply.computation, true);
            try self.readAll(apply.arguments);
        },
        .handle => |handle| {
            try self.read(handle.body, true);
            try self.readAll(handle.arguments);
            try self.readAll(handle.state);
        },
        .resume_value => |resume_value| {
            try self.read(resume_value.resumption, true);
            try self.read(resume_value.argument, true);
        },
        .resume_with => |resume_with| {
            try self.read(resume_with.resumption, true);
            try self.read(resume_with.argument, true);
            try self.readAll(resume_with.state);
        },
        .resume_computation => |resume_computation| {
            try self.read(resume_computation.resumption, true);
            try self.read(resume_computation.computation, true);
        },
        .dispose => |dispose| try self.read(dispose.owned, true),
        .protect => |protect| {
            try self.read(protect.body, true);
            try self.read(protect.cleanup, true);
            try self.readAll(protect.arguments);
            if (protect.resource) |slot| try self.read(slot, true);
        },
        .with_region => |region| {
            try self.read(region.body, true);
            try self.readAll(region.arguments);
        },
    }
}

const Liveness = struct {
    // Compact rows reduce 64-bit scratch overhead. Keep the qualified 32-bit
    // builder: compact construction regresses measured WASM consumer latency.
    const compact_parents = @sizeOf(usize) > 4;
    const ParentRow = if (compact_parents) []p.Id else std.ArrayList(p.Id);
    analysis: *Analysis,
    entries: []sets.Root,
    positions: [][]sets.Root,
    parents: []ParentRow,
    queued: []bool,
    work: Queue,
    visits: usize = 0,

    fn derive(analysis: *Analysis, comptime require_edge_sources: bool) Error!Liveness {
        const a = analysis.allocator;
        const image = analysis.image;
        try admission.spend(analysis.allowance, image.blocks.len);
        var result: Liveness = .{
            .analysis = analysis,
            .entries = try a.alloc(sets.Root, image.blocks.len),
            .positions = try analysis.retained.alloc([]sets.Root, image.blocks.len),
            .parents = try a.alloc(ParentRow, image.blocks.len),
            .queued = try a.alloc(bool, image.blocks.len),
            .work = try Queue.init(a, image.blocks.len),
        };
        @memset(result.entries, sets.empty);
        @memset(result.positions, &.{});
        if (comptime !compact_parents) @memset(result.parents, .empty);
        @memset(result.queued, false);
        try result.deriveParents();
        var remaining = image.blocks.len;
        while (remaining != 0) {
            try admission.spend(analysis.allowance, 1);
            remaining -= 1;
            if (analysis.entries[remaining] != null) try result.enqueue(remaining);
        }
        while (result.work.pop()) |id| {
            try admission.spend(analysis.allowance, 1);
            result.visits += 1;
            result.queued[@intCast(id)] = false;
            const root = try result.block(id, require_edge_sources);
            if (root == result.entries[@intCast(id)]) continue;
            result.entries[@intCast(id)] = root;
            const parents = if (comptime compact_parents) result.parents[
                @intCast(id)
            ] else result.parents[
                @intCast(id)
            ].items;
            for (parents) |parent| {
                try admission.spend(analysis.allowance, 1);
                try result.enqueue(parent);
            }
        }
        return result;
    }

    fn deriveParents(self: *Liveness) Error!void {
        try admission.spend(self.analysis.allowance, 1);
        const a = self.analysis.allocator;
        const image = self.analysis.image;
        if (comptime compact_parents) {
            const counts = try a.alloc(usize, image.blocks.len);
            @memset(counts, 0);
            var edge_count: usize = 0;
            for (image.blocks, 0..) |code, id| {
                try admission.spend(self.analysis.allowance, 1);
                if (self.analysis.entries[id] == null) continue;
                var successors: Successors = .{ .image = image, .code = code };
                while (successors.next()) |next| {
                    try admission.spend(self.analysis.allowance, 1);
                    const child: usize = @intCast(next.edge.block);
                    counts[child] = std.math.add(
                        usize,
                        counts[child],
                        1,
                    ) catch return error.OutOfMemory;
                    edge_count = std.math.add(usize, edge_count, 1) catch return error.OutOfMemory;
                }
            }
            try admission.spend(self.analysis.allowance, edge_count);
            const parents = try a.alloc(p.Id, edge_count);
            var offset: usize = 0;
            for (self.parents, counts) |*row, count| {
                try admission.spend(self.analysis.allowance, 1);
                row.* = parents[offset..][0..count];
                offset += count;
            }
            // Replay the same immutable edge traversal, preserving predecessor order.
            @memset(counts, 0);
            for (image.blocks, 0..) |code, id| {
                try admission.spend(self.analysis.allowance, 1);
                if (self.analysis.entries[id] == null) continue;
                var successors: Successors = .{ .image = image, .code = code };
                while (successors.next()) |next| {
                    try admission.spend(self.analysis.allowance, 1);
                    const child: usize = @intCast(next.edge.block);
                    self.parents[child][counts[child]] = id;
                    counts[child] += 1;
                }
            }
        } else {
            for (image.blocks, 0..) |code, id| {
                try admission.spend(self.analysis.allowance, 1);
                if (self.analysis.entries[id] == null) continue;
                var successors: Successors = .{ .image = image, .code = code };
                while (successors.next()) |next| {
                    try admission.spend(self.analysis.allowance, 1);
                    try self.parents[@intCast(next.edge.block)].append(a, id);
                }
            }
        }
    }

    fn enqueue(self: *Liveness, id: p.Id) Error!void {
        try admission.spend(self.analysis.allowance, 1);
        if (self.queued[@intCast(id)]) return;
        self.work.push(id);
        self.queued[@intCast(id)] = true;
    }

    fn pinOwners(self: *Liveness, id: p.Id, position: usize, root: sets.Root) Error!sets.Root {
        try admission.spend(self.analysis.allowance, 1);
        const obligations = self.analysis.positions[@intCast(id)][position].obligations;
        return self.analysis.pool.unite(root, obligations);
    }

    fn edge(self: *Liveness, next: ir.Edge, comptime require_edge_sources: bool) Error!sets.Root {
        try admission.spend(self.analysis.allowance, 1);
        const pool = self.analysis.pool;
        const after = self.entries[@intCast(next.block)];
        var before = after;
        // Invert the simultaneous assignment: clear all destinations before
        // adding any required predecessor sources, including cyclic swaps.
        for (next.assignments) |assignment| {
            try admission.spend(self.analysis.allowance, 1);
            before = try pool.remove(
                before,
                assignment.destination,
            );
        }
        for (next.assignments) |assignment| {
            try admission.spend(self.analysis.allowance, 1);
            if (assignment.source == .slot and (require_edge_sources or pool.contains(
                after,
                assignment.destination,
            )))
                before = try pool.insert(before, assignment.source.slot);
        }
        return before;
    }

    fn block(self: *Liveness, id: p.Id, comptime require_edge_sources: bool) Error!sets.Root {
        try admission.spend(self.analysis.allowance, 1);
        const code = self.analysis.image.blocks[@intCast(id)];
        const pool = self.analysis.pool;
        var live: LiveReads = .{ .pool = pool };
        var successors: Successors = .{ .image = self.analysis.image, .code = code };
        while (successors.next()) |next| {
            try admission.spend(self.analysis.allowance, 1);
            var root = try self.edge(next.edge, require_edge_sources);
            if (code.terminator == .unpack_product)
                root = try pool.excluding(root, code.terminator.unpack_product.destinations);
            live.root = try pool.unite(live.root, root);
        }
        try controlReads(&live, code.terminator);
        const position_count = std.math.add(usize, code.instructions.len, 1) catch
            return error.OutOfMemory;
        try admission.spend(self.analysis.allowance, position_count);
        var position = code.instructions.len;
        live.root = try self.pinOwners(id, position, live.root);
        if (self.positions[@intCast(id)].len == 0)
            self.positions[@intCast(id)] = try self.analysis.retained.alloc(
                sets.Root,
                position_count,
            );
        self.positions[@intCast(id)][position] = live.root;
        while (position != 0) {
            try admission.spend(self.analysis.allowance, 1);
            position -= 1;
            const operation = code.instructions[position];
            live.root = try pool.remove(live.root, operation.destination);
            try live.readAll(operation.operands);
            live.root = try self.pinOwners(id, position, live.root);
            self.positions[@intCast(id)][position] = live.root;
        }
        return live.root;
    }
};

const LiveReads = struct {
    pool: *sets.Pool,
    root: sets.Root = sets.empty,

    fn read(self: *LiveReads, slot: p.Id, _: bool) Error!void {
        self.root = try self.pool.insert(self.root, slot);
    }

    fn readAll(self: *LiveReads, slots: []const p.Id) Error!void {
        for (slots) |slot| try self.read(slot, false);
    }
};

const Successor = struct { edge: ir.Edge, returned: ?p.Id = null };
const Successors = struct {
    image: ir.Program,
    code: ir.Block,
    index: usize = 0,

    fn shape(self: Successors, slot: p.Id) p.Schema {
        const layout = self.image.functions[@intCast(self.code.function)].layout.slots;
        return self.image.schemas[@intCast(layout[@intCast(slot)])];
    }

    fn next(self: *Successors) ?Successor {
        const index = self.index;
        self.index += 1;
        switch (self.code.terminator) {
            .return_value, .fail => return null,
            .branch => |branch| return switch (index) {
                0 => .{ .edge = branch.when_true },
                1 => .{ .edge = branch.when_false },
                else => null,
            },
            .switch_variant => |selected| return if (index < selected.cases.len) .{
                .edge = selected.cases[index],
                .returned = self.shape(selected.value).sum[index],
            } else null,
            else => if (index != 0) return null,
        }
        return switch (self.code.terminator) {
            .jump, .yield_value => |edge| .{ .edge = edge },
            .unpack_product => |unpack| .{ .edge = unpack.next },
            .call => |call| .{
                .edge = call.next,
                .returned = self.image.functions[@intCast(call.function)].result,
            },
            .perform => |perform| .{
                .edge = perform.next,
                .returned = self.image.effects[@intCast(perform.effect)].result,
            },
            .apply => |apply| .{
                .edge = apply.next,
                .returned = self.shape(apply.computation).internal.computation.result,
            },
            .handle => |handle| .{
                .edge = handle.next,
                .returned = self.image.handlers[@intCast(handle.handler)].answer,
            },
            inline .resume_value, .resume_computation => |operation| .{
                .edge = operation.next,
                .returned = self.shape(operation.resumption).internal.resumption.answer,
            },
            .resume_with => |operation| .{
                .edge = operation.next,
                .returned = self.image.handlers[@intCast(operation.handler)].answer,
            },
            .dispose => |dispose| .{ .edge = dispose.next },
            inline .protect, .with_region => |operation| .{
                .edge = operation.next,
                .returned = self.shape(operation.body).internal.computation.result,
            },
            else => unreachable, // Exhausted or returned above.
        };
    }
};
