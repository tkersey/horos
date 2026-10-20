// Copyright (c) 2026 Boundary contributors. MIT license.
//! Fixed four-by-four tiles over the independently recognized P24 domain.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const loops = @import("loop_regions.zig");
const rectangle = @import("rectangular_loops.zig");
const equal = @import("record_equal.zig").equal;
const image = @import("program_image.zig");
const p01 = @import("coalescing.zig");
pub const tile_width: u64 = 4;
pub const Error = rectangle.Error || error{InvalidRectangularTiling};
pub const Options = struct {
    work_limit: u64 = 2_000_000,
    max_added_bytes: usize = 4096,
    coalescing: p01.Options = .{},
};
pub const Statistics = struct {
    candidates: usize = 0,
    tiled: usize = 0,
    economic_rejection: bool = false,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    source: rectangle.Shape,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn block(
    a: std.mem.Allocator,
    instructions: []const ir.Instruction,
    term: ir.Terminator,
) !ir.Block {
    const ops = try a.dupe(ir.Instruction, instructions);
    for (ops) |*op| op.operands = try a.dupe(p.Id, op.operands);
    return .{ .function = 0, .instructions = ops, .terminator = term };
}
fn move(destination: p.Id, source: []const p.Id) ir.Instruction {
    return .{ .destination = destination, .opcode = .move, .operands = source };
}
fn testBranch(condition: p.Id, yes: p.Id, no: p.Id) ir.Terminator {
    return .{ .branch = .{
        .condition = condition,
        .when_true = .{ .block = yes },
        .when_false = .{ .block = no },
    } };
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
    const s = (try rectangle.analyze(a, original, &budget)) orelse return null;
    const old = original.functions[0];
    const schema = old.layout.slots[@intCast(s.i)];
    for ([_]p.Id{
        s.j,
        s.n,
        s.m,
        s.one,
    }) |slot| if (old.layout.slots[@intCast(slot)] != schema) return null;
    const functions = try a.dupe(ir.Function, original.functions);
    const slots = try a.alloc(p.Id, old.layout.slots.len + 6);
    @memcpy(slots[0..old.layout.slots.len], old.layout.slots);
    @memset(slots[old.layout.slots.len..], schema);
    functions[0].entry = 0;
    functions[0].layout.slots = slots;
    const constants = try a.alloc(p.Literal, original.constants.len + 1);
    @memcpy(constants[0..original.constants.len], original.constants);
    const encoded = try a.alloc(u8, 8);
    std.mem.writeInt(u64, encoded[0..8], tile_width, .little);
    constants[original.constants.len] = .{ .schema = schema, .bytes = encoded };
    const blocks = try a.alloc(ir.Block, 13);
    try emitInitial(a, original, s, blocks);
    try emitRows(a, original, s, blocks);
    try emitColumns(a, original, s, blocks);
    try emitBody(a, original, s, blocks);
    var program = original;
    program.blocks = blocks;
    program.functions = functions;
    program.constants = constants;
    keep = true;
    return .{ .arena = arena, .program = program, .source = s };
}
fn emitInitial(
    a: std.mem.Allocator,
    original: ir.Program,
    s: rectangle.Shape,
    blocks: []ir.Block,
) Error!void {
    const old = original.functions[0];
    const start: p.Id = @intCast(old.layout.slots.len);
    const ai = start;
    const width = start + 5;
    const init = try a.alloc(ir.Instruction, original.blocks[s.entry].instructions.len + 2);
    @memcpy(init[0 .. init.len - 2], original.blocks[s.entry].instructions);
    init[init.len - 2] = .{
        .destination = width,
        .opcode = .constant,
        .immediate = original.constants.len,
    };
    init[init.len - 1] = move(ai, &.{s.i});
    blocks[0] = try block(a, init, .{ .jump = .{ .block = 1 } });
}
fn emitRows(
    a: std.mem.Allocator,
    original: ir.Program,
    s: rectangle.Shape,
    blocks: []ir.Block,
) Error!void {
    const old = original.functions[0];
    const start: p.Id = @intCast(old.layout.slots.len);
    const ai = start;
    const ei = start + 2;
    const scratch = start + 4;
    const width = start + 5;
    const condition = original.blocks[s.outer].instructions[0].destination;
    const failures = original.blocks[s.latch].instructions[0].failures;
    const bj = start + 1;
    var reset = original.blocks[s.reset].instructions[0];
    reset.destination = bj;
    blocks[1] = try block(
        a,
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ ai, s.n } }},
        testBranch(condition, 2, 12),
    );
    blocks[2] = try block(a, &.{
        .{
            .destination = scratch,
            .opcode = .integer_sub,
            .operands = &.{ s.n, ai },
            .failures = failures,
        },
        .{ .destination = condition, .opcode = .less, .operands = &.{ scratch, width } },
        .{ .destination = scratch, .opcode = .select, .operands = &.{ condition, scratch, width } },
        .{
            .destination = ei,
            .opcode = .integer_add,
            .operands = &.{ ai, scratch },
            .failures = failures,
        },
        reset,
    }, .{ .jump = .{ .block = 3 } });
}
fn emitColumns(
    a: std.mem.Allocator,
    original: ir.Program,
    s: rectangle.Shape,
    blocks: []ir.Block,
) Error!void {
    const old = original.functions[0];
    const start: p.Id = @intCast(old.layout.slots.len);
    const ai = start;
    const bj = start + 1;
    const ej = start + 3;
    const scratch = start + 4;
    const width = start + 5;
    const condition = original.blocks[s.outer].instructions[0].destination;
    const failures = original.blocks[s.latch].instructions[0].failures;
    blocks[3] = try block(
        a,
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ bj, s.m } }},
        testBranch(condition, 4, 11),
    );
    blocks[4] = try block(a, &.{
        .{
            .destination = scratch,
            .opcode = .integer_sub,
            .operands = &.{ s.m, bj },
            .failures = failures,
        },
        .{ .destination = condition, .opcode = .less, .operands = &.{ scratch, width } },
        .{ .destination = scratch, .opcode = .select, .operands = &.{ condition, scratch, width } },
        .{
            .destination = ej,
            .opcode = .integer_add,
            .operands = &.{ bj, scratch },
            .failures = failures,
        },
        move(s.i, &.{ai}),
    }, .{ .jump = .{ .block = 5 } });
}
fn emitBody(
    a: std.mem.Allocator,
    original: ir.Program,
    s: rectangle.Shape,
    blocks: []ir.Block,
) Error!void {
    const old = original.functions[0];
    const start: p.Id = @intCast(old.layout.slots.len);
    const ai = start;
    const bj = start + 1;
    const ei = start + 2;
    const ej = start + 3;
    const condition = original.blocks[s.outer].instructions[0].destination;
    blocks[5] = try block(
        a,
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ s.i, ei } }},
        testBranch(condition, 6, 10),
    );
    blocks[6] = try block(a, &.{move(s.j, &.{bj})}, .{ .jump = .{ .block = 7 } });
    blocks[7] = try block(
        a,
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ s.j, ej } }},
        testBranch(condition, 8, 9),
    );
    blocks[8] = try block(a, original.blocks[s.body].instructions, .{ .jump = .{ .block = 7 } });
    blocks[9] = try block(a, original.blocks[s.latch].instructions, .{ .jump = .{ .block = 5 } });
    blocks[10] = try block(a, &.{move(bj, &.{ej})}, .{ .jump = .{ .block = 3 } });
    blocks[11] = try block(a, &.{move(ai, &.{ei})}, .{ .jump = .{ .block = 1 } });
    blocks[12] = try block(a, &.{}, .{ .return_value = s.accumulator });
}
fn check(actual: ir.Block, instructions: []const ir.Instruction, term: ir.Terminator) Error!void {
    if (actual.function != 0 or actual.custody != 0 or !equal(
        []const ir.Instruction,
        actual.instructions,
        instructions,
    ) or !equal(ir.Terminator, actual.terminator, term)) return error.InvalidRectangularTiling;
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: rectangle.Shape,
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
    const s = (try rectangle.analyze(
        arena.allocator(),
        original,
        &budget,
    )) orelse return error.InvalidRectangularTiling;
    if (!std.meta.eql(s, witness) or
        candidate.blocks.len != 13 or
        candidate.functions.len != 1 or
        candidate.constants.len != original.constants.len + 1)
        return error.InvalidRectangularTiling;
    var rest = candidate;
    rest.blocks = original.blocks;
    rest.functions = original.functions;
    rest.constants = original.constants;
    if (!equal(ir.Program, original, rest)) return error.InvalidRectangularTiling;
    try validateMetadata(original, candidate, s);
    try validateInitial(original, candidate, s);
    try validateRows(original, candidate, s);
    try validateColumns(original, candidate, s);
    try validateBody(original, candidate, s);
}
fn validateMetadata(
    original: ir.Program,
    candidate: ir.Program,
    s: rectangle.Shape,
) Error!void {
    const old = original.functions[0];
    const changed = candidate.functions[0];
    const start = old.layout.slots.len;
    const schema = old.layout.slots[@intCast(s.i)];
    if (changed.entry != 0 or changed.layout.slots.len != start + 6 or !std.mem.eql(
        p.Id,
        old.layout.slots,
        changed.layout.slots[0..start],
    )) return error.InvalidRectangularTiling;
    for ([_]p.Id{
        s.j,
        s.n,
        s.m,
        s.one,
    }) |slot| if (old.layout.slots[@intCast(slot)] != schema) return error.InvalidRectangularTiling;
    for (changed.layout.slots[start..]) |sid|
        if (sid != schema)
            return error.InvalidRectangularTiling;
    var metadata = changed;
    metadata.entry = old.entry;
    metadata.layout = old.layout;
    if (!equal(ir.Function, old, metadata) or !equal(
        []const p.Literal,
        original.constants,
        candidate.constants[0..original.constants.len],
    )) return error.InvalidRectangularTiling;
    const literal = candidate.constants[original.constants.len];
    if (literal.schema != schema or literal.bytes.len != 8 or std.mem.readInt(
        u64,
        literal.bytes[0..8],
        .little,
    ) != tile_width) return error.InvalidRectangularTiling;
}
fn validateInitial(
    original: ir.Program,
    candidate: ir.Program,
    s: rectangle.Shape,
) Error!void {
    const start = original.functions[0].layout.slots.len;
    const ai: p.Id = @intCast(start);
    const width = ai + 5;
    const first = candidate.blocks[0];
    const initial = original.blocks[s.entry].instructions;
    if (first.function != 0 or
        first.custody != 0 or
        first.instructions.len != initial.len + 2 or
        !equal([]const ir.Instruction, initial, first.instructions[0..initial.len]) or
        !equal(ir.Terminator, first.terminator, .{ .jump = .{ .block = 1 } }))
        return error.InvalidRectangularTiling;
    if (!equal(
        ir.Instruction,
        first.instructions[initial.len],
        .{ .destination = width, .opcode = .constant, .immediate = original.constants.len },
    ) or !equal(
        ir.Instruction,
        first.instructions[initial.len + 1],
        .{ .destination = ai, .opcode = .move, .operands = &.{s.i} },
    )) return error.InvalidRectangularTiling;
}
fn validateRows(
    original: ir.Program,
    candidate: ir.Program,
    s: rectangle.Shape,
) Error!void {
    const start = original.functions[0].layout.slots.len;
    const ai: p.Id = @intCast(start);
    const bj = ai + 1;
    const ei = ai + 2;
    const scratch = ai + 4;
    const width = ai + 5;
    const condition = original.blocks[s.outer].instructions[0].destination;
    const failures = original.blocks[s.latch].instructions[0].failures;
    // Reconstruct the range and transfer equations, not an emitted candidate.
    try check(
        candidate.blocks[1],
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ ai, s.n } }},
        .{ .branch = .{
            .condition = condition,
            .when_true = .{ .block = 2 },
            .when_false = .{ .block = 12 },
        } },
    );
    var reset = original.blocks[s.reset].instructions[0];
    reset.destination = bj;
    try check(candidate.blocks[2], &.{
        .{
            .destination = scratch,
            .opcode = .integer_sub,
            .operands = &.{ s.n, ai },
            .failures = failures,
        },
        .{ .destination = condition, .opcode = .less, .operands = &.{ scratch, width } },
        .{ .destination = scratch, .opcode = .select, .operands = &.{ condition, scratch, width } },
        .{
            .destination = ei,
            .opcode = .integer_add,
            .operands = &.{ ai, scratch },
            .failures = failures,
        },
        reset,
    }, .{ .jump = .{ .block = 3 } });
}
fn validateColumns(
    original: ir.Program,
    candidate: ir.Program,
    s: rectangle.Shape,
) Error!void {
    const start = original.functions[0].layout.slots.len;
    const ai: p.Id = @intCast(start);
    const bj = ai + 1;
    const ej = ai + 3;
    const scratch = ai + 4;
    const width = ai + 5;
    const condition = original.blocks[s.outer].instructions[0].destination;
    const failures = original.blocks[s.latch].instructions[0].failures;
    try check(
        candidate.blocks[3],
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ bj, s.m } }},
        .{ .branch = .{
            .condition = condition,
            .when_true = .{ .block = 4 },
            .when_false = .{ .block = 11 },
        } },
    );
    try check(candidate.blocks[4], &.{
        .{
            .destination = scratch,
            .opcode = .integer_sub,
            .operands = &.{ s.m, bj },
            .failures = failures,
        },
        .{ .destination = condition, .opcode = .less, .operands = &.{ scratch, width } },
        .{ .destination = scratch, .opcode = .select, .operands = &.{ condition, scratch, width } },
        .{
            .destination = ej,
            .opcode = .integer_add,
            .operands = &.{ bj, scratch },
            .failures = failures,
        },
        .{ .destination = s.i, .opcode = .move, .operands = &.{ai} },
    }, .{ .jump = .{ .block = 5 } });
}
fn validateBody(
    original: ir.Program,
    candidate: ir.Program,
    s: rectangle.Shape,
) Error!void {
    const start = original.functions[0].layout.slots.len;
    const ai: p.Id = @intCast(start);
    const bj = ai + 1;
    const ei = ai + 2;
    const ej = ai + 3;
    const condition = original.blocks[s.outer].instructions[0].destination;
    try check(
        candidate.blocks[5],
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ s.i, ei } }},
        .{ .branch = .{
            .condition = condition,
            .when_true = .{ .block = 6 },
            .when_false = .{ .block = 10 },
        } },
    );
    try check(
        candidate.blocks[6],
        &.{.{ .destination = s.j, .opcode = .move, .operands = &.{bj} }},
        .{ .jump = .{ .block = 7 } },
    );
    try check(
        candidate.blocks[7],
        &.{.{ .destination = condition, .opcode = .less, .operands = &.{ s.j, ej } }},
        .{ .branch = .{
            .condition = condition,
            .when_true = .{ .block = 8 },
            .when_false = .{ .block = 9 },
        } },
    );
    try check(
        candidate.blocks[8],
        original.blocks[s.body].instructions,
        .{ .jump = .{ .block = 7 } },
    );
    try check(
        candidate.blocks[9],
        original.blocks[s.latch].instructions,
        .{ .jump = .{ .block = 5 } },
    );
    try check(
        candidate.blocks[10],
        &.{.{ .destination = bj, .opcode = .move, .operands = &.{ej} }},
        .{ .jump = .{ .block = 3 } },
    );
    try check(
        candidate.blocks[11],
        &.{.{ .destination = ai, .opcode = .move, .operands = &.{ei} }},
        .{ .jump = .{ .block = 1 } },
    );
    try check(candidate.blocks[12], &.{}, .{ .return_value = s.accumulator });
}

pub fn executionWork(s: rectangle.Shape, body_instructions: usize) ?u64 {
    const tr = s.rows / tile_width + @intFromBool(s.rows % tile_width != 0);
    const tc = s.columns / tile_width + @intFromBool(s.columns % tile_width != 0);
    const points = std.math.mul(u64, s.rows, s.columns) catch return null;
    const cells = std.math.mul(u64, tr, tc) catch return null;
    const strips = std.math.mul(u64, s.rows, tc) catch return null;
    var total: u64 = 11;
    for ([_]u64{
        std.math.mul(u64, 12, tr) catch return null,
        std.math.mul(u64, 12, cells) catch return null,
        std.math.mul(u64, 8, strips) catch return null,
        std.math.mul(u64, body_instructions + 3, points) catch return null,
    }) |part| total = std.math.add(u64, total, part) catch return null;
    return total;
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
        candidate.source,
        options,
    ) catch |err| switch (err) {
        error.LoopWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    stats.candidates = 1;
    const before = try rectangle.executionWork(allocator, original);
    const after = executionWork(
        candidate.source,
        original.blocks[candidate.source.body].instructions.len,
    );
    var result = try p01.run(allocator, candidate.program, options.coalescing);
    var keep_result = false;
    defer if (!keep_result) result.deinit();
    const old_bytes = try image.encodedLength(original);
    const new_bytes = try image.encodedLength(result.program);
    if (before == null or
        after == null or
        after.? >= before.? or
        (new_bytes > old_bytes and
            new_bytes - old_bytes > options.max_added_bytes))
    {
        stats.economic_rejection = true;
        return p01.run(allocator, original, options.coalescing);
    }
    stats.tiled = 1;
    keep_result = true;
    return result;
}
