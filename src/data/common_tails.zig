// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked whole-tail sharing within a function; separate from P01 bijections.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const admission = @import("admission.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidCommonTail, CommonTailLimit };
pub const Options = struct { work_limit: usize = 1_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct {
    tails_shared: usize = 0,
    branches_removed: usize = 0,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    representatives: []const p.Id,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: usize,
    fn tick(self: *Budget) Error!void {
        if (self.left == 0) return error.CommonTailLimit;
        self.left -= 1;
    }
};
fn charge(comptime T: type, value: T, budget: *Budget) Error!void {
    try budget.tick();
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (
            info.field_names,
            info.field_types,
        ) |field_name, FieldType| try charge(FieldType, @field(value, field_name), budget),
        .@"union" => switch (value) {
            inline else => |payload| try charge(@TypeOf(payload), payload, budget),
        },
        .pointer => |info| for (value) |item| try charge(info.child, item, budget),
        .optional => |info| if (value) |item| {
            try charge(info.child, item, budget);
        },
        else => {},
    }
}
fn domain(a: std.mem.Allocator, program: ir.Program, budget: *Budget) Error![]bool {
    const permissions = try traits.derive(a, program.schemas);
    const schemas = try admission.schemas(a, program.schemas);
    const eligible = try a.alloc(bool, program.functions.len);
    for (program.functions, eligible) |function, *allowed| {
        allowed.* = function.effects.len == 0 and function.regions.len == 0;
        for (function.layout.slots) |schema| {
            try budget.tick();
            if (!permissions.copy[
                @intCast(schema)
            ] or !permissions.drop[
                @intCast(schema)
            ] or !schemas.exportable[
                @intCast(schema)
            ]) allowed.* = false;
        }
    }
    for (program.blocks) |block| {
        try budget.tick();
        switch (block.terminator) {
            .return_value, .fail, .jump, .branch => {},
            else => eligible[@intCast(block.function)] = false,
        }
    }
    return eligible;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| if (block.terminator == .branch) return true;
    return false;
}
fn edge(map: []const p.Id, before: ir.Edge) ir.Edge {
    var after = before;
    after.block = map[@intCast(before.block)];
    return after;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var admitted = try ownership.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: Budget = .{ .left = options.work_limit };
    const eligible = try domain(a, original, &budget);
    const map = try a.alloc(p.Id, original.blocks.len);
    var changed = false;
    for (original.blocks, map, 0..) |block, *representative, id| {
        representative.* = id;
        if (!eligible[@intCast(block.function)]) continue;
        for (original.blocks[0..id], 0..) |previous, previous_id| {
            try budget.tick();
            if (previous.function != block.function or previous.custody != block.custody) continue;
            try charge(ir.Block, block, &budget);
            if (map[previous_id] == previous_id and equal(ir.Block, previous, block)) {
                representative.* = previous_id;
                changed = true;
                break;
            }
        }
    }
    const functions = try a.dupe(ir.Function, original.functions);
    for (functions) |*function| function.entry = map[@intCast(function.entry)];
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (blocks) |*block| {
        try charge(ir.Block, block.*, &budget);
        switch (block.terminator) {
            .jump => |next| block.terminator = .{ .jump = edge(map, next) },
            .branch => |branch| {
                const yes = edge(map, branch.when_true);
                const no = edge(map, branch.when_false);
                if (eligible[@intCast(block.function)] and equal(ir.Edge, yes, no)) {
                    block.terminator = .{ .jump = yes };
                    changed = true;
                } else block.terminator = .{ .branch = .{
                    .condition = branch.condition,
                    .when_true = yes,
                    .when_false = no,
                } };
            },
            else => {},
        }
    }
    if (!changed) return null;
    var program = original;
    program.functions = functions;
    program.blocks = blocks;
    keep = true;
    return .{ .arena = arena, .program = program, .representatives = map };
}
fn edgeMatches(map: []const p.Id, before: ir.Edge, after: ir.Edge) bool {
    return after.block == map[@intCast(before.block)] and equal(
        []const ir.Assignment,
        before.assignments,
        after.assignments,
    );
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: []const p.Id,
    options: Options,
) Error!void {
    var before = try ownership.analyze(allocator, original);
    defer before.deinit();
    var after = try ownership.analyze(allocator, candidate);
    defer after.deinit();
    if (map.len != original.blocks.len or
        candidate.blocks.len != original.blocks.len or
        candidate.functions.len != original.functions.len)
        return error.InvalidCommonTail;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: Budget = .{ .left = options.work_limit };
    const eligible = try domain(arena.allocator(), original, &budget);
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    if (!equal(ir.Program, original, unchanged)) return error.InvalidCommonTail;
    for (map, original.blocks, 0..) |representative, block, id| {
        try charge(ir.Block, block, &budget);
        if (representative > id or map[
            @intCast(representative)
        ] != representative) return error.InvalidCommonTail;
        if (representative != id and (!eligible[@intCast(block.function)] or !equal(
            ir.Block,
            block,
            original.blocks[@intCast(representative)],
        ))) return error.InvalidCommonTail;
    }
    for (original.functions, candidate.functions) |old, new| {
        var restored = new;
        restored.entry = old.entry;
        if (new.entry != map[@intCast(old.entry)] or !equal(
            ir.Function,
            old,
            restored,
        )) return error.InvalidCommonTail;
    }
    for (original.blocks, candidate.blocks) |old, new| {
        try charge(ir.Block, old, &budget);
        var restored = new;
        restored.terminator = old.terminator;
        if (!equal(ir.Block, old, restored)) return error.InvalidCommonTail;
        switch (old.terminator) {
            .jump => |next| if (new.terminator != .jump or !edgeMatches(
                map,
                next,
                new.terminator.jump,
            )) return error.InvalidCommonTail,
            .branch => |branch| {
                if (new.terminator == .jump) {
                    if (!eligible[@intCast(old.function)] or !edgeMatches(
                        map,
                        branch.when_true,
                        new.terminator.jump,
                    ) or !edgeMatches(
                        map,
                        branch.when_false,
                        new.terminator.jump,
                    )) return error.InvalidCommonTail;
                } else {
                    if (new.terminator != .branch or
                        new.terminator.branch.condition != branch.condition or
                        !edgeMatches(map, branch.when_true, new.terminator.branch.when_true) or
                        !edgeMatches(map, branch.when_false, new.terminator.branch.when_false))
                        return error.InvalidCommonTail;
                }
            },
            else => if (!equal(
                ir.Terminator,
                old.terminator,
                new.terminator,
            )) return error.InvalidCommonTail,
        }
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
        error.CommonTailLimit => {
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
        candidate.representatives,
        options,
    ) catch |err| switch (err) {
        error.CommonTailLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    for (candidate.representatives, 0..) |representative, id| {
        if (representative != id) stats.tails_shared += 1;
    }
    for (original.blocks, candidate.program.blocks) |old, new| {
        if (old.terminator == .branch and new.terminator == .jump) stats.branches_removed += 1;
    }
    return p01.run(allocator, candidate.program, options.coalescing);
}
