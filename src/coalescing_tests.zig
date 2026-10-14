// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independently emitted closures through the public typed authoring API.
const std = @import("std");
const frozen = @import("coalescing_baselines.zig");
const testing = std.testing;
const source = @import("source.zig");
const authoring = @import("authoring.zig");
const data = @import("horos_data");

pub fn closures(
    allocator: std.mem.Allocator,
    count: usize,
    options: data.coalescing.Options,
) !source.Compiled {
    return buildClosures(allocator, count, options, false);
}

fn buildClosures(
    allocator: std.mem.Allocator,
    count: usize,
    options: data.coalescing.Options,
    literal: bool,
) !source.Compiled {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const a = raw.arena.allocator();
    const context = try authoring.Context.init(&raw);
    const integer = try context.schema(u64);
    const unit = try context.schema(void);
    const fields = try a.alloc(authoring.interop.NamedEntry(.schema), count);
    for (fields, 0..) |*field, id| field.* = .{
        .name = try a.print("value-{d}", .{id}),
        .handle = authoring.interop.erase(integer),
    };
    const named_fields = try authoring.interop.RuntimeNamed(.schema).init(context, fields);
    const result_schema = try context.record(named_fields);
    const callable = try context.callable(
        .{ .x = integer },
        integer,
        &.{},
        .{ .use = .reusable, .captures = &.{integer} },
    );
    const entry = try context.function("entry", try authoring.interop.RuntimeNamed(.schema).init(context, if (literal) &.{} else fields), result_schema, &.{});
    const body = try context.body(entry);
    const failure = try context.literalFailure(void, {});
    const arguments = try a.alloc(authoring.interop.NamedEntry(.value), count);
    for (fields, arguments, 0..) |field, *argument, id| {
        const captured = if (literal)
            authoring.interop.erase(try body.constant(u64, 3 + 4 * @as(u64, @intCast(id))))
        else
            try authoring.interop.parameter(body, field.name);
        // Each invocation emits a fresh declaration, constructor and capture site.
        const helper = try context.functionFor(field.name, callable);
        const inner = try body.closureBody(helper);
        try context.define(
            helper,
            try inner.ret(try inner.checkedAdd(try inner.parameter("x"), captured, failure)),
        );
        const closure = try body.lambda(helper, callable);
        const x = try body.constant(u64, 10);
        argument.* = .{
            .name = field.name,
            .handle = authoring.interop.erase(try body.apply(closure, .{ .x = x })),
        };
    }
    try context.define(entry, try body.ret(try body.product(result_schema, try authoring.interop.RuntimeNamed(.value).init(context, arguments))));
    return context.compileWithOptions(allocator, entry, unit, options);
}

test "coalescing typed authoring shares independently emitted captured closure family" {
    for ([_]usize{ 1, 2, 15, 16, 17, 63, 64, 65, 127, 128, 129, 255, 256, 257 }) |count| {
        var off = try frozen.closures(testing.allocator, count);
        defer off.deinit();
        var statistics: data.coalescing.Statistics = .{};
        var safe = try closures(
            testing.allocator,
            count,
            .{ .statistics = &statistics },
        );
        defer safe.deinit();
        try testing.expectEqual(count + 1, off.program.functions.len);
        try testing.expectEqual(count, off.program.constructors.len);
        try testing.expectEqual(@as(usize, 2), safe.program.functions.len);
        try testing.expectEqual(@as(usize, 1), safe.program.constructors.len);
        try testing.expectEqual(@as(usize, 1), safe.program.scopes.captures.len);
        const before = try data.program_image.encodedLength(off.program);
        const after = try data.program_image.encodedLength(safe.program);
        try testing.expect(after <= before);
        if (count >= 16) try testing.expect(after < before);
        for ([_]data.activation.Program{ off.program, safe.program }) |program| {
            const length = try data.program_image.encodedLength(program);
            const buffer = try testing.allocator.alloc(u8, length);
            defer testing.allocator.free(buffer);
            const encoded = try data.program_image.encode(testing.allocator, program, buffer);
            try testing.expectEqual(length, encoded.len);
        }
        var constructions: usize = 0;
        for (safe.program.blocks) |block| for (block.instructions) |operation|
            if (operation.opcode == .computation) {
                constructions += 1;
            };
        try testing.expectEqual(count, constructions);
    }
}

test "coalescing preserves distinct literals embedded by independent authoring" {
    var safe = try buildClosures(testing.allocator, 2, .{}, true);
    defer safe.deinit();
    try testing.expectEqual(@as(usize, 3), safe.program.functions.len);
    try testing.expectEqual(@as(usize, 2), safe.program.constructors.len);
    try testing.expectEqual(@as(usize, 1), safe.program.scopes.captures.len);
    try testing.expectEqual(@as(usize, 0), safe.program.scopes.captures[0].fields.len);
}

test "canonical coalescing shares code and observations preserve its output" {
    var ordinary = try closures(testing.allocator, 2, .{});
    defer ordinary.deinit();
    try testing.expectEqual(@as(usize, 2), ordinary.program.functions.len);
    try testing.expectEqual(@as(usize, 1), ordinary.program.constructors.len);
    var rounds: [1]data.coalescing.Round = undefined;
    var stats: data.coalescing.Statistics = .{ .rounds = &rounds };
    var observed = try closures(testing.allocator, 2, .{ .statistics = &stats });
    defer observed.deinit();
    try testing.expect(stats.round_count > stats.rounds_recorded);
    try testing.expectEqual(@as(usize, 1), stats.rounds_recorded);
    try testing.expectEqual(
        try data.program_image.identity(testing.allocator, ordinary.program),
        try data.program_image.identity(testing.allocator, observed.program),
    );
}

test "coalescing retains each original closure observation through constructor cache reuse" {
    const Id = source.Id;
    const Trace = struct {
        values: [3]Id = undefined,
        variables: [3]Id = undefined,
        count: usize = 0,
        fn closure(pointer: *anyopaque, value: Id, variable: Id) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.values[self.count] = value;
            self.variables[self.count] = variable;
            self.count += 1;
        }
        fn capture(_: *anyopaque, _: *const data.activation_ownership.CaptureSite, _: Id) void {
            @panic("effect-free fixture cannot retain a continuation capture");
        }
    };
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const triple = try b.schema(.{ .product = &.{ integer, integer, integer } });
    const shape = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .capture_bound = &.{integer},
        .use = .reusable,
    } } });
    const entry = try b.declare(&.{integer}, triple, &.{}, &.{});
    const variable = b.parameter(entry, 0);
    var helpers: [2]Id = undefined;
    for (&helpers) |*helper| {
        helper.* = try b.declare(&.{}, integer, &.{}, &.{});
        try b.define(helper.*, try b.pure(try b.reference(variable)));
    }
    var lambdas: [3]Id = undefined;
    var closures_: [3]Id = undefined;
    var results: [3]Id = undefined;
    var values: [3]Id = undefined;
    for (&lambdas, &closures_, &results, &values, [_]Id{ helpers[0], helpers[0], helpers[1] }) |*lambda, *closure, *result, *value, helper| {
        lambda.* = try b.lambda(helper, shape);
        closure.* = try b.variable(shape);
        result.* = try b.variable(integer);
        value.* = try b.reference(result.*);
    }
    var next = try b.pure(try b.primitive(triple, .product, &values, 0));
    var index: usize = 3;
    while (index != 0) {
        index -= 1;
        const apply = try b.term(.{ .apply = .{ .computation = try b.reference(closures_[index]), .arguments = &.{} } });
        next = try b.bind(closures_[index], try b.pure(lambdas[index]), try b.bind(results[index], apply, next));
    }
    try b.define(entry, next);
    const module = b.module(entry, unit);
    {
        var trace: Trace = .{};
        var observed = try source.lowerObserved(testing.allocator, module, .{
            .captures = .{ .context = &trace, .closure = Trace.closure, .capture = Trace.capture },
        });
        defer observed.deinit();
        try testing.expectEqual(@as(usize, 3), trace.count);
        try testing.expectEqualSlices(Id, &lambdas, &trace.values);
        try testing.expectEqualSlices(Id, &.{ variable, variable, variable }, &trace.variables);
        try testing.expectEqual(@as(usize, 1), observed.program.constructors.len);
        var plain = try source.lowerObserved(testing.allocator, module, .{});
        defer plain.deinit();
        try testing.expectEqual(try data.program_image.identity(testing.allocator, plain.program), try data.program_image.identity(testing.allocator, observed.program));
    }
}

test "coalescing shares depth-eight helper chains through calls and constructed computations" {
    const trees = @import("coalescing_tree_cases.zig");
    inline for (.{ trees.Kind.tree, trees.Kind.tree_near }) |kind| {
        var off = try frozen.kind(testing.allocator, "", kind);
        defer off.deinit();
        var safe = try trees.compile(testing.allocator, kind, .{});
        defer safe.deinit();
        try testing.expectEqual(@as(usize, 19), off.program.functions.len);
        try testing.expectEqual(@as(usize, if (kind == .tree) 10 else 19), safe.program.functions.len);
        try testing.expectEqual(@as(usize, 8), off.program.constructors.len);
        try testing.expectEqual(@as(usize, if (kind == .tree) 4 else 8), safe.program.constructors.len);
        try testing.expect(try data.program_image.encodedLength(safe.program) <=
            try data.program_image.encodedLength(off.program));
    }
}

test "coalescing shares stateful code while retaining every dynamic allocation site" {
    const cases = @import("coalescing_state_cases.zig");
    for (std.enums.values(cases.Kind)) |kind| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try cases.build(&builder, kind);
        var off = try frozen.kind(testing.allocator, "", kind);
        defer off.deinit();
        var safe = try source.lowerObserved(testing.allocator, module, .{});
        defer safe.deinit();
        try testing.expectEqual(off.program.functions.len - 1, safe.program.functions.len);
        try testing.expectEqual(off.program.constructors.len - 1, safe.program.constructors.len);
        const expected: usize = switch (kind) {
            .cells_independent => 2,
            .cells_shared => 1,
            .memo_independent => 3,
            .memo_shared => 2,
        };
        for ([_]data.activation.Program{ off.program, safe.program }) |program| {
            var allocations: usize = 0;
            for (program.blocks) |block| for (block.instructions) |operation| {
                allocations += @intFromBool(operation.opcode == .cell_new);
            };
            try testing.expectEqual(expected, allocations);
        }
    }
}

test "coalescing handles whole-function slot renaming with simultaneous swaps and cycles" {
    const edges = @import("coalescing_edge_cases.zig");
    for (std.enums.values(edges.Kind)) |kind| {
        var off = try frozen.kind(testing.allocator, "", kind);
        defer off.deinit();
        var safe = try edges.compile(testing.allocator, kind, .{});
        defer safe.deinit();
        try testing.expectEqual(@as(usize, 3), off.program.functions.len);
        try testing.expectEqual(@as(usize, 2), safe.program.functions.len);
        try testing.expectEqualSlices(data.program.Id, &.{ 0, 1, 2 }, safe.program.functions[0].inputs);
        try testing.expectEqual(@as(usize, if (kind == .swap) 2 else 3), safe.program.blocks[0].terminator.jump.assignments.len);
    }
}

test "coalescing production generator covers all three-slot renamings and ordered mutations" {
    const cases = @import("coalescing_edge_cases.zig");
    for (0..36) |ordinal| for ([_]usize{ 0, 64 }) |mutation| {
        var result = try cases.generated(testing.allocator, ordinal + mutation, .{});
        defer result.deinit();
        try testing.expectEqual(@as(usize, if (mutation == 0) 2 else 3), result.program.functions.len);
    };
    for (0..36) |ordinal| {
        try testing.expectError(error.InvalidReference, cases.generated(testing.allocator, ordinal + 128, .{}));
    }
}

test "coalescing matches renamed function-local loops and retains changed exit order" {
    const edges = @import("coalescing_edge_cases.zig");
    for (std.enums.values(edges.LoopKind)) |kind| {
        var off = try frozen.kind(testing.allocator, "", kind);
        defer off.deinit();
        var safe = try edges.compileLoop(testing.allocator, kind, .{});
        defer safe.deinit();
        try testing.expectEqual(@as(usize, 3), off.program.functions.len);
        try testing.expectEqual(@as(usize, if (kind == .loop) 2 else 3), safe.program.functions.len);
        try testing.expect(try data.program_image.encodedLength(safe.program) <=
            try data.program_image.encodedLength(off.program));
    }
}

test "coalescing authored recursive groups preserve role distinctions and changed bases" {
    const cases = @import("coalescing_recursive_cases.zig");
    for (std.enums.values(cases.Kind)) |kind| {
        var off = try frozen.kind(testing.allocator, "", kind);
        defer off.deinit();
        var safe = try cases.compile(testing.allocator, kind, .{});
        defer safe.deinit();
        try testing.expectEqual(@as(usize, 5), off.program.functions.len);
        try testing.expectEqual(@as(usize, if (kind == .recursive_near) 5 else 3), safe.program.functions.len);
    }
}

const ConcurrentCompilation = struct {
    count: usize,
    expected: [2][32]u8,
    failure: ?anyerror = null,
    completed: usize = 0,

    fn run(self: *ConcurrentCompilation) void {
        var allocator: std.heap.DebugAllocator(.{}) = .init;
        defer if (allocator.deinit() != .ok) {
            self.failure = error.LeakedCompilationStorage;
        };
        self.check(allocator.allocator()) catch |err| {
            self.failure = err;
        };
    }

    fn check(self: *ConcurrentCompilation, allocator: std.mem.Allocator) !void {
        for (0..4) |iteration| {
            // Alternate work-limited and completed canonical passes with independent owners.
            var stats: data.coalescing.Statistics = .{};
            var diagnostic: data.coalescing.Diagnostic = .{};
            const limited = iteration % 3 == 0;
            var compiled = try closures(allocator, self.count, .{
                .work_limit = if (limited) 0 else std.math.maxInt(u64),
                .statistics = &stats,
                .diagnostic = &diagnostic,
            });
            defer compiled.deinit();
            // closures has already destroyed the source builder at this point.
            const actual = try data.program_image.identity(allocator, compiled.program);
            const expected = self.expected[@intFromBool(!limited)];
            if (!std.mem.eql(u8, &expected, &actual)) return error.ConcurrentImageMismatch;
            if (limited and stats.outcome != .work_limit) return error.MissingWorkLimit;
            if (diagnostic.code != null) return error.StaleDiagnostic;
            self.completed += 1;
        }
    }
};

test "coalescing concurrent independent compilers preserve deterministic owners and observations" {
    var jobs: [4]ConcurrentCompilation = undefined;
    for (&jobs, [_]usize{ 2, 16, 32, 64 }) |*job, count| {
        job.* = .{ .count = count, .expected = undefined };
        var original = try closures(testing.allocator, count, .{ .work_limit = 0 });
        defer original.deinit();
        var compiled = try closures(testing.allocator, count, .{});
        defer compiled.deinit();
        job.expected[0] = try data.program_image.identity(testing.allocator, original.program);
        job.expected[1] = try data.program_image.identity(testing.allocator, compiled.program);
    }
    var threads: [jobs.len]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads, &jobs) |*thread, *job| {
        thread.* = try std.Thread.spawn(.{}, ConcurrentCompilation.run, .{job});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    for (jobs) |job| {
        if (job.failure) |err| return err;
        try testing.expectEqual(@as(usize, 4), job.completed);
    }
}

test "coalescing folds fresh hyper helper emissions but retains Step configuration" {
    const cases = @import("coalescing_hyper_cases.zig");
    var selected_functions: [3]usize = undefined;
    for (std.enums.values(cases.Kind), 0..) |kind, index| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try cases.build(&builder, kind);
        var off = try frozen.kind(testing.allocator, "hyper_", kind);
        defer off.deinit();
        var safe = try source.lowerObserved(testing.allocator, module, .{});
        defer safe.deinit();
        try testing.expect(safe.program.functions.len < off.program.functions.len);
        try testing.expect(safe.program.constructors.len < off.program.constructors.len);
        try testing.expect(try data.program_image.encodedLength(safe.program) <
            try data.program_image.encodedLength(off.program));
        selected_functions[index] = safe.program.functions.len;
    }
    // The near case changes only the second Step's actual emitted arithmetic.
    try testing.expect(selected_functions[@backingInt(cases.Kind.configured)] >
        selected_functions[@backingInt(cases.Kind.duplicate)]);
}

test "coalescing preserves reversed equal-type capture operands at distinct construction sites" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const module = try @import("coalescing_capture_case.zig").build(&builder);
    var off = try frozen.get(testing.allocator, "capture_order");
    defer off.deinit();
    var safe = try source.lowerObserved(testing.allocator, module, .{});
    defer safe.deinit();
    try testing.expectEqual(@as(usize, 3), off.program.functions.len);
    try testing.expectEqual(@as(usize, 2), safe.program.functions.len);
    try testing.expectEqual(@as(usize, 2), off.program.constructors.len);
    try testing.expectEqual(@as(usize, 1), safe.program.constructors.len);
    try testing.expectEqual(@as(usize, 2), safe.program.scopes.captures[0].fields.len);
    var constructions: usize = 0;
    for (safe.program.blocks) |block| for (block.instructions) |op| {
        if (op.opcode == .computation) {
            try testing.expectEqual(@as(usize, 2), op.operands.len);
            constructions += 1;
        }
    };
    try testing.expectEqual(@as(usize, 2), constructions);
}

test "coalescing shares immutable handler descriptions but not installations or modes" {
    const cases = @import("coalescing_handler_cases.zig");
    for (std.enums.values(cases.Kind)) |kind| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try cases.build(&builder, kind);
        var off = try frozen.kind(testing.allocator, "handler_", kind);
        defer off.deinit();
        var safe = try source.lowerObserved(testing.allocator, module, .{});
        defer safe.deinit();
        try testing.expectEqual(@as(usize, 2), off.program.handlers.len);
        try testing.expectEqual(@as(usize, if (kind == .mixed_mode) 2 else 1), safe.program.handlers.len);
        var installations: usize = 0;
        for (safe.program.blocks) |block|
            if (block.terminator == .handle) {
                installations += 1;
            };
        try testing.expectEqual(@as(usize, 2), installations);
        try testing.expect(safe.program.functions.len < off.program.functions.len);
    }
}

test "coalescing shares suspending cleanup code without merging protection installations" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const module = try @import("authoring_cases.zig").build(&builder, .shared_cleanup);
    var original = try frozen.get(testing.allocator, "shared_cleanup");
    defer original.deinit();
    var compiled = try source.lower(testing.allocator, module);
    defer compiled.deinit();
    for ([_]data.activation.Program{ original.program, compiled.program }, 0..) |program, index| {
        try testing.expectEqual(@as(usize, if (index == 0) 5 else 4), program.functions.len);
        try testing.expectEqual(@as(usize, if (index == 0) 4 else 3), program.constructors.len);
        var protections: usize = 0;
        for (program.blocks) |block| protections += @intFromBool(block.terminator == .protect);
        try testing.expectEqual(@as(usize, 2), protections);
    }
}

test "coalescing shares recursive helpers inside local and shared multi-shot state" {
    const cases = @import("authoring_cases.zig");
    for ([_]cases.Kind{ .state_recursive_local, .state_recursive_shared }) |kind| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try cases.build(&builder, kind);
        var off = try frozen.kind(testing.allocator, "", kind);
        defer off.deinit();
        var safe = try source.lower(testing.allocator, module);
        defer safe.deinit();
        try testing.expect(safe.program.functions.len < off.program.functions.len);
        for ([_]data.activation.Program{ off.program, safe.program }) |program| {
            var cells: usize = 0;
            for (program.blocks) |block| for (block.instructions) |operation| {
                cells += @intFromBool(operation.opcode == .cell_new);
            };
            try testing.expectEqual(@as(usize, 1), cells);
        }
    }
}

test "coalescing retains valid distinct caller provenance and rejects an escaping loan" {
    for ([_]bool{ false, true }) |escape| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try @import("coalescing_borrow_cases.zig").build(&builder, escape);
        {
            const result = source.lowerObserved(testing.allocator, module, .{});
            if (escape) {
                try testing.expectError(error.InvalidOwnership, result);
            } else {
                var compiled = try result;
                defer compiled.deinit();
                try testing.expectEqual(@as(usize, 7), compiled.program.functions.len);
            }
        }
    }
}

fn richAllocationCase(allocator: std.mem.Allocator, program: data.activation.Program) !void {
    var diagnostic: data.coalescing.Diagnostic = .{};
    var stats: data.coalescing.Statistics = .{};
    var result = data.coalescing.run(allocator, program, .{
        .diagnostic = &diagnostic,
        .statistics = &stats,
    }) catch |err| {
        try testing.expectEqual(err, diagnostic.code.?);
        try testing.expectEqual(err, stats.failed_check.?);
        return err;
    };
    defer result.deinit();
    try testing.expectEqual(@as(?anyerror, null), diagnostic.code);
    try testing.expectEqual(@as(?anyerror, null), stats.failed_check);
}

test "coalescing allocation failures cover handlers constructors regions resources and recursive custody" {
    const cases = @import("authoring_cases.zig");
    for ([_]cases.Kind{ .shared_cleanup, .state_recursive_local, .borrow_contexts }) |kind| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var baseline = try frozen.kind(testing.allocator, "", kind);
        defer baseline.deinit();
        const before = try data.program_image.identity(testing.allocator, baseline.program);
        try @import("allocation_testing.zig").check(testing.allocator, richAllocationCase, .{baseline.program});
        try testing.expectEqual(before, try data.program_image.identity(testing.allocator, baseline.program));
    }
}
