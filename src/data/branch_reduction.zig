// Copyright (c) 2026 Boundary contributors. MIT license.
//! Feasible-edge discovery with an independently checked constant-origin proof.
const std = @import("std");
const ir = @import("activation.zig");
const facts = @import("value_facts.zig");
const origin = @import("constant_origin.zig");
const ownership = @import("activation_ownership.zig");
const coalescing = @import("coalescing.zig");
const equal = @import("record_equal.zig").equal;
pub const Error = facts.Error || coalescing.Error || error{InvalidBranchReduction};
pub const Witness = struct { block: usize, condition: bool };
pub const Statistics = struct {
    branches_removed: usize = 0,
    proof_unavailable: usize = 0,
    proof_work_limit: bool = false,
};
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
    var known = try facts.analyze(allocator, original);
    defer known.deinit();
    try known.requireEpoch(allocator, original);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try a.dupe(ir.Block, original.blocks);
    var witnesses: std.ArrayList(Witness) = .empty;
    var proof: origin.Prover = .{ .allocator = a, .program = original };
    defer proof.deinit();
    for (original.blocks, known.blocks, 0..) |block, state, id| {
        if (!state.reachable or block.terminator != .branch) continue;
        const branch = block.terminator.branch;
        const value = state.definitions[
            state.exit[
                @intCast(branch.condition)
            ]
        ].value.boolean orelse continue;
        const certified = try proof.resolve(id, block.instructions.len, branch.condition);
        if (certified == null or certified.? != .boolean or certified.?.boolean != value) {
            stats.proof_unavailable += 1;
            continue;
        }
        blocks[id].terminator = .{ .jump = if (value) branch.when_true else branch.when_false };
        try witnesses.append(a, .{ .block = id, .condition = value });
    }
    var candidate = original;
    candidate.blocks = blocks;
    try validate(allocator, original, candidate, witnesses.items);
    var checked = try ownership.analyze(allocator, candidate);
    checked.deinit();
    stats.branches_removed = witnesses.items.len;
    stats.proof_work_limit = proof.exhausted;
    return coalescing.run(allocator, candidate, options);
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var checked = try ownership.analyze(allocator, original);
    defer checked.deinit();
    var same = candidate;
    same.blocks = original.blocks;
    if (!equal(
        ir.Program,
        original,
        same,
    ) or candidate.blocks.len != original.blocks.len) return error.InvalidBranchReduction;
    var proof: origin.Prover = .{ .allocator = allocator, .program = original };
    defer proof.deinit();
    for (original.blocks, candidate.blocks, 0..) |before, after, id| {
        var witness: ?Witness = null;
        for (witnesses) |item| if (item.block == id) {
            if (witness != null) return error.InvalidBranchReduction;
            witness = item;
        };
        if (witness) |item| {
            if (before.terminator != .branch or
                after.terminator != .jump)
                return error.InvalidBranchReduction;
            const branch = before.terminator.branch;
            const value = (try proof.resolve(
                id,
                before.instructions.len,
                branch.condition,
            )) orelse return error.InvalidBranchReduction;
            if (value != .boolean or
                value.boolean != item.condition)
                return error.InvalidBranchReduction;
            var expected = before;
            expected.terminator = .{
                .jump = if (item.condition) branch.when_true else branch.when_false,
            };
            if (!equal(ir.Block, expected, after)) return error.InvalidBranchReduction;
        } else if (!equal(ir.Block, before, after)) return error.InvalidBranchReduction;
    }
    for (witnesses) |item|
        if (item.block >= original.blocks.len)
            return error.InvalidBranchReduction;
}
