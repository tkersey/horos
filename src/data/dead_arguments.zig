// Copyright (c) 2026 Boundary contributors. MIT license.
//! Remove unused copy/drop parameters only from private direct-call workers.
//! Caller evaluation stays in place; dead-computation elimination has its own proof.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const contexts = @import("call_contexts.zig");
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
pub const Error = coalescing.Error || error{InvalidDeadArguments};
pub const Witness = struct { function: usize, removed: []const usize };
pub const Statistics = struct { parameters_removed: usize = 0, call_arguments_removed: usize = 0 };

pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: coalescing.Options,
) Error!coalescing.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var admitted = try ownership.analyze(allocator, original);
    defer admitted.deinit();
    var flow = try @import("activation_flow.zig").analyzeInputDemand(allocator, original);
    defer flow.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    var witnesses: std.ArrayList(Witness) = .empty;
    for (original.functions, 0..) |function, id| {
        if (contexts.unknownEntry(original, id)) continue;
        var removed: std.ArrayList(usize) = .empty;
        for (function.inputs, 0..) |slot, index| {
            const schema = function.layout.slots[@intCast(slot)];
            if (!permissions.copy[
                @intCast(schema)
            ] or !permissions.drop[
                @intCast(schema)
            ]) continue;
            if (flow.pool.contains(flow.live[@intCast(function.entry)][0], slot)) continue;
            try removed.append(a, index);
        }
        if (removed.items.len != 0) {
            stats.parameters_removed += removed.items.len;
            try witnesses.append(a, .{ .function = id, .removed = try removed.toOwnedSlice(a) });
        }
    }
    var candidate = original;
    const functions = try a.dupe(ir.Function, original.functions);
    const blocks = try a.dupe(ir.Block, original.blocks);
    candidate.functions = functions;
    candidate.blocks = blocks;
    for (witnesses.items) |witness| {
        functions[witness.function].inputs = try without(
            a,
            original.functions[witness.function].inputs,
            witness.removed,
        );
        for (blocks) |*block| {
            if (block.terminator != .call or
                block.terminator.call.function != witness.function)
                continue;
            block.terminator.call.arguments = try without(
                a,
                block.terminator.call.arguments,
                witness.removed,
            );
            stats.call_arguments_removed += witness.removed.len;
        }
    }
    try validate(allocator, original, candidate, witnesses.items);
    return coalescing.run(allocator, candidate, options);
}

fn without(
    allocator: std.mem.Allocator,
    slots: []const p.Id,
    removed: []const usize,
) std.mem.Allocator.Error![]const p.Id {
    const result = try allocator.alloc(p.Id, slots.len - removed.len);
    var next: usize = 0;
    for (slots, 0..) |slot, index| {
        if (std.mem.indexOfScalar(usize, removed, index) != null) continue;
        result[next] = slot;
        next += 1;
    }
    return result;
}

fn subsequence(before: []const p.Id, after: []const p.Id, removed: []const usize) bool {
    var next: usize = 0;
    var erased: usize = 0;
    for (before, 0..) |slot, index| {
        if (erased < removed.len and removed[erased] == index) {
            erased += 1;
        } else {
            if (next >= after.len or after[next] != slot) return false;
            next += 1;
        }
    }
    return erased == removed.len and next == after.len;
}

/// Verify the complete original caller set, ordered ABI subsequences, and input
/// liveness independently of the finder. No declaration or call may be omitted.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var admitted = try ownership.analyze(allocator, original);
    defer admitted.deinit();
    var flow = try @import("activation_flow.zig").analyzeInputDemand(allocator, original);
    defer flow.deinit();
    var checked = try ownership.analyze(allocator, candidate);
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    if (!equal(ir.Program, original, unchanged) or
        original.functions.len != candidate.functions.len or
        original.blocks.len != candidate.blocks.len)
        return error.InvalidDeadArguments;
    const removals = try a.alloc([]const usize, original.functions.len);
    @memset(removals, &.{});
    const seen = try a.alloc(bool, original.functions.len);
    @memset(seen, false);
    for (witnesses) |witness| {
        if (witness.function >= original.functions.len or
            seen[witness.function] or
            contexts.unknownEntry(original, witness.function))
            return error.InvalidDeadArguments;
        seen[witness.function] = true;
        removals[witness.function] = witness.removed;
        const function = original.functions[witness.function];
        for (witness.removed) |index| {
            if (index >= function.inputs.len) return error.InvalidDeadArguments;
            const slot = function.inputs[index];
            const schema = function.layout.slots[@intCast(slot)];
            if (!permissions.copy[
                @intCast(schema)
            ] or !permissions.drop[
                @intCast(schema)
            ] or flow.pool.contains(
                flow.live[@intCast(function.entry)][0],
                slot,
            )) return error.InvalidDeadArguments;
        }
    }
    try validateSubsequences(original, candidate, removals);
}
fn validateSubsequences(
    original: ir.Program,
    candidate: ir.Program,
    removals: []const []const usize,
) Error!void {
    for (original.functions, candidate.functions, removals) |before, after, removed| {
        var same = after;
        same.inputs = before.inputs;
        if (!equal(ir.Function, before, same) or !subsequence(
            before.inputs,
            after.inputs,
            removed,
        )) return error.InvalidDeadArguments;
    }
    for (original.blocks, candidate.blocks) |before, after| {
        var same = after;
        if (before.terminator == .call) {
            if (after.terminator != .call or
                after.terminator.call.function != before.terminator.call.function)
                return error.InvalidDeadArguments;
            const removed = removals[@intCast(before.terminator.call.function)];
            if (!subsequence(
                before.terminator.call.arguments,
                after.terminator.call.arguments,
                removed,
            )) return error.InvalidDeadArguments;
            same.terminator.call.arguments = before.terminator.call.arguments;
        }
        if (!equal(ir.Block, before, same)) return error.InvalidDeadArguments;
    }
}
