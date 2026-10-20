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
        .branch => |v| if (index == 0) .{ .edge = v.when_true } else if (index == 1) .{ .edge = v.when_false } else null,
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
    var definitions: std.ArrayList(Definition) = .empty;
    for (original.blocks, 0..) |block, bid| for (block.instructions, 0..) |op, index| {
        if (!budget.tick()) return rollback(allocator, original, &stats, options);
        if (!eligible(original, block, op, permissions)) continue;
        try definitions.append(
            a,
            .{
                .location = .{ .block = bid, .instruction = index },
                .function = block.function,
                .instruction = op,
                .schema = original.functions[
                    @intCast(block.function)
                ].layout.slots[
                    @intCast(op.destination)
                ],
            },
        );
    };
    const all_defs = definitions.items;
    stats.eligible_definitions = all_defs.len;
    // A capture boundary kills every reuse fact. Build only the transparent
    // control-flow components in which a producer can possibly justify a use.
    const regions = try a.alloc(usize, original.blocks.len);
    for (regions, 0..) |*region, id| region.* = id;
    for (original.blocks, 0..) |block, id| {
        var edge_index: usize = 0;
        while (successor(block.terminator, edge_index)) |transfer| : (edge_index += 1) {
            if (!budget.tick()) return rollback(allocator, original, &stats, options);
            if (transfer.capture_boundary) continue;
            const left = representative(regions, id);
            const right = representative(regions, @intCast(transfer.edge.block));
            regions[@max(left, right)] = @min(left, right);
        }
    }
    for (0..regions.len) |id| regions[id] = representative(regions, id);
    const region_defs = try a.alloc(std.ArrayList(Definition), original.blocks.len);
    const predecessors = indexPredecessors(a, original, &budget) catch |err| {
        if (err == error.ExpressionWorkLimit) return rollback(allocator, original, &stats, options);
        return err;
    };
    for (region_defs) |*items| items.* = .empty;
    // Only an expression with another exact occurrence can be reused. Hashes
    // select comparison buckets; function/schema/raw operands decide identity.
    const repeated = try a.alloc(bool, all_defs.len);
    const next_definition = try a.alloc(?usize, all_defs.len);
    @memset(repeated, false);
    @memset(next_definition, null);
    var buckets: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    for (all_defs, 0..) |definition, id| {
        if (!budget.tick()) return rollback(allocator, original, &stats, options);
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, definition.function);
        std.hash.autoHash(&hash, regions[definition.location.block]);
        std.hash.autoHash(&hash, definition.schema);
        std.hash.autoHash(&hash, definition.instruction.opcode);
        std.hash.autoHash(&hash, definition.instruction.immediate);
        std.hash.autoHash(&hash, definition.instruction.operands.len);
        for (definition.instruction.operands) |operand| {
            if (!budget.tick()) return rollback(allocator, original, &stats, options);
            std.hash.autoHash(&hash, operand);
        }
        const key = hash.final();
        var cursor: ?usize = buckets.get(key);
        var found = false;
        while (cursor) |prior| {
            if (!budget.tick()) return rollback(allocator, original, &stats, options);
            const other = all_defs[prior];
            if (regions[definition.location.block] == regions[other.location.block] and
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
            try buckets.put(a, key, id);
        }
    }
    for (all_defs, repeated) |definition, needed| {
        if (needed) {
            try region_defs[regions[definition.location.block]].append(a, definition);
            stats.tracked_definitions += 1;
        }
    }
    const entries = try a.alloc([]bool, original.blocks.len);
    stats.phase = .availability;
    const exits = try a.alloc([]bool, original.blocks.len);
    for (original.blocks, entries, exits, 0..) |block, *entry, *out, bid| {
        const defs = region_defs[regions[bid]].items;
        entry.* = try a.alloc(bool, defs.len);
        out.* = try a.alloc(bool, defs.len);
        for (defs, entry.*, out.*) |definition, *inside, *outside| {
            if (!budget.tick()) return rollback(allocator, original, &stats, options);
            inside.* = definition.function == block.function and
                flow.positions[bid].len != 0 and
                original.functions[
                    @intCast(block.function)
                ].entry != bid;
            outside.* = inside.*;
        }
    }
    const scratch_state = try a.alloc(bool, all_defs.len);
    var pending: std.ArrayList(usize) = .empty;
    const queued = try a.alloc(bool, original.blocks.len);
    @memset(queued, true);
    for (0..original.blocks.len) |id| try pending.append(a, id);
    var head: usize = 0;
    while (head < pending.items.len) {
        if (!budget.tick()) return rollback(allocator, original, &stats, options);
        const bid = pending.items[head];
        head += 1;
        queued[bid] = false;
        const block = original.blocks[bid];
        const defs = region_defs[regions[bid]].items;
        const state = scratch_state[0..defs.len];
        if (flow.positions[bid].len == 0) continue;
        const entry_block = original.functions[@intCast(block.function)].entry == bid;
        for (defs, 0..) |definition, d| {
            var available = !entry_block and definition.function == block.function;
            var count: usize = 0;
            for (predecessors[bid].items) |predecessor| {
                if (!budget.tick()) return rollback(allocator, original, &stats, options);
                const pred = predecessor.block;
                if (flow.positions[pred].len == 0) continue;
                const incoming = predecessor.transfer;
                count += 1;
                available = available and
                    !incoming.capture_boundary and
                    exits[pred][d] and
                    edgePreserves(definition, incoming.edge, incoming.overwritten);
            }
            entries[bid][d] = available and count != 0;
        }
        @memcpy(state, entries[bid]);
        for (block.instructions, 0..) |op, index|
            for (defs, 0..) |definition, d| {
                if (!budget.tick()) return rollback(allocator, original, &stats, options);
                if (relevant(definition, op.destination)) state[d] = false;
                if (definition.location.block == bid and
                    definition.location.instruction == index)
                    state[d] = true;
            };
        if (!std.mem.eql(bool, state, exits[bid])) {
            @memcpy(exits[bid], state);
            var edge_index: usize = 0;
            while (successor(block.terminator, edge_index)) |transfer| : (edge_index += 1) {
                if (!budget.tick()) return rollback(allocator, original, &stats, options);
                if (transfer.capture_boundary) continue;
                const target: usize = @intCast(transfer.edge.block);
                if (!queued[target]) {
                    try pending.append(a, target);
                    queued[target] = true;
                }
            }
        }
    }
    const blocks = try a.dupe(ir.Block, original.blocks);
    stats.phase = .rewriting;
    var witnesses: std.ArrayList(Witness) = .empty;
    for (original.blocks, blocks, 0..) |block, *out, bid| {
        const defs = region_defs[regions[bid]].items;
        const state = scratch_state[0..defs.len];
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        out.instructions = instructions;
        @memcpy(state, entries[bid]);
        for (block.instructions, 0..) |op, index| {
            if (flow.positions[bid].len != 0 and eligible(original, block, op, permissions)) {
                for (defs, state) |definition, available| {
                    if (!budget.tick()) return rollback(allocator, original, &stats, options);
                    if (!available or
                        definition.function != block.function or
                        definition.schema != original.functions[
                            @intCast(block.function)
                        ].layout.slots[
                            @intCast(op.destination)
                        ] or
                        !sameExpression(definition.instruction, op))
                        continue;
                    if (!flow.pool.contains(
                        flow.positions[bid][index].available,
                        definition.instruction.destination,
                    )) continue;
                    const witness: Witness = .{
                        .target = .{ .block = bid, .instruction = index },
                        .source = definition.location,
                    };
                    if (!try proves(allocator, original, witness, predecessors, &budget)) {
                        if (budget.exhausted) return rollback(allocator, original, &stats, options);
                        stats.proof_unavailable += 1;
                        continue;
                    }
                    instructions[index] = .{
                        .destination = op.destination,
                        .opcode = .move,
                        .operands = try a.dupe(p.Id, &.{definition.instruction.destination}),
                    };
                    try witnesses.append(a, witness);
                    break;
                }
            }
            for (defs, 0..) |definition, d| {
                if (!budget.tick()) return rollback(allocator, original, &stats, options);
                if (relevant(definition, op.destination)) state[d] = false;
                if (definition.location.block == bid and
                    definition.location.instruction == index)
                    state[d] = true;
            }
        }
    }
    var candidate = original;
    candidate.blocks = blocks;
    stats.phase = .validation;
    validateWithBudget(allocator, original, candidate, witnesses.items, &budget) catch |err| {
        if (err == error.ExpressionWorkLimit) return rollback(allocator, original, &stats, options);
        return err;
    };
    stats.expressions_reused = witnesses.items.len;
    for (witnesses.items) |item| if (item.source.block != item.target.block) {
        stats.across_blocks += 1;
    };
    return coalescing.run(allocator, candidate, options.coalescing);
}
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
    fn resolve(self: *Proof, block_id: usize, before: usize, depth: usize) bool {
        if (!self.budget.tick()) return false;
        if (depth == 256) return false;
        const block = self.program.blocks[block_id];
        const full = before == block.instructions.len;
        if (full) switch (self.cache[block_id]) {
            .active, .no => return false,
            .yes => return true,
            .unseen => {},
        };
        if (full) self.cache[block_id] = .active;
        var success = false;
        defer if (full) {
            self.cache[block_id] = if (success) .yes else .no;
        };
        var cursor = before;
        while (cursor != 0) {
            if (!self.budget.tick()) return false;
            cursor -= 1;
            if (self.definition.location.block == block_id and
                self.definition.location.instruction == cursor)
            {
                success = true;
                return true;
            }
            if (relevant(self.definition, block.instructions[cursor].destination)) return false;
        }
        if (self.program.functions[@intCast(block.function)].entry == block_id) return false;
        var count: usize = 0;
        for (self.predecessors[block_id].items) |indexed| {
            if (!self.budget.tick()) return false;
            const pred = indexed.block;
            const predecessor = self.program.blocks[pred];
            if (predecessor.function != block.function) continue;
            const incoming = indexed.transfer;
            count += 1;
            if (incoming.capture_boundary or !edgePreserves(
                self.definition,
                incoming.edge,
                incoming.overwritten,
            ) or !self.resolve(pred, predecessor.instructions.len, depth + 1)) return false;
        }
        success = count != 0;
        return success;
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
    return proof.resolve(witness.target.block, witness.target.instruction, 0);
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
    const targets = try arena.allocator().alloc([]?Witness, original.blocks.len);
    for (original.blocks, targets) |block, *row| {
        if (!budget.tick()) return error.ExpressionWorkLimit;
        row.* = try arena.allocator().alloc(?Witness, block.instructions.len);
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
    for (original.blocks, candidate.blocks, 0..) |before, after, bid| {
        if (!budget.tick()) return error.ExpressionWorkLimit;
        if (before.instructions.len != after.instructions.len) return error.InvalidExpressionReuse;
        var block_same = after;
        block_same.instructions = before.instructions;
        if (!equal(ir.Block, before, block_same)) return error.InvalidExpressionReuse;
        for (before.instructions, after.instructions, 0..) |op, replacement, index| {
            if (!budget.tick()) return error.ExpressionWorkLimit;
            if (targets[bid][index]) |item| {
                if (!eligible(
                    original,
                    before,
                    op,
                    permissions,
                )) return error.InvalidExpressionReuse;
                const proved = try proves(allocator, original, item, predecessors, budget);
                if (budget.exhausted) return error.ExpressionWorkLimit;
                if (!proved) return error.InvalidExpressionReuse;
                const source = original.blocks[item.source.block].instructions[item.source.instruction];
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
            } else if (!equal(ir.Instruction, op, replacement)) return error.InvalidExpressionReuse;
        }
    }
    for (witnesses) |item|
        if (item.target.block >= original.blocks.len or
            item.target.instruction >= original.blocks[item.target.block].instructions.len)
            return error.InvalidExpressionReuse;
}
