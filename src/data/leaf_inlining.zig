// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked substitution of bounded pure leaf bodies into private call sites.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const privacy = @import("capture_reduction.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
const image = @import("program_image.zig");
pub const Error = p01.Error || error{ InvalidLeafInlining, InlineLimit };
pub const Options = struct {
    work_limit: usize = 1_000_000,
    max_sites: usize = 32,
    max_instructions: usize = 8,
    max_added_bytes: usize = 4096,
    coalescing: p01.Options = .{},
};
pub const Statistics = struct {
    calls_removed: usize = 0,
    instructions_copied: usize = 0,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    sites: []const usize,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: usize,
    fn tick(self: *Budget) Error!void {
        if (self.left == 0) return error.InlineLimit;
        self.left -= 1;
    }
};
fn eligible(
    program: ir.Program,
    bid: usize,
    permissions: traits.Facts,
    maximum: usize,
    budget: *Budget,
) Error!bool {
    try budget.tick();
    const caller = program.blocks[bid];
    if (caller.terminator != .call or caller.custody != 0) return false;
    const target = caller.terminator.call.function;
    var private = privacy.privateDirectWorker(program, target);
    for (program.constructors, 0..) |constructor, cid| {
        try budget.tick();
        if (constructor.function == target) private = privacy.privateWorker(program, cid);
    }
    if (!private) return false;
    const function = program.functions[@intCast(target)];
    if (function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1 or
        program.functions[
            @intCast(caller.function)
        ].custody.len != 1)
        return false;
    const body = program.blocks[@intCast(function.entry)];
    if (body.custody != 0 or
        body.terminator != .return_value or
        body.instructions.len > maximum)
        return false;
    for (program.blocks, 0..) |block, id| {
        try budget.tick();
        if (block.function == target and id != function.entry) return false;
    }
    for (function.layout.slots) |schema| {
        try budget.tick();
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ]) return false;
    }
    for (body.instructions) |op| {
        try budget.tick();
        if (op.failures.len != 0) return false;
        switch (op.opcode) {
            .move,
            .constant,
            .product,
            .field,
            .variant,
            .boolean_not,
            .select,
            .integer_bit_not,
            .integer_bit_and,
            .integer_bit_or,
            .integer_bit_xor,
            => {},
            else => return false,
        }
    }
    return true;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| if (block.terminator == .call) return true;
    return false;
}
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
    const permissions = try traits.derive(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    const functions = try a.dupe(ir.Function, original.functions);
    const blocks = try a.dupe(ir.Block, original.blocks);
    var sites: std.ArrayList(usize) = .empty;
    for (original.blocks, blocks, 0..) |before, *after, bid| {
        if (!try eligible(original, bid, permissions, options.max_instructions, &budget)) continue;
        if (sites.items.len == options.max_sites) return error.InlineLimit;
        const call = before.terminator.call;
        const callee = original.functions[@intCast(call.function)];
        const body = original.blocks[@intCast(callee.entry)];
        const caller = &functions[@intCast(before.function)];
        const map = try a.alloc(p.Id, callee.layout.slots.len);
        @memset(map, std.math.maxInt(p.Id));
        for (callee.inputs, call.arguments) |input, argument| map[@intCast(input)] = argument;
        const old_len = caller.layout.slots.len;
        const slots = try a.alloc(p.Id, old_len + body.instructions.len);
        @memcpy(slots[0..old_len], caller.layout.slots);
        caller.layout.slots = slots;
        const instructions = try a.alloc(
            ir.Instruction,
            before.instructions.len + body.instructions.len,
        );
        @memcpy(instructions[0..before.instructions.len], before.instructions);
        for (body.instructions, 0..) |op, index| {
            try budget.tick();
            var copy = op;
            const operands = try a.alloc(p.Id, op.operands.len);
            for (operands, op.operands) |*target, source| target.* = map[@intCast(source)];
            copy.operands = operands;
            copy.destination = old_len + index;
            slots[old_len + index] = callee.layout.slots[@intCast(op.destination)];
            map[@intCast(op.destination)] = copy.destination;
            instructions[before.instructions.len + index] = copy;
        }
        after.instructions = instructions;
        const assignments = try a.dupe(ir.Assignment, call.next.assignments);
        for (assignments) |*assignment| if (assignment.source == .returned) {
            assignment.source = .{ .slot = map[@intCast(body.terminator.return_value)] };
        };
        after.terminator = .{ .jump = .{ .block = call.next.block, .assignments = assignments } };
        try sites.append(a, bid);
    }
    if (sites.items.len == 0) return null;
    var program = original;
    program.functions = functions;
    program.blocks = blocks;
    const before_bytes = try image.encodedLength(original);
    const after_bytes = try image.encodedLength(program);
    if (after_bytes > before_bytes and
        after_bytes - before_bytes > options.max_added_bytes)
        return error.InlineLimit;
    const selected = try sites.toOwnedSlice(a);
    keep = true;
    return .{ .arena = arena, .program = program, .sites = selected };
}

/// Independently trace each callee slot backwards to its last definition or
/// original argument. No emitter map or derived fact is trusted by this checker.
fn sourceAt(
    body: ir.Block,
    function: ir.Function,
    arguments: []const p.Id,
    slot: p.Id,
    position: usize,
    first: usize,
) p.Id {
    var cursor = position;
    while (cursor != 0) {
        cursor -= 1;
        if (body.instructions[cursor].destination == slot) return first + cursor;
    }
    for (function.inputs, arguments) |input, actual| if (input == slot) return actual;
    unreachable; // independently admitted original body has definite values
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    sites: []const usize,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    if (original.functions.len != candidate.functions.len or
        original.blocks.len != candidate.blocks.len)
        return error.InvalidLeafInlining;
    var rest = candidate;
    rest.functions = original.functions;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, rest, original)) return error.InvalidLeafInlining;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const lengths = try a.alloc(usize, original.functions.len);
    for (original.functions, candidate.functions, lengths) |old, new, *length| {
        length.* = old.layout.slots.len;
        var metadata = new;
        metadata.layout = old.layout;
        if (!equal(
            ir.Function,
            metadata,
            old,
        ) or new.layout.slots.len < old.layout.slots.len or !std.mem.eql(
            p.Id,
            new.layout.slots[0..old.layout.slots.len],
            old.layout.slots,
        )) return error.InvalidLeafInlining;
    }
    var budget: Budget = .{ .left = options.work_limit };
    var seen: usize = 0;
    for (original.blocks, candidate.blocks, 0..) |old, new, bid| {
        try budget.tick();
        const count = std.mem.count(usize, sites, &.{bid});
        if (count == 0) {
            if (!equal(ir.Block, old, new)) return error.InvalidLeafInlining;
            continue;
        }
        if (count != 1 or !try eligible(
            original,
            bid,
            permissions,
            options.max_instructions,
            &budget,
        )) return error.InvalidLeafInlining;
        seen += 1;
        const call = old.terminator.call;
        const function = original.functions[@intCast(call.function)];
        const body = original.blocks[@intCast(function.entry)];
        const first = lengths[@intCast(old.function)];
        const slots = candidate.functions[@intCast(old.function)].layout.slots;
        if (slots.len < first + body.instructions.len or
            new.function != old.function or
            new.custody != old.custody or
            new.instructions.len != old.instructions.len + body.instructions.len or
            !equal(
                []const ir.Instruction,
                new.instructions[0..old.instructions.len],
                old.instructions,
            ))
            return error.InvalidLeafInlining;
        for (body.instructions, new.instructions[old.instructions.len..], 0..) |op, copied, index| {
            try budget.tick();
            if (copied.destination != first + index or
                copied.operands.len != op.operands.len or
                slots[first + index] != function.layout.slots[
                    @intCast(op.destination)
                ])
                return error.InvalidLeafInlining;
            for (
                op.operands,
                copied.operands,
            ) |old_operand, new_operand| if (new_operand != sourceAt(
                body,
                function,
                call.arguments,
                old_operand,
                index,
                first,
            )) return error.InvalidLeafInlining;
            var metadata = copied;
            metadata.operands = op.operands;
            metadata.destination = op.destination;
            if (!equal(ir.Instruction, op, metadata)) return error.InvalidLeafInlining;
        }
        if (new.terminator != .jump or
            new.terminator.jump.block != call.next.block or
            new.terminator.jump.assignments.len != call.next.assignments.len)
            return error.InvalidLeafInlining;
        for (
            call.next.assignments,
            new.terminator.jump.assignments,
        ) |old_assignment, new_assignment| {
            var expected = old_assignment;
            if (expected.source == .returned) expected.source = .{ .slot = sourceAt(
                body,
                function,
                call.arguments,
                body.terminator.return_value,
                body.instructions.len,
                first,
            ) };
            if (!equal(ir.Assignment, expected, new_assignment)) return error.InvalidLeafInlining;
        }
        lengths[@intCast(old.function)] += body.instructions.len;
    }
    if (seen != sites.len) return error.InvalidLeafInlining;
    for (
        lengths,
        candidate.functions,
    ) |length, function| if (length != function.layout.slots.len) return error.InvalidLeafInlining;
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
        error.InlineLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validate(
        allocator,
        original,
        candidate.program,
        candidate.sites,
        options,
    ) catch |err| switch (err) {
        error.InlineLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    stats.calls_removed = candidate.sites.len;
    for (candidate.sites) |bid|
        stats.instructions_copied += candidate.program.blocks[bid].instructions.len - original.blocks[bid].instructions.len;
    return p01.run(allocator, candidate.program, options.coalescing);
}
