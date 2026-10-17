// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;
const pe = source.specialize;
const context: pe.Context = .{ .core = @splat(1), .guest = @splat(2), .observation = @splat(3), .base_profile = @splat(4), .admission_profile = @splat(5), .compiler_policy = @splat(6) };
fn known(value: u64, storage: *[8]u8, schema: p.Id) pe.Knowledge {
    std.mem.writeInt(u64, storage, value, .little);
    return .{ .known = .{ .schema = schema, .bytes = storage } };
}
test "specialization renaming preserves lexical shadowing and rejects capture" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |shadows_source| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const word = try b.scalar(u64);
        const f = try b.declare(&.{word}, word, &.{}, &.{});
        const x = b.parameter(f, 0);
        const y = if (shadows_source) x else try b.variable(word);
        try b.define(f, try b.bind(y, try b.pure(try b.constant(u64, 42)), try b.pure(try b.reference(x))));
        const module = b.module(f, unit);
        const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{.dynamic} };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        const residual = result.module().functions[@intCast(result.entry)];
        result.builder.terms.items[@intCast(residual.body.?)].bind.variable = residual.parameters[0];
        // Both candidates are legal source. Only the first changes which
        // source binding the final reference denotes.
        var admitted = try source.lower(a, result.module());
        defer admitted.deinit();
        if (shadows_source) {
            try pe.validate(a, module, request, &result);
        } else try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, module, request, &result));
    }
}

test "specialization rejects capture through unpack and both sum branch forms" {
    const a = std.testing.allocator;
    for (0..3) |kind| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const word = try b.scalar(u64);
        const shape = try b.schema(if (kind == 0) .{ .product = &.{word} } else .{ .sum = &.{ word, word } });
        const f = try b.declare(&.{ word, shape }, word, &.{}, &.{});
        const x = b.parameter(f, 0);
        const input = try b.reference(b.parameter(f, 1));
        const y = try b.variable(word);
        const finish = try b.pure(try b.reference(x));
        try b.define(f, try b.term(if (kind == 0)
            .{ .unpack_product = .{ .value = input, .variables = &.{y}, .body = finish } }
        else
            .{ .match_sum = .{ .value = input, .cases = &.{ .{ .variable = y, .body = finish }, .{ .variable = try b.variable(word), .body = finish } } } }));
        const module = b.module(f, unit);
        const arguments = [_]pe.Knowledge{ .dynamic, if (kind == 2) .{ .known = .{ .schema = shape, .bytes = &.{ 0, 42, 0, 0, 0, 0, 0, 0, 0 } } } else .dynamic };
        const request: pe.Request = .{ .context = context, .function = f, .arguments = &arguments };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        const residual = result.module().functions[@intCast(result.entry)];
        const term = &result.builder.terms.items[@intCast(residual.body.?)];
        switch (kind) {
            0 => @constCast(term.unpack_product.variables)[0] = residual.parameters[0],
            1 => @constCast(term.match_sum.cases)[0].variable = residual.parameters[0],
            else => term.bind.variable = residual.parameters[0],
        }
        var admitted = try source.lower(a, result.module());
        defer admitted.deinit();
        try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, module, request, &result));
    }
}

test "specialization preserves ordered dynamic parameter identity" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{ word, word }, word, &.{}, &.{});
    try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
    const module = b.module(f, unit);
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{ .dynamic, .dynamic } };
    var result = try pe.specialize(a, module, request);
    defer result.deinit();
    const parameters = @constCast(result.builder.functions.items[@intCast(result.entry)].parameters);
    std.mem.swap(p.Id, &parameters[0], &parameters[1]);
    var admitted = try source.lower(a, result.module());
    defer admitted.deinit();
    try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, module, request, &result));
    std.mem.swap(p.Id, &parameters[0], &parameters[1]);
    parameters[1] = parameters[0];
    // Duplicate formals are already rejected by ordinary source admission.
    try std.testing.expectError(error.InvalidSource, pe.validate(a, module, request, &result));
}

test "non-exportable aggregate constructors remain residual" {
    const a = std.testing.allocator;
    for (0..3) |kind| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const word = try b.scalar(u64);
        const closure = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = unit } } });
        const aggregate = try b.schema(switch (kind) {
            0 => .{ .sum = &.{ unit, closure } },
            1 => .{ .seq = closure },
            else => .{ .array = .{ .element = closure, .length = 0 } },
        });
        const f = try b.declare(&.{}, word, &.{}, &.{});
        const value = if (kind == 0)
            try b.primitive(aggregate, .variant, &.{try b.constant(void, {})}, 0)
        else
            try b.primitive(aggregate, .sequence, &.{}, 0);
        try b.define(f, try b.pure(try b.primitive(word, if (kind == 0) .variant_tag else .sequence_length, &.{value}, 0)));
        const module = b.module(f, unit);
        var original = try source.lower(a, module);
        defer original.deinit();
        const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{} };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        var seen = false;
        for (result.value_proofs.items) |proof| if (proof.before == value) {
            seen = true;
            try std.testing.expect(!proof.folded);
            try std.testing.expectEqual(.primitive, std.meta.activeTag(result.module().values[@intCast(proof.after)].expression));
        };
        try std.testing.expect(seen);
        var residual = try source.lower(a, result.module());
        defer residual.deinit();
    }
}

test "source specialization reserves recursive keys and retains dynamic arithmetic" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const u64_type = try b.scalar(u64);
    const bool_type = try b.scalar(bool);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const f = try b.declare(&.{ u64_type, u64_type }, u64_type, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const factor = try b.reference(b.parameter(f, 1));
    const zero = try b.constant(u64, 0);
    const one = try b.constant(u64, 1);
    const stop = try b.primitive(bool_type, .equal, &.{ x, zero }, 0);
    const reduced = try b.value(.{ .schema = u64_type, .expression = .{ .primitive = .{ .opcode = .integer_sub, .operands = &.{ x, one }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }} } } });
    const recurse = try b.term(.{ .call = .{ .function = f, .arguments = &.{ reduced, factor } } });
    const finish = try b.pure(factor);
    try b.define(f, try b.term(.{ .conditional = .{ .condition = stop, .when_true = finish, .when_false = recurse } }));
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{ .dynamic, known(7, &bytes, u64_type) } };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.functions.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.module().functions[@intCast(result.entry)].parameters.len);
    var compiled = try source.lower(a, result.module());
    defer compiled.deinit();
    const proof = &result.value_proofs.items[result.value_proofs.items.len - 1];
    const saved = proof.before;
    proof.before = 0;
    try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, b.module(f, unit), request, &result));
    proof.before = saved;
    var changed = request;
    changed.context.guest[0] ^= 1;
    try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, b.module(f, unit), changed, &result));
}
test "source specialization selects known condition and checks forged literal" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{boolean}, word, &.{}, &.{});
    const condition = try b.reference(b.parameter(f, 0));
    const yes = try b.pure(try b.constant(u64, 11));
    const no = try b.pure(try b.constant(u64, 19));
    try b.define(f, try b.term(.{ .conditional = .{ .condition = condition, .when_true = yes, .when_false = no } }));
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{.{ .known = .{ .schema = boolean, .bytes = &.{1} } }} };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = &result.term_proofs.items[result.term_proofs.items.len - 1];
    try std.testing.expectEqual(@as(?usize, 0), last.selected);
    last.selected = 1;
    try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, b.module(f, unit), request, &result));
    last.selected = 0;
    var small = request;
    small.policy.work = 0;
    try std.testing.expectError(error.SpecializationLimit, pe.specialize(a, b.module(f, unit), small));
}

test "partly known record folds bound fields without dropping a failing sibling" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const input = try b.reference(b.parameter(f, 0));
    const one = try b.constant(u64, 1);
    const seven = try b.constant(u64, 7);
    const divide = try b.value(.{ .schema = word, .expression = .{ .primitive = .{ .opcode = .integer_div, .operands = &.{ one, input }, .failures = &.{ .{ .kind = .arithmetic_overflow, .value = failure }, .{ .kind = .division_by_zero, .value = failure } } } } });
    const product = try b.primitive(pair, .product, &.{ divide, seven }, 0);
    const projection = try b.primitive(word, .field, &.{product}, 1);
    try b.define(f, try b.pure(projection));
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{.dynamic} };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = result.value_proofs.items[result.value_proofs.items.len - 1];
    try std.testing.expect(!last.folded);
    try std.testing.expectEqual(.field, result.module().values[@intCast(last.after)].expression.primitive.opcode);
    // A bound record has already evaluated every sibling; its static field is
    // then safe to substitute while the original binding remains in the code.
    const bound = try b.variable(pair);
    const read = try b.reference(bound);
    const field = try b.primitive(word, .field, &.{read}, 1);
    const body = try b.bind(bound, try b.pure(product), try b.pure(field));
    b.functions.items[@intCast(f)].body = body;
    var bound_result = try pe.specialize(a, b.module(f, unit), request);
    defer bound_result.deinit();
    const folded = bound_result.value_proofs.items[bound_result.value_proofs.items.len - 1];
    try std.testing.expect(folded.folded);
    try std.testing.expectEqual(.bind, std.meta.activeTag(bound_result.module().terms[@intCast(bound_result.module().functions[@intCast(bound_result.entry)].body.?)]));
}

test "specialization retains effects and rejects an effect substitution" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const effect = try b.effect(.{ .identity = "specialize/test", .payload = word, .result = word, .external = true, .control_use = .linear });
    const f = try b.declare(&.{word}, word, &.{effect}, &.{});
    const argument = try b.reference(b.parameter(f, 0));
    try b.define(f, try b.term(.{ .perform = .{ .effect = effect, .payload = argument } }));
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{known(41, &bytes, word)} };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const term = result.module().terms[@intCast(result.module().functions[@intCast(result.entry)].body.?)];
    try std.testing.expectEqual(effect, term.perform.effect);
    // The checker rejects an effect substitution even if a caller recomputes
    // the content digest; the local derivation binds the actual source effect.
    const at = result.module().functions[@intCast(result.entry)].body.?;
    result.builder.terms.items[@intCast(at)] = .{ .value = term.perform.payload };
    try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, b.module(f, unit), request, &result));
}

test "static tag selection and normalized structured keys have checked payloads" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const sum = try b.schema(.{ .sum = &.{ unit, word } });
    const f = try b.declare(&.{sum}, word, &.{}, &.{});
    const tag = try b.reference(b.parameter(f, 0));
    const none = try b.variable(unit);
    const some = try b.variable(word);
    const empty = try b.pure(try b.constant(u64, 0));
    const full = try b.pure(try b.reference(some));
    try b.define(f, try b.term(.{ .match_sum = .{ .value = tag, .cases = &.{ .{ .variable = none, .body = empty }, .{ .variable = some, .body = full } } } }));
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{.{ .known = .{ .schema = sum, .bytes = &.{ 1, 7, 0, 0, 0, 0, 0, 0, 0 } } }} };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = &result.term_proofs.items[result.term_proofs.items.len - 1];
    try std.testing.expectEqual(@as(?usize, 1), last.selected);
    last.selected = 0;
    try std.testing.expectError(error.InvalidSpecialization, pe.validate(a, b.module(f, unit), request, &result));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var work: u64 = 100;
    var bytes: [8]u8 = undefined;
    const structured: pe.Knowledge = .{ .product = .{ .schema = 4, .fields = &.{known(17, &bytes, word)} } };
    const normal = try pe.values.normalize(arena.allocator(), structured, &work);
    try std.testing.expectEqualSlices(u8, &bytes, normal.known.bytes);
}

test "static recursion generalizes at the compiler key allowance" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const zero = try b.constant(u64, 0);
    const one = try b.constant(u64, 1);
    const condition = try b.primitive(boolean, .equal, &.{ x, zero }, 0);
    const reduced = try b.value(.{ .schema = word, .expression = .{ .primitive = .{ .opcode = .integer_sub, .operands = &.{ x, one }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }} } } });
    const recurse = try b.term(.{ .call = .{ .function = f, .arguments = &.{reduced} } });
    const end = try b.pure(zero);
    try b.define(f, try b.term(.{ .conditional = .{ .condition = condition, .when_true = end, .when_false = recurse } }));
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{known(20, &bytes, word)}, .policy = .{ .keys_per_function = 2 } };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.functions.items.len);
    var generic_calls: usize = 0;
    for (result.term_proofs.items) |proof| {
        const t = result.module().terms[@intCast(proof.after)];
        if (t == .call and t.call.function == f) generic_calls += 1;
    }
    try std.testing.expect(generic_calls > 0);
}

test "constant lookup of huge zero-width sequence does not enumerate its length" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const sequence = try b.schema(.{ .seq = unit });
    const option = try b.schema(.{ .sum = &.{ unit, unit } });
    const f = try b.declare(&.{sequence}, option, &.{}, &.{});
    const items = try b.reference(b.parameter(f, 0));
    const index = try b.constant(u64, 999999999);
    try b.define(f, try b.pure(try b.primitive(option, .sequence_get, &.{ items, index }, 0)));
    var encoded: [10]u8 = undefined;
    var writer: @import("horos_data").wire.Writer = .{ .output = &encoded };
    try writer.natural(1000000000);
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{.{ .known = .{ .schema = sequence, .bytes = encoded[0..writer.position] } }} };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const value = result.module().values[@intCast(result.value_proofs.items[result.value_proofs.items.len - 1].after)];
    try std.testing.expectEqualSlices(u8, &.{1}, result.module().constants[@intCast(value.expression.literal)].bytes);
    _ = word;
}
