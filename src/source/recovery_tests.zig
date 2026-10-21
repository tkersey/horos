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

const QualifiedOwned = struct {
    bytes: []const u8 align(1),
    words: []align(1) const volatile u32 align(1),
    children: []align(1) const @This() align(1),
    flags: packed struct { low: u3, high: u5 },
};

fn checkQualifiedOwnership(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var storage: [9]u8 align(4) = undefined;
    const words: *align(1) [2]u32 = @ptrCast(&storage[1]);
    words.* = .{ 3, 7 };
    var bytes = [_]u8{ 'a', 'b', 'c' };
    const leaf: QualifiedOwned = .{
        .bytes = &bytes,
        .words = words,
        .children = &.{},
        .flags = .{ .low = 3, .high = 9 },
    };
    var root = leaf;
    root.children = &.{leaf};
    const copied = try source.own(QualifiedOwned, arena.allocator(), root);
    bytes[0] = 'z';
    words[0] = 99;
    for ([_]QualifiedOwned{ copied, copied.children[0] }) |node| {
        try std.testing.expectEqualSlices(u8, "abc", node.bytes);
        try std.testing.expectEqual(@as(u32, 3), node.words[0]);
        try std.testing.expectEqual(@as(u32, 7), node.words[1]);
        try std.testing.expectEqual(@as(u3, 3), node.flags.low);
        try std.testing.expectEqual(@as(u5, 9), node.flags.high);
    }
    try std.testing.expect(copied.bytes.ptr != copied.children[0].bytes.ptr);
    try std.testing.expect(copied.words.ptr != copied.children[0].words.ptr);
}

test "source ownership preserves qualified slices and underaligned fields" {
    try std.testing.checkAllAllocationFailures(a, checkQualifiedOwnership, .{});
}

const slicing = @import("slice.zig");

fn slicingModule(b: *source.Builder) !struct {
    module: source.Module,
    pure_entry: source.Id,
} {
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const service = try b.effect(.{ .identity = "live-service", .payload = word, .result = word });
    const live = try b.declare(&.{word}, word, &.{service}, &.{});
    const leaf = try b.declare(&.{word}, word, &.{}, &.{});
    const pure_entry = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(live, try b.term(.{ .perform = .{
        .effect = service,
        .payload = try b.reference(b.parameter(live, 0)),
    } }));
    try b.define(leaf, try b.pure(try b.reference(b.parameter(leaf, 0))));
    try b.define(pure_entry, try b.term(.{ .call = .{
        .function = leaf,
        .arguments = &.{try b.reference(b.parameter(pure_entry, 0))},
    } }));
    return .{ .module = b.module(live, unit), .pure_entry = pure_entry };
}

test "source slices own executable closure and remove unreachable bridge catalogs" {
    var b = source.Builder.init(a);
    const fixture = slicingModule(&b) catch |err| {
        b.deinit();
        return err;
    };
    var selected = slicing.extract(a, fixture.module, .{
        .entry = fixture.pure_entry,
        .require_pure = true,
    }) catch |err| {
        b.deinit();
        return err;
    };
    b.deinit();
    defer selected.deinit();
    const module = selected.module();
    try std.testing.expectEqual(@as(source.Id, 0), selected.original_entry);
    try std.testing.expectEqual(@as(source.Id, 2), selected.selected_entry);
    try std.testing.expectEqual(@as(usize, 0), module.effects.len);
    try std.testing.expectEqual(@as(usize, 2), module.functions.len);
    try std.testing.expectEqual(@as(usize, 2), module.variables.len);
    try std.testing.expectEqual(@as(?source.Id, null), selected.maps.functions[0]);
    try std.testing.expectEqual(@as(?source.Id, null), selected.maps.effects[0]);
    const entry = module.functions[@intCast(module.entry)];
    const body = module.terms[@intCast(entry.body.?)].call;
    try std.testing.expectEqual(selected.maps.functions[1].?, body.function);
    try std.testing.expectEqual(
        entry.parameters[0],
        module.values[@intCast(body.arguments[0])].expression.variable,
    );
    var compiled = try source.lower(a, module);
    defer compiled.deinit();
}

test "source slicing admits the full original before selecting a pure export" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const fixture = try slicingModule(&b);
    b.functions.items[0].body = null;
    try std.testing.expectError(error.UndefinedFunction, slicing.extract(a, b.module(
        fixture.module.entry,
        fixture.module.failure,
    ), .{ .entry = fixture.pure_entry, .require_pure = true }));
}

test "source slices cannot erase malformed unused effect declarations" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const fixture = try slicingModule(&b);
    b.effects.items[0].payload = b.schemas.items.len;
    try std.testing.expectError(error.InvalidSchema, slicing.extract(a, fixture.module, .{
        .entry = fixture.pure_entry,
        .require_pure = true,
    }));
}

test "source slicing rejects reachable external effects without hiding their declarations" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const fixture = try slicingModule(&b);
    try std.testing.expectError(error.ImpureSlice, slicing.extract(a, fixture.module, .{
        .entry = fixture.module.entry,
        .require_pure = true,
    }));
    var selected = try slicing.extract(a, fixture.module, .{ .entry = fixture.module.entry });
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.module().effects.len);
    try std.testing.expect(selected.module().effects[0].external);
}

test "source slices preserve handlers captures recursive calls and nominal resources" {
    for ([_]*const fn (*source.Builder) source.Error!source.Module{
        source.examples.deep,
        source.examples.lexical,
        source.examples.recursive,
        source.examples.resourceScalar,
    }) |build| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const module = try build(&b);
        var selected = try slicing.extract(a, module, .{ .entry = module.entry });
        defer selected.deinit();
        const retained = selected.module();
        try std.testing.expectEqual(module.handlers.len, retained.handlers.len);
        try std.testing.expectEqual(module.resources.len, retained.resources.len);
        try std.testing.expectEqual(module.region_count, retained.region_count);
        try std.testing.expectEqual(
            selected.maps.functions[@intCast(module.entry)].?,
            retained.entry,
        );
    }
}

fn checkSliceAllocation(allocator: std.mem.Allocator, module: source.Module) !void {
    var selected = try slicing.extract(allocator, module, .{ .entry = module.entry });
    defer selected.deinit();
}

test "source slicing releases partial owners on allocation failure" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const entry = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(void, {})));
    const module = b.module(entry, unit);
    try failingSliceAllocations(module);
    var raw_builder = source.Builder.init(a);
    defer raw_builder.deinit();
    try failingSliceAllocations((try rawSlice(&raw_builder)).module);
}

fn failingSliceAllocations(module: source.Module) !void {
    var counting = std.testing.FailingAllocator.init(a, .{});
    try checkSliceAllocation(counting.allocator(), module);
    for (0..counting.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        checkSliceAllocation(failing.allocator(), module) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "source slices retain sparse nominal region identities without count-sized allocation" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const fixture = try slicingModule(&b);
    var module = fixture.module;
    module.region_count = std.math.maxInt(source.Id);
    var selected = try slicing.extract(a, module, .{
        .entry = fixture.pure_entry,
        .require_pure = true,
    });
    defer selected.deinit();
    try std.testing.expectEqual(module.region_count, selected.module().region_count);
    try std.testing.expectEqual(@as(usize, 0), selected.maps.regions.len);
}

const RawSlice = struct { module: source.Module, generator: u64, target: u64, raw: u64 };

fn rawSlice(b: *source.Builder) !RawSlice {
    const unit = try b.scalar(void);
    const word = try b.scalar(u8);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = pair,
        .capture_bound = &.{word},
    } } });
    const bridge = try b.effect(.{
        .identity = "source-slice/registration-bridge",
        .payload = unit,
        .result = unit,
        .external = true,
    });
    _ = try b.variable(word);
    const generator = try b.declare(&.{ word, word }, computation, &.{bridge}, &.{});
    const target = try b.declare(&.{}, pair, &.{}, &.{});
    const first = try b.reference(b.parameter(generator, 0));
    const second = try b.reference(b.parameter(generator, 1));
    try b.define(target, try b.pure(try b.primitive(pair, .product, &.{ first, second }, 0)));
    const ignored = try b.variable(unit);
    try b.define(generator, try b.bind(ignored, try b.term(.{ .perform = .{
        .effect = bridge,
        .payload = try b.constant(void, {}),
    } }), try b.pure(try b.lambda(target, computation))));
    const entry = try b.declare(&.{}, pair, &.{}, &.{});
    const raw = try b.primitive(computation, .computation, &.{
        try b.constant(u8, 11),
        try b.constant(u8, 22),
    }, 0);
    try b.define(entry, try b.term(.{ .apply = .{ .computation = raw, .arguments = &.{} } }));
    return .{
        .module = b.module(entry, unit),
        .generator = generator,
        .target = target,
        .raw = raw,
    };
}

test "source slices retain supplied captures while replacing registration-only bridge functions" {
    const bindings = @import("constructor_bindings.zig");
    var b = source.Builder.init(a);
    defer b.deinit();
    const fixture = try rawSlice(&b);
    var selected = try slicing.extract(a, fixture.module, .{
        .entry = fixture.module.entry,
        .require_pure = true,
    });
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.generated_functions);
    try std.testing.expectEqual(
        @as(?u64, null),
        selected.maps.functions[@intCast(fixture.generator)],
    );
    try std.testing.expectEqual(@as(?u64, null), selected.maps.variables[0]);
    const module = selected.module();
    try std.testing.expectEqual(@as(usize, 0), module.effects.len);
    var work: u64 = 1_000_000;
    const constructors = try bindings.admit(a, b.allocator(), module, &work);
    try std.testing.expectEqual(
        selected.maps.functions[@intCast(fixture.target)].?,
        constructors[0].function,
    );
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 }, constructors[0].captures);
    const value = module.values[@intCast(selected.maps.values[@intCast(fixture.raw)].?)];
    try std.testing.expectEqual(@as(u64, 0), value.expression.primitive.immediate);
    for (value.expression.primitive.operands, [_]u8{ 11, 22 }) |operand, expected| {
        const literal = module.values[@intCast(operand)].expression.literal;
        try std.testing.expectEqualSlices(
            u8,
            &.{expected},
            module.constants[@intCast(literal)].bytes,
        );
    }
    try rejectCapturePermutation(b.allocator(), fixture.module);
}

fn rejectCapturePermutation(allocator: std.mem.Allocator, module: source.Module) !void {
    var maps: source.relation.Relocation.Maps = .{ .region_count = module.region_count };
    inline for (.{
        "schemas",   "constants", "effects", "handlers",  "resources",
        "variables", "values",    "terms",   "functions",
    }) |name| {
        const entries = try allocator.alloc(?u64, @field(module, name).len);
        for (entries, 0..) |*entry, index| entry.* = index;
        @field(maps, name) = entries;
    }
    std.mem.swap(?u64, &@constCast(maps.variables)[1], &@constCast(maps.variables)[2]);
    const changed = try source.relation.Relocation.relocate(allocator, module, maps);
    const steps = [_]source.relation.Step{.{
        .successor = changed,
        .rule = .{ .relocation = maps },
    }};
    try std.testing.expectError(
        error.UnsupportedRelation,
        source.relation.validate(a, module, changed, &steps, .{}),
    );
}

fn emittedConstantModule(b: *source.Builder, failure: bool) !source.Module {
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "emitted-constant/dispose",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const resumption = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = unit,
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const dispose = try b.declare(&.{resumption}, unit, &.{}, &.{});
    try b.define(dispose, try b.term(.{ .dispose = try b.reference(b.parameter(dispose, 0)) }));
    const entry = try b.declare(
        if (failure) &.{ word, word } else &.{},
        if (failure) word else unit,
        &.{},
        &.{},
    );
    const value = if (failure) try b.value(.{
        .schema = word,
        .expression = .{ .primitive = .{
            .opcode = .integer_div,
            .operands = &.{
                try b.reference(b.parameter(entry, 0)),
                try b.reference(b.parameter(entry, 1)),
            },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = 0 },
                .{ .kind = .division_by_zero, .value = 0 },
            },
        } },
    }) else try b.primitive(unit, .constant, &.{}, 0);
    try b.define(entry, try b.pure(value));
    return b.module(entry, unit);
}

fn identityRelocation(
    allocator: std.mem.Allocator,
    module: source.Module,
) !source.relation.Relocation.Maps {
    var maps: source.relation.Relocation.Maps = .{ .region_count = module.region_count };
    inline for (.{
        "schemas",   "constants", "effects", "handlers",  "resources",
        "variables", "values",    "terms",   "functions",
    }) |name| {
        const entries = try allocator.alloc(?u64, @field(module, name).len);
        for (entries, 0..) |*entry, index| entry.* = index;
        @field(maps, name) = entries;
    }
    return maps;
}

test "source relocation and pure slices retain emitted constants and failure literals" {
    for ([_]bool{ false, true }) |failure| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const module = try emittedConstantModule(&b, failure);
        try std.testing.expectEqual(@as(usize, 0), module.constants.len);
        var work: u64 = 1_000_000;
        try source.admitWithWork(a, module, &work);
        const maps = try identityRelocation(b.allocator(), module);
        const relocated = try source.relation.Relocation.relocate(b.allocator(), module, maps);
        try std.testing.expectEqual(@as(usize, 1), relocated.constants.len);
        try source.relation.validate(a, module, relocated, &.{.{
            .successor = relocated,
            .rule = .{ .relocation = maps },
        }}, .{});
        var selected = try slicing.extract(a, module, .{
            .entry = module.entry,
            .require_pure = true,
        });
        defer selected.deinit();
        try std.testing.expectEqual(@as(usize, 0), selected.maps.constants.len);
        try std.testing.expectEqualSlices(?u64, &.{0}, selected.emitted_constants);
        try std.testing.expectEqual(@as(usize, 1), selected.module().constants.len);
        try std.testing.expectEqual(@as(usize, 1), selected.module().functions.len);
        try std.testing.expectEqual(@as(usize, 0), selected.module().effects.len);
        var compiled = try source.lower(a, selected.module());
        defer compiled.deinit();
        try std.testing.expectEqual(@as(usize, 1), compiled.program.constants.len);
    }
}

test "source relocation preserves emitted constants through schema permutation" {
    var b = source.Builder.init(a);
    defer b.deinit();
    _ = try emittedConstantModule(&b, false);
    try b.schemas.append(b.allocator(), .unit);
    const module = b.module(1, 0);
    var work: u64 = 1_000_000;
    try source.admitWithWork(a, module, &work);
    const maps = try identityRelocation(b.allocator(), module);
    const last = maps.schemas.len - 1;
    std.mem.swap(?u64, &@constCast(maps.schemas)[0], &@constCast(maps.schemas)[last]);
    const relocated = try source.relation.Relocation.relocate(b.allocator(), module, maps);
    try std.testing.expectEqual(@as(u64, last), relocated.constants[0].schema);
    try source.relation.validate(a, module, relocated, &.{.{
        .successor = relocated,
        .rule = .{ .relocation = maps },
    }}, .{});
}

test "source relocation transports source constants beside emitted failure literals" {
    for ([_]bool{ false, true }) |failure| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const original = try emittedConstantModule(&b, failure);
        _ = try b.constant(u64, 11);
        _ = try b.constant(u64, 22);
        for (b.values.items) |*value| {
            if (value.expression != .primitive) continue;
            const primitive = &value.expression.primitive;
            if (primitive.opcode == .constant) primitive.immediate = 2;
            for (@constCast(primitive.failures)) |*item| item.value = 2;
        }
        const module = b.module(original.entry, original.failure);
        const maps = try identityRelocation(b.allocator(), module);
        std.mem.swap(?u64, &@constCast(maps.constants)[0], &@constCast(maps.constants)[1]);
        const relocated = try source.relation.Relocation.relocate(b.allocator(), module, maps);
        try std.testing.expectEqual(@as(usize, 3), relocated.constants.len);
        try std.testing.expectEqual(@as(u8, 22), relocated.constants[0].bytes[0]);
        try std.testing.expectEqual(@as(u8, 11), relocated.constants[1].bytes[0]);
        try source.relation.validate(a, module, relocated, &.{.{
            .successor = relocated,
            .rule = .{ .relocation = maps },
        }}, .{});
        var selected = try slicing.extract(a, module, .{
            .entry = module.entry,
            .require_pure = true,
        });
        defer selected.deinit();
        try std.testing.expectEqualSlices(?u64, &.{ null, null }, selected.maps.constants);
        try std.testing.expectEqualSlices(?u64, &.{ null, null, 0 }, selected.emitted_constants);
        try std.testing.expectEqual(@as(usize, 1), selected.module().constants.len);
    }
}

test "source relocation reserves generated nested records before owning their copies" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const parameter_schemas: [64]u64 = @splat(unit);
    const entry = try b.declare(&parameter_schemas, unit, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(void, {})));
    const module = b.module(entry, unit);
    const maps = try identityRelocation(b.allocator(), module);
    const generated: [16]source.ast.Function = @splat(module.functions[0]);
    @constCast(maps.functions)[0] = generated.len;
    const relocation = source.relation.Relocation;
    var work: u64 = 1_000;
    try std.testing.expectError(error.RelationLimit, relocation.relocateCatalogWithWork(
        b.allocator(),
        module,
        module.constants,
        maps,
        .{ .functions = &generated },
        &work,
    ));
    work = 0;
    try std.testing.expectError(error.RelationLimit, relocation.relocateWithWork(
        b.allocator(),
        module,
        maps,
        .{ .functions = &generated },
        &work,
    ));
    work = 1_000_000;
    const relocated = try relocation.relocateWithWork(
        b.allocator(),
        module,
        maps,
        .{ .functions = &generated },
        &work,
    );
    try std.testing.expect(1_000_000 - work >= generated.len * parameter_schemas.len);
    try std.testing.expect(relocated.functions[0].parameters.ptr != generated[0].parameters.ptr);
    try source.admitWithWork(a, relocated, &work);
}

fn checkEmittedRelocationAllocation(allocator: std.mem.Allocator, module: source.Module) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const maps = try identityRelocation(arena.allocator(), module);
    _ = try source.relation.Relocation.relocate(arena.allocator(), module, maps);
}

test "source emitted catalog copies release partial owners and respect zero work" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try emittedConstantModule(&b, false);
    try failingSliceAllocations(module);
    try @import("../allocation_testing.zig").check(a, checkEmittedRelocationAllocation, .{module});
    const maps = try identityRelocation(b.allocator(), module);
    var work: u64 = 0;
    try std.testing.expectError(error.RelationLimit, source.relation.Relocation.relocateWithWork(
        b.allocator(),
        module,
        maps,
        .{},
        &work,
    ));
}

test "source emitted catalog transport rejects malformed raw constant references" {
    for ([_]bool{ false, true }) |failure| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const module = try emittedConstantModule(&b, failure);
        for (b.values.items) |*value| {
            if (value.expression != .primitive) continue;
            const primitive = &value.expression.primitive;
            if (primitive.opcode == .constant) primitive.immediate = 99;
            for (@constCast(primitive.failures)) |*item| item.value = 99;
        }
        const maps = try identityRelocation(b.allocator(), module);
        const expected = if (failure) error.InvalidProgram else error.InvalidReference;
        try std.testing.expectError(expected, source.relation.Relocation.relocate(
            b.allocator(),
            module,
            maps,
        ));
        try std.testing.expectError(expected, slicing.extract(a, module, .{
            .entry = module.entry,
            .require_pure = true,
        }));
    }
}

test "source specialization relation covers retained emitted constant references" {
    for ([_]bool{ false, true }) |failure| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const module = try emittedConstantModule(&b, failure);
        const pe = source.specialize;
        const request: pe.Request = .{
            .context = .{
                .core = @splat(0),
                .guest = @splat(0),
                .observation = @splat(0),
                .base_profile = @splat(0),
                .admission_profile = @splat(0),
                .compiler_policy = @splat(0),
            },
            .function = module.entry,
            .arguments = if (failure) &.{ .dynamic, .dynamic } else &.{},
        };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        var work: u64 = 1_000_000;
        try source.admitWithWork(a, result.module(), &work);
        try pe.validate(a, module, request, &result);
        var step: source.relation.Step = .{
            .successor = result.module(),
            .rule = .{ .specialization = .{
                .request = request,
                .entry = result.entry,
                .functions = result.functions.items,
                .values = result.value_proofs.items,
                .terms = result.term_proofs.items,
            } },
        };
        try source.relation.validate(a, module, result.module(), &.{step}, .{});
        try result.builder.constants.append(result.builder.allocator(), .{
            .schema = module.failure,
            .bytes = &.{},
        });
        try result.builder.constants.append(result.builder.allocator(), .{
            .schema = 1,
            .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
        });
        step.successor = result.module();
        try source.admitWithWork(a, step.successor, &work);
        try pe.validate(a, module, request, &result);
        try std.testing.expectError(error.InvalidRelation, source.relation.validate(
            a,
            module,
            step.successor,
            &.{step},
            .{},
        ));
    }
}

test "source reference traversal follows compiler emitted constants into their schemas" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try emittedConstantModule(&b, false);
    const body = module.terms[@intCast(module.functions[@intCast(module.entry)].body.?)].value;
    const relocation = source.relation.Relocation;
    var references: std.ArrayList(relocation.Reference) = .empty;
    defer references.deinit(a);
    try relocation.visitReferences(a, module, .value, body, &references);
    try std.testing.expectEqualSlices(relocation.Reference, &.{
        .{ .kind = .schema, .id = module.failure },
        .{ .kind = .constant, .id = 0 },
    }, references.items);
    references.clearRetainingCapacity();
    try relocation.visitReferences(a, module, .constant, 0, &references);
    try std.testing.expectEqualSlices(relocation.Reference, &.{
        .{ .kind = .schema, .id = module.failure },
    }, references.items);
}
