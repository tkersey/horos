// Copyright (c) 2026 Boundary contributors. MIT license.
//! Empty deep handlers have no selectable operation. Keep state evaluation and
//! preserve nonidentity pure total returns with an explicit ordered call bridge.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const total = @import("total_clause.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidHandlerElimination, HandlerWorkLimit };
pub const Options = struct { work_limit: usize = 1_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct {
    installations_removed: usize = 0,
    return_calls_preserved: usize = 0,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    installations_removed: usize,
    return_calls_preserved: usize,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: usize,
    fn take(self: *Budget, count: usize) Error!void {
        if (count > self.left) return error.HandlerWorkLimit;
        self.left -= count;
    }
};
fn identityReturn(program: ir.Program, handler: ir.Handler) bool {
    if (handler.input != handler.answer) return false;
    const function = program.functions[@intCast(handler.return_function)];
    const entry = program.blocks[@intCast(function.entry)];
    return entry.instructions.len == 0 and
        entry.terminator == .return_value and
        entry.terminator.return_value == function.inputs[handler.state.len];
}
fn eligible(
    a: std.mem.Allocator,
    program: ir.Program,
    handler: ir.Handler,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!bool {
    try budget.take(1);
    if (handler.mode != .deep or
        handler.clauses.len != 0 or
        handler.effects.len != 0 or
        handler.input != handler.answer)
        return false;
    for (handler.state) |schema| {
        try budget.take(1);
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return false;
    }
    for ([_]p.Id{ handler.input, handler.answer }) |schema| if (!exportable[
        @intCast(schema)
    ] or !permissions.copy[
        @intCast(schema)
    ] or !permissions.drop[
        @intCast(schema)
    ]) return false;
    const function = program.functions[@intCast(handler.return_function)];
    if (function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1)
        return false;
    for (program.blocks) |block| {
        try budget.take(1);
        if (block.function != handler.return_function) continue;
        if (block.custody != 0) return false;
        for (block.instructions) |op| {
            try budget.take(1 + op.operands.len);
            if (!total.instruction(
                op,
            ) or op.opcode == .cell_get or op.opcode == .cell_set) return false;
        }
    }
    total.validate(a, program, handler.return_function, permissions) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    return true;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| if (block.terminator == .handle) {
        const handler = program.handlers[@intCast(block.terminator.handle.handler)];
        if (handler.mode == .deep and handler.clauses.len == 0) return true;
    };
    return false;
}
fn returnBridge(
    a: std.mem.Allocator,
    old: ir.Block,
    caller: *ir.Function,
    blocks: *std.ArrayList(ir.Block),
    handle: anytype,
    handler: anytype,
) Error!ir.Edge {
    const slot = caller.layout.slots.len;
    const slots = try a.alloc(
        p.Id,
        std.math.add(usize, slot, 1) catch return error.Capacity,
    );
    @memcpy(slots[0..slot], caller.layout.slots);
    slots[slot] = handler.input;
    caller.layout.slots = slots;
    const arguments = try a.alloc(p.Id, handle.state.len + 1);
    @memcpy(arguments[0..handle.state.len], handle.state);
    arguments[handle.state.len] = slot;
    const assignments = try a.alloc(ir.Assignment, 1);
    assignments[0] = .{ .destination = slot, .source = .returned };
    const next: ir.Edge = .{ .block = blocks.items.len, .assignments = assignments };
    try blocks.append(
        a,
        .{
            .function = old.function,
            .custody = old.custody,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = handler.return_function,
                .arguments = arguments,
                .next = handle.next,
            } },
        },
    );
    return next;
}
fn validateBridge(
    original: ir.Block,
    candidate: ir.Program,
    lengths: []usize,
    bridge: *usize,
    handle: anytype,
    apply: anytype,
    handler: anytype,
) Error!void {
    const old = original;
    if (bridge.* >= candidate.blocks.len or
        apply.next.block != bridge.* or
        apply.next.assignments.len != 1)
        return error.InvalidHandlerElimination;
    const slot = lengths[@intCast(old.function)];
    const assignment = apply.next.assignments[0];
    if (assignment.destination != slot or
        assignment.source != .returned or
        slot >= candidate.functions[
            @intCast(old.function)
        ].layout.slots.len or
        candidate.functions[
            @intCast(old.function)
        ].layout.slots[slot] != handler.input)
        return error.InvalidHandlerElimination;
    lengths[@intCast(old.function)] += 1;
    const call = candidate.blocks[bridge.*];
    bridge.* += 1;
    if (call.function != old.function or
        call.custody != old.custody or
        call.instructions.len != 0 or
        call.terminator != .call or
        call.terminator.call.function != handler.return_function or
        !equal(ir.Edge, call.terminator.call.next, handle.next))
        return error.InvalidHandlerElimination;
    const actual = call.terminator.call.arguments;
    if (actual.len != handle.state.len + 1 or !equal(
        []const p.Id,
        actual[0..handle.state.len],
        handle.state,
    ) or actual[handle.state.len] != slot) return error.InvalidHandlerElimination;
}
fn validateLayouts(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
) Error![]usize {
    const lengths = try a.alloc(usize, original.functions.len);
    for (original.functions, candidate.functions, lengths) |old, new, *length| {
        length.* = old.layout.slots.len;
        var metadata = new;
        metadata.layout = old.layout;
        if (!equal(ir.Function, old, metadata) or new.layout.slots.len < length.* or !equal(
            []const p.Id,
            old.layout.slots,
            new.layout.slots[0..length.*],
        )) return error.InvalidHandlerElimination;
    }
    return lengths;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!Candidate {
    var checked = try own.analyze(allocator, original);
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    const functions = try a.dupe(ir.Function, original.functions);
    var blocks: std.ArrayList(ir.Block) = .empty;
    try blocks.appendSlice(a, original.blocks);
    var selected: usize = 0;
    var calls: usize = 0;
    for (original.blocks, 0..) |old, id| {
        try budget.take(1);
        if (old.terminator != .handle) continue;
        const handle = old.terminator.handle;
        const handler = original.handlers[@intCast(handle.handler)];
        if (!try eligible(a, original, handler, permissions, schemas.exportable, &budget)) continue;
        var next = handle.next;
        if (!identityReturn(original, handler)) {
            next = try returnBridge(
                a,
                old,
                &functions[@intCast(old.function)],
                &blocks,
                handle,
                handler,
            );
            calls += 1;
        }
        blocks.items[id].terminator = .{ .apply = .{
            .computation = handle.body,
            .arguments = handle.arguments,
            .next = next,
        } };
        selected += 1;
    }
    var program = original;
    program.functions = functions;
    program.blocks = try blocks.toOwnedSlice(a);
    keep = true;
    return .{
        .arena = arena,
        .program = program,
        .installations_removed = selected,
        .return_calls_preserved = calls,
    };
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    limit: usize,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var rest = candidate;
    rest.blocks = original.blocks;
    rest.functions = original.functions;
    if (!equal(ir.Program, original, rest) or
        original.functions.len != candidate.functions.len or
        original.blocks.len > candidate.blocks.len)
        return error.InvalidHandlerElimination;
    const lengths = try validateLayouts(a, original, candidate);
    var budget: Budget = .{ .left = limit };
    var bridge = original.blocks.len;
    for (original.blocks, candidate.blocks[0..original.blocks.len]) |old, new| {
        try budget.take(1);
        if (equal(ir.Block, old, new)) continue;
        if (old.terminator != .handle or
            new.terminator != .apply)
            return error.InvalidHandlerElimination;
        var metadata = new;
        metadata.terminator = old.terminator;
        const handle = old.terminator.handle;
        const apply = new.terminator.apply;
        const handler = original.handlers[@intCast(handle.handler)];
        if (!equal(ir.Block, old, metadata) or !try eligible(
            a,
            original,
            handler,
            permissions,
            schemas.exportable,
            &budget,
        ) or apply.computation != handle.body or !equal(
            []const p.Id,
            apply.arguments,
            handle.arguments,
        )) return error.InvalidHandlerElimination;
        if (identityReturn(original, handler) and equal(ir.Edge, apply.next, handle.next)) continue;
        try validateBridge(old, candidate, lengths, &bridge, handle, apply, handler);
    }
    if (bridge != candidate.blocks.len) return error.InvalidHandlerElimination;
    for (
        candidate.functions,
        lengths,
    ) |function, length|
        if (function.layout.slots.len != length)
            return error.InvalidHandlerElimination;
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
    var candidate = construct(allocator, original, options) catch |err| switch (err) {
        error.HandlerWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    defer candidate.deinit();
    validate(allocator, original, candidate.program, options.work_limit) catch |err| switch (err) {
        error.HandlerWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.installations_removed = candidate.installations_removed;
    stats.return_calls_preserved = candidate.return_calls_preserved;
    return result;
}
