// Copyright (c) 2026 Boundary contributors. MIT license.
//! Private capture/worker affine census. This plan is not rewrite acceptance.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const extract = @import("affine_extract.zig");
const space = @import("affine_space.zig");
const edge_state = @import("affine_edges.zig");
const privacy = @import("capture_reduction.zig");
const ownership = @import("activation_ownership.zig");
pub const Error = ownership.Error || space.Error;
pub const Target = @import("affine_target.zig").Target;
pub const Transition = struct { block: usize, values: []const extract.Expression };
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    constructor: ?usize,
    worker: p.Id,
    schema: p.Id,
    dimension: usize,
    basis: []const space.Row,
    input_bias: []const u64,
    observations: []const space.Row,
    transitions: []const Transition,
    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn observe(seed: *space.Space, value: ?extract.Expression, budget: *space.Budget) Error!void {
    if (value) |v| _ = try seed.insert(v.state, budget);
}

/// Original admission precedes discovery for either private interface form.
pub fn analyze(
    allocator: std.mem.Allocator,
    program: ir.Program,
    constructor_id: usize,
    work_limit: u64,
) Error!?Plan {
    return analyzeTarget(allocator, program, .{ .capture = constructor_id }, work_limit);
}
pub fn analyzeTarget(
    allocator: std.mem.Allocator,
    program: ir.Program,
    target: Target,
    work_limit: u64,
) Error!?Plan {
    var flow = try ownership.analyze(allocator, program);
    defer flow.deinit();
    const constructor_id = target.constructor();
    if (constructor_id) |id| {
        if (id >= program.constructors.len or !privacy.privateWorker(
            program,
            id,
        ) or !privacy.privateConstructions(program, id)) return null;
        const capture = program.scopes.captures[@intCast(program.constructors[id].capture)];
        if (capture.owned_regions.len != 0 or
            capture.borrowed_regions.len != 0 or
            capture.use != .reusable)
            return null;
    } else if (!privacy.privateDirectWorker(program, target.parameters.worker)) return null;
    const worker_id = target.worker(program);
    const worker = program.functions[@intCast(worker_id)];
    const n = target.dimension(program);
    if (n == 0 or
        n > space.max_dimension or
        n > worker.inputs.len or
        worker.effects.len != 0 or
        worker.regions.len != 0)
        return null;
    const schema = worker.layout.slots[@intCast(worker.inputs[0])];
    if (extract.unsignedWidth(program.schemas[@intCast(schema)]) == null) return null;
    for (worker.inputs[0..n]) |slot| if (worker.layout.slots[@intCast(slot)] != schema) return null;
    if (worker.inputs.len - n > space.max_dimension) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: space.Budget = .{ .remaining = work_limit };
    var seed = try space.Space.init(n);
    var transitions: std.ArrayList(Transition) = .empty;
    var rows: std.ArrayList([]const space.Row) = .empty;
    const returned = try a.alloc(bool, worker.layout.slots.len);
    @memset(returned, false);
    // A returned value is an opaque boundary result, not a hidden state copy.
    for (program.blocks) |block| {
        if (block.function != worker_id) continue;
        var edges: [2]ir.Edge = undefined;
        const count: usize = switch (block.terminator) {
            .call => |call| blk: {
                edges[0] = call.next;
                break :blk 1;
            },
            .jump => |edge| blk: {
                edges[0] = edge;
                break :blk 1;
            },
            .branch => |branch| blk: {
                edges[0] = branch.when_true;
                edges[1] = branch.when_false;
                break :blk 2;
            },
            else => 0,
        };
        for (edges[0..count]) |edge| for (edge.assignments) |assignment| {
            const input = std.mem.indexOfScalar(p.Id, worker.inputs, assignment.destination);
            switch (assignment.source) {
                .returned => {
                    if (input != null) return null;
                    returned[@intCast(assignment.destination)] = true;
                },
                .slot => if (input == null) return null,
            }
        };
    }
    for (program.blocks, 0..) |block, block_id| {
        if (block.function != worker_id) continue;
        try budget.charge();
        const values = try a.alloc(?extract.Expression, worker.layout.slots.len);
        const defined = try a.dupe(bool, returned);
        @memset(values, null);
        for (worker.inputs, 0..) |slot, index| {
            defined[@intCast(slot)] = true;
            if (index < n) values[
                @intCast(slot)
            ] = .{ .state = space.coordinate(index) } else if (worker.layout.slots[
                @intCast(slot)
            ] == schema) values[
                @intCast(slot)
            ] = .{ .input = space.coordinate(index - n) };
        }
        for (block.instructions) |op| {
            try budget.charge();
            if (std.mem.indexOfScalar(p.Id, worker.inputs, op.destination) != null) return null;
            for (op.operands) |slot| if (!defined[@intCast(slot)]) return null;
            const expression = try extract.instruction(
                program,
                worker,
                op,
                values,
                schema,
                &budget,
            );
            if (expression == null) for (op.operands) |slot| try observe(
                &seed,
                values[@intCast(slot)],
                &budget,
            );
            values[@intCast(op.destination)] = expression;
            defined[@intCast(op.destination)] = true;
        }
        var edges: [2]ir.Edge = undefined;
        const edge_count: usize = switch (block.terminator) {
            .call => |call| blk: {
                edges[0] = call.next;
                break :blk 1;
            },
            .jump => |edge| blk: {
                edges[0] = edge;
                break :blk 1;
            },
            .branch => |branch| blk: {
                edges[0] = branch.when_true;
                edges[1] = branch.when_false;
                break :blk 2;
            },
            else => 0,
        };
        for (edges[0..edge_count]) |edge| {
            if (edge.assignments.len == 0) continue;
            for (edge.assignments) |assignment| switch (assignment.source) {
                .slot => |slot| {
                    if (!defined[@intCast(slot)]) return null;
                    if (std.mem.indexOfScalar(
                        p.Id,
                        worker.inputs[0..n],
                        assignment.destination,
                    ) == null)
                        try observe(&seed, values[@intCast(slot)], &budget);
                },
                .returned => {},
            };
            var captures_changed = false;
            for (edge.assignments) |assignment| if (std.mem.indexOfScalar(
                p.Id,
                worker.inputs[0..n],
                assignment.destination,
            ) != null) {
                captures_changed = true;
            };
            if (!captures_changed) continue;
            const state = (try edge_state.state(
                a,
                worker.inputs[0..n],
                values,
                edge,
                &budget,
            )) orelse return null;
            const matrix = try a.alloc(space.Row, n);
            for (state, matrix) |value, *row| row.* = value.state;
            try rows.append(a, matrix);
            try transitions.append(a, .{ .block = block_id, .values = state });
        }
        switch (block.terminator) {
            .return_value => |slot| {
                if (!defined[@intCast(slot)]) return null;
                try observe(&seed, values[@intCast(slot)], &budget);
            },
            .branch => |branch| {
                if (!defined[@intCast(branch.condition)]) return null;
                try observe(&seed, values[@intCast(branch.condition)], &budget);
            },
            .jump => {},
            .call => |call| {
                for (call.arguments) |slot| if (!defined[@intCast(slot)]) return null;
                if (call.function == worker_id) {
                    const state = (try extract.interface(
                        a,
                        values,
                        call.arguments[0..n],
                        &budget,
                    )) orelse return null;
                    const matrix = try a.alloc(space.Row, n);
                    for (state, matrix) |value, *row| row.* = value.state;
                    try rows.append(a, matrix);
                    try transitions.append(a, .{ .block = block_id, .values = state });
                    for (call.arguments[n..]) |slot| try observe(
                        &seed,
                        values[@intCast(slot)],
                        &budget,
                    );
                } else for (call.arguments) |slot| try observe(
                    &seed,
                    values[@intCast(slot)],
                    &budget,
                );
            },
            else => return null,
        }
    }
    if (transitions.items.len == 0) return null;
    var observation_buffer: [space.max_dimension]space.Row = undefined;
    const observations = try a.dupe(space.Row, seed.rows(&observation_buffer));
    const closed = try space.close(a, seed, rows.items, &budget);
    var basis_buffer: [space.max_dimension]space.Row = undefined;
    const basis = try a.dupe(space.Row, closed.rows(&basis_buffer));
    const owned_transitions = try transitions.toOwnedSlice(a);
    const input_bias = try a.alloc(u64, worker.inputs.len - n);
    @memset(input_bias, 0);
    for (owned_transitions) |transition| for (transition.values) |value| {
        if (@popCount(value.input) != 1 or value.constant == 0) continue;
        const index: usize = @intCast(@ctz(value.input));
        if (index < input_bias.len) input_bias[index] = value.constant;
    };
    // This first normalization keeps encoded input values invariant through CFG
    // edges. Reassigned dynamic inputs retain their original representation.
    for (program.blocks) |block| {
        if (block.function != worker_id) continue;
        for (worker.inputs[n..], input_bias) |slot, *bias| {
            if (@import("slot_access.zig").terminator(
                block.terminator,
                slot,
            ).writes != 0) bias.* = 0;
        }
    }
    keep = true;
    return .{
        .arena = arena,
        .constructor = constructor_id,
        .worker = worker_id,
        .schema = schema,
        .dimension = n,
        .basis = basis,
        .input_bias = input_bias,
        .observations = observations,
        .transitions = owned_transitions,
    };
}
