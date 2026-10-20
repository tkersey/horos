// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const reduce = @import("capture_reduction.zig");
const a = std.testing.allocator;
const reused: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,     .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
        .boolean,
    },
    .constants = &.{.{ .schema = 3, .bytes = &.{1} }},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 0, 2, 0 } },
            .result = 0,
        },
        .{ .entry = 3, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 3 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 3,
                .opcode = .computation,
                .operands = &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .apply = .{
                .computation = 3,
                .arguments = &.{1},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 3,
                .arguments = &.{2},
                .next = .{
                    .block = 2,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
};

test "reused closure loses a dead capture while preserving explicit arguments" {
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, reused, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.construction_operands_removed);
    try std.testing.expectEqual(
        @as(usize, 0),
        result.program.scopes.captures[@intCast(result.program.constructors[0].capture)].fields.len,
    );
    std.debug.print(
        "dead capture in reused closure: {d} -> {d} bytes\n",
        .{
            try @import("program_image.zig").encodedLength(reused),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}

test "capture becomes dead only after the known branch is removed" {
    var original = reused;
    original.blocks = &.{
        reused.blocks[0], reused.blocks[1],                                                               reused.blocks[2],
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 4 },
                .when_false = .{ .block = 5 },
            } },
        },
        reused.blocks[3], .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var stats: reduce.Statistics = .{};
    var retained = try reduce.run(a, original, &stats, .{});
    defer retained.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.fields_removed);
    var pruned = try @import("branch_reduction.zig").run(a, original, null, .{});
    defer pruned.deinit();
    var result = try reduce.run(a, pruned.program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.fields_removed);
}

test "capture checker rejects a forged same-type worker input correspondence" {
    var candidate = reused;
    var functions = reused.functions[0..2].*;
    functions[1].inputs = &.{1};
    candidate.functions = &functions;
    var blocks = reused.blocks[0..4].*;
    blocks[0].instructions = &.{.{ .destination = 3, .opcode = .computation, .immediate = 0 }};
    candidate.blocks = &blocks;
    candidate.scopes.captures = &.{
        reused.scopes.captures[0],
        .{ .fields = &.{}, .use = .reusable },
    };
    candidate.constructors = &.{.{ .function = 1, .capture = 1, .schema = 2 }};
    const witness = &.{reduce.Witness{ .constructor = 0, .removed = &.{0} }};
    try reduce.validate(a, reused, candidate, witness);
    // Keep admission valid by changing both the input binding and its return.
    functions[1].inputs = &.{0};
    blocks[3].terminator.return_value = 0;
    try std.testing.expectError(
        error.InvalidCaptureReduction,
        reduce.validate(a, reused, candidate, witness),
    );
}

test "a closure alias is an opaque use and retains its environment" {
    var program = reused;
    var functions = reused.functions[0..2].*;
    functions[0].layout.slots = &.{ 0, 0, 0, 2, 0, 2 };
    program.functions = &functions;
    var blocks = reused.blocks[0..4].*;
    blocks[0].instructions = &.{
        reused.blocks[0].instructions[0],
        .{ .destination = 5, .opcode = .move, .operands = &.{3} },
    };
    program.blocks = &blocks;
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.opaque_constructors);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try reduce.run(allocator, reused, null, .{});
    defer result.deinit();
}
test "capture reduction releases all partial owners on allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "direct worker calls drop the same capture prefix operand" {
    var program = reused;
    program.blocks = &.{
        reused.blocks[0], reused.blocks[1],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 2 },
                .next = .{
                    .block = 4,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        reused.blocks[3], reused.blocks[2],
    };
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.direct_arguments_removed);
}

test "a shared capture descriptor remains intact for a worker that needs its field" {
    var program = reused;
    program.functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 0, 2, 0, 2 } },
            .result = 0,
        },
        reused.functions[1],
        .{ .entry = 4, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
    };
    program.constructors = &.{
        reused.constructors[0],
        .{ .function = 2, .capture = 0, .schema = 2 },
    };
    program.blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                reused.blocks[0].instructions[0],
                .{ .destination = 5, .opcode = .computation, .operands = &.{0}, .immediate = 1 },
            },
            .terminator = reused.blocks[0].terminator,
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 5,
                .arguments = &.{2},
                .next = reused.blocks[1].terminator.apply.next,
            } },
        },
        reused.blocks[2],
        reused.blocks[3],
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.fields_removed);
    var empty: usize = 0;
    var retained: usize = 0;
    for (result.program.constructors) |constructor| {
        const count = result.program.scopes.captures[@intCast(constructor.capture)].fields.len;
        if (count == 0) empty += 1 else if (count == 1) retained += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), empty);
    try std.testing.expectEqual(@as(usize, 1), retained);
    try std.testing.expectEqual(@as(usize, 1), program.scopes.captures[0].fields.len);
}

test "removed capture evaluation retains its arithmetic failure" {
    var program = reused;
    program.constants = &.{ reused.constants[0], .{ .schema = 1, .bytes = &.{} } };
    var blocks = reused.blocks[0..4].*;
    blocks[0].instructions = &.{
        .{
            .destination = 0,
            .opcode = .integer_div,
            .operands = &.{ 1, 2 },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = 1 },
                .{ .kind = .division_by_zero, .value = 1 },
            },
        },
        reused.blocks[0].instructions[0],
    };
    program.blocks = &blocks;
    var stats: reduce.Statistics = .{};
    var result = try reduce.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.fields_removed);
    var faults: usize = 0;
    for (result.program.blocks) |block| for (block.instructions) |op| {
        if (op.opcode == .integer_div) faults += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), faults);
}
