// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independently recheck a composed structural correspondence. Reachability
//! and raw records establish its meaning; optimizer discovery is never rerun.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const origins = @import("coalescing_origins.zig");
const witness = @import("coalescing_witness.zig");
const validation = @import("coalescing_validation.zig");
const admission = @import("activation_ownership.zig");
pub const Error = admission.Error || witness.Error;
pub const Region = struct { original: p.Id, current: p.Id };
pub const Correspondence = struct {
    maps: r.Maps,
    regions: []const Region,
    locals: []const witness.Local,

    pub fn copy(a: std.mem.Allocator, trace: *const origins.Trace) Error!Correspondence {
        var maps: r.Maps = undefined;
        for (trace.maps, &maps) |before, *after| after.* = try a.dupe(p.Id, before);
        const regions = try a.alloc(Region, trace.regions.len);
        for (
            trace.regions,
            regions,
        ) |before, *after| after.* = .{ .original = before.original, .current = before.current };
        const locals = try a.alloc(witness.Local, trace.locals.len);
        for (
            trace.locals,
            locals,
        ) |before, *after| after.* = .{
            .slots = try a.dupe(p.Id, before.slots),
            .custody = try a.dupe(p.Id, before.custody),
        };
        return .{ .maps = maps, .regions = regions, .locals = locals };
    }
};

fn require(ok: bool) Error!void {
    if (!ok) return error.InvalidCorrespondence;
}

pub fn validate(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: Correspondence,
) Error!void {
    var original_facts = try admission.analyze(a, original);
    original_facts.deinit();
    var candidate_facts = try admission.analyze(a, candidate);
    candidate_facts.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const storage = scratch.allocator();
    const live = try r.ownReachable(storage, storage, original);
    const projection = live.maps orelse return error.InvalidCorrespondence;
    const counts = try r.sizes(live.program);
    const targets = try r.sizes(candidate);
    // A quotient cannot contain more classes than its reachable source.
    // Establish this before allocating indexes by a submitted target domain;
    // in particular, a nominal region bound is not a stored-record count.
    for (counts, targets) |count, target| try require(target <= count);
    const projected_maps = try projectMaps(storage, live, projection, map, counts, targets);
    const final = projected_maps.final;
    var representatives = projected_maps.representatives;
    try require(map.locals.len == original.functions.len);
    const locals = try storage.alloc(witness.Local, live.program.functions.len);
    for (live.function_origins, locals) |origin, *local| local.* = map.locals[@intCast(origin)];
    try blockRepresentatives(storage, live.program, candidate, final, &representatives);
    try validation.validate(
        a,
        live.program,
        candidate,
        .{ .representatives = representatives, .final = final, .locals = locals },
    );
}

fn blockRepresentatives(
    storage: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    final: r.Maps,
    representatives: *r.Maps,
) Error!void {
    // Blocks are owned by whole functions. Select the representative's block
    // rather than assuming arbitrary input block order follows function order.
    const block_kind = @backingInt(r.Kind.block);
    const function_kind = @backingInt(r.Kind.function);
    const block_reps = try storage.alloc(p.Id, original.blocks.len);
    const block_owners = try storage.alloc(p.Id, candidate.blocks.len);
    @memset(block_owners, r.missing);
    for (original.blocks, final[block_kind], 0..) |block, target, id| {
        if (representatives[function_kind][@intCast(block.function)] == block.function) {
            try require(block_owners[@intCast(target)] == r.missing);
            block_owners[@intCast(target)] = id;
        }
    }
    for (final[block_kind], block_reps) |target, *rep| {
        rep.* = block_owners[@intCast(target)];
        try require(rep.* != r.missing);
    }
    representatives[block_kind] = block_reps;
}

const ProjectedMaps = struct { final: r.Maps, representatives: r.Maps };
fn projectMaps(
    storage: std.mem.Allocator,
    live: r.Projection,
    projection: r.Maps,
    map: Correspondence,
    counts: [r.kind_count]usize,
    targets: [r.kind_count]usize,
) Error!ProjectedMaps {
    var final: r.Maps = undefined;
    var representatives: r.Maps = undefined;
    for (projection, map.maps, 0..) |projected, submitted, kind| {
        try require(projected.len == submitted.len);
        const mapped = try storage.alloc(p.Id, counts[kind]);
        @memset(mapped, r.missing);
        if (kind == @backingInt(r.Kind.region)) {
            try require(map.regions.len == live.regions.count());
            for (map.regions) |region| {
                const index = live.regions.get(
                    region.original,
                ) orelse return error.InvalidCorrespondence;
                try require(index < mapped.len and region.current < targets[kind]);
                try require(mapped[@intCast(index)] == r.missing);
                mapped[@intCast(index)] = region.current;
            }
        } else for (projected, submitted) |index, target| {
            if (index == r.missing) {
                try require(target == r.missing);
                continue;
            }
            try require(index < mapped.len and target < targets[kind]);
            mapped[@intCast(index)] = target;
        }
        const owners = try storage.alloc(p.Id, targets[kind]);
        @memset(owners, r.missing);
        const reps = try storage.alloc(p.Id, mapped.len);
        for (mapped, reps, 0..) |target, *rep, id| {
            try require(target < owners.len);
            const owner = &owners[@intCast(target)];
            if (owner.* == r.missing) owner.* = id;
            rep.* = owner.*;
        }
        for (owners) |owner| try require(owner != r.missing);
        final[kind] = mapped;
        representatives[kind] = reps;
    }
    return .{ .final = final, .representatives = representatives };
}
