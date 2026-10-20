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
            try self.slot_order.append(self.allocator, old);
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
            try chain.append(self.allocator, cursor);
            const parent = self.function.custody[@intCast(cursor)].parent orelse break;
            if (parent >= cursor) return error.InvalidReference;
            cursor = parent;
        }
        while (chain.pop()) |id| {
            self.custody[@intCast(id)] = self.scope_order.items.len;
            try self.scope_order.append(self.allocator, id);
        }
        return self.custody[@intCast(old)];
    }
    pub fn complete(self: *Names, schemas: []const p.Id) Error!void {
        var remaining: std.ArrayList(Slot) = .empty;
        for (self.function.layout.slots, self.slots, 0..) |schema, name, old| {
            try self.work.charge(1);
            if (schema >= schemas.len) return error.InvalidReference;
            if (name == r.missing) try remaining.append(
                self.allocator,
                .{ .schema = schemas[@intCast(schema)], .old = old },
            );
        }
        std.mem.sort(Slot, remaining.items, {}, Slot.less);
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
            std.mem.sort(p.Id, children, @as([]const p.Id, tree.ranks), ScopeTree.lessChild);
            for (children) |child| {
                try self.work.charge(1);
                if (self.custody[@intCast(child)] == r.missing) _ = try self.scope(child);
            }
        }
        if (self.scope_order.items.len != n) return error.InvalidProgram;
    }
};

const Slot = struct {
    schema: p.Id,
    old: p.Id,
    fn less(_: void, a: Slot, b: Slot) bool {
        return if (a.schema == b.schema) a.old < b.old else a.schema < b.schema;
    }
};
const Shape = struct { old: p.Id, height: usize, children: []const p.Id = &.{} };
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
                try children[index].append(a, cursor);
            } else if (cursor != 0) return error.InvalidProgram;
            shapes[cursor] = .{ .old = cursor, .height = heights[cursor] };
        }
        std.mem.sort(Shape, shapes, {}, lessHeight);
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
                const ranks = try self.allocator.alloc(p.Id, children.len);
                for (children, ranks) |child, *target| {
                    try self.work.charge(1);
                    target.* = self.ranks[@intCast(child)];
                }
                std.mem.sort(p.Id, ranks, {}, std.sort.asc(p.Id));
                shape.children = ranks;
            }
            std.mem.sort(Shape, self.shapes[first..end], {}, lessShape);
            for (self.shapes[first..end], first..) |shape, index| {
                try self.work.charge(1);
                const different = index == first or
                    !std.mem.eql(p.Id, self.shapes[index - 1].children, shape.children);
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
