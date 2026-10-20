// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independent symbolic correspondence over original and emitted records.
//! Does not call affine discovery, extraction, closure, or candidate emission.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const privacy = @import("capture_reduction.zig");
const equal = @import("record_equal.zig").equal;
const space = @import("affine_space.zig");
pub const Error = ownership.Error || space.Error || error{InvalidAffineCandidate};
const Word = struct {
    state: u128 = 0,
    // Independent entry/opaque-result symbols are not capture coordinates.
    atoms: [4]u128 = @splat(0),
    constant: u64 = 0,
    fn xor(a: Word, b: Word) Word {
        var result: Word = .{ .state = a.state ^ b.state, .constant = a.constant ^ b.constant };
        for (&result.atoms, a.atoms, b.atoms) |*out, left, right| out.* = left ^ right;
        return result;
    }
};
const Value = union(enum) { word: Word, token: usize };
fn same(a: ?Value, b: ?Value) bool {
    return a != null and b != null and equal(Value, a.?, b.?);
}
fn word(value: ?Value) Error!Word {
    return if (value != null and value.? == .word) value.?.word else error.InvalidAffineCandidate;
}
fn atom(next: *usize) Error!Value {
    if (next.* >= 512) return error.WorkLimit;
    var result: Value = .{ .word = .{} };
    result.word.atoms[next.* / 128] = @as(u128, 1) << @intCast(next.* % 128);
    next.* += 1;
    return result;
}
fn width(schema: p.Schema) ?usize {
    return switch (schema) {
        .u8 => 1,
        .u16 => 2,
        .u32 => 4,
        .u64 => 8,
        else => null,
    };
}
fn evaluate(
    program: ir.Program,
    function: ir.Function,
    op: ir.Instruction,
    values: []const ?Value,
    schema: p.Id,
) Error!?Word {
    if (function.layout.slots[
        @intCast(op.destination)
    ] != schema or op.failures.len != 0) return null;
    switch (op.opcode) {
        .constant => {
            if (op.operands.len != 0) return null;
            const literal = program.constants[@intCast(op.immediate)];
            const bytes = width(
                program.schemas[
                    @intCast(schema)
                ],
            ) orelse return error.InvalidAffineCandidate;
            if (literal.schema != schema or
                literal.bytes.len != bytes)
                return error.InvalidAffineCandidate;
            var result: u64 = 0;
            for (literal.bytes, 0..) |byte, i| result |= @as(u64, byte) << @intCast(i * 8);
            return .{ .constant = result };
        },
        .move => {
            if (op.operands.len != 1 or op.immediate != 0) return null;
            const value = values[
                @intCast(op.operands[0])
            ] orelse return error.InvalidAffineCandidate;
            return if (value == .word) value.word else null;
        },
        .integer_bit_xor => {
            if (op.operands.len != 2 or op.immediate != 0) return null;
            return (try word(values[
                @intCast(op.operands[0])
            ])).xor(
                try word(values[
                    @intCast(op.operands[1])
                ]),
            );
        },
        else => return null,
    }
}
fn mappedArguments(
    before: []const p.Id,
    after: []const p.Id,
    old: []const ?Value,
    new: []const ?Value,
    basis: []const u128,
    n: usize,
    input_bias: []const u64,
) Error!void {
    if (before.len < n or
        after.len != before.len - n + basis.len)
        return error.InvalidAffineCandidate;
    for (basis, after[0..basis.len]) |row, slot| {
        var expected: Word = .{};
        for (before[0..n], 0..) |input, i| if (row & space.coordinate(i) != 0) {
            expected = expected.xor(try word(old[@intCast(input)]));
        };
        if (!equal(
            Word,
            expected,
            try word(new[@intCast(slot)]),
        )) return error.InvalidAffineCandidate;
    }
    try inputArguments(before[n..], after[basis.len..], old, new, input_bias);
}
fn inputArguments(
    before: []const p.Id,
    after: []const p.Id,
    old: []const ?Value,
    new: []const ?Value,
    biases: []const u64,
) Error!void {
    if (before.len != after.len or before.len != biases.len) return error.InvalidAffineCandidate;
    for (before, after, biases) |left, right, bias| {
        if (bias == 0) {
            if (!same(
                old[@intCast(left)],
                new[@intCast(right)],
            )) return error.InvalidAffineCandidate;
        } else {
            var expected = try word(old[@intCast(left)]);
            expected.constant ^= bias;
            if (!equal(
                Word,
                expected,
                try word(new[@intCast(right)]),
            )) return error.InvalidAffineCandidate;
        }
    }
}
fn selectedApplication(program: ir.Program, function: p.Id, slot: p.Id, constructor: usize) bool {
    for (program.blocks) |block|
        if (block.function == function) {
            for (block.instructions) |op|
                if (op.destination == slot and
                    op.opcode == .computation and
                    op.immediate == constructor)
                    return true;
        };
    return false;
}

fn drain(
    program: ir.Program,
    block: ir.Block,
    index: *usize,
    values: []?Value,
    schema: p.Id,
    minimum_slot: usize,
    budget: *space.Budget,
) Error!void {
    while (index.* < block.instructions.len) {
        const op = block.instructions[index.*];
        if (op.destination < minimum_slot) break;
        const value = (try evaluate(
            program,
            program.functions[@intCast(block.function)],
            op,
            values,
            schema,
        )) orelse break;
        try budget.charge();
        values[@intCast(op.destination)] = .{ .word = value };
        index.* += 1;
    }
}

fn edgeSource(edge: ir.Edge, destination: p.Id) ir.Source {
    for (edge.assignments) |assignment|
        if (assignment.destination == destination)
            return assignment.source;
    return .{ .slot = destination };
}
fn edgeValue(edge: ir.Edge, destination: p.Id, values: []const ?Value) Error!?Value {
    return switch (edgeSource(edge, destination)) {
        .slot => |slot| values[@intCast(slot)],
        .returned => error.InvalidAffineCandidate,
    };
}
fn checkEdge(
    before: ir.Edge,
    after: ir.Edge,
    old: []const ?Value,
    new: []const ?Value,
    captures: []const p.Id,
    summary: []const p.Id,
    basis: []const u128,
    inputs: []const p.Id,
    budget: *space.Budget,
) Error!void {
    if (before.block != after.block) return error.InvalidAffineCandidate;
    for (basis, summary) |row, destination| {
        var expected: Word = .{};
        for (captures, 0..) |slot, i| {
            try budget.charge();
            if (row & space.coordinate(i) != 0) expected = expected.xor(try word(try edgeValue(
                before,
                slot,
                old,
            )));
        }
        if (!equal(
            Word,
            expected,
            try word(try edgeValue(after, destination, new)),
        )) return error.InvalidAffineCandidate;
    }
    for (before.assignments) |assignment| {
        try budget.charge();
        if (std.mem.indexOfScalar(p.Id, captures, assignment.destination) != null) continue;
        const actual = edgeSource(after, assignment.destination);
        if (assignment.source == .returned) {
            if (actual != .returned or std.mem.indexOfScalar(
                p.Id,
                inputs,
                assignment.destination,
            ) != null) return error.InvalidAffineCandidate;
        } else {
            if (std.mem.indexOfScalar(
                p.Id,
                inputs,
                assignment.destination,
            ) == null or actual != .slot or !same(
                old[@intCast(assignment.source.slot)],
                new[@intCast(actual.slot)],
            )) return error.InvalidAffineCandidate;
        }
    }
    for (after.assignments) |assignment| {
        if (std.mem.indexOfScalar(p.Id, summary, assignment.destination) != null) continue;
        if (std.mem.indexOfScalar(
            p.Id,
            captures,
            assignment.destination,
        ) != null) return error.InvalidAffineCandidate;
        var present = false;
        for (before.assignments) |prior| if (prior.destination == assignment.destination) {
            present = true;
            break;
        };
        if (!present) return error.InvalidAffineCandidate;
    }
}

pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    constructor_id: usize,
    basis: []const u128,
    input_bias: []const u64,
    work_limit: u64,
) Error!void {
    return validateTarget(
        allocator,
        original,
        candidate,
        .{ .capture = constructor_id },
        basis,
        input_bias,
        work_limit,
    );
}
pub fn validateTarget(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    target: @import("affine_target.zig").Target,
    basis: []const u128,
    input_bias: []const u64,
    work_limit: u64,
) Error!void {
    var original_flow = try ownership.analyze(allocator, original);
    defer original_flow.deinit();
    var candidate_flow = try ownership.analyze(allocator, candidate);
    defer candidate_flow.deinit();
    const validation = try Validation.admit(original, candidate, target, basis, input_bias);
    try validation.checkMetadata();
    try validation.layouts();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: space.Budget = .{ .remaining = work_limit };
    for (original.blocks, candidate.blocks, 0..) |before, after, block_index| {
        try validation.block(arena.allocator(), before, after, block_index, &budget);
    }
}

const Validation = struct {
    original: ir.Program,
    candidate: ir.Program,
    basis: []const u128,
    input_bias: []const u64,
    constructor_id: ?usize,
    worker_id: p.Id,
    worker: ir.Function,
    schema: p.Id,
    n: usize,
    fn admit(
        original: ir.Program,
        candidate: ir.Program,
        target: @import("affine_target.zig").Target,
        basis: []const u128,
        input_bias: []const u64,
    ) Error!Validation {
        const constructor_id = target.constructor();
        if (constructor_id) |id| {
            if (id >= original.constructors.len or !privacy.privateWorker(
                original,
                id,
            ) or !privacy.privateConstructions(original, id)) return error.InvalidAffineCandidate;
            const capture = original.scopes.captures[@intCast(original.constructors[id].capture)];
            if (capture.use != .reusable or
                capture.owned_regions.len != 0 or
                capture.borrowed_regions.len != 0)
                return error.InvalidAffineCandidate;
        } else if (!privacy.privateDirectWorker(
            original,
            target.parameters.worker,
        )) return error.InvalidAffineCandidate;
        const worker_id = target.worker(original);
        const worker = original.functions[@intCast(worker_id)];
        const n = target.dimension(original);
        if (n == 0 or
            n > 128 or
            n > worker.inputs.len or
            basis.len >= n)
            return error.InvalidAffineCandidate;
        const schema = worker.layout.slots[@intCast(worker.inputs[0])];
        if (width(original.schemas[@intCast(schema)]) == null) return error.InvalidAffineCandidate;
        for (worker.inputs[0..n]) |slot| if (worker.layout.slots[
            @intCast(slot)
        ] != schema) return error.InvalidAffineCandidate;
        for (basis) |row| if (row & ~space.mask(n) != 0) return error.InvalidAffineCandidate;
        return .{
            .original = original,
            .candidate = candidate,
            .basis = basis,
            .input_bias = input_bias,
            .constructor_id = constructor_id,
            .worker_id = worker_id,
            .worker = worker,
            .schema = schema,
            .n = n,
        };
    }
    fn checkMetadata(self: Validation) Error!void {
        var unchanged = self.candidate;
        unchanged.functions = self.original.functions;
        unchanged.blocks = self.original.blocks;
        unchanged.constructors = self.original.constructors;
        unchanged.scopes.captures = self.original.scopes.captures;
        unchanged.constants = self.original.constants;
        if (!equal(ir.Program, self.original, unchanged) or
            self.original.functions.len != self.candidate.functions.len or
            self.original.blocks.len != self.candidate.blocks.len or
            self.original.constructors.len != self.candidate.constructors.len or
            self.candidate.scopes.captures.len != self.original.scopes.captures.len + @intFromBool(
                self.constructor_id != null,
            ) or
            self.candidate.constants.len < self.original.constants.len)
            return error.InvalidAffineCandidate;
        for (
            self.original.constants,
            self.candidate.constants[0..self.original.constants.len],
        ) |a, b| if (!equal(p.Literal, a, b)) return error.InvalidAffineCandidate;
        for (
            self.original.scopes.captures,
            self.candidate.scopes.captures[0..self.original.scopes.captures.len],
        ) |a, b| if (!equal(p.Capture, a, b)) return error.InvalidAffineCandidate;
        if (self.constructor_id) |id| {
            const capture = self.original.scopes.captures[
                @intCast(self.original.constructors[id].capture)
            ];
            var new_capture = self.candidate.scopes.captures[self.original.scopes.captures.len];
            if (new_capture.fields.len != self.basis.len) return error.InvalidAffineCandidate;
            for (new_capture.fields) |field|
                if (field != self.schema) return error.InvalidAffineCandidate;
            new_capture.fields = capture.fields;
            if (!equal(p.Capture, capture, new_capture)) return error.InvalidAffineCandidate;
        }
        for (self.original.constructors, self.candidate.constructors, 0..) |before, after, id| {
            var expected = before;
            if (self.constructor_id != null and
                id == self.constructor_id.?)
                expected.capture = self.original.scopes.captures.len;
            if (!equal(p.Constructor, expected, after)) return error.InvalidAffineCandidate;
        }
    }
    fn layouts(self: Validation) Error!void {
        if (self.input_bias.len != self.worker.inputs.len - self.n)
            return error.InvalidAffineCandidate;
        const word_bytes = width(self.original.schemas[@intCast(self.schema)]).?;
        for (self.worker.inputs[self.n..], self.input_bias) |slot, bias| {
            if (bias != 0 and (self.worker.layout.slots[
                @intCast(slot)
            ] != self.schema or (word_bytes < 8 and bias >> @intCast(
                word_bytes * 8,
            ) != 0))) return error.InvalidAffineCandidate;
        }
        if (self.worker.effects.len != 0 or self.worker.regions.len != 0)
            return error.InvalidAffineCandidate;
        for (self.original.functions, self.candidate.functions, 0..) |before, after, id| {
            var metadata = after;
            metadata.inputs = before.inputs;
            metadata.layout = before.layout;
            if (!equal(
                ir.Function,
                before,
                metadata,
            ) or after.layout.slots.len < before.layout.slots.len or !std.mem.eql(
                p.Id,
                before.layout.slots,
                after.layout.slots[0..before.layout.slots.len],
            )) return error.InvalidAffineCandidate;
            for (after.layout.slots[before.layout.slots.len..]) |field|
                if (field != self.schema)
                    return error.InvalidAffineCandidate;
            if (id == self.worker_id) {
                if (after.inputs.len != before.inputs.len - self.n + self.basis.len or !std.mem.eql(
                    p.Id,
                    before.inputs[0..self.basis.len],
                    after.inputs[0..self.basis.len],
                ) or !std.mem.eql(
                    p.Id,
                    before.inputs[self.n..],
                    after.inputs[self.basis.len..],
                )) return error.InvalidAffineCandidate;
            } else if (!std.mem.eql(
                p.Id,
                before.inputs,
                after.inputs,
            )) return error.InvalidAffineCandidate;
        }
    }
    fn block(
        self: Validation,
        a: std.mem.Allocator,
        before: ir.Block,
        after: ir.Block,
        block_index: usize,
        budget: *space.Budget,
    ) Error!void {
        try budget.charge();
        if (before.function != after.function or
            before.custody != after.custody)
            return error.InvalidAffineCandidate;
        const old_function = self.original.functions[@intCast(before.function)];
        const new_function = self.candidate.functions[@intCast(before.function)];
        const is_worker = before.function == self.worker_id;
        if (is_worker) for (self.worker.inputs[self.n..], self.input_bias) |slot, bias| {
            if (bias != 0 and @import("slot_access.zig").terminator(
                before.terminator,
                slot,
            ).writes != 0) return error.InvalidAffineCandidate;
        };
        if (is_worker) switch (before.terminator) {
            .jump, .branch, .call, .return_value => {},
            else => return error.InvalidAffineCandidate,
        };
        const old = try a.alloc(?Value, old_function.layout.slots.len);
        const new = try a.alloc(?Value, new_function.layout.slots.len);
        @memset(old, null);
        @memset(new, null);
        var next_atom = try self.seedValues(
            old_function,
            new_function,
            is_worker,
            block_index,
            old,
            new,
        );
        try self.instructions(before, after, old_function, is_worker, old, new, &next_atom, budget);
        try self.checkTerminator(before, after, new_function, is_worker, old, new, budget);
    }
    fn seedValues(
        self: Validation,
        old_function: ir.Function,
        new_function: ir.Function,
        is_worker: bool,
        block_index: usize,
        old: []?Value,
        new: []?Value,
    ) Error!usize {
        var next_atom: usize = 0;
        for (old_function.layout.slots, 0..) |field, slot| {
            if (is_worker and (std.mem.indexOfScalar(
                p.Id,
                old_function.inputs,
                slot,
            ) == null or std.mem.indexOfScalar(
                p.Id,
                self.worker.inputs[0..self.n],
                slot,
            ) != null)) continue;
            const value: Value = if (field == self.schema)
                try atom(&next_atom)
            else
                .{ .token = slot };
            old[slot] = value;
            new[slot] = value;
        }
        if (is_worker) {
            for (self.worker.inputs[0..self.n], 0..) |slot, i| {
                old[@intCast(slot)] = .{ .word = .{ .state = space.coordinate(i) } };
                new[@intCast(slot)] = null;
            }
            for (
                self.basis,
                new_function.inputs[0..self.basis.len],
            ) |row, slot| new[@intCast(slot)] = .{ .word = .{ .state = row } };
            for (self.worker.inputs[self.n..], self.input_bias) |slot, bias| if (bias != 0) {
                var encoded = try word(old[@intCast(slot)]);
                encoded.constant ^= bias;
                new[@intCast(slot)] = .{ .word = encoded };
            };
            try self.returnedValues(old_function, block_index, old, new, &next_atom);
        }
        return next_atom;
    }
    fn returnedValues(
        self: Validation,
        old_function: ir.Function,
        block_index: usize,
        old: []?Value,
        new: []?Value,
        next_atom: *usize,
    ) Error!void {
        // Only matching call-return transfers introduce token cross-block values.
        for (self.original.blocks) |predecessor| {
            if (predecessor.function != self.worker_id or
                predecessor.terminator != .call or
                predecessor.terminator.call.next.block >= self.original.blocks.len)
                continue;
            const edge = predecessor.terminator.call.next;
            if (edge.block != block_index) continue;
            for (edge.assignments) |assignment| {
                if (assignment.source != .returned) {
                    if (std.mem.indexOfScalar(
                        p.Id,
                        self.worker.inputs,
                        assignment.destination,
                    ) == null) return error.InvalidAffineCandidate;
                    continue;
                }
                if (std.mem.indexOfScalar(
                    p.Id,
                    self.worker.inputs,
                    assignment.destination,
                ) != null) return error.InvalidAffineCandidate;
                const slot: usize = @intCast(assignment.destination);
                const value: Value = if (old_function.layout.slots[slot] == self.schema) try atom(
                    next_atom,
                ) else .{ .token = slot };
                old[slot] = value;
                new[slot] = value;
            }
        }
    }
    fn instructions(
        self: Validation,
        before: ir.Block,
        after: ir.Block,
        old_function: ir.Function,
        is_worker: bool,
        old: []?Value,
        new: []?Value,
        next_atom: *usize,
        budget: *space.Budget,
    ) Error!void {
        var cursor: usize = 0;
        for (before.instructions, 0..) |op, op_index| {
            try budget.charge();
            if (is_worker and std.mem.indexOfScalar(
                p.Id,
                self.worker.inputs,
                op.destination,
            ) != null) return error.InvalidAffineCandidate;
            for (op.operands) |slot| if (old[
                @intCast(slot)
            ] == null) return error.InvalidAffineCandidate;
            const value = try evaluate(self.original, old_function, op, old, self.schema);
            if (is_worker and value != null) {
                old[@intCast(op.destination)] = .{ .word = value.? };
                continue;
            }
            try drain(self.candidate, after, &cursor, new, self.schema, old.len, budget);
            if (cursor >= after.instructions.len) return error.InvalidAffineCandidate;
            const replacement = after.instructions[cursor];
            cursor += 1;
            var metadata = replacement;
            metadata.operands = op.operands;
            if (!equal(ir.Instruction, op, metadata)) return error.InvalidAffineCandidate;
            if (self.constructor_id != null and
                op.opcode == .computation and
                op.immediate == self.constructor_id.?)
            {
                try mappedArguments(
                    op.operands,
                    replacement.operands,
                    old,
                    new,
                    self.basis,
                    self.n,
                    &.{},
                );
            } else {
                if (op.operands.len != replacement.operands.len)
                    return error.InvalidAffineCandidate;
                for (
                    op.operands,
                    replacement.operands,
                ) |left, right| if (!same(
                    old[@intCast(left)],
                    new[@intCast(right)],
                )) return error.InvalidAffineCandidate;
            }
            const result: Value = if (value) |v| .{ .word = v } else if (old_function.layout.slots[
                @intCast(op.destination)
            ] == self.schema) try atom(next_atom) else .{ .token = old.len + op_index };
            old[@intCast(op.destination)] = result;
            new[@intCast(replacement.destination)] = result;
        }
        try drain(self.candidate, after, &cursor, new, self.schema, old.len, budget);
        if (cursor != after.instructions.len) return error.InvalidAffineCandidate;
    }
    fn checkTerminator(
        self: Validation,
        before: ir.Block,
        after: ir.Block,
        new_function: ir.Function,
        is_worker: bool,
        old: []?Value,
        new: []?Value,
        budget: *space.Budget,
    ) Error!void {
        var terminator = after.terminator;
        switch (before.terminator) {
            .call => |call| {
                try self.callTerminator(
                    call,
                    &terminator,
                    new_function,
                    is_worker,
                    old,
                    new,
                    budget,
                );
            },
            .apply => |application| try self.applicationTerminator(
                application,
                before.function,
                &terminator,
                is_worker,
                old,
                new,
            ),
            .return_value => |slot| if (is_worker) {
                if (terminator != .return_value or !same(
                    old[@intCast(slot)],
                    new[@intCast(terminator.return_value)],
                )) return error.InvalidAffineCandidate;
                terminator.return_value = slot;
            },
            .branch => |branch| if (is_worker) {
                try self.branchTerminator(branch, &terminator, new_function, old, new, budget);
            },
            .jump => |edge| if (is_worker) {
                if (terminator != .jump) return error.InvalidAffineCandidate;
                try checkEdge(
                    edge,
                    terminator.jump,
                    old,
                    new,
                    self.worker.inputs[0..self.n],
                    new_function.inputs[0..self.basis.len],
                    self.basis,
                    self.worker.inputs,
                    budget,
                );
                terminator.jump = edge;
            },
            else => {},
        }
        if (!equal(
            ir.Terminator,
            before.terminator,
            terminator,
        )) return error.InvalidAffineCandidate;
    }
    fn callTerminator(
        self: Validation,
        call: @FieldType(ir.Terminator, "call"),
        terminator: *ir.Terminator,
        new_function: ir.Function,
        is_worker: bool,
        old: []?Value,
        new: []?Value,
        budget: *space.Budget,
    ) Error!void {
        if (terminator.* != .call) return error.InvalidAffineCandidate;
        const arguments = terminator.call.arguments;
        if (call.function == self.worker_id) try mappedArguments(
            call.arguments,
            arguments,
            old,
            new,
            self.basis,
            self.n,
            self.input_bias,
        ) else {
            if (call.arguments.len != arguments.len) return error.InvalidAffineCandidate;
            for (
                call.arguments,
                arguments,
            ) |left, right| if (!same(
                old[@intCast(left)],
                new[@intCast(right)],
            )) return error.InvalidAffineCandidate;
        }
        terminator.call.arguments = call.arguments;
        if (is_worker) {
            try checkEdge(
                call.next,
                terminator.call.next,
                old,
                new,
                self.worker.inputs[0..self.n],
                new_function.inputs[0..self.basis.len],
                self.basis,
                self.worker.inputs,
                budget,
            );
            terminator.call.next = call.next;
        }
    }
    fn branchTerminator(
        self: Validation,
        branch: @FieldType(ir.Terminator, "branch"),
        terminator: *ir.Terminator,
        new_function: ir.Function,
        old: []?Value,
        new: []?Value,
        budget: *space.Budget,
    ) Error!void {
        if (terminator.* != .branch or !same(
            old[@intCast(branch.condition)],
            new[@intCast(terminator.branch.condition)],
        )) return error.InvalidAffineCandidate;
        terminator.branch.condition = branch.condition;
        try checkEdge(
            branch.when_true,
            terminator.branch.when_true,
            old,
            new,
            self.worker.inputs[0..self.n],
            new_function.inputs[0..self.basis.len],
            self.basis,
            self.worker.inputs,
            budget,
        );
        try checkEdge(
            branch.when_false,
            terminator.branch.when_false,
            old,
            new,
            self.worker.inputs[0..self.n],
            new_function.inputs[0..self.basis.len],
            self.basis,
            self.worker.inputs,
            budget,
        );
        terminator.branch.when_true = branch.when_true;
        terminator.branch.when_false = branch.when_false;
    }
    fn applicationTerminator(
        self: Validation,
        application: @FieldType(ir.Terminator, "apply"),
        function: p.Id,
        terminator: *ir.Terminator,
        is_worker: bool,
        old: []?Value,
        new: []?Value,
    ) Error!void {
        if (self.constructor_id != null and
            !is_worker and
            selectedApplication(
                self.original,
                function,
                application.computation,
                self.constructor_id.?,
            ))
        {
            if (terminator.* != .apply) return error.InvalidAffineCandidate;
            try inputArguments(
                application.arguments,
                terminator.apply.arguments,
                old,
                new,
                self.input_bias,
            );
            terminator.apply.arguments = application.arguments;
        }
    }
};
