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
const spend = @import("admission.zig").spend;
const admission = @import("activation_ownership.zig");
const coalescing = @import("coalescing.zig");
pub const Error = admission.Error || witness.Error;
pub const Region = struct { original: p.Id, current: p.Id };
pub const Correspondence = struct {
    maps: r.Maps,
    regions: []const Region,
    locals: []const witness.Local,

    pub const Reconstruction = Reconstructed;

    pub fn copy(a: std.mem.Allocator, trace: *const origins.Trace) Error!Correspondence {
        return copyWithWork(a, trace, trace.remaining);
    }

    pub fn copyWithWork(
        a: std.mem.Allocator,
        trace: *const origins.Trace,
        work: ?*u64,
    ) Error!Correspondence {
        return copyTrace(a, trace, work, false);
    }

    pub fn copyCanonical(
        a: std.mem.Allocator,
        trace: *const origins.Trace,
        work: *u64,
    ) Error!Correspondence {
        return copyTrace(a, trace, work, true);
    }

    fn copyTrace(
        a: std.mem.Allocator,
        trace: *const origins.Trace,
        work: ?*u64,
        canonical: bool,
    ) Error!Correspondence {
        var maps: r.Maps = undefined;
        var maps_ready: usize = 0;
        errdefer for (maps[0..maps_ready]) |map| a.free(map);
        for (trace.maps, &maps) |before, *after| {
            try spend(work, before.len);
            after.* = try a.dupe(p.Id, before);
            maps_ready += 1;
        }
        try spend(work, trace.regions.len);
        const regions = try a.alloc(Region, trace.regions.len);
        errdefer a.free(regions);
        for (
            trace.regions,
            regions,
        ) |before, *after| after.* = .{ .original = before.original, .current = before.current };
        if (canonical) try sortRegions(regions, work);
        try spend(work, trace.locals.len);
        const locals = try a.alloc(witness.Local, trace.locals.len);
        errdefer a.free(locals);
        var locals_ready: usize = 0;
        errdefer for (locals[0..locals_ready]) |local| {
            a.free(local.slots);
            a.free(local.custody);
        };
        for (trace.locals, locals) |before, *after| {
            try spend(work, before.slots.len);
            try spend(work, before.custody.len);
            const slots = try a.dupe(p.Id, before.slots);
            errdefer a.free(slots);
            after.* = .{ .slots = slots, .custody = try a.dupe(p.Id, before.custody) };
            locals_ready += 1;
        }
        return .{ .maps = maps, .regions = regions, .locals = locals };
    }
};

fn sortRegions(regions: []Region, work: ?*u64) Error!void {
    if (regions.len < 2) return;
    const levels: u64 = @bitSizeOf(usize) - @as(u64, @clz(regions.len));
    const cost = std.math.mul(u64, regions.len, 4 * (levels + 1)) catch return error.RelationLimit;
    try spend(work, cost);
    std.sort.heap(Region, regions, {}, regionLess);
}

fn regionLess(_: void, lhs: Region, rhs: Region) bool {
    return lhs.original < rhs.original;
}

fn require(ok: bool) Error!void {
    if (!ok) return error.InvalidCorrespondence;
}

const Reconstructed = struct {
    final: coalescing.Owned,
    map: Correspondence,

    pub const Submitted = struct { program: ir.Program, map: Correspondence };

    const Capture = struct {
        arena: *std.heap.ArenaAllocator,
        work: *u64,
        map: ?Correspondence = null,

        fn observe(ptr: *anyopaque, trace: *const origins.Trace) coalescing.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.map = try Correspondence.copyCanonical(self.arena.allocator(), trace, self.work);
        }
    };

    pub fn run(
        a: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        original: ir.Program,
        work: *u64,
    ) coalescing.Error!Reconstructed {
        var capture: Capture = .{ .arena = arena, .work = work };
        var final = try coalescing.runWithWork(a, original, .{
            .compact_refinement = true,
            .correspondence = .{ .context = &capture, .receive = Capture.observe },
        }, work);
        errdefer final.deinit();
        return .{ .final = final, .map = capture.map orelse return error.InvalidCorrespondence };
    }

    pub fn checked(
        a: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        original: ir.Program,
        submitted: ?Submitted,
        work: *u64,
    ) coalescing.Error!Reconstructed {
        var result = try run(a, arena, original, work);
        errdefer result.final.deinit();
        try checkRecords(original, result.final.program, result.map, submitted, work);
        try checkMap(a, original, result.final.program, result.map, work);
        return result;
    }
};

fn checkRecords(
    original: ir.Program,
    candidate: ir.Program,
    map: Correspondence,
    submitted: ?Reconstructed.Submitted,
    work: *u64,
) Error!void {
    var records: @import("wire.zig").Writer = .{ .remaining = work };
    const record = @import("record.zig");
    try record.write(ir.Program, original, &records);
    if (submitted) |actual| {
        try require(try record.equalWithWork(ir.Program, candidate, actual.program, work));
        try require(try record.equalWithWork(Correspondence, map, actual.map, work));
    } else {
        try record.write(ir.Program, candidate, &records);
        try record.write(Correspondence, map, &records);
    }
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
    return checkMap(a, original, candidate, map, null);
}

pub fn validateWithFlow(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: Correspondence,
    work: ?*u64,
) Error!@import("activation_flow.zig").Facts {
    if (work) |remaining| try checkRecords(original, candidate, map, null, remaining);
    return checkedFlow(a, original, candidate, map, work);
}

pub fn validateMatchingWithFlow(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: Correspondence,
    submitted_program: ir.Program,
    submitted_map: Correspondence,
    work: *u64,
) Error!@import("activation_flow.zig").Facts {
    try checkRecords(original, candidate, map, .{
        .program = submitted_program,
        .map = submitted_map,
    }, work);
    return checkedFlow(a, original, candidate, map, work);
}

fn checkedFlow(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: Correspondence,
    work: ?*u64,
) Error!@import("activation_flow.zig").Facts {
    var original_facts = try admission.analyzeObservedWithWork(a, original, null, null, work);
    original_facts.deinit();
    var actual = try admission.analyzeObservedWithWork(a, candidate, null, null, work);
    errdefer actual.deinit();
    try checkMap(a, original, candidate, map, work);
    return actual;
}

fn checkMap(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: Correspondence,
    work: ?*u64,
) Error!void {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const storage = scratch.allocator();
    const live = try r.ownReachableWithRegionOrder(storage, storage, original, work, .unobserved);
    const projection = live.maps orelse return error.InvalidCorrespondence;
    const counts = try r.sizes(live.program);
    const targets = try r.sizes(candidate);
    // A quotient cannot contain more classes than its reachable source.
    // Establish this before allocating indexes by a submitted target domain;
    // in particular, a nominal region bound is not a stored-record count.
    for (counts, targets) |count, target| try require(target <= count);
    const projected_maps = try projectMaps(storage, live, projection, map, counts, targets, work);
    const final = projected_maps.final;
    var representatives = projected_maps.representatives;
    try require(map.locals.len == original.functions.len);
    try spend(work, live.program.functions.len);
    const locals = try storage.alloc(witness.Local, live.program.functions.len);
    for (live.function_origins, locals) |origin, *local| local.* = map.locals[@intCast(origin)];
    try blockRepresentatives(storage, live.program, candidate, final, &representatives, work);
    try validation.validateDiagnosedWithWork(
        a,
        live.program,
        candidate,
        .{ .representatives = representatives, .final = final, .locals = locals },
        null,
        work,
    );
}

fn blockRepresentatives(
    storage: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    final: r.Maps,
    representatives: *r.Maps,
    work: ?*u64,
) Error!void {
    // Blocks are owned by whole functions. Select the representative's block
    // rather than assuming arbitrary input block order follows function order.
    const block_kind = @backingInt(r.Kind.block);
    const function_kind = @backingInt(r.Kind.function);
    try spend(work, original.blocks.len);
    try spend(work, original.blocks.len);
    try spend(work, candidate.blocks.len);
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
    work: ?*u64,
) Error!ProjectedMaps {
    var final: r.Maps = undefined;
    var representatives: r.Maps = undefined;
    for (projection, map.maps, 0..) |projected, submitted, kind| {
        try require(projected.len == submitted.len);
        try spend(work, counts[kind]);
        const mapped = try storage.alloc(p.Id, counts[kind]);
        @memset(mapped, r.missing);
        if (kind == @backingInt(r.Kind.region)) {
            try require(map.regions.len == live.regions.count());
            try spend(work, map.regions.len);
            for (map.regions) |region| {
                const index = live.mappedWithWork(.region, region.original, work) catch |err|
                    return if (err == error.InvalidReference) error.InvalidCorrespondence else err;
                try require(index < mapped.len and region.current < targets[kind]);
                try require(mapped[@intCast(index)] == r.missing);
                mapped[@intCast(index)] = region.current;
            }
        } else {
            try spend(work, projected.len);
            for (projected, submitted) |index, target| {
                if (index == r.missing) {
                    try require(target == r.missing);
                    continue;
                }
                try require(index < mapped.len and target < targets[kind]);
                mapped[@intCast(index)] = target;
            }
        }
        try spend(work, targets[kind]);
        try spend(work, mapped.len);
        try spend(work, targets[kind]);
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
