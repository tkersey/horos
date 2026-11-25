// Copyright (c) 2026 Boundary contributors. MIT license.
//! Closed-record opportunities, separate from materialization and acceptance.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const graph = @import("coalescing_graph.zig");
const view = @import("coalescing_view.zig");
const Blocks = @import("coalescing_locals.zig").Blocks;
const w = @import("coalescing_witness.zig");
const record = @import("record.zig");
pub const Error = view.Error || w.Error;
pub const Profile = @FieldType(w.Witness, "profile");
pub const Analysis = struct {
    descriptions: r.Maps,
    nodes: []const graph.Node,
    functions: []const view.View,
};

/// Inputs are the established admitted live baseline. Results and partial
/// allocations are scratch-arena owned. No equivalence verdict grants admission.
pub fn analyze(a: std.mem.Allocator, program: ir.Program, work: *graph.Work) Error!Analysis {
    const fixed = try descriptionClasses(a, program, work);
    const descriptors = std.math.add(
        usize,
        program.constructors.len,
        program.handlers.len,
    ) catch return error.InvalidLength;
    const total = std.math.add(usize, program.functions.len, descriptors) catch
        return error.InvalidLength;
    const nodes = try a.alloc(graph.Node, total);
    const functions = try a.alloc(view.View, program.functions.len);
    const block_names = try Blocks.index(a, program.blocks.len, work);
    for (functions, 0..) |*function, id| {
        function.* = try view.functionWithBlocks(a, program, id, fixed, work, block_names);
        nodes[id] = function.node;
    }
    for (program.constructors, 0..) |_, id|
        nodes[program.functions.len + id] =
            try view.descriptor(a, program, .constructor, id, fixed, work);
    for (program.handlers, 0..) |_, id|
        nodes[program.functions.len + program.constructors.len + id] =
            try view.descriptor(a, program, .handler, id, fixed, work);
    if (program.roots.entry >= program.functions.len) return error.InvalidReference;
    nodes[@intCast(program.roots.entry)].pinned = true;
    for (program.scopes.resources) |resource|
        for ([_][]const p.Id{ resource.introducers, resource.eliminators }) |authorities|
            for (authorities) |id| {
                try work.chargeBounded(1);
                if (id >= program.functions.len) return error.InvalidReference;
                nodes[@intCast(id)].pinned = true;
            };
    return .{ .descriptions = fixed, .nodes = nodes, .functions = functions };
}

fn encoded(a: std.mem.Allocator, value: anytype, work: *graph.Work) Error![]const u8 {
    var measured: @import("wire.zig").Writer = .{ .remaining = work.remaining };
    try record.write(@TypeOf(value), value, &measured);
    try work.charge(measured.position);
    const bytes = try a.alloc(u8, measured.position);
    var writer: @import("wire.zig").Writer = .{ .output = bytes };
    try record.write(@TypeOf(value), value, &writer);
    return bytes;
}

fn descriptionClasses(a: std.mem.Allocator, program: ir.Program, work: *graph.Work) Error!r.Maps {
    var maps = try r.identityMapsWithWork(a, try r.sizes(program), work.remaining);
    const schemas = try @import("schema_partition.zig").computeWithWork(a, program, work.remaining);
    maps[@backingInt(r.Kind.schema)] = try firstRepresentatives(a, schemas, work);
    const mapper: r.Mapper = .{ .allocator = a, .maps = maps, .work = work.remaining };
    const total = std.math.add(
        usize,
        program.constants.len,
        program.scopes.captures.len,
    ) catch return error.InvalidLength;
    const nodes = try a.alloc(graph.Node, total);
    for (program.constants, 0..) |value, id| nodes[id] = .{
        .kind = .constant,
        .label = try encoded(a, try mapper.literal(value), work),
    };
    for (program.scopes.captures, 0..) |value, id| nodes[program.constants.len + id] = .{
        .kind = .capture,
        .label = try encoded(a, try mapper.capture(value), work),
    };
    const classes = try graph.discover(a, nodes, &.{}, work);
    maps[@backingInt(r.Kind.constant)] = try extract(a, classes, 0, program.constants.len, work);
    maps[@backingInt(r.Kind.capture)] =
        try extract(a, classes, program.constants.len, program.scopes.captures.len, work);
    return maps;
}

fn firstRepresentatives(
    a: std.mem.Allocator,
    classes: []const p.Id,
    work: *graph.Work,
) Error![]const p.Id {
    try work.chargeBounded(classes.len);
    const first = try a.alloc(p.Id, classes.len);
    @memset(first, r.missing);
    const result = try a.alloc(p.Id, classes.len);
    try work.chargeBounded(classes.len);
    for (classes, result, 0..) |class, *target, id| {
        if (class >= first.len) return error.InvalidReference;
        if (first[@intCast(class)] == r.missing) first[@intCast(class)] = id;
        target.* = first[@intCast(class)];
    }
    return result;
}

fn extract(
    a: std.mem.Allocator,
    classes: []const usize,
    offset: usize,
    count: usize,
    work: *graph.Work,
) Error![]const p.Id {
    try work.chargeBounded(count);
    const result = try a.alloc(p.Id, count);
    for (classes[offset..][0..count], result) |class, *target| {
        if (class < offset or class - offset >= count) return error.InvalidReference;
        target.* = class - offset;
    }
    return result;
}

/// Discover a stable restricted/full relation, then compose the total local maps.
pub fn correspondence(
    a: std.mem.Allocator,
    program: ir.Program,
    analysis: Analysis,
    profile: Profile,
    work: *graph.Work,
) Error!w.Witness {
    try work.chargeBounded(analysis.nodes.len);
    const singletons = try a.alloc(bool, analysis.nodes.len);
    @memset(singletons, false);
    if (profile == .descriptions) {
        try work.chargeBounded(program.functions.len);
        @memset(singletons[0..program.functions.len], true);
    }
    const classes = try graph.discover(a, analysis.nodes, singletons, work);
    var reps = analysis.descriptions;
    reps[@backingInt(r.Kind.function)] = try extract(a, classes, 0, program.functions.len, work);
    reps[@backingInt(r.Kind.constructor)] =
        try extract(a, classes, program.functions.len, program.constructors.len, work);
    reps[@backingInt(r.Kind.handler)] = try extract(
        a,
        classes,
        program.functions.len + program.constructors.len,
        program.handlers.len,
        work,
    );
    try work.chargeBounded(program.blocks.len);
    const blocks = try a.alloc(p.Id, program.blocks.len);
    @memset(blocks, r.missing);
    const locals = try a.alloc(w.Local, program.functions.len);
    const function_reps = reps[@backingInt(r.Kind.function)];
    for (analysis.functions, locals, function_reps) |function, *local, representative| {
        const target = analysis.functions[@intCast(representative)];
        if (function.blocks.len != target.blocks.len) return error.InvalidCorrespondence;
        try work.chargeBounded(function.blocks.len);
        for (function.blocks, target.blocks) |old, new| blocks[@intCast(old)] = new;
        local.* = .{
            .slots = try localMap(a, function.slots, target.slots, work),
            .custody = try localMap(a, function.custody, target.custody, work),
        };
    }
    try work.chargeBounded(blocks.len);
    for (blocks) |block| if (block == r.missing) return error.InvalidCorrespondence;
    reps[@backingInt(r.Kind.block)] = blocks;
    var final: r.Maps = undefined;
    for (reps, &final) |map, *dense| dense.* = try denseMap(a, map, work);
    return .{ .profile = profile, .representatives = reps, .final = final, .locals = locals };
}

fn localMap(
    a: std.mem.Allocator,
    from: []const p.Id,
    to: []const p.Id,
    work: *graph.Work,
) Error![]const p.Id {
    if (from.len != to.len) return error.InvalidCorrespondence;
    try work.chargeBounded(to.len);
    const inverse = try a.alloc(p.Id, to.len);
    @memset(inverse, r.missing);
    try work.chargeBounded(to.len);
    for (to, 0..) |canonical, old| {
        if (canonical >= to.len or inverse[@intCast(canonical)] != r.missing)
            return error.InvalidCorrespondence;
        inverse[@intCast(canonical)] = old;
    }
    try work.chargeBounded(from.len);
    const result = try a.alloc(p.Id, from.len);
    for (from, result) |canonical, *target| {
        if (canonical >= from.len) return error.InvalidCorrespondence;
        target.* = inverse[@intCast(canonical)];
    }
    return result;
}

fn denseMap(
    a: std.mem.Allocator,
    representatives: []const p.Id,
    work: *graph.Work,
) Error![]const p.Id {
    try work.chargeBounded(representatives.len);
    const map = try a.alloc(p.Id, representatives.len);
    @memset(map, r.missing);
    var next: p.Id = 0;
    try work.chargeBounded(representatives.len);
    for (representatives, 0..) |representative, id| if (representative == id) {
        map[id] = next;
        next += 1;
    };
    try work.chargeBounded(representatives.len);
    for (representatives, 0..) |representative, id| {
        if (representative >= map.len) return error.InvalidCorrespondence;
        if (representatives[@intCast(representative)] != representative)
            return error.InvalidCorrespondence;
        map[id] = map[@intCast(representative)];
    }
    return map;
}
