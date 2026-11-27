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
        try image.identity(a, .unhinted(baseline.program)),
        try image.identity(a, .unhinted(result.program)),
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

const DistinctCapturesFixture = struct {
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
};

test "same closure code with distinct captures retains both constructions" {
    const program = DistinctCapturesFixture.program;
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
        .u64,
        .unit,
        .{ .internal = .{ .region = 0 } },
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
        .terminator = if (id == blocks.len - 1)
            .{ .return_value = 0 }
        else
            .{ .yield_value = .{ .block = id + 1 } },
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

const scalar = @import("scalar_field_reuse.zig");
const Schema = @import("program.zig").Schema;
const field_witness: scalar.Witness = .{
    .source = .{ .block = 0, .instruction = 0 },
    .target = .{ .block = 3, .instruction = 0 },
};
const scalar_diamond: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .boolean, .unit, .{ .product = &.{ 0, 0 } } },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2, 5 },
        .layout = .{ .slots = &.{ 3, 3, 1, 0, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .field, .operands = &.{0}, .destination = 3 }},
            .terminator = diamond.blocks[0].terminator,
        },
        diamond.blocks[1],
        diamond.blocks[2],
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .field, .operands = &.{0}, .destination = 4 }},
            .terminator = .{ .return_value = 4 },
        },
    },
};

fn expectRetained(program: ir.Program) !scalar.Statistics {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const witnesses = try scalar.discover(arena.allocator(), program, &budget, &stats);
    try std.testing.expectEqual(0, witnesses.len);
    const forged = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        &.{field_witness},
        &budget,
    );
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        scalar.validate(a, program, forged, &.{field_witness}, &budget),
    );
    return stats;
}

test "recovery field reuse rejects overwritten versions" {
    for ([_][2]ir.Id{ .{ 0, 1 }, .{ 3, 5 } }) |pair| {
        var blocks = scalar_diamond.blocks[0..4].*;
        var program = scalar_diamond;
        program.blocks = &blocks;
        blocks[1].instructions = &.{.{
            .opcode = .move,
            .destination = pair[0],
            .operands = &.{pair[1]},
        }};
        _ = try expectRetained(program);
        blocks[1].instructions = &.{};
        blocks[1].terminator.jump.assignments = &.{
            .{ .destination = pair[0], .source = .{ .slot = pair[1] } },
            .{ .destination = pair[1], .source = .{ .slot = pair[0] } },
        };
        _ = try expectRetained(program);
    }
}

test "recovery field reuse stops at capture boundaries" {
    const next: ir.Edge = .{ .block = 3 };
    const terms = [_]ir.Terminator{
        .{ .call = .{ .function = 1, .arguments = &.{3}, .next = next } },
        .{ .perform = .{ .effect = 0, .payload = 3, .next = next } },
        .{ .yield_value = next },
        .{ .resume_value = .{ .resumption = 6, .argument = 3, .next = next } },
    };
    for (terms) |term| {
        var program = scalar_diamond;
        program.roots.entry = 1;
        const token: Schema = .{ .internal = .{ .resumption = .{
            .effect = 0,
            .input = 0,
            .answer = 0,
            .handled = &.{0},
            .mode = .deep,
            .use = .multi,
        } } };
        const resource: Schema = .{ .internal = .{ .abstract_resource = 0 } };
        program.schemas = &(scalar_diamond.schemas[0..4].* ++ [_]Schema{ token, resource });
        program.scopes.resources = &.{.{
            .representation = 0,
            .introducers = &.{0},
            .eliminators = &.{},
        }};
        program.effects = &.{.{
            .identity = "field/reuse",
            .payload = 0,
            .result = 0,
            .control_use = .multi,
        }};
        var fun = scalar_diamond.functions[0];
        fun.layout.slots = &.{ 3, 3, 1, 0, 0, 0, 4 };
        fun.inputs = &.{ 0, 1, 2, 5, 6 };
        fun.effects = &.{0};
        program.functions = &.{ fun, .{
            .entry = 4,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 0, 5 } },
            .result = 0,
        } };
        var blocks = scalar_diamond.blocks[0..4].* ++ [_]ir.Block{.{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        }};
        blocks[1].terminator = term;
        program.blocks = &blocks;
        const stats = try expectRetained(program);
        try std.testing.expect(stats.capture_boundary > 0);
    }
}

test "recovery evidence accounts for complete records" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    const ws = &.{field_witness};
    const original = scalar_diamond;
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        original,
        ws,
        &budget,
    );
    try scalar.validate(a, original, candidate, ws, &budget);
    var changed = candidate;
    changed.constants = &.{.{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } }};
    try std.testing.expectError(error.InvalidExpressionReuse, scalar.validate(
        a,
        original,
        changed,
        ws,
        &budget,
    ));
    changed = candidate;
    var blocks = candidate.blocks[0..4].*;
    changed.blocks = &blocks;
    blocks[2].terminator.jump.assignments = &.{.{ .destination = 3, .source = .{ .slot = 5 } }};
    try std.testing.expectError(error.InvalidExpressionReuse, scalar.validate(
        a,
        original,
        changed,
        ws,
        &budget,
    ));
    blocks[2] = candidate.blocks[2];
    var op = blocks[3].instructions[0];
    op.failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }};
    blocks[3].instructions = &.{op};
    try std.testing.expectError(error.InvalidExpressionReuse, scalar.validate(
        a,
        original,
        changed,
        ws,
        &budget,
    ));
    changed = candidate;
    changed.constructors = &.{.{ .function = 0, .capture = 0, .schema = 0 }};
    try std.testing.expectError(error.InvalidExpressionReuse, scalar.validate(
        a,
        original,
        changed,
        ws,
        &budget,
    ));
}

test "recovery field reuse excludes nested copyable internal schemas" {
    const region: Schema = .{ .internal = .{ .region = 0 } };
    var program = scalar_diamond;
    program.schemas = &.{
        .u64,
        .boolean,
        .unit,
        .{ .product = &.{ 0, 4 } },
        .{ .seq = 5 },
        region,
        .{ .internal = .{ .abstract_resource = 0 } },
    };
    program.scopes.region_count = 1;
    program.scopes.resources = &.{.{
        .representation = 0,
        .introducers = &.{0},
        .eliminators = &.{},
    }};
    var functions = [_]ir.Function{ scalar_diamond.functions[0], .{
        .entry = 4,
        .inputs = &.{0},
        .layout = .{ .slots = &.{ 0, 6 } },
        .result = 0,
    } };
    functions[0].regions = &.{0};
    program.functions = &functions;
    program.roots.entry = 1;
    program.blocks = &(scalar_diamond.blocks[0..4].* ++ [_]ir.Block{.{
        .function = 1,
        .instructions = &.{},
        .terminator = .{ .return_value = 0 },
    }});
    const stats = try expectRetained(program);
    try std.testing.expectEqual(2, stats.unsupported_schema);
}

test "recovery field reuse rejects unordered duplicate and irrelevant proof coordinates" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    var blocks = scalar_diamond.blocks[0..4].*;
    blocks[3].instructions = &.{ blocks[3].instructions[0], blocks[3].instructions[0] };
    var program = scalar_diamond;
    program.blocks = &blocks;
    var second = field_witness;
    second.target.instruction = 1;
    const valid = [_]scalar.Witness{ field_witness, second };
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        &valid,
        &budget,
    );
    try scalar.validate(a, program, candidate, &valid, &budget);
    const wrong = [_][]const scalar.Witness{
        &.{ second, field_witness },
        &.{ field_witness, field_witness },
        &.{field_witness},
        &.{.{ .source = .{ .block = 4, .instruction = 0 }, .target = field_witness.target }},
        &.{.{ .source = field_witness.source, .target = .{ .block = 3, .instruction = 2 } }},
    };
    for (wrong) |ws|
        try std.testing.expectError(
            error.InvalidExpressionReuse,
            scalar.validate(a, program, candidate, ws, &budget),
        );
}

test "recovery field reuse bounds predecessor depth and rejects an unresolved cycle" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .depth = 1 });
    const program = scalar_diamond;
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        &.{field_witness},
        &budget,
    );
    try std.testing.expectError(
        error.ScalarFieldLimit,
        scalar.validate(a, program, candidate, &.{field_witness}, &budget),
    );
    var cyclic = program;
    var blocks = scalar_diamond.blocks[0..4].*;
    blocks[1].terminator = .{ .branch = .{
        .condition = 2,
        .when_true = .{ .block = 1 },
        .when_false = .{ .block = 3 },
    } };
    cyclic.blocks = &blocks;
    _ = try expectRetained(cyclic);
}

test "recovery discovery excludes same-block fields from its producer search" {
    var program = scalar_diamond;
    var operations: [512]ir.Instruction = undefined;
    @memset(&operations, scalar_diamond.blocks[0].instructions[0]);
    program.blocks = &.{.{
        .function = 0,
        .instructions = &operations,
        .terminator = .{ .return_value = operations[0].destination },
    }};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .work = operations.len * operations.len / 2 });
    var stats: scalar.Statistics = .{};
    try std.testing.expectEqual(0, (try scalar.discover(
        arena.allocator(),
        program,
        &budget,
        &stats,
    )).len);
    try std.testing.expectEqual(budget.limits.work - budget.remaining, budget.workUsed());
    try std.testing.expect(budget.workUsed() > operations.len);
    try std.testing.expectEqual(0, stats.proven);
    try std.testing.expectEqual(0, stats.unavailable_version);
    budget = scalar.Budget.init(.{ .work = 0 });
    try std.testing.expectError(error.ScalarFieldLimit, scalar.discover(
        arena.allocator(),
        program,
        &budget,
        &stats,
    ));
    try std.testing.expect(budget.exhausted);
}

test "recovery discovery reports proven sites when the witness limit discards the batch" {
    var blocks = scalar_diamond.blocks[0..4].*;
    const targets: [3]ir.Instruction = @splat(blocks[3].instructions[0]);
    blocks[3].instructions = &targets;
    var program = scalar_diamond;
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .witnesses = 1 });
    var stats: scalar.Statistics = .{};
    try std.testing.expectError(error.ScalarFieldLimit, scalar.discover(
        arena.allocator(),
        program,
        &budget,
        &stats,
    ));
    try std.testing.expectEqual(2, stats.proven);
    try std.testing.expectEqual(0, stats.unavailable_version);
    try std.testing.expect(budget.exhausted);
}

test "recovery discovery counts neither numbering of a successful producer as a rejection" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (0..2) |early| {
        const late = 1 - early;
        var blocks: [2]ir.Block = undefined;
        blocks[early] = scalar_diamond.blocks[0];
        blocks[early].terminator = .{ .jump = .{ .block = late } };
        blocks[late] = scalar_diamond.blocks[3];
        var function = scalar_diamond.functions[0];
        function.entry = early;
        var program = scalar_diamond;
        program.functions = &.{function};
        program.blocks = &blocks;
        var budget = scalar.Budget.init(.{});
        var stats: scalar.Statistics = .{};
        const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
        try std.testing.expectEqual(1, ws.len);
        try std.testing.expectEqual(early, ws[0].source.block);
        try std.testing.expectEqual(late, ws[0].target.block);
        try std.testing.expectEqualDeep(scalar.Statistics{ .proven = 1 }, stats);
    }
}

test "recovery discovery spends the witness quota only on retained blocks" {
    var functions = [_]ir.Function{ scalar_diamond.functions[0], scalar_diamond.functions[0] };
    functions[1].entry = 4;
    var blocks = scalar_diamond.blocks[0..4].* ++ scalar_diamond.blocks[0..4].*;
    for (blocks[4..]) |*block| block.function = 1;
    blocks[4].terminator.branch.when_true.block = 5;
    blocks[4].terminator.branch.when_false.block = 6;
    blocks[5].terminator.jump.block = 7;
    blocks[6].terminator.jump.block = 7;
    var program = scalar_diamond;
    program.functions = &functions;
    program.blocks = &blocks;
    program.roots.entry = 1;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    {
        var budget = scalar.Budget.init(.{ .witnesses = 1 });
        var stats: scalar.Statistics = .{};
        const ws = try scalar.discover(
            arena.allocator(),
            program,
            &budget,
            &stats,
        );
        try std.testing.expectEqual(1, ws.len);
        try std.testing.expectEqual(4, ws[0].source.block);
        try std.testing.expectEqual(7, ws[0].target.block);
        try std.testing.expectEqual(1, stats.proven);
    }
    var budget = scalar.Budget.init(.{});
    const dead = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        &.{field_witness},
        &budget,
    );
    try std.testing.expectError(error.InvalidExpressionReuse, scalar.validate(
        a,
        program,
        dead,
        &.{field_witness},
        &budget,
    ));
}

test "recovery witness coordinates decode at full width before program range checking" {
    const witness: scalar.Witness = .{
        .source = .{ .block = @as(u64, 1) << 40, .instruction = @as(u64, 1) << 33 },
        .target = field_witness.target,
    };
    const wire = @import("wire.zig");
    const record = @import("record.zig");
    var bytes: [32]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.write(scalar.Witness, witness, &writer);
    var reader: wire.Reader = .{ .input = bytes[0..writer.position] };
    const decoded = try record.read(scalar.Witness, &reader, a);
    try reader.finish();
    try std.testing.expectEqualDeep(witness, decoded);
    var budget = scalar.Budget.init(.{});
    try std.testing.expectError(error.InvalidExpressionReuse, scalar.reconstructBorrowedProposal(
        a,
        scalar_diamond,
        &.{decoded},
        &budget,
    ));
}

test "recovery proofs ignore an unreachable predecessor at a reachable join" {
    var blocks = scalar_diamond.blocks[0..4].*;
    var program = scalar_diamond;
    program.blocks = &blocks;
    blocks[0].terminator = .{ .jump = .{ .block = 3 } };
    blocks[1].terminator = .{ .yield_value = .{ .block = 3 } };
    blocks[2].terminator = .{ .jump = .{ .block = 1 } };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .depth = 2 });
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
    try std.testing.expectEqualDeep(@as([]const scalar.Witness, &.{field_witness}), ws);
    try std.testing.expectEqualDeep(scalar.Statistics{ .proven = 1 }, stats);
    const proposal = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        ws,
        &budget,
    );
    try scalar.validate(a, program, proposal, ws, &budget);
}

test "recovery discovery indexes repeated fields within transparent components" {
    const count = 128;
    var blocks: [count]ir.Block = undefined;
    var ops: [count]ir.Instruction = undefined;
    const fields: [count]ir.Id = @splat(0);
    var program = scalar_diamond;
    program.schemas = &.{ .u64, .boolean, .unit, .{ .product = &fields } };
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var distinct_work: u64 = 0;
    for ([_]bool{ false, true }) |repeated| {
        for (&blocks, &ops, 0..) |*block, *op, i| {
            op.* = scalar_diamond.blocks[0].instructions[0];
            op.immediate = if (repeated) 0 else i;
            block.* = .{
                .function = 0,
                .instructions = op[0..1],
                .terminator = if (i + 1 == count)
                    .{ .return_value = op.destination }
                else
                    .{ .yield_value = .{ .block = i + 1 } },
            };
        }
        var budget = scalar.Budget.init(.{});
        var stats: scalar.Statistics = .{};
        const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
        try std.testing.expectEqual(0, ws.len);
        if (repeated) {
            try std.testing.expectEqual(count - 1, stats.capture_boundary);
            try std.testing.expectEqual(1, stats.unavailable_version);
            try std.testing.expect(budget.workUsed() < distinct_work + count * 8);
        } else {
            try std.testing.expectEqualDeep(scalar.Statistics{}, stats);
            distinct_work = budget.workUsed();
        }
    }
}

test "recovery discovery keeps reachable literal payload out of scratch" {
    const length = 1 << 20;
    const bytes = try a.alloc(u8, length + 3);
    defer a.free(bytes);
    var writer: @import("wire.zig").Writer = .{ .output = bytes };
    try writer.natural(length);
    @memset(bytes[writer.position..], 0);
    var program = scalar_diamond;
    program.schemas = &(scalar_diamond.schemas[0..4].* ++ [_]Schema{.bytes});
    program.constants = &.{.{ .schema = 4, .bytes = bytes }};
    var function = scalar_diamond.functions[0];
    function.layout.slots = &(function.layout.slots[0..6].* ++ [_]ir.Id{4});
    program.functions = &.{function};
    var blocks = scalar_diamond.blocks[0..4].*;
    blocks[0].instructions = &.{
        .{ .opcode = .constant, .immediate = 0, .destination = 6 },
        scalar_diamond.blocks[0].instructions[0],
    };
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .temporary_bytes = length / 2 });
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
    try std.testing.expectEqual(1, ws.len);
    try std.testing.expectEqual(1, ws[0].source.instruction);
}

test "recovery capture counts require an earlier field on the same path" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var program = scalar_diamond;
    var blocks = [_]ir.Block{
        scalar_diamond.blocks[1],
        scalar_diamond.blocks[0],
        scalar_diamond.blocks[2],
        scalar_diamond.blocks[3],
        scalar_diamond.blocks[3],
    };
    program.blocks = &blocks;
    blocks[0].terminator = .{ .yield_value = .{ .block = 1 } };
    blocks[1].terminator = .{ .yield_value = .{ .block = 3 } };
    blocks[2].terminator = .{ .yield_value = .{ .block = 4 } };
    for ([_]usize{ 1, 0 }) |expected| {
        if (expected == 0) {
            blocks[0].terminator = scalar_diamond.blocks[0].terminator;
            blocks[1].instructions = &.{};
        }
        var budget = scalar.Budget.init(.{});
        var stats: scalar.Statistics = .{};
        const witnesses = try scalar.discover(arena.allocator(), program, &budget, &stats);
        try std.testing.expectEqual(0, witnesses.len);
        try std.testing.expectEqual(expected, stats.capture_boundary);
        try std.testing.expectEqual(2 - expected, stats.unavailable_version);
    }
}

test "recovery proposal charges source membership in a block with indexed targets" {
    var blocks = scalar_diamond.blocks[0..4].*;
    var program = scalar_diamond;
    program.blocks = &blocks;
    blocks[0].terminator = .{ .jump = .{ .block = 1 } };
    const fields: [4]ir.Instruction = @splat(scalar_diamond.blocks[0].instructions[0]);
    blocks[1].instructions = &fields;
    blocks[1].terminator = .{ .jump = .{ .block = 3 } };
    var witnesses: [4]scalar.Witness = undefined;
    for (&witnesses, 0..) |*w, i| w.* = .{
        .source = field_witness.source,
        .target = if (i == 3) field_witness.target else .{ .block = 1, .instruction = i },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var baseline = scalar.Budget.init(.{});
    _ = try scalar.reconstructBorrowedProposal(arena.allocator(), program, &witnesses, &baseline);
    witnesses[3].source = .{ .block = 1, .instruction = 3 };
    var indexed = scalar.Budget.init(.{});
    _ = try scalar.reconstructBorrowedProposal(arena.allocator(), program, &witnesses, &indexed);
    try std.testing.expect(indexed.workUsed() > baseline.workUsed());
    var tight = scalar.Budget.init(.{ .work = baseline.workUsed() });
    try std.testing.expectError(error.ScalarFieldLimit, scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        &witnesses,
        &tight,
    ));
}

fn fieldFanOutWork(comptime count: usize, repeated: bool, capture: bool) !u64 {
    const fields: [count]ir.Id = @splat(0);
    const variants: [count]ir.Id = @splat(2);
    var program = scalar_diamond;
    program.schemas = &.{ .u64, .{ .sum = &variants }, .unit, .{ .product = &fields } };
    var blocks: [count * 3 + 1]ir.Block = undefined;
    var cases: [count]ir.Edge = undefined;
    var ops: [count]ir.Instruction = undefined;
    for (&cases, &ops, 0..) |*edge, *op, i| {
        blocks[i] = .{ .function = 0, .instructions = &.{}, .terminator = .{
            .jump = .{ .block = i + 1 },
        } };
        const arm = count + 1 + i;
        const field = arm + count;
        edge.* = .{ .block = arm };
        const next: ir.Edge = .{ .block = field };
        blocks[arm] = .{
            .function = 0,
            .instructions = &.{},
            .terminator = if (capture) .{ .yield_value = next } else .{ .jump = next },
        };
        op.* = scalar_diamond.blocks[3].instructions[0];
        op.immediate = if (repeated) 0 else i;
        blocks[field] = .{ .function = 0, .instructions = op[0..1], .terminator = .{
            .return_value = op.destination,
        } };
    }
    blocks[count] = .{ .function = 0, .instructions = &.{}, .terminator = .{
        .switch_variant = .{ .value = 2, .cases = &cases },
    } };
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
    try std.testing.expectEqual(0, ws.len);
    try std.testing.expectEqualDeep(scalar.Statistics{
        .unavailable_version = if (repeated) count else 0,
    }, stats);
    return budget.workUsed();
}

test "recovery capture diagnostics share work across mutually exclusive arms" {
    inline for (.{ 64, 128 }) |count| {
        const distinct = try fieldFanOutWork(count, false, true);
        const repeated = try fieldFanOutWork(count, true, true);
        try std.testing.expect(repeated > distinct);
        try std.testing.expect(repeated - distinct <= 10 * count);
    }
}

test "recovery capture diagnostics distinguish a block's own returning field" {
    var program = scalar_diamond;
    var blocks = scalar_diamond.blocks[0..4].*;
    blocks[0].instructions = &.{};
    blocks[0].terminator.branch.when_true.block = 2;
    blocks[0].terminator.branch.when_false.block = 3;
    blocks[2].terminator = .{ .yield_value = .{ .block = 1 } };
    blocks[1].instructions = scalar_diamond.blocks[0].instructions;
    blocks[1].terminator = .{ .yield_value = .{ .block = 1 } };
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]usize{ 0, 1 }) |captures| {
        if (captures == 1) blocks[1].terminator.yield_value.block = 3;
        var budget = scalar.Budget.init(.{});
        var stats: scalar.Statistics = .{};
        const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
        try std.testing.expectEqual(0, ws.len);
        try std.testing.expectEqualDeep(scalar.Statistics{
            .capture_boundary = captures,
            .unavailable_version = 2 - captures,
        }, stats);
    }
}

test "recovery discovery skips mutually exclusive transparent field blocks" {
    inline for (.{ 64, 128 }) |count| {
        const distinct = try fieldFanOutWork(count, false, false);
        const repeated = try fieldFanOutWork(count, true, false);
        try std.testing.expect(repeated <= distinct + 10 * count);
    }
}

test "recovery capture attribution follows the producer through a bypassed join" {
    var program = scalar_diamond;
    var blocks = scalar_diamond.blocks[0..4].*;
    blocks[1].instructions = blocks[0].instructions;
    blocks[0].instructions = &.{};
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]bool{ false, true }) |swap| {
        blocks[0].terminator.branch.when_true.block = if (swap) 2 else 1;
        blocks[0].terminator.branch.when_false.block = if (swap) 1 else 2;
        for ([_]usize{ 0, 1, 2 }) |captured_arm| {
            for (1..3) |arm| {
                const next: ir.Edge = .{ .block = 3 };
                blocks[arm].terminator = if (captured_arm == arm)
                    .{ .yield_value = next }
                else
                    .{ .jump = next };
            }
            var budget = scalar.Budget.init(.{});
            var stats: scalar.Statistics = .{};
            const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
            const captures: usize = @intFromBool(captured_arm == 1);
            try std.testing.expectEqual(0, ws.len);
            try std.testing.expectEqualDeep(scalar.Statistics{
                .capture_boundary = captures,
                .unavailable_version = 2 - captures,
            }, stats);
        }
    }
}

test "recovery reports an unavailable field whose only other block was replaced" {
    var program = scalar_diamond;
    var function = scalar_diamond.functions[0];
    function.entry = 1;
    program.functions = &.{function};
    var second = scalar_diamond.blocks[0].instructions[0];
    second.destination = 5;
    program.blocks = &.{
        scalar_diamond.blocks[3],
        .{
            .function = 0,
            .instructions = &.{ scalar_diamond.blocks[0].instructions[0], second },
            .terminator = .{ .jump = .{ .block = 0 } },
        },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
    try std.testing.expectEqual(1, ws.len);
    try std.testing.expectEqualDeep(scalar.Location{ .block = 1, .instruction = 0 }, ws[0].source);
    try std.testing.expectEqualDeep(scalar.Statistics{
        .proven = 1,
        .unavailable_version = 1,
    }, stats);
}

test "recovery chooses the lexicographically first provable ancestor" {
    var program = scalar_diamond;
    var function = program.functions[0];
    function.entry = 1;
    program.functions = &.{function};
    var blocks = scalar_diamond.blocks[0..4].*;
    const field = blocks[0].instructions[0];
    var fields: [4]ir.Instruction = @splat(field);
    const destinations = [_]ir.Id{ 4, 3, 5, 4 };
    const next = [_]ir.Id{ 0, 3, 0, 2 };
    for (&blocks, &fields, destinations, next) |*block, *op, slot, dest| {
        op.destination = slot;
        block.instructions = op[0..1];
        block.terminator = .{ .jump = .{ .block = dest } };
    }
    blocks[0].terminator = .{ .return_value = 4 };
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]usize{ 1, 2 }) |expected| {
        if (expected == 2) blocks[3].instructions = &.{
            fields[3],
            .{ .opcode = .move, .operands = &.{5}, .destination = 3 },
        };
        var budget = scalar.Budget.init(.{});
        var stats: scalar.Statistics = .{};
        const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
        try std.testing.expect(ws.len > 0);
        try std.testing.expectEqual(0, ws[0].target.block);
        try std.testing.expectEqual(expected, ws[0].source.block);
    }
}

fn fieldTailWork(
    comptime groups: usize,
    comptime length: usize,
    repeated: bool,
    final_field: bool,
) !u64 {
    var program = scalar_diamond;
    const fields: [groups * 2 + 1]ir.Id = @splat(0);
    program.schemas = &.{ .u64, .boolean, .unit, .{ .product = &fields } };
    var ops: [groups * 2]ir.Instruction = @splat(scalar_diamond.blocks[0].instructions[0]);
    for (&ops, 0..) |*op, i| op.immediate = if (repeated) i % groups else i;
    var blocks: [2 + length]ir.Block = undefined;
    for (&blocks, 0..) |*block, i| {
        block.* = .{
            .function = 0,
            .instructions = if (i < 2) ops[i * groups ..][0..groups] else &.{},
            .terminator = if (i == 0)
                .{ .yield_value = .{ .block = 1 } }
            else if (i + 1 < blocks.len)
                .{ .jump = .{ .block = i + 1 } }
            else
                .{ .return_value = 3 },
        };
    }
    var last = scalar_diamond.blocks[0].instructions[0];
    last.immediate = groups * 2;
    if (final_field) blocks[blocks.len - 1].instructions = (&last)[0..1];
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
    const count: usize = if (repeated) groups else 0;
    try std.testing.expectEqual(0, ws.len);
    try std.testing.expectEqualDeep(scalar.Statistics{
        .capture_boundary = count,
        .unavailable_version = count,
    }, stats);
    return budget.workUsed();
}

test "recovery capture groups stop before field free tails" {
    const baseline = try fieldTailWork(64, 0, false, false);
    const repeated = try fieldTailWork(64, 0, true, false);
    const total = try fieldTailWork(64, 128, false, false);
    const total_repeated = try fieldTailWork(64, 128, true, false);
    try std.testing.expect(total_repeated - total <= repeated - baseline + 2 * 128);
}

fn fieldPrefixWork(comptime count: usize, comptime overwritten: bool) ![2]u64 {
    const field = scalar_diamond.blocks[0].instructions[0];
    const sources: [if (overwritten) count else 1]ir.Instruction = @splat(field);
    var targets: [count]ir.Instruction = @splat(field);
    for (&targets) |*op| op.destination = 4;
    var program = scalar_diamond;
    program.blocks = &.{
        .{ .function = 0, .instructions = &sources, .terminator = .{ .jump = .{ .block = 1 } } },
        .{ .function = 0, .instructions = &targets, .terminator = .{ .return_value = 4 } },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(arena.allocator(), program, &budget, &stats);
    try std.testing.expectEqual(count, ws.len);
    for (ws, 0..) |w, i| {
        try std.testing.expectEqual(sources.len - 1, w.source.instruction);
        try std.testing.expectEqual(i, w.target.instruction);
    }
    const cost = budget.workUsed();
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        ws,
        &budget,
    );
    const before = budget.workUsed();
    try scalar.validate(a, program, candidate, ws, &budget);
    return .{ cost, budget.workUsed() - before };
}

test "recovery field prefixes index overwritten producers and repeated target reads" {
    inline for (.{ false, true }) |overwritten| {
        const small = try fieldPrefixWork(64, overwritten);
        const large = try fieldPrefixWork(128, overwritten);
        for (small, large) |before, after| try std.testing.expect(after * 4 <= before * 9);
    }
}

test "recovery capture groups stop before an unrelated populated tail" {
    const short = try fieldTailWork(64, 1, true, true);
    const long = try fieldTailWork(64, 128, true, true);
    const short_control = try fieldTailWork(64, 1, false, true);
    const long_control = try fieldTailWork(64, 128, false, true);
    try std.testing.expect(long - long_control <= short - short_control + 2 * 128);
}

fn successiveFieldPairWork(comptime pairs: usize, repeated: bool) !u64 {
    const count = pairs * 2;
    const fields: [count]ir.Id = @splat(0);
    var program = scalar_diamond;
    program.schemas = &.{ .u64, .boolean, .unit, .{ .product = &fields } };
    var ops: [count]ir.Instruction = @splat(scalar_diamond.blocks[0].instructions[0]);
    var blocks: [count]ir.Block = undefined;
    for (&ops, &blocks, 0..) |*op, *block, i| {
        op.immediate = if (repeated) i / 2 else i;
        block.* = .{
            .function = 0,
            .instructions = op[0..1],
            .terminator = if (i + 1 < count)
                .{ .yield_value = .{ .block = i + 1 } }
            else
                .{ .return_value = op.destination },
        };
    }
    program.blocks = &blocks;
    var stats: scalar.Statistics = .{};
    var budget = scalar.Budget.init(.{});
    const ws = try scalar.discover(a, program, &budget, &stats);
    defer a.free(ws);
    try std.testing.expectEqual(0, ws.len);
    const rejected: usize = if (repeated) pairs else 0;
    try std.testing.expectEqualDeep(scalar.Statistics{
        .capture_boundary = rejected,
        .unavailable_version = rejected,
    }, stats);
    return budget.workUsed();
}

test "recovery successive capture pairs stop before earlier and later groups" {
    inline for (.{ 64, 128 }) |count| {
        const all = try successiveFieldPairWork(count, true);
        const control = try successiveFieldPairWork(count, false);
        try std.testing.expect(all - control <= 16 * count);
    }
}

test "scalar proof limits apply to directly constructed budgets" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const limits: scalar.Limits = .{ .depth = 1 };
    var budget: scalar.Budget = .{
        .limits = limits,
        .remaining = limits.work,
        .bytes_remaining = limits.temporary_bytes,
    };
    const ws = &.{field_witness};
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        scalar_diamond,
        ws,
        &budget,
    );
    try std.testing.expectError(
        error.ScalarFieldLimit,
        scalar.validate(a, scalar_diamond, candidate, ws, &budget),
    );
    try std.testing.expect(budget.exhausted);
}

test "prepared scalar operations honor the current depth and storage allowances" {
    const Check = struct {
        pub const Result = void;
        const Operation = enum { validate_depth, validate_storage, discover_storage };
        budget: *scalar.Budget,
        operation: Operation,
        candidate: ir.Program,
        allocations: *std.testing.FailingAllocator,

        pub fn prepared(self: @This(), original: *scalar.PreparedOriginal) !void {
            switch (self.operation) {
                .validate_depth => self.budget.limits.depth = 1,
                .validate_storage, .discover_storage => self.budget.limits.temporary_bytes = 0,
            }
            const allocated = self.allocations.allocated_bytes;
            if (self.operation == .discover_storage) {
                var stats: scalar.Statistics = .{};
                try std.testing.expectError(error.ScalarFieldLimit, original.discover(a, &stats));
            } else try std.testing.expectError(
                error.ScalarFieldLimit,
                original.validateObserved(self.candidate, &.{field_witness}, null),
            );
            if (self.operation != .validate_depth)
                try std.testing.expectEqual(allocated, self.allocations.allocated_bytes);
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var proposal_budget = scalar.Budget.init(.{});
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        scalar_diamond,
        &.{field_witness},
        &proposal_budget,
    );
    for ([_]Check.Operation{ .validate_depth, .validate_storage, .discover_storage }) |operation| {
        var budget = scalar.Budget.init(.{});
        var allocations = std.testing.FailingAllocator.init(a, .{});
        try scalar.withPreparedOriginal(allocations.allocator(), scalar_diamond, &budget, Check{
            .budget = &budget,
            .operation = operation,
            .candidate = candidate,
            .allocations = &allocations,
        });
    }
}

test "prepared scalar operations use additional proof depth within the same preparation" {
    const Check = struct {
        pub const Result = void;
        budget: *scalar.Budget,
        proposal: ir.Program,

        pub fn prepared(self: @This(), original: *scalar.PreparedOriginal) !void {
            self.budget.limits.depth = 3;
            try original.validateObserved(self.proposal, &.{field_witness}, null);
            var stats: scalar.Statistics = .{};
            const ws = try original.discover(a, &stats);
            defer a.free(ws);
            try std.testing.expectEqualSlices(scalar.Witness, &.{field_witness}, ws);
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .depth = 1 });
    const proposal = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        scalar_diamond,
        &.{field_witness},
        &budget,
    );
    try scalar.withPreparedOriginal(a, scalar_diamond, &budget, Check{
        .budget = &budget,
        .proposal = proposal,
    });
}

test "proof frames reuse their allocation after refused growth and on repeated proofs" {
    const proof = @import("expression_reuse_proof.zig");
    const AllocationBudget = @import("allocation_budget.zig");
    const w: proof.Witness = .{
        .source = .{ .block = 0, .instruction = 0 },
        .target = .{ .block = 3, .instruction = 0 },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .depth = 1 });
    const preds = try proof.indexPredecessors(arena.allocator(), scalar_diamond, &budget);
    var cap: AllocationBudget = .{ .parent = a, .remaining = budget.bytes() };
    var ws = try proof.Workspace.init(cap.allocator(), scalar_diamond, &budget);
    defer ws.deinit();
    const available = budget.bytes_remaining;
    budget.limits.depth = 3;
    budget.bytes_remaining = 0;
    try std.testing.expectError(error.OutOfMemory, ws.proves(scalar_diamond, w, preds, &budget));
    try std.testing.expect(cap.exhausted);
    budget.bytes_remaining = available;
    try std.testing.expect(try ws.proves(scalar_diamond, w, preds, &budget));
    try std.testing.expect(budget.bytes_remaining < available);
    budget.bytes_remaining = 0;
    try std.testing.expect(try ws.proves(scalar_diamond, w, preds, &budget));
    budget.limits.depth = 1;
    try std.testing.expect(!try ws.proves(scalar_diamond, w, preds, &budget));
    try std.testing.expect(budget.exhausted);
}

test "lazy write indexes release unpublished storage on a work limit and allow retry" {
    const proof = @import("expression_reuse_proof.zig");
    var moves: [16]ir.Instruction = @splat(.{
        .opcode = .move,
        .destination = 3,
        .operands = &.{5},
    });
    for (&moves, 0..) |*op, i| op.destination += i % 2;
    var program = scalar_diamond;
    program.blocks = &.{.{
        .function = 0,
        .instructions = &moves,
        .terminator = .{ .return_value = 3 },
    }};
    var budget = scalar.Budget.init(.{});
    var allocations = std.testing.FailingAllocator.init(a, .{});
    var ws = try proof.Workspace.init(allocations.allocator(), program, &budget);
    defer ws.deinit();
    const live = allocations.allocated_bytes - allocations.freed_bytes;
    const last: proof.Location = .{ .block = 0, .instruction = moves.len - 1 };
    budget.remaining = moves.len;
    try std.testing.expectError(
        error.ExpressionWorkLimit,
        ws.writtenBefore(program, last, 3, &budget),
    );
    try std.testing.expectEqual(live, allocations.allocated_bytes - allocations.freed_bytes);
    budget = scalar.Budget.init(.{});
    try std.testing.expect(try ws.writtenBefore(program, last, 3, &budget));
    const allocated = allocations.allocated_bytes;
    try std.testing.expect(try ws.writtenBefore(program, last, 4, &budget));
    try std.testing.expectEqual(allocated, allocations.allocated_bytes);
}

test "prepared scalar original releases discovery scratch and admits once across checks" {
    const Checked = struct {
        pub const Result = []const scalar.Witness;
        candidate: ir.Program,
        allocations: *std.testing.FailingAllocator,

        const Observation = @import("activation_flow.zig").Observation;

        pub fn checked(self: @This(), before: *const Observation, after: *const Observation) !void {
            try std.testing.expect(@typeInfo(Observation) == .@"opaque");
            for ([_]*const Observation{ before, after }) |observed| {
                try std.testing.expectEqual(self.candidate.blocks.len, observed.blockCount());
                try std.testing.expectEqual(@as(usize, 2), observed.positionCount(0));
                try std.testing.expect(observed.availableAt(0, 0, 0));
                try std.testing.expect(observed.liveAt(0, 0, 0));
            }
        }

        pub fn prepared(self: @This(), original: *scalar.PreparedOriginal) !Result {
            const al = self.allocations;
            const base_live = al.allocated_bytes - al.freed_bytes;
            var stats: scalar.Statistics = .{};
            const ws = try original.discover(a, &stats);
            errdefer a.free(ws);
            try std.testing.expectEqual(base_live, al.allocated_bytes - al.freed_bytes);
            try original.validateObserved(self.candidate, ws, self);
            try std.testing.expectError(
                error.InvalidExpressionReuse,
                original.validateObserved(scalar_diamond, ws, null),
            );
            try original.validateObserved(self.candidate, ws, null);
            return ws;
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        scalar_diamond,
        &.{field_witness},
        &budget,
    );
    budget = scalar.Budget.init(.{});
    var alloc = std.testing.FailingAllocator.init(a, .{});
    const ws = try scalar.withPreparedOriginal(alloc.allocator(), scalar_diamond, &budget, Checked{
        .candidate = candidate,
        .allocations = &alloc,
    });
    defer a.free(ws);
    try std.testing.expectEqualSlices(scalar.Witness, &.{field_witness}, ws);
    try std.testing.expectEqual(alloc.allocated_bytes, alloc.freed_bytes);
    var raw = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const independent = try scalar.discover(a, scalar_diamond, &raw, &stats);
    defer a.free(independent);
    try scalar.validate(a, scalar_diamond, candidate, independent, &raw);
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        scalar.validate(a, scalar_diamond, scalar_diamond, independent, &raw),
    );
    try scalar.validate(a, scalar_diamond, candidate, independent, &raw);
    try std.testing.expect(budget.workUsed() < raw.workUsed());
}

test "prepared scalar original retains nested records after the input owner releases them" {
    const Inspect = struct {
        pub const Result = void;
        storage: *std.heap.ArenaAllocator,
        candidate: ir.Program,

        pub fn prepared(self: @This(), input: *scalar.PreparedOriginal) !void {
            _ = self.storage.reset(.free_all);
            var stats: scalar.Statistics = .{};
            const ws = try input.discover(a, &stats);
            defer a.free(ws);
            try std.testing.expectEqualSlices(scalar.Witness, &.{field_witness}, ws);
            try input.validateObserved(self.candidate, ws, null);
        }
    };
    var storage = std.heap.ArenaAllocator.init(a);
    defer storage.deinit();
    const tmp = storage.allocator();
    var program = scalar_diamond;
    const blocks = try tmp.dupe(ir.Block, program.blocks);
    program.blocks = blocks;
    const ops = try tmp.dupe(ir.Instruction, blocks[0].instructions);
    blocks[0].instructions = ops;
    ops[0].operands = try tmp.dupe(ir.Id, ops[0].operands);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{});
    const candidate = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        scalar_diamond,
        &.{field_witness},
        &budget,
    );
    try scalar.withPreparedOriginal(a, program, &budget, Inspect{
        .storage = &storage,
        .candidate = candidate,
    });
}

test "indexed scalar proofs use the last operand and destination writes in each prefix" {
    const field = scalar_diamond.blocks[0].instructions[0];
    var sources: [20]ir.Instruction = @splat(field);
    sources[11] = .{ .opcode = .move, .destination = 0, .operands = &.{1} };
    sources[12].destination = 5;
    var targets: [20]ir.Instruction = @splat(field);
    for (&targets) |*op| op.destination = 4;
    targets[9] = .{ .opcode = .move, .destination = 5, .operands = &.{3} };
    targets[16] = sources[11];
    var program = scalar_diamond;
    program.blocks = &.{
        .{ .function = 0, .instructions = &sources, .terminator = .{ .jump = .{ .block = 1 } } },
        .{ .function = 0, .instructions = &targets, .terminator = .{ .return_value = 4 } },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stats: scalar.Statistics = .{};
    var budget = scalar.Budget.init(.{});
    const ws = try scalar.discover(a, program, &budget, &stats);
    defer a.free(ws);
    try std.testing.expectEqual(15, ws.len);
    for (ws, 0..) |w, i| {
        try std.testing.expectEqual(if (i < 9) @as(u64, 12) else 19, w.source.instruction);
        try std.testing.expectEqual(if (i < 9) i else i + 1, w.target.instruction);
    }
    const proposal = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        ws,
        &budget,
    );
    try scalar.validate(a, program, proposal, ws, &budget);
    var late = ws[ws.len - 1];
    late.target.instruction = 19;
    const stale = try scalar.reconstructBorrowedProposal(
        arena.allocator(),
        program,
        &.{late},
        &budget,
    );
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        scalar.validate(a, program, stale, &.{late}, &budget),
    );
}

test "capture classification preserves distinct field origins within one cyclic component" {
    var program = scalar_diamond;
    program.schemas = &.{ .u64, .boolean, .unit, .{ .product = &.{ 0, 0 } } };
    const field = scalar_diamond.blocks[0].instructions[0];
    var pair: [2]ir.Instruction = @splat(field);
    pair[1].immediate = 1;
    program.blocks = &.{
        .{
            .function = 0,
            .instructions = &pair,
            .terminator = .{ .yield_value = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &pair,
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 0 },
                .when_false = .{ .block = 2 },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
    };
    var stats: scalar.Statistics = .{};
    var budget = scalar.Budget.init(.{});
    const ws = try scalar.discover(a, program, &budget, &stats);
    defer a.free(ws);
    try std.testing.expectEqual(0, ws.len);
    try std.testing.expectEqualDeep(scalar.Statistics{ .capture_boundary = 4 }, stats);
}

test "scalar work and allocation use the lesser of initial and remaining allowances" {
    const limits: scalar.Limits = .{ .work = 11, .temporary_bytes = 17 };
    var b: scalar.Budget = .{ .limits = limits, .remaining = 60, .bytes_remaining = 90 };
    try std.testing.expectEqual(0, b.workUsed());
    try std.testing.expectEqual(11, b.workRemaining());
    try std.testing.expectEqual(17, b.bytes().*);
    try std.testing.expect(b.charge(4));
    try std.testing.expectEqual(7, b.work().*);
    b.work().* -= 3;
    try std.testing.expectEqual(7, b.workUsed());
    try std.testing.expect(!b.charge(5));
    try std.testing.expectEqual(4, b.workRemaining());
    var aggregate: scalar.Budget = .{
        .limits = .{ .work = 0 },
        .remaining = 1_000_000,
        .bytes_remaining = 100_000,
    };
    var stats: scalar.Statistics = .{};
    try std.testing.expectError(
        error.ScalarFieldLimit,
        scalar.discover(a, scalar_diamond, &aggregate, &stats),
    );
    try std.testing.expectEqual(0, aggregate.remaining);
}

fn joinedFieldWork(comptime arms: usize, comptime reads: usize) ![2]u64 {
    const variants: [arms]ir.Id = @splat(2);
    var program = scalar_diamond;
    program.schemas = &.{ .u64, .{ .sum = &variants }, .unit, .{ .product = &.{ 0, 0 } } };
    var blocks: [arms + 2]ir.Block = undefined;
    var cases: [arms]ir.Edge = undefined;
    const join = blocks.len - 1;
    for (&cases, 0..) |*edge, i| {
        edge.* = .{ .block = i + 1 };
        blocks[i + 1] = .{ .function = 0, .instructions = &.{}, .terminator = .{
            .jump = .{ .block = join },
        } };
    }
    blocks[0] = .{
        .function = 0,
        .instructions = scalar_diamond.blocks[0].instructions,
        .terminator = .{ .switch_variant = .{ .value = 2, .cases = &cases } },
    };
    const targets: [reads]ir.Instruction = @splat(scalar_diamond.blocks[3].instructions[0]);
    blocks[join] = .{
        .function = 0,
        .instructions = &targets,
        .terminator = .{ .return_value = 4 },
    };
    program.blocks = &blocks;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(tmp, program, &budget, &stats);
    try std.testing.expectEqual(reads, ws.len);
    const discover_work = budget.workUsed();
    const proposal = try scalar.reconstructBorrowedProposal(tmp, program, ws, &budget);
    const precheck = budget.workUsed();
    try scalar.validate(a, program, proposal, ws, &budget);
    const validate_work = budget.workUsed() - precheck;
    for (ws, 0..) |w, i| {
        try std.testing.expectEqual(0, w.source.block);
        try std.testing.expectEqual(join, w.target.block);
        try std.testing.expectEqual(i, w.target.instruction);
    }
    return .{ discover_work, validate_work };
}

fn capturedIntervalWork(comptime groups: usize, comptime middle: usize, repeated: bool) !u64 {
    const fields: [groups * 2]ir.Id = @splat(0);
    var program = scalar_diamond;
    program.schemas = &.{ .u64, .boolean, .unit, .{ .product = &fields } };
    var ops: [groups * 2]ir.Instruction = @splat(scalar_diamond.blocks[0].instructions[0]);
    for (&ops, 0..) |*op, i| op.immediate = if (repeated) i % groups else i;
    var blocks: [middle + 2]ir.Block = undefined;
    for (&blocks, 0..) |*bl, i| {
        const last = i == middle + 1;
        bl.* = .{
            .function = 0,
            .instructions = if (i == 0) ops[0..groups] else if (last) ops[groups..] else &.{},
            .terminator = if (i == 0)
                .{ .yield_value = .{ .block = i + 1 } }
            else if (last)
                .{ .return_value = 3 }
            else
                .{ .jump = .{ .block = i + 1 } },
        };
    }
    program.blocks = &blocks;
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(a, program, &budget, &stats);
    defer a.free(ws);
    try std.testing.expectEqual(0, ws.len);
    const expected: usize = if (repeated) groups else 0;
    try std.testing.expectEqualDeep(scalar.Statistics{
        .capture_boundary = expected,
        .unavailable_version = expected,
    }, stats);
    return budget.workUsed();
}

test "unchanged reads at a join share the predecessor proof within each independent check" {
    const small = try joinedFieldWork(16, 16);
    const more_arms = try joinedFieldWork(32, 16);
    const more_reads = try joinedFieldWork(16, 32);
    const large = try joinedFieldWork(32, 32);
    for (large, small, more_arms, more_reads) |both, base, arms, reads| {
        try std.testing.expect(both + base <= arms + reads + 32);
    }
}

test "capture groups with equal block roles share the intervening path" {
    inline for (.{ 16, 32 }) |groups| {
        const short = try capturedIntervalWork(groups, 16, true);
        const short_control = try capturedIntervalWork(groups, 16, false);
        const long = try capturedIntervalWork(groups, 32, true);
        const long_control = try capturedIntervalWork(groups, 32, false);
        try std.testing.expect(long - long_control <= short - short_control + 128);
    }
}

fn killedAncestorWork(comptime count: usize, repeated: bool) !u64 {
    var program = scalar_diamond;
    const fields: [count]ir.Id = @splat(0);
    program.schemas = &.{ .u64, .boolean, .unit, .{ .product = &fields } };
    const read = scalar_diamond.blocks[0].instructions[0];
    const kill: ir.Instruction = .{ .opcode = .move, .destination = 3, .operands = &.{5} };
    var ops: [count][2]ir.Instruction = @splat(.{ read, kill });
    var blocks: [count]ir.Block = undefined;
    for (&blocks, &ops, 0..) |*block, *pair, i| {
        pair[0].immediate = if (repeated) 0 else i;
        block.* = .{
            .function = 0,
            .instructions = pair,
            .terminator = if (i + 1 == count)
                .{ .return_value = 3 }
            else
                .{ .jump = .{ .block = i + 1 } },
        };
    }
    program.blocks = &blocks;
    return unavailableFieldWork(program, if (repeated) count else 0);
}

fn unavailableFieldWork(program: ir.Program, rejected: usize) !u64 {
    var budget = scalar.Budget.init(.{});
    var stats: scalar.Statistics = .{};
    const ws = try scalar.discover(a, program, &budget, &stats);
    defer a.free(ws);
    try std.testing.expectEqual(0, ws.len);
    try std.testing.expectEqualDeep(scalar.Statistics{ .unavailable_version = rejected }, stats);
    return budget.workUsed();
}

fn changedOperandWork(comptime count: usize, repeated: bool) !u64 {
    var program = scalar_diamond;
    const field = scalar_diamond.blocks[0].instructions[0];
    var writes: [count]ir.Instruction = @splat(field);
    for (&writes, 0..) |*w, i| w.destination = 6 + i;
    var reads: [count + 1]ir.Instruction = @splat(scalar_diamond.blocks[3].instructions[0]);
    reads[0] = .{ .opcode = .move, .destination = 0, .operands = &.{1} };
    for (reads[1..]) |*read| read.immediate = @intFromBool(!repeated);
    const slots = scalar_diamond.functions[0].layout.slots[0..6].* ++ @as([count]ir.Id, @splat(0));
    var function = scalar_diamond.functions[0];
    function.layout.slots = &slots;
    program.functions = (&function)[0..1];
    program.blocks = &.{
        .{ .function = 0, .instructions = &writes, .terminator = .{ .jump = .{ .block = 1 } } },
        .{ .function = 0, .instructions = &reads, .terminator = .{ .return_value = 4 } },
    };
    return unavailableFieldWork(program, if (repeated) 2 * count else 0);
}

test "killed field producers and changed aggregate versions avoid empty searches" {
    inline for (.{ 32, 64 }) |count| {
        const killed = try killedAncestorWork(count, true);
        const distinct = try killedAncestorWork(count, false);
        try std.testing.expect(killed <= distinct + 4 * count);
        const changed = try changedOperandWork(count, true);
        const separated = try changedOperandWork(count, false);
        try std.testing.expect(changed <= separated + 50 * count);
    }
}

test "field proof preparation does not index unused block writes" {
    var arithmetic: [128]ir.Instruction = @splat(.{
        .opcode = .move,
        .operands = &.{5},
        .destination = 3,
    });
    for (&arithmetic, 0..) |*op, i| op.destination = 3 + i % 2;
    var program = scalar_diamond;
    program.blocks = &.{.{
        .function = 0,
        .instructions = &arithmetic,
        .terminator = .{ .return_value = 3 },
    }};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var budget = scalar.Budget.init(.{ .work = program.blocks.len });
    const proof = @import("expression_reuse_proof.zig");
    var ws = try proof.Workspace.init(arena.allocator(), program, &budget);
    defer ws.deinit();
    _ = try unavailableFieldWork(program, 0);
}
