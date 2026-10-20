// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked logical packing for pure non-suspending activation-local values.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const flow = @import("activation_flow.zig");
const sets = @import("analysis_sets.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidSlotPacking, SlotPackingLimit };
pub const Options = struct {
    work_limit: usize = 10_000_000,
    max_slots: usize = 128,
    coalescing: p01.Options = .{},
};
pub const Statistics = struct {
    functions: usize = 0,
    slots_removed: usize = 0,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    maps: []const ?[]const p.Id,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: usize,
    fn tick(self: *Budget) Error!void {
        if (self.left == 0) return error.SlotPackingLimit;
        self.left -= 1;
    }
};
fn eligible(
    program: ir.Program,
    id: usize,
    permissions: traits.Facts,
    exportable: []const bool,
    options: Options,
    budget: *Budget,
) Error!bool {
    const function = program.functions[id];
    if (function.layout.slots.len < 2 or
        function.layout.slots.len > options.max_slots or
        function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1)
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
    for (program.blocks) |block| {
        try budget.tick();
        if (block.function != id) continue;
        if (block.custody != 0) return false;
        switch (block.terminator) {
            .return_value, .fail, .jump, .branch => {},
            else => return false,
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
                .product,
                .field,
                .variant,
                .select,
                => {},
                else => return false,
            }
        }
    }
    return true;
}
fn successor(term: ir.Terminator, index: usize) ?ir.Edge {
    return switch (term) {
        .jump => |edge| if (index == 0) edge else null,
        .branch => |branch| if (index == 0)
            branch.when_true
        else if (index == 1)
            branch.when_false
        else
            null,
        else => null,
    };
}
fn interfere(matrix: []bool, n: usize, x: usize, y: usize) void {
    if (x != y) {
        matrix[x * n + y] = true;
        matrix[y * n + x] = true;
    }
}
fn liveClique(
    matrix: []bool,
    n: usize,
    facts: *flow.Facts,
    live: sets.Root,
    budget: *Budget,
) Error!void {
    for (0..n) |x| if (facts.pool.contains(live, x)) {
        for (x + 1..n) |y| {
            try budget.tick();
            if (facts.pool.contains(live, y)) interfere(matrix, n, x, y);
        }
    };
}
fn interference(
    a: std.mem.Allocator,
    program: ir.Program,
    id: usize,
    facts: *flow.Facts,
    budget: *Budget,
) Error![]bool {
    const function = program.functions[id];
    const n = function.layout.slots.len;
    const matrix = try a.alloc(bool, std.math.mul(usize, n, n) catch return error.Capacity);
    @memset(matrix, false);
    for (function.inputs) |x| for (0..n) |y| {
        try budget.tick();
        interfere(matrix, n, @intCast(x), @intCast(y));
    };
    for (program.blocks, 0..) |block, bid| {
        try budget.tick();
        if (block.function != id) continue;
        if (facts.live[bid].len != 0) {
            for (facts.live[bid]) |live| try liveClique(matrix, n, facts, live, budget);
            for (block.instructions, 0..) |op, index| for (0..n) |live| {
                try budget.tick();
                if (facts.pool.contains(facts.live[bid][index + 1], live))
                    interfere(matrix, n, @intCast(op.destination), live);
            };
        }
        var next: usize = 0;
        while (successor(block.terminator, next)) |edge| : (next += 1) {
            for (edge.assignments) |assignment| {
                for (edge.assignments) |other| {
                    try budget.tick();
                    interfere(
                        matrix,
                        n,
                        @intCast(assignment.destination),
                        @intCast(other.destination),
                    );
                }
                if (facts.live[@intCast(edge.block)].len != 0) for (0..n) |live| {
                    try budget.tick();
                    if (facts.pool.contains(
                        facts.live[@intCast(edge.block)][0],
                        live,
                    )) interfere(matrix, n, @intCast(assignment.destination), live);
                };
            }
        }
    }
    return matrix;
}
fn ids(a: std.mem.Allocator, values: []const p.Id, map: []const p.Id) Error![]const p.Id {
    const result = try a.alloc(p.Id, values.len);
    for (values, result) |old, *new| new.* = map[@intCast(old)];
    return result;
}
fn edgeMap(a: std.mem.Allocator, edge: ir.Edge, map: []const p.Id) Error!ir.Edge {
    var assignments: std.ArrayList(ir.Assignment) = .empty;
    for (edge.assignments) |old| {
        var assignment = old;
        assignment.destination = map[@intCast(old.destination)];
        if (old.source == .slot) assignment.source = .{ .slot = map[@intCast(old.source.slot)] };
        if (assignment.source == .slot and
            assignment.source.slot == assignment.destination)
            continue;
        try assignments.append(a, assignment);
    }
    return .{ .block = edge.block, .assignments = try assignments.toOwnedSlice(a) };
}
pub fn possible(program: ir.Program) bool {
    for (program.functions) |function|
        if (function.layout.slots.len >= 2 and
            function.layout.slots.len > function.inputs.len)
            return true;
    return false;
}
fn colorFunction(
    a: std.mem.Allocator,
    original: ir.Program,
    id: usize,
    out: *ir.Function,
    facts: *flow.Facts,
    budget: *Budget,
) Error!?[]const p.Id {
    const function = original.functions[id];
    const n = function.layout.slots.len;
    const matrix = try interference(a, original, id, facts, budget);
    const map = try a.alloc(p.Id, n);
    @memset(map, std.math.maxInt(p.Id));
    var colors: std.ArrayList(p.Id) = .empty;
    // Inputs get distinct destinations and preserve their public order.
    for (function.inputs) |input| {
        map[@intCast(input)] = colors.items.len;
        try colors.append(a, function.layout.slots[@intCast(input)]);
    }
    for (function.layout.slots, 0..) |schema, slot| {
        if (map[slot] != std.math.maxInt(p.Id)) continue;
        var selected: ?usize = null;
        for (colors.items, 0..) |color_schema, color| {
            try budget.tick();
            if (color_schema != schema) continue;
            var conflict = false;
            for (map, 0..) |other_color, other| {
                try budget.tick();
                if (other_color == color and matrix[slot * n + other]) {
                    conflict = true;
                    break;
                }
            }
            if (!conflict) {
                selected = color;
                break;
            }
        }
        if (selected) |color| map[slot] = color else {
            map[slot] = colors.items.len;
            try colors.append(a, schema);
        }
    }
    if (colors.items.len >= n) return null;
    out.layout.slots = try colors.toOwnedSlice(a);
    out.inputs = try ids(a, function.inputs, map);
    return map;
}
fn mapBlocks(
    a: std.mem.Allocator,
    original: ir.Program,
    maps: []const ?[]const p.Id,
) Error![]ir.Block {
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (blocks) |*block| {
        const map = maps[@intCast(block.function)] orelse continue;
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        for (instructions) |*op| {
            op.destination = map[@intCast(op.destination)];
            op.operands = try ids(a, op.operands, map);
        }
        block.instructions = instructions;
        block.terminator = switch (block.terminator) {
            .return_value => |slot| .{ .return_value = map[@intCast(slot)] },
            .fail => |slot| .{ .fail = map[@intCast(slot)] },
            .jump => |edge| .{ .jump = try edgeMap(a, edge, map) },
            .branch => |branch| .{ .branch = .{
                .condition = map[@intCast(branch.condition)],
                .when_true = try edgeMap(a, branch.when_true, map),
                .when_false = try edgeMap(a, branch.when_false, map),
            } },
            else => return error.InvalidSlotPacking,
        };
    }
    return blocks;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var facts = try own.analyze(allocator, original);
    defer facts.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    const functions = try a.dupe(ir.Function, original.functions);
    const maps = try a.alloc(?[]const p.Id, functions.len);
    @memset(maps, null);
    var changed = false;
    for (functions, 0..) |*out, id| {
        if (!try eligible(
            original,
            id,
            permissions,
            schemas.exportable,
            options,
            &budget,
        )) continue;
        const map = (try colorFunction(a, original, id, out, &facts, &budget)) orelse continue;
        maps[id] = map;
        changed = true;
    }
    if (!changed) return null;
    const blocks = try mapBlocks(a, original, maps);
    var program = original;
    program.functions = functions;
    program.blocks = blocks;
    keep = true;
    return .{ .arena = arena, .program = program, .maps = maps };
}
fn distinct(map: []const p.Id, x: p.Id, y: p.Id) Error!void {
    if (x != y and map[@intCast(x)] == map[@intCast(y)]) return error.InvalidSlotPacking;
}
fn sameIds(old: []const p.Id, new: []const p.Id, map: []const p.Id) bool {
    if (old.len != new.len) return false;
    for (old, new) |x, y| if (map[@intCast(x)] != y) return false;
    return true;
}
fn edgeMatches(old: ir.Edge, new: ir.Edge, map: []const p.Id) bool {
    if (old.block != new.block) return false;
    var next: usize = 0;
    for (old.assignments) |x| {
        if (x.source == .slot and map[
            @intCast(x.source.slot)
        ] == map[
            @intCast(x.destination)
        ]) continue;
        if (next >= new.assignments.len) return false;
        const y = new.assignments[next];
        if (map[@intCast(x.destination)] != y.destination) return false;
        switch (x.source) {
            .returned => if (y.source != .returned) return false,
            .slot => |slot| if (y.source != .slot or y.source.slot != map[
                @intCast(slot)
            ]) return false,
        }
        next += 1;
    }
    return next == new.assignments.len;
}
fn validateFunction(
    a: std.mem.Allocator,
    old: ir.Function,
    new: ir.Function,
    map: []const p.Id,
) Error!void {
    var metadata = new;
    metadata.layout = old.layout;
    metadata.inputs = old.inputs;
    if (!equal(ir.Function, old, metadata) or
        !sameIds(old.inputs, new.inputs, map))
        return error.InvalidSlotPacking;
    const seen = try a.alloc(bool, new.layout.slots.len);
    @memset(seen, false);
    for (map, old.layout.slots) |color, schema| {
        if (color >= seen.len or new.layout.slots[
            @intCast(color)
        ] != schema) return error.InvalidSlotPacking;
        seen[@intCast(color)] = true;
    }
    for (seen) |used| if (!used) return error.InvalidSlotPacking;
    for (old.inputs) |x| for (0..map.len) |y| try distinct(map, x, y);
}
fn validateInterference(
    old: ir.Block,
    bid: usize,
    map: []const p.Id,
    facts: *flow.Facts,
    budget: *Budget,
) Error!void {
    var structural_edge: usize = 0;
    while (successor(
        old.terminator,
        structural_edge,
    )) |edge| : (structural_edge += 1) for (edge.assignments) |assignment| {
        for (edge.assignments) |other| {
            try budget.tick();
            try distinct(map, assignment.destination, other.destination);
        }
    };
    // Re-derive noninterference directly from original live states and writes;
    // no discovery graph, coloring order, or supplied liveness is trusted.
    if (facts.live[bid].len != 0) {
        for (facts.live[bid]) |live| for (0..map.len) |x| if (facts.pool.contains(live, x)) {
            for (x + 1..map.len) |y| {
                try budget.tick();
                if (facts.pool.contains(live, y)) try distinct(map, x, y);
            }
        };
        for (old.instructions, 0..) |op, index| for (0..map.len) |live| {
            try budget.tick();
            if (facts.pool.contains(facts.live[bid][index + 1], live))
                try distinct(map, op.destination, live);
        };
        var index: usize = 0;
        while (successor(
            old.terminator,
            index,
        )) |edge| : (index += 1) for (edge.assignments) |assignment| {
            for (edge.assignments) |other| try distinct(
                map,
                assignment.destination,
                other.destination,
            );
            if (facts.live[@intCast(edge.block)].len != 0) for (0..map.len) |live| {
                try budget.tick();
                if (facts.pool.contains(
                    facts.live[@intCast(edge.block)][0],
                    live,
                )) try distinct(map, assignment.destination, live);
            };
        };
    }
}
fn validateBlockMapping(
    old: ir.Block,
    new: ir.Block,
    map: []const p.Id,
    budget: *Budget,
) Error!void {
    for (old.instructions, new.instructions) |op, replacement| {
        try budget.tick();
        if (replacement.destination != map[@intCast(op.destination)] or !sameIds(
            op.operands,
            replacement.operands,
            map,
        )) return error.InvalidSlotPacking;
        var metadata = replacement;
        metadata.destination = op.destination;
        metadata.operands = op.operands;
        if (!equal(ir.Instruction, op, metadata)) return error.InvalidSlotPacking;
    }
    switch (old.terminator) {
        .return_value => |slot| if (new.terminator != .return_value or
            new.terminator.return_value != map[
                @intCast(slot)
            ])
            return error.InvalidSlotPacking,
        .fail => |slot| if (new.terminator != .fail or new.terminator.fail != map[
            @intCast(slot)
        ]) return error.InvalidSlotPacking,
        .jump => |edge| if (new.terminator != .jump or !edgeMatches(
            edge,
            new.terminator.jump,
            map,
        )) return error.InvalidSlotPacking,
        .branch => |branch| if (new.terminator != .branch or
            new.terminator.branch.condition != map[
                @intCast(branch.condition)
            ] or
            !edgeMatches(branch.when_true, new.terminator.branch.when_true, map) or
            !edgeMatches(branch.when_false, new.terminator.branch.when_false, map))
            return error.InvalidSlotPacking,
        else => return error.InvalidSlotPacking,
    }
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    maps: []const ?[]const p.Id,
    options: Options,
) Error!void {
    var facts = try own.analyze(allocator, original);
    defer facts.deinit();
    var admitted = try own.analyze(allocator, candidate);
    defer admitted.deinit();
    if (maps.len != original.functions.len or
        candidate.functions.len != original.functions.len or
        candidate.blocks.len != original.blocks.len)
        return error.InvalidSlotPacking;
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    if (!equal(ir.Program, original, unchanged)) return error.InvalidSlotPacking;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    for (original.functions, candidate.functions, maps, 0..) |old, new, mapping, id| {
        const map = mapping orelse {
            if (!equal(ir.Function, old, new)) return error.InvalidSlotPacking;
            continue;
        };
        if (!try eligible(original, id, permissions, schemas.exportable, options, &budget) or
            map.len != old.layout.slots.len or
            new.layout.slots.len >= map.len)
            return error.InvalidSlotPacking;
        try validateFunction(a, old, new, map);
    }
    for (original.blocks, candidate.blocks, 0..) |old, new, bid| {
        const map = maps[@intCast(old.function)] orelse {
            if (!equal(ir.Block, old, new)) return error.InvalidSlotPacking;
            continue;
        };
        if (old.function != new.function or
            old.custody != new.custody or
            old.instructions.len != new.instructions.len)
            return error.InvalidSlotPacking;
        try validateInterference(old, bid, map, &facts, &budget);
        try validateBlockMapping(old, new, map, &budget);
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
        error.SlotPackingLimit => {
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
        candidate.maps,
        options,
    ) catch |err| switch (err) {
        error.SlotPackingLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    for (
        original.functions,
        candidate.program.functions,
        candidate.maps,
    ) |old, new, map| if (map != null) {
        stats.functions += 1;
        stats.slots_removed += old.layout.slots.len - new.layout.slots.len;
    };
    return p01.run(allocator, candidate.program, options.coalescing);
}
