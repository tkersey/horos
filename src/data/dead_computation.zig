// Copyright (c) 2026 Boundary contributors. MIT license.
//! Backwards demand removes only total, copyable and droppable computations.
//! Calls, mutable reads/writes, failures and control/cleanup operations stay.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
pub const Error = coalescing.Error || error{InvalidDeadComputation};
pub const Options = struct {
    work_limit: u64 = std.math.maxInt(u64),
    round_limit: usize = std.math.maxInt(usize),
    coalescing: coalescing.Options = .{},
};
pub const Statistics = struct {
    instructions_removed: usize = 0,
    constructions_removed: usize = 0,
    rounds: usize = 0,
    round_attempts: usize = 0,
    work: u64 = 0,
    work_limit: bool = false,
};
pub const Witness = struct { block: usize, removed: []const usize };

pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!coalescing.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var retained = std.heap.ArenaAllocator.init(allocator);
    defer retained.deinit();
    var current = original;
    while (stats.round_attempts < options.round_limit) {
        stats.round_attempts += 1;
        var admitted = try ownership.analyze(allocator, current);
        defer admitted.deinit();
        var flow = try @import("activation_flow.zig").analyzeInputDemand(allocator, current);
        defer flow.deinit();
        var next_arena = std.heap.ArenaAllocator.init(allocator);
        defer next_arena.deinit();
        const a = next_arena.allocator();
        const permissions = try traits.derive(a, current.schemas);
        const blocks = try a.dupe(ir.Block, current.blocks);
        const removed = (try collectDeletions(
            a,
            current,
            &flow,
            permissions,
            blocks,
            &stats,
            options.work_limit,
        )) orelse {
            resetProgress(&stats);
            return coalescing.run(allocator, original, options.coalescing);
        };
        if (removed.removed_count == 0)
            return coalescing.run(allocator, current, options.coalescing);
        var candidate = current;
        candidate.blocks = blocks;
        try validate(allocator, current, candidate, removed.witnesses.items);
        stats.instructions_removed += removed.removed_count;
        stats.constructions_removed += removed.removed_constructions;
        stats.rounds += 1;
        // All metadata and operands still borrow the immutable original;
        // instruction/block arrays are copied completely into the next owner.
        retained.deinit();
        retained = next_arena;
        next_arena = std.heap.ArenaAllocator.init(allocator);
        current = candidate;
    }
    resetProgress(&stats);
    return coalescing.run(allocator, original, options.coalescing);
}

const Deletions = struct {
    witnesses: std.ArrayList(Witness) = .empty,
    removed_count: usize = 0,
    removed_constructions: usize = 0,
};
fn resetProgress(stats: *Statistics) void {
    stats.work_limit = true;
    stats.instructions_removed = 0;
    stats.constructions_removed = 0;
    stats.rounds = 0;
}
fn collectDeletions(
    a: std.mem.Allocator,
    current: ir.Program,
    flow: *@import("activation_flow.zig").Facts,
    permissions: traits.Facts,
    blocks: []ir.Block,
    stats: *Statistics,
    work_limit: u64,
) Error!?Deletions {
    var result: Deletions = .{};
    for (current.blocks, blocks, 0..) |block, *out, id| {
        const remove = try a.alloc(bool, block.instructions.len);
        @memset(remove, false);
        if (!try markDeletions(
            current,
            block,
            id,
            flow,
            permissions,
            remove,
            stats,
            work_limit,
            &result,
        )) return null;
        var instructions: std.ArrayList(ir.Instruction) = .empty;
        var removed: std.ArrayList(usize) = .empty;
        for (block.instructions, remove, 0..) |instruction, discard, index| {
            if (discard)
                try removed.append(a, index)
            else
                try instructions.append(a, instruction);
        }
        out.instructions = try instructions.toOwnedSlice(a);
        if (removed.items.len != 0) try result.witnesses.append(
            a,
            .{ .block = id, .removed = try removed.toOwnedSlice(a) },
        );
    }
    return result;
}
fn markDeletions(
    current: ir.Program,
    block: ir.Block,
    id: usize,
    flow: *@import("activation_flow.zig").Facts,
    permissions: traits.Facts,
    remove: []bool,
    stats: *Statistics,
    work_limit: u64,
    result: *Deletions,
) Error!bool {
    if (flow.live[id].len != 0) {
        var demand = flow.live[id][block.instructions.len];
        var index = block.instructions.len;
        while (index != 0) {
            if (stats.work == work_limit) return false;
            stats.work += 1;
            index -= 1;
            const instruction = block.instructions[index];
            if (!flow.pool.contains(demand, instruction.destination) and
                totalDroppable(current, block.function, instruction, permissions))
            {
                remove[index] = true;
                result.removed_count += 1;
                if (instruction.opcode == .computation) result.removed_constructions += 1;
            } else {
                demand = try flow.pool.remove(demand, instruction.destination);
                for (instruction.operands) |slot| demand = try flow.pool.insert(
                    demand,
                    slot,
                );
            }
        }
    }
    return true;
}

fn totalDroppable(
    program: ir.Program,
    function: p.Id,
    instruction: ir.Instruction,
    permissions: traits.Facts,
) bool {
    if (instruction.failures.len != 0) return false;
    const slots = program.functions[@intCast(function)].layout.slots;
    const schema = slots[@intCast(instruction.destination)];
    if (!permissions.copy[@intCast(schema)] or !permissions.drop[@intCast(schema)]) return false;
    for (instruction.operands) |slot| {
        const operand = slots[@intCast(slot)];
        if (!permissions.copy[
            @intCast(operand)
        ] or !permissions.drop[
            @intCast(operand)
        ]) return false;
    }
    return switch (instruction.opcode) {
        .constant,
        .move,
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
        .computation => blk: {
            const constructor = program.constructors[@intCast(instruction.immediate)];
            const capture = program.scopes.captures[@intCast(constructor.capture)];
            break :blk capture.fields.len == 0 and
                capture.owned_regions.len == 0 and
                capture.borrowed_regions.len == 0 and
                program.functions[
                    @intCast(constructor.function)
                ].regions.len == 0;
        },
        else => false,
    };
}

/// Check the retained subsequence and each deletion against candidate demand.
/// An erased fault/control operation cannot be justified by output admission.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var original_flow = try ownership.analyze(allocator, original);
    defer original_flow.deinit();
    var admitted_candidate = try ownership.analyze(allocator, candidate);
    defer admitted_candidate.deinit();
    var candidate_flow = try @import("activation_flow.zig").analyzeInputDemand(
        allocator,
        candidate,
    );
    defer candidate_flow.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const permissions = try traits.derive(arena.allocator(), original.schemas);
    var unchanged = candidate;
    unchanged.blocks = original.blocks;
    if (!equal(
        ir.Program,
        original,
        unchanged,
    ) or candidate.blocks.len != original.blocks.len) return error.InvalidDeadComputation;
    for (original.blocks, candidate.blocks, 0..) |before, after, id| {
        var removed: []const usize = &.{};
        var found = false;
        for (witnesses) |witness| if (witness.block == id) {
            if (found) return error.InvalidDeadComputation;
            found = true;
            removed = witness.removed;
        };
        if (before.function != after.function or before.custody != after.custody or !equal(
            ir.Terminator,
            before.terminator,
            after.terminator,
        )) return error.InvalidDeadComputation;
        var next: usize = 0;
        var erased: usize = 0;
        for (before.instructions, 0..) |instruction, index| {
            if (erased < removed.len and removed[erased] == index) {
                if (!totalDroppable(
                    original,
                    before.function,
                    instruction,
                    permissions,
                )) return error.InvalidDeadComputation;
                if (candidate_flow.live[id].len != 0 and candidate_flow.pool.contains(
                    candidate_flow.live[id][next],
                    instruction.destination,
                )) return error.InvalidDeadComputation;
                erased += 1;
            } else {
                if (next >= after.instructions.len or !equal(
                    ir.Instruction,
                    instruction,
                    after.instructions[next],
                )) return error.InvalidDeadComputation;
                next += 1;
            }
        }
        if (erased != removed.len or
            next != after.instructions.len)
            return error.InvalidDeadComputation;
    }
    for (witnesses) |witness|
        if (witness.block >= original.blocks.len)
            return error.InvalidDeadComputation;
}
