// Copyright (c) 2026 Boundary contributors. MIT license.
//! P24: interchange a rectangular, total u64 XOR reduction over admitted records.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const loops = @import("loop_regions.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || loops.Error || error{InvalidRectangularLoop};
pub const Options = struct { work_limit: u64 = 2_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct { interchanges: usize = 0, work_limit: bool = false };
pub const Shape = struct {
    entry: usize,
    outer: usize,
    reset: usize,
    inner: usize,
    body: usize,
    latch: usize,
    exit: usize,
    i: p.Id,
    j: p.Id,
    n: p.Id,
    m: p.Id,
    accumulator: p.Id,
    one: p.Id,
    rows: u64,
    columns: u64,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    shape: Shape,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn jump(block: ir.Block) ?usize {
    if (block.terminator != .jump or block.terminator.jump.assignments.len != 0) return null;
    return @intCast(block.terminator.jump.block);
}
fn branch(block: ir.Block) bool {
    return block.instructions.len == 1 and
        block.instructions[0].opcode == .less and
        block.instructions[0].operands.len == 2 and
        block.instructions[0].failures.len == 0 and
        block.terminator == .branch and
        block.instructions[0].destination == block.terminator.branch.condition and
        block.terminator.branch.when_true.assignments.len == 0 and
        block.terminator.branch.when_false.assignments.len == 0;
}
fn constant(program: ir.Program, op: ir.Instruction) ?u64 {
    if (op.opcode != .constant or op.operands.len != 0 or op.failures.len != 0) return null;
    const value = program.constants[@intCast(op.immediate)];
    if (program.schemas[@intCast(value.schema)] != .u64 or value.bytes.len != 8) return null;
    return std.mem.readInt(u64, value.bytes[0..8], .little);
}
fn initial(program: ir.Program, entry: ir.Block, slot: p.Id) ?u64 {
    var found: ?u64 = null;
    for (entry.instructions) |op| if (op.destination == slot) {
        if (found != null) return null;
        found = constant(program, op) orelse return null;
    };
    return found;
}
fn increment(op: ir.Instruction, index: p.Id, one: p.Id) bool {
    if (op.destination != index or op.opcode != .integer_add or !std.mem.eql(
        p.Id,
        op.operands,
        &.{ index, one },
    )) return false;
    for (op.failures) |fault| if (fault.kind != .arithmetic_overflow) return false;
    return true;
}
pub fn analyze(a: std.mem.Allocator, program: ir.Program, budget: *loops.Budget) Error!?Shape {
    try budget.record(ir.Program, program);
    if (program.functions.len != 1 or program.blocks.len != 7) return null;
    const f = program.functions[0];
    if (program.roots.entry != 0 or
        f.effects.len != 0 or
        f.regions.len != 0 or
        f.custody.len != 1)
        return null;
    for (program.blocks) |block| if (block.function != 0 or block.custody != 0) return null;
    const entry: usize = @intCast(f.entry);
    const outer = jump(program.blocks[entry]) orelse return null;
    if (!branch(program.blocks[outer])) return null;
    const reset: usize = @intCast(program.blocks[outer].terminator.branch.when_true.block);
    const exit: usize = @intCast(program.blocks[outer].terminator.branch.when_false.block);
    const inner = jump(program.blocks[reset]) orelse return null;
    if (!branch(program.blocks[inner])) return null;
    const body: usize = @intCast(program.blocks[inner].terminator.branch.when_true.block);
    const latch: usize = @intCast(program.blocks[inner].terminator.branch.when_false.block);
    const ids = [_]usize{ entry, outer, reset, inner, body, latch, exit };
    for (ids, 0..) |id, at| for (ids[0..at]) |other| if (id == other) return null;
    if (jump(program.blocks[body]) != inner or jump(program.blocks[latch]) != outer) return null;
    if (program.blocks[exit].instructions.len != 0 or
        program.blocks[exit].terminator != .return_value)
        return null;
    const i = program.blocks[outer].instructions[0].operands[0];
    const n = program.blocks[outer].instructions[0].operands[1];
    const j = program.blocks[inner].instructions[0].operands[0];
    const m = program.blocks[inner].instructions[0].operands[1];
    const accumulator = program.blocks[exit].terminator.return_value;
    const tail = program.blocks[latch].instructions;
    if (tail.len != 1 or tail[0].operands.len != 2) return null;
    const one = tail[0].operands[1];
    const roles = [_]p.Id{ i, j, n, m, accumulator, one };
    for (roles, 0..) |slot, at| {
        if (program.schemas[@intCast(f.layout.slots[@intCast(slot)])] != .u64) return null;
        for (roles[0..at]) |other| if (slot == other) return null;
        if (std.mem.indexOfScalar(p.Id, f.inputs, slot) != null) return null;
    }
    const init = program.blocks[entry];
    if (init.instructions.len != 5 or initial(program, init, i) != 0 or initial(program, init, accumulator) != 0 or initial(program, init, one) != 1) return null;
    const rows = initial(program, init, n) orelse return null;
    const columns = initial(program, init, m) orelse return null;
    const resets = program.blocks[reset].instructions;
    if (resets.len != 1 or resets[0].destination != j or constant(
        program,
        resets[0],
    ) != 0) return null;
    const work = program.blocks[body].instructions;
    if (work.len < 2 or !increment(work[work.len - 1], j, one) or !increment(tail[0], i, one)) return null;
    const reduction = work[work.len - 2];
    if (reduction.opcode != .integer_bit_xor or
        reduction.destination != accumulator or
        reduction.operands.len != 2 or
        reduction.operands[0] != accumulator or
        reduction.failures.len != 0)
        return null;
    const available = try a.alloc(bool, f.layout.slots.len);
    @memset(available, false);
    for (f.inputs) |slot| {
        if (program.schemas[@intCast(f.layout.slots[@intCast(slot)])] != .u64) return null;
        available[@intCast(slot)] = true;
    }
    for ([_]p.Id{ i, j, n, m, one }) |slot| available[@intCast(slot)] = true;
    for (work[0 .. work.len - 2]) |op| {
        try budget.take(1);
        if (op.failures.len != 0 or available[
            @intCast(op.destination)
        ] or op.destination == accumulator or program.schemas[
            @intCast(f.layout.slots[
                @intCast(op.destination)
            ])
        ] != .u64) return null;
        switch (op.opcode) {
            .integer_bit_xor, .integer_bit_and, .integer_bit_or => if (op.operands.len != 2)
                return null,
            .integer_bit_not, .move => if (op.operands.len != 1) return null,
            else => return null,
        }
        for (op.operands) |slot| if (!available[@intCast(slot)]) return null;
        available[@intCast(op.destination)] = true;
    }
    if (!available[@intCast(reduction.operands[1])]) return null;
    return .{
        .entry = entry,
        .outer = outer,
        .reset = reset,
        .inner = inner,
        .body = body,
        .latch = latch,
        .exit = exit,
        .i = i,
        .j = j,
        .n = n,
        .m = m,
        .accumulator = accumulator,
        .one = one,
        .rows = rows,
        .columns = columns,
    };
}
fn replacement(op: ir.Instruction, destination: p.Id, operands: []const p.Id) ir.Instruction {
    var result = op;
    result.destination = destination;
    result.operands = operands;
    return result;
}
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
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    const s = (try analyze(a, original, &budget)) orelse return null;
    // Fewer outer resets/guards; also makes this orientation idempotent.
    if (s.rows <= s.columns) return null;
    const blocks = try a.dupe(ir.Block, original.blocks);
    for ([_]usize{
        s.entry,
        s.outer,
        s.reset,
        s.inner,
        s.body,
        s.latch,
    }) |bid| blocks[bid].instructions = try a.dupe(
        ir.Instruction,
        original.blocks[bid].instructions,
    );
    const entry = @constCast(blocks[s.entry].instructions);
    for (entry) |*op| if (op.destination == s.i) {
        op.destination = s.j;
    };
    @constCast(blocks[s.reset].instructions)[0].destination = s.i;
    @constCast(blocks[s.outer].instructions)[0].operands = try a.dupe(p.Id, &.{ s.j, s.m });
    @constCast(blocks[s.inner].instructions)[0].operands = try a.dupe(p.Id, &.{ s.i, s.n });
    const body = @constCast(blocks[s.body].instructions);
    body[body.len - 1] = replacement(body[body.len - 1], s.i, try a.dupe(p.Id, &.{ s.i, s.one }));
    const latch = @constCast(blocks[s.latch].instructions);
    latch[0] = replacement(latch[0], s.j, try a.dupe(p.Id, &.{ s.j, s.one }));
    var program = original;
    program.blocks = blocks;
    keep = true;
    return .{ .arena = arena, .program = program, .shape = s };
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Shape,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    try budget.record(ir.Program, candidate);
    const s = (try analyze(
        arena.allocator(),
        original,
        &budget,
    )) orelse return error.InvalidRectangularLoop;
    if (!std.meta.eql(s, witness) or
        s.rows <= s.columns or
        candidate.blocks.len != original.blocks.len)
        return error.InvalidRectangularLoop;
    var rest = candidate;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidRectangularLoop;
    for (original.blocks, candidate.blocks, 0..) |old, new, bid| {
        try budget.take(1);
        if (old.function != new.function or old.custody != new.custody or !equal(
            ir.Terminator,
            old.terminator,
            new.terminator,
        ) or old.instructions.len != new.instructions.len) return error.InvalidRectangularLoop;
        for (old.instructions, new.instructions, 0..) |op, actual, at| {
            var expected = op;
            if (bid == s.entry and op.destination == s.i) expected.destination = s.j;
            if (bid == s.reset) expected.destination = s.i;
            if (bid == s.outer) expected.operands = &.{ s.j, s.m };
            if (bid == s.inner) expected.operands = &.{ s.i, s.n };
            if (bid == s.body and at == old.instructions.len - 1) expected = replacement(
                op,
                s.i,
                &.{ s.i, s.one },
            );
            if (bid == s.latch) expected = replacement(op, s.j, &.{ s.j, s.one });
            if (!equal(ir.Instruction, expected, actual)) return error.InvalidRectangularLoop;
        }
    }
}

pub fn possible(program: ir.Program) bool {
    return program.functions.len == 1 and program.blocks.len == 7;
}
/// Exact logical instruction/terminator count for the recognized fragment.
/// Overflow means unknown, never a saturated estimate or permission to reorder.
pub fn executionWork(allocator: std.mem.Allocator, program: ir.Program) Error!?u64 {
    if (!possible(program)) return null;
    var admitted = try own.analyze(allocator, program);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: loops.Budget = .{ .remaining = 2_000_000 };
    const s = (analyze(arena.allocator(), program, &budget) catch |err| switch (err) {
        error.LoopWorkLimit => return null,
        else => return err,
    }) orelse return null;
    const points = std.math.mul(u64, s.rows, s.columns) catch return null;
    const visits = std.math.mul(
        u64,
        points,
        program.blocks[s.body].instructions.len + 3,
    ) catch return null;
    const control = std.math.mul(u64, 8, s.rows) catch return null;
    return std.math.add(u64, std.math.add(u64, visits, control) catch return null, 9) catch null;
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
        error.LoopWorkLimit => {
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
        candidate.shape,
        options,
    ) catch |err| switch (err) {
        error.LoopWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.interchanges = 1;
    return result;
}
