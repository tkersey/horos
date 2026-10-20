// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked zero-origin, unit-step unsigned induction over admitted records.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const loops = @import("loop_regions.zig");
const origin = @import("constant_origin.zig");
pub const Error = loops.Error;
pub const Entry = struct { block: usize, edge: usize };
pub const Length = struct { sequence: p.Id, block: usize, instruction: usize };
pub const Certificate = struct {
    header: usize,
    body: usize,
    latch: usize,
    increment: usize,
    index: p.Id,
    limit: p.Id,
    one: p.Id,
    step_result: p.Id,
    maximum: u64,
    limit_upper: u64,
    actual_length: ?Length,
    members: []const bool,
    entries: []const Entry,
};
pub fn unsignedMaximum(schema: p.Schema) ?u64 {
    return switch (schema) {
        .u8 => 255,
        .u16 => 65535,
        .u32 => 4294967295,
        .u64 => std.math.maxInt(u64),
        else => null,
    };
}
pub fn changed(edge: ir.Edge, slot: p.Id) bool {
    for (edge.assignments) |assignment|
        if (assignment.destination == slot and
            (assignment.source != .slot or
                assignment.source.slot != slot))
            return true;
    return false;
}
pub fn stable(
    program: ir.Program,
    graph: loops.Graph,
    members: []const bool,
    slot: p.Id,
    budget: *loops.Budget,
) Error!bool {
    for (graph.blocks, members) |bid, inside| if (inside) {
        for (program.blocks[bid].instructions) |op| {
            try budget.take(1);
            if (op.destination == slot) return false;
        }
        var at: usize = 0;
        while (loops.edge(program.blocks[bid].terminator, at)) |edge| : (at += 1) {
            try budget.take(1);
            if (changed(edge, slot)) return false;
        }
    };
    return true;
}
fn edgeSource(edge: ir.Edge, slot: p.Id) ?p.Id {
    for (edge.assignments) |assignment|
        if (assignment.destination == slot)
            return if (assignment.source == .slot)
                assignment.source.slot
            else
                null;
    return slot;
}
pub fn entryConstant(
    program: ir.Program,
    entries: []const Entry,
    slot: p.Id,
    proof: *origin.Prover,
    budget: *loops.Budget,
) Error!?u64 {
    var value: ?u64 = null;
    for (entries) |entry| {
        try budget.take(1);
        const block = program.blocks[entry.block];
        const source = edgeSource(
            loops.edge(block.terminator, entry.edge).?,
            slot,
        ) orelse return null;
        const before = proof.work;
        const resolved = try proof.resolve(entry.block, block.instructions.len, source);
        try budget.take(@intCast(proof.work - before));
        if (proof.exhausted) return error.LoopWorkLimit;
        const constant = resolved orelse return null;
        if (constant != .unsigned) return null;
        if (value) |old| {
            if (old != constant.unsigned) return null;
        } else value = constant.unsigned;
    }
    return value;
}
fn acyclicIteration(
    graph: loops.Graph,
    members: []const bool,
    header: usize,
    budget: *loops.Budget,
) Error!bool {
    const degree = try graph.allocator.alloc(usize, graph.blocks.len);
    @memset(degree, 0);
    var pending: std.ArrayList(usize) = .empty;
    var count: usize = 0;
    for (members, 0..) |inside, node| if (inside and node != header) {
        count += 1;
        for (graph.predecessors[node].items) |pred| {
            try budget.take(1);
            if (members[pred] and pred != header) degree[node] += 1;
        }
        if (degree[node] == 0) try pending.append(graph.allocator, node);
    };
    var visited: usize = 0;
    while (pending.pop()) |node| {
        visited += 1;
        var at: usize = 0;
        while (loops.edge(
            graph.program.blocks[graph.blocks[node]].terminator,
            at,
        )) |edge| : (at += 1) {
            try budget.take(1);
            const target = graph.local[@intCast(edge.block)];
            if (!members[target] or target == header) continue;
            degree[target] -= 1;
            if (degree[target] == 0) try pending.append(graph.allocator, target);
        }
    }
    return count == visited;
}
/// Derive from the original graph. `members` must be a natural loop certified by
/// the caller's dominance proof; initialization and every transfer are rechecked.
pub fn derive(
    a: std.mem.Allocator,
    program: ir.Program,
    graph: loops.Graph,
    members: []const bool,
    header: usize,
    budget: *loops.Budget,
) Error!?Certificate {
    const h = graph.local[header];
    const f = program.functions[graph.function];
    const block = program.blocks[header];
    if (f.entry == header or
        block.instructions.len != 1 or
        block.terminator != .branch)
        return null;
    const compare = block.instructions[0];
    const branch = block.terminator.branch;
    if (compare.opcode != .less or
        compare.operands.len != 2 or
        compare.failures.len != 0 or
        compare.destination != branch.condition)
        return null;
    if (!members[
        graph.local[
            @intCast(branch.when_true.block)
        ]
    ] or members[
        graph.local[
            @intCast(branch.when_false.block)
        ]
    ]) return null;
    const index = compare.operands[0];
    const limit = compare.operands[1];
    const maximum = unsignedMaximum(
        program.schemas[
            @intCast(f.layout.slots[
                @intCast(index)
            ])
        ],
    ) orelse return null;
    if (!try stable(program, graph, members, limit, budget)) return null;
    if (!try acyclicIteration(graph, members, h, budget)) return null;
    var entries: std.ArrayList(Entry) = .empty;
    var latch: ?usize = null;
    for (graph.blocks, 0..) |bid, node| {
        var edge_index: usize = 0;
        while (loops.edge(program.blocks[bid].terminator, edge_index)) |edge| : (edge_index += 1) {
            try budget.take(1);
            if (edge.block != header) continue;
            if (members[node]) {
                if (latch != null) return null;
                latch = bid;
            } else if (graph.reachable[node]) try entries.append(
                a,
                .{ .block = bid, .edge = edge_index },
            );
        }
    }
    if (entries.items.len == 0) return null;
    const tail_id = latch orelse return null;
    const tail = program.blocks[tail_id];
    if (tail.terminator != .jump or tail.terminator.jump.block != header) return null;
    var proof: origin.Prover = .{
        .allocator = a,
        .program = program,
        .work_limit = budget.remaining,
    };
    defer proof.deinit();
    if ((try entryConstant(program, entries.items, index, &proof, budget)) != 0) return null;
    var step: ?usize = null;
    for (tail.instructions, 0..) |op, at| {
        try budget.take(1);
        if (op.opcode != .integer_add or op.operands.len != 2 or op.operands[0] != index) continue;
        const source = edgeSource(tail.terminator.jump, index) orelse continue;
        if (source != op.destination or step != null) continue;
        if (!try stable(program, graph, members, op.operands[1], budget)) continue;
        if ((try entryConstant(
            program,
            entries.items,
            op.operands[1],
            &proof,
            budget,
        )) != 1) continue;
        step = at;
    }
    const increment = step orelse return null;
    const addition = tail.instructions[increment];
    if (!try stable(program, graph, members, addition.operands[1], budget)) return null;
    // Exactly one update of the induction version occurs on every backedge.
    for (graph.blocks, members) |bid, inside|
        if (inside) {
            for (program.blocks[bid].instructions, 0..) |op, at| {
                try budget.take(1);
                if (op.destination == index and
                    !(bid == tail_id and
                        at == increment and
                        addition.destination == index))
                    return null;
                if (bid == tail_id and
                    at > increment and
                    op.destination == addition.destination)
                    return null;
            }
            var edge_index: usize = 0;
            while (loops.edge(
                program.blocks[bid].terminator,
                edge_index,
            )) |edge| : (edge_index += 1)
                for (edge.assignments) |assignment| {
                    try budget.take(1);
                    if (assignment.destination != index or
                        (assignment.source == .slot and
                            assignment.source.slot == index))
                        continue;
                    if (bid != tail_id or
                        edge.block != header or
                        assignment.source != .slot or
                        assignment.source.slot != addition.destination)
                        return null;
                };
        };
    var bound = (try entryConstant(program, entries.items, limit, &proof, budget));
    var length: ?Length = null;
    if (bound == null and std.mem.indexOfScalar(p.Id, f.inputs, limit) != null) bound = maximum;
    if (bound == null) {
        // A unique length definition over an immutable function argument is a
        // runtime length, not its schema capacity. Capacity only bounds arithmetic.
        var found: ?Length = null;
        for (graph.blocks) |bid| {
            for (program.blocks[bid].instructions, 0..) |op, at|
                if (op.destination == limit) {
                    try budget.take(1);
                    if (found != null or
                        members[graph.local[bid]] or
                        op.opcode != .sequence_length or
                        op.operands.len != 1 or
                        op.failures.len != 0)
                        return null;
                    found = .{ .sequence = op.operands[0], .block = bid, .instruction = at };
                };
            var ordinal: usize = 0;
            while (loops.edge(
                program.blocks[bid].terminator,
                ordinal,
            )) |edge| : (ordinal += 1) if (changed(edge, limit)) return null;
        }
        const source = found orelse return null;
        if (std.mem.indexOfScalar(p.Id, f.inputs, source.sequence) == null) return null;
        // Cutting the definition must make the header unreachable.
        const without = try graph.reachAvoid(graph.local[source.block], budget);
        if (without[h]) return null;
        for (graph.blocks) |bid| {
            for (program.blocks[bid].instructions) |op|
                if (op.destination == source.sequence)
                    return null;
            var ordinal: usize = 0;
            while (loops.edge(
                program.blocks[bid].terminator,
                ordinal,
            )) |edge| : (ordinal += 1) if (changed(edge, source.sequence)) return null;
        }
        bound = switch (program.schemas[@intCast(f.layout.slots[@intCast(source.sequence)])]) {
            .array => |v| v.length,
            .vector => |v| v.maximum,
            .seq => std.math.maxInt(u64),
            else => return null,
        };
        length = source;
    }
    if (bound.? > maximum) return null;
    return .{
        .header = header,
        .body = @intCast(branch.when_true.block),
        .latch = tail_id,
        .increment = increment,
        .index = index,
        .limit = limit,
        .one = addition.operands[1],
        .step_result = addition.destination,
        .maximum = maximum,
        .limit_upper = bound.?,
        .actual_length = length,
        .members = members,
        .entries = try entries.toOwnedSlice(a),
    };
}
