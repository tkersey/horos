// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const patterns = @import("call_patterns.zig");
const own = @import("activation_ownership.zig");
const a = std.testing.allocator;
pub const countdown: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64, .unit, .boolean,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .use = .reusable,
        } } },
    },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{} },
    },
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 3, 0, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 3, 0, 0, 0, 0, 0, 2, 0, 0, 0 } },
            .result = 0,
        },
        .{ .entry = 7, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 2, .opcode = .computation, .immediate = 0 },
                .{ .destination = 3, .opcode = .constant, .immediate = 0 },
            },
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 2, 0, 1, 3 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 4, .opcode = .constant, .immediate = 0 },
                .{ .destination = 5, .opcode = .constant, .immediate = 1 },
                .{ .destination = 6, .opcode = .equal, .operands = &.{ 1, 4 } },
            },
            .terminator = .{ .branch = .{
                .condition = 6,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{
            .function = 1,
            .instructions = &.{
                .{
                    .destination = 7,
                    .opcode = .integer_sub,
                    .operands = &.{ 1, 5 },
                    .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
                },
                .{
                    .destination = 8,
                    .opcode = .integer_add,
                    .operands = &.{ 3, 5 },
                    .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
                },
            },
            .terminator = .{ .apply = .{
                .computation = 0,
                .arguments = &.{2},
                .next = .{
                    .block = 5,
                    .assignments = &.{.{ .destination = 9, .source = .returned }},
                },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 7, 9, 8 },
                .next = .{
                    .block = 6,
                    .assignments = &.{.{ .destination = 9, .source = .returned }},
                },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 9 } },
        .{
            .function = 2,
            .instructions = &.{.{
                .destination = 1,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 1 },
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{.{ .function = 2, .capture = 0, .schema = 3 }},
};
pub fn withOpaqueEffect(allocator: std.mem.Allocator) !ir.Program {
    var result = countdown;
    result.effects = &.{.{ .identity = "p29/opaque", .payload = 0, .result = 0 }};
    const functions = try allocator.dupe(ir.Function, countdown.functions);
    functions[0].effects = &.{0};
    functions[1].effects = &.{0};
    result.functions = functions;
    const blocks = try allocator.alloc(ir.Block, countdown.blocks.len + 1);
    @memcpy(blocks[0..countdown.blocks.len], countdown.blocks);
    blocks[4].terminator = .{ .perform = .{
        .effect = 0,
        .payload = 2,
        .next = .{ .block = 8, .assignments = &.{.{ .destination = 9, .source = .returned }} },
    } };
    blocks[8] = .{
        .function = 1,
        .instructions = &.{},
        .terminator = .{ .apply = .{
            .computation = 0,
            .arguments = &.{9},
            .next = countdown.blocks[4].terminator.apply.next,
        } },
    };
    result.blocks = blocks;
    return result;
}
test "unknown effect stays residual with its nominal identity payload and continuation" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try withOpaqueEffect(arena.allocator());
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        10_000_000,
    );
    const copied = candidate.program.blocks[
        candidate.variants[0].first_block +
            2
    ].terminator.perform;
    try std.testing.expectEqual(@as(u64, 0), copied.effect);
    try std.testing.expectEqual(@as(u64, 2), copied.payload);
    var stats: patterns.Statistics = .{};
    var result = try patterns.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.residual_boundaries);
    try std.testing.expectEqual(@as(usize, 1), stats.folded_calls);
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[candidate.variants[0].first_block + 2].terminator.perform.payload = 3;
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try own.analyze(a, wrong);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, original, wrong, candidate.variants, candidate.sites, 10_000_000),
    );
}

test "equivalent recursive configurations reuse workers while distinct counters stay dynamic" {
    var original = countdown;
    var functions = countdown.functions[0..3].*;
    functions[0].inputs = &.{ 0, 1, 5 };
    functions[0].layout.slots = &.{ 0, 0, 3, 0, 0, 2 };
    original.functions = &functions;
    var blocks: [10]ir.Block = undefined;
    @memcpy(blocks[0..8], countdown.blocks);
    blocks[0].terminator = .{ .branch = .{
        .condition = 5,
        .when_true = .{ .block = 8 },
        .when_false = .{ .block = 9 },
    } };
    blocks[8] = .{
        .function = 0,
        .instructions = &.{},
        .terminator = countdown.blocks[0].terminator,
    };
    blocks[9] = .{
        .function = 0,
        .instructions = &.{.{ .destination = 3, .opcode = .constant, .immediate = 1 }},
        .terminator = countdown.blocks[0].terminator,
    };
    original.blocks = &blocks;
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        10_000_000,
    );
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    try std.testing.expectEqual(@as(usize, 2), candidate.sites.len);
    try std.testing.expectEqual(
        candidate.program.blocks[8].terminator.call.function,
        candidate.program.blocks[9].terminator.call.function,
    );
    try std.testing.expectEqualSlices(usize, &.{3}, candidate.variants[0].generalized_parameters);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try patterns.run(allocator, countdown, null, .{});
    defer result.deinit();
}
test "recursive worker generation and certificate clean allocation failures" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}
test "recursive specialization folds invariant constructors and generalizes growing arguments" {
    var candidate = (try patterns.construct(a, countdown, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        countdown,
        candidate.program,
        candidate.variants,
        candidate.sites,
        10_000_000,
    );
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    const variant = candidate.variants[0];
    try std.testing.expectEqualSlices(usize, &.{3}, variant.generalized_parameters);
    try std.testing.expectEqual(
        @as(usize, 3),
        candidate.program.functions[@intCast(variant.function)].inputs.len,
    );
    const recursive = candidate.program.blocks[variant.first_block + 3].terminator.call;
    try std.testing.expectEqual(variant.function, recursive.function);
    try std.testing.expectEqualSlices(u64, &.{ 7, 9, 8 }, recursive.arguments);
    var stats: patterns.Statistics = .{};
    var result = try patterns.run(a, countdown, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.folded_calls);
    try std.testing.expectEqual(@as(usize, 1), stats.generalized_parameters);
    try std.testing.expect(!stats.work_limit);
}
test "admitted wrong recursive argument and false generalization fail the worker certificate" {
    var candidate = (try patterns.construct(a, countdown, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[candidate.variants[0].first_block + 3].terminator.call.arguments = &.{ 8, 9, 7 };
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try own.analyze(a, wrong);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, countdown, wrong, candidate.variants, candidate.sites, 10_000_000),
    );
    const variants = try a.dupe(patterns.Variant, candidate.variants);
    defer a.free(variants);
    variants[0].generalized_parameters = &.{1};
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(
            a,
            countdown,
            candidate.program,
            variants,
            candidate.sites,
            10_000_000,
        ),
    );
}
test "changing the recursive selector is not the same specialization configuration" {
    var original = countdown;
    var blocks = countdown.blocks[0..8].*;
    original.blocks = &blocks;
    blocks[5].instructions = &.{.{ .destination = 0, .opcode = .computation, .immediate = 0 }};
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try patterns.construct(a, original, .{}) == null);
}
