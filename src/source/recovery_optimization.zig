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

pub const Rule = enum(u8) { scalar_field_reuse_v1 = 1, _ };
pub const Formal = phases.Formal;
pub const Limits = struct {
    rule: reuse.Limits = .{
        .work = 300_000_000,
        .witnesses = 4096,
        .depth = 256,
        .temporary_bytes = 1024 * 1024 * 1024,
    },
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
    program: Program,
    parameters: []const source.RecoveryBinding,
    evidence: Evidence,
    outcome: Outcome,
    statistics: Statistics,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn requirements(module: source.Module, options: Options) !void {
    if (options.rule != .scalar_field_reuse_v1) return error.UnsupportedVersion;
    for (options.formals) |formal| {
        if (formal.function >= module.functions.len or
            formal.ordinal >= module.functions[@intCast(formal.function)].parameters.len)
            return error.InvalidCorrespondence;
    }
}

pub fn lower(a: Allocator, module: source.Module, options: Options) !Result {
    try requirements(module, options);
    var source_work = options.limits.source_work;
    var lowering_bytes = options.limits.lowering_bytes;
    var mandatory: data.AllocationBudget = .{
        .parent = a,
        .remaining = &lowering_bytes,
        .accounting = .live,
    };
    const scratch = mandatory.allocator();
    var original = try lowering.lowerRecoveryInputWithWork(scratch, module, &source_work);
    defer original.deinit();
    var baseline = try structural(scratch, &original, options.limits);
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
        else => return err,
    };
    if (result) |selected| return selected;
    return owned(a, baseline.program, original.parameters, .{
        .rule = options.rule,
        .witnesses = &.{},
        .correspondence = baseline.recovery_evidence.?.correspondence,
    }, outcome, stats);
}

const Context = struct {
    a: Allocator,
    original: *const source.Compiled,
    module: source.Module,
    options: Options,
    budget: *reuse.Budget,

    fn checked(self: Context, arena: Allocator, witnesses: []const reuse.Witness) !Program {
        const r = self.original.program;
        const s = try reuse.reconstruct(arena, r, witnesses, self.budget);
        try reuse.validateObserved(self.a, r, s, witnesses, self.budget, PhaseCheck{
            .ctx = self,
            .candidate = s,
        });
        return s;
    }

    fn composed(
        self: Context,
        structural_map: Correspondence,
        s: Program,
        t: Program,
        evidence: Evidence,
    ) !void {
        var flow = try data.coalescing.correspondenceFlow(
            self.a,
            s,
            t,
            evidence.correspondence,
            &self.budget.remaining,
        );
        defer flow.deinit();
        try phases.validate(
            self.a,
            self.module,
            self.original.parameters,
            self.options.formals,
            self.original.program,
            &self.original.flow,
            t,
            &flow,
            evidence.correspondence,
            &self.budget.remaining,
        );
        try phases.validateAliases(
            self.a,
            self.module,
            self.original.parameters,
            self.options.formals,
            self.original.program,
            structural_map,
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
        try phases.validate(
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
    baseline: *const source.Compiled,
    stats: *Statistics,
    outcome: *Outcome,
) !?Result {
    outcome.* = .budget;
    const limits = options.limits;
    if (limits.rule.work == 0 or limits.rule.depth == 0 or
        limits.rule.witnesses == 0 or limits.evidence_bytes == 0) return null;
    var scratch = std.heap.ArenaAllocator.init(work);
    defer scratch.deinit();
    var budget = reuse.Budget.init(limits.rule);
    const ctx: Context = .{
        .a = work,
        .original = original,
        .options = options,
        .module = module,
        .budget = &budget,
    };
    const discovered = try reuse.discover(
        scratch.allocator(),
        original.program,
        &budget,
        &stats.discovery,
    );
    if (discovered.len == 0) {
        outcome.* = .no_sites;
        return null;
    }
    stats.budget = discovered.len;
    var witnesses = discovered;
    const s = ctx.checked(scratch.allocator(), witnesses) catch |err| blk: {
        if (err != error.RecoveryLiveness) return err;
        witnesses = try filterLive(ctx, scratch.allocator(), witnesses, stats);
        if (witnesses.len == 0) {
            outcome.* = .recovery_liveness;
            stats.budget = 0;
            return null;
        }
        break :blk try ctx.checked(scratch.allocator(), witnesses);
    };
    const selected = finish(parent, ctx, s, witnesses, baseline, stats) catch |err| {
        switch (err) {
            error.RecoveryLiveness => {
                stats.recovery_liveness += witnesses.len;
                outcome.* = .recovery_liveness;
            },
            error.ImageSizeLimit => {
                stats.size_guard = witnesses.len;
                outcome.* = .size_guard;
            },
            else => return err,
        }
        stats.budget = 0;
        return null;
    };
    return selected;
}

fn filterLive(
    ctx: Context,
    arena: Allocator,
    witnesses: []const reuse.Witness,
    stats: *Statistics,
) ![]const reuse.Witness {
    const selected = try arena.alloc(reuse.Witness, witnesses.len);
    var count: usize = 0;
    for (witnesses) |w| {
        var trial = std.heap.ArenaAllocator.init(ctx.a);
        defer trial.deinit();
        selected[count] = w;
        _ = ctx.checked(trial.allocator(), selected[0 .. count + 1]) catch |err| {
            if (err != error.RecoveryLiveness) return err;
            stats.recovery_liveness += 1;
            continue;
        };
        count += 1;
    }
    return selected[0..count];
}

const Capture = struct {
    arena: Allocator,
    map: ?Correspondence = null,

    fn observe(
        ptr: *anyopaque,
        trace: *const data.coalescing.OriginsTrace,
    ) data.coalescing.Error!void {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        self.map = try Correspondence.copy(self.arena, trace);
    }
};

fn structural(a: Allocator, original: *const source.Compiled, limits: Limits) !source.Compiled {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var capture: Capture = .{ .arena = scratch.allocator() };
    var final = try data.coalescing.run(a, original.program, .{
        .work_limit = limits.p01_work,
        .correspondence = .{ .context = &capture, .receive = Capture.observe },
    });
    errdefer final.deinit();
    const map = capture.map orelse return error.InvalidCorrespondence;
    try data.coalescing.validateCorrespondence(a, original.program, final.program, map);
    const owner = final.arena.allocator();
    const proof = try source.own(Correspondence, owner, map);
    const bindings = try relocate(owner, original.parameters, proof);
    return .{
        .arena = final.arena,
        .program = final.program,
        .flow = final.flow,
        .parameters = bindings,
        .recovery_evidence = .{ .correspondence = proof },
    };
}

fn finish(
    a: Allocator,
    ctx: Context,
    s: Program,
    witnesses: []const reuse.Witness,
    baseline: *const source.Compiled,
    stats: *Statistics,
) !Result {
    var scratch = std.heap.ArenaAllocator.init(ctx.a);
    defer scratch.deinit();
    var capture: Capture = .{ .arena = scratch.allocator() };
    var final = try data.coalescing.run(ctx.a, s, .{
        .work_limit = ctx.options.limits.p01_work,
        .correspondence = .{ .context = &capture, .receive = Capture.observe },
    });
    defer final.deinit();
    const evidence: Evidence = .{
        .rule = ctx.options.rule,
        .witnesses = witnesses,
        .correspondence = capture.map orelse return error.InvalidCorrespondence,
    };
    _ = try evidenceSize(evidence, ctx.options.limits.evidence_bytes, &ctx.budget.remaining);
    try ctx.composed(
        baseline.recovery_evidence.?.correspondence,
        s,
        final.program,
        evidence,
    );
    const before = try data.program_image.encodedLength(baseline.program);
    const after = try data.program_image.encodedLength(final.program);
    if (after -| before > ctx.options.limits.image_growth_bytes) return error.ImageSizeLimit;
    stats.budget = 0;
    return owned(a, final.program, ctx.original.parameters, evidence, .applied, stats.*);
}

fn owned(
    a: Allocator,
    program: Program,
    origins: []const source.RecoveryBinding,
    evidence: Evidence,
    outcome: Outcome,
    stats: Statistics,
) !Result {
    var result = std.heap.ArenaAllocator.init(a);
    errdefer result.deinit();
    const owner = result.allocator();
    const records = try source.own(Program, owner, program);
    const bindings = try relocate(owner, origins, evidence.correspondence);
    const proof = try source.own(Evidence, owner, evidence);
    return .{
        .program = records,
        .parameters = bindings,
        .evidence = proof,
        .arena = result,
        .outcome = outcome,
        .statistics = stats,
    };
}

fn relocate(
    a: Allocator,
    parameters_in: []const source.RecoveryBinding,
    map: Correspondence,
) ![]const source.RecoveryBinding {
    var bindings: std.ArrayList(source.RecoveryBinding) = .empty;
    errdefer bindings.deinit(a);
    for (parameters_in) |binding| if (try binding.relocated(map)) |mapped| {
        try bindings.append(a, mapped);
    };
    return bindings.toOwnedSlice(a);
}

fn evidenceSize(evidence: Evidence, limit: usize, work: *u64) !usize {
    const available = @min(limit, work.*);
    var remaining: u64 = available;
    var size: data.wire.Writer = .{ .remaining = &remaining };
    try data.record.write(Evidence, evidence, &size);
    work.* -= available - remaining;
    return size.position;
}

pub fn parameters(
    a: Allocator,
    module: source.Module,
    program: Program,
    evidence: Evidence,
    options: Options,
) ![]const source.RecoveryBinding {
    try requirements(module, options);
    if (evidence.rule != options.rule) return error.UnsupportedVersion;
    if (evidence.witnesses.len > options.limits.rule.witnesses) return error.ScalarFieldLimit;
    var lowering_bytes = options.limits.lowering_bytes;
    var mandatory: data.AllocationBudget = .{
        .parent = a,
        .remaining = &lowering_bytes,
        .accounting = .live,
    };
    const preparation = mandatory.allocator();
    var remaining = options.limits.rule.temporary_bytes;
    var storage: data.AllocationBudget = .{ .parent = a, .remaining = &remaining };
    const work = storage.allocator();
    var budget = reuse.Budget.init(options.limits.rule);
    _ = try evidenceSize(evidence, options.limits.evidence_bytes, &budget.remaining);
    var source_work = options.limits.source_work;
    var original = try lowering.lowerRecoveryInputWithWork(preparation, module, &source_work);
    defer original.deinit();
    var scratch = std.heap.ArenaAllocator.init(work);
    defer scratch.deinit();
    const ctx: Context = .{
        .a = work,
        .original = &original,
        .options = options,
        .module = module,
        .budget = &budget,
    };
    const s = try ctx.checked(scratch.allocator(), evidence.witnesses);
    var baseline = try structural(preparation, &original, options.limits);
    defer baseline.deinit();
    try ctx.composed(baseline.recovery_evidence.?.correspondence, s, program, evidence);
    return relocate(a, original.parameters, evidence.correspondence);
}

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    evidence: Evidence,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decode(a: Allocator, bytes: []const u8, limits: Limits) !Decoded {
    if (bytes.len > limits.evidence_bytes or bytes.len > limits.rule.work)
        return error.ScalarFieldLimit;
    var reader: data.wire.Reader = .{ .input = bytes };
    if (try reader.natural() != @backingInt(Rule.scalar_field_reuse_v1))
        return error.UnsupportedVersion;
    if (try reader.count() > limits.rule.witnesses) return error.ScalarFieldLimit;
    reader.position = 0;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var capacity = @min(limits.evidence_bytes, limits.rule.temporary_bytes);
    const evidence = try data.record.readBounded(Evidence, &reader, arena.allocator(), &capacity);
    try reader.finish();
    return .{ .arena = arena, .evidence = evidence };
}
