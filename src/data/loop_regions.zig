// Copyright (c) 2026 Boundary contributors. MIT license.
//! Bounded CFG facts consumed by checked loop transformations.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
pub const Error = std.mem.Allocator.Error || error{LoopWorkLimit};
pub const Budget = struct {
    remaining: u64,
    pub fn take(self: *@This(), amount: usize) Error!void {
        if (amount > self.remaining) return error.LoopWorkLimit;
        self.remaining -= amount;
    }
    pub fn record(self: *@This(), comptime T: type, value: T) Error!void {
        try self.take(1);
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
pub fn supported(term: ir.Terminator) bool {
    return term == .jump or
        term == .branch or
        term == .switch_variant or
        term == .return_value or
        term == .fail;
}
pub fn edge(term: ir.Terminator, index: usize) ?ir.Edge {
    return switch (term) {
        .jump => |v| if (index == 0) v else null,
        .branch => |v| if (index == 0) v.when_true else if (index == 1) v.when_false else null,
        .switch_variant => |v| if (index < v.cases.len) v.cases[index] else null,
        else => null,
    };
}
pub const Graph = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    function: usize,
    blocks: []usize,
    local: []usize,
    predecessors: []std.ArrayList(usize),
    reachable: []bool,
    entry: usize,
    pub fn init(
        a: std.mem.Allocator,
        program: ir.Program,
        function: usize,
        budget: *Budget,
    ) Error!?Graph {
        var count: usize = 0;
        for (program.blocks) |block| {
            try budget.take(1);
            if (block.function != function) continue;
            if (!supported(block.terminator)) return null;
            count += 1;
        }
        try budget.take(program.blocks.len + count);
        const blocks = try a.alloc(usize, count);
        const local = try a.alloc(usize, program.blocks.len);
        @memset(local, std.math.maxInt(usize));
        var at: usize = 0;
        for (program.blocks, 0..) |block, id| if (block.function == function) {
            blocks[at] = id;
            local[id] = at;
            at += 1;
        };
        const predecessors = try a.alloc(std.ArrayList(usize), count);
        @memset(predecessors, .empty);
        for (blocks, 0..) |bid, from| {
            var ordinal: usize = 0;
            while (edge(program.blocks[bid].terminator, ordinal)) |e| : (ordinal += 1) {
                try budget.take(1);
                try predecessors[local[@intCast(e.block)]].append(a, from);
            }
        }
        var result: Graph = .{
            .allocator = a,
            .program = program,
            .function = function,
            .blocks = blocks,
            .local = local,
            .predecessors = predecessors,
            .reachable = undefined,
            .entry = local[@intCast(program.functions[function].entry)],
        };
        result.reachable = try result.reachAvoid(null, budget);
        return result;
    }
    /// Independent cut reachability also supplies the checker's dominance proof.
    pub fn reachAvoid(self: Graph, cut: ?usize, budget: *Budget) Error![]bool {
        try budget.take(self.blocks.len);
        const seen = try self.allocator.alloc(bool, self.blocks.len);
        @memset(seen, false);
        if (cut == self.entry) return seen;
        var pending: std.ArrayList(usize) = .empty;
        try pending.append(self.allocator, self.entry);
        seen[self.entry] = true;
        while (pending.pop()) |node| {
            var ordinal: usize = 0;
            while (edge(
                self.program.blocks[self.blocks[node]].terminator,
                ordinal,
            )) |e| : (ordinal += 1) {
                try budget.take(1);
                const target = self.local[@intCast(e.block)];
                if (cut == target or seen[target]) continue;
                seen[target] = true;
                try pending.append(self.allocator, target);
            }
        }
        return seen;
    }
    pub fn cyclic(self: Graph, budget: *Budget) Error!bool {
        const indegree = try self.allocator.alloc(usize, self.blocks.len);
        @memset(indegree, 0);
        var pending: std.ArrayList(usize) = .empty;
        var count: usize = 0;
        for (self.reachable, 0..) |live, node| if (live) {
            count += 1;
            for (self.predecessors[node].items) |pred| {
                try budget.take(1);
                if (self.reachable[pred]) indegree[node] += 1;
            }
            if (indegree[node] == 0) try pending.append(self.allocator, node);
        };
        var visited: usize = 0;
        while (pending.pop()) |node| {
            visited += 1;
            var ordinal: usize = 0;
            while (edge(
                self.program.blocks[self.blocks[node]].terminator,
                ordinal,
            )) |e| : (ordinal += 1) {
                try budget.take(1);
                const target = self.local[@intCast(e.block)];
                indegree[target] -= 1;
                if (indegree[target] == 0) try pending.append(self.allocator, target);
            }
        }
        return visited != count;
    }
    pub fn dominators(self: Graph, budget: *Budget) Error![]bool {
        const n = self.blocks.len;
        const size = std.math.mul(usize, n, n) catch return error.LoopWorkLimit;
        try budget.take(size);
        const dom = try self.allocator.alloc(bool, size);
        for (0..n) |node|
            for (0..n) |ancestor| {
                dom[node * n + ancestor] = self.reachable[node] and
                    self.reachable[ancestor] and
                    (node != self.entry or
                        ancestor == node);
            };
        var changed = true;
        while (changed) {
            changed = false;
            for (0..n) |node| {
                if (!self.reachable[node] or node == self.entry) continue;
                for (0..n) |ancestor| {
                    var present = true;
                    for (self.predecessors[node].items) |pred| {
                        try budget.take(1);
                        if (self.reachable[pred] and !dom[pred * n + ancestor]) {
                            present = false;
                            break;
                        }
                    }
                    present = present or ancestor == node;
                    if (dom[node * n + ancestor] != present) {
                        dom[node * n + ancestor] = present;
                        changed = true;
                    }
                }
            }
        }
        return dom;
    }
    /// Build a natural loop from all backedges dominated by its header.
    /// Discovery passes matrix membership; validation passes a header-cut proof.
    pub fn region(
        self: Graph,
        header: usize,
        dominated: []const bool,
        budget: *Budget,
    ) Error!?[]bool {
        const members = try self.allocator.alloc(bool, self.blocks.len);
        @memset(members, false);
        members[header] = true;
        var pending: std.ArrayList(usize) = .empty;
        var found = false;
        for (self.predecessors[header].items) |pred| {
            try budget.take(1);
            if (self.reachable[pred] and dominated[pred]) {
                found = true;
                if (pred != header) try pending.append(self.allocator, pred);
            }
        }
        if (!found) return null;
        while (pending.pop()) |node| {
            try budget.take(1);
            if (members[node]) continue;
            if (!dominated[node]) return null;
            members[node] = true;
            for (self.predecessors[node].items) |pred| if (self.reachable[pred]) try pending.append(
                self.allocator,
                pred,
            );
        }
        // The region has no sanctioned entry other than its header.
        for (
            members,
            0..,
        ) |inside, node| if (inside and node != header) for (self.predecessors[node].items) |pred| {
            try budget.take(1);
            if (self.reachable[pred] and !members[pred]) return null;
        };
        return members;
    }
};
