// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const testing = std.testing;
const discovery = @import("coalescing_discovery.zig");
const candidate = @import("coalescing_candidate.zig");
const graph = @import("coalescing_graph.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const image = @import("program_image.zig");
const fixture = @import("coalescing_witness_tests.zig").original;

fn candidateCase(allocator: std.mem.Allocator) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var input_owner = std.heap.ArenaAllocator.init(allocator);
    defer input_owner.deinit();
    var original_facts = try @import("activation_ownership.zig").analyze(allocator, fixture);
    original_facts.deinit();
    const baseline = try r.ownReachable(input_owner.allocator(), scratch.allocator(), fixture);
    var work: graph.Work = .{};
    const opportunities = try discovery.analyze(scratch.allocator(), baseline.program, &work);
    var full = try candidate.build(
        allocator,
        scratch.allocator(),
        baseline.program,
        opportunities,
        .full,
        &work,
    );
    defer full.deinit();
    try testing.expectEqual(@as(usize, 2), full.program.functions.len);
    try testing.expect(full.bytes < try image.encodedLength(baseline.program));
    const buffer = try allocator.alloc(u8, full.bytes);
    defer allocator.free(buffer);
    try testing.expectEqual(full.bytes, (try image.encode(allocator, full.program, buffer)).len);
    var descriptions = try candidate.build(
        allocator,
        scratch.allocator(),
        baseline.program,
        opportunities,
        .descriptions,
        &work,
    );
    defer descriptions.deinit();
    try testing.expectEqual(@as(usize, 3), descriptions.program.functions.len);
    try testing.expectEqual(try image.encodedLength(baseline.program), descriptions.bytes);
}

test "coalescing candidate shares whole code and independently admits both profiles" {
    try candidateCase(testing.allocator);
}

test "coalescing candidate owns selected storage after source and scratch release" {
    var full = result: {
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        var work: graph.Work = .{};
        const opportunities = try discovery.analyze(scratch.allocator(), fixture, &work);
        break :result try candidate.build(
            testing.allocator,
            scratch.allocator(),
            fixture,
            opportunities,
            .full,
            &work,
        );
    };
    defer full.deinit();
    // Scratch correspondence is deliberately not accessed after the arena dies.
    var checked = try @import("activation_ownership.zig").analyze(testing.allocator, full.program);
    defer checked.deinit();
    try testing.expectEqual(@as(usize, 2), full.program.functions.len);
}

test "coalescing candidate allocation failures leave no partially published owner" {
    try @import("allocation_testing.zig").check(testing.allocator, candidateCase, .{});
}

test "coalescing candidate keeps pinned authority functions separate" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var work: graph.Work = .{};
    var program = fixture;
    program.schemas = &.{ .u64, .unit, .{ .internal = .{ .abstract_resource = 0 } } };
    var functions = fixture.functions[0..3].*;
    functions[2].layout.slots = &.{ 0, 2 };
    program.functions = &functions;
    program.scopes.resources = &.{.{
        .representation = 0,
        .introducers = &.{0},
        .eliminators = &.{1},
    }};
    var admitted = try @import("activation_ownership.zig").analyze(testing.allocator, program);
    admitted.deinit();
    const projected = try r.ownReachable(scratch.allocator(), scratch.allocator(), program);
    try testing.expectEqual(@as(usize, 1), projected.program.scopes.resources.len);
    const opportunities = try discovery.analyze(scratch.allocator(), projected.program, &work);
    const map = try discovery.correspondence(
        scratch.allocator(),
        projected.program,
        opportunities,
        .full,
        &work,
    );
    try testing.expectEqualSlices(
        ir.Id,
        &.{ 0, 1, 2 },
        map.representatives[@backingInt(r.Kind.function)],
    );
}

test "coalescing public pass separates privileged and unprivileged identical code" {
    const pass = @import("coalescing.zig");
    for ([_]bool{ false, true }) |both| {
        var program = fixture;
        program.schemas = &.{ .u64, .unit, .{ .internal = .{ .abstract_resource = 0 } } };
        var functions = fixture.functions[0..3].*;
        functions[2].layout.slots = &.{ 0, 2 };
        program.functions = &functions;
        program.scopes.resources = &.{.{
            .representation = 0,
            .introducers = &.{0},
            .eliminators = if (both) &.{1} else &.{},
        }};
        var result = try pass.run(testing.allocator, program, .{});
        defer result.deinit();
        try testing.expectEqual(@as(usize, 3), result.program.functions.len);
        try testing.expectEqual(@as(usize, 1), result.program.scopes.resources.len);
        try testing.expectEqualSlices(ir.Id, &.{0}, result.program.scopes.resources[0].introducers);
        try testing.expectEqualSlices(
            ir.Id,
            if (both) &.{1} else &.{},
            result.program.scopes.resources[0].eliminators,
        );
    }
}

test "discarded authority neither pins live helpers nor hides an invalid unused declaration" {
    const pass = @import("coalescing.zig");
    inline for (.{ false, true }) |eliminate| {
        var program = fixture;
        program.schemas = &.{ .u64, .unit, .{ .internal = .{ .abstract_resource = 0 } } };
        var functions = [_]ir.Function{
            fixture.functions[0], fixture.functions[1], fixture.functions[2],
            .{
                .entry = fixture.blocks.len,
                .inputs = &.{0},
                .layout = .{ .slots = if (eliminate) &.{ 2, 0 } else &.{ 0, 2 } },
                .result = if (eliminate) 0 else 2,
            },
        };
        var blocks: [fixture.blocks.len + 1]ir.Block = undefined;
        @memcpy(blocks[0..fixture.blocks.len], fixture.blocks);
        blocks[fixture.blocks.len] = .{
            .function = 3,
            .instructions = &.{.{
                .opcode = if (eliminate) .resource_unpack else .resource_pack,
                .destination = 1,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 1 },
        };
        program.functions = &functions;
        program.blocks = &blocks;
        program.scopes.resources = &.{.{
            .representation = 0,
            .introducers = &.{0},
            .eliminators = &.{1},
        }};
        try testing.expectError(error.InvalidOwnership, pass.run(testing.allocator, program, .{}));
        program.scopes.resources = &.{.{
            .representation = 0,
            .introducers = if (eliminate) &.{0} else &.{ 0, 3 },
            .eliminators = if (eliminate) &.{ 1, 3 } else &.{1},
        }};
        var result = try pass.run(testing.allocator, program, .{});
        defer result.deinit();
        try testing.expectEqual(@as(usize, 0), result.program.scopes.resources.len);
        try testing.expectEqual(@as(usize, 2), result.program.functions.len);
        var repeated = try pass.run(testing.allocator, result.program, .{});
        defer repeated.deinit();
        try testing.expectEqual(
            try image.identity(testing.allocator, result.program),
            try image.identity(testing.allocator, repeated.program),
        );
    }
}
