// Copyright (c) 2026 Boundary contributors. MIT license.
//! Existing linker structural schema partition, shared with closed-program coalescing.
//! Inputs have already passed schema validation; nominal maps remain identities.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const relocate = @import("relocation.zig");
const equal = @import("record.zig").equal;
const record = @import("record.zig");
const wire = @import("wire.zig");
const Kind = relocate.Kind;
const Id = p.Id;
const Error = relocate.Error;
pub const Statistics = struct { rounds: usize = 0, comparisons: usize = 0, lookups: usize = 0 };

/// Result and scratch belong to the caller's arena. Returns dense schema classes.
pub fn compute(a: std.mem.Allocator, program: ir.Program) Error![]const Id {
    return computeObserved(a, program, null);
}
pub fn computeObserved(
    a: std.mem.Allocator,
    program: ir.Program,
    statistics: ?*Statistics,
) Error![]const Id {
    return computeImpl(a, program, statistics, false, 0);
}
fn KeyContext(comptime collide: bool, comptime seed: u64) type {
    return struct {
        stats: *Statistics,
        pub fn hash(_: @This(), key: []const u8) u64 {
            return if (collide) 0 else std.hash.Wyhash.hash(seed, key);
        }
        pub fn eql(self: @This(), left: []const u8, right: []const u8) bool {
            self.stats.comparisons += 1;
            return std.mem.eql(u8, left, right);
        }
    };
}
fn encodeKey(a: std.mem.Allocator, shape: p.Schema) Error![]const u8 {
    var size: wire.Writer = .{};
    try record.write(p.Schema, shape, &size);
    const bytes = try a.alloc(u8, size.position);
    var writer: wire.Writer = .{ .output = bytes };
    try record.write(p.Schema, shape, &writer);
    return bytes;
}
fn computeImpl(
    a: std.mem.Allocator,
    program: ir.Program,
    statistics: ?*Statistics,
    comptime collide: bool,
    comptime seed: u64,
) Error![]const Id {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var classes = try a.alloc(Id, program.schemas.len);
    var next = try a.alloc(Id, classes.len);
    @memset(classes, 0);
    var maps = try relocate.identityMaps(a, try relocate.sizes(program));
    var changed = true;
    while (changed) {
        stats.rounds += 1;
        var pass = std.heap.ArenaAllocator.init(a);
        defer pass.deinit();
        maps[@backingInt(Kind.schema)] = classes;
        const mapper: relocate.Mapper = .{ .allocator = pass.allocator(), .maps = maps };
        const shapes = try pass.allocator().alloc(p.Schema, classes.len);
        var distinct: usize = 0;
        var index: std.HashMapUnmanaged([]const u8, Id, KeyContext(collide, seed), 80) = .empty;
        const context: KeyContext(collide, seed) = .{ .stats = &stats };
        var indexed = false;
        for (shapes, program.schemas, 0..) |*shape, original, i| {
            shape.* = try mapper.schema(original);
            next[i] = i;
            stats.lookups += 1;
            if (!indexed and distinct <= 16) {
                var found = false;
                for (shapes[0..i], 0..) |prior, j| {
                    stats.comparisons += 1;
                    if (equal(p.Schema, shape.*, prior)) {
                        next[i] = next[j];
                        found = true;
                        break;
                    }
                }
                if (!found) distinct += 1;
                continue;
            }
            if (!indexed) {
                for (
                    shapes[0..i],
                    0..,
                ) |prior, j| if (next[j] == j) try index.putContext(
                    pass.allocator(),
                    try encodeKey(pass.allocator(), prior),
                    next[j],
                    context,
                );
                indexed = true;
            }
            const encoded = try encodeKey(pass.allocator(), shape.*);
            const entry = try index.getOrPutContext(pass.allocator(), encoded, context);
            if (entry.found_existing) {
                next[i] = entry.value_ptr.*;
                pass.allocator().free(encoded);
            } else entry.value_ptr.* = i;
        }
        changed = !std.mem.eql(Id, classes, next);
        if (changed) std.mem.swap([]Id, &classes, &next);
    }
    const representatives = try a.alloc(Id, classes.len);
    var count: Id = 0;
    for (classes, 0..) |class, i| if (class == i) {
        representatives[i] = count;
        count += 1;
    };
    for (classes) |*class| class.* = representatives[@intCast(class.*)];
    return classes;
}

fn reference(a: std.mem.Allocator, program: ir.Program) Error![]const Id {
    if (!@import("builtin").is_test) @compileError("test-only reference");
    var classes = try a.alloc(Id, program.schemas.len);
    var next = try a.alloc(Id, classes.len);
    @memset(classes, 0);
    var maps = try relocate.identityMaps(a, try relocate.sizes(program));
    var changed = true;
    while (changed) {
        var pass = std.heap.ArenaAllocator.init(a);
        defer pass.deinit();
        maps[@backingInt(Kind.schema)] = classes;
        const mapper: relocate.Mapper = .{ .allocator = pass.allocator(), .maps = maps };
        const shapes = try pass.allocator().alloc(p.Schema, classes.len);
        for (shapes, program.schemas, 0..) |*shape, original, i| {
            shape.* = try mapper.schema(original);
            next[i] = i;
            for (shapes[0..i], 0..) |prior, j| if (equal(p.Schema, shape.*, prior)) {
                next[i] = next[j];
                break;
            };
        }
        changed = !std.mem.eql(Id, classes, next);
        if (changed) std.mem.swap([]Id, &classes, &next);
    }
    const representatives = try a.alloc(Id, classes.len);
    var count: Id = 0;
    for (classes, 0..) |class, i| if (class == i) {
        representatives[i] = count;
        count += 1;
    };
    for (classes) |*class| class.* = representatives[@intCast(class.*)];
    return classes;
}

test "indexed partition agrees with pairwise reference under forced hash collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var schemas: [66]p.Schema = undefined;
    schemas[0] = .u8;
    for (
        schemas[1..65],
        0..,
    ) |*schema, i| schema.* = .{ .array = .{ .element = 0, .length = i % 40 } };
    schemas[65] = .{ .internal = .{ .region = 0 } };
    const program = fixtureProgram(&schemas, 1);
    var admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    const expected = try reference(a, program);
    try std.testing.expectEqualSlices(Id, expected, try compute(a, program));
    try std.testing.expectEqualSlices(Id, expected, try computeImpl(a, program, null, true, 0));
    const seeds = comptime blk: {
        var random = std.Random.DefaultPrng.init(0x473334);
        var values: [8]u64 = undefined;
        for (&values) |*value| value.* = random.random().int(u64);
        break :blk values;
    };
    inline for (seeds) |seed|
        try std.testing.expectEqualSlices(
            Id,
            expected,
            try computeImpl(a, program, null, false, seed),
        );
}
test "recursive definitions and nominal leaves are reindexed from each current input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var schemas = [_]p.Schema{
        .u8,
        .{ .sum = &.{ 0, 1 } },
        .{ .sum = &.{ 0, 2 } },
        .{ .internal = .{ .region = 0 } },
        .{ .internal = .{ .region = 1 } },
    };
    const program = fixtureProgram(&schemas, 2);
    var admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    const before = try compute(a, program);
    try std.testing.expectEqual(before[1], before[2]);
    try std.testing.expect(before[3] != before[4]);
    // A completed recursive binder receives a different definition before the
    // next invocation. No fingerprint or equivalence survives across calls.
    schemas[2] = .{ .sum = &.{ 0, 0 } };
    const after = try compute(a, program);
    try std.testing.expect(after[1] != after[2]);
    try std.testing.expectEqualSlices(Id, try reference(a, program), after);
    schemas[2] = .{ .sum = &.{ 0, 2 } };
    try std.testing.expectEqualSlices(Id, before, try compute(a, program));
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var schemas: [40]p.Schema = undefined;
    schemas[0] = .u8;
    for (schemas[1..], 0..) |*schema, i| schema.* = .{ .array = .{ .element = 0, .length = i } };
    const program = fixtureProgram(&schemas, 0);
    _ = try compute(arena.allocator(), program);
}
fn fixtureProgram(schemas: []const p.Schema, regions: Id) ir.Program {
    if (!@import("builtin").is_test) @compileError("test-only fixture");
    return .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = schemas,
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        }},
        .scopes = .{ .region_count = regions },
    };
}
test "partition indexing releases every failed allocation" {
    try @import("allocation_testing.zig").check(std.testing.allocator, allocationAttempt, .{});
}
test "indexed and reference partitions preserve invalid-reference diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = fixtureProgram(&.{ .u8, .{ .array = .{ .element = 99, .length = 1 } } }, 0);
    try std.testing.expectError(error.InvalidReference, reference(arena.allocator(), program));
    try std.testing.expectError(error.InvalidReference, compute(arena.allocator(), program));
}
