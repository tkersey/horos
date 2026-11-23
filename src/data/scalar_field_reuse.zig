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
    last_proved: ?proof.Witness = null,

    fn init(
        a: Allocator,
        program: ir.Program,
        flow: *const Flow,
        budget: *Budget,
    ) Error!Context {
        const catalog = try admission.schemasWithWork(a, program.schemas, budget.work());
        const permissions = try traits.deriveWithWork(a, program.schemas, budget.work());
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

    fn matches(self: *Context, w: proof.Witness) Error!bool {
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
        if (self.last_proved) |previous| {
            if (previous.source.block == w.source.block and
                previous.source.instruction == w.source.instruction and
                previous.target.block == w.target.block)
            {
                return !try self.writtenBefore(w.target, earlier.destination) and
                    !try self.writtenBefore(w.target, earlier.operands[0]);
            }
        }
        const proved = try self.workspace.proves(self.program, w, self.predecessors, self.budget);
        if (self.budget.exhausted) return error.ScalarFieldLimit;
        if (proved) self.last_proved = w;
        return proved;
    }

    fn writtenBefore(self: Context, target: Site, slot: ir.Id) Error!bool {
        return self.workspace.writtenBefore(self.program, target, slot, self.budget);
    }
};

pub const PreparedOriginal = opaque {
    fn state(self: *PreparedOriginal) *PreparedState {
        return @ptrCast(@alignCast(self));
    }

    pub fn discover(
        self: *PreparedOriginal,
        result: Allocator,
        stats: *Statistics,
    ) Error![]const Witness {
        const prepared = self.state();
        const ctx = prepared.context;
        stats.* = .{};
        var scratch = std.heap.ArenaAllocator.init(prepared.allocator());
        defer scratch.deinit();
        const selected = find(scratch.allocator(), ctx, stats) catch |err|
            return translated(err, prepared.cap.*, ctx.budget);
        var output: AllocationBudget = .{
            .parent = result,
            .remaining = ctx.budget.bytes(),
        };
        return output.allocator().dupe(Witness, selected) catch |err|
            return translated(err, output, ctx.budget);
    }

    pub fn validateObserved(
        self: *PreparedOriginal,
        candidate: ir.Program,
        witnesses: []const Witness,
        observer: anytype,
    ) !void {
        const prepared = self.state();
        const ctx = prepared.context;
        var after = check(prepared.allocator(), ctx, candidate, witnesses) catch |err|
            return translated(err, prepared.cap.*, ctx.budget);
        defer after.deinit();
        if (comptime @TypeOf(observer) != @TypeOf(null))
            observer.checked(ctx.flow, &after) catch |err| {
                if (@as(anyerror, err) == error.RelationLimit) ctx.budget.exhausted = true;
                return err;
            };
    }
};

const PreparedState = struct {
    cap: *AllocationBudget,
    context: Context,

    fn allocator(self: *PreparedState) Allocator {
        self.cap.remaining = self.context.budget.bytes();
        return self.cap.allocator();
    }
};

pub fn withPreparedOriginal(
    work: Allocator,
    original: ir.Program,
    budget: *Budget,
    observer: anytype,
) !@TypeOf(observer).Result {
    return prepare(.owned, work, original, budget, observer);
}

fn prepare(
    comptime storage: enum { owned, borrowed },
    work: Allocator,
    original: ir.Program,
    budget: *Budget,
    observer: anytype,
) !@TypeOf(observer).Result {
    var cap: AllocationBudget = .{ .parent = work, .remaining = budget.bytes() };
    var arena = std.heap.ArenaAllocator.init(cap.allocator());
    defer arena.deinit();
    const program = switch (storage) {
        .owned => snapshot(arena.allocator(), original, budget) catch |err|
            return translated(err, cap, budget),
        .borrowed => original,
    };
    var flow = analyze(cap.allocator(), program, budget) catch |err|
        return translated(err, cap, budget);
    defer flow.deinit();
    const ctx = Context.init(arena.allocator(), program, &flow, budget) catch |err|
        return translated(err, cap, budget);
    var prepared: PreparedState = .{ .cap = &cap, .context = ctx };
    return observer.prepared(@as(*PreparedOriginal, @ptrCast(&prepared)));
}

fn snapshot(a: Allocator, program: ir.Program, budget: *Budget) Error!ir.Program {
    var measure: wire.Writer = .{ .remaining = budget.work() };
    try record.write(ir.Program, program, &measure);
    const bytes = try a.alloc(u8, measure.position);
    var writer: wire.Writer = .{ .output = bytes, .remaining = budget.work() };
    try record.write(ir.Program, program, &writer);
    try spend(budget, bytes.len);
    var reader: wire.Reader = .{ .input = bytes };
    const owned = try record.read(ir.Program, &reader, a);
    try reader.finish();
    return owned;
}

const FindOriginal = struct {
    pub const Result = []const Witness;
    result: Allocator,
    stats: *Statistics,

    pub fn prepared(self: FindOriginal, original: *PreparedOriginal) Error!Result {
        return original.discover(self.result, self.stats);
    }
};

pub fn discover(
    arena: Allocator,
    original: ir.Program,
    budget: *Budget,
    stats: *Statistics,
) Error![]const Witness {
    stats.* = .{};
    return prepare(.borrowed, arena, original, budget, FindOriginal{
        .result = arena,
        .stats = stats,
    });
}

fn liveBlocks(
    a: Allocator,
    program: ir.Program,
    flow: *const Flow,
    budget: *Budget,
) Error![]const bool {
    try spend(budget, program.blocks.len);
    const live = try relocation.reachableBlocks(a, program, budget.work());
    for (flow.positions, live) |positions, *out| out.* = out.* and positions.len != 0;
    return live;
}

const Candidate = struct {
    site: Site,
    first_source: ?usize = null,
    next_source: ?usize = null,
    parent: ?usize = null,
    least: ?usize = null,
    state: State = .unmatched,

    const State = enum {
        unmatched,
        repeated,
        pending_capture,
        unavailable,
        capture,
        producer,
        replaced,
    };
};

const TreeBlock = struct {
    order: usize = 0,
    end: usize = 0,
    low: usize = 0,
    component: usize = 0,
    previous_open: ?usize = null,
    segment: usize = 0,
    parent: ?usize = null,
    next_edge: usize = 0,
    reaches_field: bool = false,
    has_capture: bool = false,
};

fn spanningTree(a: Allocator, ctx: Context) Error![]TreeBlock {
    try spend(ctx.budget, ctx.live.len);
    const tree = try a.alloc(TreeBlock, ctx.live.len);
    @memset(tree, .{});
    var order: usize = 0;
    var components: usize = 0;
    try spend(ctx.budget, ctx.program.functions.len);
    for (ctx.program.functions) |function| {
        const entry: usize = @intCast(function.entry);
        if (!ctx.live[entry]) continue;
        order += 1;
        tree[entry] = .{ .order = order, .low = order, .segment = entry };
        var open: ?usize = entry;
        var current: ?usize = entry;
        while (current) |id| {
            try spend(ctx.budget, 1);
            const block = &tree[id];
            const term = ctx.program.blocks[id].terminator;
            const edge = proof.successor(term, block.next_edge) orelse {
                block.end = order;
                if (block.low == block.order) {
                    components += 1;
                    while (open) |member| {
                        try spend(ctx.budget, 1);
                        open = tree[member].previous_open;
                        tree[member].component = components;
                        if (member == id) break;
                    }
                }
                if (block.parent) |parent| tree[parent].low = @min(tree[parent].low, block.low);
                current = block.parent;
                continue;
            };
            block.next_edge += 1;
            const target: usize = @intCast(edge.edge.block);
            if (!ctx.live[target]) continue;
            if (edge.capture_boundary) tree[entry].has_capture = true;
            if (tree[target].order != 0) {
                if (tree[target].component == 0) block.low = @min(block.low, tree[target].order);
                continue;
            }
            order += 1;
            tree[target] = .{
                .order = order,
                .low = order,
                .previous_open = open,
                .segment = if (edge.capture_boundary) target else block.segment,
                .parent = id,
            };
            open = target;
            current = target;
        }
    }
    return tree;
}

fn markFieldPaths(a: Allocator, ctx: Context, tree: []TreeBlock) Error!void {
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(a);
    try spend(ctx.budget, tree.len);
    for (tree, 0..) |block, i| {
        if (block.reaches_field) try append(usize, a, ctx.budget, &queue, i);
    }
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const incoming = ctx.predecessors[queue.items[cursor]].items;
        try spend(ctx.budget, incoming.len + 1);
        for (incoming) |edge| {
            if (tree[edge.block].reaches_field) continue;
            tree[edge.block].reaches_field = true;
            try append(usize, a, ctx.budget, &queue, edge.block);
        }
    }
}

fn find(tmp: Allocator, ctx: Context, stats: *Statistics) Error![]Witness {
    const budget = ctx.budget;
    const program = ctx.program;
    const tree = try spanningTree(tmp, ctx);
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
            tree[bid].reaches_field = true;
        }
    }
    var selected: std.ArrayList(Witness) = .empty;
    var paths: CapturePaths = .{};
    try markFieldPaths(tmp, ctx, tree);
    for (sites, program.functions) |function, declaration| {
        defer countRejections(function.items, stats);
        const ordered = try indexExpressions(tmp, ctx, function.items, tree);
        const has_capture = tree[@intCast(declaration.entry)].has_capture;
        try selectFunction(tmp, ctx, function.items, &selected, stats, has_capture);
        if (has_capture)
            try classifyCaptures(tmp, ctx, function.items, ordered, &paths, tree);
    }
    try spend(budget, selected.items.len);
    return selected.items;
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
    order: usize,
    site: usize,

    fn before(_: void, left: Ordered, right: Ordered) bool {
        return switch (std.mem.order(ir.Id, &left.expression, &right.expression)) {
            .lt => true,
            .gt => false,
            .eq => {
                if (left.region != right.region) return left.region < right.region;
                if (left.order != right.order) return left.order < right.order;
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
    tree: []const TreeBlock,
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
            .region = tree[site.block].segment,
            .order = tree[site.block].order,
            .site = i,
        };
    }
    std.sort.heap(Ordered, items, {}, Ordered.before);
    var start: usize = 0;
    while (start < items.len) {
        const end = Ordered.expressionEnd(items, start);
        try indexAncestors(sites, items, start, end, tree, ctx);
        start = end;
    }
    return items;
}

fn indexAncestors(
    sites: []Candidate,
    items: []const Ordered,
    start: usize,
    end: usize,
    tree: []const TreeBlock,
    ctx: Context,
) Error!void {
    const repeated = sites[items[start].site].site.block != sites[items[end - 1].site].site.block;
    var low = start;
    var parent: ?usize = null;
    while (low < end) {
        const first = items[low];
        if (low > start and items[low - 1].region != first.region) parent = null;
        while (parent) |p| {
            try spend(ctx.budget, 1);
            if (tree[sites[p].site.block].end >= first.order) break;
            parent = sites[p].parent;
        }
        var high = low + 1;
        while (high < end and items[high].order == first.order) high += 1;
        const least = if (parent) |p| @min(p, sites[p].least orelse p) else null;
        var last: ?usize = null;
        var first_source: ?usize = null;
        for (items[low..high]) |item| {
            const candidate = &sites[item.site];
            if (repeated and
                try ctx.workspace.survivesExit(ctx.program, candidate.site, ctx.budget))
            {
                if (last) |previous| {
                    sites[previous].next_source = item.site;
                } else first_source = item.site;
                last = item.site;
            }
            if (ctx.budget.exhausted) return error.ScalarFieldLimit;
            candidate.parent = parent;
            candidate.least = least;
            if (repeated) candidate.state = .repeated;
        }
        sites[first.site].first_source = first_source;
        if (first_source != null) parent = first.site;
        low = high;
    }
}

fn matchingBlock(
    ctx: *Context,
    sites: []Candidate,
    first: ?usize,
    target: Site,
) Error!?usize {
    var next = first;
    while (next) |i| {
        try spend(ctx.budget, 1);
        const source = sites[i];
        next = source.next_source;
        if (source.state == .replaced) continue;
        if (try ctx.matches(.{ .source = source.site, .target = target })) return i;
    }
    return null;
}

fn findSource(
    a: Allocator,
    ctx: *Context,
    sites: []Candidate,
    target: Candidate,
    alternatives: *std.ArrayList(usize),
) Error!?usize {
    const least = target.least orelse return null;
    if (try ctx.writtenBefore(target.site, instruction(ctx.program, target.site).operands[0]))
        return null;
    if (try matchingBlock(ctx, sites, sites[least].first_source, target.site)) |source|
        return source;
    alternatives.clearRetainingCapacity();
    var ancestor = target.parent;
    while (ancestor) |p| {
        try spend(ctx.budget, 1);
        if (p != least) try append(usize, a, ctx.budget, alternatives, p);
        ancestor = sites[p].parent;
    }
    const items = alternatives.items;
    const levels: usize = @bitSizeOf(usize) - @clz(items.len);
    const sorting = std.math.mul(usize, items.len, 2 * levels) catch return error.ScalarFieldLimit;
    try spend(ctx.budget, sorting);
    std.sort.heap(usize, items, {}, std.sort.asc(usize));
    for (items) |p| {
        if (try matchingBlock(ctx, sites, sites[p].first_source, target.site)) |source|
            return source;
    }
    return null;
}

fn selectFunction(
    a: Allocator,
    original: Context,
    sites: []Candidate,
    selected: *std.ArrayList(Witness),
    stats: *Statistics,
    has_capture: bool,
) Error!void {
    var ctx = original;
    var alternatives: std.ArrayList(usize) = .empty;
    defer alternatives.deinit(a);
    try spend(ctx.budget, sites.len);
    for (sites) |*target| {
        if (target.state == .producer) continue;
        const i = try findSource(a, &ctx, sites, target.*, &alternatives) orelse {
            if (target.state == .repeated)
                target.state = if (has_capture) .pending_capture else .unavailable;
            continue;
        };
        const source = &sites[i];
        source.state = .producer;
        target.state = .replaced;
        stats.proven += 1;
        if (selected.items.len == ctx.budget.limits.witnesses) return error.ScalarFieldLimit;
        try append(Witness, a, ctx.budget, selected, .{
            .source = Location.from(source.site),
            .target = Location.from(target.site),
        });
    }
}

const Origins = enum(usize) {
    none = std.math.maxInt(usize),
    several = std.math.maxInt(usize) - 1,
    _,

    fn join(self: Origins, other: Origins) Origins {
        if (self == .none) return other;
        if (other == .none or self == other) return self;
        return .several;
    }

    fn containsOther(self: Origins, block: usize) bool {
        return self != .none and self != @as(Origins, @fromBackingInt(@intCast(block)));
    }
};

const CapturePaths = struct {
    const Block = struct {
        before: Origins = .none,
        after: Origins = .none,
        queued: bool = false,
        reaches_target: bool = false,
    };
    blocks: []Block = &.{},
    queue: std.ArrayList(usize) = .empty,
    reached: std.ArrayList(usize) = .empty,

    fn merge(
        self: *CapturePaths,
        a: Allocator,
        budget: *Budget,
        target: usize,
        before: Origins,
        after: Origins,
    ) Error!void {
        const block = &self.blocks[target];
        const plain = block.before.join(before);
        const crossed = block.after.join(after);
        if (plain == block.before and crossed == block.after) return;
        block.before = plain;
        block.after = crossed;
        if (!block.queued) {
            try append(usize, a, budget, &self.queue, target);
            block.queued = true;
        }
    }

    fn markTarget(self: *CapturePaths, a: Allocator, budget: *Budget, block: usize) Error!void {
        if (self.blocks[block].reaches_target) return;
        self.blocks[block].reaches_target = true;
        try append(usize, a, budget, &self.reached, block);
    }

    fn markGroupPaths(
        self: *CapturePaths,
        a: Allocator,
        ctx: Context,
        sites: []const Candidate,
        members: []const Ordered,
        tree: []const TreeBlock,
    ) Error!void {
        var earliest_source: usize = 0;
        for (members) |item| {
            const site = sites[item.site];
            if (site.state != .replaced)
                earliest_source = @max(earliest_source, tree[site.site.block].component);
            if (site.state == .pending_capture) try self.markTarget(a, ctx.budget, site.site.block);
        }
        var reached: usize = 0;
        while (reached < self.reached.items.len) : (reached += 1) {
            const incoming = ctx.predecessors[self.reached.items[reached]].items;
            try spend(ctx.budget, incoming.len + 1);
            for (incoming) |edge| {
                if (tree[edge.block].component <= earliest_source)
                    try self.markTarget(a, ctx.budget, edge.block);
            }
        }
    }

    fn classify(
        self: *CapturePaths,
        a: Allocator,
        ctx: Context,
        sites: []Candidate,
        members: []const Ordered,
        tree: []const TreeBlock,
    ) Error!void {
        if (self.blocks.len == 0) {
            try spend(ctx.budget, ctx.live.len);
            self.blocks = try a.alloc(Block, ctx.live.len);
            @memset(self.blocks, .{});
        }
        defer {
            for (self.queue.items) |id| self.blocks[id] = .{};
            self.queue.clearRetainingCapacity();
            for (self.reached.items) |id| self.blocks[id].reaches_target = false;
            self.reached.clearRetainingCapacity();
        }
        try spend(ctx.budget, members.len);
        if (members.len != sites.len) try self.markGroupPaths(a, ctx, sites, members, tree);
        for (members) |item| {
            const site = sites[item.site];
            if (site.state != .replaced) {
                const source = site.site.block;
                try self.merge(a, ctx.budget, source, @fromBackingInt(@intCast(source)), .none);
            }
        }
        var cursor: usize = 0;
        while (cursor < self.queue.items.len) : (cursor += 1) {
            try spend(ctx.budget, 1);
            const id = self.queue.items[cursor];
            self.blocks[id].queued = false;
            const state = self.blocks[id];
            const terminator = ctx.program.blocks[id].terminator;
            var edge: usize = 0;
            while (proof.successor(terminator, edge)) |transfer| : (edge += 1) {
                try spend(ctx.budget, 1);
                const target: usize = @intCast(transfer.edge.block);
                if (members.len == sites.len) {
                    if (!tree[target].reaches_field) continue;
                } else if (!self.blocks[target].reaches_target) continue;
                const crossed = transfer.capture_boundary;
                const after = if (crossed) state.after.join(state.before) else state.after;
                try self.merge(a, ctx.budget, target, if (crossed) .none else state.before, after);
            }
        }
        for (members) |item| {
            const site = &sites[item.site];
            if (site.state != .pending_capture) continue;
            const target = site.site.block;
            const earlier = self.blocks[target].after;
            site.state = if (earlier.containsOther(target)) .capture else .unavailable;
        }
    }
};

fn copyCaptureClassifications(
    sites: []Candidate,
    previous: []const Ordered,
    members: []const Ordered,
    budget: *Budget,
) Error!bool {
    if (previous.len != members.len) return false;
    try spend(budget, members.len);
    for (previous, members) |left, right| {
        const before = sites[left.site];
        const after = sites[right.site];
        if (before.site.block != after.site.block or
            (before.state == .replaced) != (after.state == .replaced) or
            (before.state == .capture or before.state == .unavailable) !=
                (after.state == .pending_capture)) return false;
    }
    try spend(budget, members.len);
    for (previous, members) |left, right| {
        if (sites[right.site].state == .pending_capture)
            sites[right.site].state = sites[left.site].state;
    }
    return true;
}

fn classifyCaptures(
    a: Allocator,
    ctx: Context,
    sites: []Candidate,
    ordered: []const Ordered,
    paths: *CapturePaths,
    tree: []const TreeBlock,
) Error!void {
    try spend(ctx.budget, ordered.len);
    var previous: []const Ordered = &.{};
    var first: usize = 0;
    while (first < ordered.len) {
        const end = Ordered.expressionEnd(ordered, first);
        const members = ordered[first..end];
        first = end;
        for (members) |item| {
            if (sites[item.site].state == .pending_capture) break;
        } else continue;
        if (!try copyCaptureClassifications(sites, previous, members, ctx.budget))
            try paths.classify(a, ctx, sites, members, tree);
        previous = members;
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
    var cap: AllocationBudget = .{ .parent = arena, .remaining = budget.bytes() };
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
    const CheckOriginal = struct {
        pub const Result = void;
        candidate: ir.Program,
        witnesses: []const Witness,
        observer: if (@TypeOf(observer) == @TypeOf(null)) void else @TypeOf(observer),

        pub fn prepared(self: @This(), input: *PreparedOriginal) !void {
            const callback = if (@TypeOf(observer) == @TypeOf(null)) null else self.observer;
            try input.validateObserved(self.candidate, self.witnesses, callback);
        }
    };
    return prepare(.borrowed, allocator, original, budget, CheckOriginal{
        .candidate = candidate,
        .witnesses = witnesses,
        .observer = if (@TypeOf(observer) == @TypeOf(null)) {} else observer,
    });
}

fn check(
    a: Allocator,
    prepared: Context,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!Flow {
    var ctx = prepared;
    const original = ctx.program;
    const budget = ctx.budget;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const tmp = scratch.allocator();
    const targets = try index(tmp, original, witnesses, budget);
    var measure: wire.Writer = .{ .remaining = budget.work() };
    try record.write(ir.Program, original, &measure);
    try sameDeclarations(original, candidate);
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
    return analyze(a, candidate, budget);
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
    return ownership.analyzeObservedWithWork(a, program, null, null, budget.work());
}
