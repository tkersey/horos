// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const a = std.testing.allocator;

/// Two real loops: eager map into a bounded vector, followed by a total fold.
pub const map_fold: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .boolean,                                       .unit,
        .{ .vector = .{ .element = 0, .maximum = 8 } }, .{ .product = &.{ 0, 2 } },
        .{ .sum = &.{ 1, 3 } },
        .{
            .vector = .{ .element = 0, .maximum = 8 },
        },
        .{ .product = &.{ 0, 5 } },                     .{ .sum = &.{ 1, 6 } },
    },
    .constants = &.{.{ .schema = 1, .bytes = &.{} }},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 2, 0, 5, 4, 3, 0, 2, 0, 5, 7, 6, 0, 5, 0 } },
            .result = 0,
        },
        .{ .entry = 9, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
        .{
            .entry = 10,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0 } },
            .result = 0,
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .sequence }},
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 3, .opcode = .sequence_pop, .operands = &.{0} }},
            .terminator = .{ .switch_variant = .{
                .value = 3,
                .cases = &.{ .{ .block = 4 }, .{ .block = 2 } },
            } },
        },
        .{ .function = 0, .instructions = &.{
            .{
                .destination = 4,
                .opcode = .variant_payload,
                .operands = &.{3},
                .immediate = 1,
                .failures = &.{.{ .kind = .invalid_variant, .value = 0 }},
            },
            .{ .destination = 5, .opcode = .field, .operands = &.{4}, .immediate = 0 },
            .{ .destination = 6, .opcode = .field, .operands = &.{4}, .immediate = 1 },
        }, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{5},
            .next = .{ .block = 3, .assignments = &.{.{ .destination = 7, .source = .returned }} },
        } } },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .sequence_append,
                .operands = &.{ 2, 7 },
                .failures = &.{.{ .kind = .capacity_exceeded, .value = 0 }},
            }},
            .terminator = .{ .jump = .{
                .block = 1,
                .assignments = &.{.{ .destination = 0, .source = .{ .slot = 6 } }},
            } },
        },
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 8, .opcode = .move, .operands = &.{2} },
                .{ .destination = 13, .opcode = .move, .operands = &.{1} },
            },
            .terminator = .{ .jump = .{ .block = 5 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 9, .opcode = .sequence_pop, .operands = &.{8} }},
            .terminator = .{ .switch_variant = .{
                .value = 9,
                .cases = &.{ .{ .block = 8 }, .{ .block = 6 } },
            } },
        },
        .{ .function = 0, .instructions = &.{
            .{
                .destination = 10,
                .opcode = .variant_payload,
                .operands = &.{9},
                .immediate = 1,
                .failures = &.{.{ .kind = .invalid_variant, .value = 0 }},
            },
            .{ .destination = 11, .opcode = .field, .operands = &.{10}, .immediate = 0 },
            .{ .destination = 12, .opcode = .field, .operands = &.{10}, .immediate = 1 },
        }, .terminator = .{ .call = .{
            .function = 2,
            .arguments = &.{ 13, 11 },
            .next = .{
                .block = 7,
                .assignments = &.{.{ .destination = 13, .source = .returned }},
            },
        } } },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .jump = .{
                .block = 5,
                .assignments = &.{.{ .destination = 8, .source = .{ .slot = 12 } }},
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 13 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 1, .opcode = .boolean_not, .operands = &.{0} }},
            .terminator = .{ .return_value = 1 },
        },
        .{
            .function = 2,
            .instructions = &.{
                .{ .destination = 2, .opcode = .boolean_not, .operands = &.{1} },
                .{ .destination = 3, .opcode = .select, .operands = &.{ 0, 2, 0 } },
            },
            .terminator = .{ .return_value = 3 },
        },
    },
};

test "map/fold source and its failing smaller-capacity sibling are independently admitted" {
    var valid = try own.analyze(a, map_fold);
    valid.deinit();
    var small = map_fold;
    var schemas = map_fold.schemas[0..8].*;
    schemas[5].vector.maximum = 7;
    small.schemas = &schemas;
    valid = try own.analyze(a, small);
    valid.deinit();
}

test "bounded total map/fold removes the intermediate vector and the second traversal" {
    const fusion = @import("sequence_fusion.zig");
    var candidate = (try fusion.construct(a, map_fold, .{})).?;
    defer candidate.deinit();
    try fusion.validate(a, map_fold, candidate.program, candidate.sites, .{});
    var stats: fusion.Statistics = .{};
    var result = try fusion.run(a, map_fold, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.loops_fused);
    var pops: usize = 0;
    for (result.program.blocks) |block| for (block.instructions) |op| {
        try std.testing.expect(op.opcode != .sequence and op.opcode != .sequence_append);
        pops += @intFromBool(op.opcode == .sequence_pop);
    };
    try std.testing.expectEqual(@as(usize, 1), pops);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("sequence_fusion.zig").run(allocator, map_fold, null, .{});
    defer result.deinit();
}
test "sequence fusion releases each failed allocation and limits roll back through P01" {
    const fusion = @import("sequence_fusion.zig");
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, map_fold, .{});
    defer baseline.deinit();
    var stats: fusion.Statistics = .{};
    var limited = try fusion.run(a, map_fold, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
    var invalid = map_fold;
    invalid.roots.entry = 100;
    try std.testing.expectError(
        error.InvalidReference,
        fusion.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}
test "independently admitted wrong fold argument order and wrong suffix are rejected" {
    const fusion = @import("sequence_fusion.zig");
    var candidate = (try fusion.construct(a, map_fold, .{})).?;
    defer candidate.deinit();
    var changed = candidate.program.blocks[0..11].*;
    var forged = candidate.program;
    forged.blocks = &changed;
    changed[3].terminator.call.arguments = &.{ 7, 13 };
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidSequenceFusion,
        fusion.validate(a, map_fold, forged, candidate.sites, .{}),
    );
    changed = candidate.program.blocks[0..11].*;
    changed[7].terminator.jump.assignments = &.{.{ .destination = 0, .source = .{ .slot = 0 } }};
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidSequenceFusion,
        fusion.validate(a, map_fold, forged, candidate.sites, .{}),
    );
}
test "potential capacity fault is retained rather than optimized away" {
    var original = map_fold;
    var schemas = map_fold.schemas[0..8].*;
    schemas[5].vector.maximum = 7;
    original.schemas = &schemas;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    var candidate = try @import("sequence_fusion.zig").construct(a, original, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}
test "returned or separately observed intermediate blocks fusion" {
    const fusion = @import("sequence_fusion.zig");
    for ([_]bool{ false, true }) |returned| {
        var original = map_fold;
        var functions = map_fold.functions[0..3].*;
        var blocks = map_fold.blocks[0..11].*;
        var schemas: [9]p.Schema = undefined;
        @memcpy(schemas[0..8], map_fold.schemas);
        schemas[8] = .u64;
        original.functions = &functions;
        original.blocks = &blocks;
        if (returned) {
            original.roots.result = 5;
            functions[0].result = 5;
            blocks[8].terminator = .{ .return_value = 2 };
        } else {
            original.schemas = &schemas;
            original.roots.result = 8;
            functions[0].result = 8;
            functions[0].layout.slots = &.{ 2, 0, 5, 4, 3, 0, 2, 0, 5, 7, 6, 0, 5, 0, 8 };
            blocks[8].instructions = &.{.{
                .destination = 14,
                .opcode = .sequence_length,
                .operands = &.{2},
            }};
            blocks[8].terminator = .{ .return_value = 14 };
        }
        var admitted = try own.analyze(a, original);
        admitted.deinit();
        var candidate = try fusion.construct(a, original, .{});
        defer if (candidate) |*value| value.deinit();
        try std.testing.expect(candidate == null);
    }
}

pub fn failingSteps(allocator: std.mem.Allocator) !ir.Program {
    var original = map_fold;
    original.roots.failure = 0;
    original.constants = &.{ .{ .schema = 0, .bytes = &.{0} }, .{ .schema = 0, .bytes = &.{1} } };
    const functions = try allocator.dupe(ir.Function, original.functions);
    functions[1].layout.slots = &.{ 0, 0, 0 };
    original.functions = functions;
    const blocks = try allocator.alloc(ir.Block, 13);
    @memcpy(blocks[0..11], original.blocks);
    blocks[9] = .{
        .function = 1,
        .instructions = &.{},
        .terminator = .{ .branch = .{
            .condition = 0,
            .when_true = .{ .block = 11 },
            .when_false = .{ .block = 12 },
        } },
    };
    blocks[10] = .{
        .function = 2,
        .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 0 }},
        .terminator = .{ .fail = 2 },
    };
    blocks[11] = .{
        .function = 1,
        .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 1 }},
        .terminator = .{ .fail = 2 },
    };
    blocks[12] = .{
        .function = 1,
        .instructions = &.{.{ .destination = 1, .opcode = .boolean_not, .operands = &.{0} }},
        .terminator = .{ .return_value = 1 },
    };
    original.blocks = blocks;
    return original;
}
test "failing mapper and folder retain eager phase ordering" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try failingSteps(arena.allocator());
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    var candidate = try @import("sequence_fusion.zig").construct(a, original, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}

test "an effectful mapper remains in its eager production phase" {
    var program = map_fold;
    program.effects = &.{.{
        .identity = "map.observe",
        .payload = 1,
        .result = 0,
        .external = true,
    }};
    var functions = map_fold.functions[0..3].*;
    functions[0].effects = &.{0};
    functions[1].effects = &.{0};
    functions[1].layout.slots = &.{ 0, 0, 1 };
    program.functions = &functions;
    var blocks: [12]ir.Block = undefined;
    @memcpy(blocks[0..11], map_fold.blocks);
    blocks[9] = .{
        .function = 1,
        .instructions = &.{.{ .destination = 2, .opcode = .constant }},
        .terminator = .{ .perform = .{
            .effect = 0,
            .payload = 2,
            .next = .{
                .block = 11,
                .assignments = &.{.{ .destination = 1, .source = .returned }},
            },
        } },
    };
    blocks[11] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } };
    program.blocks = &blocks;
    var admitted = try own.analyze(a, program);
    admitted.deinit();
    const fusion = @import("sequence_fusion.zig");
    var stats: fusion.Statistics = .{};
    var result = try fusion.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.loops_fused);
    var baseline = try @import("coalescing.zig").run(a, program, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, result.program),
    );
}
