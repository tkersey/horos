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
const Phase = enum {
    scan,
    callers,
    caller_result,
    predecessors,
    branch_result,
    variant_result,
    edges,
    edge_result,
    unary,
    binary_left,
    binary_right,
};
const Frame = struct {
    query: Query,
    phase: Phase = .scan,
    index: usize = 0,
    edge_index: usize = 0,
    selected_edge: ?usize = null,
    parameter: usize = 0,
    instruction: ir.Instruction = undefined,
    left: ?Constant = null,
    count: usize = 0,
    value: ?Constant = null,
    fn merge(self: *Frame, value: ?Constant) void {
        if (self.count == 0) self.value = value else if (!std.meta.eql(
            self.value,
            value,
        )) self.value = null;
        self.count += 1;
    }
};
pub const Prover = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    active: std.ArrayList(Frame) = .empty,
    exhausted: bool = false,
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
    fn push(self: *Prover, query: Query, result: *?Constant) std.mem.Allocator.Error!void {
        result.* = null;
        if (self.exhausted or !self.tick()) return;
        if (self.active.items.len >= self.max_depth) {
            self.exhausted = true;
            return;
        }
        for (self.active.items) |old| {
            if (!self.tick()) return;
            if (std.meta.eql(old.query, query)) return;
        }
        try self.active.append(self.allocator, .{ .query = query });
    }
    fn finish(self: *Prover, value: ?Constant, result: *?Constant) void {
        _ = self.active.pop();
        result.* = value;
    }
    pub fn resolve(
        self: *Prover,
        block: usize,
        before: usize,
        slot: p.Id,
    ) std.mem.Allocator.Error!?Constant {
        const base = self.active.items.len;
        defer self.active.shrinkRetainingCapacity(base);
        var result: ?Constant = null;
        try self.push(.{ .block = block, .before = before, .slot = slot }, &result);
        while (self.active.items.len > base) {
            const frame = &self.active.items[self.active.items.len - 1];
            switch (frame.phase) {
                .scan => try self.scan(frame, &result),
                .callers => try self.callers(frame, &result),
                .caller_result => {
                    frame.merge(result);
                    frame.phase = .callers;
                },
                .predecessors => try self.predecessors(frame, &result),
                .branch_result, .variant_result => self.selectEdges(frame, result),
                .edges => try self.edges(frame, &result),
                .edge_result => {
                    frame.merge(result);
                    frame.phase = .edges;
                },
                .unary => self.finish(unary(frame.instruction.opcode, result), &result),
                .binary_left => {
                    frame.left = result;
                    frame.phase = .binary_right;
                    try self.operand(frame, 1, &result);
                },
                .binary_right => self.finish(if (self.exhausted) null else binary(
                    frame.instruction.opcode,
                    frame.left,
                    result,
                ), &result),
            }
        }
        return result;
    }
    fn operand(
        self: *Prover,
        frame: *const Frame,
        index: usize,
        result: *?Constant,
    ) std.mem.Allocator.Error!void {
        try self.push(.{
            .block = frame.query.block,
            .before = frame.index,
            .slot = frame.instruction.operands[index],
        }, result);
    }
    fn scan(self: *Prover, frame: *Frame, result: *?Constant) std.mem.Allocator.Error!void {
        const source = self.program.blocks[frame.query.block];
        var index = frame.query.before;
        while (index != 0) {
            if (!self.tick()) return self.finish(null, result);
            index -= 1;
            const instruction = source.instructions[index];
            if (instruction.destination != frame.query.slot) continue;
            frame.instruction = instruction;
            frame.index = index;
            switch (instruction.opcode) {
                .constant => self.finish(self.constant(instruction.immediate), result),
                .computation => self.finish(.{ .constructor = instruction.immediate }, result),
                .variant => self.finish(.{ .variant = instruction.immediate }, result),
                .variant_tag, .move, .boolean_not => {
                    frame.phase = .unary;
                    try self.operand(frame, 0, result);
                },
                .equal, .less, .integer_bit_and => {
                    frame.phase = .binary_left;
                    try self.operand(frame, 0, result);
                },
                else => self.finish(null, result),
            }
            return;
        }
        frame.index = 0;
        frame.phase = .predecessors;
        const function = self.program.functions[@intCast(source.function)];
        if (function.entry == frame.query.block) {
            if (contexts.unknownEntry(self.program, source.function))
                return self.finish(null, result);
            frame.parameter = std.mem.indexOfScalar(
                p.Id,
                function.inputs,
                frame.query.slot,
            ) orelse return self.finish(null, result);
            frame.phase = .callers;
        }
    }
    fn constant(self: *Prover, id: p.Id) ?Constant {
        const value = self.program.constants[@intCast(id)];
        return switch (self.program.schemas[@intCast(value.schema)]) {
            .boolean => .{ .boolean = value.bytes[0] == 1 },
            .u8 => .{ .unsigned = value.bytes[0] },
            .u16 => .{ .unsigned = std.mem.readInt(u16, value.bytes[0..2], .little) },
            .u32 => .{ .unsigned = std.mem.readInt(u32, value.bytes[0..4], .little) },
            .u64 => .{ .unsigned = std.mem.readInt(u64, value.bytes[0..8], .little) },
            else => null,
        };
    }
    fn callers(self: *Prover, frame: *Frame, result: *?Constant) std.mem.Allocator.Error!void {
        const function = self.program.blocks[frame.query.block].function;
        while (frame.index < self.program.blocks.len) {
            if (!self.tick()) return self.finish(null, result);
            const id = frame.index;
            frame.index += 1;
            const caller = self.program.blocks[id];
            if (caller.terminator != .call or caller.terminator.call.function != function) continue;
            frame.phase = .caller_result;
            try self.push(.{
                .block = id,
                .before = caller.instructions.len,
                .slot = caller.terminator.call.arguments[frame.parameter],
            }, result);
            return;
        }
        frame.index = 0;
        frame.phase = .predecessors;
    }
    fn predecessors(self: *Prover, frame: *Frame, result: *?Constant) std.mem.Allocator.Error!void {
        const function = self.program.blocks[frame.query.block].function;
        while (frame.index < self.program.blocks.len) {
            if (!self.tick()) return self.finish(null, result);
            const id = frame.index;
            frame.index += 1;
            const source = self.program.blocks[id];
            if (source.function != function) continue;
            frame.edge_index = 0;
            frame.selected_edge = null;
            frame.phase = .edges;
            switch (source.terminator) {
                .return_value, .fail => continue,
                .branch => |branch| {
                    if (branch.when_true.block != frame.query.block and
                        branch.when_false.block != frame.query.block) continue;
                    frame.phase = .branch_result;
                    try self.push(.{
                        .block = id,
                        .before = source.instructions.len,
                        .slot = branch.condition,
                    }, result);
                },
                .switch_variant => |branch| {
                    var targets_query = false;
                    for (branch.cases) |next| {
                        if (!self.tick()) return self.finish(null, result);
                        if (next.block == frame.query.block) {
                            targets_query = true;
                            break;
                        }
                    }
                    if (!targets_query) continue;
                    frame.phase = .variant_result;
                    try self.push(.{
                        .block = id,
                        .before = source.instructions.len,
                        .slot = branch.value,
                    }, result);
                },
                else => {},
            }
            return;
        }
        self.finish(if (!self.exhausted and frame.count != 0) frame.value else null, result);
    }
    fn selectEdges(_: *Prover, frame: *Frame, result: ?Constant) void {
        if (result) |value| {
            if (frame.phase == .branch_result and value == .boolean)
                frame.selected_edge = if (value.boolean) 0 else 1;
            if (frame.phase == .variant_result and value == .variant)
                frame.selected_edge = @intCast(value.variant);
        }
        frame.phase = .edges;
    }
    fn edges(self: *Prover, frame: *Frame, result: *?Constant) std.mem.Allocator.Error!void {
        const id = frame.index - 1;
        const source = self.program.blocks[id];
        const next = nextEdge(frame, source.terminator) orelse {
            frame.phase = .predecessors;
            return;
        };
        if (!self.tick()) {
            frame.merge(null);
            return;
        }
        if (next.block != frame.query.block) return;
        var origin = frame.query.slot;
        for (next.assignments) |assignment| {
            if (!self.tick()) {
                frame.merge(null);
                return;
            }
            if (assignment.destination == frame.query.slot) {
                if (assignment.source == .returned) {
                    frame.merge(null);
                    return;
                }
                origin = assignment.source.slot;
            }
        }
        if (source.terminator == .unpack_product and std.mem.indexOfScalar(
            p.Id,
            source.terminator.unpack_product.destinations,
            origin,
        ) != null) {
            frame.merge(null);
            return;
        }
        frame.phase = .edge_result;
        try self.push(.{ .block = id, .before = source.instructions.len, .slot = origin }, result);
    }
};
fn nextEdge(frame: *Frame, terminator: ir.Terminator) ?ir.Edge {
    const index = frame.edge_index;
    frame.edge_index += 1;
    if (frame.selected_edge != null and index != 0) return null;
    const selected = frame.selected_edge orelse index;
    return switch (terminator) {
        .return_value, .fail => null,
        .jump, .yield_value => |next| if (index == 0) next else null,
        .branch => |branch| switch (selected) {
            0 => branch.when_true,
            1 => branch.when_false,
            else => null,
        },
        .switch_variant => |branch| if (selected < branch.cases.len)
            branch.cases[selected]
        else
            null,
        inline else => |value| if (index == 0) value.next else null,
    };
}
fn unary(opcode: p.Opcode, result: ?Constant) ?Constant {
    const value = result orelse return null;
    return switch (opcode) {
        .move => value,
        .variant_tag => if (value == .variant) .{ .unsigned = value.variant } else null,
        .boolean_not => if (value == .boolean) .{ .boolean = !value.boolean } else null,
        else => unreachable,
    };
}
fn binary(opcode: p.Opcode, left: ?Constant, right: ?Constant) ?Constant {
    // These proofs describe the successful result only. The
    // branch rewrite retains both operand evaluations and the
    // primitive, including any preceding failure or effect.
    if (opcode == .integer_bit_and) {
        if ((left != null and left.? == .unsigned and left.?.unsigned == 0) or
            (right != null and right.? == .unsigned and right.?.unsigned == 0))
            return .{ .unsigned = 0 };
    }
    const l = left orelse return null;
    const r = right orelse return null;
    if (l == .unsigned and r == .unsigned) return switch (opcode) {
        .equal => .{ .boolean = l.unsigned == r.unsigned },
        .less => .{ .boolean = l.unsigned < r.unsigned },
        .integer_bit_and => .{ .unsigned = l.unsigned & r.unsigned },
        else => unreachable,
    };
    if (opcode == .equal and l == .boolean and r == .boolean)
        return .{ .boolean = l.boolean == r.boolean };
    return null;
}

test "constant proof frames preserve depth admission and exact work accounting" {
    var instructions: [512]ir.Instruction = @splat(.{
        .destination = 0,
        .opcode = .move,
        .operands = &.{0},
    });
    instructions[0] = .{ .destination = 0, .opcode = .constant };
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u8, .unit },
        .constants = &.{.{ .schema = 0, .bytes = &.{42} }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &instructions,
            .terminator = .{ .return_value = 0 },
        }},
    };
    var bounded: Prover = .{ .allocator = std.testing.allocator, .program = program };
    defer bounded.deinit();
    try std.testing.expectEqual(@as(?Constant, null), try bounded.resolve(0, instructions.len, 0));
    try std.testing.expect(bounded.exhausted);
    try std.testing.expectEqual(@as(usize, 0), bounded.active.items.len);
    var expanded: Prover = .{
        .allocator = std.testing.allocator,
        .program = program,
        .max_depth = instructions.len,
    };
    defer expanded.deinit();
    try std.testing.expectEqual(Constant{ .unsigned = 42 }, (try expanded.resolve(
        0,
        instructions.len,
        0,
    )).?);
    try std.testing.expect(!expanded.exhausted);
    try std.testing.expectEqual(@as(u64, 512 * 515 / 2), expanded.work);
    try std.testing.expectEqual(@as(usize, 0), expanded.active.items.len);
}
