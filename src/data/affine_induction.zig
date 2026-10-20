// Copyright (c) 2026 Boundary contributors. MIT license.
//! P20: checked unsigned i*stride+base becomes a private scalar recurrence.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const loops = @import("loop_regions.zig");
const induction = @import("induction_facts.zig");
const origin = @import("constant_origin.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || loops.Error || error{InvalidAffineInduction};
pub const Options = struct { work_limit: u64 = 2_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct { recurrences: usize = 0, work_limit: bool = false };
pub const Witness = struct { header: usize, instruction: usize };
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    witness: Witness,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn permitted(
    program: ir.Program,
    fid: usize,
    uses: traits.Facts,
    exported: []const bool,
    budget: *loops.Budget,
) Error!bool {
    const f = program.functions[fid];
    if (f.effects.len != 0 or f.regions.len != 0 or f.custody.len != 1) return false;
    for (f.layout.slots) |schema| {
        try budget.take(1);
        if (!uses.copy[
            @intCast(schema)
        ] or !uses.drop[
            @intCast(schema)
        ] or !exported[
            @intCast(schema)
        ]) return false;
    }
    for (program.blocks) |b| if (b.function == fid) {
        try budget.take(1);
        if (b.custody != 0 or !loops.supported(b.terminator)) return false;
    };
    return true;
}
fn termReads(term: ir.Terminator, slot: p.Id) bool {
    switch (term) {
        .return_value, .fail => |v| if (v == slot) {
            return true;
        },
        .branch => |v| if (v.condition == slot) {
            return true;
        },
        .switch_variant => |v| if (v.value == slot) {
            return true;
        },
        .jump => {},
        else => return true,
    }
    var ordinal: usize = 0;
    while (loops.edge(term, ordinal)) |edge| : (ordinal += 1)
        for (edge.assignments) |assignment|
            if (assignment.source == .slot and
                assignment.source.slot == slot)
                return true;
    return false;
}
const Shape = struct {
    stride: p.Id,
    base: p.Id,
    multiply: ir.Instruction,
    addition: ir.Instruction,
};
fn shape(
    a: std.mem.Allocator,
    program: ir.Program,
    graph: loops.Graph,
    certificate: induction.Certificate,
    index: usize,
    budget: *loops.Budget,
) Error!?Shape {
    const body = program.blocks[certificate.body];
    if (index >= body.instructions.len or body.instructions.len - index < 2) return null;
    if (certificate.body == certificate.latch and index + 1 >= certificate.increment) return null;
    const multiply = body.instructions[index];
    const addition = body.instructions[index + 1];
    if (multiply.opcode != .integer_mul or
        multiply.operands.len != 2 or
        multiply.operands[0] != certificate.index or
        addition.opcode != .integer_add or
        addition.operands.len != 2 or
        addition.operands[0] != multiply.destination)
        return null;
    const stride = multiply.operands[1];
    const base = addition.operands[1];
    const slots = program.functions[graph.function].layout.slots;
    const schema = slots[@intCast(certificate.index)];
    if (slots[
        @intCast(multiply.destination)
    ] != schema or
        slots[
            @intCast(addition.destination)
        ] != schema or
        multiply.destination == addition.destination or
        multiply.destination == certificate.index or
        addition.destination == certificate.index)
        return null;
    if (!try induction.stable(
        program,
        graph,
        certificate.members,
        stride,
        budget,
    ) or !try induction.stable(program, graph, certificate.members, base, budget)) return null;
    var constants: origin.Prover = .{
        .allocator = a,
        .program = program,
        .work_limit = budget.remaining,
    };
    defer constants.deinit();
    const coefficient = (try induction.entryConstant(
        program,
        certificate.entries,
        stride,
        &constants,
        budget,
    )) orelse return null;
    const initial = (try induction.entryConstant(
        program,
        certificate.entries,
        base,
        &constants,
        budget,
    )) orelse return null;
    if (coefficient == 0) return null;
    const product_bound = std.math.mul(u64, certificate.limit_upper, coefficient) catch return null;
    const final_bound = std.math.add(u64, product_bound, initial) catch return null;
    // Includes the final transfer, not just useful i < limit evaluations.
    if (final_bound > certificate.maximum) return null;
    for (multiply.failures) |fault| if (fault.kind != .arithmetic_overflow) return null;
    for (addition.failures) |fault| if (fault.kind != .arithmetic_overflow) return null;
    // The intermediate product is private to the adjacent addition. Removing
    // it must not hide a later observer or an independent definition.
    for (graph.blocks) |bid| {
        for (program.blocks[bid].instructions, 0..) |op, at| {
            try budget.take(1);
            if (bid == certificate.body and (at == index or at == index + 1)) continue;
            if (op.destination == multiply.destination or std.mem.indexOfScalar(
                p.Id,
                op.operands,
                multiply.destination,
            ) != null) return null;
        }
        if (termReads(program.blocks[bid].terminator, multiply.destination)) return null;
        var ordinal: usize = 0;
        while (loops.edge(program.blocks[bid].terminator, ordinal)) |edge| : (ordinal += 1)
            for (edge.assignments) |assignment|
                if (assignment.destination == multiply.destination)
                    return null;
    }
    return .{ .stride = stride, .base = base, .multiply = multiply, .addition = addition };
}
fn redirected(a: std.mem.Allocator, term: ir.Terminator, from: usize, to: usize) !ir.Terminator {
    var result = term;
    switch (result) {
        .jump => |*e| if (e.block == from) {
            e.block = to;
        },
        .branch => |*b| {
            if (b.when_true.block == from) b.when_true.block = to;
            if (b.when_false.block == from) b.when_false.block = to;
        },
        .switch_variant => |*v| {
            const edges = try a.dupe(ir.Edge, v.cases);
            for (edges) |*e| if (e.block == from) {
                e.block = to;
            };
            v.cases = edges;
        },
        else => {},
    }
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
    try budget.record(ir.Program, original);
    const uses = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    for (original.functions, 0..) |_, fid| {
        if (!try permitted(original, fid, uses, schemas.exportable, &budget)) continue;
        const graph = (try loops.Graph.init(a, original, fid, &budget)) orelse continue;
        if (!try graph.cyclic(&budget)) continue;
        const dom = try graph.dominators(&budget);
        const dominated = try a.alloc(bool, graph.blocks.len);
        for (graph.blocks, 0..) |header, h| {
            try budget.take(1);
            if (!graph.reachable[h]) continue;
            for (dominated, 0..) |*v, node| v.* = dom[node * graph.blocks.len + h];
            const members = (try graph.region(h, dominated, &budget)) orelse continue;
            const cert = (try induction.derive(
                a,
                original,
                graph,
                members,
                header,
                &budget,
            )) orelse continue;
            for (original.blocks[cert.body].instructions, 0..) |_, index| {
                const found = (try shape(a, original, graph, cert, index, &budget)) orelse continue;
                // shape proves this old intermediate has no other observer,
                // definition or edge transfer anywhere in the function.
                const recurrence = found.multiply.destination;
                const blocks = try a.alloc(ir.Block, original.blocks.len + 1);
                @memcpy(blocks[0..original.blocks.len], original.blocks);
                for (graph.blocks, 0..) |bid, local| if (!members[local]) {
                    blocks[bid].terminator = try redirected(
                        a,
                        blocks[bid].terminator,
                        header,
                        original.blocks.len,
                    );
                };
                blocks[original.blocks.len] = .{
                    .function = fid,
                    .instructions = try a.dupe(
                        ir.Instruction,
                        &.{.{
                            .destination = recurrence,
                            .opcode = .move,
                            .operands = try a.dupe(p.Id, &.{found.base}),
                        }},
                    ),
                    .terminator = .{ .jump = .{ .block = header } },
                };
                const body = original.blocks[cert.body].instructions;
                const instructions = try a.alloc(ir.Instruction, body.len - 1);
                @memcpy(instructions[0..index], body[0..index]);
                instructions[index] = .{
                    .destination = found.addition.destination,
                    .opcode = .move,
                    .operands = try a.dupe(p.Id, &.{recurrence}),
                };
                @memcpy(instructions[index + 1 ..], body[index + 2 ..]);
                blocks[cert.body].instructions = instructions;
                const latch = blocks[cert.latch].instructions;
                const transferred = try a.alloc(ir.Instruction, latch.len + 1);
                @memcpy(transferred[0..latch.len], latch);
                transferred[latch.len] = .{
                    .destination = recurrence,
                    .opcode = .integer_add,
                    .operands = try a.dupe(p.Id, &.{ recurrence, found.stride }),
                    .failures = found.addition.failures,
                };
                blocks[cert.latch].instructions = transferred;
                var program = original;
                program.blocks = blocks;
                keep = true;
                return .{
                    .arena = arena,
                    .program = program,
                    .witness = .{ .header = header, .instruction = index },
                };
            }
        }
    }
    return null;
}
fn sameTargets(old: ir.Terminator, new: ir.Terminator, from: usize, to: usize) bool {
    if (std.meta.activeTag(old) != std.meta.activeTag(new)) return false;
    switch (old) {
        .return_value, .fail => return equal(ir.Terminator, old, new),
        .branch => |v| if (v.condition != new.branch.condition) {
            return false;
        },
        .switch_variant => |v| if (v.value != new.switch_variant.value or
            v.cases.len != new.switch_variant.cases.len)
        {
            return false;
        },
        .jump => {},
        else => return false,
    }
    var i: usize = 0;
    while (loops.edge(old, i)) |before| : (i += 1) {
        const after = loops.edge(new, i) orelse return false;
        if (after.block != (if (before.block == from) to else before.block) or !equal(
            []const ir.Assignment,
            before.assignments,
            after.assignments,
        )) return false;
    }
    return true;
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    try budget.record(ir.Program, original);
    try budget.record(ir.Program, candidate);
    if (witness.header >= original.blocks.len or
        candidate.blocks.len != original.blocks.len + 1 or
        candidate.functions.len != original.functions.len)
        return error.InvalidAffineInduction;
    const fid: usize = @intCast(original.blocks[witness.header].function);
    const uses = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    if (!try permitted(
        original,
        fid,
        uses,
        schemas.exportable,
        &budget,
    )) return error.InvalidAffineInduction;
    const graph = (try loops.Graph.init(
        a,
        original,
        fid,
        &budget,
    )) orelse return error.InvalidAffineInduction;
    const h = graph.local[witness.header];
    const outside = try graph.reachAvoid(h, &budget);
    const dominated = try a.alloc(bool, graph.blocks.len);
    for (dominated, 0..) |*v, node| v.* = graph.reachable[node] and !outside[node];
    const members = (try graph.region(
        h,
        dominated,
        &budget,
    )) orelse return error.InvalidAffineInduction;
    const cert = (try induction.derive(
        a,
        original,
        graph,
        members,
        witness.header,
        &budget,
    )) orelse return error.InvalidAffineInduction;
    const found = (try shape(
        a,
        original,
        graph,
        cert,
        witness.instruction,
        &budget,
    )) orelse return error.InvalidAffineInduction;
    const recurrence = found.multiply.destination;
    var rest = candidate;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidAffineInduction;
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
        try budget.take(1);
        if (old.function != new.function or
            old.custody != new.custody)
            return error.InvalidAffineInduction;
        var expected_count = old.instructions.len;
        if (bid == cert.body) expected_count -= 1;
        if (bid == cert.latch) expected_count += 1;
        if (new.instructions.len != expected_count) return error.InvalidAffineInduction;
        var out: usize = 0;
        var index: usize = 0;
        while (index < old.instructions.len) : (index += 1) {
            if (bid == cert.body and index == witness.instruction) {
                if (!equal(
                    ir.Instruction,
                    .{
                        .destination = found.addition.destination,
                        .opcode = .move,
                        .operands = &.{recurrence},
                    },
                    new.instructions[out],
                )) return error.InvalidAffineInduction;
                index += 1;
            } else if (!equal(
                ir.Instruction,
                old.instructions[index],
                new.instructions[out],
            )) return error.InvalidAffineInduction;
            out += 1;
        }
        if (bid == cert.latch) if (!equal(
            ir.Instruction,
            .{
                .destination = recurrence,
                .opcode = .integer_add,
                .operands = &.{ recurrence, found.stride },
                .failures = found.addition.failures,
            },
            new.instructions[out],
        )) return error.InvalidAffineInduction;
        if (old.function == fid and !members[graph.local[bid]]) {
            if (!sameTargets(
                old.terminator,
                new.terminator,
                witness.header,
                original.blocks.len,
            )) return error.InvalidAffineInduction;
        } else if (!equal(
            ir.Terminator,
            old.terminator,
            new.terminator,
        )) return error.InvalidAffineInduction;
    }
    const entry = candidate.blocks[original.blocks.len];
    if (entry.function != fid or entry.custody != 0 or !equal(
        []const ir.Instruction,
        &.{.{ .destination = recurrence, .opcode = .move, .operands = &.{found.base} }},
        entry.instructions,
    ) or !equal(
        ir.Terminator,
        .{ .jump = .{ .block = witness.header } },
        entry.terminator,
    )) return error.InvalidAffineInduction;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block|
        for (block.instructions) |op|
            if (op.opcode == .integer_mul)
                return true;
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
        candidate.witness,
        options,
    ) catch |err| switch (err) {
        error.LoopWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.recurrences = 1;
    return result;
}
