// Copyright (c) 2026 Boundary contributors. MIT license.
//! Lexically admitted region dependencies, independent of runtime identities.
const std = @import("std");
const p = @import("program.zig");
const a = @import("admission.zig");
const contracts = @import("contracts.zig");

pub fn catalogWithWork(image: anytype, regions: []const p.Id, work: ?*u64) a.Error!void {
    try a.spend(work, 1);
    for (regions, 0..) |id, index| {
        try a.spend(work, 1);
        if (id >= image.scopes.region_count) return error.InvalidReference;
        if (index > 0 and regions[index - 1] >= id) return error.NonCanonical;
    }
}

pub const Dependencies = struct {
    work: ?*u64 = null,
    regions: []const p.Id,
    values: []bool,
    fn of(self: Dependencies, schema: p.Id) []bool {
        const width = self.regions.len;
        return self.values[@as(usize, @intCast(schema)) * width ..][0..width];
    }
    fn contains(self: Dependencies, schema: p.Id, region: p.Id) a.Error!bool {
        for (self.regions, 0..) |id, index| {
            try a.spend(self.work, 1);
            if (id == region) return self.of(schema)[index];
        }
        return false;
    }
};

/// Only referenced nominal regions occupy columns. An ordinal upper bound is
/// not a request to allocate one entry for every unused name below that bound.
pub fn dependenciesWithWork(
    allocator: std.mem.Allocator,
    image: anytype,
    work: ?*u64,
) a.Error!Dependencies {
    try a.spend(work, 1);
    var regions: std.ArrayList(p.Id) = .empty;
    var indices: std.AutoHashMapUnmanaged(p.Id, usize) = .empty;
    for (image.schemas) |shape| {
        try a.spend(work, 1);
        if (shape == .internal) {
            const id = switch (shape.internal) {
                .region => |id| id,
                .cell => |cell| cell.region,
                .borrowed => |borrow| borrow.region,
                else => continue,
            };
            if (id >= image.scopes.region_count) return error.InvalidReference;
            const entry = try indices.getOrPut(allocator, id);
            if (!entry.found_existing) {
                entry.value_ptr.* = regions.items.len;
                try regions.append(allocator, id);
            }
        }
    }
    const width = regions.items.len;
    const length = std.math.mul(usize, image.schemas.len, width) catch
        return error.InvalidLength;
    try a.spend(work, length);
    const result = try allocator.alloc(bool, length);
    @memset(result, false);
    var changed = true;
    while (changed) {
        try a.spend(work, 1);
        changed = false;
        for (image.schemas, 0..) |shape, schema| {
            try a.spend(work, 1);
            changed = try propagateDependencies(
                shape,
                result[schema * width ..][0..width],
                result,
                regions.items,
                indices,
                work,
            ) or changed;
        }
    }
    return .{ .regions = regions.items, .values = result, .work = work };
}

fn propagateDependencies(
    shape: p.Schema,
    target: []bool,
    result: []const bool,
    regions: []const p.Id,
    indices: std.AutoHashMapUnmanaged(p.Id, usize),
    work: ?*u64,
) a.Error!bool {
    try a.spend(work, 1);
    const width = regions.len;
    var changed = false;
    const fields: []const p.Id = switch (shape) {
        .product, .sum => |fields| fields,
        .seq => |*element| element[0..1],
        .vector => |*vector| (&vector.element)[0..1],
        .array => |*array| (&array.element)[0..1],
        .internal => |*internal| switch (internal.*) {
            .region, .cell, .borrowed => blk: {
                const id = switch (internal.*) {
                    .region => |id| id,
                    .cell => |cell| cell.region,
                    .borrowed => |borrow| borrow.region,
                    else => unreachable,
                };
                const index = indices.get(id) orelse return error.InvalidReference;
                if (!target[index]) {
                    target[index] = true;
                    changed = true;
                }
                break :blk switch (internal.*) {
                    .cell => |*cell| (&cell.element)[0..1],
                    .borrowed => |*borrow| (&borrow.value)[0..1],
                    else => &.{},
                };
            },
            .computation => |signature| signature.capture_bound,
            .resumption => |signature| signature.capture_bound,
            .suspension_package => |*inner| inner[0..1],
            else => &.{},
        },
        else => &.{},
    };
    for (fields) |child| {
        try a.spend(work, 1);
        for (
            target,
            result[@as(usize, @intCast(child)) * width ..][0..width],
            0..,
        ) |*to, from, region_id| {
            try a.spend(work, 1);
            if (shape == .internal and shape.internal == .resumption and
                try contracts.containsEffectWithWork(
                    shape.internal.resumption.owned_regions,
                    regions[region_id],
                    work,
                )) continue;
            if (from and !to.*) {
                to.* = true;
                changed = true;
            }
        }
    }
    return changed;
}

pub fn validate(allocator: std.mem.Allocator, image: anytype) a.Error!void {
    return validateDiagnosedWithWork(allocator, image, null, null);
}

pub fn validateDiagnosedWithWork(
    allocator: std.mem.Allocator,
    image: anytype,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    if (diagnostic) |d| d.* = .{ .phase = .region };
    const deps = try dependenciesWithWork(allocator, image, work);
    for (image.functions, 0..) |function, index| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{ .phase = .region, .function = index };
        try catalogWithWork(image, function.regions, work);
        const parameters = @import("function_inputs.zig").of(function);
        for (0..parameters.len) |parameter| {
            try a.spend(work, 1);
            try allowed(deps, parameters.at(parameter), function.regions, work);
        }
        for (function.layout.slots) |schema| {
            try a.spend(work, 1);
            try allowed(deps, schema, function.regions, work);
        }
        try allowed(deps, function.result, function.regions, work);
    }
    for (image.blocks, 0..) |block, index| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{
            .phase = .region,
            .function = block.function,
            .block = index,
            .terminator = std.meta.activeTag(block.terminator),
            .callee = if (block.terminator == .call) block.terminator.call.function else null,
        };
        try validateBlock(image, block, deps, work);
    }
}

fn validateBlock(image: anytype, block: anytype, deps: Dependencies, work: ?*u64) a.Error!void {
    const regions = image.functions[@intCast(block.function)].regions;

    switch (block.terminator) {
        .call => |call| try contracts.subsetWithWork(
            image.functions[@intCast(call.function)].regions,
            regions,
            work,
        ),
        .handle => |handle| {
            const handler = image.handlers[@intCast(handle.handler)];
            try contracts.subsetWithWork(
                image.functions[@intCast(handler.return_function)].regions,
                regions,
                work,
            );
            for (handler.clauses) |clause| {
                try a.spend(work, 1);
                try contracts.subsetWithWork(
                    image.functions[@intCast(clause.function)].regions,
                    regions,
                    work,
                );
            }
        },
        .with_region => |scope| {
            const body_schema = try codeSlot(image, block, scope.body);
            const body = try contracts.computation(image, body_schema);
            if (try deps.contains(body.result, scope.region)) return error.InvalidOwnership;
        },
        .protect => |protection| if (protection.loan_region) |region| {
            const schema = try codeSlot(image, block, protection.body);
            const body = try contracts.computation(image, schema);
            if (try deps.contains(body.result, region)) return error.InvalidOwnership;
        },
        .resume_with => |resuming| {
            const successor = image.handlers[@intCast(resuming.handler)];
            try contracts.subsetWithWork(
                image.functions[@intCast(successor.return_function)].regions,
                regions,
                work,
            );
            for (successor.clauses) |clause| {
                try a.spend(work, 1);
                try contracts.subsetWithWork(
                    image.functions[@intCast(clause.function)].regions,
                    regions,
                    work,
                );
            }
        },
        else => {},
    }
}

fn codeSlot(image: anytype, block: anytype, slot: p.Id) a.Error!p.Id {
    return a.slotType(image.functions[@intCast(block.function)].layout.slots, slot);
}

fn allowed(deps: Dependencies, schema: p.Id, regions: []const p.Id, work: ?*u64) a.Error!void {
    try a.spend(work, 1);
    for (deps.of(schema), deps.regions) |needed, id| {
        try a.spend(work, 1);
        if (needed and !(try contracts.containsEffectWithWork(
            regions,
            id,
            work,
        ))) return error.InvalidOwnership;
    }
}

pub fn instructionWithWork(
    image: anytype,
    op: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    if (op.immediate != 0) return error.InvalidProgram;
    const operands = op.operands;
    if (op.opcode == .cell_new) {
        if (operands.len != 2) return error.TypeMismatch;
        const shape = image.schemas[@intCast(op.result_type)];
        if (shape != .internal or shape.internal != .cell) return error.TypeMismatch;
        const cell = shape.internal.cell;
        const region = image.schemas[@intCast(slots[@intCast(operands[0])])];
        if (region != .internal or
            region.internal != .region or
            region.internal.region != cell.region or
            slots[
                @intCast(operands[1])
            ] != cell.element)
            return error.TypeMismatch;
    } else {
        if (operands.len != @as(
            usize,
            if (op.opcode == .cell_get) 1 else 2,
        )) return error.TypeMismatch;
        const shape = image.schemas[@intCast(slots[@intCast(operands[0])])];
        if (shape != .internal or shape.internal != .cell) return error.TypeMismatch;
        const cell = shape.internal.cell;
        if (!uses.copy[@intCast(cell.element)]) return error.InvalidOwnership;
        if (op.opcode == .cell_get) {
            if (op.result_type != cell.element) return error.TypeMismatch;
        } else if (slots[
            @intCast(operands[1])
        ] != cell.element or image.schemas[
            @intCast(op.result_type)
        ] != .unit) return error.TypeMismatch;
    }
}

pub fn catalog(image: anytype, regions: []const p.Id) a.Error!void {
    return catalogWithWork(image, regions, null);
}

pub fn dependencies(allocator: std.mem.Allocator, image: anytype) a.Error!Dependencies {
    return dependenciesWithWork(allocator, image, null);
}

pub fn validateDiagnosed(
    allocator: std.mem.Allocator,
    image: anytype,
    diagnostic: ?*a.Diagnostic,
) a.Error!void {
    return validateDiagnosedWithWork(allocator, image, diagnostic, null);
}

pub fn instruction(
    image: anytype,
    op: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
) a.Error!void {
    return instructionWithWork(image, op, slots, uses, null);
}
