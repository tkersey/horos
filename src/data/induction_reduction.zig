// Copyright (c) 2026 Boundary contributors. MIT license.
//! P20: consume checked induction facts without introducing unchecked opcodes.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const loops = @import("loop_regions.zig");
const induction = @import("induction_facts.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || loops.Error || error{InvalidInductionReduction};
pub const Options = struct { work_limit: u64 = 2_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct { guards_removed: usize = 0, work_limit: bool = false };
pub const Witness = struct { header: usize, block: usize, instruction: usize };
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    witness: Witness,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn allowed(
    program: ir.Program,
    fid: usize,
    uses: traits.Facts,
    exportable: []const bool,
    budget: *loops.Budget,
) Error!bool {
    const f = program.functions[fid];
    if (f.effects.len != 0 or f.regions.len != 0 or f.custody.len != 1) return false;
    for (f.layout.slots) |schema| {
        try budget.take(1);
        if (!uses.copy[
            @intCast(schema)
        ] or !uses.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return false;
    }
    for (program.blocks) |b| if (b.function == fid) {
        try budget.take(1);
        if (b.custody != 0 or !loops.supported(b.terminator)) return false;
    };
    return true;
}
fn termReads(term: ir.Terminator, slot: p.Id) bool {
    switch (term) {
        .return_value, .fail => |v| if (v == slot) {
            return true;
        },
        .branch => |v| if (v.condition == slot) {
            return true;
        },
        .switch_variant => |v| if (v.value == slot) {
            return true;
        },
        .jump => {},
        else => return true,
    }
    var at: usize = 0;
    while (loops.edge(term, at)) |edge| : (at += 1)
        for (edge.assignments) |assignment|
            if (assignment.source == .slot and
                assignment.source.slot == slot)
                return true;
    return false;
}
fn redundant(
    program: ir.Program,
    proof: induction.Certificate,
    budget: *loops.Budget,
) Error!?usize {
    const body = program.blocks[proof.body];
    if (body.terminator != .branch or body.instructions.len == 0) return null;
    const at = body.instructions.len - 1;
    const compare = body.instructions[at];
    if (compare.opcode != .less or
        compare.operands.len != 2 or
        compare.operands[0] != proof.index or
        compare.operands[1] != proof.limit or
        compare.failures.len != 0 or
        compare.destination != body.terminator.branch.condition)
        return null;
    // The original successful header establishes this exact relation. Neither
    // version may change before the redundant test; capacity is not substituted.
    for (body.instructions[0..at]) |op| {
        try budget.take(1);
        if (op.destination == proof.index or op.destination == proof.limit) return null;
    }
    const fid = body.function;
    for (program.blocks, 0..) |block, bid|
        if (block.function == fid) {
            for (block.instructions, 0..) |op, index| {
                try budget.take(1);
                if (bid == proof.body and index == at) continue;
                if (std.mem.indexOfScalar(
                    p.Id,
                    op.operands,
                    compare.destination,
                ) != null or op.destination == compare.destination) return null;
            }
            if (bid != proof.body and termReads(block.terminator, compare.destination)) return null;
            var edge_index: usize = 0;
            while (loops.edge(block.terminator, edge_index)) |edge| : (edge_index += 1)
                for (edge.assignments) |assignment| {
                    try budget.take(1);
                    if (assignment.destination == compare.destination or
                        (assignment.source == .slot and
                            assignment.source.slot == compare.destination))
                        return null;
                };
        };
    return at;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var checked = try own.analyze(allocator, original);
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    try budget.record(ir.Program, original);
    const uses = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    for (original.functions, 0..) |_, fid| {
        if (!try allowed(original, fid, uses, schemas.exportable, &budget)) continue;
        const graph = (try loops.Graph.init(a, original, fid, &budget)) orelse continue;
        if (!try graph.cyclic(&budget)) continue;
        const dom = try graph.dominators(&budget);
        const dominated = try a.alloc(bool, graph.blocks.len);
        for (graph.blocks, 0..) |header, h| {
            try budget.take(1);
            if (!graph.reachable[h]) continue;
            for (dominated, 0..) |*v, node| v.* = dom[node * graph.blocks.len + h];
            const members = (try graph.region(h, dominated, &budget)) orelse continue;
            const proof = (try induction.derive(
                a,
                original,
                graph,
                members,
                header,
                &budget,
            )) orelse continue;
            const index = (try redundant(original, proof, &budget)) orelse continue;
            const blocks = try a.dupe(ir.Block, original.blocks);
            blocks[proof.body].instructions = original.blocks[proof.body].instructions[0..index];
            blocks[proof.body].terminator = .{
                .jump = original.blocks[proof.body].terminator.branch.when_true,
            };
            var program = original;
            program.blocks = blocks;
            keep = true;
            return .{
                .arena = arena,
                .program = program,
                .witness = .{ .header = header, .block = proof.body, .instruction = index },
            };
        }
    }
    return null;
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    try budget.record(ir.Program, original);
    try budget.record(ir.Program, candidate);
    if (witness.header >= original.blocks.len or
        witness.block >= original.blocks.len or
        candidate.blocks.len != original.blocks.len)
        return error.InvalidInductionReduction;
    const fid: usize = @intCast(original.blocks[witness.header].function);
    const uses = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    if (!try allowed(
        original,
        fid,
        uses,
        schemas.exportable,
        &budget,
    )) return error.InvalidInductionReduction;
    const graph = (try loops.Graph.init(
        a,
        original,
        fid,
        &budget,
    )) orelse return error.InvalidInductionReduction;
    const h = graph.local[witness.header];
    const outside = try graph.reachAvoid(h, &budget);
    const dominated = try a.alloc(bool, graph.blocks.len);
    for (dominated, 0..) |*v, node| v.* = graph.reachable[node] and !outside[node];
    const members = (try graph.region(
        h,
        dominated,
        &budget,
    )) orelse return error.InvalidInductionReduction;
    const proof = (try induction.derive(
        a,
        original,
        graph,
        members,
        witness.header,
        &budget,
    )) orelse return error.InvalidInductionReduction;
    if (proof.body != witness.block or (try redundant(
        original,
        proof,
        &budget,
    )) != witness.instruction) return error.InvalidInductionReduction;
    var rest = candidate;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidInductionReduction;
    for (original.blocks, candidate.blocks, 0..) |old, new, bid| {
        try budget.take(1);
        if (bid != witness.block) {
            if (!equal(ir.Block, old, new)) return error.InvalidInductionReduction;
            continue;
        }
        if (old.function != new.function or old.custody != new.custody or !equal(
            []const ir.Instruction,
            old.instructions[0..witness.instruction],
            new.instructions,
        ) or !equal(
            ir.Terminator,
            .{ .jump = old.terminator.branch.when_true },
            new.terminator,
        )) return error.InvalidInductionReduction;
    }
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block|
        if (block.terminator == .branch and
            block.instructions.len > 0 and
            block.instructions[block.instructions.len - 1].opcode == .less)
            return true;
    return false;
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
        error.LoopWorkLimit => {
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
        candidate.witness,
        options,
    ) catch |err| switch (err) {
        error.LoopWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.guards_removed = 1;
    return result;
}
