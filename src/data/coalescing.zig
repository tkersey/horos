// Copyright (c) 2026 Boundary contributors. MIT license.
//! Closed-program coalescing. Compilation/linking owns when this pass is invoked.
const std = @import("std");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const image = @import("program_image.zig");
const admission = @import("activation_ownership.zig");
const spend = @import("admission.zig").spend;
const graph = @import("coalescing_graph.zig");
const discovery = @import("coalescing_discovery.zig");
const candidate = @import("coalescing_candidate.zig");
const origins = @import("coalescing_origins.zig");
pub const Diagnostic = origins.Diagnostic;
pub const OriginsTrace = origins.Trace;
pub const Correspondence = @import("coalescing_correspondence.zig").Correspondence;
pub const validateCorrespondence = @import("coalescing_correspondence.zig").validate;
pub const correspondenceFlow = @import("coalescing_correspondence.zig").validateWithFlow;
pub const matchingCorrespondenceFlow =
    @import("coalescing_correspondence.zig").validateMatchingWithFlow;
pub const Outcome = enum {
    not_run,
    deferred_open_component,
    no_change,
    applied,
    size_guard,
    work_limit,
};
pub const Counts = struct {
    catalogs: [r.kind_count]usize = @splat(0),
    instructions: usize = 0,
    bytes: usize = 0,
    entries: usize = 0,

    pub fn of(program: ir.Program) Error!Counts {
        return measure(program, try image.encodedLength(program), null);
    }

    fn measure(program: ir.Program, bytes: usize, remaining: ?*u64) Error!Counts {
        try spend(remaining, program.blocks.len);
        var result: Counts = .{
            .catalogs = try r.sizes(program),
            .bytes = bytes,
            .entries = try candidate.count(program),
        };
        for (program.blocks) |block|
            result.instructions = std.math.add(
                usize,
                result.instructions,
                block.instructions.len,
            ) catch return error.InvalidLength;
        return result;
    }
};
pub const Statistics = struct {
    /// Optional caller-owned storage. Short storage reports a truncated trace;
    /// it never changes selection or retains program/scratch references.
    rounds: []Round = &.{},
    round_count: usize = 0,
    rounds_recorded: usize = 0,
    outcome: Outcome = .not_run,
    baseline: Counts = .{},
    full: Counts = .{},
    descriptions: Counts = .{},
    selected: Counts = .{},
    work: graph.Work = .{},
    extraction_rounds: usize = 0,
    attempted_extraction_rounds: usize = 0,
    first_selected_work: u64 = 0,
    selected_profile: ?discovery.Profile = null,
    validator_calls: usize = 0,
    candidate_admissions: usize = 0,
    pinned_functions: usize = 0,
    failed_check: ?anyerror = null,
};
pub const Round = struct {
    materialized: bool,
    baseline: Counts,
    full: Counts,
    descriptions: Counts,
    selected: ?discovery.Profile,
    work: u64,
};
pub const Options = struct {
    statistics: ?*Statistics = null,
    diagnostic: ?*Diagnostic = null,
    /// Deterministic discovery-work units; unlimited unless a caller selects a bound.
    work_limit: u64 = std.math.maxInt(u64),
    compact_refinement: bool = false,
    /// Borrowed final provenance from independently checked selected rounds.
    /// No provisional candidate is reported. Copy needed fields in the callback.
    correspondence: ?struct {
        context: *anyopaque,
        receive: *const fn (*anyopaque, *const origins.Trace) Error!void,
    } = null,

    pub fn resetObservations(self: Options) void {
        if (self.statistics) |stats| stats.* = .{ .rounds = stats.rounds };
        if (self.diagnostic) |diagnostic| diagnostic.* = .{};
    }
};
pub const Error = candidate.Error;
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    flow: @import("activation_flow.zig").Facts,

    pub fn deinit(self: *Owned) void {
        self.flow.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Raw-record entry point: checks the complete original before projection.
/// Source/component obligations remain the outer compiler/linker's responsibility.
/// Returned records/facts own their storage; statistics retain no record references.
pub fn run(allocator: std.mem.Allocator, original: ir.Program, options: Options) Error!Owned {
    return observe(allocator, original, options, null);
}

pub fn runWithWork(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
    remaining: *u64,
) Error!Owned {
    return observe(allocator, original, options, remaining);
}

fn observe(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
    remaining: ?*u64,
) Error!Owned {
    options.resetObservations();
    const result = runInternal(allocator, original, options, remaining) catch |failure| {
        const err = if (failure == error.WorkLimit and remaining != null)
            error.RelationLimit
        else
            failure;
        if (options.diagnostic) |d| d.code = err;
        if (options.statistics) |stats| stats.failed_check = err;
        return err;
    };
    if (options.diagnostic) |d| d.* = .{};
    return result;
}

fn runInternal(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
    remaining: ?*u64,
) Error!Owned {
    const round_storage: []Round = if (options.statistics) |stats| stats.rounds else &.{};
    try admitOriginal(allocator, original, options, remaining);
    if (options.diagnostic) |d| d.* = .{ .stage = .baseline };
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var baseline_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer baseline_arena.deinit();
    const baseline = try r.ownReachableWithWork(
        baseline_arena.allocator(),
        scratch.allocator(),
        original,
        remaining,
    );
    var trace: ?origins.Trace = if (options.diagnostic != null or options.correspondence != null)
        try origins.Trace.initWithWork(allocator, original, baseline, remaining)
    else
        null;
    defer if (trace) |*value| value.deinit();
    if (options.diagnostic) |d| d.* = .{ .stage = .baseline };
    var flow = try baselineFlow(allocator, baseline.program, options, &trace, remaining);
    errdefer flow.deinit();
    if (options.diagnostic) |d| d.* = .{ .stage = .cost };
    const bytes = try image.encodedLengthWithWork(baseline.program, remaining);
    const counts = try Counts.measure(baseline.program, bytes, remaining);
    var stats: Statistics = .{
        .baseline = counts,
        .selected = counts,
        .rounds = round_storage,
        .work = .{
            .limit = options.work_limit,
            .remaining = remaining,
            .compact_refinement = options.compact_refinement,
        },
    };
    defer {
        stats.work.remaining = null;
        if (options.statistics) |output| output.* = stats;
    }
    const selected = try select(allocator, original, baseline, &stats, &trace, options);
    if (selected) |result| {
        errdefer {
            var rejected = result;
            rejected.deinit();
        }
        if (options.correspondence) |observer| try observer.receive(observer.context, &trace.?);
        flow.deinit();
        baseline_arena.deinit();
        return result;
    }
    if (options.correspondence) |observer| try observer.receive(observer.context, &trace.?);
    return .{ .arena = baseline_arena, .program = baseline.program, .flow = flow };
}

fn select(
    allocator: std.mem.Allocator,
    original: ir.Program,
    baseline: r.Projection,
    stats: *Statistics,
    trace: *?origins.Trace,
    options: Options,
) Error!?Owned {
    return attempt(
        allocator,
        baseline.program,
        stats,
        if (trace.*) |*t| t else null,
        options.diagnostic,
    ) catch |err| switch (err) {
        error.WorkLimit => blk: {
            if (stats.work.remaining != null and !stats.work.local_exhausted)
                return error.RelationLimit;
            // The attempt may have selected earlier rounds before exhausting
            // its allowance. Returning the baseline also restores its mapping.
            if (trace.*) |*t| {
                t.deinit();
                trace.* = null;
                trace.* = try origins.Trace.initWithWork(
                    allocator,
                    original,
                    baseline,
                    stats.work.remaining,
                );
            }
            stats.outcome = .work_limit;
            stats.selected = stats.baseline;
            stats.extraction_rounds = 0;
            stats.selected_profile = null;
            break :blk null;
        },
        else => return err,
    };
}

fn owned(value: candidate.Candidate) Owned {
    return .{ .arena = value.arena, .program = value.program, .flow = value.flow };
}

fn eligible(value: candidate.Candidate, baseline: Counts, remaining: ?*u64) Error!bool {
    if (value.bytes > baseline.bytes or value.entries >= baseline.entries) return false;
    return hasMerge(value.correspondence.representatives, remaining);
}

const Cost = struct { bytes: usize, entries: usize };
fn choose(full: ?Cost, descriptions: ?Cost) ?discovery.Profile {
    if (full) |left| {
        const right = descriptions orelse return .full;
        return if (left.bytes < right.bytes or
            (left.bytes == right.bytes and left.entries <= right.entries)) .full else .descriptions;
    }
    return if (descriptions != null) .descriptions else null;
}

fn recordRound(stats: *Statistics, selected: ?discovery.Profile, materialized: bool) void {
    if (stats.rounds_recorded < stats.rounds.len) {
        stats.rounds[stats.rounds_recorded] = .{
            .materialized = materialized,
            .baseline = stats.selected,
            .full = stats.full,
            .descriptions = stats.descriptions,
            .selected = selected,
            .work = stats.work.units,
        };
        stats.rounds_recorded += 1;
    }
    stats.round_count += 1;
}

fn attempt(
    allocator: std.mem.Allocator,
    baseline: ir.Program,
    stats: *Statistics,
    trace: ?*origins.Trace,
    diagnostic: ?*Diagnostic,
) Error!?Owned {
    var selected: ?Owned = null;
    errdefer if (selected) |*value| value.deinit();
    stats.outcome = .no_change;
    var remaining = stats.baseline.entries;
    while (remaining != 0) {
        if (!try attemptRound(allocator, baseline, stats, trace, diagnostic, &selected))
            return selected;
        remaining -= 1;
    }
    return error.InvalidCorrespondence;
}

fn hasMerge(maps: r.Maps, remaining: ?*u64) Error!bool {
    for (maps) |map| if (try mapHasMerge(map, remaining)) return true;
    return false;
}

fn mapHasMerge(map: []const @import("program.zig").Id, remaining: ?*u64) Error!bool {
    try spend(remaining, map.len);
    for (map, 0..) |representative, id| if (representative != id) return true;
    return false;
}

test "coalescing exact portfolio cost seam preserves byte then entry then full ordering" {
    const testing = std.testing;
    try testing.expect(choose(null, null) == null);
    try testing.expectEqual(
        discovery.Profile.full,
        choose(.{ .bytes = 100, .entries = 8 }, .{ .bytes = 101, .entries = 7 }).?,
    );
    try testing.expectEqual(
        discovery.Profile.descriptions,
        choose(.{ .bytes = 102, .entries = 6 }, .{ .bytes = 101, .entries = 7 }).?,
    );
    try testing.expectEqual(
        discovery.Profile.descriptions,
        choose(.{ .bytes = 100, .entries = 8 }, .{ .bytes = 100, .entries = 7 }).?,
    );
    try testing.expectEqual(
        discovery.Profile.full,
        choose(.{ .bytes = 100, .entries = 7 }, .{ .bytes = 100, .entries = 7 }).?,
    );
}

test "coalescing size guard independently rejects growth and nonreducing extraction" {
    const testing = std.testing;
    const original = @import("coalescing_witness_tests.zig").original;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var work: graph.Work = .{};
    const analysis = try discovery.analyze(scratch.allocator(), original, &work);
    var proposed = try candidate.build(
        testing.allocator,
        scratch.allocator(),
        original,
        analysis,
        .full,
        &work,
    );
    defer proposed.deinit();
    const baseline = try Counts.of(original);
    try testing.expect(try eligible(proposed, baseline, null));
    // Inject cost orderings at the selection seam; do not claim these costs
    // were emitted by the real codec for this independently checked candidate.
    var cost = proposed;
    cost.bytes = baseline.bytes + 1;
    try testing.expect(!try eligible(cost, baseline, null));
    cost.bytes = baseline.bytes;
    try testing.expect(try eligible(cost, baseline, null));
    cost.entries = baseline.entries;
    try testing.expect(!try eligible(cost, baseline, null));
    cost.bytes = 0;
    try testing.expect(!try eligible(cost, baseline, null));
}

fn admitOriginal(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
    remaining: ?*u64,
) Error!void {
    var checked = admission.analyzeObservedWithWork(
        allocator,
        original,
        if (options.diagnostic) |d| &d.target else null,
        null,
        remaining,
    ) catch |err| {
        if (err != error.RelationLimit) if (options.diagnostic) |d| {
            origins.explainOriginalWithWork(original, d, remaining);
        };
        return err;
    };
    checked.deinit();
}

fn baselineFlow(
    allocator: std.mem.Allocator,
    program: ir.Program,
    options: Options,
    trace: *?origins.Trace,
    remaining: ?*u64,
) Error!@import("activation_flow.zig").Facts {
    return admission.analyzeObservedWithWork(
        allocator,
        program,
        if (options.diagnostic) |d| &d.target else null,
        null,
        remaining,
    ) catch |err| {
        if (err != error.RelationLimit) if (options.diagnostic) |d| {
            if (trace.*) |*t| t.explain(null, d);
        };
        return err;
    };
}

fn attemptRound(
    allocator: std.mem.Allocator,
    baseline: ir.Program,
    stats: *Statistics,
    trace: ?*origins.Trace,
    diagnostic: ?*Diagnostic,
    selected: *?Owned,
) Error!bool {
    if (diagnostic) |d| d.* = .{ .stage = .mapping };
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const program = if (selected.*) |value| value.program else baseline;
    const analysis = try discovery.analyze(a, program, &stats.work);
    try spend(stats.work.remaining, program.functions.len);
    if (stats.round_count == 0) for (analysis.nodes[0..program.functions.len]) |node| {
        stats.pinned_functions += @intFromBool(node.pinned);
    };
    const full_map = try discovery.correspondence(a, program, analysis, .full, &stats.work);
    // A restricted profile can only split the complete full relation. If
    // that relation has no merge, neither profile can reduce live records.
    if (!try hasMerge(full_map.representatives, stats.work.remaining)) {
        stats.full = stats.selected;
        stats.descriptions = stats.selected;
        recordRound(stats, null, false);
        return false;
    }
    return materializeRound(
        allocator,
        a,
        program,
        analysis,
        full_map,
        stats,
        trace,
        diagnostic,
        selected,
    );
}

fn materializeRound(
    allocator: std.mem.Allocator,
    a: std.mem.Allocator,
    program: ir.Program,
    analysis: discovery.Analysis,
    full_map: @import("coalescing_witness.zig").Witness,
    stats: *Statistics,
    trace: ?*origins.Trace,
    diagnostic: ?*Diagnostic,
    selected: *?Owned,
) Error!bool {
    var full = try candidate.materialize(
        allocator,
        a,
        program,
        full_map,
        trace,
        diagnostic,
        stats.work.remaining,
    );
    var keep_full = false;
    defer if (!keep_full) full.deinit();
    // The description profile adds only singleton function restrictions.
    // When full discovery already has those singletons, both fixed points
    // and materializations are identical. Reuse the independently checked
    // full candidate; the existing tie-break selects it in either case.
    const same_profiles = !try mapHasMerge(
        full_map.representatives[@backingInt(r.Kind.function)],
        stats.work.remaining,
    );
    var separate_descriptions: ?candidate.Candidate = if (same_profiles)
        null
    else
        try candidate.buildObserved(
            allocator,
            a,
            program,
            analysis,
            .descriptions,
            &stats.work,
            trace,
            diagnostic,
        );
    const descriptions = if (separate_descriptions) |*value| value else &full;
    var keep_descriptions = false;
    defer if (!keep_descriptions) if (separate_descriptions) |*value| value.deinit();
    const selected_profile = try selectProfile(
        stats,
        full,
        descriptions.*,
        same_profiles,
        selected.* == null,
    ) orelse return false;
    if (diagnostic) |d| d.* = .{ .stage = .mapping };
    const winner = if (selected_profile == .full) &full else descriptions;
    if (trace) |t| try t.advance(winner.correspondence);
    if (selected.*) |*old| old.deinit();
    keep_full = selected_profile == .full;
    keep_descriptions = selected_profile == .descriptions;
    selected.* = owned(winner.*);
    stats.selected = if (keep_full) stats.full else stats.descriptions;
    stats.selected_profile = selected_profile;
    stats.outcome = .applied;
    stats.extraction_rounds += 1;
    stats.attempted_extraction_rounds += 1;
    if (stats.first_selected_work == 0) stats.first_selected_work = stats.work.units;
    return true;
}

fn selectProfile(
    stats: *Statistics,
    full: candidate.Candidate,
    descriptions: candidate.Candidate,
    same_profiles: bool,
    initial: bool,
) Error!?discovery.Profile {
    stats.validator_calls += if (same_profiles) @as(usize, 2) else 4;
    stats.candidate_admissions += if (same_profiles) @as(usize, 1) else 2;
    stats.full = try Counts.measure(full.program, full.bytes, stats.work.remaining);
    stats.descriptions = if (same_profiles) stats.full else try Counts.measure(
        descriptions.program,
        descriptions.bytes,
        stats.work.remaining,
    );
    const full_eligible = try eligible(full, stats.selected, stats.work.remaining);
    const description_eligible = try eligible(descriptions, stats.selected, stats.work.remaining);
    const selected_profile = choose(
        if (full_eligible) .{ .bytes = full.bytes, .entries = full.entries } else null,
        if (description_eligible)
            .{ .bytes = descriptions.bytes, .entries = descriptions.entries }
        else
            null,
    );
    recordRound(stats, selected_profile, true);
    if (!full_eligible and !description_eligible) {
        if (initial and (full.entries < stats.selected.entries or
            descriptions.entries < stats.selected.entries)) stats.outcome = .size_guard;
        return null;
    }
    return selected_profile;
}
