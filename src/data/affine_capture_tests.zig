const std = @import("std");
const ir = @import("activation.zig");
const affine = @import("affine_capture.zig");
const a = std.testing.allocator;

pub const rotating: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64, .unit, .boolean,
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 0, 2 },
            .result = 0,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
    },
    .constants = &.{.{ .schema = 2, .bytes = &.{0} }},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3, 4 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 2, 3, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2, 3, 4 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 2, 0, 2, 0 } },
            .result = 0,
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 5,
                .opcode = .computation,
                .operands = &.{ 0, 1, 2 },
                .immediate = 0,
            }},
            .terminator = .{ .apply = .{
                .computation = 5,
                .arguments = &.{ 3, 4 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 6, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 6 } },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 4,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 5 },
            } },
        },
        .{ .function = 1, .instructions = &.{
            .{ .destination = 5, .opcode = .integer_bit_xor, .operands = &.{ 0, 3 } },
            .{ .destination = 6, .opcode = .constant, .immediate = 0 },
        }, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{ 1, 2, 5, 3, 6 },
            .next = .{ .block = 4, .assignments = &.{.{ .destination = 7, .source = .returned }} },
        } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 7 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 5,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .return_value = 5 },
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{ 0, 0, 0 }, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 3 }},
};

test "private recursive capture worker derives two coordinates from admitted records" {
    var plan = (try affine.analyze(a, rotating, 0, 100000)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.dimension);
    try std.testing.expectEqual(@as(usize, 2), plan.basis.len);
    try std.testing.expectEqual(@as(usize, 1), plan.transitions.len);
    try std.testing.expectEqual(@as(u128, 1), plan.transitions[0].values[2].input);
}

test "individual state observation forces full rank" {
    var program = rotating;
    var blocks = rotating.blocks[0..6].*;
    blocks[5].terminator = .{ .return_value = 0 };
    program.blocks = &blocks;
    var plan = (try affine.analyze(a, program, 0, 100000)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.basis.len);
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var plan = (try affine.analyze(allocator, rotating, 0, 100000)).?;
    defer plan.deinit();
}
test "affine capture census releases every partial owner" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    try std.testing.expectError(error.WorkLimit, affine.analyze(a, rotating, 0, 0));
}

test "affine emitter constructs a two-word recursive capture interface" {
    var candidate = (try @import("affine_emit.zig").construct(a, rotating, 0, 100000)).?;
    defer candidate.deinit();
    var admitted = try @import("activation_ownership.zig").analyze(a, candidate.program);
    defer admitted.deinit();
    const capture = candidate.program.scopes.captures[
        @intCast(candidate.program.constructors[0].capture)
    ];
    try std.testing.expectEqual(@as(usize, 2), capture.fields.len);
    try std.testing.expectEqual(@as(usize, 4), candidate.program.functions[1].inputs.len);
    try std.testing.expectEqual(
        @as(usize, 4),
        candidate.program.blocks[3].terminator.call.arguments.len,
    );
}

test "independent affine checker validates emitted equations and rejects wrong capture order" {
    const check = @import("affine_validate.zig");
    var candidate = (try @import("affine_emit.zig").construct(a, rotating, 0, 100000)).?;
    defer candidate.deinit();
    try check.validate(
        a,
        rotating,
        candidate.program,
        0,
        candidate.basis,
        candidate.input_bias,
        100000,
    );
    var altered = candidate.program;
    const blocks = try a.dupe(ir.Block, altered.blocks);
    defer a.free(blocks);
    const operations = try a.dupe(ir.Instruction, blocks[0].instructions);
    defer a.free(operations);
    const last = operations.len - 1;
    const wrong = [_]u64{ operations[last].operands[1], operations[last].operands[0] };
    operations[last].operands = &wrong;
    blocks[0].instructions = operations;
    altered.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, altered);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        check.validate(a, rotating, altered, 0, candidate.basis, candidate.input_bias, 100000),
    );
}

test "affine acceptance rejects wrong recursive input terms and basis" {
    const check = @import("affine_validate.zig");
    var candidate = (try @import("affine_emit.zig").construct(a, rotating, 0, 100000)).?;
    defer candidate.deinit();
    var altered = candidate.program;
    const blocks = try a.dupe(ir.Block, altered.blocks);
    defer a.free(blocks);
    const arguments = try a.dupe(u64, blocks[3].terminator.call.arguments);
    defer a.free(arguments);
    arguments[1] = arguments[0];
    blocks[3].terminator.call.arguments = arguments;
    altered.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, altered);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        check.validate(a, rotating, altered, 0, candidate.basis, candidate.input_bias, 100000),
    );
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        check.validate(
            a,
            rotating,
            candidate.program,
            0,
            &.{ 1, 2 },
            candidate.input_bias,
            100000,
        ),
    );
    try std.testing.expectError(
        error.WorkLimit,
        check.validate(
            a,
            rotating,
            candidate.program,
            0,
            candidate.basis,
            candidate.input_bias,
            0,
        ),
    );
}

fn checkedAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try @import("affine_state.zig").run(allocator, rotating, 0, null, 100000, .{});
    defer result.deinit();
}
test "checked affine transformation owns output and rolls back deterministic limits" {
    const pass = @import("affine_state.zig");
    var stats: pass.Statistics = .{};
    var p01: @import("coalescing.zig").Statistics = .{};
    var result = try pass.run(a, rotating, 0, &stats, 100000, .{ .statistics = &p01 });
    defer result.deinit();
    try std.testing.expectEqual(.applied, stats.outcome);
    try std.testing.expectEqual(@as(usize, 3), stats.original_words);
    try std.testing.expectEqual(@as(usize, 2), stats.reduced_words);
    try std.testing.expect(p01.outcome != .not_run);
    var limited = try pass.run(a, rotating, 0, &stats, 0, .{});
    defer limited.deinit();
    var baseline = try @import("coalescing.zig").run(a, rotating, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(.work_limit, stats.outcome);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
    try @import("allocation_testing.zig").check(a, checkedAllocationAttempt, .{});
}

test "semantic closed compilation consumes affine state while structural preserves it" {
    const compilation = @import("closed_compilation.zig");
    const Trace = struct {
        visited: bool = false,
        fn enter(context: *anyopaque, stage: compilation.Stage) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (stage == .affine_state) self.visited = true;
        }
    };
    var trace: Trace = .{};
    var structural = try compilation.run(a, rotating, .{});
    defer structural.deinit();
    var stats: compilation.Statistics = .{};
    var semantic = try compilation.run(
        a,
        rotating,
        .{
            .contract = .semantic,
            .statistics = &stats,
            .observer = .{ .context = &trace, .enter = Trace.enter },
        },
    );
    defer semantic.deinit();
    try std.testing.expect(trace.visited);
    try std.testing.expectEqual(compilation.Outcome.applied, stats.outcome);
    try std.testing.expect(stats.changed_stages > 0);
    try std.testing.expect(!std.mem.eql(
        u8,
        &(try @import("program_image.zig").identity(a, structural.program)),
        &(try @import("program_image.zig").identity(a, semantic.program)),
    ));
}

pub fn parityFixture(allocator: std.mem.Allocator, n: usize) !ir.Program {
    std.debug.assert(n >= 2 and n <= 128);
    const inputs = try allocator.alloc(u64, n + 2);
    for (inputs, 0..) |*slot, i| slot.* = i;
    const fields = try allocator.alloc(u64, n);
    @memset(fields, 0);
    const captures = try allocator.alloc(u64, n);
    for (captures, 0..) |*slot, i| slot.* = i;
    const main_layout = try allocator.alloc(u64, n + 4);
    @memset(main_layout, 0);
    main_layout[n + 1] = 2;
    main_layout[n + 2] = 3;
    const worker_layout = try allocator.alloc(u64, n + 5);
    @memset(worker_layout, 0);
    worker_layout[n + 1] = 2;
    worker_layout[n + 3] = 2;
    const call_args = try allocator.alloc(u64, n + 2);
    for (call_args[0..n], 0..) |*slot, i| {
        const permutation = (i * (if (n == 3) @as(usize, 2) else 5) + 1) % n;
        slot.* = if (permutation == 0) n + 2 else permutation;
    }
    call_args[n] = n;
    call_args[n + 1] = n + 3;
    const observations = try allocator.alloc(ir.Instruction, n - 1);
    for (
        observations,
        0..,
    ) |*op, i| op.* = .{
        .destination = n + 2,
        .opcode = .integer_bit_xor,
        .operands = try allocator.dupe(u64, &.{ if (i == 0) 0 else n + 2, i + 1 }),
    };
    var program = rotating;
    program.functions = try allocator.dupe(ir.Function, &.{
        .{ .entry = 0, .inputs = inputs, .layout = .{ .slots = main_layout }, .result = 0 },
        .{ .entry = 2, .inputs = inputs, .layout = .{ .slots = worker_layout }, .result = 0 },
    });
    program.scopes.captures = try allocator.dupe(
        @import("program.zig").Capture,
        &.{.{ .fields = fields, .use = .reusable }},
    );
    program.blocks = try allocator.dupe(ir.Block, &.{
        .{
            .function = 0,
            .instructions = try allocator.dupe(
                ir.Instruction,
                &.{.{ .destination = n + 2, .opcode = .computation, .operands = captures }},
            ),
            .terminator = .{ .apply = .{
                .computation = n + 2,
                .arguments = try allocator.dupe(u64, &.{ n, n + 1 }),
                .next = .{
                    .block = 1,
                    .assignments = try allocator.dupe(
                        ir.Assignment,
                        &.{.{ .destination = n + 3, .source = .returned }},
                    ),
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = n + 3 } },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = n + 1,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 5 },
            } },
        },
        .{ .function = 1, .instructions = try allocator.dupe(ir.Instruction, &.{
            .{
                .destination = n + 2,
                .opcode = .integer_bit_xor,
                .operands = try allocator.dupe(u64, &.{ 0, n }),
            },
            .{ .destination = n + 3, .opcode = .constant, .immediate = 0 },
        }), .terminator = .{ .call = .{
            .function = 1,
            .arguments = call_args,
            .next = .{
                .block = 4,
                .assignments = try allocator.dupe(
                    ir.Assignment,
                    &.{.{ .destination = n + 4, .source = .returned }},
                ),
            },
        } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = n + 4 } },
        .{ .function = 1, .instructions = observations, .terminator = .{ .return_value = n + 2 } },
    });
    return program;
}

test "checked capture synthesis reduces generated live-word permutations to one word" {
    for ([_]usize{ 2, 3, 8, 32, 64, 128 }) |n| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const program = try parityFixture(arena.allocator(), n);
        var stats: @import("affine_state.zig").Statistics = .{};
        var result = try @import("affine_state.zig").run(a, program, 0, &stats, 10000000, .{});
        defer result.deinit();
        try std.testing.expectEqual(.applied, stats.outcome);
        try std.testing.expectEqual(@as(usize, 1), stats.reduced_words);
    }
}

fn twoModes() ir.Program {
    var program = rotating;
    program.constants = &.{
        rotating.constants[0],
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    };
    program.blocks = &.{
        rotating.blocks[0], rotating.blocks[1], rotating.blocks[2],
        .{ .function = 1, .instructions = &.{
            .{ .destination = 5, .opcode = .constant, .immediate = 1 },
            .{ .destination = 6, .opcode = .equal, .operands = &.{ 3, 5 } },
        }, .terminator = .{ .branch = .{
            .condition = 6,
            .when_true = .{ .block = 6 },
            .when_false = .{ .block = 7 },
        } } },
        rotating.blocks[4], rotating.blocks[5], rotating.blocks[3],
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 6, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 1, 0, 2, 3, 6 },
                .next = .{
                    .block = 4,
                    .assignments = &.{.{ .destination = 7, .source = .returned }},
                },
            } },
        },
    };
    return program;
}

test "all recursive modes close and a newly added reset invalidates the old candidate" {
    const program = comptime twoModes();
    var plan = (try affine.analyze(a, program, 0, 100000)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.transitions.len);
    try std.testing.expectEqual(@as(usize, 2), plan.basis.len);
    var candidate = (try @import("affine_emit.zig").construct(a, program, 0, 100000)).?;
    defer candidate.deinit();
    try @import("affine_validate.zig").validate(
        a,
        program,
        candidate.program,
        0,
        candidate.basis,
        candidate.input_bias,
        100000,
    );
    var changed = program;
    var blocks = program.blocks[0..8].*;
    blocks[7].instructions = &.{
        .{ .destination = 6, .opcode = .constant, .immediate = 0 },
        .{ .destination = 5, .opcode = .constant, .immediate = 1 },
    };
    blocks[7].terminator.call.arguments = &.{ 5, 1, 2, 3, 6 };
    changed.blocks = &blocks;
    var expanded = (try affine.analyze(a, changed, 0, 100000)).?;
    defer expanded.deinit();
    try std.testing.expectEqual(@as(usize, 3), expanded.basis.len);
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        @import("affine_validate.zig").validate(
            a,
            changed,
            candidate.program,
            0,
            candidate.basis,
            candidate.input_bias,
            100000,
        ),
    );
}

test "rank-zero state is emitted and full-rank observation is a legal no-op" {
    const pass = @import("affine_state.zig");
    var program = rotating;
    program.constants = &.{
        rotating.constants[0],
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    };
    var blocks = rotating.blocks[0..6].*;
    blocks[5].instructions = &.{.{ .destination = 5, .opcode = .constant, .immediate = 1 }};
    program.blocks = &blocks;
    var stats: pass.Statistics = .{};
    var reduced = try pass.run(a, program, 0, &stats, 100000, .{});
    defer reduced.deinit();
    try std.testing.expectEqual(.applied, stats.outcome);
    try std.testing.expectEqual(@as(usize, 0), stats.reduced_words);
    blocks[5].terminator = .{ .return_value = 0 };
    var retained = try pass.run(a, program, 0, &stats, 100000, .{});
    defer retained.deinit();
    try std.testing.expectEqual(.no_change, stats.outcome);
    var baseline = try @import("coalescing.zig").run(a, program, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, retained.program),
    );
}

pub fn inspectionThenLoop(storage: std.mem.Allocator) !ir.Program {
    var program = try parityFixture(storage, 2);
    const schema = @import("program.zig").Schema;
    program.schemas = try storage.dupe(
        schema,
        &.{
            program.schemas[0],         program.schemas[1], program.schemas[2], program.schemas[3],
            .{ .product = &.{ 0, 0 } },
        },
    );
    program.effects = &.{.{
        .identity = "affine/full-inspection",
        .payload = 4,
        .result = 1,
        .external = true,
    }};
    const functions = try storage.dupe(ir.Function, program.functions);
    functions[0].effects = &.{0};
    functions[0].layout.slots = &.{ 0, 0, 0, 2, 3, 0, 4 };
    program.functions = functions;
    const blocks = try storage.alloc(ir.Block, 7);
    @memcpy(blocks[0..6], program.blocks);
    blocks[6] = program.blocks[0];
    blocks[0] = .{
        .function = 0,
        .instructions = &.{.{ .destination = 6, .opcode = .product, .operands = &.{ 0, 1 } }},
        .terminator = .{ .perform = .{ .effect = 0, .payload = 6, .next = .{ .block = 6 } } },
    };
    program.blocks = blocks;
    return program;
}

test "full external inspection precedes a one-coordinate private parity loop" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const program = try inspectionThenLoop(arena.allocator());
    var stats: @import("affine_state.zig").Statistics = .{};
    var result = try @import("affine_state.zig").run(a, program, 0, &stats, 1000000, .{});
    defer result.deinit();
    try std.testing.expectEqual(.applied, stats.outcome);
    try std.testing.expectEqual(@as(usize, 1), stats.reduced_words);
    try std.testing.expectEqual(
        @as(usize, 4),
        result.program.functions[@intCast(result.program.roots.entry)].inputs.len,
    );
    try std.testing.expectEqual(@as(usize, 1), result.program.effects.len);
    const effect = result.program.effects[0];
    try std.testing.expectEqualSlices(u8, "affine/full-inspection", effect.identity);
    try std.testing.expectEqual(
        @as(usize, 2),
        result.program.schemas[@intCast(effect.payload)].product.len,
    );
}

test "edge from a parity worker back to full inspection prevents capture loss" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    var program = try parityFixture(storage, 2);
    const functions = try storage.alloc(ir.Function, 3);
    @memcpy(functions[0..2], program.functions);
    functions[2] = .{
        .entry = 6,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 0, 0 } },
        .result = 0,
    };
    program.functions = functions;
    const blocks = try storage.alloc(ir.Block, 8);
    @memcpy(blocks[0..6], program.blocks);
    blocks[5].terminator = .{ .call = .{
        .function = 2,
        .arguments = &.{ 0, 1 },
        .next = .{ .block = 7, .assignments = &.{.{ .destination = 6, .source = .returned }} },
    } };
    blocks[6] = .{
        .function = 2,
        .instructions = &.{.{
            .destination = 2,
            .opcode = .integer_bit_or,
            .operands = &.{ 0, 1 },
        }},
        .terminator = .{ .return_value = 2 },
    };
    blocks[7] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 6 } };
    program.blocks = blocks;
    var plan = (try affine.analyze(a, program, 0, 1000000)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.basis.len);
    var stats: @import("affine_state.zig").Statistics = .{};
    var result = try @import("affine_state.zig").run(a, program, 0, &stats, 1000000, .{});
    defer result.deinit();
    try std.testing.expectEqual(.no_change, stats.outcome);
}

test "unseen admitted affine matrices use record semantics rather than fixture names" {
    var random: u64 = 0x3183_25_2026;
    for (0..24) |_| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const storage = arena.allocator();
        var program = try parityFixture(storage, 3);
        const functions = try storage.dupe(ir.Function, program.functions);
        const blocks = try storage.dupe(ir.Block, program.blocks);
        var layout: std.ArrayList(u64) = .empty;
        try layout.appendSlice(storage, functions[1].layout.slots);
        var operations: std.ArrayList(ir.Instruction) = .empty;
        const arguments = try storage.dupe(u64, blocks[3].terminator.call.arguments);
        const literal = @import("program.zig").Literal;
        program.constants = try storage.dupe(
            literal,
            &.{
                program.constants[0],
                .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
                .{ .schema = 0, .bytes = &.{ 0x37, 0, 0, 0, 0, 0, 0, 0 } },
            },
        );
        // Equal row parity preserves the all-ones unobservable direction of
        // the two-dimensional even-parity observation space. Rows are not
        // restricted to permutations: some combine all original coordinates.
        for (0..3) |row| {
            random = random *% 6364136223846793005 +% 1442695040888963407;
            const mask = ([_]u8{ 1, 2, 4, 7 })[@intCast(random >> 62)];
            var value: ?u64 = null;
            for (0..3) |column| if (mask & (@as(u8, 1) << @intCast(column)) != 0) {
                if (value) |previous| {
                    const slot = layout.items.len;
                    try layout.append(storage, 0);
                    try operations.append(
                        storage,
                        .{
                            .destination = slot,
                            .opcode = .integer_bit_xor,
                            .operands = try storage.dupe(u64, &.{ previous, column }),
                        },
                    );
                    value = slot;
                } else value = column;
            };
            if (random & 1 != 0) {
                const slot = layout.items.len;
                try layout.append(storage, 0);
                try operations.append(
                    storage,
                    .{
                        .destination = slot,
                        .opcode = .integer_bit_xor,
                        .operands = try storage.dupe(u64, &.{ value.?, 3 }),
                    },
                );
                value = slot;
            }
            if (random & 2 != 0) {
                const constant_slot = layout.items.len;
                try layout.append(storage, 0);
                try operations.append(
                    storage,
                    .{ .destination = constant_slot, .opcode = .constant, .immediate = 2 },
                );
                const slot = layout.items.len;
                try layout.append(storage, 0);
                try operations.append(
                    storage,
                    .{
                        .destination = slot,
                        .opcode = .integer_bit_xor,
                        .operands = try storage.dupe(u64, &.{ value.?, constant_slot }),
                    },
                );
                value = slot;
            }
            arguments[row] = value.?;
        }
        try operations.append(storage, .{ .destination = 6, .opcode = .constant, .immediate = 0 });
        blocks[3].instructions = operations.items;
        blocks[3].terminator.call.arguments = arguments;
        blocks[5].instructions = &.{.{
            .destination = 5,
            .opcode = .integer_bit_xor,
            .operands = &.{ 0, 1 },
        }};
        blocks[5].terminator = .{ .return_value = 5 };
        functions[1].layout.slots = layout.items;
        program.functions = functions;
        program.blocks = blocks;
        var stats: @import("affine_state.zig").Statistics = .{};
        var result = try @import("affine_state.zig").run(a, program, 0, &stats, 1000000, .{});
        defer result.deinit();
        try std.testing.expectEqual(.applied, stats.outcome);
        try std.testing.expect(stats.reduced_words <= 2);
    }
}

test "distinct canonical and observation bases both validate with actual emitted costs" {
    const emit = @import("affine_emit.zig");
    const check = @import("affine_validate.zig");
    var observation = (try emit.constructBasis(a, rotating, 0, 1000000, .observations)).?;
    defer observation.deinit();
    var canonical = (try emit.constructBasis(a, rotating, 0, 1000000, .canonical)).?;
    defer canonical.deinit();
    try std.testing.expect(!std.mem.eql(u128, observation.basis, canonical.basis));
    try check.validate(
        a,
        rotating,
        observation.program,
        0,
        observation.basis,
        observation.input_bias,
        1000000,
    );
    try check.validate(
        a,
        rotating,
        canonical.program,
        0,
        canonical.basis,
        canonical.input_bias,
        1000000,
    );
    var stats: @import("affine_state.zig").Statistics = .{};
    var result = try @import("affine_state.zig").run(a, rotating, 0, &stats, 1000000, .{});
    defer result.deinit();
    try std.testing.expect(stats.observation_cost != null and stats.canonical_cost != null);
    try std.testing.expectEqual(.observations, stats.selected_basis);
    try std.testing.expect(
        stats.observation_cost.?.worker_instructions < stats.canonical_cost.?.worker_instructions,
    );
}

test "checked affine output survives decoded input and source buffer release" {
    const image = @import("program_image.zig");
    var result = blk: {
        const bytes = try a.alloc(u8, try image.encodedLength(rotating));
        defer a.free(bytes);
        _ = try image.encode(a, rotating, bytes);
        var decoded = try image.decode(a, bytes);
        defer decoded.deinit();
        const transformed = try @import("affine_state.zig").run(
            a,
            decoded.program,
            0,
            null,
            1000000,
            .{},
        );
        @memset(bytes, 0xff);
        break :blk transformed;
    };
    defer result.deinit();
    const encoded = try a.alloc(u8, try image.encodedLength(result.program));
    defer a.free(encoded);
    _ = try image.encode(a, result.program, encoded);
    var decoded_result = try image.decode(a, encoded);
    defer decoded_result.deinit();
    try std.testing.expectEqual(try image.identity(a, result.program), decoded_result.identity);
}

pub fn directFixture(storage: std.mem.Allocator) !ir.Program {
    return directParameters(storage, rotating);
}
fn directParameters(storage: std.mem.Allocator, original: ir.Program) !ir.Program {
    var program = original;
    const blocks = try storage.dupe(ir.Block, program.blocks);
    blocks[0].instructions = &.{};
    blocks[0].terminator = .{ .call = .{
        .function = 1,
        .arguments = program.functions[0].inputs,
        .next = program.blocks[0].terminator.apply.next,
    } };
    program.blocks = blocks;
    program.constructors = &.{};
    return program;
}

test "direct recursive parameter state uses the checked affine pipeline without constructors" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const program = try directFixture(arena.allocator());
    const pass = @import("affine_state.zig");
    const target = pass.directTarget(program, 1).?;
    var stats: pass.Statistics = .{};
    var output = try pass.runTarget(a, program, target, &stats, 1000000, .{});
    defer output.deinit();
    try std.testing.expectEqual(.applied, stats.outcome);
    try std.testing.expectEqual(@as(usize, 3), stats.original_words);
    try std.testing.expectEqual(@as(usize, 2), stats.reduced_words);
    try std.testing.expectEqual(@as(usize, 0), output.program.constructors.len);
    const entry = output.program.functions[@intCast(output.program.roots.entry)];
    try std.testing.expectEqual(@as(usize, 5), entry.inputs.len);
    var semantic = try @import("closed_compilation.zig").run(
        a,
        program,
        .{ .contract = .semantic },
    );
    defer semantic.deinit();
    try std.testing.expectEqual(@as(usize, 0), semantic.program.constructors.len);
    // This small direct-call fixture is sound to reduce but uneconomical under
    // the default objective. The larger parity witness below must be selected.
    var baseline = try @import("coalescing.zig").run(a, program, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, semantic.program),
    );
}

test "direct parameter acceptance rejects admissible wrong incoming argument" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const program = try directFixture(arena.allocator());
    const pass = @import("affine_state.zig");
    const target = pass.directTarget(program, 1).?;
    var candidate = (try @import("affine_emit.zig").constructTarget(
        a,
        program,
        target,
        1000000,
        .observations,
    )).?;
    defer candidate.deinit();
    try pass.validateTarget(
        a,
        program,
        candidate.program,
        target,
        candidate.basis,
        candidate.input_bias,
        1000000,
    );
    const blocks = try arena.allocator().dupe(ir.Block, candidate.program.blocks);
    const arguments = try arena.allocator().dupe(u64, blocks[0].terminator.call.arguments);
    arguments[0] = 0;
    blocks[0].terminator.call.arguments = arguments;
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        pass.validateTarget(
            a,
            program,
            wrong,
            target,
            candidate.basis,
            candidate.input_bias,
            1000000,
        ),
    );
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        pass.validateTarget(
            a,
            program,
            candidate.program,
            .{ .parameters = .{ .worker = 0, .count = 4 } },
            candidate.basis,
            candidate.input_bias,
            1000000,
        ),
    );
    try std.testing.expect(pass.directTarget(rotating, 1) == null);
    try std.testing.expect(pass.directTarget(program, 0) == null);
}

fn directAllocationAttempt(allocator: std.mem.Allocator, program: ir.Program) !void {
    const pass = @import("affine_state.zig");
    var output = try pass.runTarget(
        allocator,
        program,
        pass.directTarget(program, 1).?,
        null,
        1000000,
        .{},
    );
    defer output.deinit();
}

test "direct parameter synthesis owns every partial allocation and rolls back work exhaustion" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const program = try directFixture(arena.allocator());
    try @import("allocation_testing.zig").check(a, directAllocationAttempt, .{program});
    const pass = @import("affine_state.zig");
    var stats: pass.Statistics = .{};
    var limited = try pass.runTarget(a, program, pass.directTarget(program, 1).?, &stats, 0, .{});
    defer limited.deinit();
    var baseline = try @import("coalescing.zig").run(a, program, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(.work_limit, stats.outcome);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
}

test "shared compiler selects profitable direct parity state and retains small no-ops" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]usize{ 2, 3, 8, 32 }) |n| {
        const program = try directParameters(
            arena.allocator(),
            try parityFixture(arena.allocator(), n),
        );
        var stats: @import("closed_compilation.zig").Statistics = .{};
        var output = try @import("closed_compilation.zig").run(
            a,
            program,
            .{ .contract = .semantic, .statistics = &stats },
        );
        defer output.deinit();
        const entry = output.program.functions[@intCast(output.program.roots.entry)].entry;
        if (n >= 8) {
            try std.testing.expectEqual(
                @as(usize, 3),
                output.program.blocks[@intCast(entry)].terminator.call.arguments.len,
            );
            try std.testing.expectEqual(.full, stats.selected_candidate);
            try std.testing.expect(stats.final_bytes < stats.baseline_bytes);
            const pass = @import("affine_state.zig");
            var candidate = (try @import("affine_emit.zig").constructTarget(
                a,
                program,
                pass.directTarget(program, 1).?,
                1000000,
                .observations,
            )).?;
            defer candidate.deinit();
            try std.testing.expectEqual(
                program.functions[0].layout.slots.len + 1,
                candidate.program.functions[0].layout.slots.len,
            );
        } else {
            try std.testing.expectEqual(.baseline, stats.selected_candidate);
            try std.testing.expectEqual(stats.baseline_bytes, stats.final_bytes);
        }
    }
}

test "direct state dimension bound excludes a forwarded dynamic word" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const program = try directParameters(
        arena.allocator(),
        try parityFixture(arena.allocator(), 128),
    );
    const pass = @import("affine_state.zig");
    const target = pass.directTarget(program, 1).?;
    try std.testing.expectEqual(@as(usize, 128), target.parameters.count);
    var stats: pass.Statistics = .{};
    var output = try pass.runTarget(a, program, target, &stats, 1000000, .{});
    defer output.deinit();
    try std.testing.expectEqual(.applied, stats.outcome);
    try std.testing.expectEqual(@as(usize, 1), stats.reduced_words);
}

test "additional opaque observation expands the actual record state space" {
    var original_plan = (try affine.analyze(a, rotating, 0, 1000000)).?;
    defer original_plan.deinit();
    var program = rotating;
    var blocks = rotating.blocks[0..6].*;
    // Retain the parity observation and add an independent field observation
    // at a nonlinear boundary; every recursive update remains identical.
    blocks[5].instructions = &.{
        rotating.blocks[5].instructions[0],
        .{ .destination = 5, .opcode = .integer_bit_or, .operands = &.{ 5, 0 } },
    };
    program.blocks = &blocks;
    var expanded = (try affine.analyze(a, program, 0, 1000000)).?;
    defer expanded.deinit();
    try std.testing.expectEqualDeep(original_plan.transitions, expanded.transitions);
    try std.testing.expectEqual(@as(usize, 3), expanded.basis.len);
    const space = @import("affine_space.zig");
    var closure = try space.Space.init(3);
    var budget: space.Budget = .{ .remaining = 1000000 };
    for (expanded.basis) |row| _ = try closure.insert(row, &budget);
    for (original_plan.basis) |row| try std.testing.expect((try closure.coefficients(
        row,
        &budget,
    )) != null);
    var stats: @import("affine_state.zig").Statistics = .{};
    var retained = try @import("affine_state.zig").run(a, program, 0, &stats, 1000000, .{});
    defer retained.deinit();
    try std.testing.expectEqual(.no_change, stats.outcome);
}

test "independent acceptance rejects an admissible wrong affine offset" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    var original = rotating;
    original.constants = &.{
        rotating.constants[0],
        .{ .schema = 0, .bytes = &.{ 0xa5, 0, 0, 0, 0, 0, 0, 0 } },
    };
    const functions = try storage.dupe(ir.Function, original.functions);
    functions[1].layout.slots = &.{ 0, 0, 0, 0, 2, 0, 2, 0, 0 };
    original.functions = functions;
    var blocks = rotating.blocks[0..6].*;
    blocks[3].instructions = &.{
        rotating.blocks[3].instructions[0],
        .{ .destination = 8, .opcode = .constant, .immediate = 1 },
        .{ .destination = 5, .opcode = .integer_bit_xor, .operands = &.{ 5, 8 } },
        rotating.blocks[3].instructions[1],
    };
    original.blocks = &blocks;
    var candidate = (try @import("affine_emit.zig").construct(a, original, 0, 1000000)).?;
    defer candidate.deinit();
    const check = @import("affine_validate.zig");
    try check.validate(
        a,
        original,
        candidate.program,
        0,
        candidate.basis,
        candidate.input_bias,
        1000000,
    );
    try std.testing.expect(candidate.program.constants.len > original.constants.len);
    const constants = try storage.dupe(@import("program.zig").Literal, candidate.program.constants);
    const index = original.constants.len;
    const bytes = try storage.dupe(u8, constants[index].bytes);
    bytes[0] ^= 1;
    constants[index].bytes = bytes;
    var wrong = candidate.program;
    wrong.constants = constants;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        check.validate(a, original, wrong, 0, candidate.basis, candidate.input_bias, 1000000),
    );
}

test "independent acceptance rejects an admissible wrong successor worker" {
    var original = rotating;
    original.functions = &.{
        rotating.functions[0], rotating.functions[1],
        .{
            .entry = 6,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 0, 2 } },
            .result = 0,
        },
    };
    var blocks: [7]ir.Block = undefined;
    @memcpy(blocks[0..6], rotating.blocks);
    blocks[6] = .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
    original.blocks = &blocks;
    var candidate = (try @import("affine_emit.zig").construct(a, original, 0, 1000000)).?;
    defer candidate.deinit();
    const check = @import("affine_validate.zig");
    try check.validate(
        a,
        original,
        candidate.program,
        0,
        candidate.basis,
        candidate.input_bias,
        1000000,
    );
    const changed = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(changed);
    changed[3].terminator.call.function = 2;
    var wrong = candidate.program;
    wrong.blocks = changed;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        check.validate(a, original, wrong, 0, candidate.basis, candidate.input_bias, 1000000),
    );
}

test "full product inspection of the rotating state preserves all three words" {
    var program = rotating;
    var schemas = [_]@import("program.zig").Schema{
        rotating.schemas[0],
        rotating.schemas[1],
        rotating.schemas[2],
        rotating.schemas[3],
        .{ .product = &.{ 0, 0, 0 } },
    };
    schemas[3].internal.computation.result = 4;
    program.schemas = &schemas;
    program.roots.result = 4;
    var functions = rotating.functions[0..2].*;
    functions[0].result = 4;
    functions[0].layout.slots = &.{ 0, 0, 0, 0, 2, 3, 4 };
    functions[1].result = 4;
    functions[1].layout.slots = &.{ 0, 0, 0, 0, 2, 0, 2, 4, 4 };
    program.functions = &functions;
    var blocks = rotating.blocks[0..6].*;
    blocks[5].instructions = &.{.{
        .destination = 8,
        .opcode = .product,
        .operands = &.{ 0, 1, 2 },
    }};
    blocks[5].terminator = .{ .return_value = 8 };
    program.blocks = &blocks;
    var plan = (try affine.analyze(a, program, 0, 1000000)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.observations.len);
    try std.testing.expectEqual(@as(usize, 3), plan.basis.len);
    var stats: @import("affine_state.zig").Statistics = .{};
    var retained = try @import("affine_state.zig").run(a, program, 0, &stats, 1000000, .{});
    defer retained.deinit();
    var baseline = try @import("coalescing.zig").run(a, program, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(.no_change, stats.outcome);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, retained.program),
    );
}

test "original capture admission precedes every affine target decision" {
    var original = rotating;
    var blocks = rotating.blocks[0..6].*;
    blocks[0].instructions = &.{.{
        .destination = 5,
        .opcode = .computation,
        .operands = &.{ 0, 1 },
        .immediate = 0,
    }};
    original.blocks = &blocks;
    if (@import("activation_ownership.zig").analyze(a, original)) |value| {
        var accepted = value;
        accepted.deinit();
        return error.ExpectedOriginalRejection;
    } else |original_error| {
        try std.testing.expectError(
            original_error,
            @import("affine_state.zig").run(a, original, 0, null, 1000000, .{}),
        );
        try std.testing.expectError(
            original_error,
            @import("affine_state.zig").run(a, original, std.math.maxInt(usize), null, 0, .{}),
        );
        try std.testing.expectError(
            original_error,
            @import("affine_state.zig").runTarget(
                a,
                original,
                .{ .parameters = .{ .worker = 0, .count = 0 } },
                null,
                0,
                .{},
            ),
        );
    }
}

test "a valid opaque computation consumer keeps its original capture interface" {
    var original = rotating;
    original.functions = &.{
        rotating.functions[0], rotating.functions[1],
        .{
            .entry = 6,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 3, 0, 2, 0 } },
            .result = 0,
        },
    };
    var blocks: [8]ir.Block = undefined;
    @memcpy(blocks[0..6], rotating.blocks);
    blocks[0].terminator = .{ .call = .{
        .function = 2,
        .arguments = &.{ 5, 3, 4 },
        .next = rotating.blocks[0].terminator.apply.next,
    } };
    blocks[6] = .{
        .function = 2,
        .instructions = &.{},
        .terminator = .{ .apply = .{
            .computation = 0,
            .arguments = &.{ 1, 2 },
            .next = .{ .block = 7, .assignments = &.{.{ .destination = 3, .source = .returned }} },
        } },
    };
    blocks[7] = .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 3 } };
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var plan = try affine.analyze(a, original, 0, 1000000);
    defer if (plan) |*value| value.deinit();
    try std.testing.expect(plan == null);
    var stats: @import("affine_state.zig").Statistics = .{};
    var retained = try @import("affine_state.zig").run(a, original, 0, &stats, 1000000, .{});
    defer retained.deinit();
    var baseline = try @import("coalescing.zig").run(a, original, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(.no_change, stats.outcome);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, retained.program),
    );
}

test "a future reset prevents a one-coordinate parity rewrite" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var original = try parityFixture(arena.allocator(), 2);
    original.constants = &.{
        rotating.constants[0],
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    };
    const blocks = try arena.allocator().dupe(ir.Block, original.blocks);
    blocks[3].instructions = &.{
        .{ .destination = 4, .opcode = .constant, .immediate = 1 },
        .{ .destination = 5, .opcode = .constant, .immediate = 0 },
    };
    blocks[3].terminator.call.arguments = &.{ 4, 1, 2, 5 };
    original.blocks = blocks;
    var plan = (try affine.analyze(a, original, 0, 1000000)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.basis.len);
    var stats: @import("affine_state.zig").Statistics = .{};
    var retained = try @import("affine_state.zig").run(a, original, 0, &stats, 1000000, .{});
    defer retained.deinit();
    try std.testing.expectEqual(.no_change, stats.outcome);
}

test "adding a third legal update mode invalidates a two-mode summary" {
    const original = comptime twoModes();
    var previous = (try @import("affine_emit.zig").construct(a, original, 0, 1000000)).?;
    defer previous.deinit();
    var expanded = original;
    expanded.constants = &.{
        original.constants[0],                                    original.constants[1],
        .{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } },
    };
    var blocks: [10]ir.Block = undefined;
    @memcpy(blocks[0..8], original.blocks);
    // u=0 retains rotation; other nonzero inputs retain swap; u=42 adds reset.
    blocks[2].terminator.branch.when_true.block = 8;
    blocks[8] = .{
        .function = 1,
        .instructions = &.{
            .{ .destination = 5, .opcode = .constant, .immediate = 2 },
            .{ .destination = 6, .opcode = .equal, .operands = &.{ 3, 5 } },
        },
        .terminator = .{ .branch = .{
            .condition = 6,
            .when_true = .{ .block = 9 },
            .when_false = .{ .block = 3 },
        } },
    };
    blocks[9] = .{
        .function = 1,
        .instructions = &.{
            .{ .destination = 5, .opcode = .constant, .immediate = 1 },
            .{ .destination = 6, .opcode = .constant, .immediate = 0 },
        },
        .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{ 5, 1, 2, 3, 6 },
            .next = original.blocks[7].terminator.call.next,
        } },
    };
    expanded.blocks = &blocks;
    var plan = (try affine.analyze(a, expanded, 0, 1000000)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.transitions.len);
    try std.testing.expectEqual(@as(usize, 3), plan.basis.len);
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        @import("affine_validate.zig").validate(
            a,
            expanded,
            previous.program,
            0,
            previous.basis,
            previous.input_bias,
            1000000,
        ),
    );
    var stats: @import("affine_state.zig").Statistics = .{};
    var retained = try @import("affine_state.zig").run(a, expanded, 0, &stats, 1000000, .{});
    defer retained.deinit();
    try std.testing.expectEqual(.no_change, stats.outcome);
}
