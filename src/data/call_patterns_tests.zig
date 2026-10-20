const std = @import("std");
const ir = @import("activation.zig");
const patterns = @import("call_patterns.zig");
const a = std.testing.allocator;
const profile = @import("optimization_profile.zig");

test "an exact immutable profile prioritizes a proved hot constructor within one variant" {
    var counts = @as([repeated.blocks.len]u64, @splat(0));
    counts[4] = 100;
    const record: profile.Record = .{
        .image_identity = try @import("program_image.zig").identity(a, repeated),
        .block_counts = &counts,
        .total = 100,
    };
    var candidate = (try patterns.construct(
        a,
        repeated,
        .{ .profile = record, .max_variants = 1 },
    )).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        repeated,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    try std.testing.expectEqual(@as(u64, 1), candidate.variants[0].key.value.constructor);
    // Unobserved, reachable alternatives remain generic, not unreachable.
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[1].terminator.call.function);
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[3].terminator.call.function);
    var again = (try patterns.construct(a, repeated, .{ .profile = record, .max_variants = 1 })).?;
    defer again.deinit();
    try std.testing.expect(@import("record_equal.zig").equal(
        ir.Program,
        candidate.program,
        again.program,
    ));
}

test "a hot polymorphic call does not acquire a constructor proof from its profile" {
    var blocks: [repeated.blocks.len + 1]ir.Block = undefined;
    @memcpy(blocks[0..repeated.blocks.len], repeated.blocks);
    blocks[repeated.blocks.len] = .{
        .function = 0,
        .instructions = &.{},
        .terminator = repeated.blocks[1].terminator,
    };
    blocks[1].terminator = .{ .jump = .{ .block = repeated.blocks.len } };
    blocks[4].terminator = .{ .jump = .{ .block = repeated.blocks.len } };
    var original = repeated;
    original.blocks = &blocks;
    var counts = @as([blocks.len]u64, @splat(0));
    counts[repeated.blocks.len] = 1000000;
    const record: profile.Record = .{
        .image_identity = try @import("program_image.zig").identity(a, original),
        .block_counts = &counts,
        .total = 1000000,
    };
    var candidate = (try patterns.construct(
        a,
        original,
        .{ .profile = record, .max_variants = 1 },
    )).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        candidate.program.blocks[repeated.blocks.len].terminator.call.function,
    );
    for (candidate.sites) |site| try std.testing.expect(site.block != repeated.blocks.len);
}

test "profile identity toolchain locations and overflowing counters reject" {
    var counts = @as([repeated.blocks.len]u64, @splat(0));
    var record: profile.Record = .{
        .image_identity = try @import("program_image.zig").identity(a, repeated),
        .block_counts = &counts,
        .total = 0,
    };
    try profile.validate(a, repeated, record);
    record.image_identity[0] ^= 1;
    try std.testing.expectError(
        error.InvalidOptimizationProfile,
        patterns.construct(a, repeated, .{ .profile = record }),
    );
    try std.testing.expectError(
        error.InvalidOptimizationProfile,
        patterns.construct(a, repeated, .{ .profile = record, .work_limit = 0 }),
    );
    record.image_identity[0] ^= 1;
    record.toolchain_identity = "another compiler";
    try std.testing.expectError(
        error.InvalidOptimizationProfile,
        profile.validate(a, repeated, record),
    );
    record.toolchain_identity = profile.toolchain;
    record.block_counts = counts[0 .. counts.len - 1];
    try std.testing.expectError(
        error.InvalidOptimizationProfile,
        profile.validate(a, repeated, record),
    );
    record.block_counts = &counts;
    counts[0] = std.math.maxInt(u64);
    counts[1] = 1;
    try std.testing.expectError(
        error.InvalidOptimizationProfile,
        profile.validate(a, repeated, record),
    );
}

test "local profile collection snapshots and canonical bytes preserve checked counts" {
    var collector = try profile.Collector.init(a, repeated);
    defer collector.deinit();
    try collector.observe(4);
    var snapshot = try collector.snapshot(a);
    defer snapshot.deinit();
    try collector.observe(1);
    try std.testing.expectEqual(@as(u64, 1), snapshot.record.total);
    try std.testing.expectEqual(@as(u64, 0), snapshot.record.block_counts[1]);
    const bytes = try a.alloc(u8, try profile.encodedLength(snapshot.record));
    defer a.free(bytes);
    _ = try profile.encode(snapshot.record, bytes);
    var decoded = try profile.decode(a, repeated, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(
        u64,
        snapshot.record.block_counts,
        decoded.record.block_counts,
    );
    for (0..bytes.len) |length| {
        const result = profile.decode(a, repeated, bytes[0..length]);
        if (result) |value| {
            var owner = value;
            owner.deinit();
            return error.AcceptedTruncatedProfile;
        } else |_| {}
    }
    collector.total = std.math.maxInt(u64);
    const before = collector.counts[4];
    try std.testing.expectError(error.InvalidOptimizationProfile, collector.observe(4));
    try std.testing.expectEqual(before, collector.counts[4]);
    try std.testing.expectError(
        error.InvalidOptimizationProfile,
        collector.observe(collector.counts.len),
    );
}
pub const repeated: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{
        .u64, .boolean, .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 1, 1, 3, 0 } },
            .result = 0,
        },
        .{
            .entry = 6,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 3, 0, 0, 0, 0, 0 } },
            .result = 0,
        },
        .{ .entry = 9, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 10, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 1 },
                .when_false = .{ .block = 2 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 4, .opcode = .computation, .immediate = 0 }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 4, 0, 1 },
                .next = .{
                    .block = 5,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 3,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 4, .opcode = .computation, .immediate = 0 }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 4, 0, 1 },
                .next = .{
                    .block = 5,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 4, .opcode = .computation, .immediate = 1 }},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 4, 0, 1 },
                .next = .{
                    .block = 5,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 5 } },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 0,
                .arguments = &.{1},
                .next = .{
                    .block = 7,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 0,
                .arguments = &.{2},
                .next = .{
                    .block = 8,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 5,
                .opcode = .integer_bit_or,
                .operands = &.{ 3, 4 },
            }},
            .terminator = .{ .return_value = 5 },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{
            .function = 3,
            .instructions = &.{.{
                .destination = 1,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 1 },
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{
        .{ .function = 2, .capture = 0, .schema = 3 },
        .{ .function = 3, .capture = 0, .schema = 3 },
    },
};
test "call patterns create two direct workers and share repeated static keys" {
    var candidate = (try patterns.construct(a, repeated, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        repeated,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 2), candidate.variants.len);
    try std.testing.expectEqual(@as(usize, 3), candidate.sites.len);
    try std.testing.expectEqual(
        candidate.program.blocks[1].terminator.call.function,
        candidate.program.blocks[3].terminator.call.function,
    );
    try std.testing.expect(
        candidate.program.blocks[1].terminator.call.function !=
            candidate.program.blocks[4].terminator.call.function,
    );
    for (candidate.variants) |variant| {
        try std.testing.expectEqual(
            @as(usize, 2),
            candidate.program.functions[@intCast(variant.function)].inputs.len,
        );
        try std.testing.expect(candidate.program.blocks[variant.first_block].terminator == .call);
        try std.testing.expect(
            candidate.program.blocks[variant.first_block + 1].terminator == .call,
        );
    }
    var stats: patterns.Statistics = .{};
    var result = try patterns.run(a, repeated, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), stats.direct_applications);
    try std.testing.expectEqual(@as(usize, 3), stats.rewritten_calls);
}
test "call-pattern checker rejects a well-typed wrong target and stale epoch" {
    var candidate = (try patterns.construct(a, repeated, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[candidate.variants[0].first_block].terminator.call.function = 3;
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, repeated, wrong, candidate.variants, candidate.sites, 1000000),
    );
    const variants = try a.dupe(patterns.Variant, candidate.variants);
    defer a.free(variants);
    variants[0].key.epoch[0] ^= 1;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, repeated, candidate.program, variants, candidate.sites, 1000000),
    );
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try patterns.run(allocator, repeated, null, .{});
    defer result.deinit();
}
test "call-pattern allocation and code-growth exhaustion retain P01 baseline" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, repeated, .{});
    defer baseline.deinit();
    for ([_]patterns.Options{
        .{ .max_variants = 1 },
        .{ .max_added_blocks = 1 },
        .{ .max_added_bytes = 0 },
        .{ .work_limit = 0 },
    }) |options| {
        var stats: patterns.Statistics = .{};
        var result = try patterns.run(a, repeated, &stats, options);
        defer result.deinit();
        try std.testing.expect(stats.work_limit);
        try std.testing.expectEqual(
            try @import("program_image.zig").identity(a, baseline.program),
            try @import("program_image.zig").identity(a, result.program),
        );
    }
}

test "unknown callable join retains the generic fallback beside a known variant" {
    var original = repeated;
    var blocks: [12]ir.Block = undefined;
    @memcpy(blocks[0..11], repeated.blocks);
    blocks[1].terminator = .{ .jump = .{ .block = 11 } };
    blocks[4].terminator = .{ .jump = .{ .block = 11 } };
    blocks[11] = .{
        .function = 0,
        .instructions = &.{},
        .terminator = repeated.blocks[1].terminator,
    };
    original.blocks = &blocks;
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    try std.testing.expectEqual(@as(usize, 1), candidate.sites.len);
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[11].terminator.call.function);
    var stats: patterns.Statistics = .{};
    var result = try patterns.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.generic_fallback_calls);
}
test "recursive generic workers fold finitely without unfolding their runtime recursion" {
    try std.testing.expect(patterns.possible(repeated));
    var original = repeated;
    var blocks = repeated.blocks[0..11].*;
    blocks[6].terminator = .{ .call = .{
        .function = 1,
        .arguments = &.{ 0, 1, 2 },
        .next = repeated.blocks[6].terminator.apply.next,
    } };
    original.blocks = &blocks;
    try std.testing.expect(patterns.possible(original));
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        10_000_000,
    );
    try std.testing.expectEqual(@as(usize, 2), candidate.variants.len);
    try std.testing.expectEqual(original.functions.len + 2, candidate.program.functions.len);
    for (candidate.variants) |variant| {
        const call = candidate.program.blocks[variant.first_block].terminator.call;
        try std.testing.expectEqual(variant.function, call.function);
        try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, call.arguments);
    }
}
test "call-pattern validation retains argument order and public interface authority" {
    var candidate = (try patterns.construct(a, repeated, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    blocks[1].terminator.call.arguments = &.{ 1, 0 };
    var wrong = candidate.program;
    wrong.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, wrong);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, repeated, wrong, candidate.variants, candidate.sites, 1000000),
    );
    const variants = try a.dupe(patterns.Variant, candidate.variants);
    defer a.free(variants);
    variants[0].key.function = 0;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, repeated, candidate.program, variants, candidate.sites, 1000000),
    );
}
test "shared pipeline selects checked repeated-callable specialization" {
    var stats: @import("closed_compilation.zig").Statistics = .{};
    var result = try @import("closed_compilation.zig").run(
        a,
        repeated,
        .{ .contract = .semantic, .statistics = &stats },
    );
    defer result.deinit();
    try std.testing.expectEqual(.full, stats.selected_candidate);
    const entry = result.program.blocks[
        @intCast(result.program.functions[
            @intCast(result.program.roots.entry)
        ].entry)
    ];
    const first = result.program.blocks[@intCast(entry.terminator.branch.when_true.block)];
    try std.testing.expectEqual(@as(usize, 2), first.terminator.call.arguments.len);
    // Final P01 uses the existing reference-closure projection. Once every
    // caller has a worker, the generic callable-taking implementation is dead.
    for (result.program.blocks) |block| try std.testing.expect(block.terminator != .apply);
    for (result.program.functions) |function| for (function.inputs) |slot| {
        const schema = result.program.schemas[@intCast(function.layout.slots[@intCast(slot)])];
        try std.testing.expect(schema != .internal or schema.internal != .computation);
    };
}

test "runtime captures remain outside static constructor keys" {
    var original = repeated;
    original.scopes.captures = &.{
        repeated.scopes.captures[0],
        .{ .fields = &.{0}, .use = .reusable },
    };
    original.constructors = &.{
        .{ .function = 2, .capture = 1, .schema = 3 },
        repeated.constructors[1],
    };
    var functions = repeated.functions[0..4].*;
    functions[2].inputs = &.{ 0, 1 };
    functions[2].layout.slots = &.{ 0, 0 };
    original.functions = &functions;
    var blocks = repeated.blocks[0..11].*;
    blocks[1].instructions = &.{.{
        .destination = 4,
        .opcode = .computation,
        .operands = &.{0},
        .immediate = 0,
    }};
    blocks[3].instructions = &.{.{
        .destination = 4,
        .opcode = .computation,
        .operands = &.{1},
        .immediate = 0,
    }};
    blocks[9].terminator.return_value = 1;
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try patterns.validate(
        a,
        original,
        candidate.program,
        candidate.variants,
        candidate.sites,
        1000000,
    );
    try std.testing.expectEqual(@as(usize, 2), candidate.variants.len);
    try std.testing.expectEqual(@as(u64, 0), candidate.variants[0].key.value.constructor);
    try std.testing.expectEqual(
        candidate.program.blocks[1].terminator.call.function,
        candidate.program.blocks[3].terminator.call.function,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{ 0, 1, 0 },
        candidate.program.blocks[1].terminator.call.arguments,
    );
    try std.testing.expectEqualSlices(
        u64,
        &.{ 0, 1, 1 },
        candidate.program.blocks[3].terminator.call.arguments,
    );
}
test "configuration changes cannot relabel an old specialization epoch" {
    var candidate = (try patterns.construct(a, repeated, .{})).?;
    defer candidate.deinit();
    var original = repeated;
    var blocks = repeated.blocks[0..11].*;
    blocks[8].instructions = &.{.{
        .destination = 5,
        .opcode = .integer_bit_and,
        .operands = &.{ 3, 4 },
    }};
    original.blocks = &blocks;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(
            a,
            original,
            candidate.program,
            candidate.variants,
            candidate.sites,
            1000000,
        ),
    );
    const variants = try a.dupe(patterns.Variant, candidate.variants);
    defer a.free(variants);
    const epoch = try @import("program_image.zig").identity(a, original);
    for (variants) |*variant| variant.key.epoch = epoch;
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, original, candidate.program, variants, candidate.sites, 1000000),
    );
}

test "original capture admission cannot be hidden by specialization limits" {
    var original = repeated;
    var blocks = repeated.blocks[0..11].*;
    blocks[1].instructions = &.{.{
        .destination = 4,
        .opcode = .computation,
        .operands = &.{0},
        .immediate = 0,
    }};
    original.blocks = &blocks;
    if (@import("activation_ownership.zig").analyze(a, original)) |value| {
        var admitted = value;
        admitted.deinit();
        return error.ExpectedOriginalRejection;
    } else |original_error| {
        try std.testing.expectError(
            original_error,
            patterns.construct(a, original, .{ .work_limit = 0, .max_variants = 0 }),
        );
        try std.testing.expectError(
            original_error,
            patterns.run(a, original, null, .{ .work_limit = 0, .max_variants = 0 }),
        );
    }
}

test "overwriting the callable parameter cannot reuse its incoming static binding" {
    var original = repeated;
    var blocks = repeated.blocks[0..11].*;
    blocks[6].instructions = &.{.{ .destination = 0, .opcode = .computation, .immediate = 1 }};
    original.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var candidate = try patterns.construct(a, original, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}

test "identical leaf code with a handler role is not interchangeable evidence" {
    var original = repeated;
    var functions = repeated.functions[0..4].*;
    functions[3].layout.slots = &.{0};
    original.functions = &functions;
    var blocks = repeated.blocks[0..11].*;
    blocks[10].instructions = &.{};
    blocks[10].terminator = .{ .return_value = 0 };
    original.blocks = &blocks;
    original.handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 3,
        .clauses = &.{},
    }};
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var candidate = (try patterns.construct(a, original, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 1), candidate.variants.len);
    try std.testing.expectEqual(@as(u64, 0), candidate.variants[0].key.value.constructor);
    try std.testing.expectEqual(@as(u64, 1), candidate.program.blocks[4].terminator.call.function);
    const changed = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(changed);
    changed[candidate.variants[0].first_block].terminator.call.function = 3;
    var wrong = candidate.program;
    wrong.blocks = changed;
    var valid_wrong = try @import("activation_ownership.zig").analyze(a, wrong);
    defer valid_wrong.deinit();
    try std.testing.expectError(
        error.InvalidCallPattern,
        patterns.validate(a, original, wrong, candidate.variants, candidate.sites, 1000000),
    );
}
