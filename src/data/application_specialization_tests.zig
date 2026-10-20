// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const specialize = @import("application_specialization.zig");
const facts = @import("value_facts.zig");
const coalescing = @import("coalescing.zig");
const a = std.testing.allocator;
pub const captured: ir.Program = .{
    .roots = .{ .entry = 0, .result = 3, .failure = 1 },
    .schemas = &.{
        .u64,                       .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 3,
            .capture_bound = &.{0},
            .use = .linear,
        } } },
        .{ .product = &.{ 0, 0 } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 2, 3 } },
            .result = 3,
        },
        .{ .entry = 2, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 3 } }, .result = 3 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .computation,
                .operands = &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .apply = .{
                .computation = 2,
                .arguments = &.{1},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } }},
            .terminator = .{ .return_value = 2 },
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .linear }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
};

test "captured application becomes an ordered direct call and final P01 runs" {
    var statistics: specialize.Statistics = .{};
    var p01: coalescing.Statistics = .{};
    var result = try specialize.run(a, captured, &statistics, .{ .statistics = &p01 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), statistics.direct_applications);
    try std.testing.expectEqual(@as(usize, 1), statistics.eliminated_constructions);
    try std.testing.expect(p01.outcome != .not_run);
    var calls: usize = 0;
    for (result.program.blocks) |block| {
        try std.testing.expect(block.terminator != .apply);
        for (block.instructions) |instruction| try std.testing.expect(
            instruction.opcode != .computation,
        );
        if (block.terminator == .call) calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), calls);
    const before = try @import("program_image.zig").encodedLength(captured);
    const after = try @import("program_image.zig").encodedLength(result.program);
    try std.testing.expect(after < before);
    std.debug.print(
        "captured specialization: BPI3 {d} -> {d} bytes; apply/construction 1 -> 0\n",
        .{ before, after },
    );
}

test "independent checker rejects swapped equal-type captures and arguments" {
    var blocks = captured.blocks[0..3].*;
    blocks[0].instructions = &.{};
    blocks[0].terminator = .{ .call = .{
        .function = 1,
        .arguments = &.{ 0, 1 },
        .next = captured.blocks[0].terminator.apply.next,
    } };
    var candidate = captured;
    candidate.blocks = &blocks;
    try specialize.validate(a, captured, candidate, &.{.{ .block = 0, .construction = 0 }});
    blocks[0].terminator.call.arguments = &.{ 1, 0 };
    try std.testing.expectError(
        error.InvalidSpecialization,
        specialize.validate(a, captured, candidate, &.{.{ .block = 0, .construction = 0 }}),
    );
}

test "an overwritten capture version retains the original application" {
    var blocks = captured.blocks[0..3].*;
    blocks[0].instructions = &.{
        captured.blocks[0].instructions[0],
        .{ .destination = 0, .opcode = .move, .operands = &.{1} },
    };
    var input = captured;
    input.blocks = &blocks;
    var statistics: specialize.Statistics = .{};
    var result = try specialize.run(a, input, &statistics, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), statistics.direct_applications);
    try std.testing.expectEqual(@as(usize, 1), statistics.unavailable_captures);
}

test "facts cannot be reused after constructor catalog mutation" {
    var known = try facts.analyze(a, captured);
    defer known.deinit();
    var changed = captured;
    changed.constructors = &.{ captured.constructors[0], captured.constructors[0] };
    try std.testing.expectError(error.StaleFacts, known.requireEpoch(a, changed));
}

test "unknown input masking gains bits while a vector bound is not its length" {
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit, .{ .vector = .{ .element = 0, .maximum = 16 } } },
        .constants = &.{.{ .schema = 0, .bytes = &.{ 15, 0, 0, 0, 0, 0, 0, 0 } }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 2, 0, 0, 0, 0 } },
            .result = 0,
        }},
        .blocks = &.{.{ .function = 0, .instructions = &.{
            .{ .destination = 2, .opcode = .constant, .immediate = 0 },
            .{ .destination = 3, .opcode = .integer_bit_and, .operands = &.{ 1, 2 } },
            .{ .destination = 4, .opcode = .sequence_length, .operands = &.{0} },
        }, .terminator = .{ .return_value = 3 } }},
    };
    var known = try facts.analyze(a, program);
    defer known.deinit();
    const block = known.blocks[0];
    const mask = block.definitions[block.results[1]].value;
    try std.testing.expectEqual(@as(?u64, 15), mask.maximum);
    try std.testing.expectEqual(~@as(u64, 15), mask.known_zero);
    try std.testing.expectEqual(@as(?u64, null), mask.unsigned);
    const length = block.definitions[block.results[2]].value;
    try std.testing.expectEqual(@as(?u64, 16), length.maximum);
    try std.testing.expectEqual(@as(?u64, null), length.unsigned);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try specialize.run(allocator, captured, null, .{});
    defer result.deinit();
}
test "specialization releases every partial owner on allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "parallel edge assignments read one predecessor view and loops widen constants" {
    const swap = ir.Edge{
        .block = 1,
        .assignments = &.{
            .{ .destination = 0, .source = .{ .slot = 1 } },
            .{ .destination = 1, .source = .{ .slot = 0 } },
        },
    };
    var program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit, .boolean },
        .constants = &.{
            .{ .schema = 0, .bytes = &.{ 4, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 0, .bytes = &.{ 9, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{2},
            .layout = .{ .slots = &.{ 0, 0, 2 } },
            .result = 0,
        }},
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{
                    .{ .destination = 0, .opcode = .constant, .immediate = 0 },
                    .{ .destination = 1, .opcode = .constant, .immediate = 1 },
                },
                .terminator = .{ .jump = swap },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        },
    };
    var acyclic = try facts.analyze(a, program);
    defer acyclic.deinit();
    try std.testing.expectEqual(@as(?u64, 9), acyclic.blocks[1].definitions[0].value.unsigned);
    try std.testing.expectEqual(@as(?u64, 4), acyclic.blocks[1].definitions[1].value.unsigned);
    program.blocks = &.{
        program.blocks[0],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = swap,
                .when_false = .{ .block = 2 },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var cyclic = try facts.analyze(a, program);
    defer cyclic.deinit();
    for (cyclic.blocks[1].definitions[0..2]) |definition| {
        try std.testing.expectEqual(@as(?u64, null), definition.value.unsigned);
        try std.testing.expectEqual(@as(?u64, 9), definition.value.maximum);
        try std.testing.expectEqual(~@as(u64, 13), definition.value.known_zero);
    }
    try std.testing.expect(cyclic.blocks[2].reachable);
}

fn branchProgram(comptime known: bool) ir.Program {
    return .{
        .roots = captured.roots,
        .schemas = &.{
            captured.schemas[0],
            captured.schemas[1],
            captured.schemas[2],
            captured.schemas[3],
            .boolean,
        },
        .constants = &.{.{ .schema = 4, .bytes = &.{1} }},
        .effects = &.{},
        .functions = &.{
            .{
                .entry = 0,
                .inputs = if (known) &.{ 0, 1 } else &.{ 0, 1, 4 },
                .layout = .{ .slots = &.{ 0, 0, 2, 3, 4 } },
                .result = 3,
            },
            .{
                .entry = 5,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 0, 0, 3 } },
                .result = 3,
            },
            .{
                .entry = 6,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 0, 0, 3 } },
                .result = 3,
            },
        },
        .blocks = &.{
            .{
                .function = 0,
                .instructions = if (known) &.{.{
                    .destination = 4,
                    .opcode = .constant,
                    .immediate = 0,
                }} else &.{},
                .terminator = .{ .branch = .{
                    .condition = 4,
                    .when_true = .{ .block = 1 },
                    .when_false = .{ .block = 2 },
                } },
            },
            .{
                .function = 0,
                .instructions = &.{.{
                    .destination = 2,
                    .opcode = .computation,
                    .operands = &.{0},
                    .immediate = 0,
                }},
                .terminator = .{ .jump = .{ .block = 3 } },
            },
            .{
                .function = 0,
                .instructions = &.{.{
                    .destination = 2,
                    .opcode = .computation,
                    .operands = &.{1},
                    .immediate = 1,
                }},
                .terminator = .{ .jump = .{ .block = 3 } },
            },
            .{
                .function = 0,
                .instructions = &.{},
                .terminator = .{ .apply = .{
                    .computation = 2,
                    .arguments = &.{1},
                    .next = .{
                        .block = 4,
                        .assignments = &.{.{ .destination = 3, .source = .returned }},
                    },
                } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
            .{
                .function = 1,
                .instructions = captured.blocks[2].instructions,
                .terminator = captured.blocks[2].terminator,
            },
            .{
                .function = 2,
                .instructions = &.{.{
                    .destination = 2,
                    .opcode = .product,
                    .operands = &.{ 1, 0 },
                }},
                .terminator = .{ .return_value = 2 },
            },
        },
        .scopes = captured.scopes,
        .constructors = &.{
            captured.constructors[0],
            .{ .function = 2, .capture = 0, .schema = 2 },
        },
    };
}
test "feasible edges narrow constructor sets without inventing an opaque environment" {
    var polymorphic = try facts.analyze(a, comptime branchProgram(false));
    defer polymorphic.deinit();
    const many = polymorphic.blocks[3].definitions[2].value;
    try std.testing.expect(many.constructors_known);
    try std.testing.expectEqual(@as(u3, 2), many.constructor_count);
    try std.testing.expectEqual(@as(?p.Id, null), many.constructor);
    var singleton = try facts.analyze(a, comptime branchProgram(true));
    defer singleton.deinit();
    try std.testing.expect(!singleton.blocks[2].reachable);
    const one = singleton.blocks[3].definitions[2].value;
    try std.testing.expectEqual(@as(?p.Id, 0), one.constructor);
    try std.testing.expectEqual(@as(?usize, null), one.construction);
}

fn closedBranchProgram(comptime known: bool) ir.Program {
    var program = comptime branchProgram(known);
    program.schemas = &.{
        .u64,                       .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 3,
            .use = .reusable,
        } } },
        .{ .product = &.{ 0, 0 } }, .boolean,
    };
    program.constants = &.{
        .{ .schema = 4, .bytes = &.{1} },
        .{ .schema = 0, .bytes = &.{ 99, 0, 0, 0, 0, 0, 0, 0 } },
    };
    program.functions = &.{
        program.functions[0],
        .{ .entry = 5, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0, 3 } }, .result = 3 },
        .{ .entry = 6, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0, 3 } }, .result = 3 },
    };
    program.blocks = &.{
        program.blocks[0],
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .computation, .immediate = 0 }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 2, .opcode = .computation, .immediate = 1 }},
            .terminator = .{ .jump = .{ .block = 3 } },
        },
        program.blocks[3],
        program.blocks[4],
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 2, .opcode = .product, .operands = &.{ 0, 0 } }},
            .terminator = .{ .return_value = 2 },
        },
        .{
            .function = 2,
            .instructions = &.{
                .{ .destination = 1, .opcode = .constant, .immediate = 1 },
                .{ .destination = 2, .opcode = .product, .operands = &.{ 1, 0 } },
            },
            .terminator = .{ .return_value = 2 },
        },
    };
    program.scopes = .{ .captures = &.{.{ .fields = &.{}, .use = .reusable }} };
    return program;
}
test "checked feasible branch removes the alternate constructor and unlocks a direct call" {
    const branch = @import("branch_reduction.zig");
    const program = comptime closedBranchProgram(true);
    var branch_stats: branch.Statistics = .{};
    var reduced = try branch.run(a, program, &branch_stats, .{});
    defer reduced.deinit();
    try std.testing.expectEqual(@as(usize, 1), branch_stats.branches_removed);
    try std.testing.expectEqual(@as(usize, 1), reduced.program.constructors.len);
    var stats: specialize.Statistics = .{};
    var specialized = try specialize.run(a, reduced.program, &stats, .{});
    defer specialized.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.direct_applications);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_constructions);
    for (specialized.program.blocks) |block| try std.testing.expect(
        block.terminator != .apply and block.terminator != .branch,
    );
    std.debug.print(
        "branch/constructor specialization: BPI3 {d} -> {d} bytes\n",
        .{
            try @import("program_image.zig").encodedLength(program),
            try @import("program_image.zig").encodedLength(specialized.program),
        },
    );
}

test "unknown external condition and forged branch certificates retain both targets" {
    const branch = @import("branch_reduction.zig");
    const program = comptime closedBranchProgram(false);
    var stats: branch.Statistics = .{};
    var unchanged = try branch.run(a, program, &stats, .{});
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.branches_removed);
    try std.testing.expectEqual(@as(usize, 2), unchanged.program.constructors.len);
    var blocks = program.blocks[0..7].*;
    blocks[0].terminator = .{ .jump = program.blocks[0].terminator.branch.when_true };
    var forged = program;
    forged.blocks = &blocks;
    try std.testing.expectError(
        error.InvalidBranchReduction,
        branch.validate(a, program, forged, &.{.{ .block = 0, .condition = true }}),
    );
}

test "branch reduction checks an invalid unselected constructor before erasing its path" {
    var program = comptime closedBranchProgram(true);
    var blocks = program.blocks[0..7].*;
    blocks[2].instructions = &.{.{ .destination = 2, .opcode = .computation, .immediate = 99 }};
    program.blocks = &blocks;
    try std.testing.expectError(
        error.InvalidReference,
        @import("branch_reduction.zig").run(a, program, null, .{}),
    );
}

fn branchAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("branch_reduction.zig").run(
        allocator,
        comptime closedBranchProgram(true),
        null,
        .{},
    );
    defer result.deinit();
}
test "branch proof and candidate owners release on every allocation failure" {
    try @import("allocation_testing.zig").check(a, branchAllocationAttempt, .{});
}

test "dead computation removes the closed constructor left by direct specialization" {
    const dead = @import("dead_computation.zig");
    var reduced = try @import("branch_reduction.zig").run(
        a,
        comptime closedBranchProgram(true),
        null,
        .{},
    );
    defer reduced.deinit();
    var specialized = try specialize.run(a, reduced.program, null, .{});
    defer specialized.deinit();
    var stats: dead.Statistics = .{};
    var result = try dead.run(a, specialized.program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.constructions_removed);
    try std.testing.expect(stats.instructions_removed >= 2);
    for (result.program.blocks) |block| for (block.instructions) |instruction| {
        try std.testing.expect(instruction.opcode != .computation);
    };
    std.debug.print(
        "dead computation after specialization: {d} -> {d} bytes\n",
        .{
            try @import("program_image.zig").encodedLength(specialized.program),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}

const dead_fixture: ir.Program = .{
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
    .blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 1, .opcode = .constant, .immediate = 0 },
        .{ .destination = 2, .opcode = .move, .operands = &.{1} },
    }, .terminator = .{ .return_value = 0 } }},
};

test "dead computation removes a total dependency chain and rolls back on work limit" {
    const dead = @import("dead_computation.zig");
    var stats: dead.Statistics = .{};
    var result = try dead.run(a, dead_fixture, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), stats.instructions_removed);
    var p01: coalescing.Statistics = .{};
    var rollback = try dead.run(
        a,
        dead_fixture,
        &stats,
        .{ .work_limit = 0, .coalescing = .{ .statistics = &p01 } },
    );
    defer rollback.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(@as(usize, 0), stats.instructions_removed);
    try std.testing.expect(p01.outcome != .not_run);
    try std.testing.expectEqual(@as(usize, 2), rollback.program.blocks[0].instructions.len);
}

fn deadAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("dead_computation.zig").run(allocator, dead_fixture, null, .{});
    defer result.deinit();
}
test "dead computation releases all partial owners on allocation failure" {
    try @import("allocation_testing.zig").check(a, deadAllocationAttempt, .{});
}

test "independent dead checker rejects erasing a live overwrite despite valid candidate admission" {
    const dead = @import("dead_computation.zig");
    var original = dead_fixture;
    original.blocks = &.{.{
        .function = 0,
        .instructions = &.{.{ .destination = 0, .opcode = .constant, .immediate = 0 }},
        .terminator = .{ .return_value = 0 },
    }};
    var candidate = original;
    candidate.blocks = &.{.{
        .function = 0,
        .instructions = &.{},
        .terminator = .{ .return_value = 0 },
    }};
    try std.testing.expectError(
        error.InvalidDeadComputation,
        dead.validate(a, original, candidate, &.{.{ .block = 0, .removed = &.{0} }}),
    );
}

test "unused division and its failure remain observable" {
    const dead = @import("dead_computation.zig");
    var original = dead_fixture;
    original.constants = &.{ dead_fixture.constants[0], .{ .schema = 1, .bytes = &.{} } };
    original.blocks = &.{.{
        .function = 0,
        .instructions = &.{.{
            .destination = 1,
            .opcode = .integer_div,
            .operands = &.{ 0, 0 },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = 1 },
                .{ .kind = .division_by_zero, .value = 1 },
            },
        }},
        .terminator = .{ .return_value = 0 },
    }};
    var stats: dead.Statistics = .{};
    var result = try dead.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.instructions_removed);
    var candidate = original;
    candidate.blocks = &.{.{
        .function = 0,
        .instructions = &.{},
        .terminator = .{ .return_value = 0 },
    }};
    try std.testing.expectError(
        error.InvalidDeadComputation,
        dead.validate(a, original, candidate, &.{.{ .block = 0, .removed = &.{0} }}),
    );
}

fn argumentBranchProgram(comptime known: bool) ir.Program {
    var program = comptime closedBranchProgram(false);
    program.roots = .{ .entry = 3, .result = 3, .failure = 1 };
    program.functions = &.{
        program.functions[0], program.functions[1], program.functions[2],
        .{
            .entry = 7,
            .inputs = if (known) &.{ 0, 1 } else &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 0, 4, 3 } },
            .result = 3,
        },
    };
    program.blocks = &.{
        program.blocks[0],
        program.blocks[1],
        program.blocks[2],
        program.blocks[3],
        program.blocks[4],
        program.blocks[5],
        program.blocks[6],
        .{
            .function = 3,
            .instructions = if (known) &.{.{
                .destination = 2,
                .opcode = .constant,
                .immediate = 0,
            }} else &.{},
            .terminator = .{ .call = .{
                .function = 0,
                .arguments = &.{ 0, 1, 2 },
                .next = .{
                    .block = 8,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
    };
    return program;
}

test "known caller argument prunes the worker branch and unlocks constructor specialization" {
    const branch = @import("branch_reduction.zig");
    const original = comptime argumentBranchProgram(true);
    var branch_stats: branch.Statistics = .{};
    var reduced = try branch.run(a, original, &branch_stats, .{});
    defer reduced.deinit();
    try std.testing.expectEqual(@as(usize, 1), branch_stats.branches_removed);
    try std.testing.expectEqual(@as(usize, 1), reduced.program.constructors.len);
    var stats: specialize.Statistics = .{};
    var result = try specialize.run(a, reduced.program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.direct_applications);
    std.debug.print(
        "known caller argument: {d} -> {d} bytes\n",
        .{
            try @import("program_image.zig").encodedLength(original),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}

test "unknown host argument does not become a private-worker constant" {
    var stats: @import("branch_reduction.zig").Statistics = .{};
    var result = try @import("branch_reduction.zig").run(
        a,
        comptime argumentBranchProgram(false),
        &stats,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.branches_removed);
    try std.testing.expectEqual(@as(usize, 2), result.program.constructors.len);
}

fn incomingCallableProgram(comptime closed: bool) ir.Program {
    var program = captured;
    program.functions = &.{
        captured.functions[0],
        if (closed) .{
            .entry = 2,
            .inputs = &.{1},
            .layout = .{ .slots = &.{ 0, 0, 3 } },
            .result = 3,
        } else captured.functions[1],
        .{ .entry = 3, .inputs = &.{ 2, 1 }, .layout = captured.functions[0].layout, .result = 3 },
    };
    program.schemas = if (closed) &.{
        .u64,                       .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 3,
            .use = .reusable,
        } } },
        .{ .product = &.{ 0, 0 } },
    } else captured.schemas;
    program.scopes = if (closed) .{ .captures = &.{.{
        .fields = &.{},
        .use = .reusable,
    }} } else captured.scopes;
    program.blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .computation,
                .operands = if (closed) &.{} else &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .call = .{
                .function = 2,
                .arguments = &.{ 2, 1 },
                .next = captured.blocks[0].terminator.apply.next,
            } },
        },
        captured.blocks[1],
        if (closed) .{
            .function = 1,
            .instructions = &.{.{ .destination = 2, .opcode = .product, .operands = &.{ 1, 1 } }},
            .terminator = .{ .return_value = 2 },
        } else captured.blocks[2],
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 2,
                .arguments = &.{1},
                .next = .{
                    .block = 4,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
    };
    return program;
}

test "singleton incoming callable specializes its worker while opaque captured environment stays" {
    var stats: specialize.Statistics = .{};
    var result = try specialize.run(a, comptime incomingCallableProgram(true), &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.direct_applications);
    try std.testing.expectEqual(@as(usize, 1), stats.retained_constructions);
    var retained = try specialize.run(a, comptime incomingCallableProgram(false), &stats, .{});
    defer retained.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.direct_applications);
}

fn polymorphicIncomingProgram() ir.Program {
    var program = comptime closedBranchProgram(false);
    program.functions = &.{
        program.functions[0],
        program.functions[1],
        program.functions[2],
        .{ .entry = 7, .inputs = &.{ 2, 1 }, .layout = program.functions[0].layout, .result = 3 },
    };
    program.blocks = &.{
        program.blocks[0],
        program.blocks[1],
        program.blocks[2],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 3,
                .arguments = &.{ 2, 1 },
                .next = program.blocks[3].terminator.apply.next,
            } },
        },
        program.blocks[4],
        program.blocks[5],
        program.blocks[6],
        .{
            .function = 3,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 2,
                .arguments = &.{1},
                .next = .{
                    .block = 8,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
    };
    return program;
}

test "two incoming constructors retain dispatch and reject a forged direct-call certificate" {
    const original = comptime polymorphicIncomingProgram();
    var stats: specialize.Statistics = .{};
    var result = try specialize.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.direct_applications);
    var blocks = original.blocks[0..9].*;
    blocks[7].terminator = .{ .call = .{
        .function = 1,
        .arguments = &.{1},
        .next = original.blocks[7].terminator.apply.next,
    } };
    var candidate = original;
    candidate.blocks = &blocks;
    try std.testing.expectError(
        error.InvalidSpecialization,
        specialize.validate(a, original, candidate, &.{.{ .block = 7 }}),
    );
}

test "recursive call component joins changing arguments and never freezes the first caller" {
    const original: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .boolean, .unit },
        .constants = &.{.{ .schema = 0, .bytes = &.{1} }},
        .effects = &.{},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
            .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        },
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{.{ .destination = 0, .opcode = .constant, .immediate = 0 }},
                .terminator = .{ .call = .{
                    .function = 1,
                    .arguments = &.{0},
                    .next = .{
                        .block = 1,
                        .assignments = &.{.{ .destination = 0, .source = .returned }},
                    },
                } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{
                .function = 1,
                .instructions = &.{},
                .terminator = .{ .branch = .{
                    .condition = 0,
                    .when_true = .{ .block = 3 },
                    .when_false = .{ .block = 4 },
                } },
            },
            .{
                .function = 1,
                .instructions = &.{.{
                    .destination = 0,
                    .opcode = .boolean_not,
                    .operands = &.{0},
                }},
                .terminator = .{ .call = .{
                    .function = 1,
                    .arguments = &.{0},
                    .next = .{
                        .block = 4,
                        .assignments = &.{.{ .destination = 0, .source = .returned }},
                    },
                } },
            },
            .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        },
    };
    var known = try facts.analyze(a, original);
    defer known.deinit();
    try std.testing.expectEqual(@as(?bool, null), known.blocks[2].definitions[0].value.boolean);
    var stats: @import("branch_reduction.zig").Statistics = .{};
    var result = try @import("branch_reduction.zig").run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.branches_removed);
}

test "constructor-visible worker stays open even when its observed direct argument is constant" {
    var original = comptime argumentBranchProgram(true);
    original.schemas = &.{
        original.schemas[0],
        original.schemas[1],
        original.schemas[2],
        original.schemas[3],
        original.schemas[4],
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 0, 0, 4 },
            .result = 3,
            .use = .reusable,
        } } },
    };
    original.constructors = &.{
        original.constructors[0],                      original.constructors[1],
        .{ .function = 0, .capture = 0, .schema = 5 },
    };
    var known = try facts.analyze(a, original);
    defer known.deinit();
    try std.testing.expectEqual(@as(?bool, null), known.blocks[0].definitions[4].value.boolean);
    var stats: @import("branch_reduction.zig").Statistics = .{};
    var result = try @import("branch_reduction.zig").run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.branches_removed);
}

fn callerAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("branch_reduction.zig").run(
        allocator,
        comptime argumentBranchProgram(true),
        null,
        .{},
    );
    defer result.deinit();
}
test "call-context propagation and independent caller proof release allocation failures" {
    try @import("allocation_testing.zig").check(a, callerAllocationAttempt, .{});
}

test "private dead callable argument removal unlocks constructor elimination" {
    const dead_args = @import("dead_arguments.zig");
    const original = comptime incomingCallableProgram(true);
    var specialized = try specialize.run(a, original, null, .{});
    defer specialized.deinit();
    var stats: dead_args.Statistics = .{};
    var smaller = try dead_args.run(a, specialized.program, &stats, .{});
    defer smaller.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.parameters_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.call_arguments_removed);
    var dead_stats: @import("dead_computation.zig").Statistics = .{};
    var result = try @import("dead_computation.zig").run(a, smaller.program, &dead_stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), dead_stats.constructions_removed);
    std.debug.print(
        "incoming callable plus dead argument/construction: {d} -> {d} bytes\n",
        .{
            try @import("program_image.zig").encodedLength(original),
            try @import("program_image.zig").encodedLength(result.program),
        },
    );
}

const private_arguments: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 1 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    },
};

test "dead argument checker preserves ordered correspondence at every call" {
    const dead = @import("dead_arguments.zig");
    var functions = private_arguments.functions[0..2].*;
    functions[1].inputs = &.{1};
    var blocks = private_arguments.blocks[0..3].*;
    blocks[0].terminator.call.arguments = &.{1};
    var candidate = private_arguments;
    candidate.functions = &functions;
    candidate.blocks = &blocks;
    try dead.validate(a, private_arguments, candidate, &.{.{ .function = 1, .removed = &.{0} }});
    blocks[0].terminator.call.arguments = &.{0};
    try std.testing.expectError(
        error.InvalidDeadArguments,
        dead.validate(a, private_arguments, candidate, &.{.{ .function = 1, .removed = &.{0} }}),
    );
}

fn deadArgumentAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("dead_arguments.zig").run(allocator, private_arguments, null, .{});
    defer result.deinit();
}
test "dead argument transformation releases all partial owners" {
    try @import("allocation_testing.zig").check(a, deadArgumentAllocationAttempt, .{});
}

test "a computation reused as a handler body retains its construction" {
    var program = captured;
    program.schemas = &.{
        .u64,                .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 3,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
        captured.schemas[3],
    };
    program.scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} };
    program.functions = &.{
        captured.functions[0],
        captured.functions[1],
        .{ .entry = 4, .inputs = &.{0}, .layout = .{ .slots = &.{3} }, .result = 3 },
    };
    program.handlers = &.{.{
        .mode = .deep,
        .input = 3,
        .answer = 3,
        .return_function = 2,
        .clauses = &.{},
    }};
    program.blocks = &.{
        captured.blocks[0],
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .handle = .{
                .handler = 0,
                .body = 2,
                .arguments = &.{1},
                .state = &.{},
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        captured.blocks[2],
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var stats: specialize.Statistics = .{};
    var result = try specialize.run(a, program, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.eliminated_constructions);
    try std.testing.expectEqual(@as(usize, 0), stats.direct_applications);
}

test "dead computation retains the source of an explicit dead edge assignment" {
    const original: ir.Program = .{
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
                .terminator = .{ .jump = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 2, .source = .{ .slot = 1 } }},
                } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        },
    };
    var stats: @import("dead_computation.zig").Statistics = .{};
    var result = try @import("dead_computation.zig").run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.instructions_removed);
}

fn maskedBranch(comptime opcode: p.Opcode) ir.Program {
    return .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit, .boolean },
        .constants = &.{
            .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
            .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 2 } },
            .result = 0,
        }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{
                .{ .destination = 1, .opcode = .constant, .immediate = 0 },
                .{ .destination = 2, .opcode = .constant, .immediate = 1 },
                .{ .destination = 3, .opcode = .integer_bit_and, .operands = &.{ 0, 1 } },
                .{ .destination = 4, .opcode = opcode, .operands = &.{ 3, 2 } },
            }, .terminator = .{ .branch = .{
                .condition = 4,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        },
    };
}

test "integer facts feed independently checked equal and less branch reductions" {
    const branch = @import("branch_reduction.zig");
    inline for (.{ p.Opcode.equal, p.Opcode.less }) |opcode| {
        const program = comptime maskedBranch(opcode);
        var stats: branch.Statistics = .{};
        var result = try branch.run(a, program, &stats, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), stats.branches_removed);
        try std.testing.expectEqual(@as(usize, 0), stats.proof_unavailable);
        for (result.program.blocks) |block| try std.testing.expect(block.terminator != .branch);
        var blocks = program.blocks[0..3].*;
        blocks[0].terminator = .{ .jump = program.blocks[0].terminator.branch.when_false };
        var candidate = program;
        candidate.blocks = &blocks;
        if (opcode == .less) {
            try std.testing.expectError(
                error.InvalidBranchReduction,
                branch.validate(a, program, candidate, &.{.{ .block = 0, .condition = false }}),
            );
        } else {
            try branch.validate(a, program, candidate, &.{.{ .block = 0, .condition = false }});
        }
    }
}

test "integer branch proof rejects unknown operands and changed comparison order" {
    const branch = @import("branch_reduction.zig");
    const baseline = comptime maskedBranch(.less);
    var instructions = baseline.blocks[0].instructions[0..4].*;
    instructions[3].operands = &.{ 2, 3 };
    var blocks = baseline.blocks[0..3].*;
    blocks[0].instructions = &instructions;
    var original = baseline;
    original.blocks = &blocks;
    var candidate_blocks = blocks;
    candidate_blocks[0].terminator = .{ .jump = baseline.blocks[0].terminator.branch.when_true };
    var candidate = original;
    candidate.blocks = &candidate_blocks;
    try std.testing.expectError(
        error.InvalidBranchReduction,
        branch.validate(a, original, candidate, &.{.{ .block = 0, .condition = true }}),
    );
    instructions[3].operands = &.{ 0, 2 };
    var stats: branch.Statistics = .{};
    var unchanged = try branch.run(a, original, &stats, .{});
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.branches_removed);
    try std.testing.expectError(
        error.InvalidBranchReduction,
        branch.validate(a, original, candidate, &.{.{ .block = 0, .condition = true }}),
    );
}

pub fn variantBranch(comptime known: bool) ir.Program {
    return .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit, .boolean, .{ .sum = &.{ 0, 0 } } },
        .effects = &.{},
        .constants = &.{.{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } }},
        .functions = &.{.{
            .entry = 0,
            .inputs = if (known) &.{0} else &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 3, 0, 0, 2 } },
            .result = 0,
        }},
        .blocks = &.{
            .{ .function = 0, .instructions = if (known) &.{
                .{ .destination = 1, .opcode = .variant, .operands = &.{0}, .immediate = 1 },
                .{ .destination = 2, .opcode = .variant_tag, .operands = &.{1} },
                .{ .destination = 3, .opcode = .constant, .immediate = 0 },
                .{ .destination = 4, .opcode = .equal, .operands = &.{ 2, 3 } },
            } else &.{
                .{ .destination = 2, .opcode = .variant_tag, .operands = &.{1} },
                .{ .destination = 3, .opcode = .constant, .immediate = 0 },
                .{ .destination = 4, .opcode = .equal, .operands = &.{ 2, 3 } },
            }, .terminator = .{ .branch = .{
                .condition = 4,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        },
    };
}

test "known variant tag feeds independent branch proof while external variants stay unknown" {
    const branch = @import("branch_reduction.zig");
    inline for (.{ true, false }) |known| {
        const original = comptime variantBranch(known);
        var stats: branch.Statistics = .{};
        var result = try branch.run(a, original, &stats, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, if (known) 1 else 0), stats.branches_removed);
        var blocks = original.blocks[0..3].*;
        blocks[0].terminator = .{ .jump = original.blocks[0].terminator.branch.when_false };
        var forged = original;
        forged.blocks = &blocks;
        try std.testing.expectError(
            error.InvalidBranchReduction,
            branch.validate(a, original, forged, &.{.{ .block = 0, .condition = false }}),
        );
    }
}

fn joinedVariants(comptime same_tag: bool) ir.Program {
    const base = comptime variantBranch(false);
    return .{
        .roots = base.roots,
        .schemas = base.schemas,
        .effects = base.effects,
        .constants = base.constants,
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{ 0, 4 },
            .layout = base.functions[0].layout,
            .result = 0,
        }},
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{},
                .terminator = .{ .branch = .{
                    .condition = 4,
                    .when_true = .{ .block = 1 },
                    .when_false = .{ .block = 2 },
                } },
            },
            .{
                .function = 0,
                .instructions = &.{.{
                    .destination = 1,
                    .opcode = .variant,
                    .operands = &.{0},
                    .immediate = 1,
                }},
                .terminator = .{ .jump = .{ .block = 3 } },
            },
            .{
                .function = 0,
                .instructions = &.{.{
                    .destination = 1,
                    .opcode = .variant,
                    .operands = &.{0},
                    .immediate = if (same_tag) 1 else 0,
                }},
                .terminator = .{ .jump = .{ .block = 3 } },
            },
            .{
                .function = 0,
                .instructions = base.blocks[0].instructions,
                .terminator = .{ .branch = .{
                    .condition = 4,
                    .when_true = .{ .block = 4 },
                    .when_false = .{ .block = 5 },
                } },
            },
            base.blocks[1],
            base.blocks[2],
        },
    };
}

test "variant joins preserve alternatives and certify only agreement" {
    const branch = @import("branch_reduction.zig");
    inline for (.{ true, false }) |same_tag| {
        const original = comptime joinedVariants(same_tag);
        var info = try facts.analyze(a, original);
        defer info.deinit();
        const variants = info.blocks[3].definitions[1].value.variants;
        try std.testing.expect(variants.known);
        try std.testing.expectEqual(@as(u3, if (same_tag) 1 else 2), variants.count);
        var stats: branch.Statistics = .{};
        var result = try branch.run(a, original, &stats, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, if (same_tag) 1 else 0), stats.branches_removed);
    }
}

test "known switch tag excludes only impossible cases and never becomes its payload" {
    const base = comptime variantBranch(true);
    var original = base;
    original.blocks = &.{
        .{
            .function = 0,
            .instructions = base.blocks[0].instructions[0..1],
            .terminator = .{ .switch_variant = .{
                .value = 1,
                .cases = &.{ .{ .block = 1 }, .{ .block = 2 } },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var info = try facts.analyze(a, original);
    defer info.deinit();
    try std.testing.expect(!info.blocks[1].reachable);
    try std.testing.expect(info.blocks[2].reachable);
    const next: ir.Edge = .{
        .block = 1,
        .assignments = &.{.{ .destination = 2, .source = .returned }},
    };
    original.blocks = &.{
        .{
            .function = 0,
            .instructions = base.blocks[0].instructions[0..1],
            .terminator = .{ .switch_variant = .{ .value = 1, .cases = &.{ next, next } } },
        },
        .{
            .function = 0,
            .instructions = base.blocks[0].instructions[2..4],
            .terminator = .{ .branch = .{
                .condition = 4,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 3 },
            } },
        },
        base.blocks[1],
        base.blocks[2],
    };
    var payload_info = try facts.analyze(a, original);
    defer payload_info.deinit();
    try std.testing.expectEqual(
        @as(?u64, null),
        payload_info.blocks[1].definitions[2].value.unsigned,
    );
    var stats: @import("branch_reduction.zig").Statistics = .{};
    var result = try @import("branch_reduction.zig").run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.branches_removed);
}

test "changing a variant tag invalidates a prior branch certificate" {
    const branch = @import("branch_reduction.zig");
    const original = comptime variantBranch(true);
    var known = try facts.analyze(a, original);
    defer known.deinit();
    var instructions = original.blocks[0].instructions[0..4].*;
    instructions[0].immediate = 0;
    var blocks = original.blocks[0..3].*;
    blocks[0].instructions = &instructions;
    var changed = original;
    changed.blocks = &blocks;
    try std.testing.expectError(error.StaleFacts, known.requireEpoch(a, changed));
    var candidate_blocks = blocks;
    candidate_blocks[0].terminator = .{ .jump = original.blocks[0].terminator.branch.when_true };
    var candidate = changed;
    candidate.blocks = &candidate_blocks;
    try std.testing.expectError(
        error.InvalidBranchReduction,
        branch.validate(a, changed, candidate, &.{.{ .block = 0, .condition = true }}),
    );
}

fn variantAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("branch_reduction.zig").run(
        allocator,
        comptime variantBranch(true),
        null,
        .{},
    );
    defer result.deinit();
}
test "variant facts and branch proofs release partial allocation owners" {
    try @import("allocation_testing.zig").check(a, variantAllocationAttempt, .{});
}
