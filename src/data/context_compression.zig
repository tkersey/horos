// Copyright (c) 2026 Boundary contributors. MIT license.
//! P15 private recursive return actions become a constant-context summary loop.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const admission = @import("admission.zig");
const traits = @import("traits.zig");
const privacy = @import("capture_reduction.zig");
const laws = @import("action_laws.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidContextCompression, ContextCompressionLimit };
pub const Options = struct { work_limit: usize = 10_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct { contexts_compressed: usize = 0, work_limit: bool = false };
const Budget = struct {
    left: usize,
    fn take(self: *@This(), n: usize) Error!void {
        if (n > self.left) return error.ContextCompressionLimit;
        self.left -= n;
    }
    fn record(self: *@This(), comptime T: type, value: T) Error!void {
        @setEvalBranchQuota(10000);
        return self.recordFields(T, value);
    }

    inline fn recordFields(self: *@This(), comptime T: type, value: T) Error!void {
        try self.take(1);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| try self.recordFields(FieldType, @field(value, field_name)),
            .@"union" => switch (value) {
                inline else => |v| try self.recordFields(@TypeOf(v), v),
            },
            .optional => |info| if (value) |v| {
                try self.recordFields(info.child, v);
            },
            .pointer => |info| for (value) |v| try self.recordFields(info.child, v),
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
    seed: p.Id,
    mask: p.Id,
    tail: p.Id,
    result: p.Id,
    returned: p.Id,
    law: laws.Law,
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
// The complete four-block worker contains no independent frame observer. Its
// sole recursive call is consumed by exactly the registered return action.
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
    if (f.inputs.len != 2 or
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
    const seed = f.inputs[1];
    const sequence_schema = program.schemas[@intCast(f.layout.slots[@intCast(sequence)])];
    const action_schema = switch (sequence_schema) {
        .vector => |v| v.element,
        .seq => |v| v,
        else => return null,
    };
    const law = laws.classify(program.schemas, action_schema, f.result) orelse return null;
    if (f.layout.slots[@intCast(seed)] != f.result) return null;
    const entry = program.blocks[@intCast(f.entry)];
    if (entry.instructions.len != 1 or !operation(
        entry.instructions[0],
        .sequence_pop,
        &.{sequence},
        0,
    ) or entry.terminator != .switch_variant) return null;
    const pop = entry.instructions[0].destination;
    const branch = entry.terminator.switch_variant;
    if (branch.value != pop or branch.cases.len != 2) return null;
    for (branch.cases) |edge| {
        if (edge.assignments.len > 1 or
            (edge.assignments.len == 1 and
                edge.assignments[0].source != .returned))
            return null;
    }
    const base = program.blocks[@intCast(branch.cases[0].block)];
    if (base.terminator != .return_value or base.terminator.return_value != seed) return null;
    if (base.instructions.len != 0 and !(base.instructions.len == 1 and operation(
        base.instructions[0],
        .variant_payload,
        &.{pop},
        0,
    ))) return null;
    return recognizeStep(program, id, sequence, seed, pop, branch, law, budget);
}
fn recognizeStep(
    program: ir.Program,
    id: p.Id,
    sequence: p.Id,
    seed: p.Id,
    pop: p.Id,
    branch: @FieldType(ir.Terminator, "switch_variant"),
    law: laws.Law,
    budget: *Budget,
) Error!?Shape {
    const step = program.blocks[@intCast(branch.cases[1].block)];
    if (step.terminator != .call) return null;
    const bound_payload = branch.cases[1].assignments.len == 1;
    const first: usize = if (bound_payload) 0 else 1;
    if (step.instructions.len != first + 2) return null;
    const pair = if (bound_payload)
        branch.cases[1].assignments[0].destination
    else
        step.instructions[0].destination;
    const mask = step.instructions[first].destination;
    const tail = step.instructions[first + 1].destination;
    if ((!bound_payload and !operation(step.instructions[0], .variant_payload, &.{pop}, 1)) or
        !operation(step.instructions[first], .field, &.{pair}, 0) or
        !operation(step.instructions[first + 1], .field, &.{pair}, 1))
        return null;
    const call = step.terminator.call;
    if (call.function != id or
        !std.mem.eql(p.Id, call.arguments, &.{ tail, seed }) or
        call.next.assignments.len != 1 or
        call.next.assignments[0].source != .returned)
        return null;
    const returned = call.next.assignments[0].destination;
    const finish = program.blocks[@intCast(call.next.block)];
    if (!laws.matches(law, finish, mask, returned)) return null;
    const result = finish.terminator.return_value;
    return recognizeRoles(
        program,
        id,
        sequence,
        seed,
        pop,
        pair,
        mask,
        tail,
        returned,
        result,
        finish,
        branch,
        call,
        law,
        budget,
    );
}
fn recognizeRoles(
    program: ir.Program,
    id: p.Id,
    sequence: p.Id,
    seed: p.Id,
    pop: p.Id,
    pair: p.Id,
    mask: p.Id,
    tail: p.Id,
    returned: p.Id,
    result: p.Id,
    finish: ir.Block,
    branch: @FieldType(ir.Terminator, "switch_variant"),
    call: @FieldType(ir.Terminator, "call"),
    law: laws.Law,
    budget: *Budget,
) Error!?Shape {
    const f = program.functions[@intCast(id)];
    const ids = [_]p.Id{ f.entry, branch.cases[0].block, branch.cases[1].block, call.next.block };
    if (!distinct(&ids) or !distinct(&.{
        sequence,
        seed,
        pop,
        pair,
        mask,
        tail,
        returned,
        result,
    })) return null;
    if (law.kind == .boolean_table and !distinct(&.{
        sequence,
        seed,
        pop,
        pair,
        mask,
        tail,
        returned,
        result,
        finish.instructions[0].destination,
        finish.instructions[1].destination,
    })) return null;
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
        .seed = seed,
        .mask = mask,
        .tail = tail,
        .result = result,
        .returned = returned,
        .law = law,
    };
}
fn bindings(program: ir.Program, s: Shape) laws.Bindings {
    const finish = program.blocks[@intCast(s.finish)];
    return .{
        .summary = s.returned,
        .summary_high = s.result,
        .action = s.mask,
        .value = s.seed,
        .result = s.result,
        .scratch = if (s.law.kind == .boolean_table) finish.instructions[0].destination else 0,
        .scratch_high = if (s.law.kind == .boolean_table) finish.instructions[1].destination else 0,
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
    var constant_count = original.constants.len;
    for (shapes.items) |s| constant_count = std.math.add(
        usize,
        constant_count,
        laws.stateCount(s.law),
    ) catch return error.Capacity;
    const constants = try a.alloc(p.Literal, constant_count);
    var constant_offset = original.constants.len;
    @memcpy(constants[0..original.constants.len], original.constants);
    try rewriteShapes(a, original, blocks, shapes.items, constants, &constant_offset);
    var program = original;
    program.blocks = blocks;
    program.constants = constants;
    const selected = try sites.toOwnedSlice(a);
    keep = true;
    return .{ .arena = arena, .program = program, .sites = selected };
}
/// Re-derive the original chain and check the actual accumulator loop, including
/// every action operand and the noncommutative outer/inner orientation.
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
        candidate.functions.len != original.functions.len or
        candidate.blocks.len != original.blocks.len + sites.len or
        candidate.constants.len < original.constants.len)
        return error.InvalidContextCompression;
    var rest = candidate;
    rest.functions = original.functions;
    rest.blocks = original.blocks;
    rest.constants = original.constants;
    if (!equal(ir.Program, original, rest) or !equal(
        []const p.Literal,
        original.constants,
        candidate.constants[0..original.constants.len],
    )) return error.InvalidContextCompression;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    const shapes = try a.alloc(Shape, sites.len);
    const constant_offsets = try a.alloc(usize, sites.len);
    var constant_count = original.constants.len;
    for (sites, shapes, 0..) |site, *shape, index| {
        try budget.take(index + 1);
        if (site >= original.functions.len or std.mem.indexOfScalar(
            p.Id,
            sites[0..index],
            site,
        ) != null) return error.InvalidContextCompression;
        shape.* = (try recognize(
            original,
            site,
            permissions,
            schemas.exportable,
            &budget,
        )) orelse return error.InvalidContextCompression;
        constant_offsets[index] = constant_count;
        constant_count = std.math.add(
            usize,
            constant_count,
            laws.stateCount(shape.law),
        ) catch return error.InvalidContextCompression;
    }
    if (candidate.constants.len != constant_count) return error.InvalidContextCompression;
    if (!equal(
        []const ir.Function,
        original.functions,
        candidate.functions,
    )) return error.InvalidContextCompression;
    try validateBlocks(original, candidate, sites, shapes, constant_offsets, &budget);
}
fn validateBlocks(
    original: ir.Program,
    candidate: ir.Program,
    sites: []const p.Id,
    shapes: []const Shape,
    constant_offsets: []const usize,
    budget: *Budget,
) Error!void {
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
        try budget.take(1);
        if (old.function != new.function or
            old.custody != new.custody)
            return error.InvalidContextCompression;
        const index = std.mem.indexOfScalar(p.Id, sites, old.function) orelse {
            if (!equal(ir.Block, old, new)) return error.InvalidContextCompression;
            continue;
        };
        const s = shapes[index];
        const b = bindings(original, s);
        const header = original.blocks.len + index;
        try validateBlock(old, new, bid, s, b, header, constant_offsets[index]);
    }
    for (shapes, 0..) |s, index| {
        if (!equal(
            ir.Block,
            original.blocks[@intCast(s.entry)],
            candidate.blocks[original.blocks.len + index],
        )) return error.InvalidContextCompression;
        for (0..laws.stateCount(s.law)) |i| {
            const literal = candidate.constants[constant_offsets[index] + i];
            if (literal.schema != s.law.value or !std.mem.eql(
                u8,
                literal.bytes,
                laws.identity(s.law, i),
            )) return error.InvalidContextCompression;
        }
    }
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block|
        if (block.terminator == .call and
            block.terminator.call.function == block.function)
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
        error.ContextCompressionLimit => {
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
        error.ContextCompressionLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.contexts_compressed = candidate.sites.len;
    return result;
}

fn rewriteShapes(
    a: std.mem.Allocator,
    original: ir.Program,
    blocks: []ir.Block,
    shapes: []const Shape,
    constants: []p.Literal,
    constant_offset: *usize,
) Error!void {
    for (shapes, 0..) |s, index| {
        const b = bindings(original, s);
        const header = original.blocks.len + index;
        blocks[header] = original.blocks[@intCast(s.entry)];
        const init_ops = try a.alloc(ir.Instruction, laws.stateCount(s.law));
        for (init_ops, 0..) |*instruction, i| {
            constants[constant_offset.* + i] = .{
                .schema = s.law.value,
                .bytes = laws.identity(s.law, i),
            };
            instruction.* = .{
                .destination = if (i == 0) b.summary else b.summary_high,
                .opcode = .constant,
                .immediate = constant_offset.* + i,
            };
        }
        constant_offset.* += init_ops.len;
        blocks[@intCast(s.entry)].instructions = init_ops;
        blocks[@intCast(s.entry)].terminator = .{ .jump = .{ .block = header } };
        blocks[@intCast(s.base)].instructions = try laws.apply(a, s.law, b);
        blocks[@intCast(s.base)].terminator = .{ .return_value = s.result };
        const compose = try laws.compose(a, s.law, b);
        const prefix = original.blocks[@intCast(s.step)].instructions;
        const operations = try a.alloc(ir.Instruction, prefix.len + compose.len);
        @memcpy(operations[0..prefix.len], prefix);
        @memcpy(operations[prefix.len..], compose);
        blocks[@intCast(s.step)].instructions = operations;
        const advance = try a.alloc(ir.Assignment, if (s.law.kind == .boolean_table) 3 else 1);
        advance[0] = .{ .destination = s.sequence, .source = .{ .slot = s.tail } };
        if (s.law.kind == .boolean_table) {
            advance[1] = .{ .destination = b.summary, .source = .{ .slot = b.scratch } };
            advance[2] = .{ .destination = b.summary_high, .source = .{ .slot = b.scratch_high } };
        }
        blocks[@intCast(s.step)].terminator = .{ .jump = .{
            .block = header,
            .assignments = advance,
        } };
    }
}

fn validateBlock(
    old: ir.Block,
    new: ir.Block,
    bid: usize,
    s: Shape,
    b: laws.Bindings,
    header: usize,
    constant_offset: usize,
) Error!void {
    if (bid == s.entry) {
        if (new.instructions.len != laws.stateCount(s.law) or !equal(
            ir.Terminator,
            .{ .jump = .{ .block = header } },
            new.terminator,
        )) return error.InvalidContextCompression;
        for (
            new.instructions,
            0..,
        ) |instruction, i| if (!equal(
            ir.Instruction,
            .{
                .destination = if (i == 0) b.summary else b.summary_high,
                .opcode = .constant,
                .immediate = constant_offset + i,
            },
            instruction,
        )) return error.InvalidContextCompression;
    } else if (bid == s.base) {
        if (!laws.checkApplication(s.law, b, new.instructions) or !equal(
            ir.Terminator,
            .{ .return_value = s.result },
            new.terminator,
        )) return error.InvalidContextCompression;
    } else if (bid == s.step) {
        if (new.instructions.len < old.instructions.len or !equal(
            []const ir.Instruction,
            old.instructions,
            new.instructions[0..old.instructions.len],
        ) or !laws.checkComposition(
            s.law,
            b,
            new.instructions[old.instructions.len..],
        )) return error.InvalidContextCompression;
        if (new.terminator != .jump or
            new.terminator.jump.block != header)
            return error.InvalidContextCompression;
        const transfers = new.terminator.jump.assignments;
        if (transfers.len != (if (s.law.kind == .boolean_table) @as(
            usize,
            3,
        ) else 1) or !equal(
            ir.Assignment,
            .{ .destination = s.sequence, .source = .{ .slot = s.tail } },
            transfers[0],
        )) return error.InvalidContextCompression;
        if (s.law.kind == .boolean_table) {
            if (!equal(
                ir.Assignment,
                .{ .destination = b.summary, .source = .{ .slot = b.scratch } },
                transfers[1],
            ) or !equal(
                ir.Assignment,
                .{ .destination = b.summary_high, .source = .{ .slot = b.scratch_high } },
                transfers[2],
            )) return error.InvalidContextCompression;
        }
    } else if (!equal(ir.Block, old, new)) return error.InvalidContextCompression;
}
