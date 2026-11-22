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
const relocation = @import("relocation.zig");
const Site = proof.Location;
pub const Location = struct {
    block: u64,
    instruction: u64,

    fn resolve(self: Location, program: ir.Program) Error!Site {
        if (self.block >= program.blocks.len) return error.InvalidExpressionReuse;
        const block: usize = @intCast(self.block);
        if (self.instruction >= program.blocks[block].instructions.len)
            return error.InvalidExpressionReuse;
        return .{ .block = block, .instruction = @intCast(self.instruction) };
    }

    fn from(site: Site) Location {
        return .{ .block = site.block, .instruction = site.instruction };
    }
};
pub const Witness = struct {
    target: Location,
    source: Location,

    fn resolve(self: Witness, program: ir.Program) Error!proof.Witness {
        return .{
            .source = try self.source.resolve(program),
            .target = try self.target.resolve(program),
        };
    }
};
pub const Limits = proof.Limits;
pub const Budget = proof.Budget;
pub const Statistics = struct {
    proven: usize = 0,
    unavailable_version: usize = 0,
    capture_boundary: usize = 0,
    unsupported_schema: usize = 0,
};
pub const Error = @import("expression_reuse.zig").Error || error{ScalarFieldLimit};
const Targets = std.AutoHashMapUnmanaged(Site, Site);

fn spend(budget: *Budget, amount: usize) Error!void {
    if (!budget.charge(amount)) return error.ScalarFieldLimit;
}

fn translated(err: Error, cap: AllocationBudget, budget: *Budget) Error {
    const result: Error = switch (err) {
        error.OutOfMemory => if (cap.exhausted) error.ScalarFieldLimit else err,
        error.RelationLimit,
        error.ExpressionWorkLimit,
        error.ValueWorkLimit,
        => error.ScalarFieldLimit,
        else => err,
    };
    if (result == error.ScalarFieldLimit) budget.exhausted = true;
    return result;
}

fn locationBefore(program: ir.Program, lhs: Site, rhs: Site) bool {
    const lfun = program.blocks[lhs.block].function;
    const rfun = program.blocks[rhs.block].function;
    if (lfun != rfun) return lfun < rfun;
    if (lhs.block != rhs.block) return lhs.block < rhs.block;
    return lhs.instruction < rhs.instruction;
}

fn instruction(program: ir.Program, site: Site) ir.Instruction {
    return program.blocks[site.block].instructions[site.instruction];
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
    var previous: ?Site = null;
    for (witnesses) |item| {
        const w = try item.resolve(program);
        const source = instruction(program, w.source);
        const target = instruction(program, w.target);
        if (source.opcode != .field or target.opcode != .field or
            w.source.block == w.target.block or
            program.blocks[w.source.block].function != program.blocks[w.target.block].function or
            (previous != null and !locationBefore(program, previous.?, w.target)))
            return error.InvalidExpressionReuse;
        previous = w.target;
        try targets.put(a, w.target, w.source);
    }
    for (witnesses) |w| if (targets.contains(try w.source.resolve(program)))
        return error.InvalidExpressionReuse;
    return targets;
}

const Context = struct {
    program: ir.Program,
    flow: *const Flow,
    permissions: traits.Facts,
    exportable: []const bool,
    live: []const bool,
    predecessors: []const std.ArrayList(proof.Predecessor),
    budget: *Budget,
    workspace: proof.Workspace,

    fn init(
        a: Allocator,
        program: ir.Program,
        flow: *const Flow,
        block_map: ?[]const ir.Id,
        budget: *Budget,
    ) Error!Context {
        const catalog = try admission.schemasWithWork(a, program.schemas, &budget.remaining);
        const permissions = try traits.deriveWithWork(a, program.schemas, &budget.remaining);
        const live = try liveBlocks(a, program, flow, block_map, budget);
        return .{
            .program = program,
            .flow = flow,
            .exportable = catalog.exportable,
            .permissions = permissions,
            .live = live,
            .predecessors = try proof.indexLivePredecessors(a, program, live, budget),
            .budget = budget,
            .workspace = try proof.Workspace.init(a, program, budget),
        };
    }

    fn eligible(self: Context, loc: Site) bool {
        if (!self.live[loc.block]) return false;
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

    fn matches(self: Context, w: proof.Witness) Error!bool {
        const earlier = instruction(self.program, w.source);
        const later = instruction(self.program, w.target);
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
    return discoverReachable(arena, original, null, budget, stats);
}

pub fn discoverReachable(
    arena: Allocator,
    original: ir.Program,
    block_map: ?[]const ir.Id,
    budget: *Budget,
    stats: *Statistics,
) Error![]const Witness {
    var cap: AllocationBudget = .{ .parent = arena, .remaining = &budget.bytes_remaining };
    var observed: Statistics = .{};
    defer stats.* = observed;
    return find(cap.allocator(), original, block_map, budget, &observed) catch |err|
        return translated(err, cap, budget);
}

fn liveBlocks(
    a: Allocator,
    program: ir.Program,
    flow: *const Flow,
    map: ?[]const ir.Id,
    budget: *Budget,
) Error![]const bool {
    try spend(budget, program.blocks.len);
    const live = if (map) |blocks| mapped: {
        if (blocks.len != program.blocks.len) return error.InvalidCorrespondence;
        const result = try a.alloc(bool, blocks.len);
        for (blocks, result) |block, *out| out.* = block != relocation.missing;
        break :mapped result;
    } else try relocation.reachableBlocks(a, program, &budget.remaining);
    for (flow.positions, live) |positions, *out| out.* = out.* and positions.len != 0;
    return live;
}

const Candidate = struct {
    site: Site,
    group: usize = 0,
    range: usize = 0,
    state: enum { unmatched, unavailable, capture, producer, replaced } = .unmatched,
};

fn find(
    a: Allocator,
    program: ir.Program,
    block_map: ?[]const ir.Id,
    budget: *Budget,
    stats: *Statistics,
) Error![]Witness {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const tmp = scratch.allocator();
    var flow = try analyze(a, program, budget);
    defer flow.deinit();
    const ctx = try Context.init(tmp, program, &flow, block_map, budget);
    const regions = try proof.transparentRegions(tmp, program, ctx.live, budget);
    try spend(budget, program.functions.len);
    const sites = try tmp.alloc(std.ArrayList(Candidate), program.functions.len);
    for (sites) |*list| list.* = .empty;
    for (program.blocks, ctx.live, 0..) |block, live, bid| {
        try spend(budget, 1);
        if (!live) continue;
        try spend(budget, block.instructions.len);
        for (block.instructions, 0..) |op, i| {
            if (op.opcode != .field) continue;
            const site: Site = .{ .block = bid, .instruction = i };
            if (!ctx.eligible(site)) {
                stats.unsupported_schema += 1;
                continue;
            }
            try sites[@intCast(block.function)].append(tmp, .{ .site = site });
        }
    }
    var selected: std.ArrayList(Witness) = .empty;
    for (sites, program.functions) |function, record_function| {
        const groups = try indexExpressions(tmp, ctx, function.items, regions);
        const entry = regions[@intCast(record_function.entry)];
        try selectFunction(tmp, ctx, function.items, groups, entry, &selected, stats);
    }
    return a.dupe(Witness, selected.items);
}

const Group = struct {
    region: usize,
    across_capture: bool = false,
    members: std.ArrayList(usize) = .empty,
    ranges: std.ArrayList(struct { block: usize, start: usize, end: usize }) = .empty,

    fn append(self: *Group, a: Allocator, block: usize, member: usize) Error!usize {
        const pos = self.members.items.len;
        const last = self.ranges.getLastOrNull();
        if (last == null or last.?.block != block)
            try self.ranges.append(a, .{ .block = block, .start = pos, .end = pos });
        try self.members.append(a, member);
        const index_last = self.ranges.items.len - 1;
        self.ranges.items[index_last].end = self.members.items.len;
        return index_last;
    }
};

fn indexExpressions(
    a: Allocator,
    ctx: Context,
    sites: []Candidate,
    regions: []const usize,
) Error![]const Group {
    const Expression = struct { operand: ir.Id, coordinate: ir.Id, schema: ir.Id };
    const Key = struct { expression: Expression, region: usize };
    var first_group: std.AutoHashMapUnmanaged(Expression, usize) = .empty;
    var index_by_key: std.AutoHashMapUnmanaged(Key, usize) = .empty;
    var groups: std.ArrayList(Group) = .empty;
    try spend(ctx.budget, sites.len);
    for (sites, 0..) |*candidate, i| {
        const site = candidate.site;
        const block = ctx.program.blocks[site.block];
        const op = block.instructions[site.instruction];
        const slots = ctx.program.functions[@intCast(block.function)].layout.slots;
        const expression: Expression = .{
            .operand = op.operands[0],
            .coordinate = op.immediate,
            .schema = slots[@intCast(op.destination)],
        };
        const region = regions[site.block];
        const group = try index_by_key.getOrPut(a, .{ .expression = expression, .region = region });
        if (!group.found_existing) {
            const first = try first_group.getOrPut(a, expression);
            group.value_ptr.* = groups.items.len;
            if (first.found_existing)
                groups.items[first.value_ptr.*].across_capture = true
            else
                first.value_ptr.* = groups.items.len;
            try groups.append(a, .{ .region = region, .across_capture = first.found_existing });
        }
        candidate.group = group.value_ptr.*;
        candidate.range = try groups.items[candidate.group].append(a, site.block, i);
    }
    return groups.items;
}

fn selectFunction(
    a: Allocator,
    ctx: Context,
    sites: []Candidate,
    groups: []const Group,
    entry: usize,
    selected: *std.ArrayList(Witness),
    stats: *Statistics,
) Error!void {
    try spend(ctx.budget, sites.len);
    defer for (sites) |candidate| {
        switch (candidate.state) {
            .unavailable => stats.unavailable_version += 1,
            .capture => stats.capture_boundary += 1,
            else => {},
        }
    };
    for (sites) |*target| {
        if (target.state == .producer) continue;
        const group = groups[target.group];
        if (group.across_capture)
            target.state = if (group.region == entry) .unavailable else .capture;
        const range = group.ranges.items[target.range];
        const candidates = [_][]const usize{
            group.members.items[0..range.start],
            group.members.items[range.end..],
        };
        ctx.budget.capture_boundary = target.state == .capture;
        search: for (candidates) |others| for (others) |id| {
            try spend(ctx.budget, 1);
            const source = &sites[id];
            if (source.state == .replaced) continue;
            if (!try ctx.matches(.{ .source = source.site, .target = target.site })) {
                target.state = if (ctx.budget.capture_boundary) .capture else .unavailable;
                continue;
            }
            source.state = .producer;
            target.state = .replaced;
            stats.proven += 1;
            if (selected.items.len == ctx.budget.limits.witnesses) return error.ScalarFieldLimit;
            try selected.append(a, .{
                .source = Location.from(source.site),
                .target = Location.from(target.site),
            });
            break :search;
        };
    }
}

pub fn reconstructBorrowedProposal(
    arena: Allocator,
    original: ir.Program,
    witnesses: []const Witness,
    budget: *Budget,
) Error!ir.Program {
    var cap: AllocationBudget = .{ .parent = arena, .remaining = &budget.bytes_remaining };
    return rewritten(cap.allocator(), original, witnesses, budget) catch |err|
        return translated(err, cap, budget);
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
    for (ws) |item| {
        const w = try item.resolve(original);
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
        return translated(err, cap, budget);
    defer facts.original.deinit();
    defer facts.candidate.deinit();
    if (comptime @TypeOf(observer) != @TypeOf(null))
        observer.checked(&facts.original, &facts.candidate) catch |err| {
            if (@as(anyerror, err) == error.RelationLimit) budget.exhausted = true;
            return err;
        };
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
    const ctx = try Context.init(tmp, original, &baseline, null, budget);
    for (original.blocks, candidate.blocks, 0..) |before, after, bid| {
        if (before.instructions.len != after.instructions.len) return error.InvalidExpressionReuse;
        var lhs = before;
        var rhs = after;
        lhs.instructions = &.{};
        rhs.instructions = &.{};
        if (!equal(ir.Block, lhs, rhs)) return error.InvalidExpressionReuse;
        for (before.instructions, after.instructions, 0..) |op, replacement, i| {
            const target: Site = .{ .block = bid, .instruction = i };
            const loc = targets.get(target) orelse {
                if (!equal(ir.Instruction, op, replacement)) return error.InvalidExpressionReuse;
                continue;
            };
            const w = proof.Witness{ .source = loc, .target = target };
            if (!ctx.eligible(loc) or !ctx.eligible(target) or !try ctx.matches(w))
                return error.InvalidExpressionReuse;
            const earlier = instruction(original, loc);
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
