// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independent pair-deletion oracle for the finite discovery graph only.
const std = @import("std");
const testing = std.testing;
const graph = @import("coalescing_graph.zig");
const Node = graph.Node;
const Edge = graph.Edge;

fn possible(a: Node, b: Node, same: bool) bool {
    if (a.kind != b.kind or ((a.pinned or b.pinned) and !same)) return false;
    if (!std.mem.eql(u8, a.label, b.label) or
        !std.mem.eql(u8, a.anchors, b.anchors) or a.edges.len != b.edges.len)
        return false;
    for (a.edges, b.edges) |left, right| if (left.role != right.role) return false;
    return true;
}

fn oracle(a: std.mem.Allocator, nodes: []const Node) ![]bool {
    const n = nodes.len;
    const pairs = try a.alloc(bool, try std.math.mul(usize, n, n));
    for (nodes, 0..) |left, i| for (nodes, 0..) |right, j| {
        pairs[i * n + j] = possible(left, right, i == j);
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (nodes, 0..) |left, i| for (nodes, 0..) |right, j| {
            if (!pairs[i * n + j]) continue;
            for (left.edges, right.edges) |x, y| if (!pairs[x.target * n + y.target]) {
                pairs[i * n + j] = false;
                changed = true;
                break;
            };
        };
    }
    return pairs;
}

fn check(nodes: []const Node) !void {
    var work: graph.Work = .{};
    const classes = try graph.discover(testing.allocator, nodes, &.{}, &work);
    defer testing.allocator.free(classes);
    const expected = try oracle(testing.allocator, nodes);
    defer testing.allocator.free(expected);
    for (classes, 0..) |x, i| {
        try testing.expectEqual(x, classes[x]);
        try testing.expect(x <= i);
        for (classes, 0..) |y, j|
            try testing.expectEqual(expected[i * nodes.len + j], x == y);
    }
    try checkQuotient(nodes, classes);
}

fn checkQuotient(nodes: []const Node, classes: []const usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dense = try a.alloc(usize, nodes.len);
    var reduced: std.ArrayList(Node) = .empty;
    for (nodes, 0..) |node, i| if (classes[i] == i) {
        dense[i] = reduced.items.len;
        try reduced.append(a, node);
    };
    for (classes, 0..) |representative, i| dense[i] = dense[representative];
    for (reduced.items) |*node| {
        const edges = try a.dupe(Edge, node.edges);
        for (edges) |*edge| edge.target = dense[edge.target];
        node.edges = edges;
    }
    var work: graph.Work = .{};
    const second = try graph.discover(testing.allocator, reduced.items, &.{}, &work);
    defer testing.allocator.free(second);
    for (second, 0..) |representative, i| try testing.expectEqual(i, representative);
}

test "coalescing discovery matches independent oracle on all 4330 unary binary-label graphs" {
    var total: usize = 0;
    var nodes: [4]Node = undefined;
    var edges: [4][1]Edge = undefined;
    for (1..5) |n| {
        const label_count = std.math.pow(usize, 2, n);
        const edge_count = std.math.pow(usize, n, n);
        for (0..label_count) |labels| for (0..edge_count) |targets| {
            var remaining = targets;
            for (0..n) |i| {
                edges[i][0] = .{ .role = 0, .target = remaining % n };
                remaining /= n;
                nodes[i] = .{
                    .kind = .function,
                    .label = if ((labels >> @intCast(i)) & 1 == 0) "0" else "1",
                    .edges = &edges[i],
                };
            }
            try check(nodes[0..n]);
            total += 1;
        };
    }
    try testing.expectEqual(@as(usize, 4330), total);
}

test "coalescing discovery matches oracle on 500 seeded typed anchored and pinned graphs" {
    var rng = std.Random.DefaultPrng.init(20260925);
    const random = rng.random();
    var nodes: [12]Node = undefined;
    var edges: [12][3]Edge = undefined;
    const labels = [_][]const u8{ "0", "1", "2" };
    const kinds = [_]@import("relocation.zig").Kind{ .function, .constructor, .handler };
    for (0..500) |_| {
        const n = random.intRangeAtMost(usize, 1, nodes.len);
        for (0..n) |i| {
            const arity = random.intRangeAtMost(usize, 0, 3);
            for (edges[i][0..arity], 0..) |*edge, role|
                edge.* = .{ .role = role, .target = random.uintLessThan(usize, n) };
            nodes[i] = .{
                .kind = kinds[random.uintLessThan(usize, kinds.len)],
                .label = labels[random.uintLessThan(usize, labels.len)],
                .anchors = labels[random.uintLessThan(usize, labels.len)],
                .edges = edges[i][0..arity],
                .pinned = random.uintLessThan(u8, 7) == 0,
            };
        }
        try check(nodes[0..n]);
    }
}

test "coalescing profile singleton restriction propagates to parents and recursive peers" {
    const nodes = [_]Node{
        .{ .kind = .function, .label = "parent", .edges = &.{.{ .role = 0, .target = 2 }} },
        .{ .kind = .function, .label = "parent", .edges = &.{.{ .role = 0, .target = 3 }} },
        .{ .kind = .function, .label = "leaf" },
        .{ .kind = .function, .label = "leaf" },
    };
    var work: graph.Work = .{};
    const full = try graph.discover(testing.allocator, &nodes, &.{}, &work);
    defer testing.allocator.free(full);
    try testing.expectEqualSlices(usize, &.{ 0, 0, 2, 2 }, full);
    const restricted = try graph.discover(
        testing.allocator,
        &nodes,
        &.{ false, false, true, true },
        &work,
    );
    defer testing.allocator.free(restricted);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, restricted);
    const recursive = [_]Node{
        .{ .kind = .function, .label = "even", .edges = &.{.{ .role = 0, .target = 1 }} },
        .{ .kind = .function, .label = "odd", .edges = &.{.{ .role = 0, .target = 0 }} },
        .{ .kind = .function, .label = "even", .edges = &.{.{ .role = 0, .target = 3 }} },
        .{ .kind = .function, .label = "odd", .edges = &.{.{ .role = 0, .target = 2 }} },
    };
    try check(&recursive);
    const folded = try graph.discover(testing.allocator, &recursive, &.{}, &work);
    defer testing.allocator.free(folded);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 0, 1 }, folded);
}

fn allocationCase(a: std.mem.Allocator) !void {
    var work: graph.Work = .{};
    const nodes = [_]Node{
        .{ .kind = .function, .label = "same", .edges = &.{.{ .role = 0, .target = 1 }} },
        .{ .kind = .function, .label = "same", .edges = &.{.{ .role = 0, .target = 0 }} },
    };
    const classes = try graph.discover(a, &nodes, &.{}, &work);
    defer a.free(classes);
    try testing.expectEqualSlices(usize, &.{ 0, 0 }, classes);
}

test "coalescing discovery releases every partial allocation" {
    try @import("allocation_testing.zig").check(testing.allocator, allocationCase, .{});
}

test "coalescing work accounting rejects overflow without wrapping or publishing extra units" {
    var work: graph.Work = .{ .units = std.math.maxInt(u64) - 1 };
    try work.charge(1);
    try testing.expectEqual(std.math.maxInt(u64), work.units);
    try testing.expectError(error.WorkLimit, work.charge(1));
    try testing.expect(work.exhausted);
    try testing.expectEqual(std.math.maxInt(u64), work.units);
    work = .{ .limit = 3, .units = 2 };
    try testing.expectError(error.WorkLimit, work.charge(2));
    try testing.expectEqual(@as(u64, 2), work.units);
}

test "coalescing discovery rejects invalid references restrictions and exhausted work" {
    var work: graph.Work = .{};
    const bad = [_]Node{.{
        .kind = .function,
        .label = "",
        .edges = &.{.{ .role = 0, .target = 1 }},
    }};
    try testing.expectError(
        error.InvalidReference,
        graph.discover(testing.allocator, &bad, &.{}, &work),
    );
    try testing.expectError(
        error.InvalidRestriction,
        graph.discover(testing.allocator, &bad, &.{ false, true }, &work),
    );
    work = .{ .limit = 0 };
    try testing.expectError(error.WorkLimit, graph.discover(testing.allocator, &bad, &.{}, &work));
    work = .{};
    const empty = try graph.discover(testing.allocator, &.{}, &.{}, &work);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
