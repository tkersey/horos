// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const patterns = @import("call_patterns.zig");
const a = std.testing.allocator;
pub const tagged: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .boolean, .unit, .{ .sum = &.{ 0, 0 } } },
    .constants = &.{.{ .schema = 2, .bytes = &.{} }},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 1, 1, 3, 0 } },
            .result = 0,
        },
        .{ .entry = 6, .inputs = &.{0}, .layout = .{ .slots = &.{ 3, 0 } }, .result = 0 },
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
            .instructions = &.{.{
                .destination = 4,
                .opcode = .variant,
                .operands = &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{4},
                .next = .{
                    .block = 5,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 3,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .variant,
                .operands = &.{1},
                .immediate = 0,
            }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{4},
                .next = .{
                    .block = 5,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .variant,
                .operands = &.{0},
                .immediate = 1,
            }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{4},
                .next = .{
                    .block = 5,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 5 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 1,
                .opcode = .variant_payload,
                .operands = &.{0},
                .immediate = 0,
                .failures = &.{.{ .kind = .invalid_variant, .value = 0 }},
            }},
            .terminator = .{ .return_value = 1 },
        },
    },
};
test "known tag reuses a payload worker without specializing runtime payload values" {
    var candidate = (try patterns.construct(a, tagged, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        tagged,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    try std.testing.expectEqual(@as(usize, 2), candidate.sites.len);
    try std.testing.expectEqual(@as(u64, 0), candidate.variants[0].key.value.variant);
    try std.testing.expectEqualSlices(
        u64,
        &.{0},
        candidate.program.blocks[1].terminator.call.arguments,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{1},
        candidate.program.blocks[3].terminator.call.arguments,
    );
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[4].terminator.call.function);
    try std.testing.expectEqual(
        .move,
        candidate.program.blocks[candidate.variants[0].first_block].instructions[0].opcode,
    );
    var stats: patterns.Statistics = .{};
    var result = try patterns.run(a, tagged, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.variant_projections);
    try std.testing.expectEqual(@as(usize, 1), stats.generic_fallback_calls);
}
test "admissible wrong runtime payload and forged static tag are rejected" {
    var candidate = (try patterns.construct(a, tagged, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..8].*;
    blocks[1].terminator.call.arguments = &.{1};
    var wrong = candidate.program;
    wrong.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, tagged, wrong, candidate.variants, candidate.sites, 1000000),
    );
    var sites = candidate.sites[0..2].*;
    sites[0].payload = 1;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, tagged, wrong, candidate.variants, &sites, 1000000),
    );
    var variants = candidate.variants[0..1].*;
    variants[0].key.value = .{ .variant = 1 };
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, tagged, candidate.program, &variants, candidate.sites, 1000000),
    );
}
test "overwritten payload retains the boxed original value" {
    var original = tagged;
    var blocks = tagged.blocks[0..7].*;
    blocks[1].instructions = &.{
        tagged.blocks[1].instructions[0],
        .{ .destination = 0, .opcode = .integer_bit_not, .operands = &.{0} },
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
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 1), candidate.sites.len);
    try std.testing.expectEqual(@as(usize, 3), candidate.sites[0].block);
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[1].terminator.call.function);
}
test "shared semantic pipeline removes selected constructor and decomposition" {
    var original = tagged;
    var blocks = tagged.blocks[0..7].*;
    blocks[4].instructions = tagged.blocks[1].instructions;
    original.blocks = &blocks;
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        original,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    for (result.program.blocks) |block| for (block.instructions) |op| try std.testing.expect(
        op.opcode != .variant and op.opcode != .variant_payload,
    );
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try patterns.run(allocator, tagged, null, .{});
    defer result.deinit();
}
test "variant worker allocation failures release all owners" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "selected tag removes a switch while preserving its edge assignments" {
    var original = tagged;
    var functions = tagged.functions[0..2].*;
    functions[1].layout.slots = &.{ 3, 0, 2 };
    original.functions = &functions;
    var blocks: [9]ir.Block = undefined;
    @memcpy(blocks[0..7], tagged.blocks);
    blocks[6] = .{
        .function = 1,
        .instructions = &.{},
        .terminator = .{ .switch_variant = .{
            .value = 0,
            .cases = &.{ .{ .block = 7 }, .{ .block = 8 } },
        } },
    };
    blocks[7] = tagged.blocks[6];
    blocks[8] = .{
        .function = 1,
        .instructions = &.{.{ .destination = 2, .opcode = .constant }},
        .terminator = .{ .fail = 2 },
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
        1000000,
    );
    const entry = candidate.variants[0].first_block;
    try std.testing.expectEqual(
        @as(u64, entry + 1),
        candidate.program.blocks[entry].terminator.jump.block,
    );
    const modified = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(modified);
    modified[entry].terminator.jump.block = entry + 2;
    var wrong = candidate.program;
    wrong.blocks = modified;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, original, wrong, candidate.variants, candidate.sites, 1000000),
    );
}
test "same-shape alternate schema cannot relabel a static variant key" {
    var original = tagged;
    original.schemas = &.{
        tagged.schemas[0],
        tagged.schemas[1],
        tagged.schemas[2],
        tagged.schemas[3],
        tagged.schemas[3],
    };
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    var variants = candidate.variants[0..1].*;
    variants[0].key.schema = 4;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, original, candidate.program, &variants, candidate.sites, 1000000),
    );
}

pub const returned_payload: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .{ .sum = &.{ 0, 0 } } },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{ 0, 2 }, .layout = .{ .slots = &.{ 0, 2, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{ 0, 2 }, .layout = .{ .slots = &.{ 2, 0, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 1,
                .opcode = .variant,
                .operands = &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 1, 2 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .switch_variant = .{
                .value = 0,
                .cases = &.{
                    .{ .block = 3, .assignments = &.{.{ .destination = 1, .source = .returned }} },
                    .{ .block = 4, .assignments = &.{.{ .destination = 1, .source = .returned }} },
                },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    },
};

test "known variant switch transports returned payload to specialized jump" {
    for ([_]u64{ 0, 1 }) |tag| {
        var original = returned_payload;
        var blocks = returned_payload.blocks[0..5].*;
        var op = blocks[0].instructions[0];
        op.immediate = tag;
        blocks[0].instructions = (&op)[0..1];
        original.blocks = &blocks;
        var admitted = try @import("activation_ownership.zig").analyze(a, original);
        defer admitted.deinit();
        var candidate = (try patterns.construct(a, original, .{})).?;
        defer candidate.deinit();
        try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
        try patterns.validate(
            a,
            original,
            candidate.program,
            candidate.variants,
            candidate.sites,
            1000000,
        );
        const entry = candidate.variants[0].first_block;
        const edge = candidate.program.blocks[entry].terminator.jump;
        try std.testing.expectEqual(@as(u64, 0), edge.assignments[0].source.slot);
        var compiled = try @import("closed_compilation.zig").run(
            a,
            original,
            .{ .contract = .semantic },
        );
        defer compiled.deinit();
        const wrong_blocks = try a.dupe(ir.Block, candidate.program.blocks);
        defer a.free(wrong_blocks);
        wrong_blocks[entry].terminator.jump.assignments = &.{.{
            .destination = 1,
            .source = .returned,
        }};
        var wrong = candidate.program;
        wrong.blocks = wrong_blocks;
        try std.testing.expectError(
            error.TypeMismatch,
            @import("activation_ownership.zig").analyze(a, wrong),
        );
        wrong_blocks[entry].terminator.jump.assignments = &.{.{
            .destination = 1,
            .source = .{ .slot = 2 },
        }};
        var admitted_wrong = try @import("activation_ownership.zig").analyze(a, wrong);
        defer admitted_wrong.deinit();
        try std.testing.expectError(
            error.InvalidCallPattern,
            patterns.validate(a, original, wrong, candidate.variants, candidate.sites, 1000000),
        );
    }
}
