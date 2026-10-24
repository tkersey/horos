// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independent admission of token-free, total branching clauses.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const a = @import("admission.zig");
const traits = @import("traits.zig");

pub fn instruction(operation: ir.Instruction) bool {
    if (operation.failures.len != 0) return false;
    return switch (operation.opcode) {
        .constant,
        .move,
        .equal,
        .less,
        .boolean_not,
        .product,
        .field,
        .variant,
        .variant_tag,
        .sequence,
        .sequence_length,
        .sequence_get,
        .sequence_append,
        .sequence_concat,
        .sequence_pop,
        .integer_bit_not,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .integer_convert,
        .enum_tag,
        .blob_length,
        .blob_compare,
        .blob_byte,
        .text_integer,
        .blob_from_byte,
        .sequence_take,
        .sequence_pop_last,
        .select,
        => true,
        // Existing local cell operations neither suspend nor have authored
        // failures. Type/region/borrow admission still checks their authority.
        .cell_get, .cell_set => true,
        else => false,
    };
}

const Visit = struct { id: p.Id, leave: bool = false };

/// Every reachable path terminates in an ordinary return. The explicit DFS
/// stack is bounded by CFG edges; each node is checked once, without recursion.
pub fn validateWithWork(
    allocator: std.mem.Allocator,
    image: ir.Program,
    id: p.Id,
    uses: traits.Facts,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const function = image.functions[@intCast(id)];
    for (function.layout.slots) |schema| {
        try a.spend(work, 1);
        if (!uses.copy[@intCast(schema)])
            return error.InvalidOwnership;
    }
    var states: std.AutoHashMapUnmanaged(p.Id, bool) = .empty;
    defer states.deinit(allocator);
    var pending: std.ArrayList(Visit) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, .{ .id = function.entry });
    while (pending.pop()) |visit| {
        try a.spend(work, 1);
        if (visit.leave) {
            states.getPtr(visit.id).?.* = true;
            continue;
        }
        if (states.get(visit.id)) |done| {
            if (!done) return error.InvalidProgram;
            continue;
        }
        try states.put(allocator, visit.id, false);
        const block = image.blocks[@intCast(visit.id)];
        if (block.function != id) return error.InvalidReference;
        for (block.instructions) |operation| {
            try a.spend(work, 1);
            if (!instruction(operation))
                return error.InvalidProgram;
        }
        try pending.append(allocator, .{ .id = visit.id, .leave = true });
        switch (block.terminator) {
            .return_value => {},
            .jump => |edge| try push(allocator, &pending, edge, work),
            .branch => |v| {
                try push(allocator, &pending, v.when_false, work);
                try push(allocator, &pending, v.when_true, work);
            },
            .switch_variant => |v| for (v.cases) |edge| {
                try a.spend(work, 1);
                try push(allocator, &pending, edge, work);
            },
            .unpack_product => |v| try push(allocator, &pending, v.next, work),
            else => return error.InvalidProgram,
        }
    }
}

fn push(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(Visit),
    edge: ir.Edge,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    for (edge.assignments) |assignment| {
        try a.spend(work, 1);
        if (assignment.source == .returned)
            return error.InvalidProgram;
    }
    try pending.append(allocator, .{ .id = edge.block });
}

test "tail clause wire tag is explicit and rejects the predecessor flag" {
    const wire = @import("wire.zig");
    const records = @import("program_record.zig");
    var bytes: [4]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    var context: records.Context = .{};
    try records.write(
        ir.Clause,
        .{ .effect = 3, .function = 4, .resumption = 5, .strategy = .tail },
        &writer,
        &context,
    );
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 5, 2 }, &bytes);
    var budget: records.Budget = .{ .maximum = 1024 };
    var reader: wire.Reader = .{ .input = &bytes };
    const decoded = try records.read(ir.Clause, &reader, std.testing.allocator, &budget, &context);
    try std.testing.expect(decoded.strategy == .tail);
    bytes[3] = 1;
    reader.position = 0;
    try std.testing.expectError(
        error.InvalidTag,
        records.read(ir.Clause, &reader, std.testing.allocator, &budget, &context),
    );
}

pub fn validate(
    allocator: std.mem.Allocator,
    image: ir.Program,
    id: p.Id,
    uses: traits.Facts,
) a.Error!void {
    return validateWithWork(allocator, image, id, uses, null);
}
