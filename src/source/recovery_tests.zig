// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const data = @import("horos_data");
const a = std.testing.allocator;

test "source recovery bounds target domains before allocation" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const entry = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(entry, try b.pure(try b.reference(b.parameter(entry, 0))));
    var module = b.module(entry, unit);
    // Unused nominal names are valid source input, not stored region records.
    module.region_count = std.math.maxInt(u64);
    var compiled = try source.lowerObserved(a, module, .{ .recovery = true });
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u64, 0), compiled.program.scopes.region_count);
    var buffer: [1024 * 1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&buffer);
    try source.recovery.validate(bounded.allocator(), module, &compiled);
    for ([_]u64{ 1 << 30, std.math.maxInt(u64) }) |count| {
        var forged = compiled;
        forged.program.scopes.region_count = count;
        var admitted = try data.activation_ownership.analyze(a, forged.program);
        admitted.deinit();
        bounded.reset();
        try std.testing.expectError(
            error.InvalidCorrespondence,
            source.recovery.parameters(
                bounded.allocator(),
                module,
                forged.program,
                forged.recovery_evidence.?,
            ),
        );
        bounded.reset();
        try std.testing.expectError(
            error.InvalidCorrespondence,
            source.recovery.validate(bounded.allocator(), module, &forged),
        );
    }
}

test "source ownership preserves sentinel array storage" {
    var output = std.heap.ArenaAllocator.init(a);
    defer output.deinit();
    const copied = try source.own([3:99]u8, output.allocator(), .{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 99 }, std.mem.asBytes(&copied));
    const empty = try source.own([0:171]u8, output.allocator(), .{});
    try std.testing.expectEqualSlices(u8, &.{171}, std.mem.asBytes(&empty));
    const nested = try source.own([2][0:171]u8, output.allocator(), .{ .{}, .{} });
    try std.testing.expectEqualSlices(u8, &.{ 171, 171 }, std.mem.asBytes(&nested));
}

test "source specialization cache preserves sentinel array results" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const selected = try b.specialization([3:99]u8, "sentinel-array-result", .{});
    const first = try selected.finish(&b, .{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 99 }, std.mem.asBytes(&first));
    const cached = try b.specialization([3:99]u8, "sentinel-array-result", .{});
    try std.testing.expect(cached.cached != null);
    const second = try cached.finish(&b, .{ 4, 5, 6 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 99 }, std.mem.asBytes(&second));
}

test "source recovery evidence owns arrays of relocation slices" {
    var input = std.heap.ArenaAllocator.init(a);
    var output = std.heap.ArenaAllocator.init(a);
    defer output.deinit();
    const ids = try input.allocator().dupe(u64, &.{ 3, 7, 11 });
    const copied = try source.own([2][]const u64, output.allocator(), .{ ids[0..1], ids[1..] });
    @memset(ids, 99);
    input.deinit();
    try std.testing.expectEqualSlices(u64, &.{3}, copied[0]);
    try std.testing.expectEqualSlices(u64, &.{ 7, 11 }, copied[1]);
}

fn coalescedBindingModule(b: *source.Builder) !struct {
    module: source.Module,
    first: source.Id,
    second: source.Id,
} {
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const entry = try b.declare(&.{ word, word }, pair, &.{}, &.{});
    const first = try b.declare(&.{word}, word, &.{}, &.{});
    const second = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(first, try b.pure(try b.reference(b.parameter(first, 0))));
    try b.define(second, try b.pure(try b.reference(b.parameter(second, 0))));
    const left = try b.variable(word);
    const right = try b.variable(word);
    const result = try b.pure(try b.primitive(
        pair,
        .product,
        &.{ try b.reference(left), try b.reference(right) },
        0,
    ));
    try b.define(
        entry,
        try b.bind(
            left,
            try b.term(.{ .call = .{
                .function = first,
                .arguments = &.{try b.reference(b.parameter(entry, 0))},
            } }),
            try b.bind(
                right,
                try b.term(.{ .call = .{
                    .function = second,
                    .arguments = &.{try b.reference(b.parameter(entry, 1))},
                } }),
                result,
            ),
        ),
    );
    return .{ .module = b.module(entry, unit), .first = first, .second = second };
}

fn rejectForgedBindingParameters(module: source.Module, compiled: source.Compiled) !void {
    // A different same-typed input is not an admissible recovery substitution.
    const parameters = try a.dupe(source.RecoveryBinding, compiled.parameters);
    defer a.free(parameters);
    var forged = compiled;
    forged.parameters = parameters;
    const old = parameters[0];
    const target = compiled.program.functions[@intCast(old.function)];
    try std.testing.expectEqual(@as(usize, 2), target.inputs.len);
    parameters[0].slot = target.inputs[1];
    try std.testing.expectEqual(target.layout.slots[@intCast(parameters[0].slot)], old.schema);
    try std.testing.expectError(
        error.InvalidCorrespondence,
        source.recovery.validate(a, module, &forged),
    );
    parameters[0] = old;
    forged.parameters = parameters[1..];
    try std.testing.expectError(
        error.InvalidCorrespondence,
        source.recovery.validate(a, module, &forged),
    );
    forged.parameters = parameters;

    // Altering actual final input records remains well typed. Checking merely
    // the map's schema or a producer-supplied digest would miss this change.
    const functions = try a.dupe(data.activation.Function, compiled.program.functions);
    defer a.free(functions);
    const reversed = [_]u64{ target.inputs[1], target.inputs[0] };
    functions[@intCast(old.function)].inputs = &reversed;
    forged.program.functions = functions;
    var admitted = try data.activation_ownership.analyze(a, forged.program);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidCorrespondence,
        source.recovery.validate(a, module, &forged),
    );
}

test "source recovery retains binding aliases through checked function coalescing" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const fixture = try coalescedBindingModule(&b);
    const module = fixture.module;
    const first = fixture.first;
    const second = fixture.second;
    var compiled = try source.lowerObserved(a, module, .{ .recovery = true });
    defer compiled.deinit();
    try source.recovery.validate(a, module, &compiled);
    var first_location: ?source.RecoveryBinding = null;
    var second_location: ?source.RecoveryBinding = null;
    for (compiled.recovery) |binding| {
        if (binding.source_function == first and binding.variable == b.parameter(
            first,
            0,
        )) first_location = binding;
        if (binding.source_function == second and binding.variable == b.parameter(
            second,
            0,
        )) second_location = binding;
        try std.testing.expectEqual(
            compiled.program.functions[
                @intCast(binding.function)
            ].layout.slots[
                @intCast(binding.slot)
            ],
            binding.schema,
        );
    }
    try std.testing.expect(first_location != null and second_location != null);
    try std.testing.expectEqual(first_location.?.function, second_location.?.function);
    try std.testing.expectEqual(first_location.?.slot, second_location.?.slot);
    try std.testing.expectEqual(
        compiled.program.functions[@intCast(first_location.?.function)].inputs[0],
        first_location.?.slot,
    );
    try std.testing.expectEqual(@as(usize, 2), compiled.program.functions.len);
    try std.testing.expectError(
        error.InvalidCorrespondence,
        source.lowerObserved(
            a,
            module,
            .{ .recovery = true, .contract = .semantic },
        ),
    );
    var bounded = try source.lowerObserved(
        a,
        module,
        .{ .recovery = true, .coalescing = .{ .work_limit = 0 } },
    );
    defer bounded.deinit();
    for (bounded.recovery) |binding| {
        const target = bounded.program.functions[@intCast(binding.function)];
        if (binding.variable == b.parameter(binding.source_function, 0))
            try std.testing.expectEqual(target.inputs[0], binding.slot);
    }
    try source.recovery.validate(a, module, &bounded);

    try rejectForgedBindingParameters(module, compiled);
}

test "source recovery derives formal parameters after captured inputs" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try source.examples.branchingTail(&b);
    var ordinary = try source.lower(a, module);
    defer ordinary.deinit();
    var tail_selected = false;
    for (ordinary.program.handlers) |handler| for (handler.clauses) |clause| {
        tail_selected = tail_selected or clause.strategy == .tail;
    };
    try std.testing.expect(tail_selected);
    var compiled = try source.lowerObserved(a, module, .{ .recovery = true });
    defer compiled.deinit();
    try source.recovery.validate(a, module, &compiled);
    // The body captures the main function's boolean before its own capability
    // parameter. Its formal parameter is not the first lowered input.
    var found = false;
    for (compiled.parameters) |binding| if (binding.source_function == 1) {
        found = true;
        try std.testing.expectEqual(module.functions[1].parameters[0], binding.variable);
        const target = compiled.program.functions[@intCast(binding.function)];
        try std.testing.expectEqual(@as(usize, 2), target.inputs.len);
        try std.testing.expectEqual(target.inputs[1], binding.slot);
    };
    try std.testing.expect(found);
}

test "source recovery rejects a same-typed source parameter permutation" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const f = try b.declare(&.{ word, word }, pair, &.{}, &.{});
    try b.define(
        f,
        try b.pure(try b.primitive(
            pair,
            .product,
            &.{ try b.reference(b.parameter(f, 0)), try b.reference(b.parameter(f, 1)) },
            0,
        )),
    );
    const module = b.module(f, unit);
    var compiled = try source.lowerObserved(a, module, .{ .recovery = true });
    defer compiled.deinit();
    const functions = try a.dupe(source.ast.Function, module.functions);
    defer a.free(functions);
    const reversed = [_]u64{ b.parameter(f, 1), b.parameter(f, 0) };
    functions[@intCast(f)].parameters = &reversed;
    var substituted = module;
    substituted.functions = functions;
    var admitted = try source.lower(a, substituted);
    defer admitted.deinit();
    const parameters = try a.dupe(source.RecoveryBinding, compiled.parameters);
    defer a.free(parameters);
    try std.testing.expectEqual(@as(usize, 2), parameters.len);
    for (parameters, reversed) |*binding, variable| binding.variable = variable;
    var forged = compiled;
    forged.parameters = parameters;
    try std.testing.expectError(
        error.InvalidCorrespondence,
        source.recovery.validate(a, substituted, &forged),
    );
}

const OwnedRecursive = union(enum) {
    branch: []const OwnedRecursive,
    leaf: struct {
        aliases: [2][]const u8,
        optional: ?[]const u8,
        empty: ?[]const u8,
        scalar: u64,
        sentinel: [0:171]u8,
    },
};

fn checkRecursiveOwnership(
    allocator: std.mem.Allocator,
    original: OwnedRecursive,
    depth: usize,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const copied = try source.own(OwnedRecursive, arena.allocator(), original);
    var before = original;
    var after = copied;
    for (0..depth) |_| {
        try std.testing.expect(before.branch.ptr != after.branch.ptr);
        try std.testing.expectEqual(@as(usize, 1), after.branch.len);
        before = before.branch[0];
        after = after.branch[0];
    }
    const leaf = after.leaf;
    try std.testing.expectEqualSlices(u8, "owned", leaf.aliases[0]);
    try std.testing.expectEqualSlices(u8, "owned", leaf.aliases[1]);
    try std.testing.expectEqualSlices(u8, "owned", leaf.optional.?);
    try std.testing.expect(leaf.aliases[0].ptr != before.leaf.aliases[0].ptr);
    try std.testing.expect(leaf.aliases[0].ptr != leaf.aliases[1].ptr);
    try std.testing.expect(leaf.aliases[0].ptr != leaf.optional.?.ptr);
    try std.testing.expect(leaf.empty == null);
    try std.testing.expectEqual(@as(u64, 42), leaf.scalar);
    try std.testing.expectEqualSlices(u8, &.{171}, std.mem.asBytes(&leaf.sentinel));
    @constCast(leaf.aliases[0])[0] = 'O';
    try std.testing.expectEqualSlices(u8, "owned", leaf.aliases[1]);
    try std.testing.expectEqualSlices(u8, "owned", before.leaf.aliases[0]);
}

test "source ownership copies deep recursive generic values with allocation failures" {
    const nodes = try a.alloc(OwnedRecursive, 4097);
    defer a.free(nodes);
    nodes[0] = .{ .leaf = .{
        .aliases = .{ "owned", "owned" },
        .optional = "owned",
        .empty = null,
        .scalar = 42,
        .sentinel = .{},
    } };
    for (nodes[1..], 1..) |*node, index| node.* = .{ .branch = nodes[index - 1 .. index] };
    try checkRecursiveOwnership(a, nodes[nodes.len - 1], nodes.len - 1);
    try std.testing.checkAllAllocationFailures(
        a,
        checkRecursiveOwnership,
        .{ nodes[nodes.len - 1], nodes.len - 1 },
    );
}

fn checkSpecializationOwnership(allocator: std.mem.Allocator) !void {
    const pe = source.specialize;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const fields: []const pe.Knowledge = &.{
        .{ .known = .{ .schema = 3, .bytes = "source" } },
        .dynamic,
    };
    const arguments: []const pe.Knowledge = &.{.{ .product = .{ .schema = 7, .fields = fields } }};
    const requested: pe.Request = .{
        .context = std.mem.zeroes(pe.Context),
        .function = 8,
        .arguments = arguments,
    };
    const copied = try source.own(pe.Request, arena.allocator(), requested);
    const copied_slice = try source.own([]const pe.Knowledge, arena.allocator(), arguments);
    try std.testing.expectEqualDeep(requested.context, copied.context);
    try std.testing.expectEqualDeep(requested.policy, copied.policy);
    try std.testing.expectEqual(requested.function, copied.function);
    for ([_][]const pe.Knowledge{ copied.arguments, copied_slice }) |values| {
        try std.testing.expect(values.ptr != arguments.ptr);
        try std.testing.expectEqual(@as(u64, 7), values[0].product.schema);
        const children = values[0].product.fields;
        try std.testing.expect(children.ptr != fields.ptr);
        try std.testing.expectEqual(@as(usize, 2), children.len);
        try std.testing.expectEqual(@as(u64, 3), children[0].known.schema);
        try std.testing.expectEqualSlices(u8, "source", children[0].known.bytes);
        try std.testing.expect(children[0].known.bytes.ptr != fields[0].known.bytes.ptr);
        try std.testing.expect(children[1] == .dynamic);
    }
}

test "source ownership accepts public specialization requests and knowledge slices" {
    try std.testing.checkAllAllocationFailures(a, checkSpecializationOwnership, .{});
}

fn checkOwnedBytes(allocator: std.mem.Allocator) !void {
    const copied = try source.own([]const u8, allocator, "independent");
    defer allocator.free(copied);
    try std.testing.expectEqualSlices(u8, "independent", copied);
}

test "source ownership releases temporary traversal storage on every outcome" {
    try std.testing.checkAllAllocationFailures(a, checkOwnedBytes, .{});
}
