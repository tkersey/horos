// Copyright (c) 2026 Boundary contributors. MIT license.
//! Registered sufficient summary: two immutable u64 captures observed only as
//! their exact XOR become one captured XOR. No runtime representation is decoded.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const privacy = @import("capture_reduction.zig");
const access = @import("slot_access.zig").terminator;
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
pub const Error = coalescing.Error || error{InvalidCaptureSummary};
pub const Witness = struct { constructor: usize };
pub const Statistics = struct {
    constructors_summarized: usize = 0,
    fields_removed: usize = 0,
    worker_xors_replaced: usize = 0,
    construction_xors: usize = 0,
    direct_call_xors: usize = 0,
    retained_constructors: usize = 0,
};

fn observesPair(op: ir.Instruction, left: p.Id, right: p.Id) bool {
    return std.mem.indexOfScalar(p.Id, op.operands, left) != null or std.mem.indexOfScalar(p.Id, op.operands, right) != null;
}
fn exactXor(op: ir.Instruction, left: p.Id, right: p.Id) bool {
    return op.opcode == .integer_bit_xor and
        op.operands.len == 2 and
        op.operands[0] == left and
        op.operands[1] == right and
        op.failures.len == 0 and
        op.immediate == 0;
}
fn lawDomain(program: ir.Program, constructor_id: usize) bool {
    const constructor = program.constructors[constructor_id];
    const capture = program.scopes.captures[@intCast(constructor.capture)];
    if (capture.fields.len != 2 or capture.fields[0] != capture.fields[1] or
        program.schemas[
            @intCast(capture.fields[0])
        ] != .u64 or
        capture.owned_regions.len != 0 or
        capture.borrowed_regions.len != 0 or
        capture.use != .reusable)
        return false;
    if (!privacy.privateWorker(program, constructor_id) or !privacy.privateConstructions(program, constructor_id)) return false;
    const worker = program.functions[@intCast(constructor.function)];
    const left = worker.inputs[0];
    const right = worker.inputs[1];
    var observations: usize = 0;
    for (program.blocks) |block| {
        if (block.function != constructor.function) continue;
        for (block.instructions) |op| {
            if (op.destination == left or op.destination == right) return false;
            if (!observesPair(op, left, right)) continue;
            if (!exactXor(op, left, right)) return false;
            observations += 1;
        }
        const l = access(block.terminator, left);
        const r = access(block.terminator, right);
        if (l.reads != 0 or l.writes != 0 or r.reads != 0 or r.writes != 0) return false;
    }
    return observations != 0;
}
fn summarized(
    allocator: std.mem.Allocator,
    values: []const p.Id,
    summary: p.Id,
) std.mem.Allocator.Error![]const p.Id {
    const result = try allocator.alloc(p.Id, values.len - 1);
    result[0] = summary;
    @memcpy(result[1..], values[2..]);
    return result;
}
fn matchesArguments(before: []const p.Id, after: []const p.Id, summary: p.Id) bool {
    return before.len >= 2 and after.len == before.len - 1 and after[0] == summary and std.mem.eql(
        p.Id,
        before[2..],
        after[1..],
    );
}

pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: coalescing.Options,
) Error!coalescing.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var flow = try ownership.analyze(allocator, original);
    defer flow.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var witnesses: std.ArrayList(Witness) = .empty;
    const selected = try a.alloc(bool, original.constructors.len);
    const workers = try a.alloc(bool, original.functions.len);
    @memset(selected, false);
    @memset(workers, false);
    for (original.constructors, 0..) |constructor, id| {
        if (!lawDomain(original, id)) {
            stats.retained_constructors += 1;
            continue;
        }
        selected[id] = true;
        workers[@intCast(constructor.function)] = true;
        try witnesses.append(a, .{ .constructor = id });
    }
    const functions = try a.dupe(ir.Function, original.functions);
    const constructors = try a.dupe(p.Constructor, original.constructors);
    var captures: std.ArrayList(p.Capture) = .empty;
    try captures.appendSlice(a, original.scopes.captures);
    for (witnesses.items) |witness| {
        const constructor = original.constructors[witness.constructor];
        var capture = original.scopes.captures[@intCast(constructor.capture)];
        capture.fields = capture.fields[0..1];
        constructors[witness.constructor].capture = captures.items.len;
        try captures.append(a, capture);
        const worker = &functions[@intCast(constructor.function)];
        worker.inputs = try summarized(a, worker.inputs, worker.inputs[0]);
    }
    // Each insertion receives its own fresh scalar slot, after every original
    // operand evaluation. Original locals never acquire a new meaning in callers.
    const layouts = try a.alloc(std.ArrayList(p.Id), functions.len);
    for (original.functions, layouts) |function, *layout| {
        layout.* = .empty;
        try layout.appendSlice(a, function.layout.slots);
    }
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (original.blocks, blocks) |block, *out| {
        var instructions: std.ArrayList(ir.Instruction) = .empty;
        const worker = original.functions[@intCast(block.function)];
        for (block.instructions) |op| {
            var replacement = op;
            if (workers[@intCast(block.function)] and exactXor(
                op,
                worker.inputs[0],
                worker.inputs[1],
            )) {
                replacement = .{
                    .destination = op.destination,
                    .opcode = .move,
                    .operands = try a.dupe(p.Id, &.{worker.inputs[0]}),
                };
                stats.worker_xors_replaced += 1;
            }
            if (op.opcode == .computation and selected[@intCast(op.immediate)]) {
                const schema = original.scopes.captures[
                    @intCast(original.constructors[
                        @intCast(op.immediate)
                    ].capture)
                ].fields[0];
                const layout = &layouts[@intCast(block.function)];
                const slot = layout.items.len;
                try layout.append(a, schema);
                try instructions.append(
                    a,
                    .{
                        .destination = slot,
                        .opcode = .integer_bit_xor,
                        .operands = try a.dupe(p.Id, op.operands[0..2]),
                    },
                );
                replacement.operands = try summarized(a, op.operands, slot);
                stats.construction_xors += 1;
            }
            try instructions.append(a, replacement);
        }
        if (block.terminator == .call and workers[@intCast(block.terminator.call.function)]) {
            const call = block.terminator.call;
            const target = original.functions[@intCast(call.function)];
            const schema = target.layout.slots[@intCast(target.inputs[0])];
            const layout = &layouts[@intCast(block.function)];
            const slot = layout.items.len;
            try layout.append(a, schema);
            try instructions.append(
                a,
                .{
                    .destination = slot,
                    .opcode = .integer_bit_xor,
                    .operands = try a.dupe(p.Id, call.arguments[0..2]),
                },
            );
            out.terminator.call.arguments = try summarized(a, call.arguments, slot);
            stats.direct_call_xors += 1;
        }
        out.instructions = try instructions.toOwnedSlice(a);
    }
    for (functions, layouts) |*function, layout| function.layout.slots = layout.items;
    var candidate = original;
    candidate.functions = functions;
    candidate.constructors = constructors;
    candidate.scopes.captures = captures.items;
    candidate.blocks = blocks;
    try validate(allocator, original, candidate, witnesses.items);
    stats.constructors_summarized = witnesses.items.len;
    stats.fields_removed = witnesses.items.len;
    return coalescing.run(allocator, candidate, options);
}

/// Check the complete observation census and each correspondence, not a finder
/// fingerprint. The only admitted relation is s = x XOR y on immutable u64s.
/// Every worker observer reads s; all other operations keep their exact records.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var flow = try ownership.analyze(allocator, original);
    defer flow.deinit();
    var checked = try ownership.analyze(allocator, candidate);
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var same = candidate;
    same.functions = original.functions;
    same.blocks = original.blocks;
    same.constructors = original.constructors;
    same.scopes.captures = original.scopes.captures;
    if (!equal(ir.Program, original, same) or
        candidate.functions.len != original.functions.len or
        candidate.blocks.len != original.blocks.len or
        candidate.constructors.len != original.constructors.len or
        candidate.scopes.captures.len != original.scopes.captures.len + witnesses.len)
        return error.InvalidCaptureSummary;
    for (
        original.scopes.captures,
        candidate.scopes.captures[0..original.scopes.captures.len],
    ) |before, after| if (!equal(p.Capture, before, after)) return error.InvalidCaptureSummary;
    const selected = try a.alloc(bool, original.constructors.len);
    const workers = try a.alloc(bool, original.functions.len);
    const capture_ids = try a.alloc(p.Id, original.constructors.len);
    @memset(selected, false);
    @memset(workers, false);
    for (original.constructors, capture_ids) |constructor, *id| id.* = constructor.capture;
    for (witnesses, 0..) |witness, index| {
        if (witness.constructor >= selected.len or
            selected[witness.constructor])
            return error.InvalidCaptureSummary;
        const constructor = original.constructors[witness.constructor];
        const capture = original.scopes.captures[@intCast(constructor.capture)];
        if (capture.fields.len != 2 or capture.fields[0] != capture.fields[1] or
            original.schemas[
                @intCast(capture.fields[0])
            ] != .u64 or
            capture.use != .reusable or
            capture.owned_regions.len != 0 or
            capture.borrowed_regions.len != 0 or
            !privacy.privateWorker(original, witness.constructor) or
            !privacy.privateConstructions(original, witness.constructor))
            return error.InvalidCaptureSummary;
        const worker = original.functions[@intCast(constructor.function)];
        // Independent universal-use check: no individual observer or update may
        // distinguish two environments with the same bitwise summary.
        var observers: usize = 0;
        for (original.blocks) |block| {
            if (block.function != constructor.function) continue;
            for (block.instructions) |op| {
                if (op.destination == worker.inputs[0] or
                    op.destination == worker.inputs[1])
                    return error.InvalidCaptureSummary;
                for (op.operands) |slot|
                    if (slot == worker.inputs[0] or slot == worker.inputs[1]) {
                        if (op.opcode != .integer_bit_xor or
                            op.operands.len != 2 or
                            op.operands[0] != worker.inputs[0] or
                            op.operands[1] != worker.inputs[1] or
                            op.immediate != 0 or
                            op.failures.len != 0)
                            return error.InvalidCaptureSummary;
                        observers += 1;
                    };
            }
            for (worker.inputs[0..2]) |slot| {
                const uses = access(block.terminator, slot);
                if (uses.reads != 0 or uses.writes != 0) return error.InvalidCaptureSummary;
            }
        }
        if (observers == 0) return error.InvalidCaptureSummary;
        const id = original.scopes.captures.len + index;
        var expected = capture;
        expected.fields = capture.fields[0..1];
        if (!equal(
            p.Capture,
            expected,
            candidate.scopes.captures[id],
        )) return error.InvalidCaptureSummary;
        selected[witness.constructor] = true;
        workers[@intCast(constructor.function)] = true;
        capture_ids[witness.constructor] = id;
    }
    for (original.constructors, candidate.constructors, capture_ids) |before, after, id| {
        var expected = before;
        expected.capture = id;
        if (!equal(p.Constructor, expected, after)) return error.InvalidCaptureSummary;
    }
    const next_slot = try a.alloc(usize, original.functions.len);
    for (
        original.functions,
        candidate.functions,
        workers,
        next_slot,
    ) |before, after, summarized_worker, *next| {
        next.* = before.layout.slots.len;
        if (after.layout.slots.len < before.layout.slots.len or !std.mem.eql(
            p.Id,
            before.layout.slots,
            after.layout.slots[0..before.layout.slots.len],
        )) return error.InvalidCaptureSummary;
        var unchanged = after;
        unchanged.layout = before.layout;
        unchanged.inputs = before.inputs;
        if (!equal(ir.Function, before, unchanged)) return error.InvalidCaptureSummary;
        if (summarized_worker) {
            if (!matchesArguments(
                before.inputs,
                after.inputs,
                before.inputs[0],
            )) return error.InvalidCaptureSummary;
        } else if (!std.mem.eql(
            p.Id,
            before.inputs,
            after.inputs,
        )) return error.InvalidCaptureSummary;
    }
    for (original.blocks, candidate.blocks) |before, after| {
        const owner: usize = @intCast(before.function);
        const worker = original.functions[owner];
        var next: usize = 0;
        for (before.instructions) |op| {
            var expected = op;
            var operands: [1]p.Id = undefined;
            if (workers[owner] and exactXor(op, worker.inputs[0], worker.inputs[1])) {
                operands[0] = worker.inputs[0];
                expected = .{
                    .destination = op.destination,
                    .opcode = .move,
                    .operands = &operands,
                };
            }
            if (op.opcode == .computation and selected[@intCast(op.immediate)]) {
                if (next >= after.instructions.len) return error.InvalidCaptureSummary;
                const slot = next_slot[owner];
                next_slot[owner] += 1;
                try checkInsertion(
                    original,
                    candidate,
                    owner,
                    slot,
                    op.operands,
                    after.instructions[next],
                );
                next += 1;
                if (next >= after.instructions.len or !matchesArguments(
                    op.operands,
                    after.instructions[next].operands,
                    slot,
                )) return error.InvalidCaptureSummary;
                expected.operands = after.instructions[next].operands;
            }
            if (next >= after.instructions.len or !equal(
                ir.Instruction,
                expected,
                after.instructions[next],
            )) return error.InvalidCaptureSummary;
            next += 1;
        }
        var unchanged = after;
        unchanged.instructions = before.instructions;
        if (before.terminator == .call and workers[@intCast(before.terminator.call.function)]) {
            const call = before.terminator.call;
            if (next >= after.instructions.len or after.terminator != .call or !matchesArguments(
                call.arguments,
                after.terminator.call.arguments,
                next_slot[owner],
            )) return error.InvalidCaptureSummary;
            try checkInsertion(
                original,
                candidate,
                owner,
                next_slot[owner],
                call.arguments,
                after.instructions[next],
            );
            next_slot[owner] += 1;
            next += 1;
            unchanged.terminator.call.arguments = call.arguments;
        }
        if (next != after.instructions.len or !equal(
            ir.Block,
            before,
            unchanged,
        )) return error.InvalidCaptureSummary;
    }
    for (
        candidate.functions,
        next_slot,
    ) |function, count| if (function.layout.slots.len != count) return error.InvalidCaptureSummary;
}
fn checkInsertion(
    original: ir.Program,
    candidate: ir.Program,
    owner: usize,
    slot: usize,
    arguments: []const p.Id,
    op: ir.Instruction,
) Error!void {
    if (slot >= candidate.functions[owner].layout.slots.len or
        arguments.len < 2)
        return error.InvalidCaptureSummary;
    const schema = original.functions[owner].layout.slots[@intCast(arguments[0])];
    if (candidate.functions[owner].layout.slots[slot] != schema or original.schemas[
        @intCast(schema)
    ] != .u64) return error.InvalidCaptureSummary;
    const expected: ir.Instruction = .{
        .destination = slot,
        .opcode = .integer_bit_xor,
        .operands = arguments[0..2],
    };
    if (!equal(ir.Instruction, expected, op)) return error.InvalidCaptureSummary;
}
