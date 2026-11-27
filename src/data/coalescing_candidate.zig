// Copyright (c) 2026 Boundary contributors. MIT license.
//! Materialize, independently validate, project, admit, and size one candidate.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const r = @import("relocation.zig");
const discovery = @import("coalescing_discovery.zig");
const graph = @import("coalescing_graph.zig");
const validation = @import("coalescing_validation.zig");
const witness = @import("coalescing_witness.zig");
const admission = @import("activation_ownership.zig");
const image = @import("program_image.zig");
const origins = @import("coalescing_origins.zig");
pub const Error = discovery.Error || admission.Error || image.Error;
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    flow: @import("activation_flow.zig").Facts,
    bytes: usize,
    entries: usize,
    /// Borrows the caller's scratch only; never retained in a published owner.
    correspondence: witness.Witness,

    pub fn deinit(self: *Candidate) void {
        self.flow.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn count(program: ir.Program) Error!usize {
    var total: usize = 0;
    for (try r.sizes(program)) |size|
        total = std.math.add(usize, total, size) catch return error.InvalidLength;
    return total;
}

/// The caller has admitted and projected the original baseline. Candidate errors
/// are defects/errors, never evidence for choosing a different profile silently.
pub fn build(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
    analysis: discovery.Analysis,
    profile: discovery.Profile,
    work: *graph.Work,
) Error!Candidate {
    return buildObserved(allocator, scratch, original, analysis, profile, work, null, null);
}

pub fn buildObserved(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
    analysis: discovery.Analysis,
    profile: discovery.Profile,
    work: *graph.Work,
    trace: ?*const origins.Trace,
    diagnostic: ?*origins.Diagnostic,
) Error!Candidate {
    if (diagnostic) |d| d.* = .{ .stage = .mapping };
    const correspondence = try discovery.correspondence(scratch, original, analysis, profile, work);
    return materialize(
        allocator,
        scratch,
        original,
        correspondence,
        trace,
        diagnostic,
        work.remaining,
    );
}

pub fn materialize(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
    proposed: witness.Witness,
    trace: ?*const origins.Trace,
    diagnostic: ?*origins.Diagnostic,
    remaining: ?*u64,
) Error!Candidate {
    var correspondence = proposed;
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    const rewritten = try r.ownQuotientWithWork(
        temporary.allocator(),
        scratch,
        original,
        correspondence.representatives,
        correspondence.final,
        remaining,
    );
    // This check precedes cleanup: projection cannot conceal a faulty rewrite.
    try checkTransformation(
        allocator,
        original,
        rewritten,
        correspondence,
        trace,
        diagnostic,
        remaining,
    );
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const projected = try r.ownReachableWithRegionOrder(
        arena.allocator(),
        scratch,
        rewritten,
        remaining,
        .unobserved,
    );
    correspondence.final = try compose(scratch, projected, correspondence.final, remaining);
    try checkTransformation(
        allocator,
        original,
        projected.program,
        correspondence,
        trace,
        diagnostic,
        remaining,
    );
    if (diagnostic) |d| d.* = .{ .stage = .candidate };
    var flow = try candidateFlow(
        allocator,
        projected.program,
        correspondence,
        trace,
        diagnostic,
        remaining,
    );
    errdefer flow.deinit();
    if (diagnostic) |d| d.* = .{ .stage = .cost };
    return .{
        .arena = arena,
        .program = projected.program,
        .flow = flow,
        .bytes = try image.encodedLengthWithWork(.unhinted(projected.program), remaining),
        .entries = try count(projected.program),
        .correspondence = correspondence,
    };
}

fn compose(
    scratch: std.mem.Allocator,
    projected: r.Projection,
    before: r.Maps,
    remaining: ?*u64,
) Error!r.Maps {
    var composed: r.Maps = undefined;
    for (before, &composed, 0..) |map, *result, kind| {
        try @import("admission.zig").spend(remaining, map.len);
        const values = try scratch.alloc(p.Id, map.len);
        for (
            map,
            values,
        ) |old, *target| target.* = try projected.mappedWithWork(
            @fromBackingInt(@intCast(kind)),
            old,
            remaining,
        );
        result.* = values;
    }
    return composed;
}

fn candidateFlow(
    allocator: std.mem.Allocator,
    program: ir.Program,
    correspondence: witness.Witness,
    trace: ?*const origins.Trace,
    diagnostic: ?*origins.Diagnostic,
    remaining: ?*u64,
) Error!@import("activation_flow.zig").Facts {
    return admission.analyzeObservedWithWork(
        allocator,
        program,
        if (diagnostic) |d| &d.target else null,
        null,
        remaining,
    ) catch |err| {
        if (err != error.RelationLimit) if (diagnostic) |d| {
            if (trace) |t| t.explain(correspondence, d);
        };
        return err;
    };
}

fn checkTransformation(
    allocator: std.mem.Allocator,
    original: ir.Program,
    result: ir.Program,
    map: witness.Witness,
    trace: ?*const origins.Trace,
    diagnostic: ?*origins.Diagnostic,
    remaining: ?*u64,
) Error!void {
    if (diagnostic) |d| d.* = .{ .stage = .transformation };
    validation.validateDiagnosedWithWork(
        allocator,
        original,
        result,
        map,
        if (diagnostic) |d| &d.target else null,
        remaining,
    ) catch |err| {
        if (err != error.RelationLimit) if (diagnostic) |d| {
            if (trace) |t| t.explain(null, d);
        };
        return err;
    };
    if (diagnostic) |d| d.* = .{ .stage = .mapping };
}
