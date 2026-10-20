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
    const schema = (try targetSchema(program, target)) orelse return null;
    const constructor_id = target.constructor();
    const worker_id = target.worker(program);
    const worker = program.functions[@intCast(worker_id)];
    const n = target.dimension(program);
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
    const census: Census = .{
        .a = a,
        .program = program,
        .worker_id = worker_id,
        .worker = worker,
        .n = n,
        .schema = schema,
        .budget = &budget,
        .seed = &seed,
        .rows = &rows,
        .transitions = &transitions,
    };
    if (!try census.returnedSlots(returned)) return null;
    for (program.blocks, 0..) |block, block_id| {
        if (block.function != worker_id) continue;
        if (!try census.analyzeBlock(block, block_id, returned)) return null;
    }
    const plan = (try finishPlan(
        &arena,
        a,
        program,
        worker_id,
        worker,
        n,
        schema,
        constructor_id,
        seed,
        rows.items,
        &transitions,
        &budget,
    )) orelse return null;
    keep = true;
    return plan;
}

fn targetSchema(program: ir.Program, target: Target) Error!?p.Id {
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
    return schema;
}

const Census = struct {
    a: std.mem.Allocator,
    program: ir.Program,
    worker_id: p.Id,
    worker: ir.Function,
    n: usize,
    schema: p.Id,
    budget: *space.Budget,
    seed: *space.Space,
    rows: *std.ArrayList([]const space.Row),
    transitions: *std.ArrayList(Transition),
    fn returnedSlots(self: Census, returned: []bool) Error!bool {
        // A returned value is an opaque boundary result, not a hidden state copy.
        for (self.program.blocks) |block| {
            if (block.function != self.worker_id) continue;
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
                const input = std.mem.indexOfScalar(
                    p.Id,
                    self.worker.inputs,
                    assignment.destination,
                );
                switch (assignment.source) {
                    .returned => {
                        if (input != null) return false;
                        returned[@intCast(assignment.destination)] = true;
                    },
                    .slot => if (input == null) return false,
                }
            };
        }
        return true;
    }
    fn analyzeBlock(
        self: Census,
        source: ir.Block,
        block_id: usize,
        returned: []const bool,
    ) Error!bool {
        const block_value = source;
        try self.budget.charge();
        const values = try self.a.alloc(?extract.Expression, self.worker.layout.slots.len);
        const defined = try self.a.dupe(bool, returned);
        @memset(values, null);
        for (self.worker.inputs, 0..) |slot, index| {
            defined[@intCast(slot)] = true;
            if (index < self.n) values[
                @intCast(slot)
            ] = .{ .state = space.coordinate(index) } else if (self.worker.layout.slots[
                @intCast(slot)
            ] == self.schema) values[
                @intCast(slot)
            ] = .{ .input = space.coordinate(index - self.n) };
        }
        if (!try self.instructions(block_value, values, defined)) return false;
        if (!try self.scanEdges(block_value, block_id, values, defined)) return false;
        return self.terminator(block_value, block_id, values, defined);
    }
    fn instructions(
        self: Census,
        block: ir.Block,
        values: []?extract.Expression,
        defined: []bool,
    ) Error!bool {
        for (block.instructions) |op| {
            try self.budget.charge();
            if (std.mem.indexOfScalar(
                p.Id,
                self.worker.inputs,
                op.destination,
            ) != null) return false;
            for (op.operands) |slot| if (!defined[@intCast(slot)]) return false;
            const expression = try extract.instruction(
                self.program,
                self.worker,
                op,
                values,
                self.schema,
                self.budget,
            );
            if (expression == null) for (op.operands) |slot| try observe(
                self.seed,
                values[@intCast(slot)],
                self.budget,
            );
            values[@intCast(op.destination)] = expression;
            defined[@intCast(op.destination)] = true;
        }
        return true;
    }
    fn scanEdges(
        self: Census,
        block: ir.Block,
        block_id: usize,
        values: []?extract.Expression,
        defined: []bool,
    ) Error!bool {
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
                    if (!defined[@intCast(slot)]) return false;
                    if (std.mem.indexOfScalar(
                        p.Id,
                        self.worker.inputs[0..self.n],
                        assignment.destination,
                    ) == null)
                        try observe(self.seed, values[@intCast(slot)], self.budget);
                },
                .returned => {},
            };
            var captures_changed = false;
            for (edge.assignments) |assignment| if (std.mem.indexOfScalar(
                p.Id,
                self.worker.inputs[0..self.n],
                assignment.destination,
            ) != null) {
                captures_changed = true;
            };
            if (!captures_changed) continue;
            const state = (try edge_state.state(
                self.a,
                self.worker.inputs[0..self.n],
                values,
                edge,
                self.budget,
            )) orelse return false;
            const matrix = try self.a.alloc(space.Row, self.n);
            for (state, matrix) |value, *row| row.* = value.state;
            try self.rows.append(self.a, matrix);
            try self.transitions.append(self.a, .{ .block = block_id, .values = state });
        }
        return true;
    }
    fn terminator(
        self: Census,
        block: ir.Block,
        block_id: usize,
        values: []?extract.Expression,
        defined: []bool,
    ) Error!bool {
        switch (block.terminator) {
            .return_value => |slot| {
                if (!defined[@intCast(slot)]) return false;
                try observe(self.seed, values[@intCast(slot)], self.budget);
            },
            .branch => |branch| {
                if (!defined[@intCast(branch.condition)]) return false;
                try observe(self.seed, values[@intCast(branch.condition)], self.budget);
            },
            .jump => {},
            .call => |call| {
                for (call.arguments) |slot| if (!defined[@intCast(slot)]) return false;
                if (call.function == self.worker_id) {
                    const state = (try extract.interface(
                        self.a,
                        values,
                        call.arguments[0..self.n],
                        self.budget,
                    )) orelse return false;
                    const matrix = try self.a.alloc(space.Row, self.n);
                    for (state, matrix) |value, *row| row.* = value.state;
                    try self.rows.append(self.a, matrix);
                    try self.transitions.append(self.a, .{ .block = block_id, .values = state });
                    for (call.arguments[self.n..]) |slot| try observe(
                        self.seed,
                        values[@intCast(slot)],
                        self.budget,
                    );
                } else for (call.arguments) |slot| try observe(
                    self.seed,
                    values[@intCast(slot)],
                    self.budget,
                );
            },
            else => return false,
        }
        return true;
    }
};

fn finishPlan(
    arena: *std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    program: ir.Program,
    worker_id: p.Id,
    worker: ir.Function,
    n: usize,
    schema: p.Id,
    constructor_id: ?usize,
    seed: space.Space,
    rows: []const []const space.Row,
    transitions: *std.ArrayList(Transition),
    budget: *space.Budget,
) Error!?Plan {
    if (transitions.items.len == 0) return null;
    var observation_buffer: [space.max_dimension]space.Row = undefined;
    const observations = try a.dupe(space.Row, seed.rows(&observation_buffer));
    const closed = try space.close(a, seed, rows, budget);
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
    return .{
        .arena = arena.*,
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
