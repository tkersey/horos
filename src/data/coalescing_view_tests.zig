// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const testing = std.testing;
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const graph = @import("coalescing_graph.zig");
const view = @import("coalescing_view.zig");
const Blocks = @import("coalescing_locals.zig").Blocks;

const fixture: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .boolean, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 1, 0 } },
            .custody = &.{ .{}, .{ .parent = 0 }, .{ .parent = 0 }, .{ .parent = 2 } },
            .result = 0,
        },
        .{
            .entry = 3,
            .inputs = &.{ 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 1 } },
            .custody = &.{ .{}, .{ .parent = 0 }, .{ .parent = 1 }, .{ .parent = 0 } },
            .result = 0,
        },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{
            .condition = 1,
            .when_true = .{ .block = 1 },
            .when_false = .{ .block = 2 },
        } } },
        .{
            .function = 0,
            .custody = 1,
            .instructions = &.{},
            .terminator = .{ .jump = .{ .block = 0 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .branch = .{
            .condition = 2,
            .when_true = .{ .block = 5 },
            .when_false = .{ .block = 4 },
        } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{
            .function = 1,
            .custody = 3,
            .instructions = &.{},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
    },
};

fn renamedCase(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var work: graph.Work = .{};
    const maps = try r.identityMaps(a, try r.sizes(fixture));
    const first = try view.function(a, fixture, 0, maps, &work);
    const second = try view.function(a, fixture, 1, maps, &work);
    try testing.expectEqualSlices(u8, first.node.label, second.node.label);
    try testing.expectEqualSlices(p.Id, &.{ 0, 1, 2 }, first.blocks);
    try testing.expectEqualSlices(p.Id, &.{ 3, 5, 4 }, second.blocks);
    try testing.expectEqualSlices(p.Id, &.{ 2, 0, 1 }, second.slots);
    try testing.expectEqualSlices(p.Id, &.{ 0, 2, 3, 1 }, second.custody);
    try testing.expectEqualSlices(p.Id, &.{ 1, 2 }, fixture.functions[1].inputs);
}

test "coalescing views identify renamed cyclic CFGs slots and unused custody subtrees" {
    var admitted = try @import("activation_ownership.zig").analyze(testing.allocator, fixture);
    admitted.deinit();
    try renamedCase(testing.allocator);
    try @import("allocation_testing.zig").check(testing.allocator, renamedCase, .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ordinary: graph.Work = .{};
    var remaining: u64 = 50_000;
    var bounded: graph.Work = .{ .remaining = &remaining };
    const maps = try r.identityMaps(a, try r.sizes(fixture));
    const index = try Blocks.index(a, fixture.blocks.len, &bounded);
    for (0..fixture.functions.len) |id| {
        const expected = try view.function(a, fixture, id, maps, &ordinary);
        const actual = try view.functionWithBlocks(a, fixture, id, maps, &bounded, index);
        try testing.expectEqualDeep(expected, actual);
    }
}

test "coalescing views retain input order branch order and unused slot multiplicity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var work: graph.Work = .{};
    const maps = try r.identityMaps(a, try r.sizes(fixture));
    const first = try view.function(a, fixture, 0, maps, &work);
    var changed = fixture;
    var blocks = fixture.blocks[0..6].*;
    blocks[3].terminator.branch.when_true.block = 4;
    blocks[3].terminator.branch.when_false.block = 5;
    changed.blocks = &blocks;
    const swapped = try view.function(a, changed, 1, maps, &work);
    try testing.expect(!std.mem.eql(u8, first.node.label, swapped.node.label));
    changed = fixture;
    var functions = fixture.functions[0..2].*;
    functions[1].inputs = &.{ 2, 1 };
    changed.functions = &functions;
    const inputs = try view.function(a, changed, 1, maps, &work);
    try testing.expect(!std.mem.eql(u8, first.node.label, inputs.node.label));
    functions[1] = fixture.functions[1];
    functions[1].layout.slots = &.{ 0, 0, 1, 0 };
    const unused = try view.function(a, changed, 1, maps, &work);
    try testing.expect(!std.mem.eql(u8, first.node.label, unused.node.label));
}

test "coalescing views retain typed recursive references outside their local label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var work: graph.Work = .{};
    var recursive = fixture;
    var blocks = fixture.blocks[0..6].*;
    blocks[1].terminator = .{ .call = .{
        .function = 0,
        .arguments = &.{ 0, 1 },
        .next = .{ .block = 2 },
    } };
    blocks[5].terminator = .{ .call = .{
        .function = 1,
        .arguments = &.{ 1, 2 },
        .next = .{ .block = 4 },
    } };
    recursive.blocks = &blocks;
    const maps = try r.identityMaps(a, try r.sizes(recursive));
    const first = try view.function(a, recursive, 0, maps, &work);
    const second = try view.function(a, recursive, 1, maps, &work);
    try testing.expectEqualSlices(u8, first.node.label, second.node.label);
    try testing.expectEqual(@as(usize, 1), first.node.edges.len);
    try testing.expectEqual(@as(usize, 0), first.node.edges[0].target);
    try testing.expectEqual(@as(usize, 1), second.node.edges[0].target);
    const classes = try graph.discover(a, &.{ first.node, second.node }, &.{}, &work);
    try testing.expectEqualSlices(usize, &.{ 0, 0 }, classes);
}
