// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const ownership = @import("activation_ownership.zig");
const flow = @import("activation_flow.zig");
const args = @import("dead_arguments.zig");
const captures = @import("capture_reduction.zig");
const a = std.testing.allocator;

pub const transferred: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
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
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .jump = .{
                .block = 3,
                .assignments = &.{.{ .destination = 1, .source = .{ .slot = 0 } }},
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
};

test "operational input demand retains transfers but kills overwritten incoming values" {
    for ([_]bool{ false, true }) |yielding| for ([_]bool{ false, true }) |overwrite| {
        var original = transferred;
        var blocks = transferred.blocks[0..4].*;
        if (yielding) blocks[2].terminator = .{
            .yield_value = transferred.blocks[2].terminator.jump,
        };
        if (overwrite) blocks[2].instructions = &.{
            .{ .destination = 0, .opcode = .constant, .immediate = 0 },
            .{ .destination = 2, .opcode = .constant, .immediate = 0 },
        };
        original.blocks = &blocks;
        var admitted = try ownership.analyze(a, original);
        defer admitted.deinit();
        try std.testing.expect(!admitted.pool.contains(admitted.live[2][0], 0));
        var demand = try flow.analyzeInputDemand(a, original);
        defer demand.deinit();
        try std.testing.expectEqual(!overwrite, demand.pool.contains(demand.live[2][0], 0));
        var stats: args.Statistics = .{};
        var result = try args.run(a, original, &stats, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, @intFromBool(overwrite)), stats.parameters_removed);
        var compiled = try @import("closed_compilation.zig").run(
            a,
            original,
            .{ .contract = .semantic },
        );
        defer compiled.deinit();
        if (!overwrite) {
            var functions = original.functions[0..2].*;
            functions[1].inputs = &.{};
            blocks[0].terminator.call.arguments = &.{};
            var invalid = original;
            invalid.functions = &functions;
            try std.testing.expectError(
                error.UnavailableSlot,
                args.validate(a, transferred, invalid, &.{.{ .function = 1, .removed = &.{0} }}),
            );
        }
    };
}

test "captured operational input demand preserves retained yield transfers" {
    for ([_]bool{ false, true }) |overwrite| {
        var original = transferred;
        original.schemas = &.{
            .u64, .unit,
            .{ .internal = .{ .computation = .{
                .parameters = &.{},
                .result = 0,
                .use = .reusable,
                .capture_bound = &.{0},
            } } },
        };
        original.scopes.captures = &.{.{ .fields = &.{0}, .use = .reusable }};
        original.constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }};
        var functions = transferred.functions[0..2].*;
        functions[0].layout.slots = &.{ 0, 0, 2 };
        original.functions = &functions;
        var blocks = transferred.blocks[0..4].*;
        blocks[0].instructions = &.{.{
            .destination = 2,
            .opcode = .computation,
            .operands = &.{0},
            .immediate = 0,
        }};
        blocks[0].terminator = .{ .apply = .{
            .computation = 2,
            .arguments = &.{},
            .next = transferred.blocks[0].terminator.call.next,
        } };
        blocks[2].terminator = .{ .yield_value = transferred.blocks[2].terminator.jump };
        if (overwrite) blocks[2].instructions = &.{
            .{ .destination = 0, .opcode = .constant, .immediate = 0 },
            .{ .destination = 2, .opcode = .constant, .immediate = 0 },
        };
        original.blocks = &blocks;
        var stats: captures.Statistics = .{};
        var result = try captures.run(a, original, &stats, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, @intFromBool(overwrite)), stats.fields_removed);
        var compiled = try @import("closed_compilation.zig").run(
            a,
            original,
            .{ .contract = .semantic },
        );
        defer compiled.deinit();
    }
}

test "operational input demand inverts simultaneous transfers before killing definitions" {
    var original = transferred;
    var functions = transferred.functions[0..2].*;
    functions[0].inputs = &.{ 0, 1 };
    functions[1].inputs = &.{ 0, 1 };
    original.functions = &functions;
    var blocks = transferred.blocks[0..4].*;
    blocks[0].terminator.call.arguments = &.{ 0, 1 };
    blocks[2].terminator.jump.assignments = &.{
        .{ .destination = 0, .source = .{ .slot = 1 } },
        .{ .destination = 1, .source = .{ .slot = 0 } },
    };
    original.blocks = &blocks;
    for ([_]bool{ false, true }) |overwrite| {
        if (overwrite) blocks[2].instructions = &.{
            .{ .destination = 0, .opcode = .constant, .immediate = 0 },
            .{ .destination = 2, .opcode = .constant, .immediate = 0 },
        };
        var demand = try flow.analyzeInputDemand(a, original);
        defer demand.deinit();
        try std.testing.expectEqual(!overwrite, demand.pool.contains(demand.live[2][0], 0));
        try std.testing.expect(demand.pool.contains(demand.live[2][0], 1));
        var stats: args.Statistics = .{};
        var result = try args.run(a, original, &stats, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, @intFromBool(overwrite)), stats.parameters_removed);
    }
}

pub const cross_block_transfer: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{.{ .schema = 0, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 } }},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{0},
        .layout = .{ .slots = &.{ 0, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 1, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .jump = .{
                .block = 2,
                .assignments = &.{.{ .destination = 2, .source = .{ .slot = 1 } }},
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    },
};

test "definition removal propagates retained transfer reads across blocks" {
    const dce = @import("dead_computation.zig");
    for ([_]bool{ false, true }) |yielding|
        for ([_]bool{ false, true }) |transfer|
            for ([_]bool{ false, true }) |overwrite| {
                var original = cross_block_transfer;
                var blocks = cross_block_transfer.blocks[0..3].*;
                const next: ir.Edge = .{
                    .block = 2,
                    .assignments = if (transfer)
                        cross_block_transfer.blocks[1].terminator.jump.assignments
                    else
                        &.{},
                };
                blocks[1].terminator = if (yielding)
                    .{ .yield_value = next }
                else
                    .{ .jump = next };
                if (overwrite) blocks[1].instructions = cross_block_transfer.blocks[0].instructions;
                original.blocks = &blocks;
                var admitted = try ownership.analyze(a, original);
                defer admitted.deinit();
                var stats: dce.Statistics = .{};
                var result = try dce.run(a, original, &stats, .{});
                defer result.deinit();
                const expected: usize = if (transfer and
                    !overwrite)
                    0
                else if (!transfer and
                    overwrite)
                    2
                else
                    1;
                try std.testing.expectEqual(expected, stats.instructions_removed);
                var compiled = try @import("closed_compilation.zig").run(
                    a,
                    original,
                    .{ .contract = .semantic },
                );
                defer compiled.deinit();
                if (transfer and !overwrite) {
                    blocks[0].instructions = &.{};
                    var invalid = original;
                    invalid.blocks = &blocks;
                    try std.testing.expectError(
                        error.UnavailableSlot,
                        ownership.analyze(a, invalid),
                    );
                    try std.testing.expectError(
                        error.UnavailableSlot,
                        dce.validate(
                            a,
                            cross_block_transfer,
                            invalid,
                            &.{.{ .block = 0, .removed = &.{0} }},
                        ),
                    );
                }
            };
}

test "definition removal propagates transfer reads through a loop backedge" {
    const dce = @import("dead_computation.zig");
    var original = cross_block_transfer;
    original.schemas = &.{ .u64, .unit, .boolean };
    original.constants = &.{ cross_block_transfer.constants[0], .{ .schema = 2, .bytes = &.{0} } };
    original.functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 3 },
        .layout = .{ .slots = &.{ 0, 0, 0, 2 } },
        .result = 0,
    }};
    original.blocks = &.{
        cross_block_transfer.blocks[0],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 3,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 3 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 3, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .yield_value = .{
                .block = 1,
                .assignments = cross_block_transfer.blocks[1].terminator.jump.assignments,
            } },
        },
        cross_block_transfer.blocks[2],
    };
    var stats: dce.Statistics = .{};
    var result = try dce.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.instructions_removed);
    var compiled = try @import("closed_compilation.zig").run(
        a,
        original,
        .{ .contract = .semantic },
    );
    defer compiled.deinit();
}
