// Copyright (c) 2026 Boundary contributors. MIT license.
//! P16: ordered immutable sequence contexts, with bounded administrative frames.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const admission = @import("admission.zig");
const traits = @import("traits.zig");
const privacy = @import("capture_reduction.zig");
const total = @import("total_clause.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidConstructorContext, ConstructorContextLimit };
pub const Options = struct { work_limit: usize = 10_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct { contexts_lowered: usize = 0, work_limit: bool = false };
const Budget = struct {
    left: usize,
    fn take(self: *@This(), n: usize) Error!void {
        if (n > self.left) return error.ConstructorContextLimit;
        self.left -= n;
    }
    fn record(self: *@This(), comptime T: type, value: T) Error!void {
        try self.take(1);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| try self.record(FieldType, @field(value, field_name)),
            .@"union" => switch (value) {
                inline else => |v| try self.record(@TypeOf(v), v),
            },
            .optional => |info| if (value) |v| {
                try self.record(info.child, v);
            },
            .pointer => |info| for (value) |v| try self.record(info.child, v),
            else => {},
        }
    }
};
const Shape = struct {
    function: p.Id,
    entry: p.Id,
    base: p.Id,
    step: p.Id,
    finish: p.Id,
    sequence: p.Id,
    tail: p.Id,
    accumulator: p.Id,
};
fn operation(op: ir.Instruction, tag: p.Opcode, operands: []const p.Id, immediate: p.Id) bool {
    return op.opcode == tag and op.immediate == immediate and std.mem.eql(
        p.Id,
        op.operands,
        operands,
    );
}
fn distinct(ids: []const p.Id) bool {
    for (ids, 0..) |id, i| if (std.mem.indexOfScalar(p.Id, ids[0..i], id) != null) return false;
    return true;
}
fn recognize(
    program: ir.Program,
    id: p.Id,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!?Shape {
    try budget.take(1);
    if (!privacy.privateDirectWorker(program, id)) return null;
    const f = program.functions[@intCast(id)];
    if (f.inputs.len != 1 or
        f.effects.len != 0 or
        f.regions.len != 0 or
        f.custody.len != 1)
        return null;
    for (f.layout.slots) |schema| {
        try budget.take(1);
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return null;
    }
    const sequence = f.inputs[0];
    const input = program.schemas[@intCast(f.layout.slots[@intCast(sequence)])];
    const output = program.schemas[@intCast(f.result)];
    if (input != .vector or output != .vector) return null;
    const entry = program.blocks[@intCast(f.entry)];
    if (entry.instructions.len != 1 or
        !operation(entry.instructions[0], .sequence_pop, &.{sequence}, 0) or
        entry.instructions[0].failures.len != 0 or
        entry.terminator != .switch_variant)
        return null;
    const pop = entry.instructions[0].destination;
    const branch = entry.terminator.switch_variant;
    if (branch.value != pop or branch.cases.len != 2) return null;
    for (branch.cases) |edge|
        if (edge.assignments.len > 1 or
            (edge.assignments.len == 1 and
                edge.assignments[0].source != .returned))
            return null;
    const base = program.blocks[@intCast(branch.cases[0].block)];
    if (base.instructions.len != 1 or
        !operation(base.instructions[0], .sequence, &.{}, 0) or
        base.instructions[0].failures.len != 0 or
        base.terminator != .return_value or
        base.terminator.return_value != base.instructions[0].destination)
        return null;
    const step = program.blocks[@intCast(branch.cases[1].block)];
    if (step.terminator != .call) return null;
    const bound_payload = branch.cases[1].assignments.len == 1;
    const first: usize = if (bound_payload) 0 else 1;
    if (step.instructions.len < first + 2) return null;
    const pair = if (bound_payload)
        branch.cases[1].assignments[0].destination
    else
        step.instructions[0].destination;
    const head = step.instructions[first].destination;
    const tail = step.instructions[first + 1].destination;
    if ((!bound_payload and !operation(
        step.instructions[0],
        .variant_payload,
        &.{pop},
        1,
    )) or !operation(step.instructions[first], .field, &.{pair}, 0) or !operation(step.instructions[first + 1], .field, &.{pair}, 1)) return null;
    const call = step.terminator.call;
    if (call.function != id or
        !std.mem.eql(p.Id, call.arguments, &.{tail}) or
        call.next.assignments.len != 1 or
        call.next.assignments[0].source != .returned)
        return null;
    const returned = call.next.assignments[0].destination;
    const finish = program.blocks[@intCast(call.next.block)];
    if (finish.instructions.len != 2 or finish.terminator != .return_value) return null;
    const chunk = finish.instructions[0];
    const join = finish.instructions[1];
    if (chunk.opcode != .sequence or
        chunk.immediate != 0 or
        chunk.operands.len == 0 or
        chunk.failures.len != 0 or
        f.layout.slots[
            @intCast(chunk.destination)
        ] != f.result or
        !operation(join, .sequence_concat, &.{ chunk.destination, returned }, 0) or
        join.destination != finish.terminator.return_value)
        return null;
    const bound = std.math.mul(u64, input.vector.maximum, chunk.operands.len) catch return null;
    if (bound > output.vector.maximum or chunk.operands.len > output.vector.maximum) return null;
    // Exact capacities make these authored failures unreachable on both sides.
    for (join.failures) |failure| if (failure.kind != .capacity_exceeded) return null;
    const roles = [_]p.Id{
        sequence,
        pop,
        pair,
        head,
        tail,
        returned,
        chunk.destination,
        join.destination,
    };
    if (!distinct(&roles)) return null;
    for (step.instructions[first + 2 ..]) |op| {
        try budget.take(1);
        if (!total.instruction(
            op,
        ) or op.opcode == .cell_get or op.opcode == .cell_set or std.mem.indexOfScalar(
            p.Id,
            &roles,
            op.destination,
        ) != null) return null;
    }
    // A chunk may only use already computed input/mapping values, never the
    // recursive result or a partially produced output.
    for (chunk.operands) |operand|
        if (operand == returned or
            operand == chunk.destination or
            operand == join.destination)
            return null;
    const ids = [_]p.Id{ f.entry, branch.cases[0].block, branch.cases[1].block, call.next.block };
    if (!distinct(&ids)) return null;
    for (ids) |bid| if (program.blocks[
        @intCast(bid)
    ].function != id or program.blocks[
        @intCast(bid)
    ].custody != 0) return null;
    for (program.blocks, 0..) |block, bid| {
        try budget.take(1);
        if (block.function == id and std.mem.indexOfScalar(p.Id, &ids, bid) == null) return null;
    }
    return .{
        .function = id,
        .entry = f.entry,
        .base = ids[1],
        .step = ids[2],
        .finish = ids[3],
        .sequence = sequence,
        .tail = tail,
        .accumulator = returned,
    };
}
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    sites: []const p.Id,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var admitted = try own.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: Budget = .{ .left = options.work_limit };
    try budget.record(ir.Program, original);
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var shapes: std.ArrayList(Shape) = .empty;
    var sites: std.ArrayList(p.Id) = .empty;
    for (
        original.functions,
        0..,
    ) |_, id| if (try recognize(
        original,
        id,
        permissions,
        schemas.exportable,
        &budget,
    )) |shape| {
        try shapes.append(a, shape);
        try sites.append(a, id);
    };
    if (shapes.items.len == 0) return null;
    const blocks = try a.alloc(
        ir.Block,
        std.math.add(usize, original.blocks.len, shapes.items.len) catch return error.Capacity,
    );
    @memcpy(blocks[0..original.blocks.len], original.blocks);
    for (shapes.items, 0..) |s, index| {
        const header = original.blocks.len + index;
        blocks[header] = original.blocks[@intCast(s.entry)];
        const init_ops = try a.alloc(ir.Instruction, 1);
        init_ops[0] = .{ .destination = s.accumulator, .opcode = .sequence };
        blocks[@intCast(s.entry)].instructions = init_ops;
        blocks[@intCast(s.entry)].terminator = .{ .jump = .{ .block = header } };
        blocks[@intCast(s.base)].instructions = &.{};
        blocks[@intCast(s.base)].terminator = .{ .return_value = s.accumulator };
        const prefix = original.blocks[@intCast(s.step)].instructions;
        const finish = original.blocks[@intCast(s.finish)].instructions;
        const operations = try a.alloc(ir.Instruction, prefix.len + 2);
        @memcpy(operations[0..prefix.len], prefix);
        operations[prefix.len] = finish[0];
        operations[prefix.len + 1] = finish[1];
        operations[prefix.len + 1].destination = s.accumulator;
        operations[prefix.len + 1].operands = try a.dupe(
            p.Id,
            &.{ s.accumulator, finish[0].destination },
        );
        blocks[@intCast(s.step)].instructions = operations;
        const advance = try a.dupe(
            ir.Assignment,
            &.{.{ .destination = s.sequence, .source = .{ .slot = s.tail } }},
        );
        blocks[@intCast(s.step)].terminator = .{ .jump = .{
            .block = header,
            .assignments = advance,
        } };
    }
    var program = original;
    program.blocks = blocks;
    const selected = try sites.toOwnedSlice(a);
    keep = true;
    return .{ .arena = arena, .program = program, .sites = selected };
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    sites: []const p.Id,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var budget: Budget = .{ .left = options.work_limit };
    try budget.record(ir.Program, original);
    try budget.record(ir.Program, candidate);
    if (sites.len == 0 or
        sites.len > original.functions.len or
        candidate.blocks.len != original.blocks.len + sites.len)
        return error.InvalidConstructorContext;
    var rest = candidate;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidConstructorContext;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    const shapes = try a.alloc(Shape, sites.len);
    for (sites, shapes, 0..) |site, *shape, index| {
        try budget.take(index + 1);
        if (site >= original.functions.len or std.mem.indexOfScalar(
            p.Id,
            sites[0..index],
            site,
        ) != null) return error.InvalidConstructorContext;
        shape.* = (try recognize(
            original,
            site,
            permissions,
            schemas.exportable,
            &budget,
        )) orelse return error.InvalidConstructorContext;
    }
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
        try budget.take(1);
        if (old.function != new.function or
            old.custody != new.custody)
            return error.InvalidConstructorContext;
        const index = std.mem.indexOfScalar(p.Id, sites, old.function) orelse {
            if (!equal(ir.Block, old, new)) return error.InvalidConstructorContext;
            continue;
        };
        const s = shapes[index];
        const header = original.blocks.len + index;
        if (bid == s.entry) {
            if (!equal(
                []const ir.Instruction,
                &.{.{ .destination = s.accumulator, .opcode = .sequence }},
                new.instructions,
            ) or !equal(
                ir.Terminator,
                .{ .jump = .{ .block = header } },
                new.terminator,
            )) return error.InvalidConstructorContext;
        } else if (bid == s.base) {
            if (new.instructions.len != 0 or !equal(
                ir.Terminator,
                .{ .return_value = s.accumulator },
                new.terminator,
            )) return error.InvalidConstructorContext;
        } else if (bid == s.step) {
            if (new.instructions.len != old.instructions.len + 2 or !equal(
                []const ir.Instruction,
                old.instructions,
                new.instructions[0..old.instructions.len],
            )) return error.InvalidConstructorContext;
            const finish = original.blocks[@intCast(s.finish)].instructions;
            if (!equal(
                ir.Instruction,
                finish[0],
                new.instructions[old.instructions.len],
            )) return error.InvalidConstructorContext;
            const join = new.instructions[old.instructions.len + 1];
            if (join.destination != s.accumulator or
                join.opcode != .sequence_concat or
                join.immediate != 0 or
                !std.mem.eql(p.Id, join.operands, &.{ s.accumulator, finish[0].destination }) or
                !equal(@TypeOf(join.failures), finish[1].failures, join.failures))
                return error.InvalidConstructorContext;
            if (!equal(
                ir.Terminator,
                .{ .jump = .{
                    .block = header,
                    .assignments = &.{.{
                        .destination = s.sequence,
                        .source = .{ .slot = s.tail },
                    }},
                } },
                new.terminator,
            )) return error.InvalidConstructorContext;
        } else if (!equal(ir.Block, old, new)) return error.InvalidConstructorContext;
    }
    for (
        shapes,
        0..,
    ) |s, index| if (!equal(
        ir.Block,
        original.blocks[@intCast(s.entry)],
        candidate.blocks[original.blocks.len + index],
    )) return error.InvalidConstructorContext;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block|
        if (block.terminator == .call and
            block.terminator.call.function == block.function)
        {
            const f = program.functions[@intCast(block.function)];
            if (f.inputs.len == 1 and program.schemas[@intCast(f.result)] == .vector) return true;
        };
    return false;
}
pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!p01.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var candidate = (construct(allocator, original, options) catch |err| switch (err) {
        error.ConstructorContextLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validate(
        allocator,
        original,
        candidate.program,
        candidate.sites,
        options,
    ) catch |err| switch (err) {
        error.ConstructorContextLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.contexts_lowered = candidate.sites.len;
    return result;
}
