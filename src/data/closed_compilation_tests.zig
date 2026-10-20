// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const compile = @import("closed_compilation.zig");
const p01 = @import("coalescing.zig");
const image = @import("program_image.zig");
const captured = @import("application_specialization_tests.zig").captured;
const a = std.testing.allocator;

test "bounded equality search reports exhaustion without discarding its checked incumbent" {
    const ir = @import("activation.zig");
    const p = @import("program.zig");
    var inputs: [128]p.Id = undefined;
    for (&inputs, 0..) |*slot, id| slot.* = id;
    const slots = @as([130]p.Id, @splat(0));
    var instructions: [128]ir.Instruction = undefined;
    instructions[0] = .{ .destination = 129, .opcode = .constant };
    var operands: [127][2]p.Id = undefined;
    for (instructions[1..], 0..) |*op, id| {
        operands[id] = .{ if (id == 0) 0 else 128, id + 1 };
        op.* = .{ .destination = 128, .opcode = .integer_bit_xor, .operands = &operands[id] };
    }
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{.{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &inputs,
            .layout = .{ .slots = &slots },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &instructions,
            .terminator = .{ .return_value = 128 },
        }},
    };
    var stats: compile.Statistics = .{};
    var result = try compile.run(a, program, .{ .contract = .semantic, .statistics = &stats });
    defer result.deinit();
    try std.testing.expect(stats.search_exhaustions > 0);
    try std.testing.expectEqual(compile.Outcome.applied, stats.outcome);
    var baseline = try p01.run(a, program, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(@as(usize, 128), baseline.program.blocks[0].instructions.len);
    try std.testing.expectEqual(@as(usize, 127), result.program.blocks[0].instructions.len);
}

test "shared profile policy reaches independently checked loop and tail consumers" {
    const programs = [_]@import("activation.zig").Program{
        @import("loop_unswitch_tests.zig").selectable,
        @import("tail_duplication_tests.zig").split,
    };
    for (programs, 0..) |program, index| {
        const counts = try a.alloc(u64, program.blocks.len);
        defer a.free(counts);
        @memset(counts, 0);
        counts[if (index == 0) 1 else 2] = 100;
        const policy: compile.ProfilePolicy = .{
            .record = .{
                .image_identity = try image.identity(a, program),
                .block_counts = counts,
                .total = 100,
            },
            .target = if (index == 0) .loop_unswitch else .tail_duplication,
            .max_copies = 1,
        };
        var stats: compile.Statistics = .{};
        var result = try compile.run(
            a,
            program,
            .{ .contract = .semantic, .profile = policy, .statistics = &stats },
        );
        defer result.deinit();
        try std.testing.expect(stats.profile_used);
        try std.testing.expectEqual(@as(usize, 1), stats.profile_rewrites);
        try std.testing.expect(stats.outcome != .work_limit);
    }
}

test "shared profile budget is bound to original records and consumed only once" {
    const program = @import("call_patterns_tests.zig").repeated;
    const profiles = @import("optimization_profile.zig");
    var counts = @as([program.blocks.len]u64, @splat(0));
    counts[4] = 100;
    const record: profiles.Record = .{
        .image_identity = try image.identity(a, program),
        .block_counts = &counts,
        .total = 100,
    };
    var stats: compile.Statistics = .{};
    var p01_stats: p01.Statistics = .{};
    const policy: compile.ProfilePolicy = .{ .record = record, .max_variants = 1 };
    var result = try compile.run(
        a,
        program,
        .{
            .contract = .semantic,
            .profile = policy,
            .statistics = &stats,
            .coalescing = .{ .statistics = &p01_stats },
        },
    );
    defer result.deinit();
    try std.testing.expect(stats.profile_used);
    try std.testing.expectEqual(@as(usize, 1), stats.profile_variants);
    try std.testing.expect(stats.outcome != .work_limit);
    try std.testing.expect(p01_stats.outcome != .not_run);
    var repeated = try compile.run(a, program, .{ .contract = .semantic, .profile = policy });
    defer repeated.deinit();
    try std.testing.expectEqualSlices(
        u8,
        &try image.identity(a, result.program),
        &try image.identity(a, repeated.program),
    );
    var structural = try compile.run(a, program, .{ .profile = policy, .statistics = &stats });
    defer structural.deinit();
    try std.testing.expect(!stats.profile_used);
    try std.testing.expectEqual(compile.Outcome.structural, stats.outcome);
    var limited = try compile.run(
        a,
        program,
        .{ .contract = .semantic, .profile = policy, .statistics = &stats, .work_limit = 0 },
    );
    defer limited.deinit();
    try std.testing.expectEqual(compile.Outcome.work_limit, stats.outcome);
    try std.testing.expectEqualSlices(
        u8,
        &try image.identity(a, structural.program),
        &try image.identity(a, limited.program),
    );
    var stale = policy;
    stale.record.image_identity[0] ^= 1;
    try std.testing.expectError(
        error.InvalidOptimizationProfile,
        compile.run(a, program, .{ .contract = .semantic, .profile = stale, .work_limit = 0 }),
    );
}

test "both closed compilation contracts invoke P01 and only semantic rewrites apply" {
    var structural_stats: compile.Statistics = .{};
    var structural_p01: p01.Statistics = .{};
    var structural = try compile.run(
        a,
        captured,
        .{ .statistics = &structural_stats, .coalescing = .{ .statistics = &structural_p01 } },
    );
    defer structural.deinit();
    try std.testing.expectEqual(compile.Outcome.structural, structural_stats.outcome);
    try std.testing.expect(structural_p01.outcome != .not_run);
    var applies: usize = 0;
    for (structural.program.blocks) |block| {
        if (block.terminator == .apply) applies += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), applies);
    var stats: compile.Statistics = .{};
    var semantic_p01: p01.Statistics = .{};
    var semantic = try compile.run(
        a,
        captured,
        .{
            .contract = .semantic,
            .statistics = &stats,
            .coalescing = .{ .statistics = &semantic_p01 },
        },
    );
    defer semantic.deinit();
    try std.testing.expectEqual(compile.Outcome.applied, stats.outcome);
    try std.testing.expect(semantic_p01.outcome != .not_run);
    try std.testing.expect(stats.changed_stages > 0 and stats.rounds >= 2);
    for (semantic.program.blocks) |block| try std.testing.expect(block.terminator != .apply);
    std.debug.print(
        "closed semantic compilation: {d} -> {d} bytes, {d} rounds\n",
        .{ stats.baseline_bytes, stats.final_bytes, stats.rounds },
    );
}

test "zero budget and a late round limit return the exact structural baseline" {
    var baseline = try compile.run(a, captured, .{});
    defer baseline.deinit();
    const identity = try image.identity(a, baseline.program);
    for ([_]compile.Options{
        .{ .contract = .semantic, .work_limit = 0 },
        .{ .contract = .semantic, .round_limit = 1 },
    }) |selected| {
        var options = selected;
        var stats: compile.Statistics = .{};
        options.statistics = &stats;
        var result = try compile.run(a, captured, options);
        defer result.deinit();
        try std.testing.expectEqual(compile.Outcome.work_limit, stats.outcome);
        try std.testing.expectEqual(identity, try image.identity(a, result.program));
        if (selected.round_limit == 1) try std.testing.expect(stats.changed_stages > 0);
    }
    try std.testing.expectError(
        error.Capacity,
        compile.run(
            a,
            captured,
            .{ .contract = .semantic, .work_limit = 0, .max_image_bytes = 0 },
        ),
    );
}

test "size objective and explicit zero growth protect the original exact image size" {
    const projection = @import("capture_projection_tests.zig").reused;
    var baseline = try compile.run(a, projection, .{});
    defer baseline.deinit();
    for ([_]compile.Options{
        .{ .contract = .semantic, .objective = .size },
        .{ .contract = .semantic, .image_growth_bytes = 0 },
    }) |options| {
        var result = try compile.run(a, projection, options);
        defer result.deinit();
        try std.testing.expect(
            try image.encodedLength(result.program) <= try image.encodedLength(baseline.program),
        );
    }
}

test "incomplete value facts and exhausted backwards proofs never escape" {
    try std.testing.expectError(
        error.SemanticWorkLimit,
        @import("value_facts.zig").analyzeWithLimit(a, captured, 0),
    );
    var proof: @import("constant_origin.zig").Prover = .{
        .allocator = a,
        .program = captured,
        .work_limit = 1,
    };
    defer proof.deinit();
    try std.testing.expectEqual(
        @as(?@import("constant_origin.zig").Constant, null),
        try proof.resolve(0, 1, 2),
    );
    try std.testing.expect(proof.exhausted);
    var invalid = captured;
    invalid.constructors = &.{.{ .function = 99, .capture = 0, .schema = 2 }};
    try std.testing.expectError(
        error.InvalidReference,
        compile.run(a, invalid, .{ .contract = .semantic, .work_limit = 0 }),
    );
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try compile.run(allocator, captured, .{ .contract = .semantic });
    defer result.deinit();
}
test "closed compilation releases baseline and successor owners on every allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "observers do not change selected semantic bytes" {
    const Counter = struct {
        count: usize = 0,
        fn enter(pointer: *anyopaque, _: compile.Stage) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    var plain = try compile.run(a, captured, .{ .contract = .semantic });
    defer plain.deinit();
    var observed = try compile.run(
        a,
        captured,
        .{ .contract = .semantic, .observer = .{ .context = &counter, .enter = Counter.enter } },
    );
    defer observed.deinit();
    try std.testing.expect(counter.count > 0);
    try std.testing.expectEqual(
        try image.identity(a, plain.program),
        try image.identity(a, observed.program),
    );
}

test "work accounting uses logical records rather than compressed literal wire lengths" {
    const ir = @import("activation.zig");
    const p = @import("program.zig");
    var bytes: [128][8]u8 = undefined;
    var literals: [128]p.Literal = undefined;
    var instructions: [128]ir.Instruction = undefined;
    for (&bytes, &literals, &instructions, 0..) |*storage, *literal, *instruction, index| {
        std.mem.writeInt(u64, storage, index, .little);
        literal.* = .{ .schema = 0, .bytes = storage };
        instruction.* = .{ .destination = 0, .opcode = .constant, .immediate = index };
    }
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &literals,
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
    var stats: compile.Statistics = .{};
    var limited = try compile.run(
        a,
        program,
        .{ .contract = .semantic, .work_limit = 0, .statistics = &stats },
    );
    defer limited.deinit();
    try std.testing.expectEqual(compile.Outcome.work_limit, stats.outcome);
    var result = try compile.run(a, program, .{ .contract = .semantic, .statistics = &stats });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.program.blocks[0].instructions.len);
    try std.testing.expect(stats.selected_candidate == .shrinking);
}

test "inapplicable semantic passes are skipped without skipping mandatory P01" {
    const ir = @import("activation.zig");
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .effects = &.{},
        .constants = &.{.{ .schema = 0, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 } }},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{.{ .destination = 0, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .return_value = 0 },
        }},
    };
    var stats: compile.Statistics = .{};
    var structural: p01.Statistics = .{};
    var result = try compile.run(
        a,
        program,
        .{
            .contract = .semantic,
            .statistics = &stats,
            .coalescing = .{ .statistics = &structural },
        },
    );
    defer result.deinit();
    try std.testing.expectEqual(compile.Outcome.no_change, stats.outcome);
    try std.testing.expectEqual(@as(usize, 0), stats.stages_run);
    try std.testing.expect(stats.stages_skipped > 0);
    try std.testing.expect(structural.outcome != .not_run);
}

test "a proved no-op stage is not repeated on unchanged records" {
    const ir = @import("activation.zig");
    // All layout slots are ABI inputs, so packing cannot merge them.
    // The explicit dead transfer still makes dead-computation discovery run.
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .effects = &.{},
        .constants = &.{.{ .schema = 0, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 } }},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{ 0, 1, 2 },
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
    var stats: compile.Statistics = .{};
    var result = try compile.run(a, program, .{ .contract = .semantic, .statistics = &stats });
    defer result.deinit();
    try std.testing.expectEqual(compile.Outcome.no_change, stats.outcome);
    try std.testing.expectEqual(@as(usize, 1), stats.stages_run);
    try std.testing.expectEqual(@as(usize, 0), stats.changed_stages);
}

const shrinking_fixture: @import("activation.zig").Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .effects = &.{},
    .constants = &.{.{ .schema = 0, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 } }},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{},
        .layout = .{ .slots = &.{ 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 0, .opcode = .constant, .immediate = 0 },
        .{ .destination = 1, .opcode = .constant, .immediate = 0 },
    }, .terminator = .{ .return_value = 1 } }},
};
fn shrinkingAllocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try compile.run(allocator, shrinking_fixture, .{ .contract = .semantic });
    defer result.deinit();
}
test "independent shrinking candidate releases every partial owner and charges its work" {
    try @import("allocation_testing.zig").check(a, shrinkingAllocationAttempt, .{});
    var stats: compile.Statistics = .{};
    var limited = try compile.run(
        a,
        shrinking_fixture,
        .{ .contract = .semantic, .work_limit = 1, .statistics = &stats },
    );
    defer limited.deinit();
    var baseline = try compile.run(a, shrinking_fixture, .{});
    defer baseline.deinit();
    try std.testing.expectEqual(compile.Outcome.work_limit, stats.outcome);
    try std.testing.expectEqual(compile.Stage.dead_computation, stats.stopped_stage.?);
    try std.testing.expectEqual(
        try image.identity(a, baseline.program),
        try image.identity(a, limited.program),
    );
}

test "dead-computation round credit preserves whole-attempt rollback and admission" {
    const dead = @import("dead_computation.zig");
    var baseline = try p01.run(a, shrinking_fixture, .{});
    defer baseline.deinit();
    for ([_]usize{ 0, 1 }) |limit| {
        var stats: dead.Statistics = .{};
        var limited = try dead.run(a, shrinking_fixture, &stats, .{ .round_limit = limit });
        defer limited.deinit();
        try std.testing.expect(stats.work_limit);
        try std.testing.expectEqual(limit, stats.round_attempts);
        try std.testing.expectEqual(@as(usize, 0), stats.instructions_removed);
        try std.testing.expectEqual(
            try image.identity(a, baseline.program),
            try image.identity(a, limited.program),
        );
    }
    var stats: dead.Statistics = .{};
    var completed = try dead.run(a, shrinking_fixture, &stats, .{ .round_limit = 2 });
    defer completed.deinit();
    try std.testing.expect(!stats.work_limit);
    try std.testing.expectEqual(@as(usize, 2), stats.round_attempts);
    try std.testing.expectEqual(@as(usize, 1), stats.instructions_removed);
    var invalid = shrinking_fixture;
    invalid.roots.entry = 9;
    try std.testing.expectError(
        error.InvalidReference,
        dead.run(a, invalid, null, .{ .round_limit = 0 }),
    );
}
