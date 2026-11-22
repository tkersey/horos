// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const testing = std.testing;
const pass = @import("coalescing.zig");
const image = @import("program_image.zig");
const fixture = @import("coalescing_witness_tests.zig").original;

fn bytes(program: @import("activation.zig").Program) ![]u8 {
    const result = try testing.allocator.alloc(u8, try image.encodedLength(program));
    errdefer testing.allocator.free(result);
    _ = try image.encode(testing.allocator, program, result);
    return result;
}

test "coalescing selects exact economical candidate to an idempotent fixed point" {
    var stats: pass.Statistics = .{};
    var full = try pass.run(testing.allocator, fixture, .{ .statistics = &stats });
    defer full.deinit();
    try testing.expectEqual(pass.Outcome.applied, stats.outcome);
    try testing.expectEqual(@as(usize, 1), stats.extraction_rounds);
    try testing.expectEqual(@as(usize, 2), full.program.functions.len);
    try testing.expect(stats.selected.bytes < stats.baseline.bytes);
    var again_stats: pass.Statistics = .{};
    var again = try pass.run(testing.allocator, full.program, .{ .statistics = &again_stats });
    defer again.deinit();
    try testing.expectEqual(pass.Outcome.no_change, again_stats.outcome);
    try testing.expectEqual(@as(usize, 0), again_stats.validator_calls);
    try testing.expectEqual(@as(usize, 0), again_stats.candidate_admissions);
    const first_bytes = try bytes(full.program);
    defer testing.allocator.free(first_bytes);
    const second_bytes = try bytes(again.program);
    defer testing.allocator.free(second_bytes);
    try testing.expectEqualSlices(u8, first_bytes, second_bytes);
}

test "coalescing work limit after an intermediate selection returns original baseline" {
    var stats: pass.Statistics = .{};
    var measured = try pass.run(testing.allocator, fixture, .{ .statistics = &stats });
    defer measured.deinit();
    try testing.expect(stats.first_selected_work > 0);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = try @import("relocation.zig").ownReachable(
        arena.allocator(),
        arena.allocator(),
        fixture,
    );
    const baseline = try bytes(original.program);
    defer testing.allocator.free(baseline);
    const Capture = struct {
        maps: @import("relocation.zig").Maps,
        called: bool = false,
        fn receive(context: *anyopaque, trace: *const pass.OriginsTrace) pass.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.called) return error.InvalidCorrespondence;
            for (
                self.maps,
                trace.maps,
            ) |expected, actual| if (!std.mem.eql(
                @import("program.zig").Id,
                expected,
                actual,
            )) return error.InvalidCorrespondence;
            for (trace.locals) |local| for (
                local.slots,
                0..,
            ) |slot, i| if (slot != i) return error.InvalidCorrespondence;
            self.called = true;
        }
    };
    for ([_]u64{ 0, stats.first_selected_work }) |limit| {
        var limited_stats: pass.Statistics = .{};
        var capture: Capture = .{ .maps = original.maps.? };
        var limited = try pass.run(
            testing.allocator,
            fixture,
            .{
                .work_limit = limit,
                .statistics = &limited_stats,
                .correspondence = .{ .context = &capture, .receive = Capture.receive },
            },
        );
        defer limited.deinit();
        try testing.expectEqual(pass.Outcome.work_limit, limited_stats.outcome);
        try testing.expectEqual(@as(usize, 0), limited_stats.extraction_rounds);
        const actual = try bytes(limited.program);
        defer testing.allocator.free(actual);
        try testing.expectEqualSlices(u8, baseline, actual);
        try testing.expect(capture.called);
    }
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var result = try pass.run(allocator, fixture, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.program.functions.len);
}

test "coalescing fixed point releases all owners at every allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, allocationCase, .{});
}

const description_only: @import("activation.zig").Program = .{
    .roots = .{ .entry = 0, .result = 2, .failure = 0 },
    .schemas = &.{ .u64, .u64, .{ .product = &.{ 0, 1 } } },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 1, 2 } },
        .result = 2,
    }},
    .blocks = &.{.{ .function = 0, .instructions = &.{.{
        .destination = 2,
        .opcode = .product,
        .operands = &.{ 0, 1 },
    }}, .terminator = .{ .return_value = 2 } }},
};

fn descriptionAllocationCase(allocator: std.mem.Allocator) !void {
    var stats: pass.Statistics = .{};
    var result = try pass.run(allocator, description_only, .{ .statistics = &stats });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.program.schemas.len);
    try testing.expectEqual(@as(usize, 1), stats.candidate_admissions);
    try testing.expectEqual(@as(usize, 2), stats.validator_calls);
    try testing.expectEqualDeep(stats.full, stats.descriptions);
    try testing.expectEqual(
        @import("coalescing_discovery.zig").Profile.full,
        stats.selected_profile.?,
    );
}

test "coalescing reuses equal portfolios with identical bytes and allocation failure cleanup" {
    try @import("allocation_testing.zig").check(testing.allocator, descriptionAllocationCase, .{});
    const discovery = @import("coalescing_discovery.zig");
    const candidate = @import("coalescing_candidate.zig");
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var work: @import("coalescing_graph.zig").Work = .{};
    const analysis = try discovery.analyze(scratch.allocator(), description_only, &work);
    var separate = try candidate.build(
        testing.allocator,
        scratch.allocator(),
        description_only,
        analysis,
        .descriptions,
        &work,
    );
    defer separate.deinit();
    var selected = try pass.run(testing.allocator, description_only, .{});
    defer selected.deinit();
    const expected = try bytes(separate.program);
    defer testing.allocator.free(expected);
    const actual = try bytes(selected.program);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
}

test "coalescing preserves duplicate sum alternatives and old duplicate-containing codec input" {
    const ir = @import("activation.zig");
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 2, .failure = 3 },
        .schemas = &.{ .u64, .u64, .{ .sum = &.{ 0, 1 } }, .unit },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{2} },
            .result = 2,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        }},
    };
    const original = try bytes(program);
    defer testing.allocator.free(original);
    var decoded = try image.decode(testing.allocator, original);
    defer decoded.deinit();
    // Decoding and encoding must never implicitly select optimizer normal form.
    try testing.expectEqual(@as(usize, 4), decoded.program.schemas.len);
    const roundtrip = try bytes(decoded.program);
    defer testing.allocator.free(roundtrip);
    try testing.expectEqualSlices(u8, original, roundtrip);
    var optimized = try pass.run(testing.allocator, decoded.program, .{});
    defer optimized.deinit();
    try testing.expectEqual(@as(usize, 3), optimized.program.schemas.len);
    const sum = optimized.program.schemas[@intCast(optimized.program.roots.result)].sum;
    try testing.expectEqual(@as(usize, 2), sum.len);
    try testing.expectEqual(sum[0], sum[1]);
    const value = @import("admission.zig");
    // Independently transcribed canonical u64 payloads in the two injections.
    const left = [_]u8{ 0, 7, 0, 0, 0, 0, 0, 0, 0 };
    const right = [_]u8{ 1, 7, 0, 0, 0, 0, 0, 0, 0 };
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    for ([_]ir.Program{ decoded.program, optimized.program }) |subject| {
        const facts = try value.schemas(scratch.allocator(), subject.schemas);
        for ([_][]const u8{ &left, &right }) |payload|
            try value.value(
                scratch.allocator(),
                subject.schemas,
                facts,
                .{ .schema = subject.roots.result, .bytes = payload },
            );
        var invalid = right;
        invalid[0] = 2;
        try testing.expectError(
            error.InvalidValue,
            value.value(
                scratch.allocator(),
                subject.schemas,
                facts,
                .{ .schema = subject.roots.result, .bytes = &invalid },
            ),
        );
    }
}

const MapCapture = struct {
    a: std.mem.Allocator,
    map: ?pass.Correspondence = null,

    fn receive(context: *anyopaque, trace: *const pass.OriginsTrace) pass.Error!void {
        const self: *MapCapture = @ptrCast(@alignCast(context));
        self.map = try pass.Correspondence.copy(self.a, trace);
    }

    fn options(self: *MapCapture) pass.Options {
        return .{ .correspondence = .{ .context = self, .receive = receive } };
    }
};

test "coalescing bounded work returns exact ordinary image and complete map at its work boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ordinary_map: MapCapture = .{ .a = arena.allocator() };
    var ordinary = try pass.run(testing.allocator, fixture, ordinary_map.options());
    defer ordinary.deinit();
    const expected = try bytes(ordinary.program);
    defer testing.allocator.free(expected);
    const maximum = std.math.maxInt(u64);
    var remaining: u64 = maximum;
    var actual_map: MapCapture = .{ .a = arena.allocator() };
    var actual = try pass.runWithWork(testing.allocator, fixture, actual_map.options(), &remaining);
    defer actual.deinit();
    const used = maximum - remaining;
    const encoded = try bytes(actual.program);
    defer testing.allocator.free(encoded);
    try testing.expectEqualSlices(u8, expected, encoded);
    try testing.expect(@import("record.zig").equal(
        pass.Correspondence,
        ordinary_map.map.?,
        actual_map.map.?,
    ));
    var exact = used;
    var repeated = try pass.runWithWork(testing.allocator, fixture, actual_map.options(), &exact);
    defer repeated.deinit();
    try testing.expectEqual(@as(u64, 0), exact);
    for ([_]u64{ 0, used - 1 }) |limit| {
        remaining = limit;
        actual_map.map = null;
        try testing.expectError(error.RelationLimit, pass.runWithWork(
            testing.allocator,
            fixture,
            actual_map.options(),
            &remaining,
        ));
        try testing.expect(actual_map.map == null);
    }
}
