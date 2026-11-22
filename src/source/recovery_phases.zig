// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const ast = @import("ast.zig");
const Binding = @import("activation_lower.zig").RecoveryBinding;
const ir = data.activation;
const Id = ir.Id;
const Facts = data.activation_flow.Facts;
const Map = data.coalescing.Correspondence;
const spend = data.admission.spend;
const missing = data.relocation.missing;
const Error = error{ RecoveryLiveness, InvalidCorrespondence, RelationLimit, OutOfMemory };

pub const Formal = struct {
    function: Id,
    ordinal: usize,

    fn key(self: Formal) u128 {
        return (@as(u128, self.function) << 64) | self.ordinal;
    }
};

pub const Normalized = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Formal) = .empty,

    pub fn formals(self: *const Normalized) []const Formal {
        return self.entries.items;
    }

    pub fn deinit(self: *Normalized) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

const FormalIndex = struct {
    const Link = union(enum) { entry: usize, branch: usize };
    const Branch = struct { mask: u128, children: [2]Link };
    const work_group = 16;

    root: Link = .{ .entry = 0 },
    branches: std.ArrayList(Branch) = .empty,

    fn edge(self: *FormalIndex, key: u128, stop: u128, work: *u64) Error!*Link {
        var link = &self.root;
        var depth: usize = 0;
        while (link.* == .branch) {
            const branch = &self.branches.items[link.branch];
            if (branch.mask <= stop) break;
            if (depth != 0 and depth % work_group == 0) try spend(work, 1);
            link = &branch.children[@intFromBool(key & branch.mask != 0)];
            depth += 1;
        }
        return link;
    }

    fn reserve(a: std.mem.Allocator, list: anytype, work: *u64) Error!void {
        const count = list.items.len;
        if (count == list.capacity and count >= work_group)
            try spend(work, 1 + (count - 1) / work_group);
        try list.ensureUnusedCapacity(a, 1);
    }

    fn include(self: *FormalIndex, selected: *Normalized, role: Formal, work: *u64) Error!void {
        const entries = &selected.entries;
        if (entries.items.len == 0) {
            try entries.append(selected.allocator, role);
            return;
        }
        const key = role.key();
        const leaf = (try self.edge(key, 0, work)).entry;
        const different = key ^ entries.items[leaf].key();
        if (different == 0) return;
        try reserve(selected.allocator, entries, work);
        try reserve(selected.allocator, &self.branches, work);
        const mask = std.math.floorPowerOfTwo(u128, different);
        const link = try self.edge(key, mask, work);
        var children = [2]Link{ link.*, link.* };
        children[@intFromBool(key & mask != 0)] = .{ .entry = entries.items.len };
        link.* = .{ .branch = self.branches.items.len };
        self.branches.appendAssumeCapacity(.{ .mask = mask, .children = children });
        entries.appendAssumeCapacity(role);
    }
};

pub fn normalize(
    a: std.mem.Allocator,
    module: ast.Module,
    submitted: []const Formal,
    work: *u64,
) Error!Normalized {
    try spend(work, submitted.len);
    var selected: Normalized = .{ .allocator = a };
    errdefer selected.deinit();
    var index: FormalIndex = .{};
    defer index.branches.deinit(a);
    for (submitted) |role| {
        if (role.function >= module.functions.len or
            role.ordinal >= module.functions[@intCast(role.function)].parameters.len)
            return error.InvalidCorrespondence;
        try index.include(&selected, role, work);
    }
    return selected;
}

const Function = struct {
    offset: usize,
    first: ?usize = null,
};

const Origin = struct {
    binding: Binding,
    input: usize,
};

const Slot = struct {
    original: Id,
    target: Id,
    function: Id,
    previous: ?usize,
};

fn indexFunctions(
    a: std.mem.Allocator,
    module: ast.Module,
    original: ir.Program,
    parameters: []const Binding,
    work: *u64,
) Error![]Function {
    if (module.functions.len != original.functions.len) return error.InvalidCorrespondence;
    try spend(work, module.functions.len);
    const functions = try a.alloc(Function, module.functions.len);
    errdefer a.free(functions);
    var offset: usize = 0;
    for (module.functions, functions) |definition, *function| {
        function.* = .{ .offset = offset };
        offset = std.math.add(usize, offset, definition.parameters.len) catch
            return error.InvalidCorrespondence;
    }
    if (offset != parameters.len) return error.InvalidCorrespondence;
    return functions;
}

fn origin(
    module: ast.Module,
    parameters: []const Binding,
    functions: []const Function,
    original: ir.Program,
    role: Formal,
) Error!Origin {
    if (role.function >= functions.len) return error.InvalidCorrespondence;
    const id: usize = @intCast(role.function);
    const formal = module.functions[id].parameters;
    if (role.ordinal >= formal.len) return error.InvalidCorrespondence;
    const variable = formal[role.ordinal];
    if (variable >= module.variables.len) return error.InvalidCorrespondence;
    const binding = parameters[functions[id].offset + role.ordinal];
    const function = original.functions[id];
    if (formal.len > function.inputs.len) return error.InvalidCorrespondence;
    const input = function.inputs.len - formal.len + role.ordinal;
    if (binding.source_function != id or binding.function != id or binding.variable != variable or
        binding.source_schema != module.variables[@intCast(variable)] or
        binding.schema != binding.source_schema or binding.slot != function.inputs[input] or
        binding.slot >= function.layout.slots.len or
        function.layout.slots[@intCast(binding.slot)] != binding.schema)
        return error.InvalidCorrespondence;
    return .{ .binding = binding, .input = input };
}

fn lookup(map: []const Id, id: Id) Error!Id {
    if (id >= map.len) return error.InvalidCorrespondence;
    return map[@intCast(id)];
}

fn mapped(map: ?Map, comptime kind: data.relocation.Kind, id: Id) Error!Id {
    return if (map) |m| lookup(m.maps[@backingInt(kind)], id) else id;
}

pub fn validate(
    a: std.mem.Allocator,
    module: ast.Module,
    parameters: []const Binding,
    formals: []const Formal,
    original: ir.Program,
    before: *const Facts,
    candidate: ir.Program,
    after: *const Facts,
    correspondence: ?Map,
    work: *u64,
) Error!void {
    var selected = try normalize(a, module, formals, work);
    defer selected.deinit();
    return validateDistinct(
        a,
        module,
        parameters,
        selected.formals(),
        original,
        before,
        candidate,
        after,
        correspondence,
        work,
    );
}

pub fn validateDistinct(
    a: std.mem.Allocator,
    module: ast.Module,
    parameters: []const Binding,
    formals: []const Formal,
    original: ir.Program,
    before: *const Facts,
    candidate: ir.Program,
    after: *const Facts,
    correspondence: ?Map,
    work: *u64,
) Error!void {
    try spend(work, 1);
    if (formals.len == 0) return;
    const functions = try indexFunctions(a, module, original, parameters, work);
    defer a.free(functions);
    try spend(work, formals.len);
    const slots = try a.alloc(Slot, formals.len);
    defer a.free(slots);
    for (formals, slots, 0..) |role, *slot, index| {
        const source = try origin(module, parameters, functions, original, role);
        const next = if (correspondence) |m| (try source.binding.relocated(m)) orelse
            continue else source.binding;
        if (next.function >= candidate.functions.len) return error.InvalidCorrespondence;
        const target = candidate.functions[@intCast(next.function)];
        if (source.input >= target.inputs.len or target.inputs[source.input] != next.slot or
            next.slot >= target.layout.slots.len or
            target.layout.slots[@intCast(next.slot)] != next.schema)
            return error.InvalidCorrespondence;
        const function = &functions[@intCast(role.function)];
        slot.* = .{
            .original = source.binding.slot,
            .target = next.slot,
            .function = next.function,
            .previous = function.first,
        };
        function.first = index;
    }
    try spend(work, original.blocks.len);
    for (original.blocks, 0..) |block, id| {
        const first = functions[@intCast(block.function)].first orelse continue;
        const next = try mapped(correspondence, .block, id);
        if (next == missing and before.positions[id].len == 0) continue;
        if (next >= candidate.blocks.len) return error.InvalidCorrespondence;
        const target = candidate.blocks[@intCast(next)];
        if (target.function != slots[first].function or
            target.instructions.len != block.instructions.len or
            std.meta.activeTag(target.terminator) != std.meta.activeTag(block.terminator))
            return error.InvalidCorrespondence;
        var current: ?usize = first;
        while (current) |i| {
            try spend(work, 1);
            const slot = slots[i];
            try positions(before, id, slot.original, after, @intCast(next), slot.target, work);
            if (before.positions[id].len != 0)
                try caller(before, block, slot.original, after, target, slot.target, work);
            current = slot.previous;
        }
    }
}

fn positions(
    before: *const Facts,
    id: usize,
    slot: Id,
    after: *const Facts,
    next: usize,
    target: Id,
    work: *u64,
) Error!void {
    const states = before.positions[id];
    const candidates = after.positions[next];
    if (states.len != candidates.len) return error.InvalidCorrespondence;
    try spend(work, states.len);
    for (states, candidates, before.live[id], after.live[next]) |state, candidate, live, now| {
        const needed = before.pool.contains(live, slot);
        const present = before.pool.contains(state.available, slot);
        if (needed != after.pool.contains(now, target) or
            present != after.pool.contains(candidate.available, target))
            return error.RecoveryLiveness;
    }
}

fn caller(
    before: *const Facts,
    block: ir.Block,
    slot: Id,
    after: *const Facts,
    target: ir.Block,
    target_slot: Id,
    work: *u64,
) Error!void {
    const edge = data.state_admission.next(block.terminator) orelse return;
    const candidate = data.state_admission.next(target.terminator) orelse
        return error.InvalidCorrespondence;
    if ((try retained(before, edge, slot, work)) !=
        (try retained(after, candidate, target_slot, work))) return error.RecoveryLiveness;
}

fn retained(facts: *const Facts, edge: ir.Edge, slot: Id, work: *u64) Error!bool {
    const positions_live = facts.live[@intCast(edge.block)];
    if (positions_live.len == 0) return error.InvalidCorrespondence;
    const live = positions_live[0];
    var unchanged = facts.pool.contains(live, slot);
    var transferred = false;
    try spend(work, edge.assignments.len);
    for (edge.assignments) |assignment| {
        if (assignment.destination == slot) unchanged = false;
        if (assignment.source == .slot and assignment.source.slot == slot and
            facts.pool.contains(live, assignment.destination)) transferred = true;
    }
    return unchanged or transferred;
}

const Pair = struct { forward: Id = missing, reverse: Id = missing };

const Bijection = struct {
    pairs: []Pair,

    fn init(a: std.mem.Allocator, count: usize, work: *u64) Error!Bijection {
        try spend(work, count);
        const pairs = try a.alloc(Pair, count);
        @memset(pairs, .{});
        return .{ .pairs = pairs };
    }

    fn bind(self: Bijection, old: Id, new: Id) Error!void {
        if (old >= self.pairs.len or new >= self.pairs.len) return error.InvalidCorrespondence;
        const forward = &self.pairs[@intCast(old)].forward;
        const reverse = &self.pairs[@intCast(new)].reverse;
        if ((forward.* != missing and forward.* != new) or
            (reverse.* != missing and reverse.* != old)) return error.RecoveryLiveness;
        forward.* = new;
        reverse.* = old;
    }

    fn matches(self: Bijection, old: Id, new: Id) Error!bool {
        if ((old != missing and old >= self.pairs.len) or
            (new != missing and new >= self.pairs.len)) return error.InvalidCorrespondence;
        const forward = if (old == missing) missing else self.pairs[@intCast(old)].forward;
        const reverse = if (new == missing) missing else self.pairs[@intCast(new)].reverse;
        if (forward == missing and reverse == missing) return false;
        if (forward != new or reverse != old) return error.RecoveryLiveness;
        return true;
    }
};

const Protected = struct { old: Id, new: Id, previous: ?usize };

const AliasClass = struct {
    head: ?usize = null,
    origin: usize = 0,
    slots: ?Bijection = null,

    fn member(
        self: *AliasClass,
        a: std.mem.Allocator,
        protected: []const Protected,
        baseline: Map,
        candidate: Map,
        id: usize,
        work: *u64,
    ) Error!void {
        if (id == self.origin) return;
        if (self.slots == null) {
            const slots = try Bijection.init(a, baseline.locals[self.origin].slots.len, work);
            var index = self.head;
            while (index) |i| {
                try spend(work, 1);
                try slots.bind(protected[i].old, protected[i].new);
                index = protected[i].previous;
            }
            try checkSlots(slots, baseline, candidate, self.origin, work);
            self.slots = slots;
        }
        try checkSlots(self.slots.?, baseline, candidate, id, work);
    }

    fn checkSlots(
        slots: Bijection,
        baseline: Map,
        candidate: Map,
        id: usize,
        work: *u64,
    ) Error!void {
        const old = baseline.locals[id].slots;
        const new = candidate.locals[id].slots;
        if (old.len != slots.pairs.len or old.len != new.len) return error.InvalidCorrespondence;
        try spend(work, old.len);
        for (old, new) |from, to| _ = try slots.matches(from, to);
    }
};

pub fn validateAliases(
    a: std.mem.Allocator,
    module: ast.Module,
    parameters: []const Binding,
    formals: []const Formal,
    original: ir.Program,
    baseline: Map,
    candidate: Map,
    work: *u64,
) Error!void {
    var selected = try normalize(a, module, formals, work);
    defer selected.deinit();
    return validateDistinctAliases(
        a,
        module,
        parameters,
        selected.formals(),
        original,
        baseline,
        candidate,
        work,
    );
}

pub fn validateDistinctAliases(
    a: std.mem.Allocator,
    module: ast.Module,
    parameters: []const Binding,
    formals: []const Formal,
    original: ir.Program,
    baseline: Map,
    candidate: Map,
    work: *u64,
) Error!void {
    try spend(work, 1);
    if (formals.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const functions = try indexFunctions(scratch, module, original, parameters, work);
    const before = baseline.maps[@backingInt(data.relocation.Kind.function)];
    const after = candidate.maps[@backingInt(data.relocation.Kind.function)];
    if (before.len != functions.len or after.len != functions.len or
        baseline.locals.len != functions.len or candidate.locals.len != functions.len)
        return error.InvalidCorrespondence;
    const labels = try Bijection.init(scratch, functions.len, work);
    try spend(work, functions.len);
    const classes = try scratch.alloc(AliasClass, functions.len);
    @memset(classes, .{});
    try spend(work, formals.len);
    const protected = try scratch.alloc(Protected, formals.len);
    for (formals, protected, 0..) |role, *slots, index| {
        const bound = (try origin(module, parameters, functions, original, role)).binding;
        const id: usize = @intCast(bound.function);
        const old = before[id];
        const new = after[id];
        if ((old == missing) != (new == missing)) return error.RecoveryLiveness;
        if (old == missing) continue;
        try labels.bind(old, new);
        const class = &classes[@intCast(old)];
        if (class.head == null) class.origin = id;
        slots.* = .{
            .old = try lookup(baseline.locals[id].slots, bound.slot),
            .new = try lookup(candidate.locals[id].slots, bound.slot),
            .previous = class.head,
        };
        class.head = index;
    }
    try spend(work, functions.len);
    var shared = false;
    for (before, after, 0..) |old, new, id| {
        if (!try labels.matches(old, new)) continue;
        const class = &classes[@intCast(old)];
        try class.member(scratch, protected, baseline, candidate, id, work);
        shared = shared or class.slots != null;
    }
    if (shared) try blockAliases(
        scratch,
        original.blocks,
        before,
        classes,
        baseline,
        candidate,
        work,
    );
}

fn blockAliases(
    a: std.mem.Allocator,
    blocks: []const ir.Block,
    functions: []const Id,
    classes: []const AliasClass,
    baseline: Map,
    candidate: Map,
    work: *u64,
) Error!void {
    const before = baseline.maps[@backingInt(data.relocation.Kind.block)];
    const after = candidate.maps[@backingInt(data.relocation.Kind.block)];
    if (before.len != blocks.len or after.len != blocks.len) return error.InvalidCorrespondence;
    const labels = try Bijection.init(a, blocks.len, work);
    try spend(work, blocks.len);
    for (blocks, before, after) |block, old, new| {
        const class = functions[@intCast(block.function)];
        if (class == missing or classes[@intCast(class)].slots == null) continue;
        if ((old == missing) != (new == missing)) return error.RecoveryLiveness;
        if (old != missing) try labels.bind(old, new);
    }
}
