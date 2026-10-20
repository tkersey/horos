// Copyright (c) 2026 Boundary contributors. MIT license.
//! P13: total bounded map/fold fusion. The retained loop consumes the original
//! suffix and folds each mapped head. No intermediate vector or second traversal.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const total = @import("total_clause.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidSequenceFusion, SequenceFusionLimit };
pub const Options = struct { work_limit: usize = 10_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct {
    loops_fused: usize = 0,
    intermediate_vectors_removed: usize = 0,
    work_limit: bool = false,
};
const Budget = struct {
    left: usize,
    fn take(self: *@This(), n: usize) Error!void {
        if (n > self.left) return error.SequenceFusionLimit;
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
    entry: p.Id,
    map_head: p.Id,
    map_body: p.Id,
    append: p.Id,
    fold_init: p.Id,
    fold_head: p.Id,
    fold_body: p.Id,
    fold_back: p.Id,
    done: p.Id,
    source: p.Id,
    seed: p.Id,
    accumulator: p.Id,
    mapped_value: p.Id,
    source_tail: p.Id,
    folder: p.Id,
};
fn operation(op: ir.Instruction, tag: p.Opcode, operands: []const p.Id, immediate: p.Id) bool {
    return op.opcode == tag and op.immediate == immediate and std.mem.eql(
        p.Id,
        op.operands,
        operands,
    );
}
fn transfer(edge: ir.Edge, destination: p.Id, source: ir.Source) bool {
    return edge.assignments.len == 1 and edge.assignments[0].destination == destination and equal(
        ir.Source,
        edge.assignments[0].source,
        source,
    );
}
fn distinct(values: []const p.Id) bool {
    for (
        values,
        0..,
    ) |value, i| if (std.mem.indexOfScalar(p.Id, values[0..i], value) != null) return false;
    return true;
}
fn pure(
    a: std.mem.Allocator,
    program: ir.Program,
    id: p.Id,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!bool {
    const function = program.functions[@intCast(id)];
    if (function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1)
        return false;
    for (function.layout.slots) |schema| {
        try budget.take(1);
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return false;
    }
    for (program.blocks) |block| {
        try budget.take(1);
        if (block.function != id) continue;
        if (block.custody != 0) return false;
        try budget.record(ir.Block, block);
        for (block.instructions) |op| if (!total.instruction(
            op,
        ) or op.opcode == .cell_get or op.opcode == .cell_set) return false;
    }
    total.validate(a, program, id, permissions) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    return true;
}
// Original admission precedes every use. The nine-block use census is also an
// escape proof: the produced vector is only appended and handed to this fold.
fn recognize(
    a: std.mem.Allocator,
    program: ir.Program,
    id: p.Id,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!?Shape {
    try budget.take(1);
    const function = program.functions[@intCast(id)];
    if (function.inputs.len != 2 or
        function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1)
        return null;
    for (function.layout.slots) |schema| {
        try budget.take(1);
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return null;
    }
    const entry = program.blocks[@intCast(function.entry)];
    if (entry.instructions.len != 1 or !operation(
        entry.instructions[0],
        .sequence,
        &.{},
        0,
    ) or entry.terminator != .jump or entry.terminator.jump.assignments.len != 0) return null;
    const source = function.inputs[0];
    const seed = function.inputs[1];
    const intermediate = entry.instructions[0].destination;
    const input_schema = program.schemas[@intCast(function.layout.slots[@intCast(source)])];
    const output_schema = program.schemas[@intCast(function.layout.slots[@intCast(intermediate)])];
    if (input_schema != .vector or
        output_schema != .vector or
        input_schema.vector.maximum > output_schema.vector.maximum)
        return null;
    const mhid = entry.terminator.jump.block;
    const mh = program.blocks[@intCast(mhid)];
    if (mh.instructions.len != 1 or !operation(
        mh.instructions[0],
        .sequence_pop,
        &.{source},
        0,
    ) or mh.terminator != .switch_variant) return null;
    const ms = mh.terminator.switch_variant;
    if (ms.value != mh.instructions[0].destination or
        ms.cases.len != 2 or
        ms.cases[0].assignments.len != 0 or
        ms.cases[1].assignments.len != 0)
        return null;
    return recognizeMapBody(.{
        .a = a,
        .budget = budget,
        .exportable = exportable,
        .function = function,
        .id = id,
        .intermediate = intermediate,
        .mhid = mhid,
        .ms = ms,
        .permissions = permissions,
        .program = program,
        .seed = seed,
        .source = source,
    });
}
fn recognizeMapBody(ctx: anytype) Error!?Shape {
    const mbid = ctx.ms.cases[1].block;
    const mb = ctx.program.blocks[@intCast(mbid)];
    if (mb.instructions.len != 3 or mb.terminator != .call) return null;
    const pair = mb.instructions[0].destination;
    if (!operation(mb.instructions[0], .variant_payload, &.{ctx.ms.value}, 1) or
        !operation(mb.instructions[1], .field, &.{pair}, 0) or
        !operation(mb.instructions[2], .field, &.{pair}, 1))
        return null;
    const map_call = mb.terminator.call;
    if (!std.mem.eql(p.Id, map_call.arguments, &.{mb.instructions[1].destination}) or
        map_call.next.assignments.len != 1 or
        map_call.next.assignments[0].source != .returned)
        return null;
    const mapped = map_call.next.assignments[0].destination;
    const tail = mb.instructions[2].destination;
    const append_id = map_call.next.block;
    const append = ctx.program.blocks[@intCast(append_id)];
    if (append.instructions.len != 1 or
        append.instructions[0].destination != ctx.intermediate or
        !operation(append.instructions[0], .sequence_append, &.{ ctx.intermediate, mapped }, 0) or
        append.terminator != .jump)
        return null;
    if (append.terminator.jump.block != ctx.mhid or !transfer(
        append.terminator.jump,
        ctx.source,
        .{ .slot = tail },
    )) return null;
    return recognizeFoldHead(.{
        .append_id = append_id,
        .map_call = map_call,
        .mapped = mapped,
        .mb = mb,
        .mbid = mbid,
        .pair = pair,
        .tail = tail,
        .a = ctx.a,
        .budget = ctx.budget,
        .exportable = ctx.exportable,
        .function = ctx.function,
        .id = ctx.id,
        .intermediate = ctx.intermediate,
        .mhid = ctx.mhid,
        .ms = ctx.ms,
        .permissions = ctx.permissions,
        .program = ctx.program,
        .seed = ctx.seed,
        .source = ctx.source,
    });
}
fn recognizeFoldHead(ctx: anytype) Error!?Shape {
    const fiid = ctx.ms.cases[0].block;
    const fi = ctx.program.blocks[@intCast(fiid)];
    if (fi.instructions.len != 2 or
        fi.terminator != .jump or
        fi.terminator.jump.assignments.len != 0)
        return null;
    if (!operation(fi.instructions[0], .move, &.{ctx.intermediate}, 0) or
        !operation(fi.instructions[1], .move, &.{ctx.seed}, 0))
        return null;
    const rest = fi.instructions[0].destination;
    const accumulator = fi.instructions[1].destination;
    const fhid = fi.terminator.jump.block;
    const fh = ctx.program.blocks[@intCast(fhid)];
    if (fh.instructions.len != 1 or !operation(
        fh.instructions[0],
        .sequence_pop,
        &.{rest},
        0,
    ) or fh.terminator != .switch_variant) return null;
    const fs = fh.terminator.switch_variant;
    if (fs.value != fh.instructions[0].destination or
        fs.cases.len != 2 or
        fs.cases[0].assignments.len != 0 or
        fs.cases[1].assignments.len != 0)
        return null;
    return recognizeFoldBody(.{
        .accumulator = accumulator,
        .fhid = fhid,
        .fiid = fiid,
        .fs = fs,
        .rest = rest,
        .a = ctx.a,
        .append_id = ctx.append_id,
        .budget = ctx.budget,
        .exportable = ctx.exportable,
        .function = ctx.function,
        .id = ctx.id,
        .intermediate = ctx.intermediate,
        .map_call = ctx.map_call,
        .mapped = ctx.mapped,
        .mb = ctx.mb,
        .mbid = ctx.mbid,
        .mhid = ctx.mhid,
        .ms = ctx.ms,
        .pair = ctx.pair,
        .permissions = ctx.permissions,
        .program = ctx.program,
        .seed = ctx.seed,
        .source = ctx.source,
        .tail = ctx.tail,
    });
}
fn recognizeFoldBody(ctx: anytype) Error!?Shape {
    const fbid = ctx.fs.cases[1].block;
    const fb = ctx.program.blocks[@intCast(fbid)];
    if (fb.instructions.len != 3 or fb.terminator != .call) return null;
    const fold_pair = fb.instructions[0].destination;
    if (!operation(fb.instructions[0], .variant_payload, &.{ctx.fs.value}, 1) or
        !operation(fb.instructions[1], .field, &.{fold_pair}, 0) or
        !operation(fb.instructions[2], .field, &.{fold_pair}, 1))
        return null;
    const fold_call = fb.terminator.call;
    if (!std.mem.eql(
        p.Id,
        fold_call.arguments,
        &.{ ctx.accumulator, fb.instructions[1].destination },
    ) or !transfer(fold_call.next, ctx.accumulator, .returned)) return null;
    const backid = fold_call.next.block;
    const back = ctx.program.blocks[@intCast(backid)];
    if (back.instructions.len != 0 or
        back.terminator != .jump or
        back.terminator.jump.block != ctx.fhid or
        !transfer(back.terminator.jump, ctx.rest, .{ .slot = fb.instructions[2].destination }))
        return null;
    const doneid = ctx.fs.cases[0].block;
    const done = ctx.program.blocks[@intCast(doneid)];
    if (done.instructions.len != 0 or
        done.terminator != .return_value or
        done.terminator.return_value != ctx.accumulator)
        return null;
    return recognizeLoopBoundary(.{
        .backid = backid,
        .doneid = doneid,
        .fb = fb,
        .fbid = fbid,
        .fold_call = fold_call,
        .fold_pair = fold_pair,
        .a = ctx.a,
        .accumulator = ctx.accumulator,
        .append_id = ctx.append_id,
        .budget = ctx.budget,
        .exportable = ctx.exportable,
        .fhid = ctx.fhid,
        .fiid = ctx.fiid,
        .fs = ctx.fs,
        .function = ctx.function,
        .id = ctx.id,
        .intermediate = ctx.intermediate,
        .map_call = ctx.map_call,
        .mapped = ctx.mapped,
        .mb = ctx.mb,
        .mbid = ctx.mbid,
        .mhid = ctx.mhid,
        .ms = ctx.ms,
        .pair = ctx.pair,
        .permissions = ctx.permissions,
        .program = ctx.program,
        .rest = ctx.rest,
        .seed = ctx.seed,
        .source = ctx.source,
        .tail = ctx.tail,
    });
}
fn recognizeLoopBoundary(ctx: anytype) Error!?Shape {
    const ids = [_]p.Id{
        ctx.function.entry,
        ctx.mhid,
        ctx.mbid,
        ctx.append_id,
        ctx.fiid,
        ctx.fhid,
        ctx.fbid,
        ctx.backid,
        ctx.doneid,
    };
    if (!distinct(&ids)) return null;
    for (ids) |bid| if (ctx.program.blocks[
        @intCast(bid)
    ].function != ctx.id or ctx.program.blocks[
        @intCast(bid)
    ].custody != 0) return null;
    for (ctx.program.blocks, 0..) |block, bid| {
        try ctx.budget.take(1);
        if (block.function == ctx.id and std.mem.indexOfScalar(
            p.Id,
            &ids,
            bid,
        ) == null) return null;
    }
    if (!distinct(&.{
        ctx.source,
        ctx.seed,
        ctx.intermediate,
        ctx.ms.value,
        ctx.pair,
        ctx.mb.instructions[1].destination,
        ctx.tail,
        ctx.mapped,
        ctx.rest,
        ctx.fs.value,
        ctx.fold_pair,
        ctx.fb.instructions[1].destination,
        ctx.fb.instructions[2].destination,
        ctx.accumulator,
    })) return null;
    return recognizePureLoop(ctx);
}
fn recognizePureLoop(ctx: anytype) Error!?Shape {
    if (!try pure(
        ctx.a,
        ctx.program,
        ctx.map_call.function,
        ctx.permissions,
        ctx.exportable,
        ctx.budget,
    ) or
        !try pure(
            ctx.a,
            ctx.program,
            ctx.fold_call.function,
            ctx.permissions,
            ctx.exportable,
            ctx.budget,
        ))
        return null;
    return .{
        .entry = ctx.function.entry,
        .map_head = ctx.mhid,
        .map_body = ctx.mbid,
        .append = ctx.append_id,
        .fold_init = ctx.fiid,
        .fold_head = ctx.fhid,
        .fold_body = ctx.fbid,
        .fold_back = ctx.backid,
        .done = ctx.doneid,
        .source = ctx.source,
        .seed = ctx.seed,
        .accumulator = ctx.accumulator,
        .mapped_value = ctx.mapped,
        .source_tail = ctx.tail,
        .folder = ctx.fold_call.function,
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
    const blocks = try a.dupe(ir.Block, original.blocks);
    var sites: std.ArrayList(p.Id) = .empty;
    for (original.functions, 0..) |_, id| {
        const shape = (try recognize(
            a,
            original,
            id,
            permissions,
            schemas.exportable,
            &budget,
        )) orelse continue;
        try sites.append(a, id);
        const initialization = try a.alloc(ir.Instruction, 1);
        initialization[0] = .{
            .destination = shape.accumulator,
            .opcode = .move,
            .operands = try a.dupe(p.Id, &.{shape.seed}),
        };
        blocks[@intCast(shape.entry)].instructions = initialization;
        const cases = try a.dupe(
            ir.Edge,
            blocks[@intCast(shape.map_head)].terminator.switch_variant.cases,
        );
        cases[0].block = shape.done;
        blocks[@intCast(shape.map_head)].terminator.switch_variant.cases = cases;
        const returned = try a.dupe(
            ir.Assignment,
            &.{.{ .destination = shape.accumulator, .source = .returned }},
        );
        blocks[@intCast(shape.append)].instructions = &.{};
        blocks[@intCast(shape.append)].terminator = .{ .call = .{
            .function = shape.folder,
            .arguments = try a.dupe(p.Id, &.{ shape.accumulator, shape.mapped_value }),
            .next = .{ .block = shape.fold_back, .assignments = returned },
        } };
        const advance = try a.dupe(
            ir.Assignment,
            &.{.{ .destination = shape.source, .source = .{ .slot = shape.source_tail } }},
        );
        blocks[@intCast(shape.fold_back)].terminator = .{ .jump = .{
            .block = shape.map_head,
            .assignments = advance,
        } };
    }
    if (sites.items.len == 0) return null;
    var program = original;
    program.blocks = blocks;
    const selected = try sites.toOwnedSlice(a);
    keep = true;
    return .{ .arena = arena, .program = program, .sites = selected };
}
/// Independent correspondence over original loops and actual candidate records.
/// No construction map or generated block is consumed as proof.
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
    if (sites.len == 0 or
        sites.len > original.functions.len or
        original.blocks.len != candidate.blocks.len)
        return error.InvalidSequenceFusion;
    var rest = candidate;
    rest.blocks = original.blocks;
    var budget: Budget = .{ .left = options.work_limit };
    try budget.record(ir.Program, original);
    try budget.record(ir.Program, candidate);
    if (!equal(ir.Program, original, rest)) return error.InvalidSequenceFusion;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    const shapes = try a.alloc(Shape, sites.len);
    for (sites, shapes, 0..) |site, *shape, index| {
        try budget.take(index + 1);
        if (std.mem.indexOfScalar(
            p.Id,
            sites[0..index],
            site,
        ) != null) return error.InvalidSequenceFusion;
        if (site >= original.functions.len) return error.InvalidSequenceFusion;
        shape.* = (try recognize(
            a,
            original,
            site,
            permissions,
            schemas.exportable,
            &budget,
        )) orelse return error.InvalidSequenceFusion;
    }
    for (original.blocks, candidate.blocks, 0..) |old, actual, bid| {
        try budget.take(1);
        if (old.function != actual.function or
            old.custody != actual.custody)
            return error.InvalidSequenceFusion;
        const index = std.mem.indexOfScalar(p.Id, sites, old.function) orelse {
            if (!equal(ir.Block, old, actual)) return error.InvalidSequenceFusion;
            continue;
        };
        try validateBlock(old, actual, bid, shapes[index]);
    }
}
fn validateBlock(old: ir.Block, actual: ir.Block, bid: usize, s: Shape) Error!void {
    if (bid == s.entry) {
        const expected: ir.Instruction = .{
            .destination = s.accumulator,
            .opcode = .move,
            .operands = &.{s.seed},
        };
        if (actual.instructions.len != 1 or !equal(
            ir.Instruction,
            expected,
            actual.instructions[0],
        ) or !equal(
            ir.Terminator,
            old.terminator,
            actual.terminator,
        )) return error.InvalidSequenceFusion;
    } else if (bid == s.map_head) {
        if (!equal(
            []const ir.Instruction,
            old.instructions,
            actual.instructions,
        ) or actual.terminator != .switch_variant) return error.InvalidSequenceFusion;
        const original_switch = old.terminator.switch_variant;
        const changed = actual.terminator.switch_variant;
        if (changed.value != original_switch.value or
            changed.cases.len != 2 or
            changed.cases[0].block != s.done or
            changed.cases[0].assignments.len != 0 or
            !equal(ir.Edge, original_switch.cases[1], changed.cases[1]))
            return error.InvalidSequenceFusion;
    } else if (bid == s.append) {
        if (actual.instructions.len != 0 or
            actual.terminator != .call)
            return error.InvalidSequenceFusion;
        const call = actual.terminator.call;
        if (call.function != s.folder or !std.mem.eql(
            p.Id,
            call.arguments,
            &.{ s.accumulator, s.mapped_value },
        ) or call.next.block != s.fold_back or !transfer(
            call.next,
            s.accumulator,
            .returned,
        )) return error.InvalidSequenceFusion;
    } else if (bid == s.fold_back) {
        if (actual.instructions.len != 0 or
            actual.terminator != .jump or
            actual.terminator.jump.block != s.map_head or
            !transfer(actual.terminator.jump, s.source, .{ .slot = s.source_tail }))
            return error.InvalidSequenceFusion;
    } else if (!equal(ir.Block, old, actual)) return error.InvalidSequenceFusion;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block|
        for (block.instructions) |op|
            if (op.opcode == .sequence_append)
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
        error.SequenceFusionLimit => {
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
        error.SequenceFusionLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.loops_fused = candidate.sites.len;
    stats.intermediate_vectors_removed = candidate.sites.len;
    return result;
}
