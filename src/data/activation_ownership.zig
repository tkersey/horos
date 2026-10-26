// Copyright (c) 2026 Boundary contributors. MIT license.
//! Compose independently derived stable-slot facts with use/capture contracts.
//! Borrow provenance and dynamic State admission remain separate obligations.
const std = @import("std");
const admission = @import("admission.zig");
const p = @import("program.zig");
const ir = @import("activation.zig");
const flow = @import("activation_flow.zig");
const types = @import("activation_types.zig");
const contracts = @import("contracts.zig");
const effect_scope = @import("effect_scope.zig");
const sets = @import("analysis_sets.zig");
const provenance = @import("control_provenance.zig");
pub const Error = types.Error || flow.Error;

/// All facts are derived inside this call from the same immutable input. A caller
/// cannot supply a live map or a weaker capture summary as proof of the program.
pub fn analyze(allocator: std.mem.Allocator, image: ir.Program) Error!flow.Facts {
    return analyzeDiagnosed(allocator, image, null);
}

/// Observes the same retained slots checked below; supplies no admission facts.
pub const CaptureObserver = struct {
    context: *anyopaque,
    capture: *const fn (*anyopaque, p.Id, *const CaptureSite, p.Id) void,
    /// Null presentation reports unavailable rendering, not unknown semantics.
    explanation: ?*const fn (
        *anyopaque,
        p.Id,
        *const CaptureSite,
        p.Id,
        ?CaptureExplanation,
    ) void = null,
    /// Borrow the already checked immutable provenance owner until return.
    analyzed: ?*const fn (*anyopaque, *const provenance.Analysis) void = null,
};
pub const CaptureSite = provenance.Selection;
pub const CaptureExplanation = provenance.Explanation;
pub fn analyzeObserved(
    allocator: std.mem.Allocator,
    image: ir.Program,
    diagnostic: ?*@import("admission.zig").Diagnostic,
    observer: ?CaptureObserver,
) Error!flow.Facts {
    return analyzeObservedWithWork(allocator, image, diagnostic, observer, null);
}

pub fn analyzeObservedWithWork(
    allocator: std.mem.Allocator,
    image: ir.Program,
    diagnostic: ?*@import("admission.zig").Diagnostic,
    observer: ?CaptureObserver,
    work: ?*u64,
) Error!flow.Facts {
    try admission.spend(work, 1);
    return analyzeInternal(allocator, image, &.{}, false, &.{}, diagnostic, observer, work);
}

pub fn analyzeDiagnosed(
    allocator: std.mem.Allocator,
    image: ir.Program,
    diagnostic: ?*@import("admission.zig").Diagnostic,
) Error!flow.Facts {
    return analyzeInternal(allocator, image, &.{}, false, &.{}, diagnostic, null, null);
}

pub fn analyzeComponent(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    borrows: []const @import("borrow_contract.zig").Summary,
) Error!flow.Facts {
    return analyzeInternal(allocator, image, imports, true, borrows, null, null, null);
}

fn analyzeInternal(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    component: bool,
    borrows: []const @import("borrow_contract.zig").Summary,
    diagnostic: ?*@import("admission.zig").Diagnostic,
    observer: ?CaptureObserver,
    work: ?*u64,
) Error!flow.Facts {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const contextual = try types.validateWithObservedFactsAndWork(
        scratch,
        image,
        imports,
        component,
        borrows,
        diagnostic,
        if (observer) |o| o.explanation != null else false,
        work,
    );
    var facts = try flow.analyzeComponentWithWork(allocator, image, imports, work);
    errdefer facts.deinit();
    facts.pool.work = work;
    defer facts.pool.work = null;
    var checker: Check = .{
        .image = image,
        .work = work,
        .observer = observer,
        .diagnostic = diagnostic,
        .facts = &facts,
        .uses = contextual.uses,
        .effects = contextual.effects,
        .provenance = contextual.control,
    };
    for (image.blocks, 0..) |block, id| {
        try admission.spend(work, 1);
        if (facts.entries[id] == null) continue;
        if (diagnostic) |d| d.* = .{
            .phase = .block,
            .function = block.function,
            .block = id,
            .callee = if (block.terminator == .call) block.terminator.call.function else null,
        };
        if (block.terminator == .return_value) {
            var obligations = facts.positions[id][block.instructions.len].obligations;
            obligations = try facts.pool.remove(obligations, block.terminator.return_value);
            if (obligations != sets.empty) return error.InvalidOwnership;
        }
        checker.boundary = .{ .block = id, .role = .callee };
        try checker.block(block);
    }
    if (observer) |o| if (o.analyzed) |receive| receive(o.context, contextual.control);
    return facts;
}

const Check = struct {
    work: ?*u64 = null,
    image: ir.Program,
    observer: ?CaptureObserver = null,
    function: p.Id = 0,
    diagnostic: ?*@import("admission.zig").Diagnostic = null,
    facts: *flow.Facts,
    uses: @import("traits.zig").Facts,
    effects: effect_scope.Facts,
    provenance: *const provenance.Analysis,
    boundary: provenance.Boundary = undefined,

    fn computation(self: Check, slots: []const p.Id, slot: p.Id) Error!p.ComputationType {
        try admission.spend(self.work, 1);
        return contracts.computation(self.image, slots[@intCast(slot)]);
    }

    fn resumption(self: Check, slots: []const p.Id, slot: p.Id) Error!p.ResumptionType {
        try admission.spend(self.work, 1);
        return contracts.resumption(self.image, slots[@intCast(slot)]);
    }

    fn block(self: *Check, code: ir.Block) Error!void {
        try admission.spend(self.work, 1);
        self.function = code.function;
        const slots = self.image.functions[@intCast(code.function)].layout.slots;
        switch (code.terminator) {
            .call => |call| try self.control(
                slots,
                self.image.functions[@intCast(call.function)].effects,
                call.next,
                .callee,
            ),
            .perform => |perform| {
                try self.control(slots, &.{perform.effect}, perform.next, .operation);
                const effect = self.image.effects[@intCast(perform.effect)];
                try self.control(slots, effect.use_site_effects, perform.next, .injected);
            },
            .apply => |apply| try self.control(
                slots,
                (try self.computation(slots, apply.computation)).effects,
                apply.next,
                .callee,
            ),
            .handle => |handle| try self.checkHandler(slots, handle),
            .resume_value => |operation| try self.control(
                slots,
                (try self.resumption(slots, operation.resumption)).effects,
                operation.next,
                .resumed,
            ),
            .resume_computation => |operation| {
                const token = try self.resumption(slots, operation.resumption);
                try self.control(slots, token.effects, operation.next, .resumed);
                try self.provenance.capturesInjected(
                    .{ .block = self.boundary.block, .role = .injected },
                    token,
                    self.uses,
                );
            },
            .resume_with => |operation| try self.resumeWith(slots, operation),
            .with_region => |region| try self.control(
                slots,
                (try self.computation(slots, region.body)).effects,
                region.next,
                .body,
            ),
            .protect => |protect| {
                try self.control(
                    slots,
                    (try self.computation(slots, protect.body)).effects,
                    protect.next,
                    .body,
                );
                try self.control(
                    slots,
                    (try self.computation(slots, protect.cleanup)).effects,
                    protect.next,
                    .cleanup,
                );
            },
            .dispose => |dispose| try self.control(
                slots,
                (try self.resumption(slots, dispose.owned)).effects,
                dispose.next,
                .resumed,
            ),
            else => {},
        }
    }

    fn checkHandler(self: *Check, slots: []const p.Id, operation: anytype) Error!void {
        try admission.spend(self.work, 1);
        const handler = self.image.handlers[@intCast(operation.handler)];
        const signature = try self.computation(slots, operation.body);
        const body_effects = try self.provenance.effectRow(
            .{ .block = self.boundary.block, .role = .body },
            signature.effects,
        );
        for (body_effects) |effect| {
            try admission.spend(self.work, 1);
            if (try contracts.containsEffectWithWork(signature.effects, effect, self.work) and
                try effect_scope.dischargedWithWork(
                    self.image,
                    self.effects,
                    handler,
                    signature,
                    effect,
                    self.work,
                ))
                continue;
            try self.controlEffects(slots, &.{effect}, operation.next, .body);
            const selected = try self.provenance.select(
                .{ .block = self.boundary.block, .role = .body },
                effect,
            );
            for (operation.state) |slot| {
                try admission.spend(self.work, 1);
                try self.capture(slots, selected, slot);
            }
        }
        try self.control(slots, handler.effects, operation.next, .handler);
    }

    fn resumeWith(self: *Check, slots: []const p.Id, operation: anytype) Error!void {
        try admission.spend(self.work, 1);
        const signature = try self.resumption(slots, operation.resumption);
        const successor = self.image.handlers[@intCast(operation.handler)];
        const effects = try self.provenance.effectRow(
            .{ .block = self.boundary.block, .role = .resumed },
            signature.effects,
        );
        for (effects) |effect| {
            try admission.spend(self.work, 1);
            const escapes = !try contracts.containsEffectWithWork(
                signature.handled,
                effect,
                self.work,
            ) or
                try contracts.containsEffectWithWork(signature.escaping, effect, self.work);
            if (try contracts.containsEffectWithWork(
                signature.effects,
                effect,
                self.work,
            ) and !escapes) continue;
            try self.controlEffects(slots, &.{effect}, operation.next, .resumed);
            const selected = try self.provenance.select(
                .{ .block = self.boundary.block, .role = .resumed },
                effect,
            );
            for (operation.state) |slot| {
                try admission.spend(self.work, 1);
                try self.capture(slots, selected, slot);
            }
        }
        try self.control(slots, successor.effects, operation.next, .handler);
    }

    fn retained(self: *Check, next: ir.Edge) Error!sets.Root {
        try admission.spend(self.work, 1);
        const pool = self.facts.pool;
        const after = self.facts.live[@intCast(next.block)][0];
        var result = after;
        for (next.assignments) |assignment| {
            try admission.spend(self.work, 1);
            result = try pool.remove(result, assignment.destination);
        }
        for (next.assignments) |assignment| {
            try admission.spend(self.work, 1);
            if (assignment.source == .slot and pool.contains(after, assignment.destination))
                result = try pool.insert(result, assignment.source.slot);
        }
        return result;
    }

    fn control(
        self: *Check,
        slots: []const p.Id,
        effects: []const p.Id,
        next: ir.Edge,
        role: provenance.Role,
    ) Error!void {
        try admission.spend(self.work, 1);
        const qualified = try self.provenance.effectRow(
            .{ .block = self.boundary.block, .role = role },
            effects,
        );
        return self.controlEffects(slots, qualified, next, role);
    }

    fn controlEffects(
        self: *Check,
        slots: []const p.Id,
        effects: []const p.Id,
        next: ir.Edge,
        role: provenance.Role,
    ) Error!void {
        try admission.spend(self.work, 1);
        if (effects.len == 0) return;
        const root = try self.retained(next);
        for (effects) |effect| {
            try admission.spend(self.work, 1);
            const selected = try self.provenance.select(
                .{ .block = self.boundary.block, .role = role },
                effect,
            );
            var live = self.facts.pool.iterator(root);
            while (live.next()) |slot| {
                try admission.spend(self.work, 1);
                try self.capture(slots, selected, slot);
            }
        }
    }

    fn capture(
        self: Check,
        slots: []const p.Id,
        selected: *const CaptureSite,
        slot: p.Id,
    ) Error!void {
        try admission.spend(self.work, 1);
        if (self.diagnostic) |d| {
            d.slot = slot;
            d.effect = selected.effect();
        }
        const allowed = try selected.captureAllowed(self.uses, slots[@intCast(slot)]);
        if (self.observer) |observer| {
            observer.capture(observer.context, self.function, selected, slot);
            if (observer.explanation) |explain| {
                var presentation: ?CaptureExplanation = self.provenance.explain(
                    selected,
                ) catch |err| switch (err) {
                    error.RelationLimit => return err,
                    else => null,
                };
                if (presentation) |*value| value.capture_constraint = .{
                    .slot = slot,
                    .schema = slots[@intCast(slot)],
                    .satisfied = allowed,
                };
                explain(observer.context, self.function, selected, slot, presentation);
            }
        }
        if (!allowed) return error.InvalidOwnership;
    }
};
