// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const motion = @import("loop_motion.zig");
const a = std.testing.allocator;
pub const counted: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .boolean },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{} },
    },
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 0, 0, 0, 0, 0, 2, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 3, .opcode = .constant, .immediate = 0 },
                .{ .destination = 4, .opcode = .constant, .immediate = 0 },
                .{ .destination = 7, .opcode = .constant, .immediate = 1 },
            },
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 5, .opcode = .less, .operands = &.{ 3, 0 } }},
            .terminator = .{ .branch = .{
                .condition = 5,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 3 },
            } },
        },
        .{ .function = 0, .instructions = &.{
            .{ .destination = 6, .opcode = .integer_bit_xor, .operands = &.{ 1, 2 } },
            .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 4, 6 } },
            .{
                .destination = 3,
                .opcode = .integer_add,
                .operands = &.{ 3, 7 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
            },
        }, .terminator = .{ .jump = .{ .block = 1 } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
    },
};
pub const guarded: ir.Program = .{
    .roots = counted.roots,
    .schemas = counted.schemas,
    .constants = counted.constants,
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2, 6 },
        .layout = counted.functions[0].layout,
        .result = 0,
    }},
    .blocks = &.{
        counted.blocks[0],
        counted.blocks[1],
        counted.blocks[2],
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 6 } },
    },
};
test "dead loop-entry destinations reuse an existing preheader" {
    var candidate = (try motion.construct(a, counted, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqualSlices(usize, &.{0}, candidate.witness.instructions);
    try motion.validate(a, counted, candidate.program, candidate.witness, .{});
    var stats: motion.Statistics = .{};
    var result = try motion.run(a, counted, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.hoisted);
    try std.testing.expectEqual(@as(usize, 0), stats.guarded_entries);
    try std.testing.expectEqual(@as(usize, 1), stats.reused_preheaders);
}
test "admitted wrong hoisted operands and guard routing fail independent validation" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var candidate = (try motion.construct(a, guarded, .{})).?;
    defer candidate.deinit();
    const blocks = try arena.allocator().dupe(ir.Block, candidate.program.blocks);
    const instructions = try arena.allocator().dupe(ir.Instruction, blocks[5].instructions);
    instructions[0].operands = &.{ 1, 1 };
    blocks[5].instructions = instructions;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidLoopMotion,
        motion.validate(a, guarded, forged, candidate.witness, .{}),
    );
    @memcpy(blocks, candidate.program.blocks);
    blocks[4].terminator.branch.when_false.block = 5;
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidLoopMotion,
        motion.validate(a, guarded, forged, candidate.witness, .{}),
    );
}
test "loop-carried slot identity is not an invariant value" {
    var program = counted;
    var blocks = counted.blocks[0..4].*;
    var instructions = counted.blocks[2].instructions[0..3].*;
    instructions[0].operands = &.{ 1, 3 };
    blocks[2].instructions = &instructions;
    program.blocks = &blocks;
    var admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, program, .{}) == null);
    instructions[0].operands = &.{ 1, 2 };
    blocks[2].terminator.jump.assignments = &.{.{ .destination = 1, .source = .{ .slot = 3 } }};
    admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, program, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator, program: ir.Program) !void {
    var result = try motion.run(allocator, program, null, .{});
    defer result.deinit();
}
test "loop motion releases every allocation failure and rolls back exact work exhaustion" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{counted});
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{guarded});
    var entry_program = counted;
    var entry_functions = counted.functions[0..1].*;
    entry_functions[0].entry = 1;
    entry_functions[0].inputs = &.{ 0, 1, 2, 3, 4, 7 };
    entry_program.functions = &entry_functions;
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{entry_program});
    var stats: motion.Statistics = .{};
    var limited = try motion.run(a, counted, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    var baseline = try @import("coalescing.zig").run(a, counted, .{});
    defer baseline.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
    var invalid = counted;
    invalid.roots.entry = 99;
    try std.testing.expectError(
        error.InvalidReference,
        motion.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}

pub const nested: ir.Program = .{
    .roots = counted.roots,
    .schemas = counted.schemas,
    .constants = counted.constants,
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 0, 0, 0, 0, 0, 0, 2, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 3, .opcode = .constant, .immediate = 0 },
                .{ .destination = 5, .opcode = .constant, .immediate = 0 },
                .{ .destination = 8, .opcode = .constant, .immediate = 1 },
            },
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 6, .opcode = .less, .operands = &.{ 3, 0 } }},
            .terminator = .{ .branch = .{
                .condition = 6,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 6 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 4, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 6, .opcode = .less, .operands = &.{ 4, 1 } }},
            .terminator = .{ .branch = .{
                .condition = 6,
                .when_true = .{ .block = 4 },
                .when_false = .{ .block = 5 },
            } },
        },
        .{ .function = 0, .instructions = &.{
            .{ .destination = 7, .opcode = .integer_bit_xor, .operands = &.{ 3, 2 } },
            .{ .destination = 5, .opcode = .integer_bit_xor, .operands = &.{ 5, 7 } },
            .{
                .destination = 4,
                .opcode = .integer_add,
                .operands = &.{ 4, 8 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
            },
        }, .terminator = .{ .jump = .{ .block = 3 } } },
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 3,
                .opcode = .integer_add,
                .operands = &.{ 3, 8 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
            }},
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 5 } },
    },
};
test "nested placement uses the inner guard because the outer iteration changes its operand" {
    var candidate = (try motion.construct(a, nested, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 3), candidate.witness.header);
    try std.testing.expectEqual(@as(usize, 4), candidate.witness.body);
    try motion.validate(a, nested, candidate.program, candidate.witness, .{});
    try std.testing.expect((try motion.repeatedScalarWork(
        a,
        candidate.program,
    )).? < (try motion.repeatedScalarWork(a, nested)).?);
}
test "an old destination read before the definition and header-edge overwrites prevent hoisting" {
    var program = counted;
    var functions = counted.functions[0..1].*;
    functions[0].inputs = &.{ 0, 1, 2, 6 };
    program.functions = &functions;
    var blocks = counted.blocks[0..4].*;
    var instructions = counted.blocks[2].instructions[0..3].*;
    std.mem.swap(ir.Instruction, &instructions[0], &instructions[1]);
    blocks[2].instructions = &instructions;
    program.blocks = &blocks;
    var admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, program, .{}) == null);
    program = counted;
    blocks = counted.blocks[0..4].*;
    blocks[1].terminator.branch.when_true.assignments = &.{.{
        .destination = 6,
        .source = .{ .slot = 1 },
    }};
    program.blocks = &blocks;
    admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, program, .{}) == null);
}
test "custody changes and observable loop suspension are excluded" {
    var program = counted;
    var functions = counted.functions[0..1].*;
    functions[0].custody = &.{ .{}, .{ .parent = 0 } };
    program.functions = &functions;
    var blocks = counted.blocks[0..4].*;
    blocks[2].custody = 1;
    program.blocks = &blocks;
    var admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, program, .{}) == null);
    program = counted;
    blocks = counted.blocks[0..4].*;
    blocks[2].terminator = .{ .yield_value = .{ .block = 1 } };
    program.blocks = &blocks;
    admitted = try own.analyze(a, program);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, program, .{}) == null);
}
test "dependent scalar batch is checked in definition order" {
    var program = counted;
    var functions = counted.functions[0..1].*;
    functions[0].layout.slots = &.{ 0, 0, 0, 0, 0, 2, 0, 0, 0 };
    program.functions = &functions;
    var blocks = counted.blocks[0..4].*;
    blocks[2].instructions = &.{
        counted.blocks[2].instructions[0],
        .{ .destination = 8, .opcode = .integer_bit_not, .operands = &.{6} },
        .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 4, 8 } },
        counted.blocks[2].instructions[2],
    };
    program.blocks = &blocks;
    var candidate = (try motion.construct(a, program, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, candidate.witness.instructions);
    try motion.validate(a, program, candidate.program, candidate.witness, .{});
    var wrong = candidate.witness;
    wrong.instructions = &.{ 1, 0 };
    try std.testing.expectError(
        error.InvalidLoopMotion,
        motion.validate(a, program, candidate.program, wrong, .{}),
    );
}
test "a loop headed at function entry redirects the actual entry" {
    var program = counted;
    var functions = counted.functions[0..1].*;
    functions[0].entry = 1;
    functions[0].inputs = &.{ 0, 1, 2, 3, 4, 7 };
    program.functions = &functions;
    var admitted = try own.analyze(a, program);
    admitted.deinit();
    var candidate = (try motion.construct(a, program, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqual(
        @as(p.Id, counted.blocks.len),
        candidate.program.functions[0].entry,
    );
    try motion.validate(a, program, candidate.program, candidate.witness, .{});
}

pub const mutable: ir.Program = .{
    .roots = counted.roots,
    .schemas = &.{
        .u64,
        .unit,
        .boolean,
        .{ .internal = .{ .region = 0 } },
        .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 3, 0, 0 },
            .result = 0,
            .use = .reusable,
            .regions = &.{0},
        } } },
        .{ .product = &.{4} },
    },
    .constants = counted.constants,
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 5, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 3, 0, 0, 4, 6, 0, 0, 2, 0, 1, 4 } },
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
            .{ .destination = 3, .opcode = .cell_new, .operands = &.{ 0, 2 } },
            .{ .destination = 4, .opcode = .product, .operands = &.{3} },
            .{ .destination = 5, .opcode = .constant, .immediate = 0 },
            .{ .destination = 6, .opcode = .constant, .immediate = 1 },
            .{ .destination = 8, .opcode = .move, .operands = &.{2} },
        }, .terminator = .{ .jump = .{ .block = 3 } } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 7, .opcode = .less, .operands = &.{ 5, 1 } }},
            .terminator = .{ .branch = .{
                .condition = 7,
                .when_true = .{ .block = 4 },
                .when_false = .{ .block = 5 },
            } },
        },
        .{ .function = 1, .instructions = &.{
            .{ .destination = 10, .opcode = .field, .operands = &.{4}, .immediate = 0 },
            .{ .destination = 8, .opcode = .cell_get, .operands = &.{10} },
            .{
                .destination = 8,
                .opcode = .integer_add,
                .operands = &.{ 8, 6 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
            },
            .{ .destination = 9, .opcode = .cell_set, .operands = &.{ 3, 8 } },
            .{
                .destination = 5,
                .opcode = .integer_add,
                .operands = &.{ 5, 6 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 2 }},
            },
        }, .terminator = .{ .jump = .{ .block = 3 } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 8 } },
    },
    .scopes = .{ .region_count = 1, .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 5 }},
};
test "an aliased mutable loop read cannot acquire scalar invariance" {
    var admitted = try own.analyze(a, mutable);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, mutable, .{}) == null);
    var stats: motion.Statistics = .{};
    var result = try motion.run(a, mutable, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.hoisted);
    var baseline = try @import("coalescing.zig").run(a, mutable, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, result.program),
    );
}

pub const yielding_infinite: ir.Program = .{
    .roots = counted.roots,
    .schemas = counted.schemas,
    .effects = &.{},
    .functions = counted.functions,
    .constants = &.{
        counted.constants[0],             counted.constants[1], counted.constants[2],
        .{ .schema = 2, .bytes = &.{1} },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                counted.blocks[0].instructions[0],
                counted.blocks[0].instructions[1],
                counted.blocks[0].instructions[2],
                .{ .destination = 5, .opcode = .constant, .immediate = 3 },
            },
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = counted.blocks[1].terminator },
        .{
            .function = 0,
            .instructions = counted.blocks[2].instructions[0..2],
            .terminator = .{ .yield_value = .{ .block = 1 } },
        },
        counted.blocks[3],
    },
};
test "an infinite loop with public observations remains untouched" {
    var admitted = try own.analyze(a, yielding_infinite);
    admitted.deinit();
    try std.testing.expect(try motion.construct(a, yielding_infinite, .{}) == null);
}

test "a live zero-trip destination requires the guard even for a total scalar" {
    var good = (try motion.construct(a, guarded, .{})).?;
    defer good.deinit();
    try std.testing.expectEqual(motion.Placement.guarded, good.witness.placement);
    try motion.validate(a, guarded, good.program, good.witness, .{});
    var speculative = (try motion.construct(a, counted, .{})).?;
    defer speculative.deinit();
    const blocks = try a.dupe(ir.Block, speculative.program.blocks);
    defer a.free(blocks);
    blocks[3].terminator = guarded.blocks[3].terminator;
    var forged = speculative.program;
    forged.blocks = blocks;
    forged.functions = guarded.functions;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidLoopMotion,
        motion.validate(a, guarded, forged, speculative.witness, .{}),
    );
}
