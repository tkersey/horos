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

pub const Formal = struct { function: Id, ordinal: usize };

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

fn continuation(control: ir.Terminator) ?ir.Edge {
    return switch (control) {
        inline .call,
        .perform,
        .apply,
        .handle,
        .resume_value,
        .resume_with,
        .resume_computation,
        .dispose,
        .protect,
        .with_region,
        => |operation| operation.next,
        .branch,
        .return_value,
        .jump,
        .yield_value,
        .fail,
        .switch_variant,
        .unpack_product,
        => null,
    };
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
    const edge = continuation(block.terminator) orelse return;
    const candidate = continuation(target.terminator) orelse return error.InvalidCorrespondence;
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
    try spend(work, 1);
    if (formals.len == 0) return;
    const functions = try indexFunctions(a, module, original, parameters, work);
    defer a.free(functions);
    const before = baseline.maps[@backingInt(data.relocation.Kind.function)];
    const after = candidate.maps[@backingInt(data.relocation.Kind.function)];
    if (before.len != functions.len or after.len != functions.len or
        baseline.locals.len != functions.len or candidate.locals.len != functions.len)
        return error.InvalidCorrespondence;
    try spend(work, formals.len);
    var shared = false;
    for (formals, 0..) |role, index| {
        const bound = (try origin(module, parameters, functions, original, role)).binding;
        const id: usize = @intCast(bound.function);
        if ((before[id] == missing) != (after[id] == missing)) return error.RecoveryLiveness;
        if (before[id] == missing) continue;
        const old_slot = try lookup(baseline.locals[id].slots, bound.slot);
        const new_slot = try lookup(candidate.locals[id].slots, bound.slot);
        try spend(work, functions.len);
        for (before, after, functions, 0..) |old, new, *function, i| {
            if ((old == before[id]) != (new == after[id])) return error.RecoveryLiveness;
            if (old != before[id] or i == id) continue;
            shared = true;
            functions[id].first = index;
            function.first = index;
            const old_slots = baseline.locals[i].slots;
            const new_slots = candidate.locals[i].slots;
            if (old_slots.len != new_slots.len) return error.InvalidCorrespondence;
            try spend(work, old_slots.len);
            for (old_slots, new_slots) |previous, next| {
                if ((previous == old_slot) != (next == new_slot)) return error.RecoveryLiveness;
            }
        }
    }
    if (shared) try blockAliases(a, original.blocks, functions, baseline, candidate, work);
}

fn blockAliases(
    a: std.mem.Allocator,
    blocks: []const ir.Block,
    functions: []const Function,
    baseline: Map,
    candidate: Map,
    work: *u64,
) Error!void {
    const before = baseline.maps[@backingInt(data.relocation.Kind.block)];
    const after = candidate.maps[@backingInt(data.relocation.Kind.block)];
    if (before.len != blocks.len or after.len != blocks.len) return error.InvalidCorrespondence;
    try spend(work, blocks.len);
    const old_to_new = try a.alloc(Id, blocks.len);
    defer a.free(old_to_new);
    try spend(work, blocks.len);
    const new_to_old = try a.alloc(Id, blocks.len);
    defer a.free(new_to_old);
    @memset(old_to_new, missing);
    @memset(new_to_old, missing);
    for (blocks, before, after) |block, old, new| {
        if (functions[@intCast(block.function)].first == null) continue;
        if ((old == missing) != (new == missing)) return error.RecoveryLiveness;
        if (old == missing) continue;
        if (old >= old_to_new.len or new >= new_to_old.len) return error.InvalidCorrespondence;
        const next = &old_to_new[@intCast(old)];
        const previous = &new_to_old[@intCast(new)];
        if ((next.* != missing and next.* != new) or (previous.* != missing and previous.* != old))
            return error.RecoveryLiveness;
        next.* = new;
        previous.* = old;
    }
}
