// Copyright (c) 2026 Boundary contributors. MIT license.
//! Scalar storage for a private cell confined to a single returning block.
//! No aliases, suspension, calls or fault observations cross the cell lifetime.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const admission = @import("admission.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
pub const Error = coalescing.Error || error{InvalidCellReduction};
pub const Witness = struct { block: usize, construction: usize };
pub const Statistics = struct {
    cells_removed: usize = 0,
    reads_removed: usize = 0,
    stores_removed: usize = 0,
    retained_cells: usize = 0,
};

fn local(program: ir.Program, block_id: usize) bool {
    const block = program.blocks[block_id];
    if (block.terminator != .return_value or program.functions[
        @intCast(block.function)
    ].entry != block_id) return false;
    for (
        program.blocks,
        0..,
    ) |other, id| if (other.function == block.function and id != block_id) return false;
    return true;
}
fn privateUses(program: ir.Program, block_id: usize, construction: usize) bool {
    const block = program.blocks[block_id];
    const cell = block.instructions[construction].destination;
    const function = program.functions[@intCast(block.function)];
    if (std.mem.indexOfScalar(
        p.Id,
        function.inputs,
        cell,
    ) != null or block.terminator.return_value == cell) return false;
    for (block.instructions, 0..) |op, index| {
        if (index == construction) continue;
        if (op.destination == cell) return false;
        if (index > construction and op.failures.len != 0) return false;
        for (op.operands, 0..) |operand, position| {
            if (operand != cell) continue;
            if (index < construction or
                position != 0 or
                (op.opcode != .cell_get and
                    op.opcode != .cell_set))
                return false;
        }
    }
    return true;
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
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var witnesses: std.ArrayList(Witness) = .empty;
    for (original.blocks, 0..) |block, bid| for (block.instructions, 0..) |op, index| {
        if (op.opcode != .cell_new) continue;
        const shape = original.schemas[
            @intCast(
                original.functions[
                    @intCast(block.function)
                ].layout.slots[
                    @intCast(op.destination)
                ],
            )
        ].internal.cell;
        if (!local(original, bid) or !privateUses(original, bid, index) or !schemas.exportable[
            @intCast(shape.element)
        ] or !permissions.copy[
            @intCast(shape.element)
        ] or !permissions.drop[
            @intCast(shape.element)
        ]) {
            stats.retained_cells += 1;
            continue;
        }
        try witnesses.append(a, .{ .block = bid, .construction = index });
    };
    const functions = try a.dupe(ir.Function, original.functions);
    for (functions) |*function| function.layout.slots = try a.dupe(p.Id, function.layout.slots);
    const blocks = try a.dupe(ir.Block, original.blocks);
    var constants: std.ArrayList(p.Literal) = .empty;
    try constants.appendSlice(a, original.constants);
    for (witnesses.items) |witness| {
        const block = original.blocks[witness.block];
        const cell = block.instructions[witness.construction].destination;
        const slots = @constCast(functions[@intCast(block.function)].layout.slots);
        slots[
            @intCast(cell)
        ] = original.schemas[
            @intCast(slots[
                @intCast(cell)
            ])
        ].internal.cell.element;
    }
    for (original.blocks, blocks, 0..) |block, *out, bid| {
        var instructions: std.ArrayList(ir.Instruction) = .empty;
        for (block.instructions, 0..) |op, index| {
            var selected: ?p.Id = null;
            for (witnesses.items) |witness| {
                if (witness.block != bid) continue;
                const cell = block.instructions[witness.construction].destination;
                if (index == witness.construction or
                    ((op.opcode == .cell_get or
                        op.opcode == .cell_set) and
                        op.operands[0] == cell))
                {
                    selected = cell;
                    break;
                }
            }
            if (selected) |cell| switch (op.opcode) {
                .cell_new => try instructions.append(
                    a,
                    .{
                        .destination = cell,
                        .opcode = .move,
                        .operands = try a.dupe(p.Id, &.{op.operands[1]}),
                    },
                ),
                .cell_get => {
                    try instructions.append(
                        a,
                        .{
                            .destination = op.destination,
                            .opcode = .move,
                            .operands = try a.dupe(p.Id, &.{cell}),
                        },
                    );
                    stats.reads_removed += 1;
                },
                .cell_set => {
                    try instructions.append(
                        a,
                        .{
                            .destination = cell,
                            .opcode = .move,
                            .operands = try a.dupe(p.Id, &.{op.operands[1]}),
                        },
                    );
                    const schema = original.functions[
                        @intCast(block.function)
                    ].layout.slots[
                        @intCast(op.destination)
                    ];
                    var literal: ?p.Id = null;
                    for (
                        constants.items,
                        0..,
                    ) |value, id| if (value.schema == schema and value.bytes.len == 0) {
                        literal = id;
                        break;
                    };
                    if (literal == null) {
                        literal = constants.items.len;
                        try constants.append(a, .{ .schema = schema, .bytes = &.{} });
                    }
                    try instructions.append(
                        a,
                        .{
                            .destination = op.destination,
                            .opcode = .constant,
                            .immediate = literal.?,
                        },
                    );
                    stats.stores_removed += 1;
                },
                else => unreachable,
            } else try instructions.append(a, op);
        }
        out.instructions = try instructions.toOwnedSlice(a);
    }
    var candidate = original;
    candidate.functions = functions;
    candidate.blocks = blocks;
    candidate.constants = constants.items;
    try validate(allocator, original, candidate, witnesses.items);
    stats.cells_removed = witnesses.items.len;
    return coalescing.run(allocator, candidate, options);
}

/// Independently match every original read/write to its scalar state transition.
/// Each changed local slot holds exactly the cell's previous payload at each
/// corresponding point; extra unit results have no effects or failure behavior.
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
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    unchanged.constants = original.constants;
    if (!equal(ir.Program, original, unchanged) or
        original.functions.len != candidate.functions.len or
        original.blocks.len != candidate.blocks.len or
        candidate.constants.len < original.constants.len)
        return error.InvalidCellReduction;
    for (
        original.constants,
        candidate.constants[0..original.constants.len],
    ) |before, after| if (!equal(p.Literal, before, after)) return error.InvalidCellReduction;
    for (candidate.constants[original.constants.len..]) |value| if (original.schemas[
        @intCast(value.schema)
    ] != .unit or value.bytes.len != 0) return error.InvalidCellReduction;
    const selected = try a.alloc([]bool, original.functions.len);
    for (original.functions, selected) |function, *slots| {
        slots.* = try a.alloc(bool, function.layout.slots.len);
        @memset(slots.*, false);
    }
    for (witnesses) |witness| {
        if (witness.block >= original.blocks.len) return error.InvalidCellReduction;
        const block = original.blocks[witness.block];
        if (witness.construction >= block.instructions.len or !local(
            original,
            witness.block,
        )) return error.InvalidCellReduction;
        const allocation = block.instructions[witness.construction];
        if (allocation.opcode != .cell_new or selected[
            @intCast(block.function)
        ][
            @intCast(allocation.destination)
        ]) return error.InvalidCellReduction;
        const function = original.functions[@intCast(block.function)];
        const cell = allocation.destination;
        const shape = original.schemas[
            @intCast(function.layout.slots[
                @intCast(cell)
            ])
        ].internal.cell;
        if (!schemas.exportable[
            @intCast(shape.element)
        ] or !permissions.copy[
            @intCast(shape.element)
        ] or !permissions.drop[
            @intCast(shape.element)
        ] or std.mem.indexOfScalar(
            p.Id,
            function.inputs,
            cell,
        ) != null or block.terminator.return_value == cell) return error.InvalidCellReduction;
        // Census independently of the finder's privateUses decision.
        for (block.instructions, 0..) |op, index| {
            if (index > witness.construction and
                op.failures.len != 0)
                return error.InvalidCellReduction;
            if (index != witness.construction and
                op.destination == cell)
                return error.InvalidCellReduction;
            for (op.operands, 0..) |operand, position|
                if (operand == cell) {
                    if (index <= witness.construction or
                        position != 0 or
                        (op.opcode != .cell_get and
                            op.opcode != .cell_set))
                        return error.InvalidCellReduction;
                };
        }
        selected[@intCast(block.function)][@intCast(cell)] = true;
    }
    for (original.functions, candidate.functions, selected) |before, after, slots| {
        if (before.layout.slots.len != after.layout.slots.len) return error.InvalidCellReduction;
        var same = after;
        same.layout = before.layout;
        if (!equal(ir.Function, before, same)) return error.InvalidCellReduction;
        for (before.layout.slots, after.layout.slots, slots) |old, new, changed| {
            if (new != (if (changed) original.schemas[
                @intCast(old)
            ].internal.cell.element else old)) return error.InvalidCellReduction;
        }
    }
    for (original.blocks, candidate.blocks) |before, after| {
        var same = after;
        same.instructions = before.instructions;
        if (!equal(ir.Block, before, same)) return error.InvalidCellReduction;
        const slots = selected[@intCast(before.function)];
        var next: usize = 0;
        for (before.instructions) |op| {
            if (next >= after.instructions.len) return error.InvalidCellReduction;
            var expected = op;
            var source: [1]p.Id = undefined;
            if (op.opcode == .cell_new and slots[@intCast(op.destination)]) {
                source[0] = op.operands[1];
                expected = .{ .destination = op.destination, .opcode = .move, .operands = &source };
            } else if ((op.opcode == .cell_get or op.opcode == .cell_set) and slots[
                @intCast(op.operands[0])
            ]) {
                const cell = op.operands[0];
                source[0] = if (op.opcode == .cell_get) cell else op.operands[1];
                expected = .{
                    .destination = if (op.opcode == .cell_get) op.destination else cell,
                    .opcode = .move,
                    .operands = &source,
                };
                if (op.opcode == .cell_set) {
                    if (!equal(
                        ir.Instruction,
                        expected,
                        after.instructions[next],
                    )) return error.InvalidCellReduction;
                    next += 1;
                    if (next >= after.instructions.len) return error.InvalidCellReduction;
                    const unit = after.instructions[next];
                    if (unit.opcode != .constant or
                        unit.immediate >= candidate.constants.len)
                        return error.InvalidCellReduction;
                    const literal = candidate.constants[@intCast(unit.immediate)];
                    if (literal.schema != original.functions[
                        @intCast(before.function)
                    ].layout.slots[
                        @intCast(op.destination)
                    ] or literal.bytes.len != 0) return error.InvalidCellReduction;
                    expected = .{
                        .destination = op.destination,
                        .opcode = .constant,
                        .immediate = unit.immediate,
                    };
                }
            }
            if (!equal(
                ir.Instruction,
                expected,
                after.instructions[next],
            )) return error.InvalidCellReduction;
            next += 1;
        }
        if (next != after.instructions.len) return error.InvalidCellReduction;
    }
}
