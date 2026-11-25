// Copyright (c) 2026 Boundary contributors. MIT license.
//! Temporary quotient correspondence. Domain checks are necessary, not a proof
//! of record equivalence: callers must independently compare actual raw records.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const spend = @import("admission.zig").spend;
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
    return checkDomainsWithWork(allocator, original, candidate, witness, null);
}

pub fn checkDomainsWithWork(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
    work: ?*u64,
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
            work,
        );
    }
    try checkPins(a, original, witness, work);
    if (witness.locals.len != original.functions.len) return error.InvalidCorrespondence;
    try spend(work, original.functions.len);
    for (original.functions, witness.locals, 0..) |function, local, id| {
        const target = candidate.functions[@intCast(witness.final[kindIndex(.function)][id])];
        try checkBijection(
            a,
            local.slots,
            function.layout.slots.len,
            target.layout.slots.len,
            work,
        );
        try checkBijection(a, local.custody, function.custody.len, target.custody.len, work);
        const representative = witness.representatives[kindIndex(.function)][id];
        if (witness.profile == .descriptions and representative != id)
            return error.InvalidCorrespondence;
        if (representative == id) {
            try spend(work, local.slots.len);
            try spend(work, local.custody.len);
            for (local.slots, 0..) |slot, position|
                if (slot != position) return error.InvalidCorrespondence;
            for (local.custody, 0..) |scope, position|
                if (scope != position) return error.InvalidCorrespondence;
        }
    }
    try checkBlockBijections(a, original, candidate, witness, work);
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
    work: ?*u64,
) Error!void {
    if (representatives.len != count or final.len != count or output_count > count)
        return error.InvalidCorrespondence;
    try spend(work, count);
    try spend(work, output_count);
    try spend(work, output_count);
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

fn checkPins(
    a: std.mem.Allocator,
    original: ir.Program,
    witness: Witness,
    work: ?*u64,
) Error!void {
    try spend(work, original.functions.len);
    try spend(work, original.functions.len);
    try spend(work, original.scopes.resources.len);
    const pins = try a.alloc(bool, original.functions.len);
    @memset(pins, false);
    if (original.roots.entry >= pins.len) return error.InvalidCorrespondence;
    pins[@intCast(original.roots.entry)] = true;
    for (original.scopes.resources) |resource| {
        for ([_][]const p.Id{ resource.introducers, resource.eliminators }) |authorities| {
            try spend(work, authorities.len);
            for (authorities) |id| {
                if (id >= pins.len) return error.InvalidCorrespondence;
                pins[@intCast(id)] = true;
            }
        }
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
    work: ?*u64,
) Error!void {
    if (map.len != before or before != after) return error.InvalidCorrespondence;
    try spend(work, after);
    try spend(work, map.len);
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
    work: ?*u64,
) Error!void {
    const mapped_functions = witness.final[kindIndex(.function)];
    const mapped_blocks = witness.final[kindIndex(.block)];
    try spend(work, candidate.functions.len);
    try spend(work, candidate.blocks.len);
    const counts = try a.alloc(usize, candidate.functions.len);
    @memset(counts, 0);
    for (candidate.blocks) |block| {
        if (block.function >= counts.len) return error.InvalidCorrespondence;
        counts[@intCast(block.function)] += 1;
    }
    try spend(work, original.functions.len);
    try spend(work, original.blocks.len);
    const heads = try a.alloc(p.Id, original.functions.len);
    const links = try a.alloc(p.Id, original.blocks.len);
    @memset(heads, relocation.missing);
    for (original.blocks, links, 0..) |block, *link, index| {
        if (block.function >= heads.len) return error.InvalidCorrespondence;
        const head = &heads[@intCast(block.function)];
        link.* = head.*;
        head.* = index;
    }
    try spend(work, candidate.blocks.len);
    try spend(work, original.functions.len);
    try spend(work, original.blocks.len);
    const owners = try a.alloc(p.Id, candidate.blocks.len);
    @memset(owners, relocation.missing);
    for (heads, mapped_functions, 0..) |head, target, function| {
        var before: usize = 0;
        var index = head;
        while (index != relocation.missing) : (index = links[@intCast(index)]) {
            const block: usize = @intCast(mapped_blocks[@intCast(index)]);
            if (candidate.blocks[block].function != target or owners[block] == function)
                return error.InvalidCorrespondence;
            owners[block] = function;
            before += 1;
        }
        if (before != counts[@intCast(target)]) return error.InvalidCorrespondence;
    }
}
