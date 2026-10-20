// Copyright (c) 2026 Boundary contributors. MIT license.
//! Latest placement of total word expressions at joins. No speculative paths.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const p01 = @import("coalescing.zig");
const equal = @import("record_equal.zig").equal;
pub const Error = p01.Error || error{ InvalidPartialRedundancy, PlacementWorkLimit };
pub const Options = struct { work_limit: u64 = 1_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct {
    reused_paths: usize = 0,
    computed_paths: usize = 0,
    split_edges: usize = 0,
    work_limit: bool = false,
};
pub const Placement = struct { predecessor: usize, edge: usize, source: ?usize };
pub const Witness = struct { join: usize, paths: []const Placement };
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    witness: Witness,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    remaining: u64,
    fn tick(self: *Budget) Error!void {
        if (self.remaining == 0) return error.PlacementWorkLimit;
        self.remaining -= 1;
    }
};
fn edgeAt(term: *ir.Terminator, index: usize) ?*ir.Edge {
    return switch (term.*) {
        .return_value, .fail => null,
        .jump => |*v| if (index == 0) v else null,
        .branch => |*v| if (index == 0) &v.when_true else if (index == 1) &v.when_false else null,
        else => null,
    };
}
fn edgeValue(term: ir.Terminator, index: usize) ?ir.Edge {
    return switch (term) {
        .return_value, .fail => null,
        .jump => |v| if (index == 0) v else null,
        .branch => |v| if (index == 0) v.when_true else if (index == 1) v.when_false else null,
        .switch_variant => |v| if (index < v.cases.len) v.cases[index] else null,
        .yield_value => |v| if (index == 0) v else null,
        inline else => |v| if (index == 0) v.next else null,
    };
}
fn transparent(term: ir.Terminator) bool {
    return term == .jump or term == .branch;
}
fn word(schema: p.Schema) bool {
    return switch (schema) {
        .u8, .u16, .u32, .u64 => true,
        else => false,
    };
}
fn eligible(program: ir.Program, block: ir.Block, op: ir.Instruction) bool {
    const function = program.functions[@intCast(block.function)];
    if (function.effects.len != 0 or
        function.regions.len != 0 or
        op.failures.len != 0)
        return false;
    const schema = function.layout.slots[@intCast(op.destination)];
    if (op.operands.len != 2) return false;
    const operand_schema = function.layout.slots[@intCast(op.operands[0])];
    switch (op.opcode) {
        .integer_bit_xor, .integer_bit_and, .integer_bit_or => if (!word(
            program.schemas[
                @intCast(schema)
            ],
        ) or schema != operand_schema) return false,
        .equal => if (program.schemas[
            @intCast(schema)
        ] != .boolean or !word(program.schemas[
            @intCast(operand_schema)
        ])) return false,
        else => return false,
    }
    for (op.operands) |slot| if (slot == op.destination or function.layout.slots[
        @intCast(slot)
    ] != operand_schema) return false;
    return true;
}
fn sameOperation(left: ir.Instruction, right: ir.Instruction) bool {
    var normalized = right;
    normalized.destination = left.destination;
    return equal(ir.Instruction, left, normalized);
}
fn preservesOperands(op: ir.Instruction, edge: ir.Edge) bool {
    for (edge.assignments) |assignment| {
        if (std.mem.indexOfScalar(p.Id, op.operands, assignment.destination) == null) continue;
        if (assignment.source != .slot or
            assignment.source.slot != assignment.destination)
            return false;
    }
    return true;
}
fn localSource(
    program: ir.Program,
    block: ir.Block,
    op: ir.Instruction,
    edge: ir.Edge,
    budget: *Budget,
) Error!?usize {
    if (!preservesOperands(op, edge)) return null;
    var index = block.instructions.len;
    while (index > 0) {
        index -= 1;
        try budget.tick();
        const producer = block.instructions[index];
        if (!eligible(program, block, producer) or !sameOperation(op, producer)) continue;
        if (program.functions[
            @intCast(block.function)
        ].layout.slots[
            @intCast(producer.destination)
        ] != program.functions[
            @intCast(block.function)
        ].layout.slots[
            @intCast(op.destination)
        ]) continue;
        var killed = false;
        for (block.instructions[index + 1 ..]) |later| {
            try budget.tick();
            if (later.destination == producer.destination or std.mem.indexOfScalar(
                p.Id,
                op.operands,
                later.destination,
            ) != null) {
                killed = true;
                break;
            }
        }
        if (!killed) return index;
    }
    return null;
}
fn appendAtPredecessor(block: ir.Block, edge: ir.Edge) bool {
    return block.terminator == .jump and edge.assignments.len == 0;
}

/// Admitted programs only. This is a cheap opportunity filter, not acceptance.
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| if (block.instructions.len != 0 and eligible(
        program,
        block,
        block.instructions[0],
    )) return true;
    return false;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    work_limit: u64,
) Error!?Candidate {
    var budget: Budget = .{ .remaining = work_limit };
    return constructWithBudget(allocator, original, &budget);
}
fn constructWithBudget(
    allocator: std.mem.Allocator,
    original: ir.Program,
    budget: *Budget,
) Error!?Candidate {
    var flow = try ownership.analyze(allocator, original);
    defer flow.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    for (original.blocks, 0..) |join, join_id| {
        try budget.tick();
        if (join.instructions.len == 0 or original.functions[
            @intCast(join.function)
        ].entry == join_id) continue;
        const op = join.instructions[0];
        if (!eligible(original, join, op)) continue;
        var paths: std.ArrayList(Placement) = .empty;
        var reusable: usize = 0;
        var allowed = true;
        for (original.blocks, 0..) |predecessor, id| {
            var index: usize = 0;
            while (edgeValue(predecessor.terminator, index)) |edge| : (index += 1) {
                try budget.tick();
                if (edge.block != join_id) continue;
                if (!transparent(predecessor.terminator) or
                    id == join_id or
                    predecessor.function != join.function or
                    predecessor.custody != join.custody or
                    flow.positions[id].len <= predecessor.instructions.len)
                {
                    allowed = false;
                    break;
                }
                const source = try localSource(original, predecessor, op, edge, budget);
                if (source != null) reusable += 1;
                try paths.append(a, .{ .predecessor = id, .edge = index, .source = source });
            }
            if (!allowed) break;
        }
        if (!allowed or paths.items.len < 2 or reusable == 0) continue;
        var split_count: usize = 0;
        for (paths.items) |path| if (path.source == null and !appendAtPredecessor(
            original.blocks[path.predecessor],
            edgeValue(original.blocks[path.predecessor].terminator, path.edge).?,
        )) {
            split_count += 1;
        };
        const blocks = try a.alloc(ir.Block, original.blocks.len + split_count);
        @memcpy(blocks[0..original.blocks.len], original.blocks);
        blocks[join_id].instructions = join.instructions[1..];
        var next = original.blocks.len;
        for (paths.items) |path| {
            try budget.tick();
            const before = original.blocks[path.predecessor];
            const selected = edgeAt(&blocks[path.predecessor].terminator, path.edge).?;
            if (path.source) |index| {
                const source = before.instructions[index].destination;
                var assignments: std.ArrayList(ir.Assignment) = .empty;
                for (selected.assignments) |assignment|
                    if (assignment.destination != op.destination) {
                        try assignments.append(a, assignment);
                    };
                if (source != op.destination) try assignments.append(
                    a,
                    .{ .destination = op.destination, .source = .{ .slot = source } },
                );
                selected.assignments = try assignments.toOwnedSlice(a);
            } else if (appendAtPredecessor(before, selected.*)) {
                const instructions = try a.alloc(ir.Instruction, before.instructions.len + 1);
                @memcpy(instructions[0..before.instructions.len], before.instructions);
                instructions[before.instructions.len] = op;
                blocks[path.predecessor].instructions = instructions;
            } else {
                selected.block = next;
                blocks[next] = .{
                    .function = join.function,
                    .custody = join.custody,
                    .instructions = try a.dupe(ir.Instruction, &.{op}),
                    .terminator = .{ .jump = .{ .block = join_id } },
                };
                next += 1;
            }
        }
        var program = original;
        program.blocks = blocks;
        const witness_paths = try paths.toOwnedSlice(a);
        keep = true;
        return .{
            .arena = arena,
            .program = program,
            .witness = .{ .join = join_id, .paths = witness_paths },
        };
    }
    return null;
}

// Independent forward version proof. Discovery uses reverse invalidation;
// acceptance derives every operand/result version and simultaneous edge value.
fn provesSource(
    a: std.mem.Allocator,
    program: ir.Program,
    predecessor: ir.Block,
    op: ir.Instruction,
    edge: ir.Edge,
    index: usize,
    budget: *Budget,
) Error!bool {
    if (index >= predecessor.instructions.len) return false;
    const source = predecessor.instructions[index];
    if (!eligible(program, predecessor, source) or
        source.opcode != op.opcode or
        source.immediate != op.immediate or
        source.operands.len != op.operands.len)
        return false;
    const slots = program.functions[@intCast(predecessor.function)].layout.slots;
    if (slots[@intCast(source.destination)] != slots[@intCast(op.destination)]) return false;
    const versions = try a.alloc(usize, slots.len);
    for (versions, 0..) |*value, id| value.* = id;
    const inputs = try a.alloc(usize, op.operands.len);
    for (predecessor.instructions, 0..) |instruction, at| {
        try budget.tick();
        if (at == index) for (source.operands, inputs) |slot, *value| {
            value.* = versions[@intCast(slot)];
        };
        versions[
            @intCast(instruction.destination)
        ] = if (instruction.opcode == .move) versions[
            @intCast(instruction.operands[0])
        ] else slots.len + at;
    }
    if (versions[@intCast(source.destination)] != slots.len + index) return false;
    for (op.operands, inputs) |slot, value| {
        var before = slot;
        for (edge.assignments) |assignment| if (assignment.destination == slot) {
            if (assignment.source != .slot) return false;
            before = assignment.source.slot;
            break;
        };
        if (versions[@intCast(before)] != value) return false;
    }
    return true;
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
    work_limit: u64,
) Error!void {
    var budget: Budget = .{ .remaining = work_limit };
    return validateWithBudget(allocator, original, candidate, witness, &budget);
}
fn validateWithBudget(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
    budget: *Budget,
) Error!void {
    var before_flow = try ownership.analyze(allocator, original);
    defer before_flow.deinit();
    var after_flow = try ownership.analyze(allocator, candidate);
    defer after_flow.deinit();
    if (witness.join >= original.blocks.len or
        original.blocks[witness.join].instructions.len == 0 or
        witness.paths.len < 2)
        return error.InvalidPartialRedundancy;
    const join = original.blocks[witness.join];
    const op = join.instructions[0];
    if (!eligible(original, join, op) or original.functions[
        @intCast(join.function)
    ].entry == witness.join) return error.InvalidPartialRedundancy;
    var unchanged = candidate;
    unchanged.blocks = original.blocks;
    if (!equal(
        ir.Program,
        original,
        unchanged,
    ) or candidate.blocks.len < original.blocks.len) return error.InvalidPartialRedundancy;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var path_index: usize = 0;
    var appended = original.blocks.len;
    var reused: usize = 0;
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |before, after, bid| {
        try budget.tick();
        var normalized = after;
        if (bid == witness.join) {
            if (!equal(
                []const ir.Instruction,
                before.instructions[1..],
                after.instructions,
            )) return error.InvalidPartialRedundancy;
            normalized.instructions = before.instructions;
        }
        var index: usize = 0;
        var insertion = false;
        while (edgeValue(before.terminator, index)) |edge| : (index += 1) {
            try budget.tick();
            if (edge.block != witness.join) continue;
            if (path_index >= witness.paths.len or
                !transparent(before.terminator) or
                bid == witness.join or
                before.function != join.function or
                before.custody != join.custody)
                return error.InvalidPartialRedundancy;
            const path = witness.paths[path_index];
            path_index += 1;
            if (path.predecessor != bid or
                path.edge != index)
                return error.InvalidPartialRedundancy;
            const actual = edgeAt(
                &normalized.terminator,
                index,
            ) orelse return error.InvalidPartialRedundancy;
            if (path.source) |source_index| {
                if (!try provesSource(
                    a,
                    original,
                    before,
                    op,
                    edge,
                    source_index,
                    budget,
                )) return error.InvalidPartialRedundancy;
                const source = before.instructions[source_index].destination;
                if (before_flow.positions[bid].len <= before.instructions.len or
                    !before_flow.pool.contains(
                        before_flow.positions[bid][before.instructions.len].available,
                        source,
                    ))
                    return error.InvalidPartialRedundancy;
                if (actual.block != witness.join) return error.InvalidPartialRedundancy;
                var at: usize = 0;
                for (edge.assignments) |assignment| {
                    if (assignment.destination == op.destination) continue;
                    if (at >= actual.assignments.len or !equal(
                        ir.Assignment,
                        assignment,
                        actual.assignments[at],
                    )) return error.InvalidPartialRedundancy;
                    at += 1;
                }
                if (source != op.destination) {
                    const expected: ir.Assignment = .{
                        .destination = op.destination,
                        .source = .{ .slot = source },
                    };
                    if (at >= actual.assignments.len or !equal(
                        ir.Assignment,
                        expected,
                        actual.assignments[at],
                    )) return error.InvalidPartialRedundancy;
                    at += 1;
                }
                if (at != actual.assignments.len) return error.InvalidPartialRedundancy;
                reused += 1;
            } else if (appendAtPredecessor(before, edge)) {
                if (!equal(
                    ir.Edge,
                    edge,
                    actual.*,
                ) or after.instructions.len != before.instructions.len + 1 or !equal(
                    []const ir.Instruction,
                    before.instructions,
                    after.instructions[0..before.instructions.len],
                ) or !equal(
                    ir.Instruction,
                    op,
                    after.instructions[before.instructions.len],
                )) return error.InvalidPartialRedundancy;
                insertion = true;
            } else {
                if (appended >= candidate.blocks.len or actual.block != appended or !equal(
                    []const ir.Assignment,
                    edge.assignments,
                    actual.assignments,
                )) return error.InvalidPartialRedundancy;
                const expected: ir.Block = .{
                    .function = join.function,
                    .custody = join.custody,
                    .instructions = &.{op},
                    .terminator = .{ .jump = .{ .block = witness.join } },
                };
                if (!equal(
                    ir.Block,
                    expected,
                    candidate.blocks[appended],
                )) return error.InvalidPartialRedundancy;
                appended += 1;
            }
            actual.* = edge;
        }
        if (insertion) normalized.instructions = before.instructions;
        if (!equal(ir.Block, before, normalized)) return error.InvalidPartialRedundancy;
    }
    if (path_index != witness.paths.len or
        appended != candidate.blocks.len or
        reused == 0)
        return error.InvalidPartialRedundancy;
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
    var budget: Budget = .{ .remaining = options.work_limit };
    var candidate = (constructWithBudget(allocator, original, &budget) catch |err| switch (err) {
        error.PlacementWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validateWithBudget(
        allocator,
        original,
        candidate.program,
        candidate.witness,
        &budget,
    ) catch |err| switch (err) {
        error.PlacementWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    for (candidate.witness.paths) |path| {
        if (path.source != null) stats.reused_paths += 1 else {
            stats.computed_paths += 1;
            const before = original.blocks[path.predecessor];
            if (!appendAtPredecessor(
                before,
                edgeValue(before.terminator, path.edge).?,
            )) stats.split_edges += 1;
        }
    }
    return p01.run(allocator, candidate.program, options.coalescing);
}
