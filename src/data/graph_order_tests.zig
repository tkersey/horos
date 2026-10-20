const std = @import("std");
const g = @import("graph.zig");
const s = @import("process_state.zig");
const order = @import("graph_order.zig");

fn detachedAllocationCase(allocator: std.mem.Allocator) !void {
    var detached: [1024]g.OwnedRef = undefined;
    var nodes: [1024]s.Node = undefined;
    for (&detached, &nodes, 0..) |*root, *node, id| {
        root.* = .{ .node = .{ .id = id } };
        node.* = .{ .record = .{ .environment = .{ .values = &.{}, .tail = null } } };
    }
    var normalized = try order.canonicalize(allocator, s.State{
        .program_identity = @as([32]u8, @splat(0)),
        .status = .active,
        .roots = .{ .detached = &detached },
        .nodes = &nodes,
    }, null);
    defer normalized.deinit();
    try std.testing.expectEqual(detached.len, normalized.state.roots.detached.len);
    try std.testing.expectEqual(nodes.len, normalized.state.nodes.len);
}

test "canonical graph owner retains final detached-root allocations" {
    try @import("allocation_testing.zig").check(std.testing.allocator, detachedAllocationCase, .{});
}

fn scratchLifetimeCase(allocator: std.mem.Allocator) !void {
    var payload = [_]u8{ 1, 2, 3, 4 };
    const values = [_]g.Value{
        .{ .schema = 0, .body = .{ .blob = .{ .id = 0 } } },
        .{ .schema = 0, .body = .{ .blob = .{ .id = 1 } } },
    };
    const nodes = [_]s.Node{
        .{ .record = .{ .environment = .{ .values = &values, .tail = .{ .id = 1 } } } },
        .{ .record = .{ .environment = .{ .values = &values, .tail = .{ .id = 0 } } } },
    };
    var normalized = try order.canonicalize(allocator, s.State{
        .program_identity = @as([32]u8, @splat(0)),
        .status = .active,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &nodes,
        .blobs = &.{ .{ .schema = 0, .bytes = &payload }, .{ .schema = 0, .bytes = &payload } },
    }, null);
    defer normalized.deinit();
    @memset(&payload, 0xa5);
    try std.testing.expectEqual(@as(usize, 2), normalized.state.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), normalized.state.blobs.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, normalized.state.blobs[0].bytes);
    try std.testing.expectEqual(
        @as(u64, 0),
        normalized.state.nodes[1].record.environment.tail.?.id,
    );
}

test "snapshot scratch release preserves owned payloads, cycles and distinct nodes" {
    try @import("allocation_testing.zig").check(std.testing.allocator, scratchLifetimeCase, .{});
}
