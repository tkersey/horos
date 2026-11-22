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
    const forged = try scalar.reconstruct(arena.allocator(), program, &.{field_witness}, &budget);
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
    const candidate = try scalar.reconstruct(arena.allocator(), original, ws, &budget);
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
    const candidate = try scalar.reconstruct(arena.allocator(), program, &valid, &budget);
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
    const candidate = try scalar.reconstruct(
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
    blocks[3].instructions = &.{ blocks[3].instructions[0], blocks[3].instructions[0] };
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
    const missing = @import("relocation.zig").missing;
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
    const map = [_]ir.Id{ missing, missing, missing, missing, 0, 1, 2, 3 };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]?[]const ir.Id{ null, &map }) |supplied| {
        var budget = scalar.Budget.init(.{ .witnesses = 1 });
        var stats: scalar.Statistics = .{};
        const ws = try scalar.discoverReachable(
            arena.allocator(),
            program,
            supplied,
            &budget,
            &stats,
        );
        try std.testing.expectEqual(1, ws.len);
        try std.testing.expectEqual(4, ws[0].source.block);
        try std.testing.expectEqual(7, ws[0].target.block);
        try std.testing.expectEqual(1, stats.proven);
    }
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
    try std.testing.expectError(error.InvalidExpressionReuse, scalar.reconstruct(
        a,
        scalar_diamond,
        &.{decoded},
        &budget,
    ));
}
