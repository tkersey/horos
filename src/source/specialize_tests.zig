// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;
const pe = source.specialize;
const context: pe.Context = .{
    .core = @splat(1),
    .guest = @splat(2),
    .observation = @splat(3),
    .base_profile = @splat(4),
    .admission_profile = @splat(5),
    .compiler_policy = @splat(6),
};
fn known(value: u64, storage: *[8]u8, schema: p.Id) pe.Knowledge {
    std.mem.writeInt(u64, storage, value, .little);
    return .{ .known = .{ .schema = schema, .bytes = storage } };
}

fn resourceAuthorityCaller(b: *source.Builder, resource: p.Resource) !source.Id {
    // Exercise the authorized effectful helpers through an ordinary
    // first-order caller, independently of the example's protection.
    const acquire = resource.introducers[0];
    const release = resource.eliminators[resource.eliminators.len - 1];
    const effects = try std.mem.concat(
        b.allocator(),
        p.Id,
        &.{
            b.functions.items[@intCast(acquire)].effects,
            b.functions.items[@intCast(release)].effects,
        },
    );
    const function = try b.declare(
        &.{},
        b.functions.items[@intCast(release)].result,
        effects,
        &.{},
    );
    const owned = try b.variable(b.functions.items[@intCast(acquire)].result);
    const acquired = try b.term(.{ .call = .{ .function = acquire, .arguments = &.{} } });
    const released = try b.term(.{ .call = .{
        .function = release,
        .arguments = &.{try b.reference(owned)},
    } });
    try b.define(function, try b.bind(owned, acquired, released));
    return function;
}

fn rejectAuthoritySpecialization(
    b: *source.Builder,
    module: source.Module,
    resource: p.Resource,
    result: *pe.Output,
) !void {
    for ([_][]const p.Id{
        resource.introducers,
        resource.eliminators,
    }) |authorities| for (authorities) |function| {
        for (result.functions.items) |proof| try std.testing.expect(proof.before != function);
        const inputs = try b.allocator().alloc(
            pe.Knowledge,
            module.functions[@intCast(function)].parameters.len,
        );
        @memset(inputs, .dynamic);
        try std.testing.expectError(
            error.UnsupportedSpecialization,
            pe.specialize(
                std.testing.allocator,
                module,
                .{ .context = context, .function = function, .arguments = inputs },
            ),
        );
    };
}

test "specialization retains nominal resource authority in generic callees" {
    const a = std.testing.allocator;
    inline for (.{ "abortCustody", "resourceScalar", "resourcePair" }) |name| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const original = try @field(source.examples, name)(&b);
        const resource = original.resources[0];
        const entry = if (comptime std.mem.eql(u8, name, "abortCustody"))
            original.entry
        else
            try resourceAuthorityCaller(&b, resource);
        const module = b.module(entry, original.failure);
        var admitted = try source.lower(a, module);
        defer admitted.deinit();
        const arguments = try b.allocator().alloc(
            pe.Knowledge,
            module.functions[@intCast(entry)].parameters.len,
        );
        @memset(arguments, .dynamic);
        const request: pe.Request = .{
            .context = context,
            .function = entry,
            .arguments = arguments,
        };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        try pe.validate(a, module, request, &result);
        var lowered = try source.lower(a, result.module());
        defer lowered.deinit();
        try std.testing.expect(@import("horos_data").record.equal(
            []const p.Resource,
            module.resources,
            result.module().resources,
        ));
        try std.testing.expect(@import("horos_data").record.equal(
            []const source.ast.Function,
            module.functions,
            result.module().functions[0..module.functions.len],
        ));
        try rejectAuthoritySpecialization(&b, module, resource, &result);
        // Ordinary admission permits an explicit extra permission. The
        // independent translation checker must reject granting it to a clone.
        const extra = try std.mem.concat(
            result.builder.allocator(),
            p.Id,
            &.{ resource.introducers, &.{result.entry} },
        );
        result.builder.resources.items[0].introducers = extra;
        var forged = try source.lower(a, result.module());
        defer forged.deinit();
        try std.testing.expectError(
            error.InvalidSpecialization,
            pe.validate(a, module, request, &result),
        );
    }
}

fn specializeExample(build: *const fn (*source.Builder) source.Error!source.Module) !bool {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try build(&b);
    var original = try source.lower(a, module);
    defer original.deinit();
    const arguments = try b.allocator().alloc(
        pe.Knowledge,
        module.functions[@intCast(module.entry)].parameters.len,
    );
    @memset(arguments, .dynamic);
    var result = pe.specialize(
        a,
        module,
        .{ .context = context, .function = module.entry, .arguments = arguments },
    ) catch |err| switch (err) {
        error.UnsupportedSpecialization, error.SpecializationLimit => return false,
        else => return err,
    };
    defer result.deinit();
    var residual = try source.lower(a, result.module());
    defer residual.deinit();
    return true;
}

test "specialization admits or precisely declines existing public examples" {
    var attempted: usize = 0;
    var specialized: usize = 0;
    inline for (comptime std.meta.declarations(source.examples)) |name| {
        const build = @field(source.examples, name);
        if (comptime @TypeOf(build) == fn (*source.Builder) source.Error!source.Module) {
            attempted += 1;
            specialized += @intFromBool(try specializeExample(build));
        }
    }
    try std.testing.expect(attempted > 0);
    try std.testing.expect(specialized > 0);
}

fn capturedCallModule(b: *source.Builder, kind: usize) !struct {
    module: source.Module,
    word: p.Id,
    entry: p.Id,
    outer: p.Id,
    callee: p.Id,
} {
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const entry = try b.declare(&.{word}, word, &.{}, &.{});
    const outer = try b.declare(&.{word}, word, &.{}, &.{});
    const captured = if (kind == 1) try b.variable(word) else b.parameter(outer, 0);
    const inner = try b.declare(&.{}, word, &.{}, &.{});
    try b.define(inner, try b.pure(try b.reference(captured)));
    const callee = if (kind == 2) blk: {
        const indirect = try b.declare(&.{}, word, &.{}, &.{});
        try b.define(
            indirect,
            try b.term(.{ .call = .{ .function = inner, .arguments = &.{} } }),
        );
        break :blk indirect;
    } else inner;
    const call = try b.term(.{ .call = .{ .function = callee, .arguments = &.{} } });
    try b.define(outer, if (kind == 1 or kind == 3)
        try b.bind(captured, try b.pure(try b.constant(u64, 42)), call)
    else
        call);
    try b.define(
        entry,
        try b.term(.{ .call = .{
            .function = outer,
            .arguments = &.{try b.reference(b.parameter(entry, 0))},
        } }),
    );
    const module = b.module(entry, unit);
    return .{ .module = module, .word = word, .entry = entry, .outer = outer, .callee = callee };
}

test "specialization keeps captured calls inside their closed generic function" {
    const a = std.testing.allocator;
    for (0..4) |kind| for ([_]bool{ false, true }) |static_input| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const fixture = try capturedCallModule(&b, kind);
        const module = fixture.module;
        const word = fixture.word;
        const entry = fixture.entry;
        const outer = fixture.outer;
        const callee = fixture.callee;
        var admitted = try source.lower(a, module);
        defer admitted.deinit();
        var bytes: [8]u8 = undefined;
        const arguments = [_]pe.Knowledge{if (static_input) known(41, &bytes, word) else .dynamic};

        // This root needs its original lexical scope. Decline it before
        // constructing a residual with fresh binders and dangling captures.
        try std.testing.expectError(
            error.UnsupportedSpecialization,
            pe.specialize(
                a,
                module,
                .{ .context = context, .function = outer, .arguments = &arguments },
            ),
        );

        // Its closed caller can still specialize: the complete original
        // callee retains its parameter/local/shadowed/transitive captures.
        const request: pe.Request = .{
            .context = context,
            .function = entry,
            .arguments = &arguments,
        };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.functions.items.len);
        const residual = result.module();
        try std.testing.expect(@import("horos_data").record.equal(
            []const source.ast.Function,
            module.functions,
            residual.functions[0..module.functions.len],
        ));
        const function = residual.functions[@intCast(result.entry)];
        try std.testing.expectEqual(
            @as(usize, if (static_input) 0 else 1),
            function.parameters.len,
        );
        const retained_call = residual.terms[@intCast(function.body.?)].call;
        try std.testing.expectEqual(outer, retained_call.function);
        try std.testing.expectEqual(@as(usize, 1), retained_call.arguments.len);
        try pe.validate(a, module, request, &result);
        var lowered = try source.lower(a, residual);
        defer lowered.deinit();

        // The independent scope checker must still reject the old broken
        // boundary: calling the captured function from the renamed caller.
        result.builder.terms.items[@intCast(function.body.?)] = .{ .call = .{
            .function = callee,
            .arguments = &.{},
        } };
        try std.testing.expectError(
            error.UnboundVariable,
            pe.validate(a, module, request, &result),
        );
    };
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
        try b.define(
            f,
            try b.bind(y, try b.pure(try b.constant(u64, 42)), try b.pure(try b.reference(x))),
        );
        const module = b.module(f, unit);
        const request: pe.Request = .{
            .context = context,
            .function = f,
            .arguments = &.{.dynamic},
        };
        var result = try pe.specialize(a, module, request);
        defer result.deinit();
        const residual = result.module().functions[@intCast(result.entry)];
        result.builder.terms.items[
            @intCast(residual.body.?)
        ].bind.variable = residual.parameters[0];
        // Both candidates are legal source. Only the first changes which
        // source binding the final reference denotes.
        var admitted = try source.lower(a, result.module());
        defer admitted.deinit();
        if (shadows_source) {
            try pe.validate(a, module, request, &result);
        } else try std.testing.expectError(
            error.InvalidSpecialization,
            pe.validate(a, module, request, &result),
        );
    }
}

test "specialization rejects capture through unpack and both sum branch forms" {
    const a = std.testing.allocator;
    for (0..3) |kind| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const word = try b.scalar(u64);
        const shape = try b.schema(if (kind == 0) .{ .product = &.{word} } else .{ .sum = &.{
            word,
            word,
        } });
        const f = try b.declare(&.{ word, shape }, word, &.{}, &.{});
        const x = b.parameter(f, 0);
        const input = try b.reference(b.parameter(f, 1));
        const y = try b.variable(word);
        const finish = try b.pure(try b.reference(x));
        try b.define(f, try b.term(if (kind == 0)
            .{ .unpack_product = .{ .value = input, .variables = &.{y}, .body = finish } }
        else
            .{ .match_sum = .{
                .value = input,
                .cases = &.{
                    .{ .variable = y, .body = finish },
                    .{ .variable = try b.variable(word), .body = finish },
                },
            } }));
        const module = b.module(f, unit);
        const arguments = [_]pe.Knowledge{
            .dynamic,
            if (kind == 2) .{ .known = .{
                .schema = shape,
                .bytes = &.{ 0, 42, 0, 0, 0, 0, 0, 0, 0 },
            } } else .dynamic,
        };
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
        try std.testing.expectError(
            error.InvalidSpecialization,
            pe.validate(a, module, request, &result),
        );
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
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{ .dynamic, .dynamic },
    };
    var result = try pe.specialize(a, module, request);
    defer result.deinit();
    const parameters = @constCast(
        result.builder.functions.items[
            @intCast(result.entry)
        ].parameters,
    );
    std.mem.swap(p.Id, &parameters[0], &parameters[1]);
    var admitted = try source.lower(a, result.module());
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, module, request, &result),
    );
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
        const closure = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = unit,
        } } });
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
        try b.define(
            f,
            try b.pure(try b.primitive(
                word,
                if (kind == 0) .variant_tag else .sequence_length,
                &.{value},
                0,
            )),
        );
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
            try std.testing.expectEqual(
                .primitive,
                std.meta.activeTag(result.module().values[@intCast(proof.after)].expression),
            );
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
    const reduced = try b.value(.{
        .schema = u64_type,
        .expression = .{ .primitive = .{
            .opcode = .integer_sub,
            .operands = &.{ x, one },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } },
    });
    const recurse = try b.term(.{ .call = .{ .function = f, .arguments = &.{ reduced, factor } } });
    const finish = try b.pure(factor);
    try b.define(
        f,
        try b.term(.{ .conditional = .{
            .condition = stop,
            .when_true = finish,
            .when_false = recurse,
        } }),
    );
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{ .dynamic, known(7, &bytes, u64_type) },
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.functions.items.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        result.module().functions[@intCast(result.entry)].parameters.len,
    );
    var compiled = try source.lower(a, result.module());
    defer compiled.deinit();
    const proof = &result.value_proofs.items[result.value_proofs.items.len - 1];
    const saved = proof.before;
    proof.before = 0;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
    proof.before = saved;
    var changed = request;
    changed.context.guest[0] ^= 1;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), changed, &result),
    );
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
    try b.define(
        f,
        try b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = yes,
            .when_false = no,
        } }),
    );
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{.{ .known = .{ .schema = boolean, .bytes = &.{1} } }},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = &result.term_proofs.items[result.term_proofs.items.len - 1];
    try std.testing.expectEqual(@as(?usize, 0), last.selected);
    last.selected = 1;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
    last.selected = 0;
    var small = request;
    small.policy.work = 0;
    try std.testing.expectError(
        error.SpecializationLimit,
        pe.specialize(a, b.module(f, unit), small),
    );
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
    const divide = try b.value(.{
        .schema = word,
        .expression = .{ .primitive = .{
            .opcode = .integer_div,
            .operands = &.{ one, input },
            .failures = &.{
                .{ .kind = .arithmetic_overflow, .value = failure },
                .{ .kind = .division_by_zero, .value = failure },
            },
        } },
    });
    const product = try b.primitive(pair, .product, &.{ divide, seven }, 0);
    const projection = try b.primitive(word, .field, &.{product}, 1);
    try b.define(f, try b.pure(projection));
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{.dynamic} };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = result.value_proofs.items[result.value_proofs.items.len - 1];
    try std.testing.expect(!last.folded);
    try std.testing.expectEqual(
        .field,
        result.module().values[@intCast(last.after)].expression.primitive.opcode,
    );
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
    try std.testing.expectEqual(
        .bind,
        std.meta.activeTag(
            bound_result.module().terms[
                @intCast(bound_result.module().functions[
                    @intCast(bound_result.entry)
                ].body.?)
            ],
        ),
    );
}

test "specialization retains effects and rejects an effect substitution" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "specialize/test",
        .payload = word,
        .result = word,
        .external = true,
        .control_use = .linear,
    });
    const f = try b.declare(&.{word}, word, &.{effect}, &.{});
    const argument = try b.reference(b.parameter(f, 0));
    try b.define(f, try b.term(.{ .perform = .{ .effect = effect, .payload = argument } }));
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{known(41, &bytes, word)},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const term = result.module().terms[
        @intCast(result.module().functions[
            @intCast(result.entry)
        ].body.?)
    ];
    try std.testing.expectEqual(effect, term.perform.effect);
    // The checker rejects an effect substitution even if a caller recomputes
    // the content digest; the local derivation binds the actual source effect.
    const at = result.module().functions[@intCast(result.entry)].body.?;
    result.builder.terms.items[@intCast(at)] = .{ .value = term.perform.payload };
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
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
    try b.define(
        f,
        try b.term(.{ .match_sum = .{
            .value = tag,
            .cases = &.{
                .{ .variable = none, .body = empty },
                .{ .variable = some, .body = full },
            },
        } }),
    );
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{.{ .known = .{
            .schema = sum,
            .bytes = &.{ 1, 7, 0, 0, 0, 0, 0, 0, 0 },
        } }},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const last = &result.term_proofs.items[result.term_proofs.items.len - 1];
    try std.testing.expectEqual(@as(?usize, 1), last.selected);
    last.selected = 0;
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, b.module(f, unit), request, &result),
    );
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var work: u64 = 100;
    var bytes: [8]u8 = undefined;
    const structured: pe.Knowledge = .{ .product = .{
        .schema = 4,
        .fields = &.{known(17, &bytes, word)},
    } };
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
    const reduced = try b.value(.{
        .schema = word,
        .expression = .{ .primitive = .{
            .opcode = .integer_sub,
            .operands = &.{ x, one },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } },
    });
    const recurse = try b.term(.{ .call = .{ .function = f, .arguments = &.{reduced} } });
    const end = try b.pure(zero);
    try b.define(
        f,
        try b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = end,
            .when_false = recurse,
        } }),
    );
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{known(20, &bytes, word)},
        .policy = .{ .keys_per_function = 2 },
    };
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
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{.{ .known = .{
            .schema = sequence,
            .bytes = encoded[0..writer.position],
        } }},
    };
    var result = try pe.specialize(a, b.module(f, unit), request);
    defer result.deinit();
    const value = result.module().values[
        @intCast(result.value_proofs.items[result.value_proofs.items.len - 1].after)
    ];
    try std.testing.expectEqualSlices(
        u8,
        &.{1},
        result.module().constants[@intCast(value.expression.literal)].bytes,
    );
    _ = word;
}

test "finite source relation checks scalar composition and rejects unexplained changes" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const moved = try b.primitive(word, .move, &.{x}, 0);
    try b.define(f, try b.pure(moved));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(moved)] = before.values[@intCast(x)];
    const steps = [_]relation.Step{.{
        .successor = after,
        .rule = .{ .scalar = .{ .value = moved, .rule = .identity } },
    }};
    try relation.validate(a, before, after, &steps, .{});
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &.{}, .{}),
    );
    @constCast(after.values)[@intCast(moved)].expression = .{ .primitive = .{
        .opcode = .integer_bit_not,
        .operands = &.{x},
    } };
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &steps, .{}),
    );
}

test "private product relation transports literals constructors projections and unpack bindings" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const product = try b.schema(.{ .product = &.{ word, boolean } });
    const f = try b.declare(&.{ word, boolean }, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const y = try b.reference(b.parameter(f, 1));
    const pair = try b.primitive(product, .product, &.{ x, y }, 0);
    const projected = try b.primitive(word, .field, &.{pair}, 0);
    _ = try b.literal(.{ .schema = product, .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0, 1 } });
    const first = try b.variable(word);
    const second = try b.variable(boolean);
    const body = try b.pure(projected);
    try b.define(f, try b.term(.{ .unpack_product = .{
        .value = pair,
        .variables = &.{ first, second },
        .body = body,
    } }));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.schemas)[@intCast(product)].product = &.{ boolean, word };
    @constCast(after.values)[@intCast(pair)].expression.primitive.operands = &.{ y, x };
    @constCast(after.values)[@intCast(projected)].expression.primitive.immediate = 1;
    @constCast(after.constants)[0].bytes = &.{ 1, 7, 0, 0, 0, 0, 0, 0, 0 };
    @constCast(after.terms)[after.terms.len - 1].unpack_product.variables = &.{ second, first };
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = product,
        .coordinates = &.{ 1, 0 },
    }} } }};
    const policy: relation.Policy = .{ .private_schemas = &.{product} };
    try relation.validate(a, before, after, &steps, policy);
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{
            .private_schemas = &.{product},
            .fixed_schemas = &.{product},
        },
    ));
    @constCast(after.values)[@intCast(projected)].expression.primitive.immediate = 0;
    try std.testing.expectError(
        error.InvalidRelation,
        relation.validate(a, before, after, &steps, policy),
    );
}

test "closed pure inlining evaluates arguments once and protects source recovery roots" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const helper = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(helper, try b.pure(try b.reference(b.parameter(helper, 0))));
    const entry = try b.declare(&.{word}, word, &.{}, &.{});
    const argument = try b.reference(b.parameter(entry, 0));
    const call = try b.term(.{ .call = .{
        .function = helper,
        .arguments = &.{argument},
    } });
    try b.define(entry, call);
    const before = b.module(entry, unit);
    const fresh = try b.variable(word);
    const value = try b.reference(fresh);
    const after = try source.own(source.ast.Module, b.allocator(), b.module(entry, unit));
    const terms = [_]source.ast.Term{
        before.terms[0],
        .{ .value = value },
        .{ .value = argument },
        .{ .bind = .{ .variable = fresh, .value = 2, .next = 1 } },
    };
    var candidate = after;
    candidate.terms = &terms;
    @constCast(candidate.functions)[@intCast(entry)].body = 3;
    const steps = [_]relation.Step{.{ .successor = candidate, .rule = .{ .inline_call = call } }};
    try relation.validate(a, before, candidate, &steps, .{});
    try std.testing.expectError(error.UnsupportedRelation, relation.validate(
        a,
        before,
        candidate,
        &steps,
        .{ .protected_functions = &.{helper} },
    ));
    try std.testing.expectError(error.RelationLimit, relation.validate(
        a,
        before,
        candidate,
        &steps,
        .{ .work = 0 },
    ));
}

test "source relation specialization binds owner selected immutable static inputs" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
    const before = b.module(f, unit);
    var bytes: [8]u8 = undefined;
    const request: pe.Request = .{
        .context = context,
        .function = f,
        .arguments = &.{known(5, &bytes, word)},
        .policy = .{ .work = 1000 },
    };
    var output = try pe.specialize(a, before, request);
    defer output.deinit();
    const after = output.module();
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .specialization = .{
        .request = request,
        .entry = output.entry,
        .functions = output.functions.items,
        .values = output.value_proofs.items,
        .terms = output.term_proofs.items,
    } } }};
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{},
    ));
    const policy: relation.Policy = .{ .static_scopes = &.{.{
        .predecessor = try relation.identity(before),
        .request = request,
    }} };
    try relation.validate(a, before, after, &steps, policy);
    const decoded = try roundTripRelationStep(b.allocator(), steps[0]);
    try relation.validate(a, before, after, &.{decoded}, policy);
    var unproved = after;
    unproved.terms = try std.mem.concat(
        b.allocator(),
        source.ast.Term,
        &.{ after.terms, &.{after.terms[0]} },
    );
    var changed_steps = steps;
    changed_steps[0].successor = unproved;
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        unproved,
        &changed_steps,
        policy,
    ));
}

test "private layout transports recursive literal graphs without changing scalar identities" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const node = try b.reserveSchema();
    const pair = try b.schema(.{ .product = &.{ word, node } });
    try b.defineSchema(node, .{ .sum = &.{ unit, pair } });
    const original_bytes = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0 };
    const transported_bytes = [_]u8{ 1, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 };
    const value = try b.literal(.{ .schema = node, .bytes = &original_bytes });
    const entry = try b.declare(&.{}, node, &.{}, &.{});
    try b.define(entry, try b.pure(value));
    const before = b.module(entry, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.schemas)[@intCast(pair)].product = &.{ node, word };
    @constCast(after.constants)[0].bytes = &transported_bytes;
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = pair,
        .coordinates = &.{ 1, 0 },
    }} } }};
    const policy: relation.Policy = .{ .private_schemas = &.{pair} };
    try relation.validate(a, before, after, &steps, policy);
    @constCast(after.constants)[0].bytes = &original_bytes;
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        policy,
    ));
}

test "source relocation preserves fixed schema endpoints and exact function correspondence" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(f, try b.pure(try b.reference(b.parameter(f, 0))));
    const other = try b.declare(&.{word}, word, &.{}, &.{});
    try b.define(other, try b.pure(try b.reference(b.parameter(other, 0))));
    const before = b.module(f, unit);
    const maps: relation.Relocation.Maps = .{
        .schemas = &.{ 1, 0 },
        .variables = &.{ 1, 0 },
        .values = &.{ 1, 0 },
        .terms = &.{ 1, 0 },
        .functions = &.{ 1, 0 },
    };
    const after = try relation.Relocation.relocate(b.allocator(), before, maps);
    try std.testing.expectEqual(@as(u64, 1), after.entry);
    try std.testing.expectEqual(@as(u64, 0), after.functions[1].result);
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .relocation = maps } }};
    try relation.validate(a, before, after, &steps, .{});
    var nominal = before;
    nominal.region_count = 2;
    var collapsed = maps;
    collapsed.region_count = 2;
    collapsed.regions = &.{.{ .old = 1, .new = 0 }};
    try std.testing.expectError(
        error.InvalidRelation,
        relation.Relocation.validateMaps(a, nominal, collapsed, false),
    );
    const roots = try relation.transportFunctions(a, &.{f}, &steps);
    defer a.free(roots);
    try std.testing.expectEqualSlices(u64, &.{1}, roots);
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{ .fixed_schemas = &.{word} },
    ));
}

test "specialization verification exhaustion remains distinct from an invalid derivation" {
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const f = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(f, try b.pure(try b.constant(void, {})));
    const before = b.module(f, unit);
    const request: pe.Request = .{ .context = context, .function = f, .arguments = &.{} };
    var output = try pe.specialize(a, before, request);
    defer output.deinit();
    output.request.policy.work = 0;
    output.key = try pe.identity(a, before, output.request);
    try std.testing.expectError(
        error.SpecializationLimit,
        pe.validate(a, before, output.request, &output),
    );
    output.request = request;
    output.key = try pe.identity(a, before, request);
    output.term_proofs.items[0].before = std.math.maxInt(u64);
    try std.testing.expectError(
        error.InvalidSpecialization,
        pe.validate(a, before, request, &output),
    );
}

test "private layout preserves nonstable evaluation order and shared pure prefixes" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const triple = try b.schema(.{ .product = &.{ word, word, word } });
    const f = try b.declare(&.{ word, word }, triple, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const y = try b.reference(b.parameter(f, 1));
    const first = try b.primitive(pair, .product, &.{ x, y }, 0);
    const second = try b.primitive(pair, .product, &.{ y, x }, 0);
    const left = try b.primitive(word, .field, &.{first}, 0);
    const right = try b.primitive(word, .field, &.{first}, 1);
    const other = try b.primitive(word, .field, &.{second}, 0);
    const result = try b.primitive(triple, .product, &.{ left, right, x }, 0);
    try b.define(f, try b.pure(result));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(result)].expression.primitive.operands = &.{ x, left, right };
    var steps = [_]relation.Step{.{ .successor = after, .rule = .{ .product_layout = &.{.{
        .schema = triple,
        .coordinates = &.{ 2, 0, 1 },
    }} } }};
    const policy: relation.Policy = .{ .private_schemas = &.{triple} };
    try relation.validate(a, before, after, &steps, policy);
    @constCast(after.values)[@intCast(result)].expression.primitive.operands = &.{ right, left, x };
    steps[0].rule.product_layout = &.{.{ .schema = triple, .coordinates = &.{ 1, 0, 2 } }};
    try relation.validate(a, before, after, &steps, policy);
    b.values.items[@intCast(result)].expression.primitive.operands = &.{ left, other, x };
    @constCast(after.values)[@intCast(result)].expression.primitive.operands = &.{ other, left, x };
    try std.testing.expectError(error.UnsupportedRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        policy,
    ));
}

test "scalar relation removes xor zero while retaining dynamic operand evaluation" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const zero = try b.constant(u64, 0);
    const xor = try b.primitive(word, .integer_bit_xor, &.{ x, zero }, 0);
    try b.define(f, try b.pure(xor));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(xor)] = before.values[@intCast(x)];
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .scalar = .{
        .value = xor,
        .rule = .identity,
    } } }};
    try relation.validate(a, before, after, &steps, .{});
}

fn roundTripRelationStep(
    a: std.mem.Allocator,
    step: @import("relation.zig").Step,
) !@import("relation.zig").Step {
    const relation = @import("relation.zig");
    const data = @import("horos_data");
    var record = try relation.encodeRecordStep(a, step);
    var measure: data.wire.Writer = .{};
    try data.record.write(relation.RecordStep, record, &measure);
    var remaining: usize = 100_000;
    const decoded = try relation.decodeRecordStep(a, record, &remaining);
    record.rule.specialization = try std.mem.concat(a, u8, &.{
        record.rule.specialization, &.{0},
    });
    try std.testing.expectError(
        error.NonCanonical,
        relation.decodeRecordStep(a, record, &remaining),
    );
    return decoded;
}

test "projection discards total nested products but preserves potentially failing operands" {
    const relation = @import("relation.zig");
    const a = std.testing.allocator;
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const f = try b.declare(&.{word}, word, &.{}, &.{});
    const x = try b.reference(b.parameter(f, 0));
    const one = try b.constant(u64, 1);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const failing = try b.value(.{ .schema = word, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ x, one },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
    } } });
    const nested = try b.primitive(pair, .product, &.{ x, x }, 0);
    const field = try b.primitive(word, .field, &.{nested}, 1);
    const product = try b.primitive(pair, .product, &.{ x, field }, 0);
    const projection = try b.primitive(word, .field, &.{product}, 0);
    try b.define(f, try b.pure(projection));
    const before = b.module(f, unit);
    const after = try source.own(source.ast.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(projection)] = before.values[@intCast(x)];
    const steps = [_]relation.Step{.{ .successor = after, .rule = .{ .scalar = .{
        .value = projection,
        .rule = .projection,
    } } }};
    try relation.validate(a, before, after, &steps, .{});
    b.values.items[@intCast(product)].expression.primitive.operands = &.{ x, failing };
    @constCast(after.values)[@intCast(product)] = before.values[@intCast(product)];
    try std.testing.expectError(error.InvalidRelation, relation.validate(
        a,
        before,
        after,
        &steps,
        .{},
    ));
    b.values.items[@intCast(projection)].expression.primitive.immediate = 1;
    @constCast(after.values)[@intCast(projection)] = before.values[@intCast(failing)];
    try relation.validate(a, before, after, &steps, .{});
}
