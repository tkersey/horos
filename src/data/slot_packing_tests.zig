// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const pack = @import("slot_packing.zig");
const a = std.testing.allocator;
pub const chain: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 0 },
    .schemas = &.{.u64},
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{0},
        .layout = .{ .slots = &.{ 0, 0, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 1, .opcode = .integer_bit_not, .operands = &.{0} },
            .{ .destination = 2, .opcode = .integer_bit_not, .operands = &.{1} },
            .{ .destination = 3, .opcode = .integer_bit_not, .operands = &.{2} },
        },
        .terminator = .{ .return_value = 3 },
    }},
};
test "disjoint temporaries share an exact-schema logical slot" {
    var candidate = (try pack.construct(a, chain, .{})).?;
    defer candidate.deinit();
    try pack.validate(a, chain, candidate.program, candidate.maps, .{});
    try std.testing.expectEqual(@as(usize, 2), candidate.program.functions[0].layout.slots.len);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 1, 1 }, candidate.maps[0].?);
}
test "independent liveness checker rejects merging simultaneous values" {
    var original = chain;
    original.functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 0, 0, 0, 0 } },
        .result = 0,
    }};
    original.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 2, .opcode = .integer_bit_not, .operands = &.{0} },
            .{ .destination = 3, .opcode = .integer_bit_not, .operands = &.{1} },
            .{ .destination = 4, .opcode = .integer_bit_or, .operands = &.{ 2, 3 } },
        },
        .terminator = .{ .return_value = 4 },
    }};
    var wrong = original;
    wrong.functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 0, 0 } },
        .result = 0,
    }};
    wrong.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 2, .opcode = .integer_bit_not, .operands = &.{0} },
            .{ .destination = 2, .opcode = .integer_bit_not, .operands = &.{1} },
            .{ .destination = 2, .opcode = .integer_bit_or, .operands = &.{ 2, 2 } },
        },
        .terminator = .{ .return_value = 2 },
    }};
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidSlotPacking,
        pack.validate(a, original, wrong, &.{&.{ 0, 1, 2, 2, 2 }}, .{}),
    );
}
test "parallel swaps survive packing around bitset boundaries" {
    for ([_]usize{ 63, 64, 65, 66 }) |count| {
        var slots: [66]u64 = @splat(0);
        slots[2] = 1;
        slots[count - 1] = 2;
        const original: ir.Program = .{
            .roots = .{ .entry = 0, .result = 2, .failure = 0 },
            .schemas = &.{ .u64, .boolean, .{ .product = &.{ 0, 0 } } },
            .constants = &.{},
            .effects = &.{},
            .functions = &.{.{
                .entry = 0,
                .inputs = &.{ 0, 1, 2 },
                .layout = .{ .slots = slots[0..count] },
                .result = 2,
            }},
            .blocks = &.{
                .{
                    .function = 0,
                    .instructions = &.{
                        .{
                            .destination = count - 3,
                            .opcode = .integer_bit_not,
                            .operands = &.{0},
                        },
                        .{
                            .destination = count - 2,
                            .opcode = .integer_bit_not,
                            .operands = &.{1},
                        },
                    },
                    .terminator = .{ .jump = .{
                        .block = 1,
                        .assignments = &.{
                            .{ .destination = 0, .source = .{ .slot = count - 2 } },
                            .{ .destination = 1, .source = .{ .slot = count - 3 } },
                        },
                    } },
                },
                .{
                    .function = 0,
                    .instructions = &.{.{
                        .destination = count - 1,
                        .opcode = .product,
                        .operands = &.{ 0, 1 },
                    }},
                    .terminator = .{ .return_value = count - 1 },
                },
            },
        };
        var candidate = (try pack.construct(a, original, .{})).?;
        defer candidate.deinit();
        try pack.validate(a, original, candidate.program, candidate.maps, .{});
        try std.testing.expect(candidate.program.functions[0].layout.slots.len < count);
        const edge = candidate.program.blocks[0].terminator.jump;
        try std.testing.expect(edge.assignments[0].destination != edge.assignments[1].destination);
        try std.testing.expect(edge.assignments[0].source.slot != edge.assignments[1].source.slot);
    }
}
test "suspension and internal ownership state retain distinct logical storage" {
    var original = chain;
    original.blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .yield_value = .{ .block = 1 } },
        },
        chain.blocks[0],
    };
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try pack.construct(a, original, .{}) == null);
    try std.testing.expect(try pack.construct(
        a,
        @import("tail_duplication_tests.zig").cell_effect,
        .{},
    ) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try pack.run(allocator, chain, null, .{});
    defer result.deinit();
}
test "packing allocation failure and work exhaustion retain P01" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: pack.Statistics = .{};
    var result = try pack.run(a, chain, &stats, .{ .work_limit = 0 });
    defer result.deinit();
    var baseline = try @import("coalescing.zig").run(a, chain, .{});
    defer baseline.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, result.program),
    );
}

test "unreachable parallel destinations still need distinct slots" {
    var original = chain;
    original.blocks = &.{
        chain.blocks[0],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .jump = .{
                .block = 1,
                .assignments = &.{
                    .{ .destination = 1, .source = .{ .slot = 0 } },
                    .{ .destination = 2, .source = .{ .slot = 0 } },
                },
            } },
        },
    };
    var candidate = (try pack.construct(a, original, .{})).?;
    defer candidate.deinit();
    try pack.validate(a, original, candidate.program, candidate.maps, .{});
    try std.testing.expect(candidate.maps[0].?[1] != candidate.maps[0].?[2]);
}
test "shared compiler selects packing and retains its fixed point" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        chain,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    try std.testing.expectEqual(@as(usize, 2), result.program.functions[0].layout.slots.len);
    var again = try @import("closed_compilation.zig").run(
        a,
        result.program,
        .{ .contract = .semantic },
    );
    defer again.deinit();
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, result.program),
        try @import("program_image.zig").identity(a, again.program),
    );
}

test "a transfer becomes removable only after its storage mapping is an identity" {
    var original = chain;
    original.constants = &.{.{ .schema = 0, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 } }};
    original.functions = &.{.{
        .entry = 0,
        .inputs = &.{0},
        .layout = .{ .slots = &.{ 0, 0, 0 } },
        .result = 0,
    }};
    original.blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 1, .opcode = .constant }},
            .terminator = .{ .jump = .{
                .block = 1,
                .assignments = &.{.{ .destination = 2, .source = .{ .slot = 1 } }},
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var candidate = (try pack.construct(a, original, .{})).?;
    defer candidate.deinit();
    try pack.validate(a, original, candidate.program, candidate.maps, .{});
    try std.testing.expectEqual(
        @as(usize, 0),
        candidate.program.blocks[0].terminator.jump.assignments.len,
    );
    try std.testing.expectEqual(candidate.maps[0].?[1], candidate.maps[0].?[2]);
}
