// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const patterns = @import("call_patterns.zig");
const a = std.testing.allocator;
pub const choice: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .boolean, .unit },
    .constants = &.{ .{ .schema = 1, .bytes = &.{1} }, .{ .schema = 1, .bytes = &.{0} } },
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 1, 1, 0 } },
            .result = 0,
        },
        .{
            .entry = 4,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 1, 0, 0 } },
            .result = 0,
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
            .instructions = &.{.{ .destination = 3, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 3, 0, 1 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 3, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 3, 0, 1 },
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
                .condition = 0,
                .when_true = .{ .block = 5 },
                .when_false = .{ .block = 6 },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
};
test "proved Boolean parameters select private branches and leave argument order" {
    var candidate = (try patterns.construct(a, choice, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        choice,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 2), candidate.variants.len);
    try std.testing.expect(candidate.variants[0].key.value.boolean);
    try std.testing.expect(!candidate.variants[1].key.value.boolean);
    for (candidate.variants) |variant| try std.testing.expect(
        candidate.program.blocks[variant.first_block].terminator == .jump,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{ 0, 1 },
        candidate.program.blocks[1].terminator.call.arguments,
    );
    var stats: patterns.Statistics = .{};
    var result = try patterns.run(a, choice, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.constant_branches);
}
test "wrong selected branch and false constant certificate reject independently" {
    var candidate = (try patterns.construct(a, choice, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[candidate.variants[0].first_block].terminator.jump.block += 1;
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, choice, wrong, candidate.variants, candidate.sites, 1000000),
    );
    var variants = candidate.variants[0..2].*;
    variants[0].key.value.boolean = false;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, choice, candidate.program, &variants, candidate.sites, 1000000),
    );
}
test "unknown Boolean retains generic worker beside the constant specialization" {
    var original = choice;
    var functions = choice.functions[0..2].*;
    functions[0].inputs = &.{ 0, 1, 2, 3 };
    original.functions = &functions;
    var blocks = choice.blocks[0..7].*;
    blocks[1].instructions = &.{};
    original.blocks = &blocks;
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[1].terminator.call.function);
}
test "changed constant bytes invalidate an old specialization" {
    var candidate = (try patterns.construct(a, choice, .{})).?;
    defer candidate.deinit();
    var changed = choice;
    changed.constants = &.{ choice.constants[1], choice.constants[0] };
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(
            a,
            changed,
            candidate.program,
            candidate.variants,
            candidate.sites,
            1000000,
        ),
    );
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try patterns.run(allocator, choice, null, .{});
    defer result.deinit();
}
test "constant worker allocation failures release owners and variant limit rolls back" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: patterns.Statistics = .{};
    var limited = try patterns.run(a, choice, &stats, .{ .max_variants = 1 });
    defer limited.deinit();
    var baseline = try @import("coalescing.zig").run(a, choice, .{});
    defer baseline.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
}
test "shared pipeline selects constant argument specialization" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        choice,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    var branches: usize = 0;
    for (result.program.blocks) |block| {
        if (block.terminator == .branch) branches += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), branches);
}

test "selected constants without an origin proof retain a valid generic call" {
    var original = choice;
    var blocks = choice.blocks[0..7].*;
    blocks[1].instructions = &.{
        choice.blocks[1].instructions[0],
        .{ .destination = 3, .opcode = .select, .operands = &.{ 2, 3, 3 } },
    };
    original.blocks = &blocks;
    var stats: patterns.Statistics = .{};
    var result = try patterns.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.rewritten_calls);
    try std.testing.expectEqual(@as(usize, 1), stats.generic_fallback_calls);
    var compiled = try @import("closed_compilation.zig").run(
        a,
        original,
        .{ .contract = .semantic },
    );
    defer compiled.deinit();
}
