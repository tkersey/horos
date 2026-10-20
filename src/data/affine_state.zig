// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked affine capture-state transformation. P01 always owns final output.
const std = @import("std");
const ir = @import("activation.zig");
const emit = @import("affine_emit.zig");
const check = @import("affine_validate.zig");
pub const validate = check.validate;
pub const validateTarget = check.validateTarget;
pub const Target = @import("affine_target.zig").Target;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || emit.Error || check.Error;
pub const Cost = struct {
    image_bytes: usize,
    worker_instructions: usize,
    construction_instructions: usize,
};
pub const Statistics = struct {
    outcome: enum { no_change, applied, work_limit } = .no_change,
    original_words: usize = 0,
    reduced_words: usize = 0,
    selected_basis: emit.Basis = .observations,
    observation_cost: ?Cost = null,
    canonical_cost: ?Cost = null,
};
fn cost(program: ir.Program, worker: u64) Error!Cost {
    var result: Cost = .{
        .image_bytes = try @import("program_image.zig").encodedLength(program),
        .worker_instructions = 0,
        .construction_instructions = 0,
    };
    for (program.blocks) |block| {
        if (block.function == worker)
            result.worker_instructions += block.instructions.len
        else
            result.construction_instructions += block.instructions.len;
    }
    return result;
}
fn cheaper(left: Cost, right: Cost) bool {
    if (left.worker_instructions != right.worker_instructions)
        return left.worker_instructions < right.worker_instructions;
    if (left.construction_instructions != right.construction_instructions)
        return left.construction_instructions < right.construction_instructions;
    return left.image_bytes < right.image_bytes;
}

/// Propose the contiguous homogeneous state parameters of an entirely private
/// worker. Both discovery and acceptance recheck eligibility after admission.
/// No constructor, handler or resource ABI is manufactured for this target.
/// Requires admitted records; runTarget is the checked transformation entry.
pub fn directTarget(program: ir.Program, worker_id: u64) ?Target {
    if (!@import("capture_reduction.zig").privateDirectWorker(program, worker_id)) return null;
    const worker = program.functions[@intCast(worker_id)];
    if (worker.inputs.len < 2 or worker.effects.len != 0 or worker.regions.len != 0) return null;
    const schema = worker.layout.slots[@intCast(worker.inputs[0])];
    if (@import("affine_extract.zig").unsignedWidth(
        program.schemas[
            @intCast(schema)
        ],
    ) == null) return null;
    var count: usize = 0;
    for (worker.inputs) |slot| {
        if (worker.layout.slots[@intCast(slot)] != schema) break;
        count += 1;
    }
    // The supported state and independent-input domains each allow 128 words.
    if (count < 2 or count > 256) return null;
    // Keep a forwarded suffix as independent dynamic inputs. This avoids
    // encoding invariant inputs into every recurrent state coordinate. The
    // checker still verifies their ordered values at every incoming call.
    while (count > 0) {
        const slot = worker.inputs[count - 1];
        var forwarded = true;
        for (program.blocks) |block| {
            if (block.function != worker_id) continue;
            for (block.instructions) |op| if (op.destination == slot) {
                forwarded = false;
            };
            if (@import("slot_access.zig").terminator(
                block.terminator,
                slot,
            ).writes != 0) forwarded = false;
            if (block.terminator == .call and
                block.terminator.call.function == worker_id and
                block.terminator.call.arguments[count - 1] != slot)
                forwarded = false;
        }
        if (!forwarded) break;
        count -= 1;
    }
    if (count < 2 or count > 128) return null;
    for (program.blocks) |block| {
        if (block.function != worker_id) continue;
        const transfer = switch (block.terminator) {
            .call => |call| call.function == worker_id,
            .jump => |edge| edge.assignments.len != 0,
            .branch => |branch| branch.when_true.assignments.len != 0 or
                branch.when_false.assignments.len != 0,
            else => false,
        };
        if (transfer) return .{ .parameters = .{ .worker = worker_id, .count = count } };
    }
    return null;
}
pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    constructor_id: usize,
    statistics: ?*Statistics,
    work_limit: u64,
    options: p01.Options,
) Error!p01.Owned {
    return runTarget(
        allocator,
        original,
        .{ .capture = constructor_id },
        statistics,
        work_limit,
        options,
    );
}
pub fn runTarget(
    allocator: std.mem.Allocator,
    original: ir.Program,
    target: Target,
    statistics: ?*Statistics,
    work_limit: u64,
    options: p01.Options,
) Error!p01.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var candidate = (emit.constructTarget(
        allocator,
        original,
        target,
        work_limit,
        .observations,
    ) catch |err| switch (err) {
        error.WorkLimit => {
            stats.outcome = .work_limit;
            return p01.run(allocator, original, options);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options);
    defer candidate.deinit();
    check.validateTarget(
        allocator,
        original,
        candidate.program,
        target,
        candidate.basis,
        candidate.input_bias,
        work_limit,
    ) catch |err| switch (err) {
        error.WorkLimit => {
            stats.outcome = .work_limit;
            return p01.run(allocator, original, options);
        },
        else => return err,
    };
    stats.observation_cost = try cost(candidate.program, target.worker(original));
    var canonical = emit.constructTarget(
        allocator,
        original,
        target,
        work_limit,
        .canonical,
    ) catch |err| switch (err) {
        error.WorkLimit => {
            stats.outcome = .work_limit;
            return p01.run(allocator, original, options);
        },
        else => return err,
    };
    defer if (canonical) |*other| other.deinit();
    var selected = candidate.program;
    if (canonical) |other| {
        if (!std.mem.eql(u128, candidate.basis, other.basis)) {
            check.validateTarget(
                allocator,
                original,
                other.program,
                target,
                other.basis,
                other.input_bias,
                work_limit,
            ) catch |err| switch (err) {
                error.WorkLimit => {
                    stats.outcome = .work_limit;
                    return p01.run(allocator, original, options);
                },
                else => return err,
            };
            stats.canonical_cost = try cost(other.program, target.worker(original));
            if (cheaper(stats.canonical_cost.?, stats.observation_cost.?)) {
                selected = other.program;
                stats.selected_basis = .canonical;
            }
        }
    }
    const result = try p01.run(allocator, selected, options);
    stats.outcome = .applied;
    stats.original_words = target.dimension(original);
    stats.reduced_words = candidate.basis.len;
    return result;
}
