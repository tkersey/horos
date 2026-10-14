// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked unpacking of one private homogeneous unsigned product capture.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const privacy = @import("capture_reduction.zig");
const access = @import("slot_access.zig").terminator;
const equal = @import("record_equal.zig").equal;
pub const Error = own.Error || error{InvalidCaptureUnpack};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn fields(program: ir.Program, id: usize) ?[]const p.Id {
    if (id >= program.constructors.len or !privacy.privateWorker(program, id) or !privacy.privateConstructions(program, id)) return null;
    const ctor = program.constructors[id];
    const capture = program.scopes.captures[@intCast(ctor.capture)];
    if (capture.fields.len != 1 or capture.use != .reusable or capture.owned_regions.len != 0 or capture.borrowed_regions.len != 0) return null;
    const schema = program.schemas[@intCast(capture.fields[0])];
    if (schema != .product or schema.product.len < 2 or schema.product.len > 128) return null;
    const scalar = schema.product[0];
    switch (program.schemas[@intCast(scalar)]) {
        .u8, .u16, .u32, .u64 => {},
        else => return null,
    }
    for (schema.product) |field| if (field != scalar) return null;
    const input = program.functions[@intCast(ctor.function)].inputs[0];
    var recursive = false;
    for (program.blocks) |block| {
        if (block.function != ctor.function) continue;
        for (block.instructions) |op| {
            if (op.destination == input) return null;
            for (op.operands) |operand| if (operand == input) {
                if (op.opcode != .field or op.operands.len != 1 or op.failures.len != 0) return null;
            };
        }
        if (block.terminator == .call and block.terminator.call.function == ctor.function) recursive = true;
        const uses = access(block.terminator, input);
        const pass_through = block.terminator == .call and block.terminator.call.function == ctor.function and block.terminator.call.arguments[0] == input;
        if (uses.writes != 0 or uses.reads != @intFromBool(pass_through)) return null;
    }
    return if (recursive) schema.product else null;
}
fn replacePrefix(a: std.mem.Allocator, old: []const p.Id, prefix: []const p.Id) std.mem.Allocator.Error![]const p.Id {
    const result = try a.alloc(p.Id, old.len - 1 + prefix.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..], old[1..]);
    return result;
}
fn project(a: std.mem.Allocator, layout: *std.ArrayList(p.Id), instructions: *std.ArrayList(ir.Instruction), product: p.Id, field_types: []const p.Id) std.mem.Allocator.Error![]const p.Id {
    const slots = try a.alloc(p.Id, field_types.len);
    for (field_types, slots, 0..) |schema, *slot, index| {
        slot.* = layout.items.len;
        try layout.append(a, schema);
        try instructions.append(a, .{ .destination = slot.*, .opcode = .field, .operands = try a.dupe(p.Id, &.{product}), .immediate = index });
    }
    return slots;
}

/// Private apply uses do not exclude retention in an effect continuation.
/// Keep both representations unchanged when ownership observes such retention:
/// the constructed closure's schema and the worker's product input contract.
const RepresentationRetention = struct {
    program: ir.Program,
    constructor: usize,
    retained: bool = false,

    fn observe(context: *anyopaque, function: p.Id, _: *const own.CaptureSite, slot: p.Id) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.retained or self.constructor >= self.program.constructors.len) return;
        const ctor = self.program.constructors[self.constructor];
        const worker = self.program.functions[@intCast(ctor.function)];
        if (function == ctor.function and worker.inputs.len != 0 and slot == worker.inputs[0]) {
            self.retained = true;
            return;
        }
        if (self.program.functions[@intCast(function)].layout.slots[@intCast(slot)] != ctor.schema) return;
        for (self.program.blocks) |block| {
            if (block.function != function) continue;
            for (block.instructions) |op| {
                if (op.opcode == .computation and op.immediate == self.constructor and op.destination == slot) {
                    self.retained = true;
                    return;
                }
            }
        }
    }
};

pub fn construct(allocator: std.mem.Allocator, original: ir.Program, id: usize) Error!?Candidate {
    var retention: RepresentationRetention = .{ .program = original, .constructor = id };
    var admitted = try own.analyzeObserved(allocator, original, null, .{ .context = &retention, .capture = RepresentationRetention.observe });
    defer admitted.deinit();
    const field_types = fields(original, id) orelse return null;
    if (retention.retained) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const old_ctor = original.constructors[id];
    const worker_id = old_ctor.function;
    const worker = original.functions[@intCast(worker_id)];
    const functions = try a.dupe(ir.Function, original.functions);
    const constructors = try a.dupe(p.Constructor, original.constructors);
    const schemas = try a.alloc(p.Schema, original.schemas.len + 1);
    @memcpy(schemas[0..original.schemas.len], original.schemas);
    var schema = original.schemas[@intCast(old_ctor.schema)];
    schema.internal.computation.capture_bound = try a.dupe(p.Id, field_types[0..1]);
    schemas[original.schemas.len] = schema;
    const captures = try a.alloc(p.Capture, original.scopes.captures.len + 1);
    @memcpy(captures[0..original.scopes.captures.len], original.scopes.captures);
    var capture = original.scopes.captures[@intCast(old_ctor.capture)];
    capture.fields = try a.dupe(p.Id, field_types);
    captures[original.scopes.captures.len] = capture;
    constructors[id].schema = original.schemas.len;
    constructors[id].capture = original.scopes.captures.len;
    const layouts = try a.alloc(std.ArrayList(p.Id), functions.len);
    for (layouts, functions) |*layout, function| {
        layout.* = .empty;
        try layout.appendSlice(a, function.layout.slots);
    }
    const inputs = try a.alloc(p.Id, field_types.len);
    for (inputs, field_types) |*slot, field| {
        slot.* = layouts[@intCast(worker_id)].items.len;
        try layouts[@intCast(worker_id)].append(a, field);
    }
    functions[@intCast(worker_id)].inputs = try replacePrefix(a, worker.inputs, inputs);
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (original.blocks, blocks) |block, *out| {
        var instructions: std.ArrayList(ir.Instruction) = .empty;
        const layout = &layouts[@intCast(block.function)];
        for (block.instructions) |op| {
            var replacement = op;
            if (block.function == worker_id and op.opcode == .field and op.operands[0] == worker.inputs[0]) replacement = .{ .destination = op.destination, .opcode = .move, .operands = try a.dupe(p.Id, &.{inputs[@intCast(op.immediate)]}) };
            if (op.opcode == .computation and op.immediate == id) {
                replacement.operands = try project(a, layout, &instructions, op.operands[0], field_types);
                layout.items[@intCast(op.destination)] = original.schemas.len;
            }
            try instructions.append(a, replacement);
        }
        if (block.terminator == .call and block.terminator.call.function == worker_id) {
            const call = block.terminator.call;
            const prefix = if (block.function == worker_id and call.arguments[0] == worker.inputs[0]) inputs else try project(a, layout, &instructions, call.arguments[0], field_types);
            out.terminator.call.arguments = try replacePrefix(a, call.arguments, prefix);
        }
        out.instructions = try instructions.toOwnedSlice(a);
    }
    for (functions, layouts) |*function, layout| function.layout.slots = layout.items;
    var candidate = original;
    candidate.functions = functions;
    candidate.constructors = constructors;
    candidate.schemas = schemas;
    candidate.scopes.captures = captures;
    candidate.blocks = blocks;
    try validate(allocator, original, candidate, id);
    return .{ .arena = arena, .program = candidate };
}
fn correspondence(before: []const p.Id, after: []const p.Id, prefix: []const p.Id) bool {
    return after.len == before.len - 1 + prefix.len and std.mem.eql(p.Id, after[0..prefix.len], prefix) and std.mem.eql(p.Id, after[prefix.len..], before[1..]);
}
fn checkProjections(original: ir.Program, candidate: ir.Program, owner: usize, product: p.Id, field_types: []const p.Id, instructions: []const ir.Instruction, cursor: *usize, next: *usize, prefix: []p.Id) Error!void {
    for (field_types, prefix, 0..) |schema, *slot, index| {
        if (cursor.* >= instructions.len or next.* >= candidate.functions[owner].layout.slots.len or candidate.functions[owner].layout.slots[next.*] != schema) return error.InvalidCaptureUnpack;
        const op = instructions[cursor.*];
        slot.* = next.*;
        next.* += 1;
        cursor.* += 1;
        if (op.destination != slot.* or op.opcode != .field or op.immediate != index or op.operands.len != 1 or op.operands[0] != product or op.failures.len != 0) return error.InvalidCaptureUnpack;
    }
    _ = original;
}
/// Exact ordered record correspondence; admission is necessary but not acceptance.
pub fn validate(allocator: std.mem.Allocator, original: ir.Program, candidate: ir.Program, id: usize) Error!void {
    var before_flow = try own.analyze(allocator, original);
    defer before_flow.deinit();
    var after_flow = try own.analyze(allocator, candidate);
    defer after_flow.deinit();
    const field_types = fields(original, id) orelse return error.InvalidCaptureUnpack;
    const ctor = original.constructors[id];
    const worker = original.functions[@intCast(ctor.function)];
    var same = candidate;
    same.functions = original.functions;
    same.blocks = original.blocks;
    same.schemas = original.schemas;
    same.constructors = original.constructors;
    same.scopes.captures = original.scopes.captures;
    if (!equal(ir.Program, original, same) or candidate.functions.len != original.functions.len or candidate.blocks.len != original.blocks.len or candidate.constructors.len != original.constructors.len or candidate.schemas.len != original.schemas.len + 1 or candidate.scopes.captures.len != original.scopes.captures.len + 1) return error.InvalidCaptureUnpack;
    for (original.schemas, candidate.schemas[0..original.schemas.len]) |x, y| if (!equal(p.Schema, x, y)) return error.InvalidCaptureUnpack;
    for (original.scopes.captures, candidate.scopes.captures[0..original.scopes.captures.len]) |x, y| if (!equal(p.Capture, x, y)) return error.InvalidCaptureUnpack;
    var expected_schema = original.schemas[@intCast(ctor.schema)];
    expected_schema.internal.computation.capture_bound = field_types[0..1];
    if (!equal(p.Schema, expected_schema, candidate.schemas[original.schemas.len])) return error.InvalidCaptureUnpack;
    var expected_capture = original.scopes.captures[@intCast(ctor.capture)];
    expected_capture.fields = field_types;
    if (!equal(p.Capture, expected_capture, candidate.scopes.captures[original.scopes.captures.len])) return error.InvalidCaptureUnpack;
    for (original.constructors, candidate.constructors, 0..) |x, y, index| {
        var expected = x;
        if (index == id) {
            expected.schema = original.schemas.len;
            expected.capture = original.scopes.captures.len;
        }
        if (!equal(p.Constructor, expected, y)) return error.InvalidCaptureUnpack;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const next = try a.alloc(usize, original.functions.len);
    const inputs = try a.alloc(p.Id, field_types.len);
    for (inputs, 0..) |*slot, index| slot.* = worker.layout.slots.len + index;
    for (original.functions, candidate.functions, next, 0..) |x, y, *count, owner| {
        var metadata = y;
        metadata.layout = x.layout;
        metadata.inputs = x.inputs;
        if (!equal(ir.Function, x, metadata) or y.layout.slots.len < x.layout.slots.len) return error.InvalidCaptureUnpack;
        for (x.layout.slots, y.layout.slots[0..x.layout.slots.len], 0..) |old_type, new_type, slot| {
            var expected = old_type;
            for (original.blocks) |block| if (block.function == owner) {
                for (block.instructions) |op| if (op.destination == slot and op.opcode == .computation and op.immediate == id) {
                    expected = original.schemas.len;
                };
            };
            if (expected != new_type) return error.InvalidCaptureUnpack;
        }
        count.* = x.layout.slots.len;
        if (owner == ctor.function) {
            if (!correspondence(x.inputs, y.inputs, inputs)) return error.InvalidCaptureUnpack;
            for (field_types) |schema| {
                if (count.* >= y.layout.slots.len or y.layout.slots[count.*] != schema) return error.InvalidCaptureUnpack;
                count.* += 1;
            }
        } else if (!std.mem.eql(p.Id, x.inputs, y.inputs)) return error.InvalidCaptureUnpack;
    }
    const prefix = try a.alloc(p.Id, field_types.len);
    for (original.blocks, candidate.blocks) |x, y| {
        if (x.function != y.function or x.custody != y.custody) return error.InvalidCaptureUnpack;
        const owner: usize = @intCast(x.function);
        var cursor: usize = 0;
        for (x.instructions) |op| {
            var expected = op;
            var operand: [1]p.Id = undefined;
            if (x.function == ctor.function and op.opcode == .field and op.operands[0] == worker.inputs[0]) {
                operand[0] = inputs[@intCast(op.immediate)];
                expected = .{ .destination = op.destination, .opcode = .move, .operands = &operand };
            }
            if (op.opcode == .computation and op.immediate == id) {
                try checkProjections(original, candidate, owner, op.operands[0], field_types, y.instructions, &cursor, &next[owner], prefix);
                expected.operands = prefix;
            }
            if (cursor >= y.instructions.len or !equal(ir.Instruction, expected, y.instructions[cursor])) return error.InvalidCaptureUnpack;
            cursor += 1;
        }
        var terminator = y.terminator;
        if (x.terminator == .call and x.terminator.call.function == ctor.function) {
            if (terminator != .call) return error.InvalidCaptureUnpack;
            const call = x.terminator.call;
            const direct = x.function == ctor.function and call.arguments[0] == worker.inputs[0];
            if (!direct) try checkProjections(original, candidate, owner, call.arguments[0], field_types, y.instructions, &cursor, &next[owner], prefix);
            if (!correspondence(call.arguments, terminator.call.arguments, if (direct) inputs else prefix)) return error.InvalidCaptureUnpack;
            terminator.call.arguments = call.arguments;
        }
        if (cursor != y.instructions.len or !equal(ir.Terminator, x.terminator, terminator)) return error.InvalidCaptureUnpack;
    }
    for (candidate.functions, next) |function, count| if (function.layout.slots.len != count) return error.InvalidCaptureUnpack;
}

pub fn run(allocator: std.mem.Allocator, original: ir.Program, options: @import("coalescing.zig").Options) (Error || @import("coalescing.zig").Error)!@import("coalescing.zig").Owned {
    for (original.constructors, 0..) |_, id| {
        var candidate = (try construct(allocator, original, id)) orelse continue;
        defer candidate.deinit();
        return @import("coalescing.zig").run(allocator, candidate.program, options);
    }
    return @import("coalescing.zig").run(allocator, original, options);
}
