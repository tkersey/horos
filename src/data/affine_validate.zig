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
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    unchanged.constructors = original.constructors;
    unchanged.scopes.captures = original.scopes.captures;
    unchanged.constants = original.constants;
    if (!equal(ir.Program, original, unchanged) or
        original.functions.len != candidate.functions.len or
        original.blocks.len != candidate.blocks.len or
        original.constructors.len != candidate.constructors.len or
        candidate.scopes.captures.len != original.scopes.captures.len + @intFromBool(
            constructor_id != null,
        ) or
        candidate.constants.len < original.constants.len)
        return error.InvalidAffineCandidate;
    for (
        original.constants,
        candidate.constants[0..original.constants.len],
    ) |a, b| if (!equal(p.Literal, a, b)) return error.InvalidAffineCandidate;
    for (
        original.scopes.captures,
        candidate.scopes.captures[0..original.scopes.captures.len],
    ) |a, b| if (!equal(p.Capture, a, b)) return error.InvalidAffineCandidate;
    if (constructor_id) |id| {
        const capture = original.scopes.captures[@intCast(original.constructors[id].capture)];
        var new_capture = candidate.scopes.captures[original.scopes.captures.len];
        if (new_capture.fields.len != basis.len) return error.InvalidAffineCandidate;
        for (new_capture.fields) |field| if (field != schema) return error.InvalidAffineCandidate;
        new_capture.fields = capture.fields;
        if (!equal(p.Capture, capture, new_capture)) return error.InvalidAffineCandidate;
    }
    for (original.constructors, candidate.constructors, 0..) |before, after, id| {
        var expected = before;
        if (constructor_id != null and
            id == constructor_id.?)
            expected.capture = original.scopes.captures.len;
        if (!equal(p.Constructor, expected, after)) return error.InvalidAffineCandidate;
    }
    if (input_bias.len != worker.inputs.len - n) return error.InvalidAffineCandidate;
    const word_bytes = width(original.schemas[@intCast(schema)]).?;
    for (worker.inputs[n..], input_bias) |slot, bias| {
        if (bias != 0 and (worker.layout.slots[
            @intCast(slot)
        ] != schema or (word_bytes < 8 and bias >> @intCast(
            word_bytes * 8,
        ) != 0))) return error.InvalidAffineCandidate;
    }
    if (worker.effects.len != 0 or worker.regions.len != 0) return error.InvalidAffineCandidate;
    for (original.functions, candidate.functions, 0..) |before, after, id| {
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
            if (field != schema)
                return error.InvalidAffineCandidate;
        if (id == worker_id) {
            if (after.inputs.len != before.inputs.len - n + basis.len or !std.mem.eql(
                p.Id,
                before.inputs[0..basis.len],
                after.inputs[0..basis.len],
            ) or !std.mem.eql(
                p.Id,
                before.inputs[n..],
                after.inputs[basis.len..],
            )) return error.InvalidAffineCandidate;
        } else if (!std.mem.eql(
            p.Id,
            before.inputs,
            after.inputs,
        )) return error.InvalidAffineCandidate;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var budget: space.Budget = .{ .remaining = work_limit };
    for (original.blocks, candidate.blocks, 0..) |before, after, block_index| {
        try budget.charge();
        if (before.function != after.function or
            before.custody != after.custody)
            return error.InvalidAffineCandidate;
        const old_function = original.functions[@intCast(before.function)];
        const new_function = candidate.functions[@intCast(before.function)];
        const is_worker = before.function == worker_id;
        if (is_worker) for (worker.inputs[n..], input_bias) |slot, bias| {
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
        var next_atom: usize = 0;
        for (old_function.layout.slots, 0..) |field, slot| {
            if (is_worker and (std.mem.indexOfScalar(
                p.Id,
                old_function.inputs,
                slot,
            ) == null or std.mem.indexOfScalar(
                p.Id,
                worker.inputs[0..n],
                slot,
            ) != null)) continue;
            const value: Value = if (field == schema) try atom(&next_atom) else .{ .token = slot };
            old[slot] = value;
            new[slot] = value;
        }
        if (is_worker) {
            for (worker.inputs[0..n], 0..) |slot, i| {
                old[@intCast(slot)] = .{ .word = .{ .state = space.coordinate(i) } };
                new[@intCast(slot)] = null;
            }
            for (
                basis,
                new_function.inputs[0..basis.len],
            ) |row, slot| new[@intCast(slot)] = .{ .word = .{ .state = row } };
            for (worker.inputs[n..], input_bias) |slot, bias| if (bias != 0) {
                var encoded = try word(old[@intCast(slot)]);
                encoded.constant ^= bias;
                new[@intCast(slot)] = .{ .word = encoded };
            };
            // Only matching call-return transfers introduce token cross-block values.
            for (original.blocks) |predecessor| {
                if (predecessor.function != worker_id or
                    predecessor.terminator != .call or
                    predecessor.terminator.call.next.block >= original.blocks.len)
                    continue;
                const edge = predecessor.terminator.call.next;
                if (edge.block != block_index) continue;
                for (edge.assignments) |assignment| {
                    if (assignment.source != .returned) {
                        if (std.mem.indexOfScalar(
                            p.Id,
                            worker.inputs,
                            assignment.destination,
                        ) == null) return error.InvalidAffineCandidate;
                        continue;
                    }
                    if (std.mem.indexOfScalar(
                        p.Id,
                        worker.inputs,
                        assignment.destination,
                    ) != null) return error.InvalidAffineCandidate;
                    const slot: usize = @intCast(assignment.destination);
                    const value: Value = if (old_function.layout.slots[slot] == schema) try atom(
                        &next_atom,
                    ) else .{ .token = slot };
                    old[slot] = value;
                    new[slot] = value;
                }
            }
        }
        var cursor: usize = 0;
        for (before.instructions, 0..) |op, op_index| {
            try budget.charge();
            if (is_worker and std.mem.indexOfScalar(
                p.Id,
                worker.inputs,
                op.destination,
            ) != null) return error.InvalidAffineCandidate;
            for (op.operands) |slot| if (old[
                @intCast(slot)
            ] == null) return error.InvalidAffineCandidate;
            const value = try evaluate(original, old_function, op, old, schema);
            if (is_worker and value != null) {
                old[@intCast(op.destination)] = .{ .word = value.? };
                continue;
            }
            try drain(candidate, after, &cursor, new, schema, old.len, &budget);
            if (cursor >= after.instructions.len) return error.InvalidAffineCandidate;
            const replacement = after.instructions[cursor];
            cursor += 1;
            var metadata = replacement;
            metadata.operands = op.operands;
            if (!equal(ir.Instruction, op, metadata)) return error.InvalidAffineCandidate;
            if (constructor_id != null and
                op.opcode == .computation and
                op.immediate == constructor_id.?)
            {
                try mappedArguments(op.operands, replacement.operands, old, new, basis, n, &.{});
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
            ] == schema) try atom(&next_atom) else .{ .token = old.len + op_index };
            old[@intCast(op.destination)] = result;
            new[@intCast(replacement.destination)] = result;
        }
        try drain(candidate, after, &cursor, new, schema, old.len, &budget);
        if (cursor != after.instructions.len) return error.InvalidAffineCandidate;
        var terminator = after.terminator;
        switch (before.terminator) {
            .call => |call| {
                if (terminator != .call) return error.InvalidAffineCandidate;
                const arguments = terminator.call.arguments;
                if (call.function == worker_id) try mappedArguments(
                    call.arguments,
                    arguments,
                    old,
                    new,
                    basis,
                    n,
                    input_bias,
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
                        worker.inputs[0..n],
                        new_function.inputs[0..basis.len],
                        basis,
                        worker.inputs,
                        &budget,
                    );
                    terminator.call.next = call.next;
                }
            },
            .apply => |application| if (constructor_id != null and
                !is_worker and
                selectedApplication(
                    original,
                    before.function,
                    application.computation,
                    constructor_id.?,
                ))
            {
                if (terminator != .apply) return error.InvalidAffineCandidate;
                try inputArguments(
                    application.arguments,
                    terminator.apply.arguments,
                    old,
                    new,
                    input_bias,
                );
                terminator.apply.arguments = application.arguments;
            },
            .return_value => |slot| if (is_worker) {
                if (terminator != .return_value or !same(
                    old[@intCast(slot)],
                    new[@intCast(terminator.return_value)],
                )) return error.InvalidAffineCandidate;
                terminator.return_value = slot;
            },
            .branch => |branch| if (is_worker) {
                if (terminator != .branch or !same(
                    old[@intCast(branch.condition)],
                    new[@intCast(terminator.branch.condition)],
                )) return error.InvalidAffineCandidate;
                terminator.branch.condition = branch.condition;
                try checkEdge(
                    branch.when_true,
                    terminator.branch.when_true,
                    old,
                    new,
                    worker.inputs[0..n],
                    new_function.inputs[0..basis.len],
                    basis,
                    worker.inputs,
                    &budget,
                );
                try checkEdge(
                    branch.when_false,
                    terminator.branch.when_false,
                    old,
                    new,
                    worker.inputs[0..n],
                    new_function.inputs[0..basis.len],
                    basis,
                    worker.inputs,
                    &budget,
                );
                terminator.branch.when_true = branch.when_true;
                terminator.branch.when_false = branch.when_false;
            },
            .jump => |edge| if (is_worker) {
                if (terminator != .jump) return error.InvalidAffineCandidate;
                try checkEdge(
                    edge,
                    terminator.jump,
                    old,
                    new,
                    worker.inputs[0..n],
                    new_function.inputs[0..basis.len],
                    basis,
                    worker.inputs,
                    &budget,
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
}
