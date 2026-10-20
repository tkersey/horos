// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const reuse = @import("expression_reuse.zig");
const a = std.testing.allocator;
const diamond: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .boolean, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 0, 0, 1, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 3,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 3 } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 3 } } },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .return_value = 4 },
        },
    },
};

test "total expression available on both sides of a diamond is reused after its join" {
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, diamond, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.expressions_reused);
    try std.testing.expectEqual(@as(usize, 1), stats.across_blocks);
    var count: usize = 0;
    for (result.program.blocks) |block| for (block.instructions) |op| {
        if (op.opcode == .integer_bit_xor) count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "local repeated expression reuses its prior successful value" {
    var program = diamond;
    program.blocks = &.{.{
        .function = 0,
        .instructions = &.{ diamond.blocks[0].instructions[0], diamond.blocks[3].instructions[0] },
        .terminator = diamond.blocks[3].terminator,
    }};
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.expressions_reused);
    try std.testing.expectEqual(@as(usize, 0), stats.across_blocks);
}

test "one-path operand write invalidates the old value version" {
    var blocks = diamond.blocks[0..4].*;
    blocks[1].instructions = &.{.{ .destination = 0, .opcode = .move, .operands = &.{1} }};
    var program = diamond;
    program.blocks = &blocks;
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    var forged_blocks = blocks;
    forged_blocks[3].instructions = &.{.{ .destination = 4, .opcode = .move, .operands = &.{3} }};
    var forged = program;
    forged.blocks = &forged_blocks;
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        reuse.validate(
            a,
            program,
            forged,
            &.{.{
                .source = .{ .block = 0, .instruction = 0 },
                .target = .{ .block = 3, .instruction = 0 },
            }},
        ),
    );
}

test "parallel edge replacement of an operand invalidates reuse" {
    var blocks = diamond.blocks[0..4].*;
    blocks[1].terminator.jump.assignments = &.{
        .{ .destination = 0, .source = .{ .slot = 1 } },
        .{ .destination = 1, .source = .{ .slot = 0 } },
    };
    var program = diamond;
    program.blocks = &blocks;
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, program, &stats, .{});
    defer result.deinit();
    // No unproved commutativity/parallel-version canonicalization.
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
}

test "non-dominating expression is not available at the join" {
    var blocks = diamond.blocks[0..4].*;
    blocks[0].instructions = &.{.{ .destination = 3, .opcode = .move, .operands = &.{0} }};
    blocks[1].instructions = diamond.blocks[0].instructions;
    var program = diamond;
    program.blocks = &blocks;
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    var forged_blocks = blocks;
    forged_blocks[3].instructions = &.{.{ .destination = 4, .opcode = .move, .operands = &.{3} }};
    var forged = program;
    forged.blocks = &forged_blocks;
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        reuse.validate(
            a,
            program,
            forged,
            &.{.{
                .source = .{ .block = 1, .instruction = 0 },
                .target = .{ .block = 3, .instruction = 0 },
            }},
        ),
    );
}

test "checker rejects using a producer that overwrote its own operand" {
    var program = diamond;
    program.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 0, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } },
            diamond.blocks[3].instructions[0],
        },
        .terminator = diamond.blocks[3].terminator,
    }};
    var forged = program;
    forged.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            program.blocks[0].instructions[0],
            .{ .destination = 4, .opcode = .move, .operands = &.{0} },
        },
        .terminator = program.blocks[0].terminator,
    }};
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        reuse.validate(
            a,
            program,
            forged,
            &.{.{
                .source = .{ .block = 0, .instruction = 0 },
                .target = .{ .block = 0, .instruction = 1 },
            }},
        ),
    );
}

test "work exhaustion rolls back expression candidates and still runs P01" {
    var stats: reuse.Statistics = .{};
    var p01: @import("coalescing.zig").Statistics = .{};
    var result = try reuse.run(
        a,
        diamond,
        &stats,
        .{ .work_limit = 1, .coalescing = .{ .statistics = &p01 } },
    );
    defer result.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    try std.testing.expect(p01.outcome != .not_run);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try reuse.run(allocator, diamond, null, .{});
    defer result.deinit();
}
test "expression reuse releases every partial owner on allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "late proof-budget exhaustion discards already selected replacements" {
    var full_stats: reuse.Statistics = .{};
    var full = try reuse.run(a, diamond, &full_stats, .{});
    defer full.deinit();
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, diamond, &stats, .{ .work_limit = full_stats.work - 1 });
    defer result.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    var baseline = try @import("coalescing.zig").run(a, diamond, .{});
    defer baseline.deinit();
    const image = @import("program_image.zig");
    try std.testing.expectEqual(
        try image.identity(a, baseline.program),
        try image.identity(a, result.program),
    );
}

test "potentially failing expressions with different payloads are never reused" {
    var program = diamond;
    program.roots.failure = 0;
    program.constants = &.{
        .{ .schema = 0, .bytes = &.{ 11, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 22, 0, 0, 0, 0, 0, 0, 0 } },
    };
    var blocks = diamond.blocks[0..4].*;
    blocks[0].instructions = &.{.{
        .destination = 3,
        .opcode = .integer_add,
        .operands = &.{ 0, 1 },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
    }};
    blocks[3].instructions = &.{.{
        .destination = 4,
        .opcode = .integer_add,
        .operands = &.{ 0, 1 },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = 1 }},
    }};
    program.blocks = &blocks;
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
}

test "same closure code with distinct captures retains both constructions" {
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 3, .failure = 1 },
        .schemas = &.{
            .u64,                       .unit,
            .{ .internal = .{ .computation = .{
                .parameters = &.{0},
                .result = 3,
                .capture_bound = &.{0},
                .use = .reusable,
            } } },
            .{ .product = &.{ 0, 0 } },
        },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{
            .{
                .entry = 0,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 0, 0, 2, 2, 3 } },
                .result = 3,
            },
            .{
                .entry = 2,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 0, 0, 3 } },
                .result = 3,
            },
        },
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{
                    .{
                        .destination = 2,
                        .opcode = .computation,
                        .operands = &.{0},
                        .immediate = 0,
                    },
                    .{
                        .destination = 3,
                        .opcode = .computation,
                        .operands = &.{1},
                        .immediate = 0,
                    },
                },
                .terminator = .{ .apply = .{
                    .computation = 3,
                    .arguments = &.{1},
                    .next = .{
                        .block = 1,
                        .assignments = &.{.{ .destination = 4, .source = .returned }},
                    },
                } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
            .{
                .function = 1,
                .instructions = &.{.{
                    .destination = 2,
                    .opcode = .product,
                    .operands = &.{ 0, 1 },
                }},
                .terminator = .{ .return_value = 2 },
            },
        },
        .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
        .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
    };
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    var blocks = program.blocks[0..3].*;
    blocks[0].instructions = &.{
        program.blocks[0].instructions[0],
        .{ .destination = 3, .opcode = .move, .operands = &.{2} },
    };
    var forged = program;
    forged.blocks = &blocks;
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        reuse.validate(
            a,
            program,
            forged,
            &.{.{
                .source = .{ .block = 0, .instruction = 0 },
                .target = .{ .block = 0, .instruction = 1 },
            }},
        ),
    );
}

const private_cell: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                                         .unit, .{ .internal = .{ .region = 0 } },
        .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 2, 0, 0 },
            .result = 0,
            .use = .reusable,
            .regions = &.{0},
        } } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 4, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 2, 0, 0, 3, 0, 1, 0 } },
            .result = 0,
            .regions = &.{0},
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .computation, .immediate = 0 }},
            .terminator = .{ .with_region = .{
                .region = 0,
                .body = 2,
                .arguments = &.{ 0, 1 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{
            .{ .destination = 3, .opcode = .cell_new, .operands = &.{ 0, 1 } },
            .{ .destination = 4, .opcode = .cell_get, .operands = &.{3} },
            .{ .destination = 5, .opcode = .cell_set, .operands = &.{ 3, 2 } },
            .{ .destination = 6, .opcode = .cell_get, .operands = &.{3} },
        }, .terminator = .{ .return_value = 6 } },
    },
    .scopes = .{ .region_count = 1, .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 4 }},
};

test "equal-looking cell reads separated by mutation are excluded" {
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, private_cell, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    var instructions = private_cell.blocks[2].instructions[0..4].*;
    instructions[3] = .{ .destination = 6, .opcode = .move, .operands = &.{4} };
    var blocks = private_cell.blocks[0..3].*;
    blocks[2].instructions = &instructions;
    var forged = private_cell;
    forged.blocks = &blocks;
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        reuse.validate(
            a,
            private_cell,
            forged,
            &.{.{
                .source = .{ .block = 2, .instruction = 1 },
                .target = .{ .block = 2, .instruction = 3 },
            }},
        ),
    );
}

test "expression reuse does not introduce retention across a capture boundary" {
    var blocks = diamond.blocks[0..4].*;
    blocks[1].terminator = .{ .yield_value = .{ .block = 3 } };
    var original = diamond;
    original.blocks = &blocks;
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    var changed = blocks;
    changed[3].instructions = &.{.{ .destination = 4, .opcode = .move, .operands = &.{3} }};
    var candidate = original;
    candidate.blocks = &changed;
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        reuse.validate(
            a,
            original,
            candidate,
            &.{.{
                .source = .{ .block = 0, .instruction = 0 },
                .target = .{ .block = 3, .instruction = 0 },
            }},
        ),
    );
}

test "unique expressions do not allocate a global availability universe" {
    const p = @import("program.zig");
    var bytes: [256][8]u8 = undefined;
    var constants: [256]p.Literal = undefined;
    var instructions: [256]ir.Instruction = undefined;
    for (&bytes, &constants, &instructions, 0..) |*value, *literal, *op, index| {
        std.mem.writeInt(u64, value, index, .little);
        literal.* = .{ .schema = 0, .bytes = value };
        op.* = .{ .destination = 0, .opcode = .constant, .immediate = index };
    }
    const original: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &constants,
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &instructions,
            .terminator = .{ .return_value = 0 },
        }},
    };
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 256), stats.eligible_definitions);
    try std.testing.expectEqual(@as(usize, 0), stats.tracked_definitions);
    try std.testing.expect(!stats.work_limit);
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
}

test "equal expressions separated by capture boundaries do not share availability storage" {
    const blocks = try a.alloc(ir.Block, 129);
    defer a.free(blocks);
    for (blocks, 0..) |*block, id| block.* = .{
        .function = 0,
        .instructions = &.{.{ .destination = 0, .opcode = .constant, .immediate = 0 }},
        .terminator = if (id == blocks.len - 1) .{ .return_value = 0 } else .{ .yield_value = .{ .block = id + 1 } },
    };
    const original: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{.{ .schema = 0, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 } }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = blocks,
    };
    var stats: reuse.Statistics = .{};
    var result = try reuse.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 129), stats.eligible_definitions);
    try std.testing.expectEqual(@as(usize, 0), stats.tracked_definitions);
    try std.testing.expectEqual(@as(usize, 0), stats.expressions_reused);
    try std.testing.expect(!stats.work_limit);
}
