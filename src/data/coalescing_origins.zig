// Copyright (c) 2026 Boundary contributors. MIT license.
//! Temporary original-input provenance. No AST, wire record, or runtime identity.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const witness = @import("coalescing_witness.zig");
const admission = @import("admission.zig");
pub const Error = witness.Error;
const Region = struct { original: p.Id, current: p.Id };
const Local = struct { slots: []p.Id, custody: []p.Id };
pub const Diagnostic = struct {
    stage: enum { original, baseline, transformation, candidate, mapping, cost } = .original,
    code: ?anyerror = null,
    target: admission.Diagnostic = .{},
    origins: admission.Origins = .{},
    /// Input-layout slot for the reported representative, not a lexical variable.
    original_slot: ?p.Id = null,
    original_block: ?p.Id = null,
};

/// The caller's input remains borrowed for the duration of optimization only.
/// Maps use original IDs as domains, so later rounds cannot erase earlier aliases.
pub const Trace = struct {
    arena: std.heap.ArenaAllocator,
    original: ir.Program,
    maps: [r.kind_count][]p.Id,
    regions: []Region,
    locals: []Local,

    pub fn map(self: *const Trace, kind: r.Kind) []const p.Id {
        return self.maps[@backingInt(kind)];
    }
    pub fn resolve(self: *const Trace, kind: r.Kind, original: p.Id) ?p.Id {
        if (kind == .region) {
            for (self.regions) |region|
                if (region.original == original) return region.current;
            return null;
        }
        const ids = self.map(kind);
        if (original >= ids.len or ids[@intCast(original)] == r.missing) return null;
        return ids[@intCast(original)];
    }

    pub fn init(
        allocator: std.mem.Allocator,
        original: ir.Program,
        projection: r.Projection,
    ) Error!Trace {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const projected = projection.maps orelse return error.InvalidCorrespondence;
        // Declared regions may be sparse and enormous. Reuse the projection's
        // live sparse region map rather than allocating region_count entries.
        const counts = [_]usize{
            original.schemas.len,
            original.constants.len,
            original.effects.len,
            original.functions.len,
            original.blocks.len,
            original.handlers.len,
            original.scopes.captures.len,
            0,
            original.scopes.resources.len,
            original.constructors.len,
        };
        var maps: [r.kind_count][]p.Id = undefined;
        for (&maps, projected, counts) |*owned, old, count| {
            if (old.len != count) return error.InvalidCorrespondence;
            owned.* = try a.dupe(p.Id, old);
        }
        const regions = try a.alloc(Region, projection.regions.count());
        var iterator = projection.regions.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            regions[index] = .{ .original = entry.key_ptr.*, .current = entry.value_ptr.* };
        }
        const locals = try a.alloc(Local, original.functions.len);
        const functions = maps[@backingInt(r.Kind.function)];
        for (locals, functions, original.functions) |*local, function, code| {
            local.slots = try identity(a, if (function == r.missing) 0 else code.layout.slots.len);
            local.custody = try identity(a, if (function == r.missing) 0 else code.custody.len);
        }
        return .{
            .arena = arena,
            .original = original,
            .maps = maps,
            .regions = regions,
            .locals = locals,
        };
    }

    pub fn deinit(self: *Trace) void {
        self.arena.deinit();
        self.* = undefined;
    }
    /// Validate the entire transition before mutating a diagnostic map. The
    /// selected witness is already checked, but stale context remains an error.
    pub fn advance(self: *Trace, next: witness.Witness) Error!void {
        for (self.map(.function), self.locals) |function, local| {
            if (function == r.missing) continue;
            if (function >= next.locals.len) return error.InvalidCorrespondence;
            const target = next.locals[@intCast(function)];
            for (local.slots) |slot| if (slot >= target.slots.len)
                return error.InvalidCorrespondence;
            for (local.custody) |scope| if (scope >= target.custody.len)
                return error.InvalidCorrespondence;
        }
        for (self.maps, 0..) |ids, kind| for (ids) |id| if (id != r.missing) {
            _ = try mapped(next.final, @fromBackingInt(@intCast(kind)), id);
        };
        for (self.regions) |region| _ = try mapped(next.final, .region, region.current);
        // No mutation precedes the complete domain check above.
        for (self.map(.function), self.locals) |function, local| {
            if (function == r.missing) continue;
            const target = next.locals[@intCast(function)];
            for (local.slots) |*slot| slot.* = target.slots[@intCast(slot.*)];
            for (local.custody) |*scope| scope.* = target.custody[@intCast(scope.*)];
        }
        for (self.maps, next.final) |ids, next_ids| for (ids) |*id| if (id.* != r.missing) {
            id.* = next_ids[@intCast(id.*)];
        };
        for (self.regions) |*region|
            region.current = next.final[@backingInt(r.Kind.region)][@intCast(region.current)];
    }
    /// `next` is supplied only after raw-record validation, for an admission
    /// failure in a not-yet-selected candidate. No provisional discovery is trusted.
    pub fn explain(self: *const Trace, next: ?witness.Witness, diagnostic: *Diagnostic) void {
        diagnostic.origins = .{};
        diagnostic.original_slot = null;
        diagnostic.original_block = null;
        if (diagnostic.target.phase == .constructor) {
            for (self.original.constructors, self.map(.constructor)) |constructor, live| {
                if (live == r.missing) continue;
                if (self.matches(
                    next,
                    .function,
                    constructor.function,
                    diagnostic.target.function,
                ) and
                    self.matches(next, .capture, constructor.capture, diagnostic.target.capture) and
                    self.matches(next, .schema, constructor.schema, diagnostic.target.schema))
                    diagnostic.origins.add(constructor.function);
            }
        } else if (diagnostic.target.function) |actual| {
            for (self.map(.function), 0..) |current, original| {
                if (current == r.missing or finalId(next, .function, current) != actual) continue;
                diagnostic.origins.add(original);
            }
        } else if (diagnostic.target.capture) |actual| {
            for (self.original.constructors, self.map(.constructor)) |constructor, live| {
                if (live == r.missing) continue;
                if (constructor.capture >= self.map(.capture).len) continue;
                const current = self.map(.capture)[@intCast(constructor.capture)];
                if (current == r.missing or finalId(next, .capture, current) != actual) continue;
                if (constructor.function >= self.map(.function).len or
                    self.map(.function)[@intCast(constructor.function)] == r.missing) continue;
                diagnostic.origins.add(constructor.function);
            }
        }
        self.explainSlot(next, diagnostic);
        if (diagnostic.target.block) |actual| {
            if (diagnostic.origins.count == 0) return;
            const function = diagnostic.origins.functions[0];
            for (self.map(.block), self.original.blocks, 0..) |current, block, old| {
                if (block.function == function and current != r.missing and
                    finalId(next, .block, current) == actual)
                {
                    diagnostic.original_block = old;
                    break;
                }
            }
        }
    }
    fn matches(
        self: *const Trace,
        next: ?witness.Witness,
        comptime kind: r.Kind,
        old: p.Id,
        expected: ?p.Id,
    ) bool {
        const ids = self.map(kind);
        if (old >= ids.len or ids[@intCast(old)] == r.missing) return false;
        const final = finalId(next, kind, ids[@intCast(old)]) orelse return false;
        return expected == null or final == expected.?;
    }
    fn explainSlot(self: *const Trace, next: ?witness.Witness, diagnostic: *Diagnostic) void {
        const actual = diagnostic.target.slot orelse return;
        if (diagnostic.origins.count == 0) return;
        const original: usize = @intCast(diagnostic.origins.functions[0]);
        const current = self.map(.function)[original];
        for (self.locals[original].slots, 0..) |slot, input_slot| {
            const final = if (next) |step| blk: {
                if (current >= step.locals.len) return;
                const locals = step.locals[@intCast(current)].slots;
                if (slot >= locals.len) return;
                break :blk locals[@intCast(slot)];
            } else slot;
            if (final == actual) {
                diagnostic.original_slot = input_slot;
                return;
            }
        }
    }
};

fn identity(a: std.mem.Allocator, count: usize) Error![]p.Id {
    const result = try a.alloc(p.Id, count);
    for (result, 0..) |*id, index| id.* = index;
    return result;
}

fn mapped(maps: r.Maps, kind: r.Kind, old: p.Id) Error!p.Id {
    const map = maps[@backingInt(kind)];
    if (old >= map.len or map[@intCast(old)] == r.missing) return error.InvalidCorrespondence;
    return map[@intCast(old)];
}
fn finalId(next: ?witness.Witness, kind: r.Kind, old: p.Id) ?p.Id {
    return if (next) |map| mapped(map.final, kind, old) catch null else old;
}

pub fn explainOriginal(original: ir.Program, diagnostic: *Diagnostic) void {
    diagnostic.origins = .{};
    if (diagnostic.target.function) |function| {
        if (function < original.functions.len) diagnostic.origins.add(function);
    } else if (diagnostic.target.capture) |capture| {
        for (original.constructors) |constructor|
            if (constructor.capture == capture and constructor.function < original.functions.len)
                diagnostic.origins.add(constructor.function);
    }
    diagnostic.original_slot = diagnostic.target.slot;
    diagnostic.original_block = diagnostic.target.block;
}
