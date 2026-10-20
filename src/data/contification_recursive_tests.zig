// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const joins = @import("contification.zig");
const a = std.testing.allocator;
pub const mutual: ir.Program = .{
    .roots = .{ .entry = 0, .result = 2, .failure = 3 },
    .schemas = &.{ .u64, .boolean, .{ .product = &.{ 0, 0 } }, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 1, 1, 2 } },
            .result = 2,
        },
        .{
            .entry = 4,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 1, 2 } },
            .result = 2,
        },
        .{
            .entry = 8,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 1, 2 } },
            .result = 2,
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 1, 3 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 2,
                .arguments = &.{ 0, 1, 3 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 5 },
                .when_false = .{ .block = 7 },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 2,
                .arguments = &.{ 0, 1, 2 },
                .next = .{
                    .block = 6,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 3, .opcode = .product, .operands = &.{ 0, 1 } }},
            .terminator = .{ .return_value = 3 },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 9 },
                .when_false = .{ .block = 11 },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 2, .opcode = .boolean_not, .operands = &.{2} }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 1, 0, 2 },
                .next = .{
                    .block = 10,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 3, .opcode = .product, .operands = &.{ 1, 0 } }},
            .terminator = .{ .return_value = 3 },
        },
    },
};
test "mutually recursive tail workers form one closed local join group" {
    var candidate = (try joins.construct(a, mutual, .{})).?;
    defer candidate.deinit();
    try joins.validate(a, mutual, candidate.program, candidate.witness, .{});
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, candidate.witness.helpers);
    try std.testing.expectEqual(@as(usize, 20), candidate.program.blocks.len);
    // The A -> B -> A path is represented by two actual local transfers.
    try std.testing.expectEqual(@as(u64, 16), candidate.program.blocks[13].terminator.jump.block);
    try std.testing.expectEqual(
        @as(usize, 0),
        candidate.program.blocks[13].terminator.jump.assignments.len,
    );
    try std.testing.expectEqual(@as(u64, 12), candidate.program.blocks[17].terminator.jump.block);
    try std.testing.expectEqual(
        @as(u64, 6),
        candidate.program.blocks[17].terminator.jump.assignments[0].source.slot,
    );
    var stats: joins.Statistics = .{};
    var result = try joins.run(a, mutual, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.helpers);
    try std.testing.expectEqual(@as(usize, 4), stats.calls_removed);
    try std.testing.expectEqual(@as(usize, 1), result.program.functions.len);
    for (result.program.blocks) |block| try std.testing.expect(block.terminator != .call);
}
test "independent checker rejects same-type recursive argument mutation" {
    var candidate = (try joins.construct(a, mutual, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..20].*;
    var assignments = blocks[17].terminator.jump.assignments[0..2].*;
    assignments[0].source.slot = 5;
    blocks[17].terminator.jump.assignments = &assignments;
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidContification,
        joins.validate(a, mutual, wrong, candidate.witness, .{}),
    );
    var omitted = candidate.witness;
    omitted.helpers = &.{1};
    try std.testing.expectError(
        error.InvalidContification,
        joins.validate(a, mutual, candidate.program, omitted, .{}),
    );
}
test "non-tail work in either recursive continuation rejects the group" {
    var original = mutual;
    var blocks = mutual.blocks[0..12].*;
    blocks[6].instructions = &.{.{ .destination = 3, .opcode = .product, .operands = &.{ 1, 0 } }};
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try joins.construct(a, original, .{}) == null);
}
test "an escaping constructor member rejects the entire recursive group" {
    var original = mutual;
    original.schemas = &.{
        mutual.schemas[0], mutual.schemas[1], mutual.schemas[2], mutual.schemas[3],
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 0, 0, 1 },
            .result = 2,
            .use = .reusable,
        } } },
    };
    original.scopes.captures = &.{.{ .fields = &.{}, .use = .reusable }};
    original.constructors = &.{.{ .function = 2, .capture = 0, .schema = 4 }};
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    try std.testing.expect(try joins.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try joins.run(allocator, mutual, null, .{});
    defer result.deinit();
}
test "recursive join allocation and group limits preserve baseline ownership" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: joins.Statistics = .{};
    var result = try joins.run(a, mutual, &stats, .{ .max_helpers = 1 });
    defer result.deinit();
    var baseline = try @import("coalescing.zig").run(a, mutual, .{});
    defer baseline.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, result.program),
    );
}
test "shared pipeline adopts recursive join conversion" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        mutual,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    std.debug.print("recursive selection: {any}\n", .{stats});
    try std.testing.expectEqual(.full, stats.selected_candidate);
    try std.testing.expectEqual(@as(usize, 1), result.program.functions.len);
}

test "different helper layouts retain separate banks" {
    var original = mutual;
    var functions = mutual.functions[0..3].*;
    functions[2].layout.slots = &.{ 0, 0, 1, 2, 0 };
    original.functions = &functions;
    var candidate = (try joins.construct(a, original, .{})).?;
    defer candidate.deinit();
    try joins.validate(a, original, candidate.program, candidate.witness, .{});
    try std.testing.expectEqual(@as(usize, 14), candidate.program.functions[0].layout.slots.len);
}
test "a forged recursive target cannot introduce a new infinite loop" {
    var candidate = (try joins.construct(a, mutual, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..20].*;
    blocks[13].terminator.jump.block = 12;
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidContification,
        joins.validate(a, mutual, wrong, candidate.witness, .{}),
    );
}
