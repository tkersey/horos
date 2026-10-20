// Copyright (c) 2026 Boundary contributors. MIT license.
//! Share repeated pure straight-line return sequences through a private worker.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
const image = @import("program_image.zig");
pub const Error = p01.Error || error{ InvalidOutlining, OutliningLimit };
pub const minimum_instructions = 9; // Above leaf_inlining's bounded fragment.
pub const Options = struct {
    work_limit: usize = 1_000_000,
    max_instructions: usize = 64,
    max_sites: usize = 32,
    coalescing: p01.Options = .{},
};
pub const Site = struct { block: usize, arguments: []const p.Id };
pub const Statistics = struct {
    sites: usize = 0,
    instructions_shared: usize = 0,
    calls_added: usize = 0,
    work_limit: bool = false,
    size_guard: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    sites: []const Site,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: usize,
    fn tick(self: *Budget) Error!void {
        if (self.left == 0) return error.OutliningLimit;
        self.left -= 1;
    }
};
const Form = struct {
    arguments: []const p.Id,
    parameters: []const p.Id,
    slots: []const p.Id,
    instructions: []const ir.Instruction,
    result: p.Id,
};
fn eligible(
    program: ir.Program,
    block: ir.Block,
    permissions: traits.Facts,
    exportable: []const bool,
    options: Options,
    budget: *Budget,
) Error!bool {
    try budget.tick();
    const function = program.functions[@intCast(block.function)];
    if (block.custody != 0 or
        function.custody.len != 1 or
        function.effects.len != 0 or
        function.regions.len != 0 or
        block.terminator != .return_value or
        block.instructions.len < minimum_instructions or
        block.instructions.len > options.max_instructions)
        return false;
    if (block.terminator.return_value != block.instructions[block.instructions.len - 1].destination)
        return false;
    for (function.layout.slots) |schema| {
        try budget.tick();
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return false;
    }
    for (block.instructions) |op| {
        try budget.tick();
        if (op.failures.len != 0) return false;
        switch (op.opcode) {
            .constant,
            .move,
            .equal,
            .less,
            .boolean_not,
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
fn normalize(
    a: std.mem.Allocator,
    program: ir.Program,
    block: ir.Block,
    budget: *Budget,
) Error!?Form {
    const layout = program.functions[@intCast(block.function)].layout.slots;
    const map = try a.alloc(p.Id, layout.len);
    @memset(map, std.math.maxInt(p.Id));
    var args: std.ArrayList(p.Id) = .empty;
    var params: std.ArrayList(p.Id) = .empty;
    var slots: std.ArrayList(p.Id) = .empty;
    const instructions = try a.dupe(ir.Instruction, block.instructions);
    for (block.instructions, instructions) |old, *new| {
        try budget.tick();
        const operands = try a.alloc(p.Id, old.operands.len);
        for (old.operands, operands) |source, *target| {
            try budget.tick();
            if (map[@intCast(source)] == std.math.maxInt(p.Id)) {
                map[@intCast(source)] = slots.items.len;
                try args.append(a, source);
                try params.append(a, slots.items.len);
                try slots.append(a, layout[@intCast(source)]);
            }
            target.* = map[@intCast(source)];
        }
        if (map[@intCast(old.destination)] != std.math.maxInt(p.Id)) return null;
        map[@intCast(old.destination)] = slots.items.len;
        new.destination = slots.items.len;
        new.operands = operands;
        try slots.append(a, layout[@intCast(old.destination)]);
    }
    return .{
        .arguments = try args.toOwnedSlice(a),
        .parameters = try params.toOwnedSlice(a),
        .slots = try slots.toOwnedSlice(a),
        .instructions = instructions,
        .result = map[@intCast(block.terminator.return_value)],
    };
}
fn same(left: Form, right: Form) bool {
    return left.result == right.result and std.mem.eql(
        p.Id,
        left.parameters,
        right.parameters,
    ) and
        std.mem.eql(p.Id, left.slots, right.slots) and
        equal([]const ir.Instruction, left.instructions, right.instructions);
}
pub fn possible(program: ir.Program) bool {
    var count: usize = 0;
    for (program.blocks) |block|
        if (block.terminator == .return_value and
            block.instructions.len >= minimum_instructions)
        {
            count += 1;
            if (count == 2) return true;
        };
    return false;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var checked = try own.analyze(allocator, original);
    defer checked.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    const forms = try a.alloc(?Form, original.blocks.len);
    @memset(forms, null);
    for (
        original.blocks,
        forms,
    ) |block, *form| if (try eligible(
        original,
        block,
        permissions,
        schemas.exportable,
        options,
        &budget,
    )) {
        form.* = try normalize(a, original, block, &budget);
    };
    var chosen: ?usize = null;
    outer: for (forms, 0..) |form, id| {
        const first = form orelse continue;
        for (forms[id + 1 ..]) |other| {
            try budget.tick();
            if (other) |second| if (same(first, second)) {
                chosen = id;
                break :outer;
            };
        }
    }
    const selected = chosen orelse return null;
    const form = forms[selected].?;
    var sites: std.ArrayList(Site) = .empty;
    for (forms, 0..) |item, id| {
        try budget.tick();
        const found = item orelse continue;
        if (!same(form, found)) continue;
        if (sites.items.len == options.max_sites) return error.OutliningLimit;
        try sites.append(a, .{ .block = id, .arguments = found.arguments });
    }
    const function_id = original.functions.len;
    const body_id = original.blocks.len;
    const functions = try a.alloc(ir.Function, original.functions.len + 1);
    @memcpy(functions[0..original.functions.len], original.functions);
    functions[function_id] = .{
        .entry = body_id,
        .inputs = form.parameters,
        .layout = .{ .slots = form.slots },
        .result = form.slots[@intCast(form.result)],
    };
    const blocks = try a.alloc(ir.Block, original.blocks.len + 1 + sites.items.len);
    @memcpy(blocks[0..original.blocks.len], original.blocks);
    blocks[body_id] = .{
        .function = function_id,
        .instructions = form.instructions,
        .terminator = .{ .return_value = form.result },
    };
    for (sites.items, 0..) |site, index| {
        const old = original.blocks[site.block];
        const continuation = body_id + 1 + index;
        blocks[site.block] = .{
            .function = old.function,
            .custody = old.custody,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = function_id,
                .arguments = site.arguments,
                .next = .{
                    .block = continuation,
                    .assignments = try a.dupe(
                        ir.Assignment,
                        &.{.{ .destination = old.terminator.return_value, .source = .returned }},
                    ),
                },
            } },
        };
        blocks[continuation] = .{
            .function = old.function,
            .custody = old.custody,
            .instructions = &.{},
            .terminator = old.terminator,
        };
    }
    var program = original;
    program.functions = functions;
    program.blocks = blocks;
    const owned_sites = try sites.toOwnedSlice(a);
    keep = true;
    return .{ .arena = arena, .program = program, .sites = owned_sites };
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    sites: []const Site,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    if (sites.len < 2 or
        candidate.functions.len != original.functions.len + 1 or
        candidate.blocks.len != original.blocks.len + 1 + sites.len)
        return error.InvalidOutlining;
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    if (!equal(ir.Program, original, unchanged) or !equal(
        []const ir.Function,
        original.functions,
        candidate.functions[0..original.functions.len],
    )) return error.InvalidOutlining;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    const worker = candidate.functions[original.functions.len];
    const body = candidate.blocks[original.blocks.len];
    if (worker.entry != original.blocks.len or
        worker.effects.len != 0 or
        worker.regions.len != 0 or
        !equal([]const ir.CustodyScope, worker.custody, &.{.{}}) or
        body.function != original.functions.len or
        body.custody != 0 or
        body.terminator != .return_value)
        return error.InvalidOutlining;
    for (sites, 0..) |site, index| {
        try budget.tick();
        if (site.block >= original.blocks.len) return error.InvalidOutlining;
        for (sites[0..index]) |previous|
            if (previous.block == site.block)
                return error.InvalidOutlining;
        const old = original.blocks[site.block];
        const caller = candidate.blocks[site.block];
        if (!try eligible(original, old, permissions, schemas.exportable, options, &budget) or
            site.arguments.len != worker.inputs.len or
            body.instructions.len != old.instructions.len or
            worker.layout.slots.len != worker.inputs.len + body.instructions.len)
            return error.InvalidOutlining;
        const old_slots = original.functions[@intCast(old.function)].layout.slots;
        const map = try a.alloc(p.Id, old_slots.len);
        @memset(map, std.math.maxInt(p.Id));
        const used = try a.alloc(bool, worker.layout.slots.len);
        @memset(used, false);
        for (site.arguments, worker.inputs) |argument, parameter| {
            if (argument >= old_slots.len or map[
                @intCast(argument)
            ] != std.math.maxInt(p.Id) or used[
                @intCast(parameter)
            ] or old_slots[
                @intCast(argument)
            ] != worker.layout.slots[
                @intCast(parameter)
            ]) return error.InvalidOutlining;
            map[@intCast(argument)] = parameter;
            used[@intCast(parameter)] = true;
        }
        // Reconstruct the substitution through actual original definitions;
        // discovery's normalized body and parameter map are not consumed.
        for (old.instructions, body.instructions) |op, replacement| {
            try budget.tick();
            if (map[
                @intCast(op.destination)
            ] != std.math.maxInt(p.Id) or used[
                @intCast(replacement.destination)
            ] or old_slots[
                @intCast(op.destination)
            ] != worker.layout.slots[
                @intCast(replacement.destination)
            ] or op.operands.len != replacement.operands.len) return error.InvalidOutlining;
            for (op.operands, replacement.operands) |operand, mapped| {
                try budget.tick();
                if (map[@intCast(operand)] != mapped) return error.InvalidOutlining;
            }
            var restored = replacement;
            restored.destination = op.destination;
            restored.operands = op.operands;
            if (!equal(ir.Instruction, op, restored)) return error.InvalidOutlining;
            map[@intCast(op.destination)] = replacement.destination;
            used[@intCast(replacement.destination)] = true;
        }
        if (map[
            @intCast(old.terminator.return_value)
        ] != body.terminator.return_value) return error.InvalidOutlining;
        if (caller.function != old.function or
            caller.custody != old.custody or
            caller.instructions.len != 0 or
            caller.terminator != .call or
            caller.terminator.call.function != original.functions.len or
            !std.mem.eql(p.Id, caller.terminator.call.arguments, site.arguments))
            return error.InvalidOutlining;
        const next = caller.terminator.call.next;
        if (next.block != original.blocks.len + 1 + index or
            next.assignments.len != 1 or
            next.assignments[0].destination != old.terminator.return_value or
            next.assignments[0].source != .returned)
            return error.InvalidOutlining;
        const continuation = candidate.blocks[@intCast(next.block)];
        if (continuation.function != old.function or
            continuation.custody != old.custody or
            continuation.instructions.len != 0 or
            !equal(ir.Terminator, continuation.terminator, old.terminator))
            return error.InvalidOutlining;
    }
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, id| {
        var selected = false;
        for (sites) |site| if (site.block == id) {
            selected = true;
        };
        if (!selected and !equal(ir.Block, old, new)) return error.InvalidOutlining;
    }
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
        error.OutliningLimit => {
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
        error.OutliningLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    var baseline = try p01.run(allocator, original, options.coalescing);
    var keep_baseline = false;
    defer if (!keep_baseline) baseline.deinit();
    var result = try p01.run(allocator, candidate.program, options.coalescing);
    var keep_result = false;
    defer if (!keep_result) result.deinit();
    if (try image.encodedLength(result.program) >= try image.encodedLength(baseline.program)) {
        stats.size_guard = true;
        keep_baseline = true;
        return baseline;
    }
    stats.sites = candidate.sites.len;
    stats.calls_added = candidate.sites.len;
    stats.instructions_shared =
        original.blocks[candidate.sites[0].block].instructions.len *
        (candidate.sites.len -
            1);
    keep_result = true;
    return result;
}
