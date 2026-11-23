// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const lowering = @import("activation_lower.zig");
const phases = @import("recovery_phases.zig");
const reuse = data.scalar_field_reuse;
const Allocator = std.mem.Allocator;
const Program = data.activation.Program;
const Correspondence = data.coalescing.Correspondence;

pub const Rule = enum(u8) { structural_fallback = 0, scalar_field_reuse_v1 = 1, _ };
pub const Formal = phases.Formal;
pub const RuleLimits = struct {
    work: u64 = 300_000_000,
    witnesses: usize = 4096,
    depth: usize = 256,
    temporary_bytes: usize = 1024 * 1024 * 1024,

    fn budget(self: RuleLimits) reuse.Budget {
        return reuse.Budget.init(.{
            .work = self.work,
            .witnesses = self.witnesses,
            .depth = self.depth,
            .temporary_bytes = self.temporary_bytes,
        });
    }
};
pub const Limits = struct {
    rule: RuleLimits = .{},
    structural_evidence_bytes: usize = 16 * 1024 * 1024,
    evidence_bytes: usize = 16 * 1024 * 1024,
    lowering_bytes: usize = 1024 * 1024 * 1024,
    source_work: u64 = 1_000_000_000,
    p01_work: u64 = 100_000_000,
    image_growth_bytes: usize = 0,
};
pub const Options = struct { rule: Rule, limits: Limits, formals: []const Formal };
pub const Evidence = struct {
    rule: Rule,
    witnesses: []const reuse.Witness,
    correspondence: Correspondence,
};
pub const Outcome = enum { applied, no_sites, recovery_liveness, budget, size_guard };
pub const Statistics = struct {
    discovery: reuse.Statistics = .{},
    recovery_liveness: usize = 0,
    size_guard: usize = 0,
    budget: usize = 0,
};
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    map_arena: std.heap.ArenaAllocator,
    program: Program,
    parameters: []const source.RecoveryBinding,
    evidence: Evidence,
    outcome: Outcome,
    statistics: Statistics,

    pub fn deinit(self: *Result) void {
        self.map_arena.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn lower(a: Allocator, module: source.Module, submitted: Options) !Result {
    if (submitted.rule != .scalar_field_reuse_v1) return error.UnsupportedVersion;
    var options = submitted;
    var source_work = options.limits.source_work;
    var lowering_bytes = options.limits.lowering_bytes;
    var mandatory: data.AllocationBudget = .{
        .parent = a,
        .remaining = &lowering_bytes,
        .accounting = .live,
    };
    const scratch = mandatory.allocator();
    var protected = try phases.normalize(scratch, module, options.formals, &source_work);
    defer protected.deinit();
    options.formals = protected.formals();
    var original = try lowering.lowerRecoveryInputWithWork(scratch, module, &source_work);
    defer original.deinit();
    var baseline = try structural(scratch, &original, module, options, null, &source_work);
    defer baseline.deinit();
    var remaining = options.limits.rule.temporary_bytes;
    var storage: data.AllocationBudget = .{ .parent = a, .remaining = &remaining };
    var stats: Statistics = .{};
    var outcome: Outcome = .no_sites;
    const result = attempt(
        a,
        storage.allocator(),
        module,
        options,
        &original,
        &baseline,
        &stats,
        &outcome,
    ) catch |err| switch (err) {
        error.RelationLimit, error.ScalarFieldLimit => null,
        error.OutOfMemory => if (storage.exhausted) null else return err,
        error.OutputAllocationFailed => return error.OutOfMemory,
        else => return err,
    };
    if (result) |selected| return selected;
    const evidence: Evidence = .{
        .rule = .structural_fallback,
        .witnesses = &.{},
        .correspondence = baseline.map,
    };
    try checkWire(scratch, evidence, options.limits, &source_work);
    return publish(
        a,
        &baseline.arena,
        &baseline.map_arena,
        baseline.program,
        original.parameters,
        evidence,
        outcome,
        stats,
        &source_work,
    );
}

const Context = struct {
    a: Allocator,
    original: *const source.Compiled,
    baseline: *const Baseline,
    module: source.Module,
    options: Options,
    budget: *reuse.Budget,
    prepared_original: ?*reuse.PreparedOriginal = null,

    fn checked(self: Context, arena: Allocator, witnesses: []const reuse.Witness) !Program {
        try surviving(witnesses, self.baseline.map, self.budget);
        const r = self.original.program;
        const s = try reuse.reconstructBorrowedProposal(arena, r, witnesses, self.budget);
        const observer: PhaseCheck = .{ .ctx = self, .candidate = s };
        if (self.prepared_original) |prepared| {
            try prepared.validateObserved(s, witnesses, observer);
        } else try reuse.validateObserved(self.a, r, s, witnesses, self.budget, observer);
        return s;
    }

    fn checkResult(self: Context, program: Program, evidence: Evidence) !void {
        try surviving(evidence.witnesses, evidence.correspondence, self.budget);
        try imageGuard(self.baseline.program, program, self.options.limits, &self.budget.remaining);
    }

    fn composed(
        self: Context,
        s: Program,
        t: Program,
        evidence: Evidence,
        p01_remaining: u64,
    ) !void {
        try self.checkResult(t, evidence);
        const allowance = @min(p01_remaining, self.budget.remaining);
        var remaining = allowance;
        var flow = data.coalescing.correspondenceFlow(
            self.a,
            s,
            t,
            evidence.correspondence,
            &remaining,
        ) catch |err| {
            self.budget.remaining -= allowance - remaining;
            return err;
        };
        self.budget.remaining -= allowance - remaining;
        defer flow.deinit();
        try self.finalPhases(t, evidence, &flow);
    }

    fn finalPhases(
        self: Context,
        t: Program,
        evidence: Evidence,
        flow: *const data.activation_flow.Facts,
    ) !void {
        try phases.validateDistinct(
            self.a,
            self.module,
            self.original.parameters,
            self.options.formals,
            self.original.program,
            &self.original.flow,
            t,
            flow,
            evidence.correspondence,
            &self.budget.remaining,
        );
        try phases.validateDistinctAliases(
            self.a,
            self.module,
            self.original.parameters,
            self.options.formals,
            self.original.program,
            self.baseline.map,
            evidence.correspondence,
            &self.budget.remaining,
        );
    }
};

const PhaseCheck = struct {
    ctx: Context,
    candidate: Program,

    pub fn checked(
        self: PhaseCheck,
        before: *const data.activation_flow.Facts,
        after: *const data.activation_flow.Facts,
    ) !void {
        const ctx = self.ctx;
        try phases.validateDistinct(
            ctx.a,
            ctx.module,
            ctx.original.parameters,
            ctx.options.formals,
            ctx.original.program,
            before,
            self.candidate,
            after,
            null,
            &ctx.budget.remaining,
        );
    }
};

fn attempt(
    parent: Allocator,
    work: Allocator,
    module: source.Module,
    options: Options,
    original: *const source.Compiled,
    baseline: *const Baseline,
    stats: *Statistics,
    outcome: *Outcome,
) !?Result {
    outcome.* = .budget;
    const limits = options.limits;
    if (limits.rule.work == 0 or limits.rule.depth == 0 or limits.rule.witnesses == 0 or
        limits.evidence_bytes == 0 or limits.p01_work == 0) return null;
    var budget = limits.rule.budget();
    return reuse.withPreparedOriginal(work, original.program, &budget, TryPrepared{
        .parent = parent,
        .ctx = .{
            .a = work,
            .original = original,
            .baseline = baseline,
            .options = options,
            .module = module,
            .budget = &budget,
        },
        .stats = stats,
        .outcome = outcome,
    });
}

const AttemptResult = ?Result;
const TryPrepared = struct {
    pub const Result = AttemptResult;
    parent: Allocator,
    ctx: Context,
    stats: *Statistics,
    outcome: *Outcome,

    pub fn prepared(
        self: TryPrepared,
        source_input: *reuse.PreparedOriginal,
    ) anyerror!AttemptResult {
        var ctx = self.ctx;
        ctx.prepared_original = source_input;
        return selectBatch(self.parent, ctx, source_input, self.stats, self.outcome);
    }
};

fn selectBatch(
    parent: Allocator,
    ctx: Context,
    prepared: *reuse.PreparedOriginal,
    stats: *Statistics,
    outcome: *Outcome,
) !?Result {
    var scratch = std.heap.ArenaAllocator.init(ctx.a);
    defer scratch.deinit();
    const discovered = prepared.discover(scratch.allocator(), &stats.discovery) catch |err| {
        stats.budget = stats.discovery.proven;
        return err;
    };
    if (discovered.len == 0) {
        outcome.* = .no_sites;
        return null;
    }
    stats.budget = discovered.len;
    var witnesses = discovered;
    var proposal = std.heap.ArenaAllocator.init(ctx.a);
    defer proposal.deinit();
    const s = try checkedBatch(ctx, &proposal, scratch.allocator(), &witnesses, stats) orelse {
        outcome.* = .recovery_liveness;
        stats.budget = 0;
        return null;
    };
    var p01 = ctx.options.limits.p01_work;
    var selected = finish(ctx, s, witnesses, &p01) catch |err| switch (err) {
        error.RecoveryLiveness => recovered: {
            _ = proposal.reset(.free_all);
            break :recovered try filterComposed(
                ctx,
                scratch.allocator(),
                &witnesses,
                stats,
                &p01,
            ) orelse {
                outcome.* = .recovery_liveness;
                return null;
            };
        },
        error.ImageSizeLimit => {
            stats.size_guard = witnesses.len;
            stats.budget = 0;
            outcome.* = .size_guard;
            return null;
        },
        else => return err,
    };
    defer selected.deinit();
    return try publishSelected(parent, ctx, &selected, witnesses, stats.*);
}

fn publishSelected(
    parent: Allocator,
    ctx: Context,
    selected: *Baseline,
    witnesses: []const reuse.Witness,
    stats: Statistics,
) !Result {
    const evidence: Evidence = .{
        .rule = ctx.options.rule,
        .witnesses = witnesses,
        .correspondence = selected.map,
    };
    var applied = stats;
    applied.budget = 0;
    return publish(
        parent,
        &selected.arena,
        &selected.map_arena,
        selected.program,
        ctx.original.parameters,
        evidence,
        .applied,
        applied,
        &ctx.budget.remaining,
    ) catch |err| return if (err == error.OutOfMemory) error.OutputAllocationFailed else err;
}

fn checkedBatch(
    ctx: Context,
    proposal: *std.heap.ArenaAllocator,
    scratch: Allocator,
    witnesses: *[]const reuse.Witness,
    stats: *Statistics,
) !?Program {
    return ctx.checked(proposal.allocator(), witnesses.*) catch |err| {
        if (err != error.RecoveryLiveness) return err;
        _ = proposal.reset(.free_all);
        if (witnesses.len == 1) {
            stats.recovery_liveness += 1;
            return null;
        }
        return filterLive(ctx, proposal, scratch, witnesses, stats);
    };
}

fn filterLive(
    ctx: Context,
    proposal: *std.heap.ArenaAllocator,
    scratch: Allocator,
    witnesses: *[]const reuse.Witness,
    stats: *Statistics,
) !?Program {
    const selected = try scratch.alloc(reuse.Witness, witnesses.len);
    var count: usize = 0;
    var best: ?Program = null;
    for (witnesses.*) |w| {
        if (count + 1 == witnesses.len) {
            stats.recovery_liveness += 1;
            stats.budget -= 1;
            break;
        }
        var trial = std.heap.ArenaAllocator.init(ctx.a);
        defer trial.deinit();
        selected[count] = w;
        best = ctx.checked(trial.allocator(), selected[0 .. count + 1]) catch |err| {
            if (err != error.RecoveryLiveness) return err;
            stats.recovery_liveness += 1;
            stats.budget -= 1;
            continue;
        };
        std.mem.swap(std.heap.ArenaAllocator, proposal, &trial);
        count += 1;
    }
    witnesses.* = selected[0..count];
    return best;
}

const Baseline = struct {
    arena: std.heap.ArenaAllocator,
    map_arena: std.heap.ArenaAllocator,
    program: Program,
    map: Correspondence,

    fn deinit(self: *Baseline) void {
        self.map_arena.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

const SubmittedFallback = Correspondence.Reconstruction.Submitted;

fn structural(
    a: Allocator,
    original: *const source.Compiled,
    module: source.Module,
    options: Options,
    submitted: ?SubmittedFallback,
    work: *u64,
) !Baseline {
    var map_arena = std.heap.ArenaAllocator.init(a);
    errdefer map_arena.deinit();
    var result = try Correspondence.Reconstruction.checked(
        a,
        &map_arena,
        original.program,
        submitted,
        work,
    );
    errdefer result.final.arena.deinit();
    defer result.final.flow.deinit();
    try phases.validateDistinct(
        a,
        module,
        original.parameters,
        options.formals,
        original.program,
        &original.flow,
        result.final.program,
        &result.final.flow,
        result.map,
        work,
    );
    return .{
        .arena = result.final.arena,
        .map_arena = map_arena,
        .program = result.final.program,
        .map = result.map,
    };
}

fn surviving(ws: []const reuse.Witness, map: Correspondence, budget: *reuse.Budget) !void {
    const blocks = map.maps[@backingInt(data.relocation.Kind.block)];
    try data.admission.spend(&budget.remaining, ws.len);
    for (ws) |w| {
        if (w.target.block >= blocks.len or w.source.block >= blocks.len or
            blocks[@intCast(w.target.block)] == data.relocation.missing or
            blocks[@intCast(w.source.block)] == data.relocation.missing)
            return error.InvalidCorrespondence;
    }
}

fn imageGuard(baseline: Program, actual: Program, limits: Limits, work: *u64) !void {
    const before = try data.program_image.encodedLengthWithWork(baseline, work);
    const after = try data.program_image.encodedLengthWithWork(actual, work);
    if (after -| before > limits.image_growth_bytes) return error.ImageSizeLimit;
}

fn finish(
    ctx: Context,
    s: Program,
    witnesses: []const reuse.Witness,
    p01: *u64,
) !Baseline {
    var scratch = std.heap.ArenaAllocator.init(ctx.a);
    errdefer scratch.deinit();
    var result = checked: {
        const allowance = @min(p01.*, ctx.budget.remaining);
        var remaining = allowance;
        defer {
            const spent = allowance - remaining;
            ctx.budget.remaining -= spent;
            p01.* -= spent;
        }
        break :checked try Correspondence.Reconstruction.checked(
            ctx.a,
            &scratch,
            s,
            null,
            &remaining,
        );
    };
    errdefer result.final.arena.deinit();
    defer result.final.flow.deinit();
    const evidence: Evidence = .{
        .rule = ctx.options.rule,
        .witnesses = witnesses,
        .correspondence = result.map,
    };
    try checkWire(ctx.a, evidence, ctx.options.limits, &ctx.budget.remaining);
    try ctx.checkResult(result.final.program, evidence);
    try ctx.finalPhases(result.final.program, evidence, &result.final.flow);
    return .{
        .arena = result.final.arena,
        .map_arena = scratch,
        .program = result.final.program,
        .map = result.map,
    };
}

fn filterComposed(
    ctx: Context,
    scratch: Allocator,
    witnesses: *[]const reuse.Witness,
    stats: *Statistics,
    p01: *u64,
) !?Baseline {
    const selected = try scratch.alloc(reuse.Witness, witnesses.len);
    var count: usize = 0;
    var best: ?Baseline = null;
    errdefer if (best) |*previous| previous.deinit();
    for (witnesses.*) |w| {
        if (count + 1 == witnesses.len) {
            stats.recovery_liveness += 1;
            stats.budget -= 1;
            break;
        }
        selected[count] = w;
        const extension = selected[0 .. count + 1];
        var trial = std.heap.ArenaAllocator.init(ctx.a);
        defer trial.deinit();
        const s = ctx.checked(trial.allocator(), extension) catch |err| {
            if (err != error.RecoveryLiveness) return err;
            stats.recovery_liveness += 1;
            stats.budget -= 1;
            continue;
        };
        const accepted = finish(ctx, s, extension, p01) catch |err| {
            switch (err) {
                error.RecoveryLiveness => stats.recovery_liveness += 1,
                error.ImageSizeLimit => stats.size_guard += 1,
                else => return err,
            }
            stats.budget -= 1;
            continue;
        };
        if (best) |*previous| previous.deinit();
        best = accepted;
        count += 1;
    }
    witnesses.* = selected[0..count];
    return best;
}

fn publish(
    parent: Allocator,
    records: *std.heap.ArenaAllocator,
    correspondence: *std.heap.ArenaAllocator,
    program: Program,
    origins: []const source.RecoveryBinding,
    evidence: Evidence,
    outcome: Outcome,
    stats: Statistics,
    work: *u64,
) !Result {
    try data.admission.spend(work, evidence.witnesses.len);
    correspondence.child_allocator = parent;
    const owner = correspondence.allocator();
    const bindings = try relocate(owner, origins, evidence.correspondence, work);
    const witnesses = try owner.dupe(reuse.Witness, evidence.witnesses);
    const result: Result = .{
        .program = program,
        .parameters = bindings,
        .evidence = .{
            .rule = evidence.rule,
            .witnesses = witnesses,
            .correspondence = evidence.correspondence,
        },
        .arena = records.state.promote(parent),
        .map_arena = correspondence.*,
        .outcome = outcome,
        .statistics = stats,
    };
    records.state = .init;
    correspondence.state = .init;
    return result;
}

fn relocate(
    a: Allocator,
    parameters_in: []const source.RecoveryBinding,
    map: Correspondence,
    work: *u64,
) ![]const source.RecoveryBinding {
    try data.admission.spend(work, parameters_in.len);
    var count: usize = 0;
    for (parameters_in) |binding| count += @intFromBool(try binding.relocated(map) != null);
    try data.admission.spend(work, parameters_in.len);
    const bindings = try a.alloc(source.RecoveryBinding, count);
    errdefer a.free(bindings);
    var index: usize = 0;
    for (parameters_in) |binding| if (try binding.relocated(map)) |mapped| {
        bindings[index] = mapped;
        index += 1;
    };
    return bindings;
}

fn evidenceSize(evidence: Evidence, limit: usize, work: *u64) !usize {
    const available = @min(limit, work.*);
    var remaining: u64 = available;
    var size: data.wire.Writer = .{ .remaining = &remaining };
    defer work.* -= available - remaining;
    try data.record.write(Evidence, evidence, &size);
    return size.position;
}

fn checkWire(a: Allocator, evidence: Evidence, limits: Limits, work: *u64) !void {
    const bytes_limit = if (evidence.rule == .structural_fallback)
        limits.structural_evidence_bytes
    else
        limits.evidence_bytes;
    const length = try evidenceSize(evidence, bytes_limit, work);
    const bytes = try a.alloc(u8, length);
    defer a.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes, .remaining = work };
    try data.record.write(Evidence, evidence, &writer);
    var decoded = try decodeWithWork(a, bytes, limits, work);
    defer decoded.deinit();
}

pub fn parameters(
    a: Allocator,
    module: source.Module,
    program: Program,
    evidence: Evidence,
    submitted: Options,
) ![]const source.RecoveryBinding {
    if (submitted.rule != .scalar_field_reuse_v1) return error.UnsupportedVersion;
    var options = submitted;
    var source_work = options.limits.source_work;
    try proofShape(evidence.rule, evidence.witnesses.len, options.limits);
    var lowering_bytes = options.limits.lowering_bytes;
    var mandatory: data.AllocationBudget = .{
        .parent = a,
        .remaining = &lowering_bytes,
        .accounting = .live,
    };
    const preparation = mandatory.allocator();
    var protected = try phases.normalize(preparation, module, options.formals, &source_work);
    defer protected.deinit();
    options.formals = protected.formals();
    var remaining = options.limits.rule.temporary_bytes;
    var storage: data.AllocationBudget = .{ .parent = a, .remaining = &remaining };
    const work = storage.allocator();
    var budget = options.limits.rule.budget();
    const fallback = evidence.rule == .structural_fallback;
    const byte_limit = if (fallback)
        options.limits.structural_evidence_bytes
    else
        options.limits.evidence_bytes;
    const check_work = if (fallback) &source_work else &budget.remaining;
    _ = try evidenceSize(evidence, byte_limit, check_work);
    try correspondenceShape(evidence.correspondence, check_work);
    var original = try lowering.lowerRecoveryInputWithWork(preparation, module, &source_work);
    defer original.deinit();
    const submitted_fallback: ?SubmittedFallback = if (fallback)
        .{ .program = program, .map = evidence.correspondence }
    else
        null;
    var baseline = try structural(
        preparation,
        &original,
        module,
        options,
        submitted_fallback,
        &source_work,
    );
    defer baseline.deinit();
    if (fallback) return relocate(a, original.parameters, baseline.map, &source_work);
    var scratch = std.heap.ArenaAllocator.init(work);
    defer scratch.deinit();
    const ctx: Context = .{
        .a = work,
        .original = &original,
        .baseline = &baseline,
        .options = options,
        .module = module,
        .budget = &budget,
    };
    const s = ctx.checked(scratch.allocator(), evidence.witnesses) catch |err|
        return validationError(err, storage);
    ctx.composed(s, program, evidence, options.limits.p01_work) catch |err|
        return validationError(err, storage);
    return relocate(a, original.parameters, evidence.correspondence, &budget.remaining);
}

fn validationError(err: anyerror, storage: data.AllocationBudget) anyerror {
    return if (err == error.OutOfMemory and storage.exhausted) error.ScalarFieldLimit else err;
}

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    evidence: Evidence,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn proofShape(rule: Rule, witnesses: usize, limits: Limits) !void {
    switch (rule) {
        .structural_fallback => if (witnesses != 0) return error.InvalidCorrespondence,
        .scalar_field_reuse_v1 => {
            if (witnesses == 0) return error.InvalidCorrespondence;
            if (witnesses > limits.rule.witnesses or limits.p01_work == 0)
                return error.ScalarFieldLimit;
        },
        else => return error.UnsupportedVersion,
    }
}

fn correspondenceShape(map: Correspondence, work: *u64) !void {
    const functions = map.maps[@backingInt(data.relocation.Kind.function)];
    if (functions.len != map.locals.len) return error.InvalidCorrespondence;
    try data.admission.spend(work, map.regions.len);
    var previous: ?u64 = null;
    for (map.regions) |region| {
        if (previous) |id| if (region.original <= id) return error.InvalidCorrespondence;
        previous = region.original;
    }
    try data.admission.spend(work, functions.len);
    for (functions, map.locals) |function, local| {
        if (function == data.relocation.missing and
            (local.slots.len != 0 or local.custody.len != 0))
            return error.InvalidCorrespondence;
    }
}

pub fn decode(a: Allocator, bytes: []const u8, limits: Limits) !Decoded {
    return decodeWithWork(a, bytes, limits, null) catch |err| switch (err) {
        error.RelationLimit => error.ScalarFieldLimit,
        else => err,
    };
}

fn decodeWithWork(a: Allocator, bytes: []const u8, limits: Limits, shared: ?*u64) !Decoded {
    var reader: data.wire.Reader = .{ .input = bytes };
    const tag = try reader.natural();
    if (tag > std.math.maxInt(u8)) return error.UnsupportedVersion;
    const rule: Rule = @fromBackingInt(@intCast(@as(u8, @intCast(tag))));
    const fallback = switch (rule) {
        .structural_fallback => true,
        .scalar_field_reuse_v1 => false,
        else => return error.UnsupportedVersion,
    };
    const byte_limit = if (fallback) limits.structural_evidence_bytes else limits.evidence_bytes;
    var allowance = if (fallback) limits.source_work else limits.rule.work;
    const work = shared orelse &allowance;
    if (bytes.len > byte_limit) return error.ScalarFieldLimit;
    try data.admission.spend(work, bytes.len);
    try proofShape(rule, try reader.count(), limits);
    reader.position = 0;
    var capacity = if (fallback) limits.lowering_bytes else limits.rule.temporary_bytes;
    var physical = capacity;
    var cap: data.AllocationBudget = .{ .parent = a, .remaining = &physical, .accounting = .live };
    var arena = std.heap.ArenaAllocator.init(cap.allocator());
    errdefer arena.deinit();
    const evidence = data.record.readBounded(
        Evidence,
        &reader,
        arena.allocator(),
        &capacity,
    ) catch |err| switch (err) {
        error.Capacity => return error.ScalarFieldLimit,
        else => return validationError(err, cap),
    };
    try reader.finish();
    try correspondenceShape(evidence.correspondence, work);
    arena.child_allocator = a;
    return .{ .arena = arena, .evidence = evidence };
}
