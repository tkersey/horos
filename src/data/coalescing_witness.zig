// Copyright (c) 2026 Boundary contributors. MIT license.
//! Temporary quotient correspondence. Domain checks are necessary, not a proof
//! of record equivalence: callers must independently compare actual raw records.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const relocation = @import("relocation.zig");
pub const Error = relocation.Error || error{InvalidCorrespondence};
pub const Local = struct {
    /// Original local IDs -> actual candidate local IDs. Both are bijections.
    slots: []const p.Id,
    custody: []const p.Id,
};
pub const Witness = struct {
    profile: enum { full, descriptions } = .full,
    /// Original ID -> original representative. Idempotent, not a chain.
    representatives: relocation.Maps,
    /// Original ID -> actual candidate ID, including final projection.
    final: relocation.Maps,
    locals: []const Local,
};

/// Validate only the domains, representative discipline, nominal injectivity,
/// authority pins and total local bijections. Does not validate record fields.
/// Scratch is freed before return; inputs are never mutated or retained.
pub fn checkDomains(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
) Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const before = try relocation.sizes(original);
    const after = try relocation.sizes(candidate);
    for (witness.representatives, witness.final, 0..) |representatives, final, kind| {
        try checkCatalog(
            a,
            representatives,
            final,
            before[kind],
            after[kind],
            @fromBackingInt(@intCast(kind)),
        );
    }
    try checkPins(a, original, witness);
    if (witness.locals.len != original.functions.len) return error.InvalidCorrespondence;
    for (original.functions, witness.locals, 0..) |function, local, id| {
        const target = candidate.functions[@intCast(witness.final[kindIndex(.function)][id])];
        try checkBijection(a, local.slots, function.layout.slots.len, target.layout.slots.len);
        try checkBijection(a, local.custody, function.custody.len, target.custody.len);
        const representative = witness.representatives[kindIndex(.function)][id];
        if (witness.profile == .descriptions and representative != id)
            return error.InvalidCorrespondence;
        if (representative == id) {
            for (local.slots, 0..) |slot, position|
                if (slot != position) return error.InvalidCorrespondence;
            for (local.custody, 0..) |scope, position|
                if (scope != position) return error.InvalidCorrespondence;
        }
    }
    try checkBlockBijections(a, original, candidate, witness);
}

fn kindIndex(kind: relocation.Kind) usize {
    return @backingInt(kind);
}

fn checkCatalog(
    a: std.mem.Allocator,
    representatives: []const p.Id,
    final: []const p.Id,
    count: usize,
    output_count: usize,
    kind: relocation.Kind,
) Error!void {
    if (representatives.len != count or final.len != count or output_count > count)
        return error.InvalidCorrespondence;
    const owners = try a.alloc(p.Id, output_count);
    @memset(owners, relocation.missing);
    for (representatives, final, 0..) |representative, target, id| {
        if (representative >= count or target >= output_count)
            return error.InvalidCorrespondence;
        if (representatives[@intCast(representative)] != representative or
            final[@intCast(representative)] != target) return error.InvalidCorrespondence;
        // Blocks follow whole-function local correspondences, not independent
        // minimum-block selection. Other structural classes choose their first ID.
        if (kind != .block and representative > id) return error.InvalidCorrespondence;
        if (kind == .effect or kind == .region or kind == .resource)
            if (representative != id) return error.InvalidCorrespondence;
        const owner = &owners[@intCast(target)];
        if (owner.* != relocation.missing and owner.* != representative)
            return error.InvalidCorrespondence;
        owner.* = representative;
    }
    for (owners) |owner| if (owner == relocation.missing) return error.InvalidCorrespondence;
}

fn checkPins(a: std.mem.Allocator, original: ir.Program, witness: Witness) Error!void {
    const pins = try a.alloc(bool, original.functions.len);
    @memset(pins, false);
    if (original.roots.entry >= pins.len) return error.InvalidCorrespondence;
    pins[@intCast(original.roots.entry)] = true;
    for (original.scopes.resources) |resource| {
        for ([_][]const p.Id{ resource.introducers, resource.eliminators }) |authorities|
            for (authorities) |id| {
                if (id >= pins.len) return error.InvalidCorrespondence;
                pins[@intCast(id)] = true;
            };
    }
    const representatives = witness.representatives[kindIndex(.function)];
    for (representatives, 0..) |representative, id|
        if ((pins[id] or pins[@intCast(representative)]) and representative != id)
            return error.InvalidCorrespondence;
}

fn checkBijection(
    a: std.mem.Allocator,
    map: []const p.Id,
    before: usize,
    after: usize,
) Error!void {
    if (map.len != before or before != after) return error.InvalidCorrespondence;
    const seen = try a.alloc(bool, after);
    @memset(seen, false);
    for (map) |id| {
        if (id >= after or seen[@intCast(id)]) return error.InvalidCorrespondence;
        seen[@intCast(id)] = true;
    }
}

fn checkBlockBijections(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
) Error!void {
    const mapped_functions = witness.final[kindIndex(.function)];
    const mapped_blocks = witness.final[kindIndex(.block)];
    const before = try a.alloc(usize, original.functions.len);
    const after = try a.alloc(usize, candidate.functions.len);
    @memset(before, 0);
    @memset(after, 0);
    for (candidate.blocks) |block| {
        if (block.function >= after.len) return error.InvalidCorrespondence;
        after[@intCast(block.function)] += 1;
    }
    // Pair keys avoid O(functions * blocks) scanning and do not define equality.
    var seen: std.AutoHashMapUnmanaged(struct { function: p.Id, block: p.Id }, void) = .empty;
    for (original.blocks, mapped_blocks) |block, mapped| {
        if (block.function >= before.len) return error.InvalidCorrespondence;
        const function = @as(usize, @intCast(block.function));
        if (candidate.blocks[@intCast(mapped)].function != mapped_functions[function])
            return error.InvalidCorrespondence;
        const pair = try seen.getOrPut(a, .{ .function = block.function, .block = mapped });
        if (pair.found_existing) return error.InvalidCorrespondence;
        before[function] += 1;
    }
    for (before, mapped_functions) |count, function|
        if (count != after[@intCast(function)]) return error.InvalidCorrespondence;
}
