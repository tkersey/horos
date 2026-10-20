// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const sets = @import("analysis_sets.zig");
const testing = std.testing;

test "set overlays share immutable roots and isolate all eight-bit operations" {
    var base: sets.Pool = .{ .allocator = testing.allocator, .limit = 8 };
    defer base.deinit();
    const prefix = try base.run(0, 4);
    const frozen = try base.readOnly();
    const count = frozen.nodeCount();
    const visits = base.visits;
    var overlay = sets.Pool.overlay(testing.allocator, frozen);
    defer overlay.deinit();
    var roots: [256]sets.Root = @splat(sets.empty);
    for (&roots, 0..) |*root, bits| for (0..8) |member| {
        if ((bits & (@as(usize, 1) << @intCast(member))) != 0)
            root.* = try overlay.insert(root.*, member);
    };
    try testing.expectEqual(prefix, roots[15]);
    for (roots, 0..) |left, a| for (roots, 0..) |right, b| {
        try testing.expectEqual(roots[a | b], try overlay.unite(left, right));
        try testing.expectEqual(roots[a & b], try overlay.intersect(left, right));
        try testing.expectEqual(roots[a & (~b & 255)], try overlay.difference(left, right));
    };
    try testing.expectEqual(count, frozen.nodeCount());
    try testing.expectEqual(visits, base.visits);
    try testing.expectError(error.InvalidReference, overlay.readOnly());
    var sibling = sets.Pool.overlay(testing.allocator, frozen);
    defer sibling.deinit();
    try testing.expectEqual(0, sibling.nodeCount());
    try testing.expectEqual(@as(u8, 15), mask(&sibling, prefix));
}

test "set overlay reuse needs no allocation and failure leaves the base intact" {
    var base: sets.Pool = .{ .allocator = testing.allocator, .limit = 8 };
    defer base.deinit();
    const prefix = try base.run(0, 4);
    var empty_buffer: [0]u8 = .{};
    var buffer = std.heap.FixedBufferAllocator.init(&empty_buffer);
    var overlay = sets.Pool.overlay(buffer.allocator(), try base.readOnly());
    defer overlay.deinit();
    try testing.expectEqual(prefix, try overlay.run(0, 4));
    try testing.expectError(error.OutOfMemory, overlay.insert(prefix, 7));
    try testing.expectEqual(0, overlay.nodeCount());
    try testing.expectEqual(@as(u8, 15), mask(&overlay, prefix));
    try testing.expectEqual(@as(u8, 15), mask(&base, prefix));
}

fn mask(pool: *sets.Pool, root: sets.Root) u8 {
    var result: u8 = 0;
    var iterator = pool.iterator(root);
    while (iterator.next()) |member| result |= @as(u8, 1) << @intCast(member);
    return result;
}

test "analysis sets agree with every pair of eight-bit sets" {
    var pool: sets.Pool = .{ .allocator = testing.allocator, .limit = 8 };
    defer pool.deinit();
    var roots: [256]sets.Root = @splat(sets.empty);
    for (&roots, 0..) |*root, bits| {
        for (0..8) |member| if ((bits & (@as(usize, 1) << @intCast(member))) != 0) {
            root.* = try pool.insert(root.*, member);
        };
        try testing.expectEqual(@as(u8, @intCast(bits)), mask(&pool, root.*));
    }
    for (roots, 0..) |left, a| {
        for (roots, 0..) |right, b| {
            try testing.expectEqual(roots[a | b], try pool.unite(left, right));
            try testing.expectEqual(roots[a & b], try pool.intersect(left, right));
            try testing.expectEqual(roots[a & (~b & 255)], try pool.difference(left, right));
        }
        for (0..8) |member| {
            const bit = @as(usize, 1) << @intCast(member);
            try testing.expectEqual(roots[a & ~bit], try pool.remove(left, member));
            try testing.expectEqual((a & bit) != 0, pool.contains(left, member));
        }
    }
}

test "analysis sets encode every monotonic prefix with bounded incremental nodes" {
    var pool: sets.Pool = .{ .allocator = testing.allocator, .limit = 4096 };
    defer pool.deinit();
    var root = sets.empty;
    for (0..4096) |member| {
        const before = pool.nodeCount();
        root = try pool.insert(root, member);
        try testing.expect(pool.nodeCount() - before <= 2);
        try testing.expectEqual(member + 1, pool.count(root));
    }
    try testing.expect(pool.visits <= 4096);
    const original = root;
    for (0..4096) |member| root = try pool.remove(root, member);
    try testing.expectEqual(sets.empty, root);
    try testing.expectEqual(4096, pool.count(original));
}

test "analysis sets handle high IDs and bounds without input-sized recursion" {
    var pool: sets.Pool = .{ .allocator = testing.allocator, .limit = std.math.maxInt(u64) };
    defer pool.deinit();
    const high = pool.limit - 1;
    const all = try pool.run(0, pool.limit);
    const middle = try pool.remove(all, @as(u64, 1) << 63);
    try testing.expectEqual(pool.limit - 1, pool.count(middle));
    try testing.expect(!pool.contains(middle, @as(u64, 1) << 63));
    try testing.expect(pool.contains(middle, high));
    try testing.expectError(error.InvalidReference, pool.insert(all, pool.limit));
    try testing.expectEqual(all, try pool.insert(middle, @as(u64, 1) << 63));
}

test "full-width sparse trees preserve every set operation and prior roots" {
    var pool: sets.Pool = .{ .allocator = testing.allocator, .limit = std.math.maxInt(u64) };
    defer pool.deinit();
    var all = sets.empty;
    var even = sets.empty;
    var odd = sets.empty;
    for (0..64) |bit| {
        const member = @as(u64, 1) << @intCast(bit);
        all = try pool.insert(all, member);
        if (bit % 2 ==
            0)
            even =
                try pool.insert(even, member)
        else
            odd =
                try pool.insert(odd, member);
    }
    try testing.expectEqual(64, pool.count(all));
    try testing.expectEqual(32, pool.count(even));
    try testing.expectEqual(32, pool.count(odd));
    try testing.expectEqual(all, try pool.unite(even, odd));
    try testing.expectEqual(even, try pool.difference(all, odd));
    try testing.expectEqual(odd, try pool.difference(all, even));
    try testing.expectEqual(sets.empty, try pool.intersect(even, odd));
    try testing.expectEqual(even, try pool.intersect(all, even));
    var remaining = all;
    for (0..64) |bit| {
        const member = @as(u64, 1) << @intCast(bit);
        remaining = try pool.remove(remaining, member);
        try testing.expectEqual(63 - bit, pool.count(remaining));
        try testing.expect(!pool.contains(remaining, member));
        try testing.expect(pool.contains(all, member));
    }
    try testing.expectEqual(sets.empty, remaining);
    try testing.expectEqual(64, pool.count(all));
}

fn failureCase(allocator: std.mem.Allocator) !void {
    var pool: sets.Pool = .{ .allocator = allocator, .limit = 32 };
    defer pool.deinit();
    const before = try pool.run(0, 16);
    const changed = pool.remove(before, 7) catch |err| {
        try testing.expectEqual(16, pool.count(before));
        try testing.expect(pool.contains(before, 7));
        return err;
    };
    try testing.expectEqual(15, pool.count(changed));
    try testing.expectEqual(16, pool.count(before));
    const bytes = try pool.materialize(allocator, changed);
    defer allocator.free(bytes);
    try testing.expectEqual(15, bytes.len);
}

test "analysis sets preserve prior roots and ownership through allocation failures" {
    try @import("allocation_testing.zig").check(testing.allocator, failureCase, .{});
}

test "low-word projection matches membership without allocating or changing shared roots" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var base: sets.Pool = .{ .allocator = failing.allocator(), .limit = std.math.maxInt(u64) };
    defer base.deinit();
    for (0..81) |low| for (low..81) |high| {
        const root = try base.run(low, high);
        var expected: u64 = 0;
        for (0..64) |bit| if (low <= bit and bit < high) {
            expected |= @as(u64, 1) << @intCast(bit);
        };
        try testing.expectEqual(expected, base.lowWord(root));
    };
    const far = try base.run(60, std.math.maxInt(u64));
    const frozen = try base.readOnly();
    const base_nodes = frozen.nodeCount();
    var overlay = sets.Pool.overlay(failing.allocator(), frozen);
    defer overlay.deinit();
    const members = [_]u64{ 0, 1, 7, 31, 32, 63, 64, std.math.maxInt(u64) - 1 };
    var roots: [256]sets.Root = undefined;
    for (&roots, 0..) |*root, subset| {
        root.* = sets.empty;
        for (members, 0..) |member, bit| if (subset & (@as(usize, 1) << @intCast(bit)) != 0) {
            root.* = try overlay.insert(root.*, member);
        };
    }
    var ladder = try overlay.insert(sets.empty, 0);
    for (0..64) |bit| ladder = try overlay.insert(ladder, @as(u64, 1) << @intCast(bit));
    const overlay_nodes = overlay.nodeCount();
    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(@as(u64, 0x100010117), overlay.lowWord(ladder));
    try testing.expectEqual(@as(u64, 0xf000000000000000), overlay.lowWord(far));
    for (roots) |root| {
        var expected: u64 = 0;
        for (0..64) |bit| if (overlay.contains(root, bit)) {
            expected |= @as(u64, 1) << @intCast(bit);
        };
        try testing.expectEqual(expected, overlay.lowWord(root));
    }
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(base_nodes, frozen.nodeCount());
    try testing.expectEqual(overlay_nodes, overlay.nodeCount());
}

test "canonical word leaves preserve all cross-word subsets and high-ID operations" {
    const maximum = std.math.maxInt(u64);
    const offsets = [_]u64{ 0, 31, 63, 64, 65, 95, 127, 128 };
    for ([_]u64{ 0, 1, 64, maximum - 256 }) |base| {
        var pool: sets.Pool = .{ .allocator = testing.allocator, .limit = maximum };
        defer pool.deinit();
        var roots: [256]sets.Root = @splat(sets.empty);
        for (&roots, 0..) |*root, bits| {
            for (offsets, 0..) |offset, bit| if (bits & (@as(usize, 1) << @intCast(bit)) != 0) {
                root.* = try pool.insert(root.*, base + offset);
            };
            var reverse = sets.empty;
            var index = offsets.len;
            while (index > 0) {
                index -= 1;
                if (bits & (@as(usize, 1) << @intCast(index)) != 0)
                    reverse = try pool.insert(reverse, base + offsets[index]);
            }
            try testing.expectEqual(root.*, reverse);
            var iterator = pool.iterator(root.*);
            for (offsets, 0..) |offset, bit| {
                const present = bits & (@as(usize, 1) << @intCast(bit)) != 0;
                try testing.expectEqual(present, pool.contains(root.*, base + offset));
                if (present) try testing.expectEqual(base + offset, iterator.next().?);
            }
            try testing.expect(iterator.next() == null);
        }
        const frozen = try pool.readOnly();
        const node_count = frozen.nodeCount();
        var overlay = sets.Pool.overlay(testing.allocator, frozen);
        defer overlay.deinit();
        for (roots, 0..) |left, a| for (roots, 0..) |right, b| {
            try testing.expectEqual(roots[a | b], try overlay.unite(left, right));
            try testing.expectEqual(roots[a & b], try overlay.intersect(left, right));
            try testing.expectEqual(roots[a & (~b & 255)], try overlay.difference(left, right));
        };
        try testing.expectEqual(node_count, frozen.nodeCount());
        try testing.expectEqual(0, overlay.nodeCount());
    }
}

test "bounded set storage preserves members and overlay roots at the 32-bit limit" {
    const boundary: u64 = std.math.maxInt(u32);
    for ([_]u64{ boundary - 1, boundary, boundary + 1, std.math.maxInt(u64) }) |limit| {
        var pool: sets.Pool = .{ .allocator = testing.allocator, .limit = limit };
        defer pool.deinit();
        const tail = try pool.run(limit - 2, limit);
        const root = try pool.insert(tail, 0);
        try testing.expectEqual(3, pool.count(root));
        var values = pool.iterator(root);
        for ([_]u64{ 0, limit - 2, limit - 1 }) |expected|
            try testing.expectEqual(expected, values.next().?);
        try testing.expect(values.next() == null);
        var overlay = sets.Pool.overlay(testing.allocator, try pool.readOnly());
        defer overlay.deinit();
        try testing.expectEqual(tail, try overlay.remove(root, 0));
        const changed = try overlay.remove(root, limit - 1);
        try testing.expectEqual(2, overlay.count(changed));
        try testing.expect(pool.contains(root, limit - 1));
        try testing.expect(!overlay.contains(changed, limit - 1));
        try testing.expectError(error.InvalidReference, overlay.insert(root, limit));
    }
}

test "set backing accounting follows live buffers through growth and release" {
    var tracked = testing.FailingAllocator.init(testing.allocator, .{});
    var pool: sets.Pool = .{ .allocator = tracked.allocator(), .limit = 4096 };
    for (0..4096) |i| {
        _ = try pool.run(i, i + 1);
        try testing.expectEqual(tracked.allocated_bytes - tracked.freed_bytes, pool.storageBytes());
    }
    try testing.expect(tracked.freed_bytes > 0);
    pool.deinit();
    try testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
}

test "local intern hits allocate nothing at node or table capacity" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var pool: sets.Pool = .{ .allocator = failing.allocator(), .limit = 4096 };
    defer pool.deinit();
    var checked_nodes = false;
    var checked_table = false;
    const first = try pool.run(0, 1);
    for (1..256) |i| {
        _ = try pool.run(i, i + 1);
        const nodes_full = pool.nodeCount() == pool.nodeCapacity();
        const table_full = pool.interned.available == 0;
        if (nodes_full or table_full) {
            const count = pool.nodeCount();
            failing.fail_index = failing.alloc_index;
            try testing.expectEqual(first, try pool.run(0, 1));
            try testing.expectEqual(count, pool.nodeCount());
            try testing.expect(!failing.has_induced_failure);
            failing.fail_index = std.math.maxInt(usize);
            checked_nodes = checked_nodes or nodes_full;
            checked_table = checked_table or table_full;
        }
    }
    try testing.expect(checked_nodes and checked_table);
}

test "direct insertion agrees with independent union across range and word boundaries" {
    const maximum = std.math.maxInt(u64);
    var pool: sets.Pool = .{ .allocator = testing.allocator, .limit = maximum };
    defer pool.deinit();
    for ([_]u64{ 0, 63, 1 << 32, maximum - 256 }) |base| {
        const low = base + 3;
        for ([_]u64{ 1, 63, 64, 65, 129 }) |length| {
            const before = try pool.run(low, low + length);
            for ([_]u64{ 0, 1, 31, 63, 64, 127, 128, 192, 255 }) |offset| {
                const member = base + offset;
                if (member >= maximum) continue;
                const expected = try pool.unite(before, try pool.run(member, member + 1));
                const actual = try pool.insert(before, member);
                try testing.expectEqual(expected, actual);
                try testing.expectEqual(length, pool.count(before));
                try testing.expect(pool.contains(actual, member));
                try testing.expectEqual(
                    length + @intFromBool(member < low or member >= low + length),
                    pool.count(actual),
                );
            }
        }
    }
}

fn directInsertFailure(allocator: std.mem.Allocator) !void {
    var base: sets.Pool = .{ .allocator = testing.allocator, .limit = std.math.maxInt(u64) };
    defer base.deinit();
    const before = try base.run(3, 132);
    const frozen = try base.readOnly();
    const count = frozen.nodeCount();
    var overlay = sets.Pool.overlay(allocator, frozen);
    defer overlay.deinit();
    const changed = overlay.insert(before, 0) catch |err| {
        try testing.expectEqual(count, frozen.nodeCount());
        try testing.expectEqual(129, base.count(before));
        try testing.expect(!base.contains(before, 0));
        return err;
    };
    try testing.expectEqual(130, overlay.count(changed));
    try testing.expect(overlay.contains(changed, 0));
    try testing.expectEqual(count, frozen.nodeCount());
    try testing.expectEqual(129, base.count(before));
}
test "direct insertion failures preserve the immutable base and release local backing" {
    try @import("allocation_testing.zig").check(testing.allocator, directInsertFailure, .{});
}
