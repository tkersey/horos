// Copyright (c) 2026 Boundary contributors. MIT license.
//! Ordered graph discovery shared by portable record families, never evaluation.
const std = @import("std");
const g = @import("graph.zig");
pub const Error = @import("record.zig").Error || error{ InvalidReference, InvalidState };
const absent = std.math.maxInt(u64);

test {
    _ = @import("graph_order_tests.zig");
}
pub const Reference = union(enum) { node: u64, blob: u64 };

/// Optional work counters. Graph discovery is distinct from the flat remapping
/// pass and byte interning; none of these observations is part of wire identity.
pub const Statistics = struct {
    nodes: u64 = 0,
    edges: u64 = 0,
    blobs: u64 = 0,
    remapped_nodes: u64 = 0,
    stored_payload_bytes: u64 = 0,
    interning_hash_bytes: u64 = 0,
    interning_comparisons: u64 = 0,
};

pub fn Owned(comptime State: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        state: State,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Normalizes irrelevant IDs and interns blobs; distinct nodes never merge.
/// The returned owner retains every byte, including the immutable blob payloads.
pub fn canonicalize(
    allocator: std.mem.Allocator,
    state: anytype,
    statistics: ?*Statistics,
) Error!Owned(@TypeOf(state)) {
    const State = @TypeOf(state);
    const Node = std.meta.Elem(@TypeOf(state.nodes));
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const plan = try discover(scratch, state, statistics);
    const node_map = plan.node_map;
    const blob_map = plan.blob_map;
    const nodes = try storage.alloc(Node, plan.order.len);
    for (nodes, plan.order) |*node, original| {
        node.* = try remap(Node, state.nodes[original], node_map, blob_map, storage);
        if (statistics) |s| s.remapped_nodes +|= 1;
    }
    const blobs = try storage.alloc(g.Blob, plan.blobs.len);
    for (
        blobs,
        plan.blobs,
    ) |*target, source| target.* = .{
        .schema = source.schema,
        .bytes = try storage.dupe(u8, source.bytes),
    };
    const canonical_state: State = .{
        .program_identity = state.program_identity,
        .status = state.status,
        .roots = try remap(g.Roots, state.roots, node_map, blob_map, storage),
        .nodes = nodes,
        .blobs = blobs,
    };
    return .{ .arena = arena, .state = canonical_state };
}

const Discovery = struct {
    node_map: []const u64,
    blob_map: []const u64,
    order: []const usize,
    blobs: []const g.Blob,
};
fn discover(scratch: std.mem.Allocator, state: anytype, statistics: ?*Statistics) Error!Discovery {
    const Node = std.meta.Elem(@TypeOf(state.nodes));
    const node_map = try scratch.alloc(u64, state.nodes.len);
    const blob_map = try scratch.alloc(u64, state.blobs.len);
    @memset(node_map, absent);
    @memset(blob_map, absent);
    var order: std.ArrayList(usize) = .empty;
    var blobs: std.ArrayList(g.Blob) = .empty;
    var interned: std.HashMapUnmanaged(g.Blob, usize, BlobContext, 80) = .empty;
    var pending: std.ArrayList(Reference) = .empty;
    var children: std.ArrayList(Reference) = .empty;
    try references(g.Roots, state.roots, &children, scratch);
    if (statistics) |s| s.edges +|= children.items.len;
    try reverseAppend(&pending, children.items, scratch);
    while (pending.pop()) |reference| {
        switch (reference) {
            .node => |id| {
                if (id >= state.nodes.len) return error.InvalidReference;
                const index: usize = @intCast(id);
                if (node_map[index] != absent) continue;
                node_map[index] = order.items.len;
                try order.append(scratch, index);
                if (statistics) |s| s.nodes +|= 1;
                children.clearRetainingCapacity();
                try references(Node, state.nodes[index], &children, scratch);
                if (statistics) |s| s.edges +|= children.items.len;
                try reverseAppend(&pending, children.items, scratch);
            },
            .blob => |id| {
                if (id >= state.blobs.len) return error.InvalidReference;
                const index: usize = @intCast(id);
                if (blob_map[index] != absent) continue;
                if (statistics) |s| s.blobs +|= 1;
                const source = state.blobs[index];
                const context: BlobContext = .{ .statistics = statistics };
                var selected = interned.getContext(source, context);
                if (selected == null) {
                    selected = blobs.items.len;
                    try blobs.append(scratch, source);
                    try interned.putContext(scratch, source, selected.?, context);
                    if (statistics) |s| s.stored_payload_bytes +|= source.bytes.len;
                }
                blob_map[index] = selected.?;
            },
        }
    }
    return .{
        .node_map = node_map,
        .blob_map = blob_map,
        .order = order.items,
        .blobs = blobs.items,
    };
}

/// Check the same discovery order without constructing another graph owner.
pub fn checkCanonical(allocator: std.mem.Allocator, state: anytype) Error!void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const plan = try discover(scratch.allocator(), state, null);
    if (plan.order.len != state.nodes.len or
        plan.blobs.len != state.blobs.len)
        return error.NonCanonical;
    for (plan.node_map, 0..) |mapped, original| if (mapped != original) return error.NonCanonical;
    for (plan.blob_map, 0..) |mapped, original| if (mapped != original) return error.NonCanonical;
}

const BlobContext = struct {
    statistics: ?*Statistics = null,
    pub fn hash(self: BlobContext, blob: g.Blob) u64 {
        if (self.statistics) |s| s.interning_hash_bytes +|= blob.bytes.len;
        return std.hash.Wyhash.hash(blob.schema, blob.bytes);
    }
    pub fn eql(self: BlobContext, left: g.Blob, right: g.Blob) bool {
        if (self.statistics) |s| s.interning_comparisons +|= 1;
        return left.schema == right.schema and std.mem.eql(u8, left.bytes, right.bytes);
    }
};

fn reverseAppend(
    list: *std.ArrayList(Reference),
    children: []const Reference,
    allocator: std.mem.Allocator,
) Error!void {
    var index = children.len;
    while (index != 0) {
        index -= 1;
        try list.append(allocator, children[index]);
    }
}

/// The record type graph is acyclic; process cycles appear only as NodeRef IDs.
pub fn references(
    comptime T: type,
    value: T,
    list: *std.ArrayList(Reference),
    allocator: std.mem.Allocator,
) Error!void {
    if (T == g.NodeRef) return list.append(allocator, .{ .node = value.id });
    if (T == g.BlobRef) return list.append(allocator, .{ .blob = value.id });
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.child != u8) for (value) |element| try references(
                info.child,
                element,
                list,
                allocator,
            );
        },
        .array => |info| {
            if (info.child != u8) for (value) |element| try references(
                info.child,
                element,
                list,
                allocator,
            );
        },
        .optional => |info| {
            if (value) |present| try references(info.child, present, list, allocator);
        },
        .@"struct" => |info| inline for (
            info.field_names,
            info.field_types,
        ) |field_name, FieldType| try references(
            FieldType,
            @field(value, field_name),
            list,
            allocator,
        ),
        .@"union" => |info| inline for (
            info.field_names,
            info.field_types,
        ) |field_name, FieldType| {
            if (std.mem.eql(u8, @tagName(value), field_name)) {
                try references(FieldType, @field(value, field_name), list, allocator);
                return;
            }
        },
        else => {},
    }
}

pub fn remap(
    comptime T: type,
    value: T,
    nodes: []const u64,
    blobs: []const u64,
    allocator: std.mem.Allocator,
) Error!T {
    if (T == g.NodeRef) return .{ .id = nodes[@intCast(value.id)] };
    if (T == g.BlobRef) return .{ .id = blobs[@intCast(value.id)] };
    return switch (@typeInfo(T)) {
        .pointer => |info| blk: {
            const result = try allocator.alloc(info.child, value.len);
            for (
                result,
                value,
            ) |*target, source| target.* = try remap(
                info.child,
                source,
                nodes,
                blobs,
                allocator,
            );
            break :blk result;
        },
        .optional => |info| if (value) |present| try remap(
            info.child,
            present,
            nodes,
            blobs,
            allocator,
        ) else null,
        .array => |info| blk: {
            var result: T = undefined;
            for (
                &result,
                value,
            ) |*target, source| target.* = try remap(
                info.child,
                source,
                nodes,
                blobs,
                allocator,
            );
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| @field(result, field_name) = try remap(
                FieldType,
                @field(value, field_name),
                nodes,
                blobs,
                allocator,
            );
            break :blk result;
        },
        .@"union" => |info| blk: {
            inline for (info.field_names, info.field_types) |field_name, FieldType| {
                if (std.mem.eql(u8, @tagName(value), field_name))
                    break :blk @unionInit(
                        T,
                        field_name,
                        try remap(FieldType, @field(value, field_name), nodes, blobs, allocator),
                    );
            }
            unreachable; // The active tag is one of this closed native union's fields.
        },
        else => value,
    };
}
