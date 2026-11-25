const std = @import("std");
const d = @import("root.zig");
const testing = std.testing;
const fixture: d.activation.Program = .{
    .roots = .{ .entry = 2, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .{ .internal = .{ .abstract_resource = 0 } }, .boolean },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 9, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } },
    },
    .effects = &.{.{ .identity = "unused", .payload = 1, .result = 3 }},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 1, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 2, .inputs = &.{}, .layout = .{ .slots = &.{ 0, 2 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 0, .opcode = .constant }},
            .terminator = .{ .return_value = 0 },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 0, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .return_value = 0 },
        },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 0, .opcode = .constant, .immediate = 2 }},
            .terminator = .{ .return_value = 0 },
        },
    },
    // Authority keeps function1, even though no call edge reaches it.
    .scopes = .{ .resources = &.{.{
        .representation = 0,
        .introducers = &.{1},
        .eliminators = &.{1},
    }} },
};

fn projectionCase(allocator: std.mem.Allocator) !void {
    var payload = [_]u8{ 42, 0, 0, 0, 0, 0, 0, 0 };
    var constants = fixture.constants[0..3].*;
    constants[2].bytes = &payload;
    var input = fixture;
    input.constants = &constants;
    var checked = try d.activation_ownership.analyze(allocator, input);
    checked.deinit();
    var output = std.heap.ArenaAllocator.init(allocator);
    defer output.deinit();
    const program = blk: {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const result = try d.relocation.ownReachable(
            output.allocator(),
            scratch.allocator(),
            input,
        );
        try testing.expectEqualSlices(u64, &.{ 1, 2 }, result.function_origins);
        break :blk result.program;
    };
    @memset(&payload, 0xff);
    try testing.expectEqual(2, program.functions.len);
    try testing.expectEqual(2, program.blocks.len);
    try testing.expectEqual(2, program.constants.len);
    try testing.expectEqual(3, program.schemas.len);
    try testing.expectEqual(0, program.effects.len);
    try testing.expectEqual(1, program.roots.entry);
    try testing.expectEqualSlices(u64, &.{0}, program.scopes.resources[0].introducers);
    try testing.expectEqualSlices(u64, &.{0}, program.scopes.resources[0].eliminators);
    try testing.expectEqual(1, program.blocks[1].instructions[0].immediate);
    try testing.expectEqual(42, program.constants[1].bytes[0]);
    var admitted = try d.activation_ownership.analyze(allocator, program);
    admitted.deinit();
}

test "closed projection follows resource authority and owns remapped output after scratch release" {
    try projectionCase(testing.allocator);
}

test "closed projection releases partial owners at every allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, projectionCase, .{});
}

test "bounded closure follows authorities independently of literal byte length" {
    var input = fixture;
    var literals = fixture.constants[0..3].*;
    var schemas = fixture.schemas[0..4].*;
    schemas[0] = .bytes;
    input.schemas = &schemas;
    for (&literals) |*literal| literal.bytes = &.{0};
    input.constants = &literals;
    var remaining: u64 = 10000;
    const expected = try d.relocation.reachableBlocks(testing.allocator, input, &remaining);
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(bool, &.{ false, true, true }, expected);
    const cost = 10000 - remaining;
    const payload = 1024 * 1024;
    const bytes = try testing.allocator.alloc(u8, d.wire.naturalLength(payload) + payload);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);
    var writer: d.wire.Writer = .{ .output = bytes };
    try writer.natural(payload);
    literals[2].bytes = bytes;
    var admitted = try d.activation_ownership.analyze(testing.allocator, input);
    admitted.deinit();
    var exact = cost;
    const actual = try d.relocation.reachableBlocks(testing.allocator, input, &exact);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(bool, expected, actual);
    try testing.expectEqual(0, exact);
    var short = cost - 1;
    try testing.expectError(
        error.RelationLimit,
        d.relocation.reachableBlocks(testing.allocator, input, &short),
    );
    var output = std.heap.ArenaAllocator.init(testing.allocator);
    defer output.deinit();
    var materialize: u64 = bytes.len - 1;
    try testing.expectError(error.RelationLimit, d.relocation.ownReachableWithWork(
        output.allocator(),
        output.allocator(),
        input,
        &materialize,
    ));
}

const SparseCosts = struct { projection: u64, lookup: u64 };

fn sparseProjectionCosts(comptime width: usize) !SparseCosts {
    const maximum = std.math.maxInt(u64);
    var even: [width]u64 = undefined;
    var odd: [width]u64 = undefined;
    for (&even, &odd, 0..) |*left, *right, i| {
        left.* = maximum - 4 * width + 4 * i;
        right.* = left.* + 1;
    }
    var functions = fixture.functions[0..3].*;
    functions[2].regions = &even;
    functions[1].regions = &odd;
    var input = fixture;
    input.functions = &functions;
    input.scopes.region_count = maximum;
    var admitted = try d.activation_ownership.analyze(testing.allocator, input);
    admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ordinary = try d.relocation.ownReachable(a, a, input);
    var work: u64 = maximum;
    const bounded = try d.relocation.ownReachableWithWork(a, a, input, &work);
    const projection = maximum - work;
    if (width == 32) {
        var exact = projection;
        _ = try d.relocation.ownReachableWithWork(a, a, input, &exact);
        try testing.expectEqual(0, exact);
        var short = projection - 1;
        try testing.expectError(error.RelationLimit, d.relocation.ownReachableWithWork(
            a,
            a,
            input,
            &short,
        ));
    }
    try testing.expectEqualDeep(ordinary.program, bounded.program);
    try testing.expectEqual(2 * width, bounded.program.scopes.region_count);
    var expected = ordinary.regions.iterator();
    var actual = bounded.regions.iterator();
    while (expected.next()) |entry| {
        const received = actual.next().?;
        try testing.expectEqual(entry.key_ptr.*, received.key_ptr.*);
        try testing.expectEqual(entry.value_ptr.*, received.value_ptr.*);
    }
    try testing.expect(actual.next() == null);
    const before = work;
    for (even, odd, 0..) |left, right, i| {
        try testing.expectEqual(i, try bounded.mappedWithWork(.region, left, &work));
        try testing.expectEqual(width + i, try bounded.mappedWithWork(.region, right, &work));
    }
    try testing.expectError(error.InvalidReference, bounded.mappedWithWork(.region, 0, &work));
    return .{ .projection = projection, .lookup = before - work };
}

test "bounded sparse region projection preserves numbering and legacy order at scale" {
    const small = try sparseProjectionCosts(32);
    const wide = try sparseProjectionCosts(1024);
    try testing.expect(wide.projection < 64 * small.projection);
    try testing.expect(wide.lookup < 64 * small.lookup);
}
