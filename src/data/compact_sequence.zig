// Copyright (c) 2026 Boundary contributors. MIT license.
//! Compact ID sequences. Logical IDs keep their meaning.
const std = @import("std");
const p = @import("program.zig");
const wire = @import("wire.zig");
const record = @import("record.zig");
const Error = record.Error;

const Mode = enum(u8) { literal = 0, repeat = 1, range = 2 };
const Segment = struct { mode: Mode, count: usize };

fn equal(comptime T: type, a: T, b: T) bool {
    comptime std.debug.assert(T == p.Id);
    return a == b;
}

fn ordinal(comptime T: type, value: T) ?u64 {
    comptime std.debug.assert(T == p.Id);
    return value;
}

fn at(comptime T: type, start: u64, index: usize) T {
    const value = start + index; // The complete range was checked before expansion.
    comptime std.debug.assert(T == p.Id);
    return value;
}

fn size(comptime T: type, value: T) usize {
    comptime std.debug.assert(T == p.Id);
    return wire.naturalLength(value);
}

fn naturalSize(value: usize) usize {
    return wire.naturalLength(value);
}

/// Each scan consumes its run. The literal scan only peeks at two neighbours.
fn run(comptime T: type, values: []const T) Segment {
    var repeated: usize = 1;
    while (repeated < values.len and equal(T, values[0], values[repeated]))
        repeated += 1;
    var ranged: usize = 1;
    if (ordinal(T, values[0])) |start| {
        while (ranged < values.len and ranged <= std.math.maxInt(u64) - start) : (ranged += 1) {
            if (ordinal(T, values[ranged]) != start + ranged) break;
        }
    }
    return if (repeated >= ranged)
        .{ .mode = .repeat, .count = repeated }
    else
        .{ .mode = .range, .count = ranged };
}

fn startsRun(comptime T: type, values: []const T) bool {
    if (values.len < 3) return false;
    if (equal(T, values[0], values[1]) and equal(T, values[1], values[2])) return true;
    const first = ordinal(T, values[0]) orelse return false;
    return first <= std.math.maxInt(u64) - 2 and
        ordinal(T, values[1]) == first + 1 and ordinal(T, values[2]) == first + 2;
}

fn next(comptime T: type, values: []const T) Segment {
    const candidate = run(T, values);
    if (candidate.count >= 3) {
        const compact = 1 + naturalSize(candidate.count) + size(T, values[0]);
        var literal: usize = 0;
        for (values[0..candidate.count]) |value| literal += size(T, value);
        if (compact < literal) return candidate;
    }
    var count: usize = 1;
    while (count < values.len and !startsRun(T, values[count..])) count += 1;
    return .{ .mode = .literal, .count = count };
}

fn segments(comptime T: type, values: []const T, writer: *wire.Writer) Error!void {
    var offset: usize = 0;
    while (offset < values.len) {
        const segment = next(T, values[offset..]);
        try writer.byte(@backingInt(segment.mode));
        try writer.natural(segment.count);
        if (segment.mode == .literal) {
            for (values[offset..][0..segment.count]) |value| try record.write(T, value, writer);
        } else try record.write(T, values[offset], writer);
        offset += segment.count;
    }
}

pub fn write(comptime T: type, values: []const T, writer: *wire.Writer) Error!void {
    try writer.natural(values.len);
    if (values.len == 0) return;
    if (values.len <= 2) {
        for (values) |value| try record.write(T, value, writer);
        return;
    }
    var segmented: wire.Writer = .{};
    try segments(T, values, &segmented);
    var literal: wire.Writer = .{};
    for (values) |value| try record.write(T, value, &literal);
    const use_segments = segmented.position < literal.position;
    try writer.byte(@intFromBool(use_segments));
    if (use_segments) return segments(T, values, writer);
    for (values) |value| try record.write(T, value, writer);
}

pub fn read(
    comptime T: type,
    comptime materialize: bool,
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    requested: *usize,
) Error![]const T {
    const count = try reader.count();
    try account(T, count, requested);
    if (count == 0) return &.{};
    const mode = if (count <= 2) 0 else try reader.byte();
    if (mode > 1) return error.InvalidTag;
    if (mode == 0 and count > reader.input.len - reader.position) return error.Truncated;
    // Validate the complete compressed descriptor before requesting expanded storage.
    // Ordinary literal rows retain the legacy bounded-count parsing discipline.
    if (materialize and mode == 1) {
        var probe = reader.*;
        try readSegments(T, false, count, &.{}, &probe, allocator);
    }
    const output = if (materialize) try allocator.alloc(T, count) else &.{};
    if (mode == 0) {
        for (0..count) |index| {
            const value = try record.read(T, reader, allocator);
            if (materialize) output[index] = value;
        }
    } else try readSegments(T, materialize, count, output, reader, allocator);
    return output;
}

fn readSegments(
    comptime T: type,
    comptime materialize: bool,
    total: usize,
    output: []T,
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
) Error!void {
    var offset: usize = 0;
    while (offset < total) {
        const mode = try reader.byte();
        if (mode > 2) return error.InvalidTag;
        const count = try reader.count();
        if (count == 0 or count > total - offset) return error.InvalidLength;
        if (mode == 0) {
            if (count > reader.input.len - reader.position) return error.Truncated;
            for (0..count) |index| {
                const value = try record.read(T, reader, allocator);
                if (materialize) output[offset + index] = value;
            }
        } else {
            const value = try record.read(T, reader, allocator);
            if (mode == 2) {
                const start = ordinal(T, value) orelse return error.InvalidTag;
                if (count - 1 > std.math.maxInt(u64) - start) return error.InvalidLength;
                if (materialize) for (output[offset..][0..count], 0..) |*item, index| {
                    item.* = at(T, start, index);
                };
            } else if (materialize) @memset(output[offset..][0..count], value);
        }
        offset += count;
    }
}

pub fn account(comptime T: type, count: usize, requested: *usize) Error!void {
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.InvalidLength;
    requested.* = std.math.add(usize, requested.*, bytes) catch return error.InvalidLength;
}

/// Test/tool attribution of the selected spelling; counts physical descriptions.
pub fn descriptions(comptime T: type, values: []const T) Error!usize {
    if (values.len <= 2) return values.len;
    var segmented: wire.Writer = .{};
    try segments(T, values, &segmented);
    var literal: wire.Writer = .{};
    for (values) |value| try record.write(T, value, &literal);
    if (segmented.position >= literal.position) return values.len;
    var result: usize = 0;
    var offset: usize = 0;
    while (offset < values.len) {
        const segment = next(T, values[offset..]);
        result += if (segment.mode == .literal) segment.count else 1;
        offset += segment.count;
    }
    return result;
}
