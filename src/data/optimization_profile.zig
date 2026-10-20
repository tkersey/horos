// Copyright (c) 2026 Boundary contributors. MIT license.
//! Opt-in search weights. Counts never establish reachability or value facts.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("activation.zig");
const image = @import("program_image.zig");
const wire = @import("wire.zig");

pub const schema_version: u32 = 1;
pub const toolchain = "boundary-profile/v1/zig-" ++ builtin.zig_version_string;
pub const Error = image.Error || error{InvalidOptimizationProfile};
pub const Record = struct {
    version: u32 = schema_version,
    toolchain_identity: []const u8 = toolchain,
    image_identity: [32]u8,
    /// Dense original block IDs, never source IDs or relocated candidate IDs.
    block_counts: []const u64,
    total: u64,
};

pub fn validate(allocator: std.mem.Allocator, program: ir.Program, record: Record) Error!void {
    if (record.version != schema_version or !std.mem.eql(
        u8,
        record.toolchain_identity,
        toolchain,
    ) or record.block_counts.len != program.blocks.len) return error.InvalidOptimizationProfile;
    var total: u64 = 0;
    for (record.block_counts) |count| total = std.math.add(
        u64,
        total,
        count,
    ) catch return error.InvalidOptimizationProfile;
    if (total != record.total or !std.mem.eql(
        u8,
        &record.image_identity,
        &try image.identity(allocator, program),
    )) return error.InvalidOptimizationProfile;
}

pub fn orderedBlocks(
    allocator: std.mem.Allocator,
    program: ir.Program,
    record: Record,
) Error![]usize {
    try validate(allocator, program, record);
    const order = try allocator.alloc(usize, program.blocks.len);
    for (order, 0..) |*id, index| id.* = index;
    std.mem.sort(usize, order, record.block_counts, struct {
        fn less(counts: []const u64, left: usize, right: usize) bool {
            return counts[left] > counts[right] or (counts[left] == counts[right] and left < right);
        }
    }.less);
    return order;
}

pub const Owned = struct {
    allocator: std.mem.Allocator,
    record: Record,
    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.record.block_counts);
        self.* = undefined;
    }
};

/// Explicit local collection only. The caller supplies the actually executed
/// original block; neither timing nor telemetry participates in compilation.
pub const Collector = struct {
    allocator: std.mem.Allocator,
    identity: [32]u8,
    counts: []u64,
    total: u64 = 0,
    pub fn init(allocator: std.mem.Allocator, program: ir.Program) Error!Collector {
        const identity = try image.identity(allocator, program);
        const counts = try allocator.alloc(u64, program.blocks.len);
        @memset(counts, 0);
        return .{ .allocator = allocator, .identity = identity, .counts = counts };
    }
    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.counts);
        self.* = undefined;
    }
    pub fn observe(self: *@This(), block: usize) Error!void {
        if (block >= self.counts.len) return error.InvalidOptimizationProfile;
        const count = std.math.add(
            u64,
            self.counts[block],
            1,
        ) catch return error.InvalidOptimizationProfile;
        const total = std.math.add(
            u64,
            self.total,
            1,
        ) catch return error.InvalidOptimizationProfile;
        self.counts[block] = count;
        self.total = total;
    }
    pub fn snapshot(self: @This(), allocator: std.mem.Allocator) Error!Owned {
        return .{
            .allocator = allocator,
            .record = .{
                .image_identity = self.identity,
                .block_counts = try allocator.dupe(u64, self.counts),
                .total = self.total,
            },
        };
    }
};

fn write(writer: *wire.Writer, record: Record) Error!void {
    try writer.put("BPF1");
    try writer.fixed(u32, record.version);
    try writer.put(&record.image_identity);
    try writer.bytes(record.toolchain_identity);
    try writer.natural(record.block_counts.len);
    try writer.fixed(u64, record.total);
    for (record.block_counts) |count| try writer.fixed(u64, count);
}
pub fn encodedLength(record: Record) Error!usize {
    var writer: wire.Writer = .{};
    try write(&writer, record);
    return writer.position;
}
pub fn encode(record: Record, output: []u8) Error![]const u8 {
    var writer: wire.Writer = .{ .output = output };
    try write(&writer, record);
    return output[0..writer.position];
}
pub fn decode(allocator: std.mem.Allocator, program: ir.Program, bytes: []const u8) Error!Owned {
    var reader: wire.Reader = .{ .input = bytes };
    if (!std.mem.eql(u8, try reader.take(4), "BPF1")) return error.InvalidOptimizationProfile;
    const version = try reader.fixed(u32);
    const identity = (try reader.take(32))[0..32].*;
    if (!std.mem.eql(u8, try reader.bytes(), toolchain)) return error.InvalidOptimizationProfile;
    const count = try reader.count();
    if (count != program.blocks.len) return error.InvalidOptimizationProfile;
    const total = try reader.fixed(u64);
    // Bound allocation by both the admitted input and available fixed counters.
    if (count > (bytes.len - reader.position) / 8) return error.Truncated;
    const counts = try allocator.alloc(u64, count);
    errdefer allocator.free(counts);
    for (counts) |*value| value.* = try reader.fixed(u64);
    try reader.finish();
    const record: Record = .{
        .version = version,
        .image_identity = identity,
        .block_counts = counts,
        .total = total,
    };
    try validate(allocator, program, record);
    return .{ .allocator = allocator, .record = record };
}
