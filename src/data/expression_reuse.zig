// Copyright (c) 2026 Boundary contributors. MIT license.
//! Must-availability of total immutable expression definitions across the CFG.
//! A separate backwards proof checks each raw-record replacement.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
pub const Error = coalescing.Error || error{ InvalidExpressionReuse, ExpressionWorkLimit };
pub const Options = struct { work_limit: u64 = 1_000_000, coalescing: coalescing.Options = .{} };
pub const Statistics = struct {
    expressions_reused: usize = 0,
    across_blocks: usize = 0,
    work: u64 = 0,
    work_limit: bool = false,
    proof_unavailable: usize = 0,
    eligible_definitions: usize = 0,
    tracked_definitions: usize = 0,
    phase: enum {
        discovery,
        availability,
        rewriting,
        validation,
    } = .discovery,
};
pub const Location = struct { block: usize, instruction: usize };
pub const Witness = struct { target: Location, source: Location };
const Definition = struct {
    location: Location,
    function: p.Id,
    instruction: ir.Instruction,
    schema: p.Id,
};
const Budget = struct {
    remaining: u64,
    used: u64 = 0,
    exhausted: bool = false,
    fn tick(self: *Budget) bool {
        if (self.remaining == 0) {
            self.exhausted = true;
            return false;
        }
        self.remaining -= 1;
        self.used += 1;
        return true;
    }
};

fn eligible(
    program: ir.Program,
    block: ir.Block,
    op: ir.Instruction,
    permissions: traits.Facts,
) bool {
    if (op.failures.len != 0) return false;
    const slots = program.functions[@intCast(block.function)].layout.slots;
    if (!permissions.copy[
        @intCast(slots[
            @intCast(op.destination)
        ])
    ] or !permissions.drop[
        @intCast(slots[
            @intCast(op.destination)
        ])
    ]) return false;
    for (op.operands) |slot| {
        if (slot == op.destination or !permissions.copy[
            @intCast(slots[
                @intCast(slot)
            ])
        ] or !permissions.drop[
            @intCast(slots[
                @intCast(slot)
            ])
        ]) return false;
    }
    return canNumber(op.opcode);
}
pub fn canNumber(opcode: p.Opcode) bool {
    return switch (opcode) {
        .constant,
        .equal,
        .less,
        .boolean_not,
        .integer_bit_not,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .product,
        .field,
        .variant,
        .variant_tag,
        .enum_tag,
        .sequence_length,
        .select,
        => true,
        else => false,
    };
}
fn sameExpression(left: ir.Instruction, right: ir.Instruction) bool {
    var normalized = right;
    normalized.destination = left.destination;
    return equal(ir.Instruction, left, normalized);
}
fn relevant(definition: Definition, slot: p.Id) bool {
    return definition.instruction.destination == slot or std.mem.indexOfScalar(
        p.Id,
        definition.instruction.operands,
        slot,
    ) != null;
}
fn edgePreserves(definition: Definition, edge: ir.Edge, overwritten: []const p.Id) bool {
    for (overwritten) |slot| if (relevant(definition, slot)) return false;
    for (edge.assignments) |assignment| {
        if (!relevant(definition, assignment.destination)) continue;
        if (assignment.source != .slot or
            assignment.source.slot != assignment.destination)
            return false;
    }
    return true;
}
const Incoming = struct {
    edge: ir.Edge,
    overwritten: []const p.Id = &.{},
    capture_boundary: bool = false,
};
const Predecessor = struct { block: usize, transfer: Incoming };
fn indexPredecessors(
    allocator: std.mem.Allocator,
    program: ir.Program,
    budget: *Budget,
) Error![]std.ArrayList(Predecessor) {
    const result = try allocator.alloc(std.ArrayList(Predecessor), program.blocks.len);
    for (result) |*items| items.* = .empty;
    for (program.blocks, 0..) |block, id| {
        var edge_index: usize = 0;
        while (successor(block.terminator, edge_index)) |transfer| : (edge_index += 1) {
            if (!budget.tick()) return error.ExpressionWorkLimit;
            try result[@intCast(transfer.edge.block)].append(
                allocator,
                .{ .block = id, .transfer = transfer },
            );
        }
    }
    return result;
}
fn successor(term: ir.Terminator, index: usize) ?Incoming {
    return switch (term) {
        .return_value, .fail => null,
        .branch => |v| if (index == 0) .{ .edge = v.when_true } else if (index == 1) .{
            .edge = v.when_false,
        } else null,
        .switch_variant => |v| if (index < v.cases.len) .{ .edge = v.cases[index] } else null,
        .jump => |v| if (index == 0) .{ .edge = v } else null,
        .yield_value => |v| if (index == 0) .{ .edge = v, .capture_boundary = true } else null,
        .unpack_product => |v| if (index == 0) .{
            .edge = v.next,
            .overwritten = v.destinations,
        } else null,
        inline else => |v| if (index == 0) .{ .edge = v.next, .capture_boundary = true } else null,
    };
}
fn representative(parents: []usize, start: usize) usize {
    var root = start;
    while (parents[root] != root) root = parents[root];
    var cursor = start;
    while (parents[cursor] != cursor) {
        const next = parents[cursor];
        parents[cursor] = root;
        cursor = next;
    }
    return root;
}

pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!coalescing.Owned {
    var stats: Statistics = .{};
    var budget: Budget = .{ .remaining = options.work_limit };
    defer if (statistics) |out| {
        stats.work = budget.used;
        out.* = stats;
    };
    var flow = try ownership.analyze(allocator, original);
    defer flow.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    var search: Search = .{
        .a = a,
        .allocator = allocator,
        .original = original,
        .stats = &stats,
        .budget = &budget,
        .flow = &flow,
        .permissions = permissions,
    };
    const candidate = search.construct() catch |err| {
        if (err == error.ExpressionWorkLimit) return rollback(allocator, original, &stats, options);
        return err;
    };
    return coalescing.run(allocator, candidate, options.coalescing);
}
const Search = struct {
    a: std.mem.Allocator,
    allocator: std.mem.Allocator,
    original: ir.Program,
    stats: *Statistics,
    budget: *Budget,
    flow: *@import("activation_flow.zig").Facts,
    permissions: traits.Facts,
    all_defs: []const Definition = &.{},
    regions: []usize = &.{},
    region_defs: []std.ArrayList(Definition) = &.{},
    predecessors: []const std.ArrayList(Predecessor) = &.{},
    entries: [][]bool = &.{},
    exits: [][]bool = &.{},
    scratch_state: []bool = &.{},
    blocks: []ir.Block = &.{},
    witnesses: std.ArrayList(Witness) = .empty,
    fn construct(self: *Search) Error!ir.Program {
        try self.collectDefinitions();
        try self.indexRegions();
        try self.indexRepeated();
        try self.initializeAvailability();
        try self.deriveAvailability();
        try self.rewrite();
        return self.validateCandidate();
    }
    fn collectDefinitions(self: *Search) Error!void {
        var definitions: std.ArrayList(Definition) = .empty;
        for (self.original.blocks, 0..) |block, bid| for (block.instructions, 0..) |op, index| {
            if (!self.budget.tick()) return error.ExpressionWorkLimit;
            if (!eligible(self.original, block, op, self.permissions)) continue;
            try definitions.append(
                self.a,
                .{
                    .location = .{ .block = bid, .instruction = index },
                    .function = block.function,
                    .instruction = op,
                    .schema = self.original.functions[
                        @intCast(block.function)
                    ].layout.slots[
                        @intCast(op.destination)
                    ],
                },
            );
        };
        self.all_defs = definitions.items;
        self.stats.eligible_definitions = self.all_defs.len;
    }
    fn indexRegions(self: *Search) Error!void {
        // A capture boundary kills every reuse fact. Build only the transparent
        // control-flow components in which a producer can possibly justify a use.
        self.regions = try self.a.alloc(usize, self.original.blocks.len);
        for (self.regions, 0..) |*region, id| region.* = id;
        for (self.original.blocks, 0..) |block, id| {
            var edge_index: usize = 0;
            while (successor(block.terminator, edge_index)) |transfer| : (edge_index += 1) {
                if (!self.budget.tick()) return error.ExpressionWorkLimit;
                if (transfer.capture_boundary) continue;
                const left = representative(self.regions, id);
                const right = representative(self.regions, @intCast(transfer.edge.block));
                self.regions[@max(left, right)] = @min(left, right);
            }
        }
        for (0..self.regions.len) |id| self.regions[id] = representative(self.regions, id);
        self.region_defs = try self.a.alloc(std.ArrayList(Definition), self.original.blocks.len);
        self.predecessors = try indexPredecessors(self.a, self.original, self.budget);
        for (self.region_defs) |*items| items.* = .empty;
    }
    fn indexRepeated(self: *Search) Error!void {
        // Only an expression with another exact occurrence can be reused. Hashes
        // select comparison buckets; function/schema/raw operands decide identity.
        const repeated = try self.a.alloc(bool, self.all_defs.len);
        const next_definition = try self.a.alloc(?usize, self.all_defs.len);
        @memset(repeated, false);
        @memset(next_definition, null);
        var buckets: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        for (self.all_defs, 0..) |definition, id| {
            if (!self.budget.tick()) return error.ExpressionWorkLimit;
            var hash = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hash, definition.function);
            std.hash.autoHash(&hash, self.regions[definition.location.block]);
            std.hash.autoHash(&hash, definition.schema);
            std.hash.autoHash(&hash, definition.instruction.opcode);
            std.hash.autoHash(&hash, definition.instruction.immediate);
            std.hash.autoHash(&hash, definition.instruction.operands.len);
            for (definition.instruction.operands) |operand| {
                if (!self.budget.tick()) return error.ExpressionWorkLimit;
                std.hash.autoHash(&hash, operand);
            }
            const key = hash.final();
            var cursor: ?usize = buckets.get(key);
            var found = false;
            while (cursor) |prior| {
                if (!self.budget.tick()) return error.ExpressionWorkLimit;
                const other = self.all_defs[prior];
                if (self.regions[definition.location.block] ==
                    self.regions[other.location.block] and
                    definition.function == other.function and
                    definition.schema == other.schema and
                    sameExpression(definition.instruction, other.instruction))
                {
                    repeated[id] = true;
                    repeated[prior] = true;
                    found = true;
                    break;
                }
                cursor = next_definition[prior];
            }
            if (!found) {
                next_definition[id] = buckets.get(key);
                try buckets.put(self.a, key, id);
            }
        }
        for (self.all_defs, repeated) |definition, needed| {
            if (needed) {
                try self.region_defs[self.regions[definition.location.block]].append(
                    self.a,
                    definition,
                );
                self.stats.tracked_definitions += 1;
            }
        }
    }
    fn initializeAvailability(self: *Search) Error!void {
        self.entries = try self.a.alloc([]bool, self.original.blocks.len);
        self.stats.phase = .availability;
        self.exits = try self.a.alloc([]bool, self.original.blocks.len);
        for (self.original.blocks, self.entries, self.exits, 0..) |block, *entry, *out, bid| {
            const defs = self.region_defs[self.regions[bid]].items;
            entry.* = try self.a.alloc(bool, defs.len);
            out.* = try self.a.alloc(bool, defs.len);
            for (defs, entry.*, out.*) |definition, *inside, *outside| {
                if (!self.budget.tick()) return error.ExpressionWorkLimit;
                inside.* = definition.function == block.function and
                    self.flow.positions[bid].len != 0 and
                    self.original.functions[
                        @intCast(block.function)
                    ].entry != bid;
                outside.* = inside.*;
            }
        }
    }
    fn deriveAvailability(self: *Search) Error!void {
        self.scratch_state = try self.a.alloc(bool, self.all_defs.len);
        var pending: std.ArrayList(usize) = .empty;
        const queued = try self.a.alloc(bool, self.original.blocks.len);
        @memset(queued, true);
        for (0..self.original.blocks.len) |id| try pending.append(self.a, id);
        var head: usize = 0;
        while (head < pending.items.len) {
            if (!self.budget.tick()) return error.ExpressionWorkLimit;
            const bid = pending.items[head];
            head += 1;
            queued[bid] = false;
            const block = self.original.blocks[bid];
            const defs = self.region_defs[self.regions[bid]].items;
            const state = self.scratch_state[0..defs.len];
            if (self.flow.positions[bid].len == 0) continue;
            const entry_block = self.original.functions[@intCast(block.function)].entry == bid;
            for (defs, 0..) |definition, d| {
                var available = !entry_block and definition.function == block.function;
                var count: usize = 0;
                for (self.predecessors[bid].items) |predecessor| {
                    if (!self.budget.tick()) return error.ExpressionWorkLimit;
                    const pred = predecessor.block;
                    if (self.flow.positions[pred].len == 0) continue;
                    const incoming = predecessor.transfer;
                    count += 1;
                    available = available and
                        !incoming.capture_boundary and
                        self.exits[pred][d] and
                        edgePreserves(definition, incoming.edge, incoming.overwritten);
                }
                self.entries[bid][d] = available and count != 0;
            }
            @memcpy(state, self.entries[bid]);
            for (block.instructions, 0..) |op, index|
                for (defs, 0..) |definition, d| {
                    if (!self.budget.tick()) return error.ExpressionWorkLimit;
                    if (relevant(definition, op.destination)) state[d] = false;
                    if (definition.location.block == bid and
                        definition.location.instruction == index)
                        state[d] = true;
                };
            if (!std.mem.eql(bool, state, self.exits[bid])) {
                @memcpy(self.exits[bid], state);
                var edge_index: usize = 0;
                while (successor(block.terminator, edge_index)) |transfer| : (edge_index += 1) {
                    if (!self.budget.tick()) return error.ExpressionWorkLimit;
                    if (transfer.capture_boundary) continue;
                    const target: usize = @intCast(transfer.edge.block);
                    if (!queued[target]) {
                        try pending.append(self.a, target);
                        queued[target] = true;
                    }
                }
            }
        }
    }
    fn rewrite(self: *Search) Error!void {
        self.blocks = try self.a.dupe(ir.Block, self.original.blocks);
        self.stats.phase = .rewriting;
        self.witnesses = .empty;
        for (self.original.blocks, self.blocks, 0..) |block, *out, bid| {
            const defs = self.region_defs[self.regions[bid]].items;
            const state = self.scratch_state[0..defs.len];
            const instructions = try self.a.dupe(ir.Instruction, block.instructions);
            out.instructions = instructions;
            @memcpy(state, self.entries[bid]);
            for (block.instructions, 0..) |op, index| {
                if (self.flow.positions[bid].len != 0 and
                    eligible(self.original, block, op, self.permissions))
                {
                    try self.tryRewrite(block, op, index, bid, defs, state, instructions);
                }
                for (defs, 0..) |definition, d| {
                    if (!self.budget.tick()) return error.ExpressionWorkLimit;
                    if (relevant(definition, op.destination)) state[d] = false;
                    if (definition.location.block == bid and
                        definition.location.instruction == index)
                        state[d] = true;
                }
            }
        }
    }
    fn tryRewrite(
        self: *Search,
        block: ir.Block,
        op: ir.Instruction,
        index: usize,
        bid: usize,
        defs: []const Definition,
        state: []const bool,
        instructions: []ir.Instruction,
    ) Error!void {
        for (defs, state) |definition, available| {
            if (!self.budget.tick()) return error.ExpressionWorkLimit;
            if (!available or
                definition.function != block.function or
                definition.schema != self.original.functions[
                    @intCast(block.function)
                ].layout.slots[
                    @intCast(op.destination)
                ] or
                !sameExpression(definition.instruction, op))
                continue;
            if (!self.flow.pool.contains(
                self.flow.positions[bid][index].available,
                definition.instruction.destination,
            )) continue;
            const witness: Witness = .{
                .target = .{ .block = bid, .instruction = index },
                .source = definition.location,
            };
            if (!try proves(
                self.allocator,
                self.original,
                witness,
                self.predecessors,
                self.budget,
            )) {
                if (self.budget.exhausted) return error.ExpressionWorkLimit;
                self.stats.proof_unavailable += 1;
                continue;
            }
            instructions[index] = .{
                .destination = op.destination,
                .opcode = .move,
                .operands = try self.a.dupe(
                    p.Id,
                    &.{definition.instruction.destination},
                ),
            };
            try self.witnesses.append(self.a, witness);
            break;
        }
    }
    fn validateCandidate(self: *Search) Error!ir.Program {
        var candidate = self.original;
        candidate.blocks = self.blocks;
        self.stats.phase = .validation;
        try validateWithBudget(
            self.allocator,
            self.original,
            candidate,
            self.witnesses.items,
            self.budget,
        );
        self.stats.expressions_reused = self.witnesses.items.len;
        for (self.witnesses.items) |item| if (item.source.block != item.target.block) {
            self.stats.across_blocks += 1;
        };
        return candidate;
    }
};
fn rollback(
    allocator: std.mem.Allocator,
    original: ir.Program,
    stats: *Statistics,
    options: Options,
) Error!coalescing.Owned {
    stats.work_limit = true;
    stats.expressions_reused = 0;
    stats.across_blocks = 0;
    return coalescing.run(allocator, original, options.coalescing);
}

const Proof = struct {
    program: ir.Program,
    definition: Definition,
    cache: []enum { unseen, active, yes, no },
    budget: *Budget,
    predecessors: []const std.ArrayList(Predecessor),
    const Frame = struct {
        block_id: usize,
        next: usize = 0,
        count: usize = 0,
        full: bool,
    };
    const Resolution = enum { pending, yes, no };
    fn enter(self: *Proof, frame: Frame, before: usize, depth: usize) Resolution {
        if (!self.budget.tick()) return .no;
        if (depth == 256) return .no;
        if (frame.full) switch (self.cache[frame.block_id]) {
            .active, .no => return .no,
            .yes => return .yes,
            .unseen => {},
        };
        if (frame.full) self.cache[frame.block_id] = .active;
        var result: Resolution = .no;
        defer if (frame.full and result != .pending) {
            self.cache[frame.block_id] = if (result == .yes) .yes else .no;
        };
        const block = self.program.blocks[frame.block_id];
        var cursor = before;
        while (cursor != 0) {
            if (!self.budget.tick()) return .no;
            cursor -= 1;
            if (self.definition.location.block == frame.block_id and
                self.definition.location.instruction == cursor)
            {
                result = .yes;
                return result;
            }
            if (relevant(self.definition, block.instructions[cursor].destination)) return .no;
        }
        if (self.program.functions[@intCast(block.function)].entry == frame.block_id) return .no;
        result = .pending;
        return result;
    }
    fn resolve(self: *Proof, block_id: usize, before: usize) bool {
        var frames: [256]Frame = undefined;
        frames[0] = .{
            .block_id = block_id,
            .full = before == self.program.blocks[block_id].instructions.len,
        };
        switch (self.enter(frames[0], before, 0)) {
            .yes => return true,
            .no => return false,
            .pending => {},
        }
        var count: usize = 1;
        defer for (frames[0..count]) |frame| {
            if (frame.full) self.cache[frame.block_id] = .no;
        };
        while (count != 0) {
            const frame = &frames[count - 1];
            const incoming = self.predecessors[frame.block_id].items;
            if (frame.next == incoming.len) {
                if (frame.count == 0) return false;
                if (frame.full) self.cache[frame.block_id] = .yes;
                count -= 1;
                continue;
            }
            if (!self.budget.tick()) return false;
            const indexed = incoming[frame.next];
            frame.next += 1;
            const predecessor = self.program.blocks[indexed.block];
            if (predecessor.function != self.program.blocks[frame.block_id].function) continue;
            frame.count += 1;
            if (indexed.transfer.capture_boundary or !edgePreserves(
                self.definition,
                indexed.transfer.edge,
                indexed.transfer.overwritten,
            )) return false;
            const child: Frame = .{ .block_id = indexed.block, .full = true };
            switch (self.enter(child, predecessor.instructions.len, count)) {
                .no => return false,
                .yes => continue,
                .pending => {
                    frames[count] = child;
                    count += 1;
                },
            }
        }
        return true;
    }
};
fn proves(
    allocator: std.mem.Allocator,
    program: ir.Program,
    witness: Witness,
    predecessors: []const std.ArrayList(Predecessor),
    budget: *Budget,
) std.mem.Allocator.Error!bool {
    if (witness.source.block >= program.blocks.len or
        witness.target.block >= program.blocks.len)
        return false;
    const source = program.blocks[witness.source.block];
    const target = program.blocks[witness.target.block];
    if (source.function != target.function or
        witness.source.instruction >= source.instructions.len or
        witness.target.instruction >= target.instructions.len)
        return false;
    const op = source.instructions[witness.source.instruction];
    if (!sameExpression(op, target.instructions[witness.target.instruction])) return false;
    var proof: Proof = .{
        .program = program,
        .definition = .{
            .location = witness.source,
            .function = source.function,
            .instruction = op,
            .schema = program.functions[
                @intCast(source.function)
            ].layout.slots[
                @intCast(op.destination)
            ],
        },
        .cache = undefined,
        .budget = budget,
        .predecessors = predecessors,
    };
    proof.cache = try allocator.alloc(
        @typeInfo(@TypeOf(proof.cache)).pointer.child,
        program.blocks.len,
    );
    defer allocator.free(proof.cache);
    @memset(proof.cache, .unseen);
    return proof.resolve(witness.target.block, witness.target.instruction);
}

pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var budget: Budget = .{ .remaining = 1_000_000 };
    return validateWithBudget(allocator, original, candidate, witnesses, &budget);
}
fn validateWithBudget(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
) Error!void {
    var flow = try ownership.analyze(allocator, original);
    defer flow.deinit();
    var checked = try ownership.analyze(allocator, candidate);
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const permissions = try traits.derive(arena.allocator(), original.schemas);
    const predecessors = try indexPredecessors(arena.allocator(), original, budget);
    var same = candidate;
    same.blocks = original.blocks;
    if (!equal(
        ir.Program,
        original,
        same,
    ) or original.blocks.len != candidate.blocks.len) return error.InvalidExpressionReuse;
    const targets = try indexWitnesses(arena.allocator(), original, witnesses, budget);
    for (original.blocks, candidate.blocks, 0..) |before, after, bid| {
        if (!budget.tick()) return error.ExpressionWorkLimit;
        if (before.instructions.len != after.instructions.len) return error.InvalidExpressionReuse;
        var block_same = after;
        block_same.instructions = before.instructions;
        if (!equal(ir.Block, before, block_same)) return error.InvalidExpressionReuse;
        for (before.instructions, after.instructions, 0..) |op, replacement, index| {
            if (!budget.tick()) return error.ExpressionWorkLimit;
            if (targets[bid][index]) |item| {
                try validateReplacement(
                    allocator,
                    original,
                    before,
                    op,
                    replacement,
                    item,
                    permissions,
                    predecessors,
                    budget,
                    &flow,
                    bid,
                    index,
                );
            } else if (!equal(ir.Instruction, op, replacement)) return error.InvalidExpressionReuse;
        }
    }
    for (witnesses) |item|
        if (item.target.block >= original.blocks.len or
            item.target.instruction >= original.blocks[item.target.block].instructions.len)
            return error.InvalidExpressionReuse;
}
fn validateReplacement(
    allocator: std.mem.Allocator,
    original: ir.Program,
    before: ir.Block,
    op: ir.Instruction,
    replacement: ir.Instruction,
    item: Witness,
    permissions: traits.Facts,
    predecessors: []const std.ArrayList(Predecessor),
    budget: *Budget,
    flow: *@import("activation_flow.zig").Facts,
    bid: usize,
    index: usize,
) Error!void {
    if (!eligible(
        original,
        before,
        op,
        permissions,
    )) return error.InvalidExpressionReuse;
    const proved = try proves(allocator, original, item, predecessors, budget);
    if (budget.exhausted) return error.ExpressionWorkLimit;
    if (!proved) return error.InvalidExpressionReuse;
    const source_block = original.blocks[item.source.block];
    const source = source_block.instructions[item.source.instruction];
    if (flow.positions[bid].len == 0 or !flow.pool.contains(
        flow.positions[bid][index].available,
        source.destination,
    )) return error.InvalidExpressionReuse;
    if (!eligible(
        original,
        original.blocks[item.source.block],
        source,
        permissions,
    )) return error.InvalidExpressionReuse;
    const source_schema = original.functions[
        @intCast(before.function)
    ].layout.slots[
        @intCast(source.destination)
    ];
    if (source_schema != original.functions[
        @intCast(before.function)
    ].layout.slots[
        @intCast(op.destination)
    ]) return error.InvalidExpressionReuse;
    const expected: ir.Instruction = .{
        .destination = op.destination,
        .opcode = .move,
        .operands = &.{source.destination},
    };
    if (!equal(
        ir.Instruction,
        expected,
        replacement,
    )) return error.InvalidExpressionReuse;
}
fn indexWitnesses(
    allocator: std.mem.Allocator,
    original: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
) Error![][]?Witness {
    const targets = try allocator.alloc([]?Witness, original.blocks.len);
    for (original.blocks, targets) |block, *row| {
        if (!budget.tick()) return error.ExpressionWorkLimit;
        row.* = try allocator.alloc(?Witness, block.instructions.len);
        @memset(row.*, null);
    }
    for (witnesses) |item| {
        if (!budget.tick()) return error.ExpressionWorkLimit;
        if (item.target.block >= targets.len or
            item.target.instruction >= targets[item.target.block].len)
            return error.InvalidExpressionReuse;
        const target = &targets[item.target.block][item.target.instruction];
        if (target.* != null) return error.InvalidExpressionReuse;
        target.* = item;
    }
    return targets;
}
