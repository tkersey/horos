// Copyright (c) 2026 Boundary contributors. MIT license.
//! P14 call-by-name eta law. A same-schema wrapper that only forces and returns
//! its captured thunk can be replaced by that thunk without moving any demand.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidThunkForwarding, ThunkForwardingLimit };
pub const Options = struct { work_limit: usize = 10_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct { wrappers_removed: usize = 0, work_limit: bool = false };
const Budget = struct {
    left: usize,
    fn tick(self: *@This()) Error!void {
        if (self.left == 0) return error.ThunkForwardingLimit;
        self.left -= 1;
    }
    fn record(self: *@This(), comptime T: type, value: T) Error!void {
        try self.tick();
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| try self.record(FieldType, @field(value, field_name)),
            .@"union" => switch (value) {
                inline else => |v| try self.record(@TypeOf(v), v),
            },
            .optional => |info| if (value) |v| {
                try self.record(info.child, v);
            },
            .pointer => |info| for (value) |v| try self.record(info.child, v),
            else => {},
        }
    }
};
fn forwarding(
    program: ir.Program,
    id: p.Id,
    permissions: traits.Facts,
    budget: *Budget,
) Error!bool {
    try budget.tick();
    const constructor = program.constructors[@intCast(id)];
    const capture = program.scopes.captures[@intCast(constructor.capture)];
    if (capture.fields.len != 1 or
        capture.fields[0] != constructor.schema or
        capture.use != .reusable or
        capture.owned_regions.len != 0 or
        capture.borrowed_regions.len != 0)
        return false;
    const signature = program.schemas[@intCast(constructor.schema)].internal.computation;
    if (signature.parameters.len != 0 or
        signature.use != .reusable or
        signature.regions.len != 0 or
        signature.effects.len != 0)
        return false;
    if (!permissions.copy[
        @intCast(constructor.schema)
    ] or !permissions.drop[
        @intCast(constructor.schema)
    ] or !permissions.copy[
        @intCast(signature.result)
    ] or !permissions.drop[
        @intCast(signature.result)
    ]) return false;
    const function = program.functions[@intCast(constructor.function)];
    if (function.inputs.len != 1 or
        function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1)
        return false;
    const entry = program.blocks[@intCast(function.entry)];
    if (entry.custody != 0 or
        entry.instructions.len != 0 or
        entry.terminator != .apply)
        return false;
    const apply = entry.terminator.apply;
    if (apply.computation != function.inputs[0] or
        apply.arguments.len != 0 or
        apply.next.assignments.len != 1 or
        apply.next.assignments[0].source != .returned or
        apply.next.block == function.entry)
        return false;
    const returned = program.blocks[@intCast(apply.next.block)];
    if (returned.function != constructor.function or
        returned.custody != 0 or
        returned.instructions.len != 0 or
        returned.terminator != .return_value or
        returned.terminator.return_value != apply.next.assignments[0].destination)
        return false;
    for (program.blocks, 0..) |block, bid| {
        try budget.tick();
        if (block.function == constructor.function and
            bid != function.entry and
            bid != apply.next.block)
            return false;
    }
    return true;
}
pub const Site = struct { block: usize, instruction: usize };
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    sites: []const Site,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var admitted = try own.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: Budget = .{ .left = options.work_limit };
    try budget.record(ir.Program, original);
    const permissions = try traits.derive(a, original.schemas);
    const eligible = try a.alloc(bool, original.constructors.len);
    for (eligible, 0..) |*yes, id| yes.* = try forwarding(original, id, permissions, &budget);
    const blocks = try a.dupe(ir.Block, original.blocks);
    var sites: std.ArrayList(Site) = .empty;
    for (blocks, 0..) |*block, bid| {
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        var count = instructions.len;
        for (instructions, 0..) |*op, position| {
            try budget.tick();
            if (op.opcode != .computation or !eligible[@intCast(op.immediate)]) continue;
            try sites.append(a, .{ .block = bid, .instruction = position });
            // There is no intervening operation or write on this edge. Returning
            // the captured value directly also avoids an inlining temporary.
            if (position + 1 == instructions.len and
                block.terminator == .return_value and
                block.terminator.return_value == op.destination)
            {
                block.terminator.return_value = op.operands[0];
                count -= 1;
            } else {
                op.opcode = .move;
                op.immediate = 0;
            }
        }
        block.instructions = instructions[0..count];
    }
    if (sites.items.len == 0) return null;
    var program = original;
    program.blocks = blocks;
    const selected = try sites.toOwnedSlice(a);
    keep = true;
    return .{ .arena = arena, .program = program, .sites = selected };
}
/// Original function bodies prove the eta law; every actual changed instruction
/// must copy the exact captured value. No construction maps or discovery flags.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var budget: Budget = .{ .left = options.work_limit };
    try budget.record(ir.Program, original);
    try budget.record(ir.Program, candidate);
    if (original.blocks.len != candidate.blocks.len) return error.InvalidThunkForwarding;
    var rest = candidate;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidThunkForwarding;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const permissions = try traits.derive(arena.allocator(), original.schemas);
    var changed: usize = 0;
    for (original.blocks, candidate.blocks) |old, new| {
        if (old.function != new.function or
            old.custody != new.custody)
            return error.InvalidThunkForwarding;
        if (old.instructions.len != new.instructions.len) {
            if (old.instructions.len != new.instructions.len + 1 or
                old.terminator != .return_value or
                new.terminator != .return_value)
                return error.InvalidThunkForwarding;
            const last = old.instructions[old.instructions.len - 1];
            if (last.opcode != .computation or
                last.destination != old.terminator.return_value or
                !try forwarding(original, last.immediate, permissions, &budget) or
                new.terminator.return_value != last.operands[0])
                return error.InvalidThunkForwarding;
            changed += 1;
        } else if (!equal(
            ir.Terminator,
            old.terminator,
            new.terminator,
        )) return error.InvalidThunkForwarding;
        for (old.instructions[0..new.instructions.len], new.instructions) |before_op, after_op| {
            try budget.tick();
            if (equal(ir.Instruction, before_op, after_op)) continue;
            if (before_op.opcode != .computation or
                after_op.opcode != .move or
                after_op.immediate != 0 or
                !try forwarding(original, before_op.immediate, permissions, &budget))
                return error.InvalidThunkForwarding;
            var restored = after_op;
            restored.opcode = .computation;
            restored.immediate = before_op.immediate;
            if (!equal(ir.Instruction, before_op, restored)) return error.InvalidThunkForwarding;
            changed += 1;
        }
    }
    if (changed == 0) return error.InvalidThunkForwarding;
}
pub fn possible(program: ir.Program) bool {
    for (program.constructors) |constructor| {
        const capture = program.scopes.captures[@intCast(constructor.capture)];
        if (capture.fields.len == 1 and
            capture.fields[0] == constructor.schema and
            capture.use == .reusable)
            return true;
    }
    return false;
}
pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!p01.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var candidate = (construct(allocator, original, options) catch |err| switch (err) {
        error.ThunkForwardingLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validate(allocator, original, candidate.program, options) catch |err| switch (err) {
        error.ThunkForwardingLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.wrappers_removed = candidate.sites.len;
    return result;
}
