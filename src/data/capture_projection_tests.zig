// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const projection = @import("capture_projection.zig");
const a = std.testing.allocator;
pub const reused: ir.Program = .{
    .roots = .{ .entry = 0, .result = 3, .failure = 1 },
    .schemas = &.{
        .u64,                       .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{3},
            .use = .reusable,
        } } },
        .{ .product = &.{ 0, 0 } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 3, 0, 0, 2, 0, 0, 3 } },
            .result = 3,
        },
        .{
            .entry = 3,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 3, 0, 0, 0 } },
            .result = 0,
        },
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
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 6, .opcode = .product, .operands = &.{ 4, 5 } }},
            .terminator = .{ .return_value = 6 },
        },
        .{
            .function = 1,
            .instructions = &.{
                .{ .destination = 2, .opcode = .field, .operands = &.{0}, .immediate = 0 },
                .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 2, 1 } },
            },
            .terminator = .{ .return_value = 3 },
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{3}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
};

test "private product capture becomes its sole observed scalar field" {
    var stats: projection.Statistics = .{};
    var result = try projection.run(a, reused, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.constructors_projected);
    try std.testing.expectEqual(@as(usize, 1), stats.producer_projections);
    try std.testing.expectEqual(@as(usize, 1), stats.worker_projections_removed);
    const constructor = result.program.constructors[0];
    const field = result.program.scopes.captures[@intCast(constructor.capture)].fields[0];
    try std.testing.expect(result.program.schemas[@intCast(field)] == .u64);
    std.debug.print(
        "capture field projection: {d} -> {d} image bytes\n",
        .{
            try @import("program_image.zig").encodedLength(reused),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}

test "independent checker rejects the wrong same-type field at construction" {
    var functions = reused.functions[0..2].*;
    functions[0].layout.slots = &.{ 3, 0, 0, 4, 0, 0, 3, 0 };
    functions[1].layout.slots = &.{ 0, 0, 0, 0 };
    var instructions = [_]ir.Instruction{
        .{ .destination = 7, .opcode = .field, .operands = &.{0}, .immediate = 0 },
        .{ .destination = 3, .opcode = .computation, .operands = &.{7}, .immediate = 0 },
    };
    var blocks = reused.blocks[0..4].*;
    blocks[0].instructions = &instructions;
    blocks[3].instructions = &.{
        .{ .destination = 2, .opcode = .move, .operands = &.{0} },
        reused.blocks[3].instructions[1],
    };
    var candidate = reused;
    candidate.functions = &functions;
    candidate.blocks = &blocks;
    candidate.schemas = &.{
        reused.schemas[0], reused.schemas[1], reused.schemas[2], reused.schemas[3],
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
    };
    candidate.scopes.captures = &.{
        reused.scopes.captures[0],
        .{ .fields = &.{0}, .use = .reusable },
    };
    candidate.constructors = &.{.{ .function = 1, .capture = 1, .schema = 4 }};
    const witnesses = &.{projection.Witness{ .constructor = 0, .field = 0 }};
    try projection.validate(a, reused, candidate, witnesses);
    instructions[0].immediate = 1;
    try std.testing.expectError(
        error.InvalidCaptureProjection,
        projection.validate(a, reused, candidate, witnesses),
    );
}

test "independent field observations keep the full product" {
    var original = reused;
    var blocks = reused.blocks[0..4].*;
    blocks[3].instructions = &.{
        reused.blocks[3].instructions[0],
        .{ .destination = 3, .opcode = .field, .operands = &.{0}, .immediate = 1 },
    };
    original.blocks = &blocks;
    var stats: projection.Statistics = .{};
    var result = try projection.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.constructors_projected);
}

test "direct callers project the same worker input field" {
    var original = reused;
    original.blocks = &.{
        reused.blocks[0], reused.blocks[1],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 1 },
                .next = .{
                    .block = 4,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        reused.blocks[3], reused.blocks[2],
    };
    var stats: projection.Statistics = .{};
    var result = try projection.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.constructors_projected);
    try std.testing.expectEqual(@as(usize, 1), stats.direct_projections);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try projection.run(allocator, reused, null, .{});
    defer result.deinit();
}
test "capture projection releases all partial owners on allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "a delayed failing variant projection is not moved to construction" {
    var original = reused;
    original.schemas = &.{
        .u64,              .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{4},
            .use = .reusable,
        } } },
        reused.schemas[3], .{ .sum = &.{ 0, 0 } },
    };
    original.constants = &.{.{ .schema = 1, .bytes = &.{} }};
    original.functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 4, 0, 0, 2, 0, 0, 3 } },
            .result = 3,
        },
        .{
            .entry = 3,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 4, 0, 0, 0 } },
            .result = 0,
        },
    };
    original.scopes.captures = &.{.{ .fields = &.{4}, .use = .reusable }};
    var blocks = reused.blocks[0..4].*;
    blocks[3].instructions = &.{
        .{
            .destination = 2,
            .opcode = .variant_payload,
            .operands = &.{0},
            .immediate = 0,
            .failures = &.{.{ .kind = .invalid_variant, .value = 0 }},
        },
        reused.blocks[3].instructions[1],
    };
    original.blocks = &blocks;
    var stats: projection.Statistics = .{};
    var result = try projection.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.constructors_projected);
}

test "shared computation schema and full environment remain available to another constructor" {
    var original = reused;
    original.functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 3, 0, 0, 2, 0, 0, 3, 2 } },
            .result = 3,
        },
        reused.functions[1],
        .{
            .entry = 4,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 3, 0, 0, 0, 0 } },
            .result = 0,
        },
    };
    original.constructors = &.{
        reused.constructors[0],
        .{ .function = 2, .capture = 0, .schema = 2 },
    };
    original.blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                reused.blocks[0].instructions[0],
                .{ .destination = 7, .opcode = .computation, .operands = &.{0}, .immediate = 1 },
            },
            .terminator = reused.blocks[0].terminator,
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 7,
                .arguments = &.{2},
                .next = reused.blocks[1].terminator.apply.next,
            } },
        },
        reused.blocks[2],
        reused.blocks[3],
        .{
            .function = 2,
            .instructions = &.{
                reused.blocks[3].instructions[0],
                .{ .destination = 3, .opcode = .field, .operands = &.{0}, .immediate = 1 },
                .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 2, 3 } },
            },
            .terminator = .{ .return_value = 4 },
        },
    };
    var stats: projection.Statistics = .{};
    var result = try projection.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.constructors_projected);
    var scalar: usize = 0;
    var product: usize = 0;
    for (result.program.constructors) |constructor| {
        const schema = result.program.scopes.captures[@intCast(constructor.capture)].fields[0];
        switch (result.program.schemas[@intCast(schema)]) {
            .u64 => scalar += 1,
            .product => product += 1,
            else => return error.UnexpectedCapture,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), scalar);
    try std.testing.expectEqual(@as(usize, 1), product);
}
