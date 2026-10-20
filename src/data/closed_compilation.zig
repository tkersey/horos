// Copyright (c) 2026 Boundary contributors. MIT license.
//! One closed-record compiler for source lowering and final component linking.
//! Both contracts admit originals and always run independently checked P01.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const image = @import("program_image.zig");
const p01 = @import("coalescing.zig");
const branch = @import("branch_reduction.zig");
const applications = @import("application_specialization.zig");
const aggregates = @import("aggregate_reduction.zig");
const expressions = @import("expression_reuse.zig");
const saturation = @import("equality_saturation.zig");
const cells = @import("cell_reduction.zig");
const dead = @import("dead_computation.zig");
const arguments = @import("dead_arguments.zig");
const captures = @import("capture_reduction.zig");
const projections = @import("capture_projection.zig");
const summaries = @import("capture_summary.zig");
const affine = @import("affine_state.zig");
const pre = @import("partial_redundancy.zig");
const patterns = @import("call_patterns.zig");
const leaves = @import("leaf_inlining.zig");
const joins = @import("contification.zig");
const tails = @import("common_tails.zig");
const duplicate_tails = @import("tail_duplication.zig");
const outlining = @import("outlining.zig");
const packing = @import("slot_packing.zig");
const handler_tail = @import("tail_clauses.zig");
const evidence = @import("evidence_forwarding.zig");
const handlers = @import("handler_elimination.zig");
const readers = @import("reader_fusion.zig");
const sequences = @import("sequence_fusion.zig");
const unfolds = @import("unfold_fusion.zig");
const thunk_forwarding = @import("thunk_forwarding.zig");
const contexts = @import("context_compression.zig");
const constructors = @import("constructor_contexts.zig");
const motion = @import("loop_motion.zig");
const unswitch = @import("loop_unswitch.zig");
const induction_guards = @import("induction_reduction.zig");
const induction_affine = @import("affine_induction.zig");
const rectangles = @import("rectangular_loops.zig");
const tiling = @import("rectangular_tiling.zig");
const profiles = @import("optimization_profile.zig");
const unpack = @import("capture_unpack.zig");
pub const Contract = enum { structural, semantic };
pub const Objective = enum { size, balanced, speed };
pub const Stage = enum {
    p01,
    branch,
    applications,
    aggregates,
    expressions,
    cells,
    dead_computation,
    dead_arguments,
    dead_captures,
    capture_projection,
    capture_summary,
    affine_state,
    capture_unpack,
    partial_redundancy,
    call_patterns,
    leaf_inlining,
    contification,
    common_tails,
    tail_duplication,
    outlining,
    slot_packing,
    tail_clauses,
    evidence_forwarding,
    handler_elimination,
    reader_fusion,
    sequence_fusion,
    unfold_fusion,
    thunk_forwarding,
    context_compression,
    constructor_contexts,
    loop_motion,
    loop_unswitch,
    induction_guards,
    induction_affine,
    rectangular_loops,
    rectangular_tiling,
    equality_saturation,
};
// Prospective construction policy for the expanded four-round schedule.
// Caller-supplied limits remain exact; this does not change P01's allowance.
pub const default_work_limit: u64 = 400_000_000_000;
pub const Outcome = enum {
    not_run,
    structural,
    deferred_open_component,
    no_change,
    applied,
    work_limit,
    size_guard,
};
pub const Statistics = struct {
    outcome: Outcome = .not_run,
    original_bytes: usize = 0,
    baseline_bytes: usize = 0,
    final_bytes: usize = 0,
    rounds: usize = 0,
    stages_run: usize = 0,
    stages_skipped: usize = 0,
    changed_stages: usize = 0,
    work_reserved: u64 = 0,
    stopped_stage: ?Stage = null,
    failed_stage: ?Stage = null,
    selected_candidate: enum { baseline, shrinking, full } = .baseline,
    admission_guard_rejections: usize = 0,
    search_exhaustions: usize = 0,
    profile_used: bool = false,
    profile_variants: usize = 0,
    profile_rewrites: usize = 0,
};
pub const ServiceObservation = struct {
    pub const Report = @import("service_interactions.zig").Report;
    contract: @import("service_interactions.zig").Contract,
    receive: *const fn (*anyopaque, ?Report) void,
};
pub const Observer = struct {
    context: *anyopaque,
    enter: *const fn (*anyopaque, Stage) void,
    service: ?ServiceObservation = null,
};
pub const ProfilePolicy = struct {
    record: profiles.Record,
    target: enum { call_patterns, loop_unswitch, tail_duplication } = .call_patterns,
    max_variants: usize = 16,
    max_copies: usize = 16,
    max_added_blocks: usize = 256,
    max_added_bytes: usize = 4096,
};
fn profileStage(policy: ProfilePolicy) Stage {
    return switch (policy.target) {
        .call_patterns => .call_patterns,
        .loop_unswitch => .loop_unswitch,
        .tail_duplication => .tail_duplication,
    };
}
pub const Options = struct {
    contract: Contract = .structural,
    objective: Objective = .balanced,
    image_growth_bytes: ?usize = null,
    max_image_bytes: ?usize = null,
    work_limit: u64 = default_work_limit,
    round_limit: usize = 4,
    statistics: ?*Statistics = null,
    observer: ?Observer = null,
    profile: ?ProfilePolicy = null,
    coalescing: p01.Options = .{},

    /// Begin an invocation before any producer can reject its input.
    pub fn resetObservations(self: Options) void {
        self.coalescing.resetObservations();
        if (self.statistics) |stats| stats.* = .{};
    }
};
pub const Error = branch.Error ||
    applications.Error ||
    aggregates.Error ||
    expressions.Error ||
    cells.Error ||
    dead.Error ||
    arguments.Error ||
    captures.Error ||
    projections.Error ||
    summaries.Error ||
    affine.Error ||
    unpack.Error ||
    pre.Error ||
    patterns.Error ||
    leaves.Error ||
    joins.Error ||
    tails.Error ||
    duplicate_tails.Error ||
    outlining.Error ||
    packing.Error ||
    handler_tail.ValidationError ||
    evidence.Error ||
    handlers.Error ||
    readers.Error ||
    sequences.Error ||
    unfolds.Error ||
    thunk_forwarding.Error ||
    contexts.Error ||
    constructors.Error ||
    motion.Error ||
    unswitch.Error ||
    induction_guards.Error ||
    induction_affine.Error ||
    rectangles.Error ||
    tiling.Error ||
    saturation.Error;
const schedule = [_]Stage{
    .rectangular_loops,
    .rectangular_tiling,
    .induction_guards,
    .induction_affine,
    .loop_unswitch,
    .loop_motion,
    .constructor_contexts,
    .context_compression,
    .unfold_fusion,
    .sequence_fusion,
    .thunk_forwarding,
    .branch,
    .capture_unpack,
    .aggregates,
    .dead_computation,
    .affine_state,
    .call_patterns,
    .branch,
    .applications,
    .leaf_inlining,
    .contification,
    .tail_clauses,
    .evidence_forwarding,
    .handler_elimination,
    .reader_fusion,
    .aggregates,
    .expressions,
    .equality_saturation,
    .partial_redundancy,
    .cells,
    .dead_computation,
    .dead_arguments,
    .dead_captures,
    .capture_projection,
    .capture_summary,
    .dead_computation,
    .dead_arguments,
    .applications,
    .dead_computation,
    .tail_duplication,
    .common_tails,
    .outlining,
    .slot_packing,
};
fn notify(options: Options, stage: Stage) void {
    if (options.observer) |observer| observer.enter(observer.context, stage);
}
fn growth(options: Options, baseline: usize) usize {
    return options.image_growth_bytes orelse switch (options.objective) {
        .size => 0,
        .balanced => @max(1024, baseline / 20 + @intFromBool(baseline % 20 != 0)),
        .speed => @max(4096, baseline / 4 + @intFromBool(baseline % 4 != 0)),
    };
}

/// Reserve a conservative bound for descriptor/operand comparison scans. Literal
/// bytes are linear, not multiplied into the quadratic descriptor bound. Dynamic
/// fact/proof searches also have counted local caps. Admission and P01 retain
/// their independent mandatory checks and P01's own work accounting.
const Shape = struct { records: u64 = 0, bytes: u64 = 0 };
inline fn recordShape(comptime T: type, value: T, result: *Shape) Error!void {
    result.records = std.math.add(u64, result.records, 1) catch return error.Capacity;
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (
            info.field_names,
            info.field_types,
        ) |field_name, FieldType| try recordShape(FieldType, @field(value, field_name), result),
        .@"union" => switch (value) {
            inline else => |payload| try recordShape(@TypeOf(payload), payload, result),
        },
        .optional => |info| if (value) |payload| {
            try recordShape(info.child, payload, result);
        },
        .pointer => |info| {
            if (info.child == u8) result.bytes = std.math.add(
                u64,
                result.bytes,
                value.len,
            ) catch return error.Capacity else for (value) |item| try recordShape(
                info.child,
                item,
                result,
            );
        },
        .array => |info| for (value) |item| try recordShape(info.child, item, result),
        else => {},
    }
}
fn sumWork(values: []const u64) Error!u64 {
    var result: u64 = 0;
    for (values) |value| result = std.math.add(u64, result, value) catch return error.Capacity;
    return result;
}
const WorkShape = struct {
    shape: Shape = .{},
    instructions: u64 = 0,
    block_squares: u64 = 0,
    applications_count: u64 = 0,
    cells_count: u64 = 0,
    constructions: u64 = 0,
    max_slots: u64 = 0,
    max_inputs: u64 = 0,
};
fn workShape(program: ir.Program) Error!WorkShape {
    // Wire compression is deliberately irrelevant to a scan-work bound.
    var result: WorkShape = .{};
    try recordShape(ir.Program, program, &result.shape);
    for (program.functions) |function| {
        result.max_slots = @max(result.max_slots, function.layout.slots.len);
        result.max_inputs = @max(result.max_inputs, function.inputs.len);
    }
    for (program.blocks) |block| {
        result.instructions = std.math.add(
            u64,
            result.instructions,
            block.instructions.len,
        ) catch return error.Capacity;
        const square = std.math.mul(
            u64,
            block.instructions.len,
            block.instructions.len,
        ) catch return error.Capacity;
        result.block_squares = std.math.add(
            u64,
            result.block_squares,
            square,
        ) catch return error.Capacity;
        result.applications_count += @intFromBool(block.terminator == .apply);
        for (block.instructions) |op| {
            result.cells_count += @intFromBool(op.opcode == .cell_new);
            result.constructions += @intFromBool(op.opcode == .computation);
        }
    }
    return result;
}
fn comparisonUnits(program: ir.Program, stage: Stage, shape: WorkShape) Error!u64 {
    // These bounded passes index whole-record scans by functions, blocks,
    // parameters or slots. Instruction-level searches have their own
    // counted allowances below; they do not each rescan the entire Program.
    return switch (stage) {
        .call_patterns,
        .leaf_inlining,
        .contification,
        .common_tails,
        .tail_duplication,
        .outlining,
        .slot_packing,
        .tail_clauses,
        .evidence_forwarding,
        .handler_elimination,
        .reader_fusion,
        .sequence_fusion,
        .unfold_fusion,
        .thunk_forwarding,
        .context_compression,
        .constructor_contexts,
        .loop_motion,
        .loop_unswitch,
        .induction_guards,
        .induction_affine,
        .rectangular_loops,
        .rectangular_tiling,
        => sumWork(&.{
            program.functions.len, shape.max_inputs, shape.max_slots, program.blocks.len, 1,
        }),
        .applications => sumWork(&.{ shape.applications_count, 1 }),
        .partial_redundancy => sumWork(&.{ shape.instructions, program.blocks.len, 1 }),
        .cells => sumWork(&.{ shape.cells_count, 1 }),
        // One dead-computation round. The driver caps and charges each actual
        // round instead of reserving all hypothetical shrinking rounds up front.
        .dead_computation => sumWork(&.{ program.blocks.len, 1 }),
        .dead_arguments => sumWork(&.{ program.functions.len, shape.max_inputs, 1 }),
        .affine_state => sumWork(&.{
            program.constructors.len, program.functions.len, shape.constructions, 1,
        }),
        .dead_captures, .capture_projection, .capture_summary, .capture_unpack => sumWork(&.{
            program.constructors.len, shape.constructions, 1,
        }),
        .p01, .branch, .aggregates, .expressions, .equality_saturation => unreachable,
    };
}
fn factReservation(program: ir.Program, stage: Stage) Error!u64 {
    return switch (stage) {
        .branch, .applications, .aggregates => 22_000_000,
        .call_patterns => 5 * (patterns.Options{}).work_limit,
        .expressions, .partial_redundancy, .equality_saturation => 1_000_000,
        .leaf_inlining, .contification, .common_tails, .outlining => 2_000_000,
        .tail_duplication => 26_000_000, // Search/checker plus fresh branch facts/proofs.
        .slot_packing,
        .tail_clauses,
        .evidence_forwarding,
        .reader_fusion,
        .sequence_fusion,
        .unfold_fusion,
        .thunk_forwarding,
        .context_compression,
        .constructor_contexts,
        .loop_motion,
        .loop_unswitch,
        .induction_guards,
        .induction_affine,
        .rectangular_loops,
        .rectangular_tiling,
        => 20_000_000,
        .handler_elimination => 2_000_000,
        .affine_state => std.math.mul(
            u64,
            try sumWork(&.{ program.constructors.len, program.functions.len }),
            6_000_000,
        ) catch return error.Capacity,
        else => 0,
    };
}
fn reservation(program: ir.Program, stage: Stage) Error!u64 {
    const shape = try workShape(program);
    // Count the domain actually scanned by this pass, not a square of unrelated
    // schemas, literals and record wrapper fields. Fixed-point/proof work below
    // is separately capped by its counted allowance.
    const comparisons = switch (stage) {
        .branch => std.math.mul(
            u64,
            program.blocks.len,
            program.blocks.len,
        ) catch return error.Capacity,
        .aggregates => shape.block_squares,
        .p01, .expressions, .equality_saturation => 0,
        else => std.math.mul(
            u64,
            try comparisonUnits(program, stage, shape),
            shape.shape.records,
        ) catch return error.Capacity,
    };
    const scans = std.math.mul(
        u64,
        std.math.add(u64, comparisons, shape.shape.records) catch return error.Capacity,
        64,
    ) catch return error.Capacity;
    const byte_work = std.math.mul(u64, shape.shape.bytes, 16) catch return error.Capacity;
    const facts = try factReservation(program, stage);
    return std.math.add(
        u64,
        std.math.add(u64, scans, byte_work) catch return error.Capacity,
        facts,
    ) catch return error.Capacity;
}
const Cost = struct {
    bytes: usize,
    work: u64,
    path_work: ?u64 = null,
    retention: u64,
    recursive_contexts: u64 = 0,
    repeated_scalar_work: ?u64 = null,
    repeated_branch_tests: ?u64 = null,
    admission_sets: [4]u64,
};
// Zig 0.16's geometric growth starts with cache_line / node_size. Cover
// 64/128-byte cache lines and 16/24-byte nodes without querying the build host.
const node_growth_starts = [_]u64{ 2, 4, 5, 8 };
fn nodeCapacityEstimate(count: usize, start: u64) Error!u64 {
    var capacity: u64 = 0;
    while (capacity < count) {
        const minimum = std.math.add(u64, capacity, 1) catch return error.Capacity;
        capacity = try sumWork(&.{ minimum, minimum / 2, start });
    }
    return capacity;
}
fn admissionSetCost(nodes: usize, table_capacity: usize) Error![4]u64 {
    var result: [4]u64 = undefined;
    for (node_growth_starts, &result) |start, *score| score.* = try sumWork(&.{
        std.math.mul(u64, try nodeCapacityEstimate(nodes, start), 24) catch return error.Capacity,
        std.math.mul(u64, table_capacity, 12) catch return error.Capacity,
    });
    return result;
}
const PayloadFrame = struct {
    schema: usize,
    next: usize = 0,
    result: u64 = 0,
};
fn payloadResolved(
    program: ir.Program,
    id: usize,
    depth: usize,
    memo: []?u64,
    active: []bool,
) ?u64 {
    if (depth == 32) return 8;
    if (memo[id]) |value| return value;
    if (active[id]) return 8;
    const value: u64 = switch (program.schemas[id]) {
        .unit => 0,
        .boolean, .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32 => 4,
        .u64, .i64 => 8,
        .product, .array => return null,
        else => 8,
    };
    memo[id] = value;
    return value;
}
fn payloadChild(program: ir.Program, frame: *PayloadFrame) ?usize {
    const child: u64 = switch (program.schemas[frame.schema]) {
        .product => |fields| if (frame.next < fields.len) fields[frame.next] else return null,
        .array => |array| if (frame.next == 0) array.element else return null,
        else => unreachable,
    };
    frame.next += 1;
    return @intCast(child);
}
fn payloadAccumulate(program: ir.Program, frame: *PayloadFrame, value: u64) void {
    switch (program.schemas[frame.schema]) {
        .product => frame.result +|= value,
        .array => |array| frame.result = array.length *| value,
        else => unreachable,
    }
}
fn payloadEstimate(
    program: ir.Program,
    schema: u64,
    depth: usize,
    memo: []?u64,
    active: []bool,
) u64 {
    const root: usize = @intCast(schema);
    if (payloadResolved(program, root, depth, memo, active)) |value| return value;
    var frames: [32]PayloadFrame = undefined;
    frames[0] = .{ .schema = root };
    active[root] = true;
    var count: usize = 1;
    while (count > 0) {
        const frame = &frames[count - 1];
        if (payloadChild(program, frame)) |child| {
            if (payloadResolved(program, child, depth + count, memo, active)) |value| {
                payloadAccumulate(program, frame, value);
            } else {
                active[child] = true;
                frames[count] = .{ .schema = child };
                count += 1;
            }
            continue;
        }
        const value = frame.result;
        memo[frame.schema] = value;
        active[frame.schema] = false;
        count -= 1;
        if (count == 0) return value;
        payloadAccumulate(program, &frames[count - 1], value);
    }
    unreachable;
}
// A bounded acyclic entry-path estimate exposes PRE and specialization work
// savings that static sums miss. Known direct callees are expanded; applications
// retain their opaque dispatch weight. Cycles/depth exhaustion yield unknown.
// This is a selection heuristic, not a whole-program runtime bound.
fn blockWork(block: ir.Block) u64 {
    var work: u64 = if (block.terminator == .apply) 4 else 1;
    for (block.instructions) |op| work +|= switch (op.opcode) {
        .move => 0,
        .cell_new => 8,
        .cell_get, .cell_set => 3,
        else => 1,
    };
    return work;
}
fn pathSuccessor(term: ir.Terminator, index: usize) ?ir.Edge {
    return switch (term) {
        .return_value, .fail => null,
        .jump => |v| if (index == 0) v else null,
        .branch => |v| if (index == 0) v.when_true else if (index == 1) v.when_false else null,
        .switch_variant => |v| if (index < v.cases.len) v.cases[index] else null,
        .yield_value => |v| if (index == 0) v else null,
        inline else => |v| if (index == 0) v.next else null,
    };
}
const PathFrame = struct {
    block: usize,
    next: usize = 0,
    following: u64 = 0,
    nested: u64 = 0,
    called: bool = false,
};
fn pathChild(program: ir.Program, frame: *PathFrame) ?usize {
    if (frame.called) return null;
    const term = program.blocks[frame.block].terminator;
    if (pathSuccessor(term, frame.next)) |edge| {
        frame.next += 1;
        return @intCast(edge.block);
    }
    frame.called = true;
    return if (term == .call)
        @intCast(program.functions[@intCast(term.call.function)].entry)
    else
        null;
}
fn pathAccumulate(frame: *PathFrame, value: u64) void {
    if (frame.called) frame.nested = value else frame.following = @max(frame.following, value);
}
fn pathAt(program: ir.Program, block: usize, marks: []u8, memo: []u64, depth: usize) ?u64 {
    if (depth >= 512 or marks[block] == 1) return null;
    if (marks[block] == 2) return memo[block];
    var frames: [512]PathFrame = undefined;
    frames[0] = .{ .block = block };
    marks[block] = 1;
    var count: usize = 1;
    while (count > 0) {
        const frame = &frames[count - 1];
        if (pathChild(program, frame)) |child| {
            if (depth + count >= 512 or marks[child] == 1) return null;
            if (marks[child] == 2) {
                pathAccumulate(frame, memo[child]);
            } else {
                marks[child] = 1;
                frames[count] = .{ .block = child };
                count += 1;
            }
            continue;
        }
        const value = blockWork(program.blocks[frame.block]) +| frame.following +| frame.nested;
        memo[frame.block] = value;
        marks[frame.block] = 2;
        count -= 1;
        if (count == 0) return value;
        pathAccumulate(&frames[count - 1], value);
    }
    unreachable;
}
fn pathWork(allocator: std.mem.Allocator, program: ir.Program) Error!?u64 {
    const marks = try allocator.alloc(u8, program.blocks.len);
    defer allocator.free(marks);
    @memset(marks, 0);
    const memo = try allocator.alloc(u64, program.blocks.len);
    defer allocator.free(memo);
    var work: u64 = 0;
    for (program.functions, 0..) |function, id| {
        if (!@import("call_contexts.zig").unknownEntry(program, id)) continue;
        work = @max(
            work,
            pathAt(program, @intCast(function.entry), marks, memo, 0) orelse return null,
        );
    }
    return work;
}
fn cost(allocator: std.mem.Allocator, owned: *const p01.Owned) Error!Cost {
    const program = owned.program;
    const memo = try allocator.alloc(?u64, program.schemas.len);
    defer allocator.free(memo);
    const active = try allocator.alloc(bool, program.schemas.len);
    defer allocator.free(active);
    @memset(memo, null);
    @memset(active, false);
    // Fixed logical weights avoid making selection depend on host pointers,
    // allocator resize success, or native versus wasm node representation.
    // This models the retained analysis containers, not Kosmos runtime memory.
    const admission_sets = try admissionSetCost(
        owned.flow.pool.nodeCount(),
        owned.flow.pool.interned.capacity(),
    );
    const repeated_work = try motion.repeatedWorkEstimate(allocator, program);
    var result: Cost = .{
        .bytes = try image.encodedLength(program),
        .work = 0,
        .path_work = if (try rectangles.executionWork(
            allocator,
            program,
        )) |work| work else try pathWork(allocator, program),
        .repeated_scalar_work = if (repeated_work) |work| work.scalars else null,
        .repeated_branch_tests = if (repeated_work) |work| work.branch_tests else null,
        .retention = 0,
        .admission_sets = admission_sets,
    };
    for (program.blocks) |block| {
        result.work +|= blockWork(block);
        if (block.terminator == .call and block.terminator.call.function == block.function) {
            const edge = block.terminator.call.next;
            const next = program.blocks[@intCast(edge.block)];
            const tail = next.function == block.function and
                next.custody == block.custody and
                next.instructions.len == 0 and
                next.terminator == .return_value and
                edge.assignments.len == 1 and
                edge.assignments[0].source == .returned and
                edge.assignments[0].destination == next.terminator.return_value;
            result.recursive_contexts +|= @intFromBool(!tail);
        }
        for (block.instructions) |op| {
            if (op.opcode == .computation) {
                const capture = program.scopes.captures[
                    @intCast(program.constructors[
                        @intCast(op.immediate)
                    ].capture)
                ];
                for (capture.fields) |field| result.retention +|= payloadEstimate(
                    program,
                    field,
                    0,
                    memo,
                    active,
                );
            }
        }
    }
    return result;
}
fn admissionGrowthAllowed(candidate: Cost, baseline: Cost) bool {
    for (candidate.admission_sets, baseline.admission_sets) |after, before| {
        const allowance = @max(1024, before / 100);
        if (after > before and after - before > allowance) return false;
    }
    return true;
}
fn allowBaseline(options: Options, bytes: usize) Error!void {
    if (options.max_image_bytes) |limit| if (bytes > limit) return error.Capacity;
}
fn better(candidate: Cost, baseline: Cost, objective: Objective) bool {
    // Deterministic, explicitly heuristic estimates; never runtime measurements.
    if (objective == .size)
        return candidate.bytes < baseline.bytes or
            (candidate.bytes == baseline.bytes and
                candidate.work < baseline.work);
    return (candidate.repeated_branch_tests != null and
        baseline.repeated_branch_tests != null and
        candidate.repeated_branch_tests.? < baseline.repeated_branch_tests.?) or
        (candidate.repeated_scalar_work != null and
            baseline.repeated_scalar_work != null and
            candidate.repeated_scalar_work.? < baseline.repeated_scalar_work.?) or
        candidate.recursive_contexts < baseline.recursive_contexts or
        candidate.retention < baseline.retention or
        candidate.work < baseline.work or
        candidate.bytes < baseline.bytes or
        (candidate.path_work != null and
            baseline.path_work != null and
            candidate.path_work.? < baseline.path_work.?);
}
fn possibleExpressions(allocator: std.mem.Allocator, program: ir.Program) Error!bool {
    const seen = try allocator.alloc(u64, program.functions.len);
    defer allocator.free(seen);
    @memset(seen, 0);
    for (program.blocks) |block| for (block.instructions) |op| {
        if (!expressions.canNumber(op.opcode)) continue;
        const tag = @backingInt(op.opcode);
        if (tag >= 64) return true;
        const bit = @as(u64, 1) << @intCast(tag);
        if (seen[@intCast(block.function)] & bit != 0) return true;
        seen[@intCast(block.function)] |= bit;
    };
    return false;
}
fn possibleDead(owned: *const p01.Owned, stage: Stage) bool {
    const program = owned.program;
    switch (stage) {
        .dead_computation => for (program.blocks, 0..) |block, id| {
            if (owned.flow.live[id].len == 0) continue;
            for (
                block.instructions,
                0..,
            ) |op, index| if (!owned.flow.pool.contains(
                owned.flow.live[id][index + 1],
                op.destination,
            )) return true;
        },
        .dead_arguments => for (program.blocks) |block| {
            if (block.terminator != .call) continue;
            const id = block.terminator.call.function;
            if (@import("call_contexts.zig").unknownEntry(program, id)) continue;
            const function = program.functions[@intCast(id)];
            for (function.inputs) |slot| if (!owned.flow.pool.contains(
                owned.flow.live[@intCast(function.entry)][0],
                slot,
            )) return true;
        },
        .dead_captures,
        .capture_projection,
        .capture_summary,
        => for (program.constructors) |constructor| {
            const capture = program.scopes.captures[@intCast(constructor.capture)];
            const function = program.functions[@intCast(constructor.function)];
            if (stage == .dead_captures) {
                for (
                    capture.fields,
                    0..,
                ) |_, index| if (!owned.flow.pool.contains(
                    owned.flow.live[@intCast(function.entry)][0],
                    function.inputs[index],
                )) return true;
            } else if (stage == .capture_projection) {
                if (capture.fields.len == 1 and program.schemas[
                    @intCast(capture.fields[0])
                ] == .product) return true;
            } else if (capture.fields.len == 2 and program.schemas[
                @intCast(capture.fields[0])
            ] == .u64 and capture.fields[0] == capture.fields[1]) return true;
        },
        else => unreachable,
    }
    return false;
}
fn possibleCaptureControl(program: ir.Program, stage: Stage) bool {
    switch (stage) {
        .capture_unpack => for (program.constructors) |constructor| {
            const capture = program.scopes.captures[@intCast(constructor.capture)];
            if (capture.fields.len != 1 or program.schemas[
                @intCast(capture.fields[0])
            ] != .product) continue;
            for (program.blocks) |block|
                if (block.function == constructor.function and
                    block.terminator == .call and
                    block.terminator.call.function == constructor.function)
                    return true;
        },
        .affine_state => {
            for (program.constructors) |constructor| {
                const capture = program.scopes.captures[@intCast(constructor.capture)];
                if (capture.fields.len == 0 or capture.fields.len > 128) continue;
                for (program.blocks) |block| {
                    if (block.function != constructor.function) continue;
                    switch (block.terminator) {
                        .call => |call| if (call.function == constructor.function) return true,
                        .jump => |edge| if (edge.assignments.len != 0) return true,
                        .branch => |choice| if (choice.when_true.assignments.len != 0 or
                            choice.when_false.assignments.len != 0)
                            return true,
                        else => {},
                    }
                }
            }
            for (
                program.functions,
                0..,
            ) |_, id| if (affine.directTarget(program, id) != null) return true;
        },
        else => unreachable,
    }
    return false;
}
fn possible(allocator: std.mem.Allocator, owned: *const p01.Owned, stage: Stage) Error!bool {
    const program = owned.program;
    switch (stage) {
        .branch => for (program.blocks) |block| {
            if (block.terminator == .branch) return true;
        },
        .applications => for (program.blocks) |block| {
            if (block.terminator == .apply) return true;
        },
        .aggregates, .cells => for (program.blocks) |block| {
            for (block.instructions) |op|
                if (op.opcode == (if (stage == .aggregates)
                    p.Opcode.field
                else
                    p.Opcode.cell_new))
                    return true;
        },
        .expressions => return possibleExpressions(allocator, program),
        .dead_computation,
        .dead_arguments,
        .dead_captures,
        .capture_projection,
        .capture_summary,
        => return possibleDead(owned, stage),
        .capture_unpack, .affine_state => return possibleCaptureControl(program, stage),
        .partial_redundancy => return pre.possible(program),
        .call_patterns => return patterns.possible(program),
        .leaf_inlining => return leaves.possible(program),
        .contification => return joins.possible(program),
        .common_tails => return tails.possible(program),
        .tail_duplication => return duplicate_tails.possible(program),
        .outlining => return outlining.possible(program),
        .slot_packing => return packing.possible(program),
        .tail_clauses => return handler_tail.possible(program),
        .evidence_forwarding => return evidence.possible(program),
        .handler_elimination => return handlers.possible(program),
        .reader_fusion => return readers.possible(program),
        .sequence_fusion => return sequences.possible(program),
        .unfold_fusion => return unfolds.possible(program),
        .thunk_forwarding => return thunk_forwarding.possible(program),
        .context_compression => return contexts.possible(program),
        .constructor_contexts => return constructors.possible(program),
        .loop_motion => return motion.possible(program),
        .loop_unswitch => return unswitch.possible(program),
        .equality_saturation => return saturation.possible(program),
        .rectangular_loops, .rectangular_tiling => return rectangles.possible(program),
        .induction_guards => return induction_guards.possible(program),
        .induction_affine => return induction_affine.possible(program),
        .p01 => return true,
    }
    return false;
}

pub fn run(allocator: std.mem.Allocator, original: ir.Program, options: Options) Error!p01.Owned {
    const result = try runInternal(allocator, original, options);
    if (options.observer) |observer| if (observer.service) |service| {
        // Optional presentation is derived only after final binding/relocation.
        // Its allocation failure cannot change the already selected image.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const owner = @import("control_provenance.zig").derive(
            scratch,
            result.program,
            &.{},
            false,
        ) catch {
            service.receive(observer.context, null);
            return result;
        };
        const report = @import("service_interactions.zig").observe(
            scratch,
            owner,
            service.contract,
        ) catch {
            service.receive(observer.context, null);
            return result;
        };
        service.receive(observer.context, report);
    };
    return result;
}
fn runInternal(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!p01.Owned {
    options.resetObservations();
    // Semantic passes need their own composed recovery correspondence. Until
    // they provide it, never publish a P01-only map for a rewritten program.
    if (options.coalescing.correspondence != null and
        options.contract != .structural)
        return error.InvalidCorrespondence;
    var stats: Statistics = .{};
    var stage: Stage = .p01;
    defer if (options.statistics) |out| {
        out.* = stats;
    };
    errdefer stats.failed_stage = stage;
    notify(options, .p01);
    var baseline = try p01.run(allocator, original, options.coalescing);
    var keep_baseline = false;
    defer if (!keep_baseline) baseline.deinit();
    // Bind logical locations before any semantic rewrite or P01 relocation.
    // Structural compilation validates the profile but explicitly does not use it.
    if (options.profile) |policy| try profiles.validate(allocator, original, policy.record);
    stats.original_bytes = try image.encodedLength(original);
    stats.baseline_bytes = try image.encodedLength(baseline.program);
    stats.final_bytes = stats.baseline_bytes;
    if (options.contract == .structural) {
        if (options.max_image_bytes) |limit| if (stats.final_bytes > limit) return error.Capacity;
        stats.outcome = .structural;
        keep_baseline = true;
        return baseline;
    }
    if (options.work_limit == 0) {
        try allowBaseline(options, stats.baseline_bytes);
        stats.outcome = .work_limit;
        keep_baseline = true;
        return baseline;
    }
    var invocation: SemanticInvocation = .{
        .allocator = allocator,
        .original = original,
        .options = options,
        .stats = &stats,
        .stage = &stage,
        .baseline = &baseline,
        .baseline_cost = try cost(allocator, &baseline),
        .limit = std.math.add(
            usize,
            stats.baseline_bytes,
            growth(options, stats.baseline_bytes),
        ) catch return error.Capacity,
        .quiet = .{ .work_limit = options.coalescing.work_limit },
    };
    defer invocation.deinit();
    if (try invocation.run()) |result| return result;
    keep_baseline = true;
    return baseline;
}
const SemanticInvocation = struct {
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
    stats: *Statistics,
    stage: *Stage,
    baseline: *const p01.Owned,
    baseline_cost: Cost,
    limit: usize,
    quiet: p01.Options,
    current: ?p01.Owned = null,
    shrinking: ?p01.Owned = null,
    generation: usize = 0,
    no_change_generation: [@typeInfo(Stage).@"enum".field_names.len]?usize = @splat(null),

    fn deinit(self: *SemanticInvocation) void {
        if (self.shrinking) |*owner| owner.deinit();
        if (self.current) |*owner| owner.deinit();
    }
    fn run(self: *SemanticInvocation) Error!?p01.Owned {
        if (!try self.applyProfile()) return null;
        if (!try self.shrink()) return null;
        if (!try self.rounds()) return null;
        return self.select();
    }
    fn stop(self: *SemanticInvocation, stopped_stage: ?Stage) Error!void {
        try allowBaseline(self.options, self.stats.baseline_bytes);
        self.stats.outcome = .work_limit;
        if (stopped_stage) |stage| self.stats.stopped_stage = stage;
    }
    fn applyProfile(self: *SemanticInvocation) Error!bool {
        const policy = self.options.profile orelse return true;
        self.stage.* = profileStage(policy);
        const charge = try reservation(self.original, self.stage.*);
        if (charge > self.options.work_limit - self.stats.work_reserved) {
            try self.stop(self.stage.*);
            return false;
        }
        self.stats.work_reserved += charge;
        notify(self.options, self.stage.*);
        var exhausted = false;
        self.current = try self.profileResult(policy, &exhausted);
        if (exhausted) {
            try self.stop(self.stage.*);
            return false;
        }
        self.stats.profile_used = true;
        self.stats.stages_run += 1;
        self.stats.changed_stages += @intFromBool(!@import("record_equal.zig").equal(
            ir.Program,
            self.baseline.program,
            self.current.?.program,
        ));
        return true;
    }
    fn profileResult(
        self: *SemanticInvocation,
        policy: ProfilePolicy,
        exhausted: *bool,
    ) Error!p01.Owned {
        return switch (policy.target) {
            .call_patterns => blk: {
                var profiled: patterns.Statistics = .{};
                const result = try patterns.run(self.allocator, self.original, &profiled, .{
                    .profile = policy.record,
                    .max_variants = policy.max_variants,
                    .max_added_blocks = policy.max_added_blocks,
                    .max_added_bytes = policy.max_added_bytes,
                    .coalescing = self.quiet,
                });
                exhausted.* = profiled.work_limit;
                self.stats.profile_variants = profiled.variants;
                self.stats.profile_rewrites = profiled.rewritten_calls;
                break :blk result;
            },
            .loop_unswitch => blk: {
                var profiled: unswitch.Statistics = .{};
                const result = try unswitch.run(
                    self.allocator,
                    self.original,
                    &profiled,
                    .{
                        .profile = policy.record,
                        .max_added_bytes = policy.max_added_bytes,
                        .coalescing = self.quiet,
                    },
                );
                exhausted.* = profiled.work_limit;
                self.stats.profile_rewrites = profiled.unswitched;
                break :blk result;
            },
            .tail_duplication => blk: {
                var profiled: duplicate_tails.Statistics = .{};
                const result = try duplicate_tails.run(
                    self.allocator,
                    self.original,
                    &profiled,
                    .{
                        .profile = policy.record,
                        .max_copies = policy.max_copies,
                        .max_added_bytes = policy.max_added_bytes,
                        .coalescing = self.quiet,
                    },
                );
                exhausted.* = profiled.work_limit;
                self.stats.profile_rewrites = profiled.copies;
                break :blk result;
            },
        };
    }
    fn shrink(self: *SemanticInvocation) Error!bool {
        // A small independent shrinking candidate keeps useful dead-work removal
        // available when a later reuse combination is uneconomical. It is an
        // internal candidate, never an alternative production compilation route.
        if (!try possible(self.allocator, self.baseline, .dead_computation)) return true;
        const charge = try reservation(self.baseline.program, .dead_computation);
        if (charge > self.options.work_limit - self.stats.work_reserved) {
            try self.stop(.dead_computation);
            return false;
        }
        self.stage.* = .dead_computation;
        notify(self.options, self.stage.*);
        var exhausted = false;
        self.shrinking = try applyWithWork(
            self.allocator,
            self.baseline.program,
            self.stage.*,
            self.quiet,
            charge,
            self.options.work_limit,
            &self.stats.work_reserved,
            &exhausted,
            &self.stats.search_exhaustions,
        );
        if (exhausted) {
            try self.stop(self.stage.*);
            return false;
        }
        self.stats.stages_run += 1;
        return true;
    }
    fn subject(self: *SemanticInvocation) *const p01.Owned {
        return if (self.current) |*owner| owner else self.baseline;
    }
    fn rounds(self: *SemanticInvocation) Error!bool {
        if (self.shrinking) |owner| {
            if (self.current == null and @import("record_equal.zig").equal(
                ir.Program,
                self.baseline.program,
                owner.program,
            )) self.no_change_generation[@backingInt(Stage.dead_computation)] = self.generation;
        }
        var round: usize = 0;
        while (round < self.options.round_limit) : (round += 1) {
            const before = try image.identity(self.allocator, self.subject().program);
            for (schedule) |next_stage| {
                self.stage.* = next_stage;
                if (!try self.runStage()) return false;
            }
            self.stats.rounds += 1;
            if (std.mem.eql(
                u8,
                &before,
                &try image.identity(self.allocator, self.subject().program),
            )) return true;
        }
        try self.stop(null);
        return false;
    }
    fn skipStage(self: *SemanticInvocation) Error!bool {
        // The one original-image profile budget is not replenished after
        // rewriting, and old IDs never rank relocated candidate records.
        if (self.options.profile) |policy| if (self.stage.* == profileStage(policy)) return true;
        if (self.no_change_generation[@backingInt(self.stage.*)] == self.generation) return true;
        return !try possible(self.allocator, self.subject(), self.stage.*);
    }
    fn runStage(self: *SemanticInvocation) Error!bool {
        if (try self.skipStage()) {
            self.stats.stages_skipped += 1;
            return true;
        }
        const input = self.subject().program;
        const charge = try reservation(input, self.stage.*);
        if (charge > self.options.work_limit - self.stats.work_reserved) {
            try self.stop(self.stage.*);
            return false;
        }
        notify(self.options, self.stage.*);
        var exhausted = false;
        var next = applyWithWork(
            self.allocator,
            input,
            self.stage.*,
            self.quiet,
            charge,
            self.options.work_limit,
            &self.stats.work_reserved,
            &exhausted,
            &self.stats.search_exhaustions,
        ) catch |err| {
            if (err == error.SemanticWorkLimit or err == error.ExpressionWorkLimit) {
                try self.stop(self.stage.*);
                return false;
            }
            return err;
        };
        errdefer next.deinit();
        if (exhausted) {
            try self.stop(self.stage.*);
            next.deinit();
            return false;
        }
        self.stats.stages_run += 1;
        // An unchanged-stage result is reusable only until another stage
        // changes actual records. No hash match authorizes skipping work.
        if (!@import("record_equal.zig").equal(ir.Program, input, next.program)) {
            self.stats.changed_stages += 1;
            self.generation += 1;
        } else self.no_change_generation[@backingInt(self.stage.*)] = self.generation;
        if (self.current) |*owner| owner.deinit();
        self.current = next;
        return true;
    }
    fn select(self: *SemanticInvocation) Error!?p01.Owned {
        var selected = self.baseline;
        var selected_cost = self.baseline_cost;
        const hard_limit = self.options.max_image_bytes orelse std.math.maxInt(usize);
        var size_rejected = false;
        const candidates = [_]?*const p01.Owned{
            if (self.shrinking) |*owner| owner else null,
            if (self.current) |*owner| owner else null,
        };
        for (candidates, 0..) |candidate, index| {
            const owner = candidate orelse continue;
            const candidate_cost = try cost(self.allocator, owner);
            if (candidate_cost.bytes > self.limit or candidate_cost.bytes > hard_limit) {
                size_rejected = true;
                continue;
            }
            if (!admissionGrowthAllowed(candidate_cost, self.baseline_cost)) {
                self.stats.admission_guard_rejections += 1;
                continue;
            }
            if (better(candidate_cost, selected_cost, self.options.objective)) {
                selected = owner;
                selected_cost = candidate_cost;
                self.stats.selected_candidate = if (index == 0) .shrinking else .full;
            }
        }
        if (self.stats.selected_candidate == .baseline) {
            if (self.stats.baseline_bytes > hard_limit) return error.Capacity;
            self.stats.outcome = if (size_rejected) .size_guard else .no_change;
            return null;
        }
        self.stage.* = .p01;
        notify(self.options, .p01);
        var result = try p01.run(self.allocator, selected.program, self.options.coalescing);
        errdefer result.deinit();
        self.stats.final_bytes = try image.encodedLength(result.program);
        self.stats.outcome = .applied;
        return result;
    }
};
fn applyWithWork(
    a: std.mem.Allocator,
    program: ir.Program,
    stage: Stage,
    options: p01.Options,
    charge: u64,
    limit: u64,
    used: *u64,
    exhausted: *bool,
    search_exhaustions: *usize,
) Error!p01.Owned {
    if (stage != .dead_computation) {
        used.* += charge;
        return apply(a, program, stage, options, exhausted, search_exhaustions);
    }
    // Each round only removes instructions, so its input scan bound cannot
    // exceed the original round's reservation. No round starts without credit.
    const allowed = (limit - used.*) / @max(charge, 1);
    var stats: dead.Statistics = .{};
    const result = try dead.run(
        a,
        program,
        &stats,
        .{ .round_limit = @intCast(@min(allowed, std.math.maxInt(usize))), .coalescing = options },
    );
    used.* += charge * stats.round_attempts;
    exhausted.* = stats.work_limit;
    return result;
}
fn measuredStage(comptime stage: Stage) type {
    return switch (stage) {
        .expressions => expressions,
        .rectangular_tiling => tiling,
        .rectangular_loops => rectangles,
        .induction_guards => induction_guards,
        .induction_affine => induction_affine,
        .loop_unswitch => unswitch,
        .loop_motion => motion,
        .constructor_contexts => constructors,
        .context_compression => contexts,
        .thunk_forwarding => thunk_forwarding,
        .unfold_fusion => unfolds,
        .sequence_fusion => sequences,
        .reader_fusion => readers,
        .handler_elimination => handlers,
        .evidence_forwarding => evidence,
        .tail_clauses => handler_tail,
        .slot_packing => packing,
        .outlining => outlining,
        .tail_duplication => duplicate_tails,
        .common_tails => tails,
        .contification => joins,
        .leaf_inlining => leaves,
        .call_patterns => patterns,
        .partial_redundancy => pre,
        else => unreachable,
    };
}
fn applyMeasured(
    comptime stage: Stage,
    a: std.mem.Allocator,
    program: ir.Program,
    options: p01.Options,
    exhausted: *bool,
) Error!p01.Owned {
    const implementation = measuredStage(stage);
    var stats: implementation.Statistics = .{};
    const result = try implementation.run(a, program, &stats, .{ .coalescing = options });
    exhausted.* = stats.work_limit;
    return result;
}
fn applyProof(
    comptime implementation: type,
    a: std.mem.Allocator,
    program: ir.Program,
    options: p01.Options,
    exhausted: *bool,
) Error!p01.Owned {
    var stats: implementation.Statistics = .{};
    const result = try implementation.run(a, program, &stats, options);
    exhausted.* = stats.proof_work_limit;
    return result;
}
fn applySaturation(
    a: std.mem.Allocator,
    program: ir.Program,
    options: p01.Options,
    search_exhaustions: *usize,
) Error!p01.Owned {
    var stats: saturation.Statistics = .{};
    const result = try saturation.run(a, program, &stats, .{ .coalescing = options });
    // Section 7.4: bounded search keeps its checked stage incumbent;
    // it does not authorize unfinished analysis or alter P01 rollback.
    search_exhaustions.* += @intFromBool(stats.work_limit);
    return result;
}
fn applyAffine(
    a: std.mem.Allocator,
    program: ir.Program,
    options: p01.Options,
    exhausted: *bool,
) Error!p01.Owned {
    for (program.constructors, 0..) |_, id| {
        var stats: affine.Statistics = .{};
        var result = try affine.run(a, program, id, &stats, 1_000_000, options);
        if (stats.outcome == .work_limit) {
            exhausted.* = true;
            return result;
        }
        if (stats.outcome == .applied) return result;
        result.deinit();
    }
    for (program.functions, 0..) |_, id| {
        const target = affine.directTarget(program, id) orelse continue;
        var stats: affine.Statistics = .{};
        var result = try affine.runTarget(a, program, target, &stats, 1_000_000, options);
        if (stats.outcome == .work_limit) {
            exhausted.* = true;
            return result;
        }
        if (stats.outcome == .applied) return result;
        result.deinit();
    }
    return p01.run(a, program, options);
}
fn apply(
    a: std.mem.Allocator,
    program: ir.Program,
    stage: Stage,
    options: p01.Options,
    exhausted: *bool,
    search_exhaustions: *usize,
) Error!p01.Owned {
    return switch (stage) {
        .p01 => unreachable,
        .branch => applyProof(branch, a, program, options, exhausted),
        .applications => applyProof(applications, a, program, options, exhausted),
        .aggregates => aggregates.run(a, program, null, options),
        .equality_saturation => applySaturation(a, program, options, search_exhaustions),
        inline .expressions,
        .rectangular_tiling,
        .rectangular_loops,
        .induction_guards,
        .induction_affine,
        .loop_unswitch,
        .loop_motion,
        .constructor_contexts,
        .context_compression,
        .thunk_forwarding,
        .unfold_fusion,
        .sequence_fusion,
        .reader_fusion,
        .handler_elimination,
        .evidence_forwarding,
        .tail_clauses,
        .slot_packing,
        .outlining,
        .tail_duplication,
        .common_tails,
        .contification,
        .leaf_inlining,
        .call_patterns,
        .partial_redundancy,
        => |selected| applyMeasured(selected, a, program, options, exhausted),
        .cells => cells.run(a, program, null, options),
        .dead_computation => unreachable, // Budgeted rounds are owned by applyWithWork.
        .dead_arguments => arguments.run(a, program, null, options),
        .dead_captures => captures.run(a, program, null, options),
        .capture_projection => projections.run(a, program, null, options),
        .capture_summary => summaries.run(a, program, null, options),
        .capture_unpack => unpack.run(a, program, options),
        .affine_state => applyAffine(a, program, options, exhausted),
    };
}

test "admission-set cost guard bounds growth without host allocator capacities" {
    const baseline: Cost = .{
        .bytes = 100,
        .work = 20,
        .retention = 0,
        .admission_sets = @splat(10_000),
    };
    var candidate = baseline;
    candidate.admission_sets[0] += 1024;
    try std.testing.expect(admissionGrowthAllowed(candidate, baseline));
    candidate.admission_sets[0] += 1;
    try std.testing.expect(!admissionGrowthAllowed(candidate, baseline));
    // A smaller image or less estimated work cannot erase this dimension.
    candidate.bytes = 1;
    candidate.work = 0;
    try std.testing.expect(!admissionGrowthAllowed(candidate, baseline));
    candidate.admission_sets = @splat(0);
    try std.testing.expect(admissionGrowthAllowed(candidate, baseline));
    const largest: Cost = .{
        .bytes = 100,
        .work = 20,
        .retention = 0,
        .admission_sets = @splat(std.math.maxInt(u64)),
    };
    try std.testing.expect(admissionGrowthAllowed(largest, largest));
}

test "candidate admission cost accounts for a wasm growth cliff hidden by native capacity" {
    try std.testing.expectEqual(@as(u64, 692), try nodeCapacityEstimate(536, 8));
    try std.testing.expectEqual(@as(u64, 692), try nodeCapacityEstimate(553, 8));
    try std.testing.expectEqual(@as(u64, 542), try nodeCapacityEstimate(536, 2));
    try std.testing.expectEqual(@as(u64, 816), try nodeCapacityEstimate(553, 2));
    const before: Cost = .{
        .bytes = 3064,
        .work = 200,
        .retention = 0,
        .admission_sets = try admissionSetCost(536, 1024),
    };
    const after: Cost = .{
        .bytes = 3047,
        .work = 190,
        .retention = 0,
        .admission_sets = try admissionSetCost(553, 1024),
    };
    try std.testing.expect(!admissionGrowthAllowed(after, before));
}

test "activation path cost is exact for a simple chain and unknown for a CFG cycle" {
    const a = std.testing.allocator;
    var blocks = [_]ir.Block{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 0, .opcode = .constant }},
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.unit},
        .constants = &.{.{ .schema = 0, .bytes = &.{} }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &blocks,
    };
    try std.testing.expectEqual(@as(?u64, 3), try pathWork(a, program));
    blocks[1].terminator = .{ .jump = .{ .block = 0 } };
    try std.testing.expectEqual(@as(?u64, null), try pathWork(a, program));
}

test "entry-path estimate expands known direct calls and declines recursion" {
    const a = std.testing.allocator;
    var blocks = [_]ir.Block{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 0, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 0, .opcode = .constant }},
            .terminator = .{ .return_value = 0 },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.unit},
        .constants = &.{.{ .schema = 0, .bytes = &.{} }},
        .effects = &.{},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
            .{ .entry = 2, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
        },
        .blocks = &blocks,
    };
    try std.testing.expectEqual(@as(?u64, 4), try pathWork(a, program));
    blocks[2].terminator = .{ .call = .{
        .function = 0,
        .arguments = &.{},
        .next = .{ .block = 3, .assignments = &.{.{ .destination = 0, .source = .returned }} },
    } };
    try std.testing.expectEqual(@as(?u64, null), try pathWork(a, program));
}

test "balanced selection observes recursive context removal without relaxing hard guards" {
    const before: Cost = .{
        .bytes = 100,
        .work = 10,
        .retention = 0,
        .recursive_contexts = 1,
        .admission_sets = @splat(1000),
    };
    const after: Cost = .{
        .bytes = 120,
        .work = 12,
        .retention = 0,
        .recursive_contexts = 0,
        .admission_sets = @splat(1000),
    };
    try std.testing.expect(better(after, before, .balanced));
    try std.testing.expect(!better(after, before, .size));
    var expensive = after;
    expensive.admission_sets = @splat(3000);
    try std.testing.expect(!admissionGrowthAllowed(expensive, before));
}

fn estimateProgram(schemas: []const p.Schema, blocks: []const ir.Block) ir.Program {
    return .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = schemas,
        .constants = &.{},
        .effects = &.{},
        .functions = &.{},
        .blocks = blocks,
    };
}

test "closed estimates preserve payload sharing cycles and saturation" {
    const schemas = [_]p.Schema{
        .{ .product = &.{ 1, 2, 1 } },
        .{ .array = .{ .element = 3, .length = 3 } },
        .{ .product = &.{ 0, 3 } },
        .u16,
        .{ .array = .{ .element = 5, .length = std.math.maxInt(u64) } },
        .u64,
        .{ .array = .{ .element = 6, .length = 0 } },
    };
    const program = estimateProgram(&schemas, &.{});
    var memo: [schemas.len]?u64 = @splat(null);
    var active: [schemas.len]bool = @splat(false);
    try std.testing.expectEqual(@as(u64, 22), payloadEstimate(program, 0, 0, &memo, &active));
    try std.testing.expectEqual(@as(?u64, 6), memo[1]);
    try std.testing.expectEqual(@as(?u64, 10), memo[2]);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        payloadEstimate(program, 4, 0, &memo, &active),
    );
    try std.testing.expectEqual(@as(u64, 0), payloadEstimate(program, 6, 0, &memo, &active));
    for (active) |mark| try std.testing.expect(!mark);
}

test "closed estimates preserve payload depth before memo lookup" {
    var schemas: [33]p.Schema = undefined;
    for (schemas[0..32], 0..) |*schema, index|
        schema.* = .{ .array = .{ .element = index + 1, .length = 2 } };
    schemas[32] = .unit;
    const program = estimateProgram(&schemas, &.{});
    var memo: [schemas.len]?u64 = @splat(null);
    var active: [schemas.len]bool = @splat(false);
    try std.testing.expectEqual(
        @as(u64, 8) << 32,
        payloadEstimate(program, 0, 0, &memo, &active),
    );
    try std.testing.expectEqual(@as(?u64, null), memo[32]);
    try std.testing.expectEqual(@as(?u64, 16), memo[31]);
    memo[32] = 0;
    try std.testing.expectEqual(@as(u64, 8), payloadEstimate(program, 32, 32, &memo, &active));
    for (active) |mark| try std.testing.expect(!mark);
}

test "closed estimates preserve path depth before memo lookup" {
    var blocks: [513]ir.Block = undefined;
    for (&blocks, 0..) |*block, index| block.* = .{
        .function = 0,
        .instructions = &.{},
        .terminator = if (index == 511 or index == 512)
            .{ .return_value = 0 }
        else
            .{ .jump = .{ .block = index + 1 } },
    };
    const program = estimateProgram(&.{.unit}, &blocks);
    var marks: [blocks.len]u8 = @splat(0);
    var memo: [blocks.len]u64 = @splat(0);
    try std.testing.expectEqual(@as(?u64, 512), pathAt(program, 0, &marks, &memo, 0));
    blocks[511].terminator = .{ .jump = .{ .block = 512 } };
    @memset(&marks, 0);
    marks[512] = 2;
    memo[512] = 1;
    try std.testing.expectEqual(@as(?u64, null), pathAt(program, 0, &marks, &memo, 0));
    try std.testing.expectEqual(@as(u8, 1), marks[511]);
    try std.testing.expectEqual(@as(u8, 2), marks[512]);
}
