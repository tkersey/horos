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
const Range = struct { start: usize = 0, end: usize = 0 };
const Targets = struct {
    ranges: []const Range,
    witnesses: []const Witness,

    fn block(self: Targets, id: usize) []const Witness {
        if (self.ranges.len == 0) return &.{};
        const r = self.ranges[id];
        return self.witnesses[r.start..r.end];
    }

    fn contains(self: Targets, location: Location, budget: *Budget) Error!bool {
        var items = self.block(@intCast(location.block));
        while (items.len != 0) {
            try spend(budget, 1);
            const mid = items.len / 2;
            const position = items[mid].target.instruction;
            if (position == location.instruction) return true;
            items = if (position < location.instruction) items[mid + 1 ..] else items[0..mid];
        }
        return false;
    }
};

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
    if (witnesses.len == 0) return .{ .ranges = &.{}, .witnesses = &.{} };
    try spend(budget, program.blocks.len);
    const ranges = try a.alloc(Range, program.blocks.len);
    @memset(ranges, .{});
    var previous: ?Site = null;
    for (witnesses, 0..) |item, i| {
        const w = try item.resolve(program);
        const source = instruction(program, w.source);
        const target = instruction(program, w.target);
        if (source.opcode != .field or target.opcode != .field or
            w.source.block == w.target.block or
            program.blocks[w.source.block].function != program.blocks[w.target.block].function or
            (previous != null and !locationBefore(program, previous.?, w.target)))
            return error.InvalidExpressionReuse;
        const range = &ranges[w.target.block];
        if (previous == null or previous.?.block != w.target.block) range.start = i;
        range.end = i + 1;
        previous = w.target;
    }
    const targets: Targets = .{ .ranges = ranges, .witnesses = witnesses };
    for (witnesses) |w| if (try targets.contains(w.source, budget))
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
        budget: *Budget,
    ) Error!Context {
        const catalog = try admission.schemasWithWork(a, program.schemas, &budget.remaining);
        const permissions = try traits.deriveWithWork(a, program.schemas, &budget.remaining);
        const live = try liveBlocks(a, program, flow, budget);
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
    var cap: AllocationBudget = .{ .parent = arena, .remaining = &budget.bytes_remaining };
    var observed: Statistics = .{};
    defer stats.* = observed;
    return find(cap.allocator(), original, budget, &observed) catch |err|
        return translated(err, cap, budget);
}

fn liveBlocks(
    a: Allocator,
    program: ir.Program,
    flow: *const Flow,
    budget: *Budget,
) Error![]const bool {
    try spend(budget, program.blocks.len);
    const live = try relocation.reachableBlocks(a, program, &budget.remaining);
    for (flow.positions, live) |positions, *out| out.* = out.* and positions.len != 0;
    return live;
}

const Candidate = struct {
    site: Site,
    component: Range = .{},
    block: Range = .{},
    state: State = .unmatched,

    const State = enum { unmatched, unavailable, possible_capture, capture, producer, replaced };
};

fn find(
    a: Allocator,
    program: ir.Program,
    budget: *Budget,
    stats: *Statistics,
) Error![]Witness {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const tmp = scratch.allocator();
    var flow = try analyze(a, program, budget);
    defer flow.deinit();
    const ctx = try Context.init(tmp, program, &flow, budget);
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
            const list = &sites[@intCast(block.function)];
            try append(Candidate, tmp, budget, list, .{ .site = site });
        }
    }
    var selected: std.ArrayList(Witness) = .empty;
    var paths: CapturePaths = .{};
    for (sites) |function| {
        defer countRejections(function.items, stats);
        const ordered = try indexExpressions(tmp, ctx, function.items, regions);
        try selectFunction(tmp, ctx, function.items, ordered, &selected, stats);
        try classifyCaptures(tmp, ctx, function.items, ordered, &paths);
    }
    try spend(budget, selected.items.len);
    return a.dupe(Witness, selected.items);
}

fn append(
    comptime T: type,
    a: Allocator,
    budget: *Budget,
    list: *std.ArrayList(T),
    value: T,
) Error!void {
    if (list.items.len == list.capacity) try spend(budget, list.items.len);
    try list.append(a, value);
}

const Ordered = struct {
    expression: [3]ir.Id,
    region: usize,
    site: usize,

    fn before(_: void, left: Ordered, right: Ordered) bool {
        return switch (std.mem.order(ir.Id, &left.expression, &right.expression)) {
            .lt => true,
            .gt => false,
            .eq => {
                if (left.region != right.region) return left.region < right.region;
                return left.site < right.site;
            },
        };
    }

    fn expressionEnd(items: []const Ordered, start: usize) usize {
        var end = start + 1;
        while (end < items.len and
            std.mem.eql(ir.Id, &items[end].expression, &items[start].expression)) end += 1;
        return end;
    }
};

fn indexExpressions(
    a: Allocator,
    ctx: Context,
    sites: []Candidate,
    regions: []const usize,
) Error![]const Ordered {
    const levels: usize = @bitSizeOf(usize) - @clz(sites.len);
    const bound = std.math.mul(usize, sites.len, 2 * levels + 10) catch
        return error.ScalarFieldLimit;
    try spend(ctx.budget, bound);
    const items = try a.alloc(Ordered, sites.len);
    for (sites, items, 0..) |candidate, *item, i| {
        const site = candidate.site;
        const block = ctx.program.blocks[site.block];
        const op = block.instructions[site.instruction];
        const slots = ctx.program.functions[@intCast(block.function)].layout.slots;
        item.* = .{
            .expression = .{ op.operands[0], op.immediate, slots[@intCast(op.destination)] },
            .region = regions[site.block],
            .site = i,
        };
    }
    std.sort.heap(Ordered, items, {}, Ordered.before);
    var start: usize = 0;
    while (start < items.len) {
        const end = Ordered.expressionEnd(items, start);
        var first = start;
        while (first < end) {
            var last = first + 1;
            while (last < end and items[first].region == items[last].region) last += 1;
            var low = first;
            while (low < last) {
                const bid = sites[items[low].site].site.block;
                var high = low + 1;
                while (high < last and sites[items[high].site].site.block == bid) high += 1;
                for (items[low..high]) |item| {
                    const site = &sites[item.site];
                    site.component = .{ .start = first, .end = last };
                    site.block = .{ .start = low, .end = high };
                    if (start != first or end != last) site.state = .possible_capture;
                }
                low = high;
            }
            first = last;
        }
        start = end;
    }
    return items;
}

fn selectFunction(
    a: Allocator,
    ctx: Context,
    sites: []Candidate,
    groups: []const Ordered,
    selected: *std.ArrayList(Witness),
    stats: *Statistics,
) Error!void {
    try spend(ctx.budget, sites.len);
    for (sites) |*target| {
        if (target.state == .producer) continue;
        const candidates = [_][]const Ordered{
            groups[target.component.start..target.block.start],
            groups[target.block.end..target.component.end],
        };
        ctx.budget.capture_boundary = target.state == .possible_capture;
        search: for (candidates) |others| for (others) |item| {
            try spend(ctx.budget, 1);
            const source = &sites[item.site];
            if (source.state == .replaced) continue;
            if (!try ctx.matches(.{ .source = source.site, .target = target.site })) {
                target.state = if (ctx.budget.capture_boundary) .possible_capture else .unavailable;
                continue;
            }
            source.state = .producer;
            target.state = .replaced;
            stats.proven += 1;
            if (selected.items.len == ctx.budget.limits.witnesses) return error.ScalarFieldLimit;
            try append(Witness, a, ctx.budget, selected, .{
                .source = Location.from(source.site),
                .target = Location.from(target.site),
            });
            break :search;
        };
    }
}

const CapturePaths = struct {
    const Step = struct { block: usize, crossed: bool };
    seen: [][2]bool = &.{},
    sources: []bool = &.{},
    queue: std.ArrayList(Step) = .empty,

    fn prepare(self: *CapturePaths, a: Allocator, ctx: Context) Error!void {
        if (self.seen.len != 0) return;
        const count = ctx.live.len;
        try spend(ctx.budget, count);
        self.seen = try a.alloc([2]bool, count);
        self.sources = try a.alloc(bool, count);
        @memset(self.seen, .{ false, false });
        @memset(self.sources, false);
    }

    fn add(self: *CapturePaths, a: Allocator, budget: *Budget, step: Step) Error!void {
        const visited = &self.seen[step.block][@intFromBool(step.crossed)];
        if (visited.*) return;
        visited.* = true;
        try append(Step, a, budget, &self.queue, step);
    }

    fn precedes(self: *CapturePaths, a: Allocator, ctx: Context, target: usize) Error!bool {
        defer {
            for (self.queue.items) |step|
                self.seen[step.block][@intFromBool(step.crossed)] = false;
            self.queue.clearRetainingCapacity();
        }
        try self.add(a, ctx.budget, .{ .block = target, .crossed = false });
        var cursor: usize = 0;
        while (cursor < self.queue.items.len) : (cursor += 1) {
            try spend(ctx.budget, 1);
            const step = self.queue.items[cursor];
            for (ctx.predecessors[step.block].items) |pred| {
                try spend(ctx.budget, 1);
                const crossed = step.crossed or pred.transfer.capture_boundary;
                if (crossed and pred.block != target and self.sources[pred.block]) return true;
                try self.add(a, ctx.budget, .{ .block = pred.block, .crossed = crossed });
            }
        }
        return false;
    }
};

fn classifyCaptures(
    a: Allocator,
    ctx: Context,
    sites: []Candidate,
    ordered: []const Ordered,
    paths: *CapturePaths,
) Error!void {
    try spend(ctx.budget, ordered.len);
    var first: usize = 0;
    while (first < ordered.len) {
        const end = Ordered.expressionEnd(ordered, first);
        const members = ordered[first..end];
        first = end;
        for (members) |item| {
            if (sites[item.site].state == .possible_capture) break;
        } else continue;
        try paths.prepare(a, ctx);
        try spend(ctx.budget, members.len);
        for (members) |item| {
            const site = sites[item.site];
            if (site.state != .replaced) paths.sources[site.site.block] = true;
        }
        var previous: ?usize = null;
        var state: Candidate.State = .unavailable;
        for (members) |item| {
            const site = &sites[item.site];
            if (site.state != .possible_capture) continue;
            if (previous != site.site.block) {
                const crossed = try paths.precedes(a, ctx, site.site.block);
                state = if (crossed) .capture else .unavailable;
                previous = site.site.block;
            }
            site.state = state;
        }
        for (members) |item| paths.sources[sites[item.site].site.block] = false;
    }
}

fn countRejections(sites: []const Candidate, stats: *Statistics) void {
    for (sites) |site| switch (site.state) {
        .unavailable => stats.unavailable_version += 1,
        .capture => stats.capture_boundary += 1,
        else => {},
    };
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
    const ctx = try Context.init(tmp, original, &baseline, budget);
    for (original.blocks, candidate.blocks, 0..) |before, after, bid| {
        if (before.instructions.len != after.instructions.len) return error.InvalidExpressionReuse;
        var lhs = before;
        var rhs = after;
        lhs.instructions = &.{};
        rhs.instructions = &.{};
        if (!equal(ir.Block, lhs, rhs)) return error.InvalidExpressionReuse;
        var pending = targets.block(bid);
        for (before.instructions, after.instructions, 0..) |op, replacement, i| {
            const target: Site = .{ .block = bid, .instruction = i };
            if (pending.len == 0 or pending[0].target.instruction != i) {
                if (!equal(ir.Instruction, op, replacement)) return error.InvalidExpressionReuse;
                continue;
            }
            const loc = try pending[0].source.resolve(original);
            pending = pending[1..];
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
