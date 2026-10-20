// Copyright (c) 2026 Boundary contributors. MIT license.
//! Forward immutable product fields from available original operand versions.
//! Construction remains until independently checked dead-computation elimination.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const facts = @import("value_facts.zig");
const ownership = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
pub const Error = facts.Error || coalescing.Error || error{InvalidAggregateReduction};
pub const Witness = struct { block: usize, projection: usize, construction: usize };
pub const Statistics = struct { fields_forwarded: usize = 0, unavailable_fields: usize = 0 };

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
    var known = try facts.analyze(allocator, original);
    defer known.deinit();
    try known.requireEpoch(allocator, original);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const blocks = try a.dupe(ir.Block, original.blocks);
    var witnesses: std.ArrayList(Witness) = .empty;
    for (original.blocks, known.blocks, blocks, 0..) |block, state, *out, id| {
        const slots = original.functions[@intCast(block.function)].layout.slots;
        const versions = try a.alloc(usize, slots.len);
        for (versions, 0..) |*version, slot| version.* = slot;
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        out.instructions = instructions;
        for (block.instructions, 0..) |instruction, index| {
            defer versions[@intCast(instruction.destination)] = state.results[index];
            if (!state.reachable or instruction.opcode != .field) continue;
            var version = state.definitions[state.results[index]].operands[0];
            while (state.definitions[version].instruction) |origin| {
                const producer = block.instructions[origin];
                if (producer.opcode == .move) {
                    version = state.definitions[version].operands[0];
                    continue;
                }
                if (producer.opcode != .product or !safe(slots, producer, permissions)) break;
                const field: usize = @intCast(instruction.immediate);
                const source = producer.operands[field];
                if (versions[@intCast(source)] != state.definitions[version].operands[field]) {
                    stats.unavailable_fields += 1;
                    break;
                }
                instructions[index] = .{
                    .destination = instruction.destination,
                    .opcode = .move,
                    .operands = try a.dupe(p.Id, &.{source}),
                };
                try witnesses.append(
                    a,
                    .{ .block = id, .projection = index, .construction = origin },
                );
                break;
            }
        }
    }
    var candidate = original;
    candidate.blocks = blocks;
    try validate(allocator, original, candidate, witnesses.items);
    stats.fields_forwarded = witnesses.items.len;
    return coalescing.run(allocator, candidate, options);
}

fn safe(slots: []const p.Id, producer: ir.Instruction, permissions: traits.Facts) bool {
    const aggregate = slots[@intCast(producer.destination)];
    return producer.failures.len == 0 and permissions.copy[
        @intCast(aggregate)
    ] and permissions.drop[
        @intCast(aggregate)
    ];
}

/// Trace the raw projection operand backwards through moves and verify the
/// selected field's actual source has not been overwritten. Finder facts are
/// neither an input nor a certificate for this correspondence.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var before_flow = try ownership.analyze(allocator, original);
    defer before_flow.deinit();
    var after_flow = try ownership.analyze(allocator, candidate);
    defer after_flow.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const permissions = try traits.derive(arena.allocator(), original.schemas);
    var unchanged = candidate;
    unchanged.blocks = original.blocks;
    if (!equal(
        ir.Program,
        original,
        unchanged,
    ) or original.blocks.len != candidate.blocks.len) return error.InvalidAggregateReduction;
    for (original.blocks, candidate.blocks, 0..) |before, after, block_id| {
        if (before.instructions.len != after.instructions.len)
            return error.InvalidAggregateReduction;
        var same = after;
        same.instructions = before.instructions;
        if (!equal(ir.Block, before, same)) return error.InvalidAggregateReduction;
        const slots = original.functions[@intCast(before.function)].layout.slots;
        for (before.instructions, after.instructions, 0..) |instruction, replacement, index| {
            var witness: ?Witness = null;
            for (witnesses) |item| if (item.block == block_id and item.projection == index) {
                if (witness != null) return error.InvalidAggregateReduction;
                witness = item;
            };
            if (witness) |item| {
                if (instruction.opcode != .field or
                    item.construction >= index)
                    return error.InvalidAggregateReduction;
                var slot = instruction.operands[0];
                var cursor = index;
                var found: ?usize = null;
                while (cursor != 0) {
                    cursor -= 1;
                    const operation = before.instructions[cursor];
                    if (operation.destination != slot) continue;
                    if (operation.opcode == .move) {
                        slot = operation.operands[0];
                        continue;
                    }
                    if (operation.opcode == .product) found = cursor;
                    break;
                }
                if (found == null or
                    found.? != item.construction)
                    return error.InvalidAggregateReduction;
                const product = before.instructions[item.construction];
                if (!safe(slots, product, permissions)) return error.InvalidAggregateReduction;
                const source = product.operands[@intCast(instruction.immediate)];
                for (before.instructions[item.construction..index]) |operation|
                    if (operation.destination == source)
                        return error.InvalidAggregateReduction;
                const expected: ir.Instruction = .{
                    .destination = instruction.destination,
                    .opcode = .move,
                    .operands = &.{source},
                };
                if (!equal(
                    ir.Instruction,
                    expected,
                    replacement,
                )) return error.InvalidAggregateReduction;
            } else if (!equal(
                ir.Instruction,
                instruction,
                replacement,
            )) return error.InvalidAggregateReduction;
        }
    }
    for (witnesses) |item|
        if (item.block >= original.blocks.len or
            item.projection >= original.blocks[item.block].instructions.len)
            return error.InvalidAggregateReduction;
}
