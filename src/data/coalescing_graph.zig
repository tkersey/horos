// Copyright (c) 2026 Boundary contributors. MIT license.
//! Internal finite, typed discovery graph. This module grants no Program admission.
//! Labels are supplied by the record comparison view; raw-record validation is separate.
const std = @import("std");
const wire = @import("wire.zig");
const Kind = @import("relocation.zig").Kind;

pub const Edge = struct { role: u64, target: usize };
pub const Node = struct {
    kind: Kind,
    label: []const u8,
    anchors: []const u8 = &.{},
    edges: []const Edge = &.{},
    pinned: bool = false,
};
pub const Error = std.mem.Allocator.Error || wire.Error || error{
    InvalidReference,
    InvalidRestriction,
    WorkLimit,
};
pub const Work = struct {
    /// Charged key bytes, node/edge visits, and exact comparison byte bounds.
    limit: u64 = std.math.maxInt(u64),
    units: u64 = 0,
    comparisons: u64 = 0,
    rounds: u64 = 0,
    exhausted: bool = false,

    pub fn charge(self: *Work, amount: usize) Error!void {
        const next = std.math.add(u64, self.units, amount) catch {
            self.exhausted = true;
            return error.WorkLimit;
        };
        if (next > self.limit) {
            self.exhausted = true;
            return error.WorkLimit;
        }
        self.units = next;
    }
};

const Key = struct { bytes: []const u8, original: usize };
fn less(work: *Work, left: Key, right: Key) Error!bool {
    try work.charge(1);
    try work.charge(@min(left.bytes.len, right.bytes.len));
    work.comparisons = std.math.add(u64, work.comparisons, 1) catch
        return error.WorkLimit;
    const order = std.mem.order(u8, left.bytes, right.bytes);
    return if (order == .eq) left.original < right.original else order == .lt;
}

// Iterative merge sort permits immediate work-limit failure inside comparisons.
fn sort(a: std.mem.Allocator, keys: []Key, work: *Work) Error!void {
    const temporary = try a.alloc(Key, keys.len);
    var width: usize = 1;
    while (width < keys.len) {
        var start: usize = 0;
        while (start < keys.len) {
            const middle = start + @min(width, keys.len - start);
            const end = middle + @min(width, keys.len - middle);
            var left = start;
            var right = middle;
            for (temporary[start..end]) |*target| {
                try work.charge(1);
                if (left < middle and
                    (right == end or try less(work, keys[left], keys[right])))
                {
                    target.* = keys[left];
                    left += 1;
                } else {
                    target.* = keys[right];
                    right += 1;
                }
            }
            start = end;
        }
        @memcpy(keys, temporary);
        width = if (width > keys.len / 2) keys.len else width * 2;
    }
}

/// Return lowest-original-node representatives in caller-owned storage.
/// `singletons` restricts a profile; predecessor distinctions propagate to stability.
/// Input slices never escape. No partial partition is returned on any error.
pub fn discover(
    allocator: std.mem.Allocator,
    nodes: []const Node,
    singletons: []const bool,
    work: *Work,
) Error![]usize {
    if (work.exhausted) return error.WorkLimit;
    if (singletons.len != 0 and singletons.len != nodes.len)
        return error.InvalidRestriction;
    for (nodes) |node| {
        try work.charge(1);
        for (node.edges) |edge| {
            try work.charge(1);
            if (edge.target >= nodes.len) return error.InvalidReference;
        }
    }
    const classes = try allocator.alloc(usize, nodes.len);
    errdefer allocator.free(classes);
    @memset(classes, 0);
    const next = try allocator.alloc(usize, nodes.len);
    defer allocator.free(next);
    // The first pass establishes local labels. Every later changed pass splits
    // at least one class, so at most n further passes (including stability) occur.
    var initial = true;
    var remaining = nodes.len;
    while (initial or remaining != 0) {
        try refine(allocator, nodes, singletons, classes, next, initial, work);
        work.rounds = std.math.add(u64, work.rounds, 1) catch return error.WorkLimit;
        if (!initial and std.mem.eql(usize, classes, next)) return classes;
        @memcpy(classes, next);
        if (nodes.len == 0) return classes;
        if (!initial) {
            remaining -= 1;
        }
        initial = false;
    }
    return error.InvalidRestriction;
}

fn refine(
    allocator: std.mem.Allocator,
    nodes: []const Node,
    singletons: []const bool,
    classes: []const usize,
    next: []usize,
    initial: bool,
    work: *Work,
) Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const keys = try a.alloc(Key, nodes.len);
    for (nodes, keys, 0..) |node, *key, id| {
        const pinned = node.pinned or (singletons.len != 0 and singletons[id]);
        var size: wire.Writer = .{};
        try writeKey(&size, nodes, node, id, pinned, classes, initial);
        try work.charge(size.position);
        const bytes = try a.alloc(u8, size.position);
        var writer: wire.Writer = .{ .output = bytes };
        try writeKey(&writer, nodes, node, id, pinned, classes, initial);
        key.* = .{ .bytes = bytes, .original = id };
    }
    try sort(a, keys, work);
    var representative: usize = 0;
    for (keys, 0..) |key, i| {
        try work.charge(key.bytes.len);
        if (i == 0 or !std.mem.eql(u8, keys[i - 1].bytes, key.bytes))
            representative = key.original;
        next[key.original] = representative;
    }
}

fn writeKey(
    writer: *wire.Writer,
    nodes: []const Node,
    node: Node,
    id: usize,
    pinned: bool,
    classes: []const usize,
    initial: bool,
) wire.Error!void {
    try writer.natural(if (initial) 0 else classes[id]);
    try writer.natural(@backingInt(node.kind));
    try writer.natural(node.label.len);
    try writer.put(node.label);
    try writer.natural(node.anchors.len);
    try writer.put(node.anchors);
    try writer.byte(@intFromBool(pinned));
    if (pinned) try writer.natural(id);
    try writer.natural(node.edges.len);
    for (node.edges) |edge| {
        try writer.natural(edge.role);
        try writer.natural(@backingInt(nodes[edge.target].kind));
        try writer.natural(if (initial) 0 else classes[edge.target]);
    }
}
