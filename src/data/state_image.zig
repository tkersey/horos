// Copyright (c) 2026 Boundary contributors. MIT license.
//! PST3 graph codec. Graph validity does not grant Program-relative admission.
const std = @import("std");
const s = @import("process_state.zig");
const wire = @import("wire.zig");
const record = @import("record.zig");
const order = @import("graph_order.zig");
pub const Error = order.Error;
pub const Owned = order.Owned(s.State);
/// Native defaults follow the allocator; finite budgets are caller policy.
pub const Limits = struct { max_decoded_bytes: usize = std.math.maxInt(usize) };
pub const magic = "ABL_PST3";

/// Structural checks only. Types, scopes, custody and code positions require
/// the matching admitted Program before any executable owner may be restored.
fn shape(state: s.State, allocator: std.mem.Allocator) Error!void {
    var owners: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer owners.deinit(allocator);
    for (state.nodes) |node| {
        const is_frame = node.record == .control or node.record == .continuation;
        if (is_frame != (node.activation != null)) return error.InvalidState;
        const activation = node.activation orelse continue;
        var previous: ?u64 = null;
        var owned_count: usize = 0;
        for (activation.bindings) |binding| {
            if (previous != null and previous.? >= binding.slot) return error.NonCanonical;
            previous = binding.slot;
            if (binding.value.body == .owned) owned_count += 1;
        }
        if (owned_count != activation.owners.len) return error.InvalidState;
        owners.clearRetainingCapacity();
        for (activation.owners) |owner| {
            if ((try owners.getOrPut(allocator, owner.slot)).found_existing) return error.InvalidState;
            const binding = find(activation.bindings, owner.slot) orelse return error.InvalidState;
            if (binding.value.body != .owned) return error.InvalidState;
        }
    }
}

pub fn find(bindings: []const s.Binding, slot: u64) ?s.Binding {
    var low: usize = 0;
    var high = bindings.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (bindings[middle].slot < slot) low = middle + 1 else high = middle;
    }
    return if (low < bindings.len and bindings[low].slot == slot) bindings[low] else null;
}

pub fn canonicalize(allocator: std.mem.Allocator, state: s.State) Error!Owned {
    var result = try order.canonicalize(allocator, state, null);
    errdefer result.deinit();
    try shape(result.state, allocator);
    return result;
}

pub fn checkGraph(allocator: std.mem.Allocator, state: s.State) Error!void {
    try order.checkCanonical(allocator, state);
    try shape(state, allocator);
}

fn length(state: s.State) Error!usize {
    var writer: wire.Writer = .{ .position = wire.header_length };
    try record.write(s.State, state, &writer);
    return writer.position;
}
fn write(state: s.State, size: usize, writer: *wire.Writer) Error!void {
    try writer.put(magic);
    try writer.fixed(u16, 3);
    try writer.fixed(u16, 0);
    try writer.fixed(u64, size - wire.header_length);
    try record.write(s.State, state, writer);
}

pub const Destination = union(enum) {
    none,
    buffer: []u8,
    allocate: std.mem.Allocator,
};
pub const Serialization = struct {
    /// Present only for buffer/allocate. Ownership follows the destination.
    bytes: ?[]u8,
    length: usize,
};

/// One canonical PST3 emission, optionally materialized and/or hashed. The
/// codec adds no hash domain. Normalization owns inputs before output may
/// overlap them; capacity/allocation failures precede emission to either sink.
pub fn serialize(allocator: std.mem.Allocator, state: s.State, destination: Destination, hasher: ?*std.crypto.hash.sha2.Sha256) Error!Serialization {
    var normalized = try canonicalize(allocator, state);
    defer normalized.deinit();
    const size = try length(normalized.state);
    const output: ?[]u8 = switch (destination) {
        .none => null,
        .buffer => |buffer| if (buffer.len >= size) buffer[0..size] else return error.Capacity,
        .allocate => |output_allocator| try output_allocator.alloc(u8, size),
    };
    errdefer if (destination == .allocate) destination.allocate.free(output.?);
    var writer: wire.Writer = .{ .output = output, .hasher = hasher };
    try write(normalized.state, size, &writer);
    std.debug.assert(writer.position == size);
    return .{ .bytes = output, .length = size };
}

pub fn encode(allocator: std.mem.Allocator, state: s.State, output: []u8) Error![]const u8 {
    return (try serialize(allocator, state, .{ .buffer = output }, null)).bytes.?;
}

pub fn emit(allocator: std.mem.Allocator, state: s.State) Error![]u8 {
    return emitWith(allocator, state, allocator);
}

pub fn emitWith(allocator: std.mem.Allocator, state: s.State, output_allocator: std.mem.Allocator) Error![]u8 {
    return (try serialize(allocator, state, .{ .allocate = output_allocator }, null)).bytes.?;
}

pub fn decodeGraph(allocator: std.mem.Allocator, input: []const u8) Error!Owned {
    return decodeGraphLimited(allocator, input, .{});
}

pub fn decodeGraphLimited(allocator: std.mem.Allocator, input: []const u8, limits: Limits) Error!Owned {
    if (input.len < wire.header_length) return error.Truncated;
    if (input.len > limits.max_decoded_bytes) return error.Capacity;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(u8, input);
    var reader: wire.Reader = .{ .input = owned };
    if (!std.mem.eql(u8, try reader.take(8), magic)) return error.InvalidFamily;
    if (try reader.fixed(u16) != 3) return error.UnsupportedVersion;
    if (try reader.fixed(u16) != 0) return error.InvalidFlags;
    if (try reader.fixed(u64) != owned.len - wire.header_length) return error.InvalidLength;
    var remaining = limits.max_decoded_bytes - owned.len;
    const state = try record.readBounded(s.State, &reader, arena.allocator(), &remaining);
    try reader.finish();
    try order.checkCanonical(allocator, state);
    try shape(state, allocator);
    var comparison: wire.Writer = .{ .expected = owned };
    try write(state, owned.len, &comparison);
    if (comparison.position != owned.len) return error.NonCanonical;
    return .{ .arena = arena, .state = state };
}
