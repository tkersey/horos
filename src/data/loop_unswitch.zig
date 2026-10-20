// Copyright (c) 2026 Boundary contributors. MIT license.
//! P19: guarded runtime-Boolean dispatch into path-specialized natural loops.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const loops = @import("loop_regions.zig");
const image = @import("program_image.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
const profiles = @import("optimization_profile.zig");
pub const Error = p01.Error || loops.Error || profiles.Error || error{InvalidLoopUnswitch};
pub const Options = struct {
    work_limit: u64 = 2_000_000,
    max_added_bytes: usize = 4096,
    profile: ?profiles.Record = null,
    coalescing: p01.Options = .{},
};
pub const Statistics = struct {
    unswitched: usize = 0,
    copied_blocks: usize = 0,
    code_budget_rejected: bool = false,
    work_limit: bool = false,
};
pub const Witness = struct { header: usize, dispatch: usize };
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
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *loops.Budget,
) Error!bool {
    const f = program.functions[fid];
    if (f.effects.len != 0 or f.custody.len != 1) return false;
    for (f.layout.slots) |schema| {
        try budget.take(1);
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ]) return false;
        const shape = program.schemas[@intCast(schema)];
        const region_local = shape == .internal and
            (shape.internal == .region or
                shape.internal == .cell);
        if (!exportable[@intCast(schema)] and !region_local) return false;
    }
    for (program.blocks) |b| if (b.function == fid) {
        try budget.take(1);
        if (b.custody != 0 or !loops.supported(b.terminator)) return false;
    };
    return true;
}
fn dispatchFor(
    program: ir.Program,
    graph: loops.Graph,
    members: []const bool,
    header: usize,
) ?usize {
    const term = program.blocks[header].terminator;
    if (term != .branch) return null;
    const yes: usize = @intCast(term.branch.when_true.block);
    const no: usize = @intCast(term.branch.when_false.block);
    const yi = members[graph.local[yes]];
    const ni = members[graph.local[no]];
    if (yi == ni) return null;
    const body = if (yi) yes else no;
    if (body == header or program.blocks[body].terminator != .branch) return null;
    return body;
}
fn immutableCondition(
    program: ir.Program,
    graph: loops.Graph,
    members: []const bool,
    condition: p.Id,
    budget: *loops.Budget,
) Error!bool {
    for (graph.blocks, members) |bid, inside|
        if (inside) {
            const block = program.blocks[bid];
            for (block.instructions) |op| {
                try budget.take(1);
                if (op.destination == condition) return false;
            }
            var ordinal: usize = 0;
            while (loops.edge(block.terminator, ordinal)) |e| : (ordinal += 1)
                for (e.assignments) |assignment| {
                    try budget.take(1);
                    if (assignment.destination == condition and
                        (assignment.source != .slot or
                            assignment.source.slot != condition))
                        return false;
                };
        };
    return true;
}
const Copies = struct {
    originals: []usize,
    ordinal: []usize,
    base: usize,
    dispatch: usize,
    selected: [2]p.Id,
    bypass: [2]bool,
    fn copy(self: @This(), bid: p.Id, arm: usize) p.Id {
        return self.base + arm * self.originals.len + self.ordinal[@intCast(bid)];
    }
    fn target(self: @This(), bid: p.Id, arm: usize) p.Id {
        const original = if (bid == self.dispatch and self.bypass[arm]) self.selected[arm] else bid;
        const index = self.ordinal[@intCast(original)];
        return if (index == std.math.maxInt(
            usize,
        )) original else self.base + arm * self.originals.len + index;
    }
};
fn copies(
    a: std.mem.Allocator,
    graph: loops.Graph,
    members: []const bool,
    dispatch: usize,
    budget: *loops.Budget,
) Error!Copies {
    try budget.take(graph.program.blocks.len + graph.blocks.len);
    var count: usize = 0;
    for (members) |inside| count += @intFromBool(inside);
    const originals = try a.alloc(usize, count);
    const ordinal = try a.alloc(usize, graph.program.blocks.len);
    @memset(ordinal, std.math.maxInt(usize));
    var index: usize = 0;
    for (graph.blocks, members) |bid, inside| if (inside) {
        originals[index] = bid;
        ordinal[bid] = index;
        index += 1;
    };
    const block = graph.program.blocks[dispatch];
    const branch = block.terminator.branch;
    return .{
        .originals = originals,
        .ordinal = ordinal,
        .base = graph.program.blocks.len,
        .dispatch = dispatch,
        .selected = .{ branch.when_true.block, branch.when_false.block },
        .bypass = .{
            block.instructions.len == 0 and
                branch.when_true.assignments.len == 0 and
                branch.when_true.block != dispatch,
            block.instructions.len == 0 and
                branch.when_false.assignments.len == 0 and
                branch.when_false.block != dispatch,
        },
    };
}
fn mappedEdge(c: Copies, edge: ir.Edge, arm: usize) ir.Edge {
    var result = edge;
    result.block = c.target(edge.block, arm);
    return result;
}
fn cloneTerm(a: std.mem.Allocator, c: Copies, term: ir.Terminator, arm: usize) !ir.Terminator {
    return switch (term) {
        .jump => |v| .{ .jump = mappedEdge(c, v, arm) },
        .branch => |v| .{ .branch = .{
            .condition = v.condition,
            .when_true = mappedEdge(c, v.when_true, arm),
            .when_false = mappedEdge(c, v.when_false, arm),
        } },
        .switch_variant => |v| blk: {
            const edges = try a.dupe(ir.Edge, v.cases);
            for (edges) |*e| e.* = mappedEdge(c, e.*, arm);
            break :blk .{ .switch_variant = .{ .value = v.value, .cases = edges } };
        },
        .return_value, .fail => term,
        else => unreachable,
    };
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    if (options.profile) |record| try profiles.validate(allocator, original, record);
    var facts = try own.analyze(allocator, original);
    defer facts.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    try budget.record(ir.Program, original);
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    const order = if (options.profile) |record| blk: {
        try budget.take(std.math.mul(
            u64,
            original.blocks.len,
            original.blocks.len,
        ) catch return error.LoopWorkLimit);
        break :blk try profiles.orderedBlocks(a, original, record);
    } else null;
    const function_order = if (order) |ids| blk: {
        const result = try a.alloc(usize, original.functions.len);
        const seen = try a.alloc(bool, original.functions.len);
        @memset(seen, false);
        var count: usize = 0;
        for (ids) |bid| {
            const fid: usize = @intCast(original.blocks[bid].function);
            if (!seen[fid]) {
                seen[fid] = true;
                result[count] = fid;
                count += 1;
            }
        }
        // Admission gives every function an entry block.
        if (count != result.len) return error.InvalidLoopUnswitch;
        break :blk result;
    } else null;
    for (0..original.functions.len) |ordinal| {
        const fid = if (function_order) |ids| ids[ordinal] else ordinal;
        if (!try allowed(original, fid, permissions, schemas.exportable, &budget)) continue;
        const graph = (try loops.Graph.init(a, original, fid, &budget)) orelse continue;
        if (!try graph.cyclic(&budget)) continue;
        const dom = try graph.dominators(&budget);
        const headers = if (order) |ids| blk: {
            const result = try a.alloc(usize, graph.blocks.len);
            var count: usize = 0;
            for (ids) |bid| if (original.blocks[bid].function == fid) {
                try budget.take(1);
                result[count] = bid;
                count += 1;
            };
            if (count != result.len) return error.InvalidLoopUnswitch;
            break :blk result;
        } else graph.blocks;
        for (headers) |header| {
            const h = graph.local[header];
            try budget.take(1);
            if (!graph.reachable[h]) continue;
            const dominated = try a.alloc(bool, graph.blocks.len);
            for (dominated, 0..) |*v, node| v.* = dom[node * graph.blocks.len + h];
            const members = (try graph.region(h, dominated, &budget)) orelse continue;
            const dispatch = dispatchFor(original, graph, members, header) orelse continue;
            const branch = original.blocks[dispatch].terminator.branch;
            if (!try immutableCondition(
                original,
                graph,
                members,
                branch.condition,
                &budget,
            )) continue;
            const c = try copies(a, graph, members, dispatch, &budget);
            const added = std.math.mul(usize, c.originals.len, 2) catch return error.Capacity;
            try budget.take(added);
            const blocks = try a.alloc(
                ir.Block,
                std.math.add(usize, original.blocks.len, added) catch return error.Capacity,
            );
            @memcpy(blocks[0..original.blocks.len], original.blocks);
            blocks[dispatch].terminator = .{ .branch = .{
                .condition = branch.condition,
                .when_true = mappedEdge(c, branch.when_true, 0),
                .when_false = mappedEdge(c, branch.when_false, 1),
            } };
            for (0..2) |arm| for (c.originals) |bid| {
                try budget.record(ir.Block, original.blocks[bid]);
                const copy = &blocks[@intCast(c.copy(bid, arm))];
                copy.* = original.blocks[bid];
                copy.terminator = if (bid == dispatch) .{ .jump = mappedEdge(
                    c,
                    if (arm == 0) branch.when_true else branch.when_false,
                    arm,
                ) } else try cloneTerm(a, c, original.blocks[bid].terminator, arm);
            };
            var program = original;
            program.blocks = blocks;
            keep = true;
            return .{
                .arena = arena,
                .program = program,
                .witness = .{ .header = header, .dispatch = dispatch },
            };
        }
    }
    return null;
}
fn checkEdge(c: Copies, before: ir.Edge, after: ir.Edge, arm: usize) bool {
    // Independent scalar correspondence: no emitter is invoked by acceptance.
    const original_target = if (before.block == c.dispatch and
        c.bypass[arm])
        c.selected[arm]
    else
        before.block;
    const index = c.ordinal[@intCast(original_target)];
    const target = if (index == std.math.maxInt(
        usize,
    )) original_target else c.base + arm * c.originals.len + index;
    return after.block == target and equal(
        []const ir.Assignment,
        before.assignments,
        after.assignments,
    );
}
fn checkTerm(c: Copies, before: ir.Terminator, after: ir.Terminator, arm: usize) bool {
    if (std.meta.activeTag(before) != std.meta.activeTag(after)) return false;
    switch (before) {
        .return_value, .fail => return equal(ir.Terminator, before, after),
        .jump => {},
        .branch => |v| if (v.condition != after.branch.condition) {
            return false;
        },
        .switch_variant => |v| if (v.value != after.switch_variant.value or
            v.cases.len != after.switch_variant.cases.len)
        {
            return false;
        },
        else => return false,
    }
    var ordinal: usize = 0;
    while (loops.edge(before, ordinal)) |e| : (ordinal += 1) if (!checkEdge(
        c,
        e,
        loops.edge(after, ordinal) orelse return false,
        arm,
    )) return false;
    return true;
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
        witness.dispatch >= original.blocks.len)
        return error.InvalidLoopUnswitch;
    const fid: usize = @intCast(original.blocks[witness.header].function);
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    if (!try allowed(
        original,
        fid,
        permissions,
        schemas.exportable,
        &budget,
    )) return error.InvalidLoopUnswitch;
    const graph = (try loops.Graph.init(
        a,
        original,
        fid,
        &budget,
    )) orelse return error.InvalidLoopUnswitch;
    const h = graph.local[witness.header];
    const without_header = try graph.reachAvoid(h, &budget);
    const dominated = try a.alloc(bool, graph.blocks.len);
    for (dominated, 0..) |*v, node| v.* = graph.reachable[node] and !without_header[node];
    const members = (try graph.region(
        h,
        dominated,
        &budget,
    )) orelse return error.InvalidLoopUnswitch;
    if (dispatchFor(
        original,
        graph,
        members,
        witness.header,
    ) != witness.dispatch) return error.InvalidLoopUnswitch;
    const branch = original.blocks[witness.dispatch].terminator.branch;
    // The selector is a definite Boolean version at every original dispatch.
    if (before.positions[witness.dispatch].len == 0 or
        !before.pool.contains(
            before.positions[witness.dispatch][original.blocks[witness.dispatch].instructions.len].available,
            branch.condition,
        ))
        return error.InvalidLoopUnswitch;
    var writes: usize = 0;
    for (members, graph.blocks) |inside, bid|
        if (inside) {
            for (original.blocks[bid].instructions) |op| {
                try budget.take(1);
                writes += @intFromBool(op.destination == branch.condition);
            }
            var ordinal: usize = 0;
            while (loops.edge(original.blocks[bid].terminator, ordinal)) |e| : (ordinal += 1)
                for (e.assignments) |assignment| {
                    try budget.take(1);
                    writes += @intFromBool(
                        assignment.destination == branch.condition and
                            (assignment.source != .slot or
                                assignment.source.slot != branch.condition),
                    );
                };
        };
    if (writes != 0) return error.InvalidLoopUnswitch;
    const c = try copies(a, graph, members, witness.dispatch, &budget);
    if (candidate.blocks.len != original.blocks.len + 2 * c.originals.len)
        return error.InvalidLoopUnswitch;
    var rest = candidate;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidLoopUnswitch;
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
        try budget.take(1);
        if (bid != witness.dispatch) {
            if (!equal(ir.Block, old, new)) return error.InvalidLoopUnswitch;
            continue;
        }
        if (old.function != new.function or old.custody != new.custody or !equal(
            []const ir.Instruction,
            old.instructions,
            new.instructions,
        ) or new.terminator != .branch) return error.InvalidLoopUnswitch;
        const split = new.terminator.branch;
        if (split.condition != branch.condition or !checkEdge(
            c,
            branch.when_true,
            split.when_true,
            0,
        ) or !checkEdge(
            c,
            branch.when_false,
            split.when_false,
            1,
        )) return error.InvalidLoopUnswitch;
    }
    for (0..2) |arm| for (c.originals, 0..) |bid, index| {
        try budget.take(1);
        const old = original.blocks[bid];
        const copy = candidate.blocks[original.blocks.len + arm * c.originals.len + index];
        // Slots and custody use an identity substitution. Copies are disjoint
        // paths of the same activation, and all internal edges stay in that copy.
        if (old.function != copy.function or old.custody != copy.custody or !equal(
            []const ir.Instruction,
            old.instructions,
            copy.instructions,
        )) return error.InvalidLoopUnswitch;
        if (bid == witness.dispatch) {
            if (copy.terminator != .jump or !checkEdge(
                c,
                if (arm == 0) branch.when_true else branch.when_false,
                copy.terminator.jump,
                arm,
            )) return error.InvalidLoopUnswitch;
        } else if (!checkTerm(
            c,
            old.terminator,
            copy.terminator,
            arm,
        )) return error.InvalidLoopUnswitch;
    };
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| if (block.terminator == .branch) {
        const targets = [_]p.Id{
            block.terminator.branch.when_true.block,
            block.terminator.branch.when_false.block,
        };
        for (targets) |bid| if (program.blocks[@intCast(bid)].terminator == .branch) return true;
    };
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
    var result = try p01.run(allocator, candidate.program, options.coalescing);
    errdefer result.deinit();
    var baseline = try p01.run(allocator, original, options.coalescing);
    defer baseline.deinit();
    const limit = std.math.add(
        usize,
        try image.encodedLength(baseline.program),
        options.max_added_bytes,
    ) catch std.math.maxInt(usize);
    if (try image.encodedLength(result.program) > limit) {
        std.mem.swap(p01.Owned, &result, &baseline);
        stats.code_budget_rejected = true;
        return result;
    }
    stats.unswitched = 1;
    stats.copied_blocks = candidate.program.blocks.len - original.blocks.len;
    return result;
}
