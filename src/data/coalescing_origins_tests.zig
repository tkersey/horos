// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const testing = std.testing;
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const origins = @import("coalescing_origins.zig");
const discovery = @import("coalescing_discovery.zig");
const candidate = @import("coalescing_candidate.zig");
const graph = @import("coalescing_graph.zig");
const pass = @import("coalescing.zig");
const fixture = @import("coalescing_witness_tests.zig").original;

fn withDeadFunction(a: std.mem.Allocator) !ir.Program {
    var maps = try r.identityMaps(a, try r.sizes(fixture));
    inline for (.{ r.Kind.function, r.Kind.block }) |kind| {
        const shifted = try a.dupe(p.Id, maps[@backingInt(kind)]);
        for (shifted) |*id| id.* += 1;
        maps[@backingInt(kind)] = shifted;
    }
    const mapper: r.Mapper = .{ .allocator = a, .maps = maps };
    const functions = try a.alloc(ir.Function, fixture.functions.len + 1);
    functions[0] = fixture.functions[0];
    for (functions[1..], fixture.functions) |*target, old| target.* = try mapper.function(old);
    const blocks = try a.alloc(ir.Block, fixture.blocks.len + 1);
    blocks[0] = fixture.blocks[0];
    for (blocks[1..], fixture.blocks) |*target, old| target.* = try mapper.block(old);
    functions[1].layout.slots = &.{ 0, 0 };
    functions[2].layout.slots = &.{ 0, 0 };
    functions[2].inputs = &.{1};
    blocks[2].terminator = .{ .return_value = 1 };
    functions[1].custody = &.{ .{}, .{ .parent = 0 }, .{ .parent = 0 }, .{ .parent = 1 } };
    functions[2].custody = &.{ .{}, .{ .parent = 0 }, .{ .parent = 0 }, .{ .parent = 2 } };
    functions[0].layout = functions[1].layout;
    functions[0].custody = functions[1].custody;
    var result = fixture;
    result.roots.entry += 1;
    result.functions = functions;
    result.blocks = blocks;
    return result;
}

test "coalescing diagnostics preserve original aliases across projection and successive maps" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const original = try withDeadFunction(a);
    var facts = try @import("activation_ownership.zig").analyze(testing.allocator, original);
    facts.deinit();
    const baseline = try r.ownReachable(a, a, original);
    var trace = try origins.Trace.init(testing.allocator, original, baseline);
    defer trace.deinit();
    var work: graph.Work = .{};
    const analysis = try discovery.analyze(a, baseline.program, &work);
    var first = try candidate.build(testing.allocator, a, baseline.program, analysis, .full, &work);
    defer first.deinit();
    var diagnostic: origins.Diagnostic = .{
        .target = .{ .phase = .block, .function = 0, .slot = 0 },
    };
    trace.explain(first.correspondence, &diagnostic);
    try testing.expectEqualSlices(p.Id, &.{ 1, 2 }, diagnostic.origins.items());
    try testing.expect(diagnostic.origins.ambiguous);
    try testing.expectEqual(@as(?p.Id, 0), diagnostic.original_slot);
    try trace.advance(first.correspondence);
    try testing.expectEqualSlices(p.Id, &.{ 1, 0 }, trace.locals[2].slots);
    try testing.expectEqualSlices(p.Id, &.{ 0, 2, 1, 3 }, trace.locals[2].custody);
    const next_analysis = try discovery.analyze(a, first.program, &work);
    var second = try candidate.build(
        testing.allocator,
        a,
        first.program,
        next_analysis,
        .full,
        &work,
    );
    defer second.deinit();
    try trace.advance(second.correspondence);
    try testing.expectEqualSlices(p.Id, &.{ 1, 0 }, trace.locals[2].slots);
    try testing.expectEqualSlices(p.Id, &.{ 0, 2, 1, 3 }, trace.locals[2].custody);
    trace.explain(null, &diagnostic);
    try testing.expectEqualSlices(p.Id, &.{ 1, 2 }, diagnostic.origins.items());
    const before = try a.dupe(p.Id, trace.map(.function));
    var stale = second.correspondence;
    stale.locals = &.{};
    try testing.expectError(error.InvalidCorrespondence, trace.advance(stale));
    try testing.expectEqualSlices(p.Id, before, trace.map(.function));
    stale = second.correspondence;
    stale.final[@backingInt(r.Kind.schema)] = &.{};
    try testing.expectError(error.InvalidCorrespondence, trace.advance(stale));
    try testing.expectEqualSlices(p.Id, before, trace.map(.function));
    try testing.expectEqualSlices(p.Id, &.{ 1, 0 }, trace.locals[2].slots);
    try testing.expectEqualSlices(p.Id, &.{ 0, 2, 1, 3 }, trace.locals[2].custody);
    diagnostic.target.function = 1;
    trace.explain(null, &diagnostic);
    try testing.expectEqualSlices(p.Id, &.{3}, diagnostic.origins.items());
    try testing.expect(!diagnostic.origins.ambiguous);
}

fn allocationCase(a: std.mem.Allocator) !void {
    var diagnostic: pass.Diagnostic = .{
        .target = .{ .function = 999, .slot = 999 },
    };
    var stats: pass.Statistics = .{};
    var result = pass.run(a, fixture, .{
        .diagnostic = &diagnostic,
        .statistics = &stats,
    }) catch |err| {
        try testing.expectEqual(err, diagnostic.code.?);
        try testing.expectEqual(err, stats.failed_check.?);
        return err;
    };
    defer result.deinit();
    try testing.expectEqual(@as(?anyerror, null), diagnostic.code);
    try testing.expectEqual(@as(?p.Id, null), diagnostic.target.function);
    try testing.expectEqual(@as(usize, 0), diagnostic.origins.count);
    try testing.expectEqual(@as(usize, 2), result.program.functions.len);
}

test "coalescing diagnostic tracking owns partial storage and clears successful observations" {
    try @import("allocation_testing.zig").check(testing.allocator, allocationCase, .{});
}

test "coalescing diagnostics do not change the selected image" {
    var diagnostic: pass.Diagnostic = .{};
    var observed = try pass.run(
        testing.allocator,
        fixture,
        .{ .diagnostic = &diagnostic },
    );
    defer observed.deinit();
    var ordinary = try pass.run(testing.allocator, fixture, .{});
    defer ordinary.deinit();
    const image = @import("program_image.zig");
    try testing.expectEqual(
        try image.identity(testing.allocator, ordinary.program),
        try image.identity(testing.allocator, observed.program),
    );
}

const typed_constructors: ir.Program = .{
    .roots = .{ .entry = 2, .result = 4, .failure = 0 },
    .schemas = &.{
        .u64,                       .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = 0,
            .capture_bound = &.{0},
        } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = 0,
            .capture_bound = &.{ 0, 1 },
        } } },
        .{ .product = &.{ 0, 0 } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 2, 3, 0, 0, 4 } },
            .result = 4,
        },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 2, .instructions = &.{
            .{ .destination = 2, .opcode = .computation, .immediate = 0, .operands = &.{0} },
            .{ .destination = 3, .opcode = .computation, .immediate = 1, .operands = &.{1} },
        }, .terminator = .{ .apply = .{
            .computation = 2,
            .arguments = &.{},
            .next = .{ .block = 3, .assignments = &.{.{ .destination = 4, .source = .returned }} },
        } } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .apply = .{
            .computation = 3,
            .arguments = &.{},
            .next = .{ .block = 4, .assignments = &.{.{ .destination = 5, .source = .returned }} },
        } } },
        .{ .function = 2, .instructions = &.{.{
            .destination = 6,
            .opcode = .product,
            .operands = &.{ 4, 5 },
        }}, .terminator = .{ .return_value = 6 } },
    },
    .constructors = &.{
        .{ .function = 0, .capture = 0, .schema = 2 },
        .{ .function = 1, .capture = 0, .schema = 3 },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
};

test "coalescing diagnostic distinguishes typed constructors sharing one code representative" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var checked = try @import("activation_ownership.zig").analyze(
        testing.allocator,
        typed_constructors,
    );
    checked.deinit();
    const baseline = try r.ownReachable(a, a, typed_constructors);
    var trace = try origins.Trace.init(testing.allocator, typed_constructors, baseline);
    defer trace.deinit();
    var work: graph.Work = .{};
    const analysis = try discovery.analyze(a, baseline.program, &work);
    var first = try candidate.build(testing.allocator, a, baseline.program, analysis, .full, &work);
    defer first.deinit();
    try testing.expectEqual(@as(usize, 2), first.program.functions.len);
    try testing.expectEqual(@as(usize, 2), first.program.constructors.len);
    try trace.advance(first.correspondence);
    const next_analysis = try discovery.analyze(a, first.program, &work);
    var second = try candidate.build(
        testing.allocator,
        a,
        first.program,
        next_analysis,
        .full,
        &work,
    );
    defer second.deinit();
    try constructorMutant(a, first.program, second.program, second.correspondence, &trace);
    try sharedBodyMutant(a, first.program, second.program, second.correspondence, &trace);
}

fn constructorMutant(
    a: std.mem.Allocator,
    before: ir.Program,
    after: ir.Program,
    map: @import("coalescing_witness.zig").Witness,
    trace: *const origins.Trace,
) !void {
    var changed = after;
    const constructors = try a.dupe(p.Constructor, after.constructors);
    constructors[0].schema = constructors[1].schema;
    changed.constructors = constructors;
    const functions = try a.dupe(ir.Function, after.functions);
    const slots = try a.dupe(p.Id, functions[@intCast(after.roots.entry)].layout.slots);
    slots[2] = constructors[1].schema;
    functions[@intCast(after.roots.entry)].layout.slots = slots;
    changed.functions = functions;
    var checked = try @import("activation_ownership.zig").analyze(testing.allocator, changed);
    checked.deinit();
    var diagnostic: origins.Diagnostic = .{ .stage = .transformation };
    try testing.expectError(
        error.InvalidCorrespondence,
        @import("coalescing_validation.zig").validateDiagnosed(
            testing.allocator,
            before,
            changed,
            map,
            &diagnostic.target,
        ),
    );
    trace.explain(null, &diagnostic);
    try testing.expectEqualSlices(p.Id, &.{0}, diagnostic.origins.items());
    try testing.expect(!diagnostic.origins.ambiguous);
}

fn sharedBodyMutant(
    a: std.mem.Allocator,
    before: ir.Program,
    after: ir.Program,
    map: @import("coalescing_witness.zig").Witness,
    trace: *const origins.Trace,
) !void {
    var changed = after;
    const blocks = try a.dupe(ir.Block, after.blocks);
    blocks[@intCast(after.functions[0].entry)].terminator = .{ .fail = 0 };
    changed.blocks = blocks;
    var checked = try @import("activation_ownership.zig").analyze(testing.allocator, changed);
    checked.deinit();
    var diagnostic: origins.Diagnostic = .{ .stage = .transformation };
    try testing.expectError(
        error.InvalidCorrespondence,
        @import("coalescing_validation.zig").validateDiagnosed(
            testing.allocator,
            before,
            changed,
            map,
            &diagnostic.target,
        ),
    );
    trace.explain(null, &diagnostic);
    try testing.expectEqualSlices(p.Id, &.{ 0, 1 }, diagnostic.origins.items());
    try testing.expect(diagnostic.origins.ambiguous);
}

test "coalescing origin composition retains sparse nominal regions without dense allocation" {
    const large = std.math.maxInt(p.Id) - 1;
    const original: ir.Program = .{
        .roots = .{ .entry = 0, .result = 1, .failure = 0 },
        .schemas = &.{
            .unit,                                 .u64,
            .{ .internal = .{ .region = large } },
            .{
                .internal = .{
                    .computation = .{
                        .parameters = &.{2},
                        .result = 1,
                        .regions = &.{large},
                    },
                },
            },
        },
        .constants = &.{.{ .schema = 1, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }},
        .effects = &.{},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{ 3, 1 } }, .result = 1 },
            .{
                .entry = 1,
                .inputs = &.{0},
                .layout = .{ .slots = &.{ 2, 1 } },
                .result = 1,
                .regions = &.{large},
            },
        },
        .blocks = &.{
            .{ .function = 0, .instructions = &.{.{
                .destination = 0,
                .opcode = .computation,
            }}, .terminator = .{ .with_region = .{
                .region = large,
                .body = 0,
                .arguments = &.{},
                .next = .{
                    .block = 2,
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } } },
            .{
                .function = 1,
                .instructions = &.{.{ .destination = 1, .opcode = .constant }},
                .terminator = .{ .return_value = 1 },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        },
        .constructors = &.{.{ .function = 1, .capture = 0, .schema = 3 }},
        .scopes = .{
            .region_count = std.math.maxInt(p.Id),
            .captures = &.{.{ .fields = &.{}, .use = .reusable }},
        },
    };
    var checked = try @import("activation_ownership.zig").analyze(testing.allocator, original);
    checked.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const baseline = try r.ownReachable(a, a, original);
    var trace = try origins.Trace.init(testing.allocator, original, baseline);
    defer trace.deinit();
    try testing.expectEqual(@as(usize, 0), trace.map(.region).len);
    try testing.expectEqual(@as(usize, 1), trace.regions.len);
    try testing.expectEqual(@as(?p.Id, 0), trace.resolve(.region, large));
    try testing.expectEqual(@as(?p.Id, null), trace.resolve(.region, 10));
    var work: graph.Work = .{};
    const analysis = try discovery.analyze(a, baseline.program, &work);
    var result = try candidate.build(
        testing.allocator,
        a,
        baseline.program,
        analysis,
        .full,
        &work,
    );
    defer result.deinit();
    try trace.advance(result.correspondence);
    try testing.expectEqual(@as(?p.Id, 0), trace.resolve(.region, large));
    const correspondence = @import("coalescing_correspondence.zig");
    const submitted = try correspondence.Correspondence.copy(a, &trace);
    var buffer: [1024 * 1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&buffer);
    try correspondence.validate(bounded.allocator(), original, result.program, submitted);
    var stale = result.correspondence;
    stale.final[@backingInt(r.Kind.region)] = &.{};
    try testing.expectError(error.InvalidCorrespondence, trace.advance(stale));
    try testing.expectEqual(@as(?p.Id, 0), trace.resolve(.region, large));
}
