// Copyright (c) 2026 Boundary contributors. MIT license.
//! Duplicate a small shared branch tail only for a certified incoming constant.
const std = @import("std");
const ir = @import("activation.zig");
const ownership = @import("activation_ownership.zig");
const origin = @import("constant_origin.zig");
const branches = @import("branch_reduction.zig");
const p01 = @import("coalescing.zig");
const image = @import("program_image.zig");
const equal = @import("record_equal.zig").equal;
const profiles = @import("optimization_profile.zig");
pub const Error = branches.Error || profiles.Error || error{
    InvalidTailDuplication,
    TailDuplicationLimit,
};
pub const Options = struct {
    work_limit: u64 = 1_000_000,
    max_copies: usize = 16,
    max_instructions: usize = 8,
    max_added_bytes: usize = 4096,
    profile: ?profiles.Record = null,
    coalescing: p01.Options = .{},
};
pub const Witness = struct { predecessor: usize, tail: usize, copy: usize, condition: bool };
pub const Statistics = struct {
    copies: usize = 0,
    exposed_branches: usize = 0,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    witnesses: []const Witness,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: u64,
    fn tick(self: *Budget) Error!void {
        if (self.left == 0) return error.TailDuplicationLimit;
        self.left -= 1;
    }
};
fn incoming(program: ir.Program, target: usize, budget: *Budget) Error!usize {
    var count: usize = 0;
    for (program.blocks) |block| {
        try budget.tick();
        switch (block.terminator) {
            .return_value, .fail => {},
            .jump, .yield_value => |edge| count += @intFromBool(edge.block == target),
            .branch => |branch| count += @intFromBool(branch.when_true.block == target) + @as(
                usize,
                @intFromBool(branch.when_false.block == target),
            ),
            .switch_variant => |branch| for (branch.cases) |edge| {
                try budget.tick();
                count += @intFromBool(edge.block == target);
            },
            inline else => |value| count += @intFromBool(value.next.block == target),
        }
    }
    return count;
}
fn selected(
    program: ir.Program,
    predecessor: usize,
    options: Options,
    proof: *origin.Prover,
    budget: *Budget,
) Error!?bool {
    try budget.tick();
    const block = program.blocks[predecessor];
    if (block.terminator != .jump) return null;
    const edge = block.terminator.jump;
    const tail = program.blocks[@intCast(edge.block)];
    if (tail.function != block.function or
        tail.custody != block.custody or
        tail.terminator != .branch or
        tail.instructions.len > options.max_instructions)
        return null;
    if (try incoming(program, @intCast(edge.block), budget) < 2) return null;
    const condition = tail.terminator.branch.condition;
    for (tail.instructions) |op| {
        try budget.tick();
        if (op.destination == condition) return null;
    }
    var source = condition;
    for (edge.assignments) |assignment| {
        try budget.tick();
        if (assignment.destination == condition) {
            if (assignment.source != .slot) return null;
            source = assignment.source.slot;
        }
    }
    const certified = (try proof.resolve(predecessor, block.instructions.len, source)) orelse {
        if (proof.exhausted) return error.TailDuplicationLimit;
        return null;
    };
    return if (certified == .boolean) certified.boolean else null;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| if (block.terminator == .jump and program.blocks[
        @intCast(block.terminator.jump.block)
    ].terminator == .branch) return true;
    return false;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    if (options.profile) |record| try profiles.validate(allocator, original, record);
    var admitted = try ownership.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: Budget = .{ .left = options.work_limit };
    var proof: origin.Prover = .{
        .allocator = a,
        .program = original,
        .work_limit = options.work_limit,
    };
    defer proof.deinit();
    var witnesses: std.ArrayList(Witness) = .empty;
    const order = if (options.profile) |record| blk: {
        const charge = std.math.mul(
            u64,
            original.blocks.len,
            original.blocks.len,
        ) catch return error.TailDuplicationLimit;
        if (charge > budget.left) return error.TailDuplicationLimit;
        budget.left -= charge;
        break :blk try profiles.orderedBlocks(a, original, record);
    } else null;
    for (0..original.blocks.len) |ordinal| {
        const bid = if (order) |ids| ids[ordinal] else ordinal;
        const block = original.blocks[bid];
        const condition = (try selected(original, bid, options, &proof, &budget)) orelse continue;
        if (witnesses.items.len == options.max_copies) {
            if (options.profile != null) break;
            return error.TailDuplicationLimit;
        }
        try witnesses.append(
            a,
            .{
                .predecessor = bid,
                .tail = @intCast(block.terminator.jump.block),
                .copy = original.blocks.len + witnesses.items.len,
                .condition = condition,
            },
        );
    }
    if (witnesses.items.len == 0) return null;
    const blocks = try a.alloc(ir.Block, original.blocks.len + witnesses.items.len);
    @memcpy(blocks[0..original.blocks.len], original.blocks);
    for (witnesses.items) |witness| {
        blocks[witness.predecessor].terminator.jump.block = witness.copy;
        blocks[witness.copy] = original.blocks[witness.tail];
    }
    var program = original;
    program.blocks = blocks;
    const before = try image.encodedLength(original);
    const after = try image.encodedLength(program);
    if (after > before and
        after - before > options.max_added_bytes)
        return error.TailDuplicationLimit;
    const list = try witnesses.toOwnedSlice(a);
    keep = true;
    return .{ .arena = arena, .program = program, .witnesses = list };
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
    options: Options,
) Error!void {
    var before = try ownership.analyze(allocator, original);
    defer before.deinit();
    var after = try ownership.analyze(allocator, candidate);
    defer after.deinit();
    if (candidate.blocks.len != original.blocks.len + witnesses.len)
        return error.InvalidTailDuplication;
    var unchanged = candidate;
    unchanged.blocks = original.blocks;
    if (!equal(ir.Program, original, unchanged)) return error.InvalidTailDuplication;
    var proof: origin.Prover = .{
        .allocator = allocator,
        .program = original,
        .work_limit = options.work_limit,
    };
    defer proof.deinit();
    var budget: Budget = .{ .left = options.work_limit };
    for (witnesses, 0..) |witness, index| {
        try budget.tick();
        if (witness.predecessor >= original.blocks.len or
            witness.tail >= original.blocks.len or
            witness.copy != original.blocks.len + index)
            return error.InvalidTailDuplication;
        for (witnesses[0..index]) |earlier|
            if (earlier.predecessor == witness.predecessor)
                return error.InvalidTailDuplication;
        const predecessor = original.blocks[witness.predecessor];
        const tail = original.blocks[witness.tail];
        if (predecessor.terminator != .jump or
            predecessor.terminator.jump.block != witness.tail or
            !equal(ir.Block, tail, candidate.blocks[witness.copy]))
            return error.InvalidTailDuplication;
        const condition = (try selected(
            original,
            witness.predecessor,
            options,
            &proof,
            &budget,
        )) orelse return error.InvalidTailDuplication;
        if (condition != witness.condition) return error.InvalidTailDuplication;
    }
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
        try budget.tick();
        var witness: ?Witness = null;
        for (witnesses) |item| if (item.predecessor == bid) {
            witness = item;
        };
        if (witness) |item| {
            if (new.terminator != .jump or
                new.terminator.jump.block != item.copy)
                return error.InvalidTailDuplication;
            var restored = new;
            restored.terminator.jump.block = old.terminator.jump.block;
            if (!equal(ir.Block, old, restored)) return error.InvalidTailDuplication;
        } else if (!equal(ir.Block, old, new)) return error.InvalidTailDuplication;
    }
}
pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!p01.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var candidate = (construct(allocator, original, options) catch |err| switch (err) {
        error.TailDuplicationLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validate(
        allocator,
        original,
        candidate.program,
        candidate.witnesses,
        options,
    ) catch |err| switch (err) {
        error.TailDuplicationLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    // Fresh facts and the existing independent branch checker consume the copies
    // before common-tail sharing can fold them back together.
    var branch_stats: branches.Statistics = .{};
    var result = branches.run(
        allocator,
        candidate.program,
        &branch_stats,
        options.coalescing,
    ) catch |err| switch (err) {
        error.SemanticWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    if (branch_stats.proof_work_limit) {
        result.deinit();
        stats.work_limit = true;
        return p01.run(allocator, original, options.coalescing);
    }
    stats.copies = candidate.witnesses.len;
    stats.exposed_branches = branch_stats.branches_removed;
    return result;
}
