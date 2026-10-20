// Copyright (c) 2026 Boundary contributors. MIT license.
//! Dead capture removal for private, locally applied constructor environments.
//! Preserve evaluations, explicit arguments, ownership flags and nominal regions.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const access = @import("slot_access.zig").terminator;
const coalescing = @import("coalescing.zig");
pub const Error = coalescing.Error || error{InvalidCaptureReduction};
pub const Witness = struct { constructor: usize, removed: []const usize };
pub const Statistics = struct {
    constructors_reduced: usize = 0,
    fields_removed: usize = 0,
    construction_operands_removed: usize = 0,
    direct_arguments_removed: usize = 0,
    opaque_constructors: usize = 0,
};

pub fn privateWorker(program: ir.Program, constructor_id: usize) bool {
    const worker = program.constructors[constructor_id].function;
    for (
        program.constructors,
        0..,
    ) |other, id| if (id != constructor_id and other.function == worker) return false;
    return privateFunction(program, worker);
}

pub fn privateDirectWorker(program: ir.Program, worker: p.Id) bool {
    if (worker >= program.functions.len) return false;
    for (program.constructors) |constructor| if (constructor.function == worker) return false;
    return privateFunction(program, worker);
}

fn privateFunction(program: ir.Program, worker: p.Id) bool {
    if (program.roots.entry == worker) return false;
    for (program.handlers) |handler| {
        if (handler.return_function == worker) return false;
        for (handler.clauses) |clause| if (clause.function == worker) return false;
    }
    for (program.scopes.resources) |resource| {
        for (resource.introducers) |id| if (id == worker) return false;
        for (resource.eliminators) |id| if (id == worker) return false;
    }
    return true;
}

/// Every construction's slot has one definition, no aliases and only apply uses.
/// This permits repeated applications while keeping opaque environments intact.
pub fn privateConstructions(program: ir.Program, constructor_id: usize) bool {
    var constructions: usize = 0;
    for (program.blocks) |block|
        for (block.instructions) |op| {
            if (op.opcode != .computation or op.immediate != constructor_id) continue;
            constructions += 1;
            const slot = op.destination;
            if (std.mem.indexOfScalar(
                p.Id,
                program.functions[@intCast(block.function)].inputs,
                slot,
            ) != null) return false;
            var definitions: usize = 0;
            var applications: usize = 0;
            for (program.blocks) |other| {
                if (other.function != block.function) continue;
                for (other.instructions) |instruction| {
                    if (instruction.destination == slot) definitions += 1;
                    if (std.mem.indexOfScalar(p.Id, instruction.operands, slot) != null)
                        return false;
                }
                const uses = access(other.terminator, slot);
                const application = other.terminator == .apply and
                    other.terminator.apply.computation == slot;
                if (uses.writes != 0 or uses.reads != @intFromBool(application)) return false;
                if (application) applications += 1;
            }
            if (definitions != 1 or applications == 0) return false;
        };
    return constructions != 0;
}

fn without(
    allocator: std.mem.Allocator,
    values: []const p.Id,
    removed: []const usize,
) std.mem.Allocator.Error![]const p.Id {
    const result = try allocator.alloc(p.Id, values.len - removed.len);
    var next: usize = 0;
    for (values, 0..) |value, index| {
        if (std.mem.indexOfScalar(usize, removed, index) != null) continue;
        result[next] = value;
        next += 1;
    }
    return result;
}
fn subsequence(before: []const p.Id, after: []const p.Id, removed: []const usize) bool {
    var next: usize = 0;
    var erased: usize = 0;
    for (before, 0..) |value, index| {
        if (erased < removed.len and removed[erased] == index) {
            erased += 1;
        } else {
            if (next >= after.len or after[next] != value) return false;
            next += 1;
        }
    }
    return next == after.len and erased == removed.len;
}

pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: coalescing.Options,
) Error!coalescing.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var admitted = try ownership.analyze(allocator, original);
    defer admitted.deinit();
    var flow = try @import("activation_flow.zig").analyzeInputDemand(allocator, original);
    defer flow.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    var witnesses: std.ArrayList(Witness) = .empty;
    for (original.constructors, 0..) |constructor, id| {
        const capture = original.scopes.captures[@intCast(constructor.capture)];
        if (capture.fields.len == 0) continue;
        if (!privateWorker(original, id) or !privateConstructions(original, id)) {
            stats.opaque_constructors += 1;
            continue;
        }
        const worker = original.functions[@intCast(constructor.function)];
        var removed: std.ArrayList(usize) = .empty;
        for (capture.fields, 0..) |schema, index| {
            if (!permissions.copy[
                @intCast(schema)
            ] or !permissions.drop[
                @intCast(schema)
            ] or flow.pool.contains(
                flow.live[@intCast(worker.entry)][0],
                worker.inputs[index],
            )) continue;
            try removed.append(a, index);
        }
        if (removed.items.len == 0) continue;
        stats.fields_removed += removed.items.len;
        try witnesses.append(a, .{ .constructor = id, .removed = try removed.toOwnedSlice(a) });
    }
    const functions = try a.dupe(ir.Function, original.functions);
    const constructors = try a.dupe(p.Constructor, original.constructors);
    var captures: std.ArrayList(p.Capture) = .empty;
    try captures.appendSlice(a, original.scopes.captures);
    const by_constructor = try a.alloc([]const usize, original.constructors.len);
    const by_function = try a.alloc([]const usize, original.functions.len);
    @memset(by_constructor, &.{});
    @memset(by_function, &.{});
    for (witnesses.items) |witness| {
        const constructor = original.constructors[witness.constructor];
        var capture = original.scopes.captures[@intCast(constructor.capture)];
        capture.fields = try without(a, capture.fields, witness.removed);
        constructors[witness.constructor].capture = captures.items.len;
        try captures.append(a, capture);
        functions[@intCast(constructor.function)].inputs = try without(
            a,
            functions[@intCast(constructor.function)].inputs,
            witness.removed,
        );
        by_constructor[witness.constructor] = witness.removed;
        by_function[@intCast(constructor.function)] = witness.removed;
    }
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (blocks) |*block| {
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        for (instructions) |*op| if (op.opcode == .computation and by_constructor[
            @intCast(op.immediate)
        ].len != 0) {
            const removed = by_constructor[@intCast(op.immediate)];
            op.operands = try without(a, op.operands, removed);
            stats.construction_operands_removed += removed.len;
        };
        block.instructions = instructions;
        if (block.terminator == .call and by_function[
            @intCast(block.terminator.call.function)
        ].len != 0) {
            const removed = by_function[@intCast(block.terminator.call.function)];
            block.terminator.call.arguments = try without(
                a,
                block.terminator.call.arguments,
                removed,
            );
            stats.direct_arguments_removed += removed.len;
        }
    }
    var candidate = original;
    candidate.functions = functions;
    candidate.constructors = constructors;
    candidate.scopes.captures = captures.items;
    candidate.blocks = blocks;
    try validate(allocator, original, candidate, witnesses.items);
    stats.constructors_reduced = witnesses.items.len;
    return coalescing.run(allocator, candidate, options);
}

/// Check each field/input/argument correspondence and original demand separately
/// from construction. The candidate cannot change other instructions or callers.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var admitted = try ownership.analyze(allocator, original);
    defer admitted.deinit();
    var flow = try @import("activation_flow.zig").analyzeInputDemand(allocator, original);
    defer flow.deinit();
    var checked = try ownership.analyze(allocator, candidate);
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    var same = candidate;
    same.functions = original.functions;
    same.blocks = original.blocks;
    same.constructors = original.constructors;
    same.scopes.captures = original.scopes.captures;
    if (!equal(ir.Program, original, same) or
        candidate.functions.len != original.functions.len or
        candidate.blocks.len != original.blocks.len or
        candidate.constructors.len != original.constructors.len or
        candidate.scopes.captures.len != original.scopes.captures.len + witnesses.len)
        return error.InvalidCaptureReduction;
    for (
        original.scopes.captures,
        candidate.scopes.captures[0..original.scopes.captures.len],
    ) |before, after| if (!equal(p.Capture, before, after)) return error.InvalidCaptureReduction;
    const ctor_removed = try a.alloc([]const usize, original.constructors.len);
    const fn_removed = try a.alloc([]const usize, original.functions.len);
    const mapped_capture = try a.alloc(p.Id, original.constructors.len);
    @memset(ctor_removed, &.{});
    @memset(fn_removed, &.{});
    for (
        original.constructors,
        mapped_capture,
    ) |constructor, *mapped| mapped.* = constructor.capture;
    for (witnesses, 0..) |witness, index| {
        if (witness.constructor >= original.constructors.len or
            witness.removed.len == 0 or
            ctor_removed[witness.constructor].len != 0 or
            !privateWorker(original, witness.constructor) or
            !privateConstructions(original, witness.constructor))
            return error.InvalidCaptureReduction;
        const constructor = original.constructors[witness.constructor];
        const capture = original.scopes.captures[@intCast(constructor.capture)];
        const worker = original.functions[@intCast(constructor.function)];
        for (witness.removed) |field| {
            if (field >= capture.fields.len) return error.InvalidCaptureReduction;
            const schema = capture.fields[field];
            if (!permissions.copy[
                @intCast(schema)
            ] or !permissions.drop[
                @intCast(schema)
            ] or flow.pool.contains(
                flow.live[@intCast(worker.entry)][0],
                worker.inputs[field],
            )) return error.InvalidCaptureReduction;
        }
        const mapped = original.scopes.captures.len + index;
        const reduced = candidate.scopes.captures[mapped];
        var unchanged = reduced;
        unchanged.fields = capture.fields;
        if (!equal(p.Capture, capture, unchanged) or !subsequence(
            capture.fields,
            reduced.fields,
            witness.removed,
        )) return error.InvalidCaptureReduction;
        ctor_removed[witness.constructor] = witness.removed;
        fn_removed[@intCast(constructor.function)] = witness.removed;
        mapped_capture[witness.constructor] = mapped;
    }
    for (original.constructors, candidate.constructors, mapped_capture) |before, after, capture| {
        var expected = before;
        expected.capture = capture;
        if (!equal(p.Constructor, expected, after)) return error.InvalidCaptureReduction;
    }
    for (original.functions, candidate.functions, fn_removed) |before, after, removed| {
        var unchanged = after;
        unchanged.inputs = before.inputs;
        if (!equal(ir.Function, before, unchanged) or !subsequence(
            before.inputs,
            after.inputs,
            removed,
        )) return error.InvalidCaptureReduction;
    }
    for (original.blocks, candidate.blocks) |before, after| {
        if (before.instructions.len != after.instructions.len) return error.InvalidCaptureReduction;
        var unchanged = after;
        unchanged.instructions = before.instructions;
        if (before.terminator == .call) {
            if (after.terminator != .call or
                after.terminator.call.function != before.terminator.call.function or
                !subsequence(
                    before.terminator.call.arguments,
                    after.terminator.call.arguments,
                    fn_removed[@intCast(before.terminator.call.function)],
                ))
                return error.InvalidCaptureReduction;
            unchanged.terminator.call.arguments = before.terminator.call.arguments;
        }
        if (!equal(ir.Block, before, unchanged)) return error.InvalidCaptureReduction;
        for (before.instructions, after.instructions) |old, new| {
            var operation = new;
            if (old.opcode == .computation) {
                if (!subsequence(
                    old.operands,
                    new.operands,
                    ctor_removed[@intCast(old.immediate)],
                )) return error.InvalidCaptureReduction;
                operation.operands = old.operands;
            }
            if (!equal(ir.Instruction, old, operation)) return error.InvalidCaptureReduction;
        }
    }
}
