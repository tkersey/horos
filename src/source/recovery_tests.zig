// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const data = @import("horos_data");
const a = std.testing.allocator;

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

test "source recovery retains binding aliases through checked function coalescing" {
    var b = source.Builder.init(a);
    defer b.deinit();
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
    const result = try b.pure(try b.primitive(pair, .product, &.{ try b.reference(left), try b.reference(right) }, 0));
    try b.define(entry, try b.bind(left, try b.term(.{ .call = .{ .function = first, .arguments = &.{try b.reference(b.parameter(entry, 0))} } }), try b.bind(right, try b.term(.{ .call = .{ .function = second, .arguments = &.{try b.reference(b.parameter(entry, 1))} } }), result)));
    var compiled = try source.lowerObserved(a, b.module(entry, unit), .{ .recovery = true });
    defer compiled.deinit();
    try source.recovery.validate(a, b.module(entry, unit), &compiled);
    var first_location: ?source.RecoveryBinding = null;
    var second_location: ?source.RecoveryBinding = null;
    for (compiled.recovery) |binding| {
        if (binding.source_function == first and binding.variable == b.parameter(first, 0)) first_location = binding;
        if (binding.source_function == second and binding.variable == b.parameter(second, 0)) second_location = binding;
        try std.testing.expectEqual(compiled.program.functions[@intCast(binding.function)].layout.slots[@intCast(binding.slot)], binding.schema);
    }
    try std.testing.expect(first_location != null and second_location != null);
    try std.testing.expectEqual(first_location.?.function, second_location.?.function);
    try std.testing.expectEqual(first_location.?.slot, second_location.?.slot);
    try std.testing.expectEqual(compiled.program.functions[@intCast(first_location.?.function)].inputs[0], first_location.?.slot);
    try std.testing.expectEqual(@as(usize, 2), compiled.program.functions.len);
    try std.testing.expectError(error.InvalidCorrespondence, source.lowerObserved(a, b.module(entry, unit), .{ .recovery = true, .contract = .semantic }));
    var bounded = try source.lowerObserved(a, b.module(entry, unit), .{ .recovery = true, .coalescing = .{ .work_limit = 0 } });
    defer bounded.deinit();
    for (bounded.recovery) |binding| {
        const target = bounded.program.functions[@intCast(binding.function)];
        if (binding.variable == b.parameter(binding.source_function, 0))
            try std.testing.expectEqual(target.inputs[0], binding.slot);
    }
    try source.recovery.validate(a, b.module(entry, unit), &bounded);

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
    try std.testing.expectError(error.InvalidCorrespondence, source.recovery.validate(a, b.module(entry, unit), &forged));
    parameters[0] = old;
    forged.parameters = parameters[1..];
    try std.testing.expectError(error.InvalidCorrespondence, source.recovery.validate(a, b.module(entry, unit), &forged));
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
    try std.testing.expectError(error.InvalidCorrespondence, source.recovery.validate(a, b.module(entry, unit), &forged));
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
    try b.define(f, try b.pure(try b.primitive(pair, .product, &.{ try b.reference(b.parameter(f, 0)), try b.reference(b.parameter(f, 1)) }, 0)));
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
    try std.testing.expectError(error.InvalidCorrespondence, source.recovery.validate(a, substituted, &forged));
}
