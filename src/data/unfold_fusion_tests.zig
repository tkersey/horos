// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const a = std.testing.allocator;
/// A lazy unfold step returns (value, delayed successor). The successor after
/// true diverges; the consumer must stop without invoking it.
pub const unfold: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .boolean,                   .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = 3,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
        .{ .product = &.{ 0, 2 } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 3, 0, 2, 0 } },
            .result = 0,
        },
        .{ .entry = 4, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 2, 3 } }, .result = 3 },
        .{ .entry = 5, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0, 3 } }, .result = 3 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{0},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{
            .{ .destination = 3, .opcode = .field, .operands = &.{2}, .immediate = 0 },
            .{ .destination = 4, .opcode = .field, .operands = &.{2}, .immediate = 1 },
            .{ .destination = 5, .opcode = .boolean_not, .operands = &.{1} },
            .{ .destination = 1, .opcode = .select, .operands = &.{ 3, 5, 1 } },
        }, .terminator = .{ .branch = .{
            .condition = 3,
            .when_true = .{ .block = 2 },
            .when_false = .{ .block = 3 },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 4,
                .arguments = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 1, .opcode = .computation, .operands = &.{0}, .immediate = 0 },
                .{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } },
            },
            .terminator = .{ .return_value = 2 },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 0,
                .when_true = .{ .block = 6 },
                .when_false = .{ .block = 7 },
            } },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 6 } } },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 1, .opcode = .boolean_not, .operands = &.{0} }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{1},
                .next = .{
                    .block = 8,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
    .constructors = &.{.{ .function = 2, .capture = 0, .schema = 2 }},
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
};
test "early-stop unfold and its divergent delayed successor are admitted" {
    var original = try @import("activation_ownership.zig").analyze(a, unfold);
    original.deinit();
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var current = try @import("closed_compilation.zig").run(
        a,
        unfold,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer current.deinit();
    var constructors: usize = 0;
    var applications: usize = 0;
    for (current.program.blocks) |block| {
        for (block.instructions) |op| {
            constructors += @intFromBool(op.opcode == .computation);
        }
        applications += @intFromBool(block.terminator == .apply);
    }
    try std.testing.expectEqual(@as(usize, 0), constructors);
    try std.testing.expectEqual(@as(usize, 0), applications);
    std.debug.print(
        "shared unfold: constructors={d} applies={d} {any}\n",
        .{ constructors, applications, stats },
    );
}

test "known delayed successor becomes state and is called only at the old apply site" {
    const fusion = @import("unfold_fusion.zig");
    var candidate = (try fusion.construct(a, unfold, .{})).?;
    defer candidate.deinit();
    try fusion.validate(a, unfold, candidate.program, .{});
    try std.testing.expect(candidate.program.blocks[1].terminator == .branch);
    try std.testing.expect(candidate.program.blocks[2].terminator == .return_value);
    try std.testing.expect(candidate.program.blocks[3].terminator == .call);
    try std.testing.expectEqualSlices(
        u64,
        &.{4},
        candidate.program.blocks[3].terminator.call.arguments,
    );
    try std.testing.expectEqual(@as(u64, 2), candidate.program.blocks[3].terminator.call.function);
    var stats: fusion.Statistics = .{};
    var selected = try fusion.run(a, unfold, &stats, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.protocols_fused);
    for (selected.program.blocks) |block| {
        try std.testing.expect(block.terminator != .apply);
        for (block.instructions) |op| try std.testing.expect(op.opcode != .computation);
    }
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("unfold_fusion.zig").run(allocator, unfold, null, .{});
    defer result.deinit();
}
test "unfold allocation failures and work exhaustion preserve original ownership" {
    const fusion = @import("unfold_fusion.zig");
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, unfold, .{});
    defer baseline.deinit();
    var stats: fusion.Statistics = .{};
    var limited = try fusion.run(a, unfold, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
    var invalid = unfold;
    invalid.roots.entry = 100;
    try std.testing.expectError(
        error.InvalidReference,
        fusion.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}
test "admissible wrong captured state and successor hoisting are rejected independently" {
    const fusion = @import("unfold_fusion.zig");
    var candidate = (try fusion.construct(a, unfold, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..9].*;
    var forged = candidate.program;
    forged.blocks = &blocks;
    blocks[3].terminator.call.arguments = &.{1};
    var admitted = try @import("activation_ownership.zig").analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(error.InvalidUnfoldFusion, fusion.validate(a, unfold, forged, .{}));
    blocks = candidate.program.blocks[0..9].*;
    blocks[1].terminator = .{ .call = .{
        .function = 2,
        .arguments = &.{4},
        .next = .{ .block = 2 },
    } };
    admitted = try @import("activation_ownership.zig").analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(error.InvalidUnfoldFusion, fusion.validate(a, unfold, forged, .{}));
}
test "two actual successor implementations do not collapse into one known function" {
    var original = unfold;
    original.constructors = &.{
        unfold.constructors[0],
        .{ .function = 1, .capture = 0, .schema = 2 },
    };
    var functions = unfold.functions[0..3].*;
    functions[1].layout.slots = &.{ 0, 2, 3, 2, 2 };
    original.functions = &functions;
    var blocks = unfold.blocks[0..9].*;
    blocks[4].instructions = &.{
        .{ .destination = 1, .opcode = .computation, .operands = &.{0}, .immediate = 0 },
        .{ .destination = 3, .opcode = .computation, .operands = &.{0}, .immediate = 1 },
        .{ .destination = 4, .opcode = .select, .operands = &.{ 0, 1, 3 } },
        .{ .destination = 2, .opcode = .product, .operands = &.{ 0, 4 } },
    };
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    admitted.deinit();
    var candidate = try @import("unfold_fusion.zig").construct(a, original, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}
