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
    return materialize(allocator, scratch, original, correspondence, trace, diagnostic);
}

pub fn materialize(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
    proposed: witness.Witness,
    trace: ?*const origins.Trace,
    diagnostic: ?*origins.Diagnostic,
) Error!Candidate {
    var correspondence = proposed;
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    const rewritten = try r.ownQuotient(
        temporary.allocator(),
        scratch,
        original,
        correspondence.representatives,
        correspondence.final,
    );
    // This check precedes cleanup: projection cannot conceal a faulty rewrite.
    try checkTransformation(allocator, original, rewritten, correspondence, trace, diagnostic);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const projected = try r.ownReachable(arena.allocator(), scratch, rewritten);
    var composed: r.Maps = undefined;
    for (correspondence.final, &composed, 0..) |map, *result, kind| {
        const values = try scratch.alloc(p.Id, map.len);
        for (
            map,
            values,
        ) |old, *target| target.* = try projected.mapped(@fromBackingInt(@intCast(kind)), old);
        result.* = values;
    }
    correspondence.final = composed;
    try checkTransformation(
        allocator,
        original,
        projected.program,
        correspondence,
        trace,
        diagnostic,
    );
    if (diagnostic) |d| d.* = .{ .stage = .candidate };
    var flow = admission.analyzeDiagnosed(
        allocator,
        projected.program,
        if (diagnostic) |d| &d.target else null,
    ) catch |err| {
        if (diagnostic) |d| if (trace) |t| t.explain(correspondence, d);
        return err;
    };
    errdefer flow.deinit();
    if (diagnostic) |d| d.* = .{ .stage = .cost };
    return .{
        .arena = arena,
        .program = projected.program,
        .flow = flow,
        .bytes = try image.encodedLength(projected.program),
        .entries = try count(projected.program),
        .correspondence = correspondence,
    };
}

fn checkTransformation(
    allocator: std.mem.Allocator,
    original: ir.Program,
    result: ir.Program,
    map: witness.Witness,
    trace: ?*const origins.Trace,
    diagnostic: ?*origins.Diagnostic,
) Error!void {
    if (diagnostic) |d| d.* = .{ .stage = .transformation };
    validation.validateDiagnosed(
        allocator,
        original,
        result,
        map,
        if (diagnostic) |d| &d.target else null,
    ) catch |err| {
        if (diagnostic) |d| if (trace) |t| t.explain(null, d);
        return err;
    };
    if (diagnostic) |d| d.* = .{ .stage = .mapping };
}
