// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independent backwards proof over actual definitions and predecessor edges.
//! Disagreeing/unknown joins and cycles cannot certify a constant. Private entry
//! proofs reconstruct every raw direct caller without consuming forward facts.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const contexts = @import("call_contexts.zig");
pub const Constant = union(enum) { boolean: bool, unsigned: u64, constructor: p.Id, variant: p.Id };
const Query = struct { block: usize, before: usize, slot: p.Id };
pub const Prover = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    active: std.ArrayList(Query) = .empty,
    exhausted: bool = false,
    // A conservative proof bound prevents valid deep graphs from exhausting
    // the native call stack. Failure to prove is not proof of impossibility.
    max_depth: usize = 256,
    work_limit: u64 = 1_000_000,
    work: u64 = 0,
    fn tick(self: *Prover) bool {
        if (self.work >= self.work_limit) {
            self.exhausted = true;
            return false;
        }
        self.work += 1;
        return true;
    }
    pub fn deinit(self: *Prover) void {
        self.active.deinit(self.allocator);
    }
    pub fn resolve(
        self: *Prover,
        block: usize,
        before: usize,
        slot: p.Id,
    ) std.mem.Allocator.Error!?Constant {
        if (self.exhausted or !self.tick()) return null;
        if (self.active.items.len >= self.max_depth) {
            self.exhausted = true;
            return null;
        }
        const query: Query = .{ .block = block, .before = before, .slot = slot };
        for (self.active.items) |old| {
            if (!self.tick()) return null;
            if (std.meta.eql(old, query)) return null;
        }
        try self.active.append(self.allocator, query);
        defer _ = self.active.pop();
        const source = self.program.blocks[block];
        var index = before;
        while (index != 0) {
            if (!self.tick()) return null;
            index -= 1;
            const instruction = source.instructions[index];
            if (instruction.destination != slot) continue;
            return switch (instruction.opcode) {
                .constant => blk: {
                    const value = self.program.constants[@intCast(instruction.immediate)];
                    break :blk switch (self.program.schemas[@intCast(value.schema)]) {
                        .boolean => .{ .boolean = value.bytes[0] == 1 },
                        .u8 => .{ .unsigned = value.bytes[0] },
                        .u16 => .{ .unsigned = std.mem.readInt(u16, value.bytes[0..2], .little) },
                        .u32 => .{ .unsigned = std.mem.readInt(u32, value.bytes[0..4], .little) },
                        .u64 => .{ .unsigned = std.mem.readInt(u64, value.bytes[0..8], .little) },
                        else => null,
                    };
                },
                .computation => .{ .constructor = instruction.immediate },
                .variant => .{ .variant = instruction.immediate },
                .variant_tag => blk: {
                    const value = (try self.resolve(
                        block,
                        index,
                        instruction.operands[0],
                    )) orelse break :blk null;
                    if (value != .variant) break :blk null;
                    break :blk .{ .unsigned = value.variant };
                },
                .move => self.resolve(block, index, instruction.operands[0]),
                .boolean_not => blk: {
                    const value = (try self.resolve(
                        block,
                        index,
                        instruction.operands[0],
                    )) orelse break :blk null;
                    if (value != .boolean) break :blk null;
                    break :blk .{ .boolean = !value.boolean };
                },
                .equal, .less, .integer_bit_and => blk: {
                    const left = try self.resolve(block, index, instruction.operands[0]);
                    const right = try self.resolve(block, index, instruction.operands[1]);
                    if (self.exhausted) break :blk null;
                    // These proofs describe the successful result only. The
                    // branch rewrite retains both operand evaluations and the
                    // primitive, including any preceding failure or effect.
                    if (instruction.opcode == .integer_bit_and) {
                        if ((left != null and left.? == .unsigned and left.?.unsigned == 0) or
                            (right != null and right.? == .unsigned and right.?.unsigned == 0))
                            break :blk .{ .unsigned = 0 };
                    }
                    const l = left orelse break :blk null;
                    const r = right orelse break :blk null;
                    if (l == .unsigned and r == .unsigned) break :blk switch (instruction.opcode) {
                        .equal => .{ .boolean = l.unsigned == r.unsigned },
                        .less => .{ .boolean = l.unsigned < r.unsigned },
                        .integer_bit_and => .{ .unsigned = l.unsigned & r.unsigned },
                        else => unreachable,
                    };
                    if (instruction.opcode == .equal and l == .boolean and r == .boolean)
                        break :blk .{ .boolean = l.boolean == r.boolean };
                    break :blk null;
                },
                else => null,
            };
        }
        var incoming: Incoming = .{ .prover = self, .target = block, .slot = slot };
        const function = self.program.functions[@intCast(source.function)];
        if (function.entry == block) {
            if (contexts.unknownEntry(self.program, source.function)) return null;
            const parameter = std.mem.indexOfScalar(p.Id, function.inputs, slot) orelse return null;
            // Reconstruct every raw caller independently of forward facts.
            // A disagreeing, unknown or cyclic caller invalidates the proof.
            for (self.program.blocks, 0..) |caller, id| {
                if (!self.tick()) return null;
                if (caller.terminator != .call or
                    caller.terminator.call.function != source.function)
                    continue;
                incoming.merge(try self.resolve(
                    id,
                    caller.instructions.len,
                    caller.terminator.call.arguments[parameter],
                ));
            }
        }
        for (self.program.blocks, 0..) |predecessor, id| {
            if (!self.tick()) return null;
            if (predecessor.function != source.function) continue;
            switch (predecessor.terminator) {
                .return_value, .fail => {},
                .jump, .yield_value => |next| try incoming.edge(id, next, &.{}),
                .branch => |branch| {
                    if (branch.when_true.block != block and
                        branch.when_false.block != block)
                        continue;
                    const condition = try self.resolve(
                        id,
                        predecessor.instructions.len,
                        branch.condition,
                    );
                    if (condition != null and condition.? == .boolean) {
                        try incoming.edge(
                            id,
                            if (condition.?.boolean) branch.when_true else branch.when_false,
                            &.{},
                        );
                    } else {
                        try incoming.edge(id, branch.when_true, &.{});
                        try incoming.edge(id, branch.when_false, &.{});
                    }
                },
                .switch_variant => |branch| {
                    var targets_query = false;
                    for (branch.cases) |next| {
                        if (!self.tick()) return null;
                        if (next.block == block) {
                            targets_query = true;
                            break;
                        }
                    }
                    if (!targets_query) continue;
                    const value = try self.resolve(id, predecessor.instructions.len, branch.value);
                    if (value != null and value.? == .variant) {
                        try incoming.edge(id, branch.cases[@intCast(value.?.variant)], &.{});
                    } else for (branch.cases) |next| try incoming.edge(id, next, &.{});
                },
                .unpack_product => |value| try incoming.edge(id, value.next, value.destinations),
                inline else => |value| try incoming.edge(id, value.next, &.{}),
            }
        }
        return if (!self.exhausted and incoming.count != 0) incoming.value else null;
    }
};
const Incoming = struct {
    prover: *Prover,
    target: usize,
    slot: p.Id,
    count: usize = 0,
    value: ?Constant = null,
    fn merge(self: *Incoming, value: ?Constant) void {
        if (self.count == 0) self.value = value else if (!std.meta.eql(
            self.value,
            value,
        )) self.value = null;
        self.count += 1;
    }
    fn edge(
        self: *Incoming,
        predecessor: usize,
        next: ir.Edge,
        overwritten: []const p.Id,
    ) std.mem.Allocator.Error!void {
        if (!self.prover.tick()) {
            self.merge(null);
            return;
        }
        if (next.block != self.target) return;
        var origin = self.slot;
        for (next.assignments) |assignment| {
            if (!self.prover.tick()) {
                self.merge(null);
                return;
            }
            if (assignment.destination == self.slot) {
                if (assignment.source == .returned) {
                    self.merge(null);
                    return;
                }
                origin = assignment.source.slot;
            }
        }
        if (std.mem.indexOfScalar(p.Id, overwritten, origin) != null) {
            self.merge(null);
            return;
        }
        // Resolve the source in the predecessor view, not the updated target.
        self.merge(try self.prover.resolve(
            predecessor,
            self.prover.program.blocks[predecessor].instructions.len,
            origin,
        ));
    }
};
