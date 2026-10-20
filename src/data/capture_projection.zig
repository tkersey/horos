// Copyright (c) 2026 Boundary contributors. MIT license.
//! A private closure observing one immutable product field captures that field.
//! New private schemas preserve every other constructor's original capture bound.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const admission = @import("admission.zig");
const privacy = @import("capture_reduction.zig");
const access = @import("slot_access.zig").terminator;
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
pub const Error = coalescing.Error || error{InvalidCaptureProjection};
pub const Witness = struct { constructor: usize, field: p.Id };
pub const Statistics = struct {
    constructors_projected: usize = 0,
    worker_projections_removed: usize = 0,
    producer_projections: usize = 0,
    direct_projections: usize = 0,
};

fn quietProducers(program: ir.Program, constructor_id: usize) bool {
    for (program.blocks) |block| for (block.instructions) |op| {
        if (op.opcode != .computation or op.immediate != constructor_id) continue;
        const slots = program.functions[@intCast(block.function)].layout.slots;
        for (program.blocks) |other| {
            if (other.function != block.function) continue;
            switch (other.terminator) {
                .return_value, .fail, .jump, .branch, .switch_variant, .unpack_product => {},
                .apply => |call| if (program.schemas[
                    @intCast(slots[
                        @intCast(call.computation)
                    ])
                ].internal.computation.effects.len != 0) return false,
                .call => |call| if (program.functions[
                    @intCast(call.function)
                ].effects.len != 0) return false,
                else => return false,
            }
        }
    };
    return true;
}
fn domain(program: ir.Program, id: usize, exportable: []const bool) bool {
    const constructor = program.constructors[id];
    const capture = program.scopes.captures[@intCast(constructor.capture)];
    const worker = program.functions[@intCast(constructor.function)];
    if (capture.fields.len != 1 or
        capture.use != .reusable or
        capture.owned_regions.len != 0 or
        capture.borrowed_regions.len != 0 or
        worker.effects.len != 0 or
        worker.regions.len != 0)
        return false;
    const schema = capture.fields[0];
    return program.schemas[
        @intCast(schema)
    ] == .product and exportable[
        @intCast(schema)
    ] and privacy.privateWorker(program, id) and privacy.privateConstructions(program, id) and quietProducers(program, id);
}
fn observedField(program: ir.Program, id: usize) ?p.Id {
    const worker_id = program.constructors[id].function;
    const input = program.functions[@intCast(worker_id)].inputs[0];
    var field: ?p.Id = null;
    for (program.blocks) |block| {
        if (block.function != worker_id) continue;
        for (block.instructions) |op| {
            if (op.destination == input) return null;
            if (std.mem.indexOfScalar(p.Id, op.operands, input) == null) continue;
            if (op.opcode != .field or
                op.operands.len != 1 or
                op.operands[0] != input or
                op.failures.len != 0)
                return null;
            if (field) |previous| {
                if (previous != op.immediate) return null;
            } else field = op.immediate;
        }
        const uses = access(block.terminator, input);
        if (uses.reads != 0 or uses.writes != 0) return null;
    }
    return field;
}
fn fieldSchema(program: ir.Program, witness: Witness) p.Id {
    const capture = program.scopes.captures[
        @intCast(program.constructors[witness.constructor].capture)
    ];
    return program.schemas[@intCast(capture.fields[0])].product[@intCast(witness.field)];
}
fn arguments(
    a: std.mem.Allocator,
    old: []const p.Id,
    slot: p.Id,
) std.mem.Allocator.Error![]const p.Id {
    const result = try a.dupe(p.Id, old);
    result[0] = slot;
    return result;
}
fn sameArguments(old: []const p.Id, new: []const p.Id, slot: p.Id) bool {
    return old.len != 0 and old.len == new.len and new[0] == slot and std.mem.eql(
        p.Id,
        old[1..],
        new[1..],
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
    const schema_facts = try admission.schemas(a, original.schemas);
    var witnesses: std.ArrayList(Witness) = .empty;
    const selected = try a.alloc(?Witness, original.constructors.len);
    const workers = try a.alloc(?Witness, original.functions.len);
    @memset(selected, null);
    @memset(workers, null);
    for (original.constructors, 0..) |constructor, id| {
        if (!domain(original, id, schema_facts.exportable)) continue;
        const field = observedField(original, id) orelse continue;
        const witness: Witness = .{ .constructor = id, .field = field };
        selected[id] = witness;
        workers[@intCast(constructor.function)] = witness;
        try witnesses.append(a, witness);
    }
    const functions = try a.dupe(ir.Function, original.functions);
    const constructors = try a.dupe(p.Constructor, original.constructors);
    const layouts = try a.alloc(std.ArrayList(p.Id), functions.len);
    for (functions, layouts) |function, *layout| {
        layout.* = .empty;
        try layout.appendSlice(a, function.layout.slots);
    }
    var schemas: std.ArrayList(p.Schema) = .empty;
    var captures: std.ArrayList(p.Capture) = .empty;
    try schemas.appendSlice(a, original.schemas);
    try captures.appendSlice(a, original.scopes.captures);
    for (witnesses.items) |witness| {
        const constructor = original.constructors[witness.constructor];
        const field_type = fieldSchema(original, witness);
        var capture = original.scopes.captures[@intCast(constructor.capture)];
        capture.fields = try a.dupe(p.Id, &.{field_type});
        constructors[witness.constructor].capture = captures.items.len;
        try captures.append(a, capture);
        var shape = original.schemas[@intCast(constructor.schema)];
        shape.internal.computation.capture_bound = capture.fields;
        constructors[witness.constructor].schema = schemas.items.len;
        try schemas.append(a, shape);
        const worker = original.functions[@intCast(constructor.function)];
        layouts[@intCast(constructor.function)].items[@intCast(worker.inputs[0])] = field_type;
    }
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (original.blocks, blocks) |block, *out| {
        var instructions: std.ArrayList(ir.Instruction) = .empty;
        const owner: usize = @intCast(block.function);
        const worker = original.functions[owner];
        for (block.instructions) |op| {
            var replacement = op;
            if (workers[owner] != null and
                op.opcode == .field and
                op.operands[0] == worker.inputs[0])
            {
                replacement = .{
                    .destination = op.destination,
                    .opcode = .move,
                    .operands = try a.dupe(p.Id, &.{worker.inputs[0]}),
                };
                stats.worker_projections_removed += 1;
            }
            if (op.opcode == .computation) if (selected[@intCast(op.immediate)]) |witness| {
                const slot = layouts[owner].items.len;
                try layouts[owner].append(a, fieldSchema(original, witness));
                layouts[owner].items[
                    @intCast(op.destination)
                ] = constructors[
                    @intCast(op.immediate)
                ].schema;
                try instructions.append(
                    a,
                    .{
                        .destination = slot,
                        .opcode = .field,
                        .operands = try a.dupe(p.Id, op.operands[0..1]),
                        .immediate = witness.field,
                    },
                );
                replacement.operands = try arguments(a, op.operands, slot);
                stats.producer_projections += 1;
            };
            try instructions.append(a, replacement);
        }
        if (block.terminator == .call) if (workers[
            @intCast(block.terminator.call.function)
        ]) |witness| {
            const call = block.terminator.call;
            const slot = layouts[owner].items.len;
            try layouts[owner].append(a, fieldSchema(original, witness));
            try instructions.append(
                a,
                .{
                    .destination = slot,
                    .opcode = .field,
                    .operands = try a.dupe(p.Id, call.arguments[0..1]),
                    .immediate = witness.field,
                },
            );
            out.terminator.call.arguments = try arguments(a, call.arguments, slot);
            stats.direct_projections += 1;
        };
        out.instructions = try instructions.toOwnedSlice(a);
    }
    for (functions, layouts) |*function, layout| function.layout.slots = layout.items;
    var candidate = original;
    candidate.functions = functions;
    candidate.constructors = constructors;
    candidate.schemas = schemas.items;
    candidate.scopes.captures = captures.items;
    candidate.blocks = blocks;
    try validate(allocator, original, candidate, witnesses.items);
    stats.constructors_projected = witnesses.items.len;
    return coalescing.run(allocator, candidate, options);
}

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
    const schema_facts = try admission.schemas(a, original.schemas);
    var same = candidate;
    same.functions = original.functions;
    same.blocks = original.blocks;
    same.constructors = original.constructors;
    same.schemas = original.schemas;
    same.scopes.captures = original.scopes.captures;
    if (!equal(ir.Program, original, same) or
        candidate.functions.len != original.functions.len or
        candidate.blocks.len != original.blocks.len or
        candidate.constructors.len != original.constructors.len or
        candidate.schemas.len != original.schemas.len + witnesses.len or
        candidate.scopes.captures.len != original.scopes.captures.len + witnesses.len)
        return error.InvalidCaptureProjection;
    for (
        original.schemas,
        candidate.schemas[0..original.schemas.len],
    ) |old, new| if (!equal(p.Schema, old, new)) return error.InvalidCaptureProjection;
    for (
        original.scopes.captures,
        candidate.scopes.captures[0..original.scopes.captures.len],
    ) |old, new| if (!equal(p.Capture, old, new)) return error.InvalidCaptureProjection;
    const selected = try a.alloc(?Witness, original.constructors.len);
    const workers = try a.alloc(?Witness, original.functions.len);
    const types = try a.alloc(p.Id, original.constructors.len);
    const captures = try a.alloc(p.Id, original.constructors.len);
    @memset(selected, null);
    @memset(workers, null);
    for (original.constructors, types, captures) |constructor, *shape, *capture| {
        shape.* = constructor.schema;
        capture.* = constructor.capture;
    }
    for (witnesses, 0..) |witness, index| {
        if (witness.constructor >= selected.len or selected[witness.constructor] != null or !domain(
            original,
            witness.constructor,
            schema_facts.exportable,
        )) return error.InvalidCaptureProjection;
        const constructor = original.constructors[witness.constructor];
        const capture = original.scopes.captures[@intCast(constructor.capture)];
        if (witness.field >= original.schemas[
            @intCast(capture.fields[0])
        ].product.len) return error.InvalidCaptureProjection;
        const worker = original.functions[@intCast(constructor.function)];
        var count: usize = 0;
        for (original.blocks) |block| {
            if (block.function != constructor.function) continue;
            for (block.instructions) |op| {
                if (op.destination == worker.inputs[0]) return error.InvalidCaptureProjection;
                for (op.operands) |slot|
                    if (slot == worker.inputs[0]) {
                        if (op.opcode != .field or
                            op.operands.len != 1 or
                            op.immediate != witness.field or
                            op.failures.len != 0)
                            return error.InvalidCaptureProjection;
                        count += 1;
                    };
            }
            const uses = access(block.terminator, worker.inputs[0]);
            if (uses.reads != 0 or uses.writes != 0) return error.InvalidCaptureProjection;
        }
        if (count == 0) return error.InvalidCaptureProjection;
        const field_type = fieldSchema(original, witness);
        var expected_capture = capture;
        expected_capture.fields = &.{field_type};
        var expected_schema = original.schemas[@intCast(constructor.schema)];
        expected_schema.internal.computation.capture_bound = &.{field_type};
        const schema_id = original.schemas.len + index;
        const capture_id = original.scopes.captures.len + index;
        if (!equal(p.Schema, expected_schema, candidate.schemas[schema_id]) or !equal(
            p.Capture,
            expected_capture,
            candidate.scopes.captures[capture_id],
        )) return error.InvalidCaptureProjection;
        selected[witness.constructor] = witness;
        workers[@intCast(constructor.function)] = witness;
        types[witness.constructor] = schema_id;
        captures[witness.constructor] = capture_id;
    }
    for (
        original.constructors,
        candidate.constructors,
        types,
        captures,
    ) |old, new, shape, capture| {
        var expected = old;
        expected.schema = shape;
        expected.capture = capture;
        if (!equal(p.Constructor, expected, new)) return error.InvalidCaptureProjection;
    }
    const layouts = try a.alloc([]p.Id, original.functions.len);
    const next_slots = try a.alloc(usize, original.functions.len);
    for (original.functions, layouts, next_slots, workers) |function, *layout, *next, witness| {
        layout.* = try a.dupe(p.Id, function.layout.slots);
        next.* = layout.len;
        if (witness) |item| layout.*[@intCast(function.inputs[0])] = fieldSchema(original, item);
    }
    for (original.blocks, candidate.blocks) |old, new| {
        const owner: usize = @intCast(old.function);
        const worker = original.functions[owner];
        var next: usize = 0;
        for (old.instructions) |op| {
            var expected = op;
            var operand: [1]p.Id = undefined;
            if (workers[owner] != null and
                op.opcode == .field and
                op.operands[0] == worker.inputs[0])
            {
                operand[0] = worker.inputs[0];
                expected = .{
                    .destination = op.destination,
                    .opcode = .move,
                    .operands = &operand,
                };
            }
            if (op.opcode == .computation) if (selected[@intCast(op.immediate)]) |witness| {
                const slot = next_slots[owner];
                next_slots[owner] += 1;
                if (next >= new.instructions.len) return error.InvalidCaptureProjection;
                try checkInsertion(
                    original,
                    candidate,
                    owner,
                    slot,
                    op.operands,
                    witness,
                    new.instructions[next],
                );
                next += 1;
                if (next >= new.instructions.len or !sameArguments(
                    op.operands,
                    new.instructions[next].operands,
                    slot,
                )) return error.InvalidCaptureProjection;
                expected.operands = new.instructions[next].operands;
                layouts[owner][@intCast(op.destination)] = types[@intCast(op.immediate)];
            };
            if (next >= new.instructions.len or !equal(
                ir.Instruction,
                expected,
                new.instructions[next],
            )) return error.InvalidCaptureProjection;
            next += 1;
        }
        var unchanged = new;
        unchanged.instructions = old.instructions;
        if (old.terminator == .call) if (workers[
            @intCast(old.terminator.call.function)
        ]) |witness| {
            const slot = next_slots[owner];
            next_slots[owner] += 1;
            if (next >= new.instructions.len or new.terminator != .call or !sameArguments(
                old.terminator.call.arguments,
                new.terminator.call.arguments,
                slot,
            )) return error.InvalidCaptureProjection;
            try checkInsertion(
                original,
                candidate,
                owner,
                slot,
                old.terminator.call.arguments,
                witness,
                new.instructions[next],
            );
            next += 1;
            unchanged.terminator.call.arguments = old.terminator.call.arguments;
        };
        if (next != new.instructions.len or !equal(
            ir.Block,
            old,
            unchanged,
        )) return error.InvalidCaptureProjection;
    }
    for (original.functions, candidate.functions, layouts, next_slots) |old, new, layout, count| {
        var same_function = new;
        same_function.layout = old.layout;
        if (!equal(
            ir.Function,
            old,
            same_function,
        ) or new.layout.slots.len != count or !std.mem.eql(
            p.Id,
            layout,
            new.layout.slots[0..layout.len],
        )) return error.InvalidCaptureProjection;
    }
}
fn checkInsertion(
    original: ir.Program,
    candidate: ir.Program,
    owner: usize,
    slot: usize,
    args: []const p.Id,
    witness: Witness,
    op: ir.Instruction,
) Error!void {
    if (slot >= candidate.functions[owner].layout.slots.len or
        args.len == 0 or
        candidate.functions[owner].layout.slots[slot] != fieldSchema(original, witness))
        return error.InvalidCaptureProjection;
    const expected: ir.Instruction = .{
        .destination = slot,
        .opcode = .field,
        .operands = args[0..1],
        .immediate = witness.field,
    };
    if (!equal(ir.Instruction, expected, op)) return error.InvalidCaptureProjection;
}
