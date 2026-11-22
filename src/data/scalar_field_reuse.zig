const std = @import("std");
const ir = @import("activation.zig");
const admission = @import("admission.zig");
const ownership = @import("activation_ownership.zig");
const Flow = @import("activation_flow.zig").Facts;
const traits = @import("traits.zig");
const proof = @import("expression_reuse_proof.zig");
const AllocationBudget = @import("allocation_budget.zig");
const equal = @import("record_equal.zig").equal;
const record = @import("record.zig");
const wire = @import("wire.zig");
const Allocator = std.mem.Allocator;
pub const Location = proof.Location;
pub const Witness = proof.Witness;
pub const Limits = proof.Limits;
pub const Budget = proof.Budget;
pub const Statistics = struct {
    unavailable_version: usize = 0,
    capture_boundary: usize = 0,
    unsupported_schema: usize = 0,
};
pub const Error = @import("expression_reuse.zig").Error || error{ScalarFieldLimit};
const Targets = std.AutoHashMapUnmanaged(Location, Location);

fn spend(budget: *Budget, amount: usize) Error!void {
    if (!budget.charge(amount)) return error.ScalarFieldLimit;
}

fn translated(err: Error, cap: AllocationBudget) Error {
    return switch (err) {
        error.OutOfMemory => if (cap.exhausted) error.ScalarFieldLimit else err,
        error.RelationLimit,
        error.ExpressionWorkLimit,
        error.ValueWorkLimit,
        => error.ScalarFieldLimit,
        else => err,
    };
}

fn locationBefore(program: ir.Program, lhs: Location, rhs: Location) bool {
    const lfun = program.blocks[lhs.block].function;
    const rfun = program.blocks[rhs.block].function;
    if (lfun != rfun) return lfun < rfun;
    if (lhs.block != rhs.block) return lhs.block < rhs.block;
    return lhs.instruction < rhs.instruction;
}

fn instruction(program: ir.Program, loc: Location) Error!ir.Instruction {
    if (loc.block >= program.blocks.len) return error.InvalidExpressionReuse;
    const instructions = program.blocks[loc.block].instructions;
    if (loc.instruction >= instructions.len) return error.InvalidExpressionReuse;
    return instructions[loc.instruction];
}

fn index(
    a: Allocator,
    program: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
) Error!Targets {
    if (witnesses.len > budget.limits.witnesses) return error.ScalarFieldLimit;
    try spend(budget, witnesses.len);
    var targets: Targets = .empty;
    for (witnesses, 0..) |w, i| {
        const source = try instruction(program, w.source);
        const target = try instruction(program, w.target);
        if (source.opcode != .field or target.opcode != .field or
            w.source.block == w.target.block or
            program.blocks[w.source.block].function != program.blocks[w.target.block].function or
            (i != 0 and !locationBefore(program, witnesses[i - 1].target, w.target)))
            return error.InvalidExpressionReuse;
        try targets.put(a, w.target, w.source);
    }
    for (witnesses) |w| if (targets.contains(w.source)) return error.InvalidExpressionReuse;
    return targets;
}

const Context = struct {
    program: ir.Program,
    flow: *const Flow,
    permissions: traits.Facts,
    exportable: []const bool,
    predecessors: []const std.ArrayList(proof.Predecessor),
    budget: *Budget,
    workspace: proof.Workspace,

    fn init(a: Allocator, program: ir.Program, flow: *const Flow, budget: *Budget) Error!Context {
        const catalog = try admission.schemasWithWork(a, program.schemas, &budget.remaining);
        const permissions = try traits.deriveWithWork(a, program.schemas, &budget.remaining);
        try spend(budget, program.blocks.len);
        return .{
            .program = program,
            .flow = flow,
            .exportable = catalog.exportable,
            .permissions = permissions,
            .predecessors = try proof.indexPredecessors(a, program, budget),
            .budget = budget,
            .workspace = try proof.Workspace.init(a, program, budget),
        };
    }

    fn eligible(self: Context, loc: Location) bool {
        const block = self.program.blocks[loc.block];
        const op = block.instructions[loc.instruction];
        if (op.opcode != .field or op.operands.len != 1 or op.failures.len != 0 or
            op.destination == op.operands[0]) return false;
        const slots = self.program.functions[@intCast(block.function)].layout.slots;
        const result = slots[@intCast(op.destination)];
        const input: usize = @intCast(slots[@intCast(op.operands[0])]);
        return self.program.schemas[@intCast(result)] == .u64 and
            self.program.schemas[input] == .product and self.exportable[input] and
            self.permissions.copy[input] and self.permissions.drop[input];
    }

    fn matches(self: Context, w: Witness) Error!bool {
        const earlier = try instruction(self.program, w.source);
        const later = try instruction(self.program, w.target);
        const block = self.program.blocks[w.target.block];
        const slots = self.program.functions[@intCast(block.function)].layout.slots;
        if (slots[@intCast(earlier.destination)] != slots[@intCast(later.destination)] or
            !proof.sameExpression(earlier, later)) return false;
        const positions = self.flow.positions[w.target.block];
        if (positions.len == 0 or !self.flow.pool.contains(
            positions[w.target.instruction].available,
            earlier.destination,
        )) return false;
        const proved = self.workspace.proves(self.program, w, self.predecessors, self.budget);
        if (self.budget.exhausted) return error.ScalarFieldLimit;
        return proved;
    }
};

pub fn discover(
    arena: Allocator,
    original: ir.Program,
    budget: *Budget,
    stats: *Statistics,
) Error![]const Witness {
    var cap: AllocationBudget = .{ .parent = arena, .remaining = &budget.bytes_remaining };
    var observed: Statistics = .{};
    defer stats.* = observed;
    return find(cap.allocator(), original, budget, &observed) catch |err|
        return translated(err, cap);
}

fn find(a: Allocator, program: ir.Program, budget: *Budget, stats: *Statistics) Error![]Witness {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const tmp = scratch.allocator();
    var flow = try analyze(a, program, budget);
    defer flow.deinit();
    const ctx = try Context.init(tmp, program, &flow, budget);
    try spend(budget, program.functions.len);
    const sites = try tmp.alloc(std.ArrayList(Location), program.functions.len);
    for (sites) |*list| list.* = .empty;
    for (program.blocks, 0..) |block, bid| {
        try spend(budget, block.instructions.len +| 1);
        for (block.instructions, 0..) |op, i| {
            if (op.opcode != .field) continue;
            const loc = Location{ .block = bid, .instruction = i };
            if (!ctx.eligible(loc)) {
                stats.unsupported_schema += 1;
                continue;
            }
            try sites[@intCast(block.function)].append(tmp, loc);
        }
    }
    var selected: std.ArrayList(Witness) = .empty;
    var targets: Targets = .empty;
    var producers: std.AutoHashMapUnmanaged(Location, void) = .empty;
    for (sites) |function| for (function.items) |target| {
        if (producers.contains(target)) continue;
        var repeated = false;
        budget.capture_boundary = false;
        for (function.items) |source| {
            try spend(budget, 1);
            if (source.block == target.block or targets.contains(source)) continue;
            const early = try instruction(program, source);
            const late = try instruction(program, target);
            if (!proof.sameExpression(early, late)) continue;
            repeated = true;
            const w: Witness = .{ .source = source, .target = target };
            if (!try ctx.matches(w)) continue;
            if (selected.items.len == budget.limits.witnesses) return error.ScalarFieldLimit;
            try selected.append(tmp, w);
            try targets.put(tmp, target, source);
            try producers.put(tmp, source, {});
            break;
        } else if (repeated) {
            if (budget.capture_boundary) {
                stats.capture_boundary += 1;
            } else stats.unavailable_version += 1;
        }
    };
    return a.dupe(Witness, selected.items);
}

pub fn reconstruct(
    arena: Allocator,
    original: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
) Error!ir.Program {
    var cap: AllocationBudget = .{ .parent = arena, .remaining = &budget.bytes_remaining };
    return rewritten(cap.allocator(), original, witnesses, budget) catch |err|
        return translated(err, cap);
}

fn rewritten(
    a: Allocator,
    original: ir.Program,
    ws: []const Witness,
    budget: *Budget,
) Error!ir.Program {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    _ = try index(scratch.allocator(), original, ws, budget);
    if (ws.len == 0) return original;
    try spend(budget, original.blocks.len);
    var result = original;
    const blocks = try a.dupe(ir.Block, original.blocks);
    errdefer {
        for (original.blocks, blocks) |before, after| {
            if (before.instructions.ptr != after.instructions.ptr) a.free(after.instructions);
        }
        a.free(blocks);
    }
    result.blocks = blocks;
    var prior: ?usize = null;
    var instructions: []ir.Instruction = &.{};
    for (ws) |w| {
        const block = &blocks[w.target.block];
        if (prior != w.target.block) {
            try spend(budget, block.instructions.len);
            instructions = try a.dupe(ir.Instruction, block.instructions);
            block.instructions = instructions;
            prior = w.target.block;
        }
        const early = &original.blocks[w.source.block].instructions[w.source.instruction];
        const target = &instructions[w.target.instruction];
        target.* = .{
            .destination = target.destination,
            .opcode = .move,
            .operands = (&early.destination)[0..1],
        };
    }
    return result;
}

pub fn validate(
    allocator: Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
) Error!void {
    return validateObserved(allocator, original, candidate, witnesses, budget, null);
}

pub fn validateObserved(
    allocator: Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
    observer: anytype,
) !void {
    var cap: AllocationBudget = .{ .parent = allocator, .remaining = &budget.bytes_remaining };
    var facts = check(cap.allocator(), original, candidate, witnesses, budget) catch |err|
        return translated(err, cap);
    defer facts.original.deinit();
    defer facts.candidate.deinit();
    if (comptime @TypeOf(observer) != @TypeOf(null))
        try observer.checked(&facts.original, &facts.candidate);
}

fn check(
    a: Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
) Error!struct { original: Flow, candidate: Flow } {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const tmp = scratch.allocator();
    const targets = try index(tmp, original, witnesses, budget);
    var measure: wire.Writer = .{ .remaining = &budget.remaining };
    try record.write(ir.Program, original, &measure);
    try sameDeclarations(original, candidate);
    var baseline = try analyze(a, original, budget);
    errdefer baseline.deinit();
    const ctx = try Context.init(tmp, original, &baseline, budget);
    for (original.blocks, candidate.blocks, 0..) |before, after, bid| {
        if (before.instructions.len != after.instructions.len) return error.InvalidExpressionReuse;
        var lhs = before;
        var rhs = after;
        lhs.instructions = &.{};
        rhs.instructions = &.{};
        if (!equal(ir.Block, lhs, rhs)) return error.InvalidExpressionReuse;
        for (before.instructions, after.instructions, 0..) |op, replacement, i| {
            const target: Location = .{ .block = bid, .instruction = i };
            const loc = targets.get(target) orelse {
                if (!equal(ir.Instruction, op, replacement)) return error.InvalidExpressionReuse;
                continue;
            };
            const w = Witness{ .source = loc, .target = target };
            if (!ctx.eligible(loc) or !ctx.eligible(target) or !try ctx.matches(w))
                return error.InvalidExpressionReuse;
            const earlier = try instruction(original, loc);
            const expected: ir.Instruction = .{
                .destination = op.destination,
                .opcode = .move,
                .operands = &.{earlier.destination},
            };
            if (!equal(ir.Instruction, expected, replacement)) return error.InvalidExpressionReuse;
        }
    }
    return .{ .original = baseline, .candidate = try analyze(a, candidate, budget) };
}

fn sameDeclarations(original: ir.Program, candidate: ir.Program) Error!void {
    if (original.blocks.len != candidate.blocks.len) return error.InvalidExpressionReuse;
    var lhs = original;
    var rhs = candidate;
    lhs.blocks = &.{};
    rhs.blocks = &.{};
    if (!equal(ir.Program, lhs, rhs)) return error.InvalidExpressionReuse;
}

fn analyze(a: Allocator, program: ir.Program, budget: *Budget) Error!Flow {
    return ownership.analyzeObservedWithWork(a, program, null, null, &budget.remaining);
}
