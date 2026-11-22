// Copyright (c) 2026 Boundary contributors. MIT license.
//! Comparison-only local names. Never rewrites a retained function's layout.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const r = @import("relocation.zig");
const graph = @import("coalescing_graph.zig");
pub const Error = graph.Error || error{InvalidProgram};

pub const Names = struct {
    allocator: std.mem.Allocator,
    work: *graph.Work,
    function: ir.Function,
    slots: []p.Id,
    custody: []p.Id,
    slot_order: std.ArrayList(p.Id) = .empty,
    scope_order: std.ArrayList(p.Id) = .empty,

    /// All allocations belong to the caller's scratch arena, including on failure.
    pub fn init(a: std.mem.Allocator, function: ir.Function, work: *graph.Work) Error!Names {
        try work.chargeBounded(function.layout.slots.len);
        try work.chargeBounded(function.custody.len);
        const slots = try a.alloc(p.Id, function.layout.slots.len);
        const custody = try a.alloc(p.Id, function.custody.len);
        @memset(slots, r.missing);
        @memset(custody, r.missing);
        return .{
            .allocator = a,
            .work = work,
            .function = function,
            .slots = slots,
            .custody = custody,
        };
    }
    pub fn slot(self: *Names, old: p.Id) Error!p.Id {
        try self.work.charge(1);
        if (old >= self.slots.len) return error.InvalidReference;
        const result = &self.slots[@intCast(old)];
        if (result.* == r.missing) {
            result.* = self.slot_order.items.len;
            try self.work.append(self.allocator, &self.slot_order, old);
        }
        return result.*;
    }
    pub fn scope(self: *Names, old: p.Id) Error!p.Id {
        if (old >= self.custody.len) return error.InvalidReference;
        var chain: std.ArrayList(p.Id) = .empty;
        defer chain.deinit(self.allocator);
        var cursor = old;
        while (self.custody[@intCast(cursor)] == r.missing) {
            try self.work.charge(1);
            try self.work.append(self.allocator, &chain, cursor);
            const parent = self.function.custody[@intCast(cursor)].parent orelse break;
            if (parent >= cursor) return error.InvalidReference;
            cursor = parent;
        }
        while (chain.pop()) |id| {
            self.custody[@intCast(id)] = self.scope_order.items.len;
            try self.work.append(self.allocator, &self.scope_order, id);
        }
        return self.custody[@intCast(old)];
    }
    pub fn complete(self: *Names, schemas: []const p.Id) Error!void {
        var remaining: std.ArrayList(Slot) = .empty;
        for (self.function.layout.slots, self.slots, 0..) |schema, name, old| {
            try self.work.charge(1);
            if (schema >= schemas.len) return error.InvalidReference;
            if (name == r.missing) try self.work.append(
                self.allocator,
                &remaining,
                .{ .schema = schemas[@intCast(schema)], .old = old },
            );
        }
        try sorted(Slot, remaining.items, {}, Slot.less, self.work, null);
        for (remaining.items) |item| _ = try self.slot(item.old);
        try self.completeScopes();
    }
    fn completeScopes(self: *Names) Error!void {
        const n = self.custody.len;
        if (n == 0) return error.InvalidProgram;
        _ = try self.scope(0);
        var tree = try ScopeTree.init(self.allocator, self.function.custody, self.work);
        try tree.rank();
        var cursor: usize = 0;
        while (cursor < self.scope_order.items.len) : (cursor += 1) {
            const parent = self.scope_order.items[cursor];
            const children = tree.children[@intCast(parent)].items;
            const ranks: []const p.Id = tree.ranks;
            try sorted(p.Id, children, ranks, ScopeTree.lessChild, self.work, null);
            for (children) |child| {
                try self.work.charge(1);
                if (self.custody[@intCast(child)] == r.missing) _ = try self.scope(child);
            }
        }
        if (self.scope_order.items.len != n) return error.InvalidProgram;
    }
};

fn sorted(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime less: fn (@TypeOf(context), T, T) bool,
    work: *graph.Work,
    comptime metered_less: anytype,
) Error!void {
    if (work.remaining == null and !work.compact_refinement)
        return std.mem.sort(T, items, context, less);
    if (items.len < 2) return;
    const Heap = struct {
        values: []T,
        context: @TypeOf(context),
        work: *graph.Work,

        fn before(self: @This(), i: usize, j: usize) Error!bool {
            try self.work.chargeBounded(1);
            if (comptime @TypeOf(metered_less) != @TypeOf(null))
                return metered_less(self.work, self.values[i], self.values[j]);
            return less(self.context, self.values[i], self.values[j]);
        }

        fn sift(self: @This(), start: usize, end: usize) Error!void {
            var root = start;
            while (root < end / 2) {
                var child = 2 * root + 1;
                if (child + 1 < end and try self.before(child, child + 1)) child += 1;
                if (!try self.before(root, child)) break;
                std.mem.swap(T, &self.values[root], &self.values[child]);
                root = child;
            }
        }
    };
    const heap: Heap = .{ .values = items, .context = context, .work = work };
    var start = items.len / 2;
    while (start > 0) {
        start -= 1;
        try heap.sift(start, items.len);
    }
    var end = items.len;
    while (end > 1) {
        try work.chargeBounded(1);
        end -= 1;
        std.mem.swap(T, &items[0], &items[end]);
        try heap.sift(0, end);
    }
}

const Slot = struct {
    schema: p.Id,
    old: p.Id,
    fn less(_: void, a: Slot, b: Slot) bool {
        return if (a.schema == b.schema) a.old < b.old else a.schema < b.schema;
    }
};
const Shape = struct { old: p.Id, height: usize, children: []const p.Id = &.{} };

test "bounded custody sorting compares child ranks only through their common prefix" {
    const wide: [256]p.Id = @splat(1);
    var shapes: [32]Shape = undefined;
    for (&shapes, 0..) |*shape, index| shape.* = .{
        .old = shapes.len - index,
        .height = 1,
        .children = if (index == 0) &wide else wide[0..1],
    };
    var expected = shapes;
    std.mem.sort(Shape, &expected, {}, ScopeTree.lessShape);
    var shared: u64 = 1024;
    var work: graph.Work = .{ .remaining = &shared };
    try sorted(Shape, &shapes, {}, ScopeTree.lessShape, &work, ScopeTree.lessShapeMetered);
    try std.testing.expectEqualDeep(expected, shapes);
    try std.testing.expect(shared < 1024);
    const differing: [256]p.Id = @splat(2);
    shared = 1;
    try std.testing.expectEqual(.lt, try ScopeTree.orderRanks(&work, &wide, &differing));
    try std.testing.expectEqual(0, shared);
    try std.testing.expectError(error.WorkLimit, ScopeTree.orderRanks(&work, &wide, &wide));
    try std.testing.expect(work.exhausted and !work.local_exhausted);
    var local: graph.Work = .{ .limit = 1, .compact_refinement = true };
    try std.testing.expectError(
        error.WorkLimit,
        sorted(Shape, &shapes, {}, ScopeTree.lessShape, &local, ScopeTree.lessShapeMetered),
    );
    try std.testing.expect(local.local_exhausted);
}

const ScopeTree = struct {
    allocator: std.mem.Allocator,
    work: *graph.Work,
    children: []std.ArrayList(p.Id),
    shapes: []Shape,
    ranks: []p.Id,

    fn init(
        a: std.mem.Allocator,
        scopes: []const ir.CustodyScope,
        work: *graph.Work,
    ) Error!ScopeTree {
        try work.chargeBounded(scopes.len);
        const children = try a.alloc(std.ArrayList(p.Id), scopes.len);
        @memset(children, .empty);
        const shapes = try a.alloc(Shape, scopes.len);
        const heights = try a.alloc(usize, scopes.len);
        @memset(heights, 0);
        var cursor = scopes.len;
        while (cursor != 0) {
            cursor -= 1;
            try work.charge(1);
            if (scopes[cursor].parent) |parent| {
                if (parent >= cursor) return error.InvalidReference;
                const index: usize = @intCast(parent);
                heights[index] = @max(heights[index], heights[cursor] + 1);
                try work.append(a, &children[index], cursor);
            } else if (cursor != 0) return error.InvalidProgram;
            shapes[cursor] = .{ .old = cursor, .height = heights[cursor] };
        }
        try sorted(Shape, shapes, {}, lessHeight, work, null);
        return .{
            .allocator = a,
            .work = work,
            .children = children,
            .shapes = shapes,
            .ranks = try a.alloc(p.Id, scopes.len),
        };
    }
    fn rank(self: *ScopeTree) Error!void {
        var first: usize = 0;
        var next_rank: p.Id = 0;
        while (first < self.shapes.len) {
            var end = first;
            while (end < self.shapes.len and
                self.shapes[end].height == self.shapes[first].height) : (end += 1)
            {
                const shape = &self.shapes[end];
                const children = self.children[@intCast(shape.old)].items;
                try self.work.chargeBounded(1);
                const ranks = try self.allocator.alloc(p.Id, children.len);
                for (children, ranks) |child, *target| {
                    try self.work.charge(1);
                    target.* = self.ranks[@intCast(child)];
                }
                try sorted(p.Id, ranks, {}, std.sort.asc(p.Id), self.work, null);
                shape.children = ranks;
            }
            try sorted(Shape, self.shapes[first..end], {}, lessShape, self.work, lessShapeMetered);
            for (self.shapes[first..end], first..) |shape, index| {
                try self.work.charge(1);
                const different = index == first or
                    self.shapes[index - 1].children.len != shape.children.len or
                    try self.childOrder(self.shapes[index - 1].children, shape.children) != .eq;
                if (different) next_rank += 1;
                self.ranks[@intCast(shape.old)] = next_rank;
            }
            first = end;
        }
    }
    fn lessHeight(_: void, a: Shape, b: Shape) bool {
        return if (a.height == b.height) a.old < b.old else a.height < b.height;
    }
    fn lessShape(_: void, a: Shape, b: Shape) bool {
        const order = std.mem.order(p.Id, a.children, b.children);
        return if (order == .eq) a.old < b.old else order == .lt;
    }
    fn lessShapeMetered(work: *graph.Work, a: Shape, b: Shape) Error!bool {
        const order = try orderRanks(work, a.children, b.children);
        return if (order == .eq) a.old < b.old else order == .lt;
    }
    fn childOrder(self: ScopeTree, a: []const p.Id, b: []const p.Id) Error!std.math.Order {
        if (self.work.remaining == null and !self.work.compact_refinement)
            return std.mem.order(p.Id, a, b);
        return orderRanks(self.work, a, b);
    }
    fn orderRanks(work: *graph.Work, a: []const p.Id, b: []const p.Id) Error!std.math.Order {
        for (0..@min(a.len, b.len)) |i| {
            try work.chargeBounded(1);
            const order = std.math.order(a[i], b[i]);
            if (order != .eq) return order;
        }
        return std.math.order(a.len, b.len);
    }
    fn lessChild(ranks: []const p.Id, a: p.Id, b: p.Id) bool {
        const left = ranks[@intCast(a)];
        const right = ranks[@intCast(b)];
        return if (left == right) a < b else left < right;
    }
};

pub const Blocks = struct {
    allocator: std.mem.Allocator,
    work: *graph.Work,
    program: ir.Program,
    function: p.Id,
    names: std.AutoHashMapUnmanaged(p.Id, p.Id) = .empty,
    order: std.ArrayList(p.Id) = .empty,
    direct: ?[]p.Id = null,

    pub fn index(a: std.mem.Allocator, count: usize, work: *graph.Work) Error!?[]p.Id {
        if (work.remaining == null and !work.compact_refinement) return null;
        try work.chargeBounded(count);
        const result = try a.alloc(p.Id, count);
        @memset(result, r.missing);
        return result;
    }

    pub fn name(self: Blocks, id: p.Id) ?p.Id {
        if (self.direct) |slots| {
            if (id >= slots.len or slots[@intCast(id)] == r.missing) return null;
            if (self.program.blocks[@intCast(id)].function != self.function) return null;
            return slots[@intCast(id)];
        }
        return self.names.get(id);
    }

    pub fn collect(self: *Blocks) Error!void {
        if (self.function >= self.program.functions.len) return error.InvalidReference;
        _ = try self.block(self.program.functions[@intCast(self.function)].entry);
        var cursor: usize = 0;
        while (cursor < self.order.items.len) : (cursor += 1) {
            const code = self.program.blocks[@intCast(self.order.items[cursor])];
            try self.edges(ir.Terminator, code.terminator);
        }
    }
    fn block(self: *Blocks, old: p.Id) Error!p.Id {
        try self.work.charge(1);
        if (old >= self.program.blocks.len or
            self.program.blocks[@intCast(old)].function != self.function)
            return error.InvalidReference;
        if (self.direct) |slots| {
            const slot = &slots[@intCast(old)];
            if (slot.* == r.missing) {
                slot.* = self.order.items.len;
                try self.work.append(self.allocator, &self.order, old);
            }
            return slot.*;
        }
        const entry = try self.names.getOrPut(self.allocator, old);
        if (!entry.found_existing) {
            entry.value_ptr.* = self.order.items.len;
            try self.order.append(self.allocator, old);
        }
        return entry.value_ptr.*;
    }
    // Only bounded record nesting recurses, never the CFG or custody tree.
    inline fn edges(self: *Blocks, comptime T: type, value: T) Error!void {
        if (T == ir.Edge) {
            _ = try self.block(value.block);
            return;
        }
        switch (@typeInfo(T)) {
            .@"union" => switch (value) {
                inline else => |payload| try self.edges(@TypeOf(payload), payload),
            },
            .@"struct" => inline for (@typeInfo(T).@"struct".field_names) |field_name|
                try self.edges(@FieldType(T, field_name), @field(value, field_name)),
            .pointer => |info| if (info.child == ir.Edge) {
                for (value) |edge| try self.edges(ir.Edge, edge);
            },
            else => {},
        }
    }
};
