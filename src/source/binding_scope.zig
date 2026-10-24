// Copyright (c) 2026 Boundary contributors. MIT license.
//! Persistent lexical lookup. Extending one scope copies only a binary search
//! path; a lookup never walks the history of preceding source bindings.
const std = @import("std");
const Id = @import("horos_data").program.Id;
pub const empty = std.math.maxInt(Id);
const Node = struct { left: Id, right: Id };
pub const Error = std.mem.Allocator.Error || error{ UnboundVariable, RelationLimit };

pub const Scopes = struct {
    allocator: std.mem.Allocator,
    work: ?*u64 = null,
    name_count: usize,
    nodes: std.ArrayList(Node) = .empty,

    pub fn deinit(self: *Scopes) void {
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn bind(self: *Scopes, root: Id, name: Id, value: Id) Error!Id {
        if (name >= self.name_count) return error.UnboundVariable;
        // Local failed insertions cannot publish a partial successor root.
        const start = self.nodes.items.len;
        errdefer self.nodes.shrinkRetainingCapacity(start);
        return self.insert(root, 0, self.name_count, @intCast(name), value);
    }

    const Path = struct { node: Node, right: bool };

    fn insert(self: *Scopes, root: Id, low: usize, high: usize, name: usize, value: Id) Error!Id {
        var path: [@bitSizeOf(usize)]Path = undefined;
        var depth: usize = 0;
        var current = root;
        var lower = low;
        var upper = high;
        while (upper - lower > 1) {
            try @import("horos_data").admission.spend(self.work, 1);
            const node: Node = if (current == empty)
                .{ .left = empty, .right = empty }
            else
                self.nodes.items[@intCast(current)];
            const middle = lower + (upper - lower) / 2;
            const right = name >= middle;
            std.debug.assert(depth < path.len);
            path[depth] = .{ .node = node, .right = right };
            depth += 1;
            if (right) {
                current = node.right;
                lower = middle;
            } else {
                current = node.left;
                upper = middle;
            }
        }
        try @import("horos_data").admission.spend(self.work, depth + 1);
        var id = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{ .left = value, .right = empty });
        while (depth != 0) {
            depth -= 1;
            var entry = path[depth];
            if (entry.right) entry.node.right = id else entry.node.left = id;
            id = self.nodes.items.len;
            try self.nodes.append(self.allocator, entry.node);
        }
        return id;
    }

    pub fn resolve(self: *const Scopes, root: Id, name: Id) Error!Id {
        if (name >= self.name_count) return error.UnboundVariable;
        var current = root;
        var low: usize = 0;
        var high = self.name_count;
        while (current != empty) {
            try @import("horos_data").admission.spend(self.work, 1);
            const node = self.nodes.items[@intCast(current)];
            if (high - low == 1) return node.left;
            const middle = low + (high - low) / 2;
            if (name < middle) {
                current = node.left;
                high = middle;
            } else {
                current = node.right;
                low = middle;
            }
        }
        return error.UnboundVariable;
    }
};

test "lexical scope extension isolates old branches with bounded path copies" {
    var scopes: Scopes = .{ .allocator = std.testing.allocator, .name_count = 1024 };
    defer scopes.deinit();
    const original = try scopes.bind(empty, 21, 9);
    const left = try scopes.bind(original, 21, 17);
    const right = try scopes.bind(original, 1000, 31);
    try std.testing.expectEqual(9, try scopes.resolve(original, 21));
    try std.testing.expectEqual(17, try scopes.resolve(left, 21));
    try std.testing.expectEqual(9, try scopes.resolve(right, 21));
    try std.testing.expectEqual(31, try scopes.resolve(right, 1000));
    try std.testing.expectError(error.UnboundVariable, scopes.resolve(left, 1000));
    try std.testing.expectEqual(33, scopes.nodes.items.len);
}

test "empty lexical scope rejects every name" {
    var scopes: Scopes = .{ .allocator = std.testing.allocator, .name_count = 0 };
    defer scopes.deinit();
    try std.testing.expectError(error.UnboundVariable, scopes.bind(empty, 0, 7));
    try std.testing.expectError(error.UnboundVariable, scopes.resolve(empty, 0));
}

fn failedInsertion(allocator: std.mem.Allocator) !void {
    var scopes: Scopes = .{ .allocator = allocator, .name_count = 1024 };
    defer scopes.deinit();
    const original = try scopes.bind(empty, 21, 9);
    const count = scopes.nodes.items.len;
    const successor = scopes.bind(original, 21, 17) catch |err| {
        try std.testing.expectEqual(count, scopes.nodes.items.len);
        try std.testing.expectEqual(9, try scopes.resolve(original, 21));
        return err;
    };
    try std.testing.expectEqual(9, try scopes.resolve(original, 21));
    try std.testing.expectEqual(17, try scopes.resolve(successor, 21));
}

test "lexical scope insertion preserves earlier roots at every allocation failure" {
    try @import("../allocation_testing.zig").check(std.testing.allocator, failedInsertion, .{});
}
