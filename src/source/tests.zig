const std = @import("std");
const source = @import("../source.zig");
const examples = @import("examples.zig");
const data = @import("horos_data");

fn requireAdmitted(program: data.activation.Program) !void {
    var facts = try data.activation_ownership.analyze(std.testing.allocator, program);
    facts.deinit();
}

fn canonical(program: data.activation.Program) !void {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, try data.program_image.encodedLength(program));
    defer a.free(bytes);
    _ = try data.program_image.encode(a, program, bytes);
    var decoded = try data.program_image.decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(program, decoded.program);
}

test "resource authority rejects absent descriptors before mutation" {
    for (0..2) |resource_count| for ([_]bool{ false, true }) |maximum| {
        for ([_]bool{ false, true }) |defined| {
            var b = source.Builder.init(std.testing.allocator);
            defer b.deinit();
            const integer = try b.scalar(u64);
            if (resource_count != 0) _ = try b.resource(integer);
            const bad: data.program.Id = if (maximum)
                std.math.maxInt(data.program.Id)
            else
                b.resources.items.len;
            const shape: data.program.Schema = .{ .internal = .{ .abstract_resource = bad } };
            const schema = if (defined) blk: {
                const reserved = try b.reserveSchema();
                try b.defineSchema(reserved, shape);
                break :blk reserved;
            } else try b.schema(shape);
            try std.testing.expectError(
                error.InvalidReference,
                b.resourceAuthority(schema, &.{0}, &.{1}),
            );
            try std.testing.expectEqual(resource_count, b.resources.items.len);
            for (b.resources.items) |descriptor| {
                try std.testing.expectEqual(integer, descriptor.representation);
                try std.testing.expectEqual(@as(usize, 0), descriptor.introducers.len);
                try std.testing.expectEqual(@as(usize, 0), descriptor.eliminators.len);
            }
        }
    };
}

test "resource authority preserves the final valid descriptor and existing errors" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    _ = try b.resource(integer);
    const resource = try b.resource(integer);
    const factory = try b.declare(&.{}, resource, &.{}, &.{});
    const release = try b.declare(&.{resource}, integer, &.{}, &.{});
    try std.testing.expectError(
        error.InvalidReference,
        b.resourceAuthority(b.schemas.items.len, &.{}, &.{}),
    );
    try std.testing.expectError(error.TypeMismatch, b.resourceAuthority(integer, &.{}, &.{}));
    try b.resourceAuthority(resource, &.{factory}, &.{release});
    try std.testing.expectEqual(@as(usize, 0), b.resources.items[0].introducers.len);
    try std.testing.expectEqual(@as(usize, 0), b.resources.items[0].eliminators.len);
    try std.testing.expectEqualSlices(source.Id, &.{factory}, b.resources.items[1].introducers);
    try std.testing.expectEqualSlices(source.Id, &.{release}, b.resources.items[1].eliminators);
    try std.testing.expectError(error.InvalidOwnership, b.resourceAuthority(resource, &.{}, &.{}));
}

test "declared result schemas reject before recursive lowering" {
    for (0..4) |variant| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const integer = try b.scalar(u64);
        const bad: data.program.Id = if (variant == 1) std.math.maxInt(
            data.program.Id,
        ) else b.schemas.items.len;
        const first = try b.declare(&.{}, bad, &.{}, &.{});
        const second = if (variant == 2) try b.declare(&.{}, bad, &.{}, &.{}) else first;
        const call = try b.term(.{ .call = .{ .function = second, .arguments = &.{} } });
        const body = if (variant == 3) try b.term(.{ .fail = try b.constant(u64, 8) }) else call;
        try b.define(first, body);
        if (second != first) try b.define(
            second,
            try b.term(.{ .call = .{ .function = first, .arguments = &.{} } }),
        );
        const module = b.module(first, integer);
        try std.testing.expectError(
            error.InvalidSchema,
            source.lower(std.testing.allocator, module),
        );
        var diagnostic: source.Diagnostic = .{};
        try std.testing.expectError(
            error.InvalidSchema,
            source.lowerObserved(std.testing.allocator, module, .{ .diagnostic = &diagnostic }),
        );
        try std.testing.expectEqual(.source_check, diagnostic.phase);
        try std.testing.expectEqual(@as(?data.program.Id, first), diagnostic.function);
    }
}

test "valid recursive result schemas do not require source termination" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const function = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(function, try b.term(.{ .call = .{ .function = function, .arguments = &.{} } }));
    var compiled = try source.lower(std.testing.allocator, b.module(function, integer));
    defer compiled.deinit();
    try requireAdmitted(compiled.program);
}

test "borrowed operands preserve evaluated consumption and owned temporary failure custody" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var compiled = try source.lower(std.testing.allocator, try examples.borrowOperands(&b));
    defer compiled.deinit();
    try requireAdmitted(compiled.program);
    try canonical(compiled.program);
}

test "successor custody never permits ordinary owner discard" {
    const edges = @import("custody_edge_example.zig");
    for (0..edges.count) |index| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const entry = try edges.scenario(&b, index, false);
        try std.testing.expectError(error.InvalidOwnership, source.lower(
            std.testing.allocator,
            b.module(entry, try b.scalar(u64)),
        ));
    }
}

test "failure custody does not permit repeated consumption inside a borrowed operand" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const module = try examples.borrowOperands(&b);
    var changed = false;
    for (b.values.items) |*value| {
        if (value.expression != .primitive) continue;
        const primitive = &value.expression.primitive;
        if (primitive.opcode != .sequence or primitive.operands.len != 1) continue;
        const operand = primitive.operands[0];
        const schema = b.values.items[@intCast(operand)].schema;
        if (b.schemas.items[@intCast(schema)] != .internal) continue;
        primitive.operands = try b.allocator().dupe(data.program.Id, &.{ operand, operand });
        changed = true;
        break;
    }
    try std.testing.expect(changed);
    try std.testing.expectError(error.UnavailableSlot, source.lower(
        std.testing.allocator,
        b.module(module.entry, module.failure),
    ));
}

test "operation clauses accept older capability payloads and reject their own attachment" {
    inline for (.{ false, true }) |older| inline for (.{ false, true }) |helper| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try @import("clause_payload_example.zig").variant(&b, older, helper);
        var diagnostic: source.Diagnostic = .{};
        if (source.lowerObserved(
            std.testing.allocator,
            module,
            .{ .diagnostic = &diagnostic },
        )) |result| {
            var compiled = result;
            defer compiled.deinit();
            try std.testing.expect(older);
        } else |err| {
            try std.testing.expect(!older);
            try std.testing.expectEqual(error.InvalidOwnership, err);
            try std.testing.expectEqual(.target_check, diagnostic.phase);
            try std.testing.expect(diagnostic.target.handler != null);
        }
    };
}

test "shallow successor state preserves independent capability and region lifetimes" {
    inline for (.{ false, true }) |capability| inline for (.{ false, true }) |cell| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try @import("successor_state_example.zig").variant(&b, capability, cell);
        var diagnostic: source.Diagnostic = .{};
        var compiled = source.lowerObserved(
            std.testing.allocator,
            module,
            .{ .diagnostic = &diagnostic },
        ) catch |err| {
            std.debug.print(
                "successor capability={any}, cell={any}: {any}\n",
                .{ capability, cell, diagnostic },
            );
            return err;
        };
        defer compiled.deinit();
    };
}

test "product destructuring requires distinct simultaneous variable binders" {
    for (0..4) |duplicate| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const integer = try b.scalar(u64);
        const product = try b.schema(.{ .product = &.{ integer, integer, integer } });
        var variables = [_]data.program.Id{
            try b.variable(integer), try b.variable(integer), try b.variable(integer),
        };
        if (duplicate < 3) {
            const pairs = [_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
            variables[pairs[duplicate][1]] = variables[pairs[duplicate][0]];
        }
        const values = try b.primitive(product, .product, &.{
            try b.constant(u64, 1), try b.constant(u64, 2), try b.constant(u64, 3),
        }, 0);
        const main = try b.declare(&.{}, integer, &.{}, &.{});
        try b.define(main, try b.term(.{ .unpack_product = .{
            .value = values,
            .variables = &variables,
            .body = try b.pure(try b.reference(variables[2])),
        } }));
        const module = b.module(main, unit);
        if (duplicate < 3) {
            try std.testing.expectError(
                error.InvalidSource,
                source.lower(std.testing.allocator, module),
            );
        } else {
            var compiled = try source.lower(std.testing.allocator, module);
            defer compiled.deinit();
        }
    }
}

const BorrowGenerator = struct {
    capability: source.Id,
    effect: source.Id,
    handler: source.Id,
    answer: source.Id,
    yielded: source.Id,
    package: source.Id,
    resumption: source.Id,
};

fn borrowGenerator(b: *source.Builder) !BorrowGenerator {
    const gen = @import("../library/generator.zig");
    const a = @import("../authoring.zig");
    const c = try a.Context.init(b);
    const typed_unit = try c.schema(void);
    const definition = try gen.create(
        c,
        "implicit-package-borrow",
        typed_unit,
        typed_unit,
        typed_unit,
        .{ .captures = .{ .continuation = &.{typed_unit} } },
    );
    // Project the checked family for deliberate lexical-borrow IR variants.
    const generator: BorrowGenerator = .{
        .capability = try a.interop.schemaId(c, definition.capability()),
        .effect = try a.interop.operationId(c, definition.effect()),
        .handler = try a.interop.handlerId(c, definition.handler()),
        .answer = try a.interop.schemaId(c, definition.answer()),
        .yielded = try a.interop.schemaId(c, definition.yielded()),
        .package = try a.interop.schemaId(c, definition.package()),
        .resumption = try a.interop.schemaId(c, definition.resumption()),
    };
    return generator;
}

fn installBorrowGenerator(
    b: *source.Builder,
    generator: BorrowGenerator,
    unit: source.Id,
) !source.Id {
    const yielded_body = try b.declare(
        &.{generator.capability},
        unit,
        &.{generator.effect},
        &.{},
    );
    try b.define(
        yielded_body,
        try b.term(.{ .perform = .{
            .effect = generator.effect,
            .capability = try b.reference(b.parameter(yielded_body, 0)),
            .payload = try b.constant(void, {}),
        } }),
    );
    const yielded_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{generator.capability},
        .result = unit,
        .effects = &.{generator.effect},
    } } });
    const installed = try b.term(.{ .handle = .{
        .handler = generator.handler,
        .body = try b.lambda(yielded_body, yielded_type),
    } });
    return installed;
}

fn borrowGeneratorConsumer(
    b: *source.Builder,
    generator: BorrowGenerator,
    unit: source.Id,
) !source.Id {
    const consume = try b.declare(&.{generator.answer}, unit, &.{}, &.{});
    const done = try b.variable(unit);
    const yielded = try b.variable(generator.yielded);
    const payload = try b.variable(unit);
    const package = try b.variable(generator.package);
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(yielded),
        .variables = &.{ payload, package },
        .body = try b.term(.{ .dispose = try b.primitive(
            generator.resumption,
            .unpack,
            &.{try b.reference(package)},
            0,
        ) }),
    } });
    try b.define(
        consume,
        try b.term(.{ .match_sum = .{
            .value = try b.reference(b.parameter(consume, 0)),
            .cases = &.{
                .{ .variable = done, .body = try b.pure(try b.constant(void, {})) },
                .{ .variable = yielded, .body = unpack },
            },
        } }),
    );
    return consume;
}

test "a nested suspension package retains implicit handler and region borrows" {
    for (0..5) |form| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const r = b.region();
        const region = try b.schema(.{ .internal = .{ .region = r } });
        const uses_region = form == 2 or form == 4;
        const regions: []const data.program.Id = if (uses_region) &.{r} else &.{};
        const generator = try borrowGenerator(&b);
        const installed = try installBorrowGenerator(&b, generator, unit);
        const consume = try borrowGeneratorConsumer(&b, generator, unit);
        const inside_result = if (form >= 3) unit else generator.answer;
        const scope = try b.declare(
            if (uses_region) &.{region} else &.{},
            inside_result,
            &.{},
            regions,
        );
        const result = try b.variable(generator.answer);
        const close = try b.term(.{ .call = .{
            .function = consume,
            .arguments = &.{try b.reference(result)},
        } });
        try b.define(scope, if (form >= 3) try b.bind(result, installed, close) else installed);
        const scope_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = if (uses_region) &.{region} else &.{},
            .result = inside_result,
            .regions = regions,
        } } });
        const main = try b.declare(&.{}, unit, &.{}, &.{});
        const wrapped = if (form == 0) installed else if (uses_region) try b.term(
            .{ .with_region = .{ .region = r, .body = try b.lambda(scope, scope_type) } },
        ) else blk: {
            const returns = try b.declare(&.{inside_result}, inside_result, &.{}, &.{});
            try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
            const handler = try b.handler(.{
                .mode = .deep,
                .input = inside_result,
                .answer = inside_result,
                .return_function = returns,
                .clauses = &.{},
            });
            break :blk try b.term(.{ .handle = .{
                .handler = handler,
                .body = try b.lambda(scope, scope_type),
            } });
        };
        try b.define(main, if (form >= 3) wrapped else try b.bind(result, wrapped, close));
        if (source.lower(std.testing.allocator, b.module(main, unit))) |result_program| {
            var compiled = result_program;
            defer compiled.deinit();
            if (form == 1 or form == 2) return error.ExpectedImplicitBorrowRejection;
        } else |err| {
            if (form != 1 and form != 2) return err;
            try std.testing.expectEqual(error.InvalidOwnership, err);
        }
    }
}

fn stateBorrowOuterHandler(
    b: *source.Builder,
    unit: source.Id,
    r: source.Id,
    effect: source.Id,
    cap: source.Id,
    cell: source.Id,
) !source.Id {
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = unit,
        .capture_bound = &.{ unit, cap, cell },
        .owned_regions = &.{r},
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ unit, token }, unit, &.{}, &.{});
    try b.define(
        clause,
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(clause, 1)),
            .argument = try b.constant(void, {}),
        } }),
    );
    const outer_handler = try b.handler(.{
        .mode = .deep,
        .input = unit,
        .answer = unit,
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    return outer_handler;
}

fn stateBorrowWriteFamily(
    b: *source.Builder,
    unit: source.Id,
    cap: source.Id,
    cell: source.Id,
) !struct { effect: source.Id, capability: source.Id, token: source.Id } {
    const write_effect = try b.effect(.{
        .identity = "state-borrow-write",
        .payload = cap,
        .result = unit,
        .external = false,
    });
    const write_cap = try b.schema(.{ .internal = .{ .capability = write_effect } });
    const write_token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = write_effect,
        .input = unit,
        .answer = unit,
        .capture_bound = &.{ unit, cap, cell, write_cap },
        .handled = &.{write_effect},
        .mode = .deep,
        .use = .linear,
    } } });
    return .{ .effect = write_effect, .capability = write_cap, .token = write_token };
}

fn stateBorrowWriteHandler(
    b: *source.Builder,
    form: usize,
    unit: source.Id,
    r: source.Id,
    cap: source.Id,
    cell: source.Id,
    input: source.Id,
    write_effect: source.Id,
    write_token: source.Id,
) !source.Id {
    const write_returns = try b.declare(&.{ cell, input }, unit, &.{}, &.{r});
    try b.define(
        write_returns,
        try b.pure(if (form < 2) try b.constant(void, {}) else try b.primitive(
            unit,
            .cell_set,
            &.{
                try b.reference(b.parameter(write_returns, 0)),
                try b.reference(b.parameter(write_returns, 1)),
            },
            0,
        )),
    );
    const write_clause = try b.declare(&.{ cell, cap, write_token }, unit, &.{}, &.{r});
    const write = try b.pure(try b.primitive(
        unit,
        .cell_set,
        &.{
            try b.reference(b.parameter(write_clause, 0)),
            try b.reference(b.parameter(write_clause, 1)),
        },
        0,
    ));
    const resumed = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(write_clause, 2)),
        .argument = try b.constant(void, {}),
    } });
    try b.define(write_clause, try b.bind(try b.variable(unit), write, resumed));
    const write_handler = try b.handler(.{
        .mode = .deep,
        .input = input,
        .answer = unit,
        .return_function = write_returns,
        .clauses = &.{.{
            .effect = write_effect,
            .function = write_clause,
            .resumption = write_token,
        }},
        .state = &.{cell},
    });
    return write_handler;
}

fn stateBorrowMiddleBody(
    b: *source.Builder,
    form: usize,
    unit: source.Id,
    r: source.Id,
    cap: source.Id,
    cell: source.Id,
    input: source.Id,
    write_effect: source.Id,
    write_cap: source.Id,
    write_handler: source.Id,
) !source.Id {
    const middle = try b.declare(&.{ cap, cap, cell }, unit, &.{}, &.{r});
    const selected = try b.reference(b.parameter(middle, if (form % 2 == 0) 0 else 1));
    const body = try b.declare(
        &.{write_cap},
        input,
        if (form < 2) &.{write_effect} else &.{},
        &.{r},
    );
    try b.define(
        body,
        if (form < 2) try b.term(.{ .perform = .{
            .effect = write_effect,
            .capability = try b.reference(b.parameter(body, 0)),
            .payload = selected,
        } }) else try b.pure(selected),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{write_cap},
        .result = input,
        .effects = if (form < 2) &.{write_effect} else &.{},
        .capture_bound = &.{cap},
        .regions = &.{r},
    } } });
    try b.define(
        middle,
        try b.term(.{ .handle = .{
            .handler = write_handler,
            .body = try b.lambda(body, body_type),
            .state = &.{try b.reference(b.parameter(middle, 2))},
        } }),
    );
    const middle_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ cap, cap, cell },
        .result = unit,
        .regions = &.{r},
    } } });
    return b.lambda(middle, middle_type);
}

fn stateBorrowInstallation(
    b: *source.Builder,
    unit: source.Id,
    r: source.Id,
    region: source.Id,
    effect: source.Id,
    cap: source.Id,
    cell: source.Id,
    outer_handler: source.Id,
    middle_body: source.Id,
) !source.Module {
    const outer = try b.declare(&.{cap}, unit, &.{effect}, &.{});
    const scope = try b.declare(&.{region}, unit, &.{effect}, &.{r});
    const older = try b.reference(b.parameter(outer, 0));
    const allocated = try b.variable(cell);
    const installation = try b.term(.{ .handle = .{
        .handler = outer_handler,
        .body = middle_body,
        .arguments = &.{ older, try b.reference(allocated) },
    } });
    const use = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.primitive(cap, .cell_get, &.{try b.reference(allocated)}, 0),
        .payload = try b.constant(void, {}),
    } });
    const allocation = try b.pure(try b.primitive(
        cell,
        .cell_new,
        &.{ try b.reference(b.parameter(scope, 0)), older },
        0,
    ));
    try b.define(
        scope,
        try b.bind(
            allocated,
            allocation,
            try b.bind(try b.variable(unit), installation, use),
        ),
    );
    const scope_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = unit,
        .effects = &.{effect},
        .capture_bound = &.{cap},
        .regions = &.{r},
    } } });
    try b.define(
        outer,
        try b.term(.{ .with_region = .{
            .region = r,
            .body = try b.lambda(scope, scope_type),
        } }),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = unit,
        .effects = &.{effect},
    } } });
    const main = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = outer_handler,
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    return b.module(main, unit);
}

test "clause and return writes retain the lifetime of actual handler state" {
    for (0..4) |form| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const r = b.region();
        const region = try b.schema(.{ .internal = .{ .region = r } });
        const effect = try b.effect(.{
            .identity = "state-borrow-owner",
            .payload = unit,
            .result = unit,
            .external = false,
        });
        const cap = try b.schema(.{ .internal = .{ .capability = effect } });
        const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = cap, .region = r } } });
        const outer_handler = try stateBorrowOuterHandler(&b, unit, r, effect, cap, cell);
        const write_family = try stateBorrowWriteFamily(&b, unit, cap, cell);
        const write_effect = write_family.effect;
        const write_cap = write_family.capability;
        const write_token = write_family.token;
        const input = if (form < 2) unit else cap;
        const write_handler = try stateBorrowWriteHandler(
            &b,
            form,
            unit,
            r,
            cap,
            cell,
            input,
            write_effect,
            write_token,
        );
        const middle_body = try stateBorrowMiddleBody(
            &b,
            form,
            unit,
            r,
            cap,
            cell,
            input,
            write_effect,
            write_cap,
            write_handler,
        );
        const module = try stateBorrowInstallation(
            &b,
            unit,
            r,
            region,
            effect,
            cap,
            cell,
            outer_handler,
            middle_body,
        );
        if (source.lower(std.testing.allocator, module)) |result_program| {
            var compiled = result_program;
            defer compiled.deinit();
            if (form % 2 == 0) return error.ExpectedHandlerStateBorrowRejection;
        } else |err| {
            if (form % 2 == 1) {
                std.debug.print("handler state form {d}: {any}\n", .{ form, err });
                return err;
            }
            try std.testing.expectEqual(error.InvalidOwnership, err);
        }
    }
}

test "actual handler installation sites share executable definitions" {
    var functions: ?usize = null;
    var clause_instructions: ?usize = null;
    for ([_]usize{ 1, 8, 64 }) |count| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        var compiled = try source.lower(
            std.testing.allocator,
            try examples.installations(&b, count),
        );
        defer compiled.deinit();
        const program = compiled.program;
        try std.testing.expectEqual(@as(usize, 1), program.handlers.len);
        const clause = program.handlers[0].clauses[0];
        try std.testing.expectEqual(@as(@TypeOf(clause.strategy), .tail), clause.strategy);
        const code = program.blocks[@intCast(program.functions[@intCast(clause.function)].entry)];
        if (functions == null) {
            functions = program.functions.len;
            clause_instructions = code.instructions.len;
        }
        try std.testing.expectEqual(functions.?, program.functions.len);
        try std.testing.expectEqual(clause_instructions.?, code.instructions.len);
        var installed: usize = 0;
        for (program.blocks) |block| if (block.terminator == .handle) {
            installed += 1;
        };
        try std.testing.expectEqual(count, installed);
    }
}

test "an added pointer-free constant occupies one stored payload" {
    var empty_size: usize = 0;
    for ([_]usize{ 0, 65536 }) |length| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const bytes_type = try b.schema(.bytes);
        const unit = try b.scalar(void);
        const pair = try b.schema(.{ .product = &.{ bytes_type, bytes_type } });
        var writer: data.wire.Writer = .{};
        try writer.natural(length);
        const bytes = try b.allocator().alloc(u8, writer.position + length);
        @memset(bytes, 0x5a);
        writer = .{ .output = bytes };
        try writer.natural(length);
        const first = try b.literal(.{ .schema = bytes_type, .bytes = bytes });
        const second = try b.literal(.{ .schema = bytes_type, .bytes = bytes });
        const main = try b.declare(&.{}, pair, &.{}, &.{});
        try b.define(main, try b.pure(try b.primitive(pair, .product, &.{ first, second }, 0)));
        var compiled = try source.lower(std.testing.allocator, b.module(main, unit));
        defer compiled.deinit();
        try std.testing.expectEqual(@as(usize, 1), compiled.program.constants.len);
        try std.testing.expectEqual(bytes.len, compiled.program.constants[0].bytes.len);
        const output = try std.testing.allocator.alloc(
            u8,
            try data.program_image.encodedLength(compiled.program),
        );
        defer std.testing.allocator.free(output);
        _ = try compiled.encode(std.testing.allocator, output);
        if (length == 0) empty_size = output.len else {
            try std.testing.expectEqual(
                @as(usize, 1),
                std.mem.count(u8, output, bytes[writer.position..]),
            );
            try std.testing.expect(output.len - empty_size >= length);
            // Two nested byte lengths, the constants section length, and the
            // six later directory offsets can each grow by two ULEB bytes.
            try std.testing.expect(output.len - empty_size <= length + 2 * 10);
        }
    }
}

test "public staged emit compiles independently and frees every failed allocation" {
    const Application = struct {
        pub fn emit(b: *source.Builder) !source.Module {
            const integer = try b.scalar(u64);
            const unit = try b.scalar(void);
            const main = try b.declare(&.{}, integer, &.{}, &.{});
            try b.define(main, try b.pure(try b.constant(u64, 42)));
            return b.module(main, unit);
        }
        fn attempt(allocator: std.mem.Allocator) !void {
            var compiled = try @import("../root.zig").program.lower(allocator, @This());
            defer compiled.deinit();
            try std.testing.expectEqual(@as(u8, 42), compiled.program.constants[0].bytes[0]);
            const bytes = try allocator.alloc(
                u8,
                try data.program_image.encodedLength(compiled.program),
            );
            defer allocator.free(bytes);
            _ = try compiled.encode(allocator, bytes);
            try std.testing.expectEqualStrings("ABL_BPI3", bytes[0..8]);
        }
    };
    try Application.attempt(std.testing.allocator);
    try @import("../allocation_testing.zig").check(std.testing.allocator, Application.attempt, .{});
}

test "lexical lambda conversion derives captures and owns emitted data independently" {
    var builder = source.Builder.init(std.testing.allocator);
    const module = try examples.lexical(&builder);
    var compiled = source.lower(std.testing.allocator, module) catch |err| {
        builder.deinit();
        return err;
    };
    defer compiled.deinit();
    builder.deinit();
    try std.testing.expectEqual(@as(usize, 1), compiled.program.constructors.len);
    try std.testing.expectEqual(@as(usize, 1), compiled.program.scopes.captures[0].fields.len);
    try std.testing.expectEqual(@as(usize, 2), compiled.program.functions[1].inputs.len);
    const output = try std.testing.allocator.alloc(
        u8,
        try data.program_image.encodedLength(compiled.program),
    );
    defer std.testing.allocator.free(output);
    _ = try compiled.encode(std.testing.allocator, output);
    var decoded = try data.program_image.decode(std.testing.allocator, output);
    defer decoded.deinit();
}

test "deep bind and value syntax lower with bounded host stack and shared pure subexpressions" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const integer = try b.scalar(u64);
    const unit = try b.scalar(void);
    const zero = try b.constant(u64, 0);
    const empty = try b.constant(void, {});
    const fault = try b.failureLiteral(empty);
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    var value = zero;
    for (0..12_000) |_| value = try b.value(.{
        .schema = integer,
        .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{ value, value },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
        } },
    });
    const first = try b.pure(empty);
    var body = try b.pure(value);
    for (0..12_000) |_| body = try b.bind(try b.variable(unit), first, body);
    try b.define(main, body);
    var compiled = try source.lower(std.testing.allocator, b.module(main, unit));
    defer compiled.deinit();
    var additions: usize = 0;
    for (compiled.program.blocks) |block|
        for (block.instructions) |instruction|
            if (instruction.opcode == .integer_add) {
                additions += 1;
            };
    try std.testing.expectEqual(@as(usize, 12_000), additions);
}

test "source bind lowers non-tail handlers and mutually recursive functions" {
    inline for (.{
        examples.deep,
        examples.recursive,
        examples.generator,
        examples.stateLocal,
        examples.stateShared,
        examples.resourceScalar,
        examples.resourcePair,
        examples.answers,
        examples.scopedReader,
        examples.writerRaise,
        examples.schedulerFifo,
        examples.queensDfs,
        examples.queensBfs,
        examples.cellOrder,
        examples.nested,
        examples.shallow,
        examples.injection,
        examples.indexed,
        examples.abortCustody,
        examples.unwind,
        examples.yieldingCleanup,
        examples.reentrant,
        examples.cloned,
        examples.clauseAbort,
    }) |example| {
        var builder = source.Builder.init(std.testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(std.testing.allocator, try example(&builder));
        defer compiled.deinit();
        try requireAdmitted(compiled.program);
        try canonical(compiled.program);
    }
}

test "tail clauses reject well-typed authored failure and hidden effects at pure admission" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    var compiled = try source.lower(std.testing.allocator, try examples.answers(&b));
    defer compiled.deinit();
    const clause = compiled.program.handlers[0].clauses[0];
    try std.testing.expectEqual(@as(@TypeOf(clause.strategy), .tail), clause.strategy);
    const function = compiled.program.functions[@intCast(clause.function)];
    var bad = compiled.program;
    const blocks = try std.testing.allocator.dupe(data.activation.Block, bad.blocks);
    defer std.testing.allocator.free(blocks);
    const failure_slot = for (function.inputs) |slot| {
        if (function.layout.slots[@intCast(slot)] == bad.roots.failure) break slot;
    } else return error.MissingFailureInput;
    blocks[@intCast(function.entry)].terminator = .{ .fail = failure_slot };
    bad.blocks = blocks;
    try std.testing.expectError(
        error.InvalidProgram,
        data.activation_types.validate(std.testing.allocator, bad),
    );
    bad = compiled.program;
    const functions = try std.testing.allocator.dupe(data.activation.Function, bad.functions);
    defer std.testing.allocator.free(functions);
    functions[@intCast(clause.function)].effects = &.{clause.effect};
    bad.functions = functions;
    try std.testing.expectError(
        error.InvalidEffect,
        data.activation_types.validate(std.testing.allocator, bad),
    );
}

test "library specializations share declarations at one eight and sixty-four installations" {
    const choice = @import("../library/choice.zig");
    const generator = @import("../library/generator.zig");
    const scheduler = @import("../library/scheduler.zig");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const typed = @import("../authoring.zig");
    const author = try typed.Context.init(&b);
    const choices = try choice.family(author, "sharing/choice");
    const region = try author.region();
    const joined = try scheduler.joinType(author, try author.schema(u64), region);
    const task_unit = try author.schema(void);
    const tasks = try generator.create(
        author,
        "sharing/generator",
        task_unit,
        task_unit,
        task_unit,
        .{ .captures = .{ .continuation = &.{} } },
    );
    var declarations: ?usize = null;
    var handlers: ?usize = null;
    var first_handler: @TypeOf((try choice.all(
        author,
        choices,
        try author.schema(u64),
        .{ .captures = .{ .continuation = &.{} }, .residual = &.{} },
    )).handler) = undefined;
    for (0..64) |index| {
        const interpreted = try choice.all(
            author,
            choices,
            try author.schema(u64),
            .{ .captures = .{ .continuation = &.{} }, .residual = &.{} },
        );
        _ = try scheduler.fifo(author, tasks, .{
            .residual = &.{},
            .borrowed_regions = &.{},
        });
        _ = try scheduler.awaiting(author, tasks, joined, .{ .borrowed_regions = &.{region} });
        if (index == 0) {
            declarations = b.functions.items.len;
            handlers = b.handlers.items.len;
            first_handler = interpreted.handler;
        }
        if (index == 0 or index == 7 or index == 63) {
            try std.testing.expectEqual(declarations.?, b.functions.items.len);
            try std.testing.expectEqual(handlers.?, b.handlers.items.len);
            try std.testing.expectEqual(first_handler, interpreted.handler);
        }
    }
    const residual = try b.effect(.{
        .identity = "sharing/residual",
        .payload = unit,
        .result = unit,
    });
    const changed = try choice.all(
        author,
        choices,
        try author.schema(u64),
        .{
            .captures = .{ .continuation = &.{} },
            .residual = &.{try typed.interop.operation(author, residual)},
        },
    );
    try std.testing.expect(changed.handler != first_handler);
    try std.testing.expectEqual(declarations.? + 2, b.functions.items.len);
    try std.testing.expectEqual(handlers.? + 1, b.handlers.items.len);
}

test "failure custody does not silently discard an owned value on a normal branch" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const module = try examples.abortCustody(&b);
    const first = b.terms.items[@intCast(b.functions.items[@intCast(module.entry)].body.?)].bind;
    const aborted = b.terms.items[@intCast(first.next)].conditional.when_false;
    const failure = b.terms.items[@intCast(aborted)].bind.next;
    const value = b.terms.items[@intCast(failure)].fail;
    b.terms.items[@intCast(failure)] = .{ .value = value };
    try std.testing.expectError(
        error.InvalidOwnership,
        source.lower(std.testing.allocator, b.module(module.entry, module.failure)),
    );
}

test "converting an owned capture consumes the original before any template activation" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const module = try examples.cloned(&b);
    const clause = b.handlers.items[0].clauses[0].function;
    const conversion = b.terms.items[@intCast(b.functions.items[@intCast(clause)].body.?)].bind;
    const saved = b.terms.items[@intCast(conversion.next)].bind;
    const resumed = b.terms.items[@intCast(saved.next)].bind.value;
    const original = try b.reference(b.parameter(clause, 3));
    b.terms.items[@intCast(resumed)].resume_value.resumption = original;
    {
        try std.testing.expectError(
            error.UnavailableSlot,
            source.lowerObserved(
                std.testing.allocator,
                b.module(module.entry, module.failure),
                .{},
            ),
        );
    }
}

test "unused binding annotations and undeclared captures still reject" {
    var builder = source.Builder.init(std.testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    const unused = try builder.variable(integer);
    try builder.define(
        main,
        try builder.bind(
            unused,
            try builder.pure(try builder.constant(bool, true)),
            try builder.pure(try builder.constant(u64, 42)),
        ),
    );
    var diagnostic: source.Diagnostic = .{};
    try std.testing.expectError(
        error.TypeMismatch,
        source.lowerObserved(
            std.testing.allocator,
            builder.module(main, unit),
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(error.TypeMismatch, diagnostic.code.?);
    try std.testing.expectEqual(builder.functions.items[@intCast(main)].body.?, diagnostic.term.?);
}

test "source clients cannot introduce or eliminate a private resource representation" {
    inline for (.{ true, false }) |introduce| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        _ = try examples.resourceScalar(&b);
        const integer = try b.scalar(u64);
        const unit = try b.scalar(void);
        var resource: data.program.Id = undefined;
        for (
            b.schemas.items,
            0..,
        ) |schema, id| if (schema == .internal and schema.internal == .abstract_resource) {
            resource = id;
            break;
        };
        const main = try b.declare(
            &.{},
            if (introduce) unit else integer,
            if (introduce) &.{} else &.{0},
            &.{},
        );
        const owned = try b.variable(resource);
        if (introduce) {
            const forged = try b.pure(try b.primitive(
                resource,
                .resource_pack,
                &.{try b.constant(u64, 41)},
                0,
            ));
            try b.define(
                main,
                try b.bind(owned, forged, try b.term(.{ .fail = try b.constant(void, {}) })),
            );
        } else {
            const acquired = try b.term(.{ .call = .{
                .function = b.resources.items[0].introducers[0],
                .arguments = &.{},
            } });
            const exposed = try b.pure(try b.primitive(
                integer,
                .resource_unpack,
                &.{try b.reference(owned)},
                0,
            ));
            try b.define(main, try b.bind(owned, acquired, exposed));
        }
        try std.testing.expectError(
            error.InvalidOwnership,
            source.lower(std.testing.allocator, b.module(main, unit)),
        );
    }
}

test "a resource borrow cannot escape its protected body even when immediately read by the caller" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const original = try examples.resourceScalar(&b);
    const main_bind = try @import("fixture_inspection.zig").resourceEntry(&b, original.entry);
    const protected = main_bind.next;
    const body_value = b.terms.items[@intCast(protected)].protect.body;
    const body_function = b.values.items[@intCast(body_value)].expression.lambda;
    const parameter = b.parameter(body_function, 0);
    const borrowed = b.variables.items[@intCast(parameter)];
    var signature = b.schemas.items[
        @intCast(b.values.items[
            @intCast(body_value)
        ].schema)
    ].internal.computation;
    signature.result = borrowed;
    const schema = try b.schema(.{ .internal = .{ .computation = signature } });
    b.values.items[@intCast(body_value)].schema = schema;
    b.functions.items[@intCast(body_function)].result = borrowed;
    const returned = try b.pure(try b.reference(parameter));
    b.functions.items[@intCast(body_function)].body = returned;
    const escaped = try b.variable(borrowed);
    const read = try b.term(.{ .call = .{
        .function = b.resources.items[0].eliminators[0],
        .arguments = &.{try b.reference(escaped)},
    } });
    const next = try b.bind(escaped, protected, read);
    const changed = try b.bind(main_bind.variable, main_bind.value, next);
    b.functions.items[@intCast(original.entry)].body = changed;
    {
        try std.testing.expectError(
            error.InvalidOwnership,
            source.lowerObserved(
                std.testing.allocator,
                b.module(original.entry, original.failure),
                .{},
            ),
        );
    }
}

test "latent multi use rejects an exclusive caller capture but permits capture before acquisition" {
    inline for (.{ true, false }) |acquire_first| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const original = try examples.resourceScalar(&b);
        const unit = try b.scalar(void);
        const multiple = try b.effect(.{
            .identity = "test/latent-multi",
            .payload = unit,
            .result = unit,
            .control_use = .multi,
        });
        const callee = try b.declare(&.{}, unit, &.{multiple}, &.{});
        try b.define(
            callee,
            try b.term(.{ .perform = .{
                .effect = multiple,
                .payload = try b.constant(void, {}),
            } }),
        );
        const call = try b.term(.{ .call = .{ .function = callee, .arguments = &.{} } });
        const old_body = b.functions.items[@intCast(original.entry)].body.?;
        const old_bind = b.terms.items[@intCast(old_body)].bind;
        const ignored = try b.variable(unit);
        const changed = if (acquire_first) try b.bind(
            old_bind.variable,
            old_bind.value,
            try b.bind(ignored, call, old_bind.next),
        ) else try b.bind(ignored, call, old_body);
        b.functions.items[@intCast(original.entry)].body = changed;
        b.functions.items[@intCast(original.entry)].effects = try b.allocator().dupe(
            data.program.Id,
            &.{ 0, 1, 2, multiple },
        );
        if (acquire_first) {
            var diagnostic: source.Diagnostic = .{};
            try std.testing.expectError(
                error.InvalidOwnership,
                source.lowerObserved(
                    std.testing.allocator,
                    b.module(original.entry, original.failure),
                    .{ .diagnostic = &diagnostic },
                ),
            );
            try std.testing.expectEqual(error.InvalidOwnership, diagnostic.code.?);
            try std.testing.expectEqual(original.entry, diagnostic.function.?);
            try std.testing.expectEqual(callee, diagnostic.target.callee.?);
            try std.testing.expect(
                diagnostic.target.block != null and diagnostic.target.slot != null,
            );
        } else {
            var compiled = try source.lower(
                std.testing.allocator,
                b.module(original.entry, original.failure),
            );
            compiled.deinit();
        }
    }
}

fn olderCapabilityHandler(
    b: *source.Builder,
    unit: source.Id,
    integer: source.Id,
    effect: source.Id,
    cap: source.Id,
) !source.Id {
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = integer,
        .capture_bound = &.{ unit, integer, cap },
        .handled = &.{effect},
        .mode = .deep,
        .use = .multi,
    } } });
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    const clause = try b.declare(&.{ unit, token }, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    try b.define(
        clause,
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(clause, 1)),
            .argument = try b.constant(void, {}),
        } }),
    );
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    return handler;
}

fn hiddenOlderCapability(
    b: *source.Builder,
    unit: source.Id,
    integer: source.Id,
    effect: source.Id,
    cap: source.Id,
    handler: source.Id,
) !source.Id {
    const hidden = try b.declare(&.{cap}, integer, &.{}, &.{});
    const inner = try b.declare(&.{cap}, integer, &.{effect}, &.{});
    const escaped = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(hidden, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(
        inner,
        try b.bind(try b.variable(unit), escaped, try b.pure(try b.constant(u64, 0))),
    );
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{effect},
        .capture_bound = &.{cap},
    } } });
    try b.define(
        hidden,
        try b.term(.{ .handle = .{
            .handler = handler,
            .body = try b.lambda(inner, inner_type),
        } }),
    );
    return hidden;
}

test "reinstalling a family cannot hide captured older capabilities from caller effects" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const resource = try b.resource(integer);
    const effect = try b.effect(.{
        .identity = "test/older-instance",
        .payload = unit,
        .result = unit,
        .control_use = .multi,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const handler = try olderCapabilityHandler(&b, unit, integer, effect, cap);
    const factory = try b.declare(&.{}, resource, &.{}, &.{});
    const release = try b.declare(&.{resource}, integer, &.{}, &.{});
    try b.resourceAuthority(resource, &.{factory}, &.{release});
    try b.define(
        factory,
        try b.pure(try b.primitive(resource, .resource_pack, &.{try b.constant(u64, 41)}, 0)),
    );
    try b.define(
        release,
        try b.pure(try b.primitive(
            integer,
            .resource_unpack,
            &.{try b.reference(b.parameter(release, 0))},
            0,
        )),
    );
    const hidden = try hiddenOlderCapability(&b, unit, integer, effect, cap, handler);
    const outer = try b.declare(&.{cap}, integer, &.{effect}, &.{});
    const owned = try b.variable(resource);
    const used = try b.term(.{ .call = .{
        .function = release,
        .arguments = &.{try b.reference(owned)},
    } });
    const call = try b.term(.{ .call = .{
        .function = hidden,
        .arguments = &.{try b.reference(b.parameter(outer, 0))},
    } });
    try b.define(
        outer,
        try b.bind(
            owned,
            try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } }),
            try b.bind(try b.variable(integer), call, used),
        ),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = integer,
        .effects = &.{effect},
    } } });
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handler,
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    try std.testing.expectError(
        error.InvalidEffect,
        source.lower(std.testing.allocator, b.module(main, unit)),
    );
}

test "large sparse region names preserve alpha-equivalent canonical images" {
    const Example = struct {
        fn compile(parent: std.mem.Allocator, region_id: data.program.Id) !source.Compiled {
            return compileObserved(parent, region_id, .{});
        }
        fn compileObserved(
            parent: std.mem.Allocator,
            region_id: data.program.Id,
            options: source.CompileOptions,
        ) !source.Compiled {
            var b = source.Builder.init(parent);
            defer b.deinit();
            b.region_count = region_id + 1;
            const unit = try b.scalar(void);
            const integer = try b.scalar(u64);
            const region_schema = try b.schema(.{ .internal = .{ .region = region_id } });
            const main = try b.declare(&.{}, integer, &.{}, &.{});
            const body = try b.declare(&.{region_schema}, integer, &.{}, &.{region_id});
            try b.define(body, try b.pure(try b.constant(u64, 42)));
            const signature = try b.schema(.{ .internal = .{ .computation = .{
                .parameters = &.{region_schema},
                .result = integer,
                .regions = &.{region_id},
            } } });
            try b.define(
                main,
                try b.term(.{ .with_region = .{
                    .region = region_id,
                    .body = try b.lambda(body, signature),
                } }),
            );
            return source.lowerObserved(parent, b.module(main, unit), options);
        }
    };
    var small = try Example.compile(std.testing.allocator, 0);
    defer small.deinit();
    var large = try Example.compile(std.testing.allocator, std.math.maxInt(data.program.Id) - 1);
    defer large.deinit();
    try std.testing.expectEqual(@as(data.program.Id, 1), large.program.scopes.region_count);
    var small_bytes: [512]u8 = undefined;
    var large_bytes: [512]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        try small.encode(std.testing.allocator, &small_bytes),
        try large.encode(std.testing.allocator, &large_bytes),
    );
    var diagnostic: data.coalescing.Diagnostic = .{};
    var optimized = try Example.compileObserved(
        std.testing.allocator,
        std.math.maxInt(data.program.Id) - 1,
        .{ .coalescing = .{ .diagnostic = &diagnostic } },
    );
    defer optimized.deinit();
    var optimized_bytes: [512]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        try large.encode(std.testing.allocator, &large_bytes),
        try optimized.encode(std.testing.allocator, &optimized_bytes),
    );
    try std.testing.expectEqual(@as(?anyerror, null), diagnostic.code);
}

test "capture diagnostics name the responsible source variable without changing compiled bytes" {
    {
        const Trace = struct {
            stages: std.ArrayList(source.CompileStage) = .empty,
            fn enter(context: *anyopaque, stage: source.CompileStage) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.stages.append(
                    std.testing.allocator,
                    stage,
                ) catch @panic("test trace allocation");
            }
        };
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try examples.lexical(&b);
        var original = try source.lowerObserved(std.testing.allocator, module, .{});
        defer original.deinit();
        var trace: Trace = .{};
        defer trace.stages.deinit(std.testing.allocator);
        var diagnostic: source.Diagnostic = .{};
        var observed = try source.lowerObserved(
            std.testing.allocator,
            module,
            .{
                .diagnostic = &diagnostic,
                .observer = .{ .context = &trace, .enter = Trace.enter },
            },
        );
        defer observed.deinit();
        try std.testing.expectEqualSlices(
            source.CompileStage,
            &.{
                .source_check,
                .lowering,
                .target_check,
                .direct_optimization,
                .coalescing,
                .complete,
            },
            trace.stages.items,
        );
        try std.testing.expect(diagnostic.code == null and diagnostic.phase == .complete);
        var a: [1024]u8 = undefined;
        var c: [1024]u8 = undefined;
        try std.testing.expectEqualSlices(
            u8,
            try original.encode(std.testing.allocator, &a),
            try observed.encode(std.testing.allocator, &c),
        );
        for (b.schemas.items) |*schema|
            if (schema.* == .internal and
                schema.internal == .computation)
            {
                schema.internal.computation.capture_bound = &.{};
            };
        try std.testing.expectError(
            error.InvalidOwnership,
            source.lowerObserved(
                std.testing.allocator,
                b.module(module.entry, module.failure),
                .{ .diagnostic = &diagnostic },
            ),
        );
        try std.testing.expectEqual(source.CompileStage.target_check, diagnostic.phase);
        try std.testing.expectEqual(@as(data.program.Id, 1), diagnostic.function.?);
        try std.testing.expectEqual(b.parameter(module.entry, 0), diagnostic.variable.?);
        try std.testing.expect(
            diagnostic.target.capture != null and diagnostic.target.field != null,
        );
    }
}

test "unbound handler captures identify the return or operation clause" {
    inline for (.{ true, false }) |return_clause| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try examples.deep(&b);
        const handler = b.handlers.items[0];
        const function = if (return_clause)
            handler.return_function
        else
            handler.clauses[0].function;
        const integer = try b.scalar(u64);
        const free = try b.variable(integer);
        // Keep the original function body well typed while introducing a free
        // variable in this specific handler function.
        const unused = try b.variable(integer);
        b.functions.items[@intCast(function)].body = try b.bind(
            unused,
            try b.pure(try b.reference(free)),
            b.functions.items[@intCast(function)].body.?,
        );
        var diagnostic: source.Diagnostic = .{};
        try std.testing.expectError(
            error.UnboundVariable,
            source.lowerObserved(
                std.testing.allocator,
                b.module(module.entry, module.failure),
                .{ .diagnostic = &diagnostic },
            ),
        );
        try std.testing.expectEqual(function, diagnostic.function.?);
        try std.testing.expectEqual(free, diagnostic.variable.?);
        try std.testing.expectEqual(
            b.functions.items[@intCast(function)].body.?,
            diagnostic.term.?,
        );
    }
}

test "resource authority sets survive every three-function root permutation" {
    const p = data.program;
    for ([_]u3{ 3, 5, 6, 7 }) |mask| for (0..3) |entry| {
        if (mask & (@as(u3, 1) << @intCast(entry)) == 0) continue;
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const integer = try b.scalar(u64);
        const resource = try b.resource(integer);
        var functions: [3]p.Id = undefined;
        var authorities: std.ArrayList(p.Id) = .empty;
        for (&functions, 0..) |*function, index| {
            function.* = try b.declare(&.{}, integer, &.{}, &.{});
            if (mask & (@as(u3, 1) << @intCast(index)) != 0)
                try authorities.append(b.allocator(), function.*);
        }
        try b.resourceAuthority(resource, authorities.items, authorities.items);
        for (functions, 0..) |function, index| {
            const value = try b.constant(u64, index);
            const body = if (mask & (@as(u3, 1) << @intCast(index)) != 0) blk: {
                const wrapped = try b.primitive(resource, .resource_pack, &.{value}, 0);
                break :blk try b.primitive(integer, .resource_unpack, &.{wrapped}, 0);
            } else value;
            try b.define(function, try b.pure(body));
        }
        var compiled = try source.lower(std.testing.allocator, b.module(functions[entry], integer));
        defer compiled.deinit();
        try canonical(compiled.program);
        const admitted = compiled.program.scopes.resources[0];
        try std.testing.expectEqual(@as(usize, @popCount(mask)), admitted.introducers.len);
        try std.testing.expectEqualSlices(p.Id, admitted.introducers, admitted.eliminators);
    };
}

test "definitely failing bind retains an unused owned function argument" {
    for (0..4) |form| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const integer = try b.scalar(u64);
        const resource = try b.resource(integer);
        const factory = try b.declare(&.{}, resource, &.{}, &.{});
        try b.resourceAuthority(resource, &.{factory}, &.{});
        try b.define(
            factory,
            try b.pure(try b.primitive(
                resource,
                .resource_pack,
                &.{try b.constant(u64, 41)},
                0,
            )),
        );
        const helper = try b.declare(&.{resource}, unit, &.{}, &.{});
        const failed = try b.term(.{ .fail = try b.constant(u64, 9) });
        const left = switch (form) {
            0 => failed,
            1 => try b.term(.{ .yield_then = failed }),
            2 => try b.term(.{ .conditional = .{
                .condition = try b.constant(bool, true),
                .when_true = failed,
                .when_false = failed,
            } }),
            else => try b.pure(try b.constant(void, {})),
        };
        try b.define(
            helper,
            try b.bind(try b.variable(unit), left, try b.pure(try b.constant(void, {}))),
        );
        const main = try b.declare(&.{}, unit, &.{}, &.{});
        const owned = try b.variable(resource);
        const acquired = try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } });
        const called = try b.term(.{ .call = .{
            .function = helper,
            .arguments = &.{try b.reference(owned)},
        } });
        try b.define(main, try b.bind(owned, acquired, called));
        const module = b.module(main, integer);
        if (form == 3) {
            try std.testing.expectError(
                error.InvalidOwnership,
                source.lower(std.testing.allocator, module),
            );
        } else {
            var compiled = try source.lower(std.testing.allocator, module);
            defer compiled.deinit();
        }
    }
}

fn borrowedChoiceHandler(
    b: *source.Builder,
    unit: source.Id,
    boolean: source.Id,
    cell: source.Id,
    sequence: source.Id,
    r: source.Id,
) !struct { effect: source.Id, capability: source.Id, handler: source.Id } {
    const choice = @import("../library/choice.zig");
    const typed = @import("../authoring.zig");
    const author = try typed.Context.init(b);
    const family = try choice.family(author, "borrowed-choice");
    const c = .{
        .effect = try typed.interop.operationId(author, family.effect()),
        .capability = try typed.interop.schemaId(author, family.capability()),
    };
    const capture_ids = [_]data.program.Id{ unit, boolean, cell, sequence, c.capability };
    var captures: [capture_ids.len]*const typed.Schema(typed.Dynamic) = undefined;
    for (capture_ids, &captures) |id, *schema| schema.* = try typed.interop.schema(author, id);
    const interpreted = try choice.all(
        author,
        family,
        try typed.interop.schema(author, cell),
        .{
            .captures = .{ .continuation = &captures },
            .residual = &.{},
            .owned_regions = &.{},
            .borrowed_regions = &.{try typed.interop.region(author, r)},
        },
    );
    const all = .{
        .handler = try typed.interop.handlerId(author, interpreted.handler),
        .answer = try typed.interop.schemaId(author, interpreted.answer),
    };
    return .{ .effect = c.effect, .capability = c.capability, .handler = all.handler };
}

test "choice returns borrowed cells to a caller inside their live region" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const integer = try b.scalar(u64);
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = integer, .region = r } } });
    const sequence = try b.schema(.{ .seq = cell });
    const c = try borrowedChoiceHandler(&b, unit, boolean, cell, sequence, r);
    const body = try b.declare(&.{ c.capability, cell }, cell, &.{c.effect}, &.{r});
    const choose = try b.term(.{ .perform = .{
        .effect = c.effect,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } });
    try b.define(
        body,
        try b.bind(
            try b.variable(boolean),
            choose,
            try b.pure(try b.reference(b.parameter(body, 1))),
        ),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ c.capability, cell },
        .result = cell,
        .effects = &.{c.effect},
        .regions = &.{r},
    } } });
    const scope = try b.declare(&.{region}, integer, &.{}, &.{r});
    const allocated = try b.variable(cell);
    const results = try b.variable(sequence);
    const install = try b.term(.{ .handle = .{
        .handler = c.handler,
        .body = try b.lambda(body, body_type),
        .arguments = &.{try b.reference(allocated)},
    } });
    const count = try b.pure(try b.primitive(
        integer,
        .sequence_length,
        &.{try b.reference(results)},
        0,
    ));
    const allocation = try b.pure(try b.primitive(
        cell,
        .cell_new,
        &.{ try b.reference(b.parameter(scope, 0)), try b.constant(u64, 42) },
        0,
    ));
    try b.define(scope, try b.bind(allocated, allocation, try b.bind(results, install, count)));
    const scope_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = integer,
        .regions = &.{r},
    } } });
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(
        main,
        try b.term(.{ .with_region = .{ .region = r, .body = try b.lambda(scope, scope_type) } }),
    );
    var compiled = try source.lower(std.testing.allocator, b.module(main, unit));
    defer compiled.deinit();
    try canonical(compiled.program);
}

fn emptyRegionChoiceHandler(
    b: *source.Builder,
    boolean: source.Id,
    r: source.Id,
    bounded: bool,
) !struct {
    effect: source.Id,
    capability: source.Id,
    handler: source.Id,
    answer: source.Id,
} {
    const choice = @import("../library/choice.zig");
    const typed = @import("../authoring.zig");
    const author = try typed.Context.init(b);
    const family = try choice.family(author, "empty-region-choice");
    const c = .{
        .effect = try typed.interop.operationId(author, family.effect()),
        .capability = try typed.interop.schemaId(author, family.capability()),
    };
    const capture_ids = [_]data.program.Id{ boolean, c.capability };
    var captures: [capture_ids.len]*const typed.Schema(typed.Dynamic) = undefined;
    for (capture_ids, &captures) |id, *schema| schema.* = try typed.interop.schema(author, id);
    const interpreted = try choice.all(
        author,
        family,
        try typed.interop.schema(author, boolean),
        .{
            .captures = .{ .continuation = &captures },
            .residual = &.{},
            .owned_regions = if (bounded) &.{try typed.interop.region(author, r)} else &.{},
            .borrowed_regions = &.{},
        },
    );
    const all = .{
        .handler = try typed.interop.handlerId(author, interpreted.handler),
        .answer = try typed.interop.schemaId(author, interpreted.answer),
    };
    return .{
        .effect = c.effect,
        .capability = c.capability,
        .handler = all.handler,
        .answer = all.answer,
    };
}

test "escaping choice captures own even a region with no live cells" {
    inline for (.{ false, true }) |bounded| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const boolean = try b.scalar(bool);
        const r = b.region();
        const region = try b.schema(.{ .internal = .{ .region = r } });
        const c = try emptyRegionChoiceHandler(&b, boolean, r, bounded);
        const body = try b.declare(&.{c.capability}, boolean, &.{c.effect}, &.{});
        const inside = try b.declare(&.{region}, boolean, &.{c.effect}, &.{r});
        try b.define(
            inside,
            try b.term(.{ .perform = .{
                .effect = c.effect,
                .capability = try b.reference(b.parameter(body, 0)),
                .payload = try b.constant(void, {}),
            } }),
        );
        const inside_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{region},
            .result = boolean,
            .effects = &.{c.effect},
            .capture_bound = &.{c.capability},
            .regions = &.{r},
        } } });
        try b.define(
            body,
            try b.term(.{ .with_region = .{
                .region = r,
                .body = try b.lambda(inside, inside_type),
            } }),
        );
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{c.capability},
            .result = boolean,
            .effects = &.{c.effect},
        } } });
        const main = try b.declare(&.{}, c.answer, &.{}, &.{});
        try b.define(
            main,
            try b.term(.{ .handle = .{
                .handler = c.handler,
                .body = try b.lambda(body, body_type),
            } }),
        );
        const module = b.module(main, unit);
        if (bounded) {
            var compiled = try source.lower(std.testing.allocator, module);
            defer compiled.deinit();
        } else if (source.lower(std.testing.allocator, module)) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.ExpectedCaptureRejection;
        } else |err| try std.testing.expectEqual(error.InvalidOwnership, err);
    }
}

fn projectionPayload(
    b: *source.Builder,
    schema: data.program.Id,
    value: data.program.Id,
) !data.program.Id {
    return b.value(.{ .schema = schema, .expression = .{ .primitive = .{
        .opcode = .variant_payload,
        .operands = &.{value},
        .immediate = 1,
        .failures = &.{.{
            .kind = .invalid_variant,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}

fn aggregateProjection(
    b: *source.Builder,
    pair: data.program.Id,
    fresh: data.program.Id,
    older: data.program.Id,
    form: usize,
) !data.program.Id {
    const value = try b.primitive(pair, .product, &.{ fresh, older }, 0);
    if (form == 0)
        return b.primitive(pair, .select, &.{ try b.constant(bool, true), value, value }, 0);
    const unit = try b.scalar(void);
    const sequence = try b.schema(.{ .seq = pair });
    const optional = try b.schema(.{ .sum = &.{ unit, pair } });
    const values = try b.primitive(sequence, .sequence, &.{value}, 0);
    const zero = try b.constant(u64, 0);
    const transformed = switch (form) {
        1 => try b.primitive(sequence, .sequence_concat, &.{ values, values }, 0),
        2 => blk: {
            const empty = try b.primitive(sequence, .sequence, &.{}, 0);
            break :blk try b.primitive(sequence, .sequence_append, &.{ empty, value }, 0);
        },
        3 => try b.primitive(sequence, .sequence_take, &.{ values, try b.constant(u64, 1) }, 0),
        4 => try b.value(.{ .schema = sequence, .expression = .{ .primitive = .{
            .opcode = .sequence_set,
            .operands = &.{ values, zero, value },
            .failures = &.{.{
                .kind = .invalid_index,
                .value = try b.failureLiteral(try b.constant(void, {})),
            }},
        } } }),
        5 => {
            const parts = try b.schema(.{ .product = &.{ pair, sequence } });
            const result = try b.schema(.{ .sum = &.{ unit, parts } });
            const popped = try b.primitive(result, .sequence_pop, &.{values}, 0);
            const present = try projectionPayload(b, parts, popped);
            return b.primitive(pair, .field, &.{present}, 0);
        },
        else => {
            const parts = try b.schema(.{ .product = &.{ sequence, optional } });
            const popped = try b.primitive(parts, .sequence_pop_last, &.{values}, 0);
            const last = try b.primitive(optional, .field, &.{popped}, 1);
            return projectionPayload(b, pair, last);
        },
    };
    const found = try b.primitive(optional, .sequence_get, &.{ transformed, zero }, 0);
    return projectionPayload(b, pair, found);
}

fn capabilityReturnHandlers(
    b: *source.Builder,
    unit: source.Id,
    effect: source.Id,
    cap: source.Id,
) ![2]source.Id {
    var handlers: [2]data.program.Id = undefined;
    for (&handlers, [_]data.program.Id{ unit, cap }) |*handler, result| {
        const returns = try b.declare(&.{result}, result, &.{}, &.{});
        try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
        const token = try b.schema(.{ .internal = .{ .resumption = .{
            .effect = effect,
            .input = unit,
            .answer = result,
            .capture_bound = &.{ unit, cap },
            .handled = &.{effect},
            .mode = .deep,
            .use = .linear,
        } } });
        const clause = try b.declare(&.{ unit, token }, result, &.{}, &.{});
        try b.define(clause, try b.term(.{ .fail = try b.constant(void, {}) }));
        handler.* = try b.handler(.{
            .mode = .deep,
            .input = result,
            .answer = result,
            .return_function = returns,
            .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
        });
    }
    return handlers;
}

fn capabilityProjectionBody(
    b: *source.Builder,
    form: usize,
    cap: source.Id,
    pair: source.Id,
    sequence: source.Id,
    optional: source.Id,
) !source.Id {
    const inner = try b.declare(&.{ cap, cap }, cap, &.{}, &.{});
    const fresh = try b.reference(b.parameter(inner, 0));
    const older = try b.reference(b.parameter(inner, 1));
    const selected = if (form % 2 == 0) fresh else older;
    const returned = switch (form / 2) {
        0 => try b.pure(selected),
        1 => try b.pure(try b.primitive(
            cap,
            .field,
            &.{try b.primitive(pair, .product, &.{ fresh, older }, 0)},
            form % 2,
        )),
        2 => blk: {
            const identity = try b.declare(&.{cap}, cap, &.{}, &.{});
            try b.define(identity, try b.pure(try b.reference(b.parameter(identity, 0))));
            break :blk try b.term(.{ .call = .{
                .function = identity,
                .arguments = &.{selected},
            } });
        },
        3 => blk: {
            const items = try b.primitive(sequence, .sequence, &.{selected}, 0);
            const found = try b.primitive(
                optional,
                .sequence_get,
                &.{ items, try b.constant(u64, 0) },
                0,
            );
            const extracted = try b.value(.{
                .schema = cap,
                .expression = .{ .primitive = .{
                    .opcode = .variant_payload,
                    .operands = &.{found},
                    .immediate = 1,
                    .failures = &.{.{
                        .kind = .invalid_variant,
                        .value = try b.failureLiteral(try b.constant(void, {})),
                    }},
                } },
            });
            break :blk try b.pure(extracted);
        },
        else => blk: {
            const value = try aggregateProjection(b, pair, fresh, older, form / 2 - 4);
            break :blk try b.pure(try b.primitive(cap, .field, &.{value}, form % 2));
        },
    };
    try b.define(inner, returned);
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ cap, cap },
        .result = cap,
    } } });
    return b.lambda(inner, inner_type);
}

fn capabilityReturnModule(
    b: *source.Builder,
    unit: source.Id,
    effect: source.Id,
    cap: source.Id,
    handlers: [2]source.Id,
    inner_body: source.Id,
) !source.Module {
    const outer = try b.declare(&.{cap}, unit, &.{effect}, &.{});
    const answer = try b.variable(cap);
    const installed = try b.term(.{ .handle = .{
        .handler = handlers[1],
        .body = inner_body,
        .arguments = &.{try b.reference(b.parameter(outer, 0))},
    } });
    const use = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(answer),
        .payload = try b.constant(void, {}),
    } });
    try b.define(outer, try b.bind(answer, installed, use));
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = unit,
        .effects = &.{effect},
    } } });
    const main = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handlers[0],
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    const module = b.module(main, unit);
    return module;
}

test "handler return distinguishes fresh capabilities from older same-family values" {
    var rejected_valid = false;
    for (0..22) |form| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const effect = try b.effect(.{
            .identity = "capability-return",
            .payload = unit,
            .result = unit,
            .external = false,
        });
        const cap = try b.schema(.{ .internal = .{ .capability = effect } });
        const pair = try b.schema(.{ .product = &.{ cap, cap } });
        const sequence = try b.schema(.{ .seq = cap });
        const optional = try b.schema(.{ .sum = &.{ unit, cap } });
        const handlers = try capabilityReturnHandlers(&b, unit, effect, cap);
        const inner_body = try capabilityProjectionBody(&b, form, cap, pair, sequence, optional);
        const module = try capabilityReturnModule(&b, unit, effect, cap, handlers, inner_body);
        var diagnostic: source.Diagnostic = .{};
        if (form % 2 == 1) {
            if (source.lower(std.testing.allocator, module)) |result| {
                var compiled = result;
                compiled.deinit();
            } else |err| {
                std.debug.print(
                    "valid capability projection {d}: {s}\n",
                    .{ form, @errorName(err) },
                );
                rejected_valid = true;
            }
        } else if (source.lowerObserved(
            std.testing.allocator,
            module,
            .{ .diagnostic = &diagnostic },
        )) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.ExpectedCapabilityEscapeRejection;
        } else |err| {
            try std.testing.expectEqual(error.InvalidOwnership, err);
            try std.testing.expectEqual(.target_check, diagnostic.phase);
            try std.testing.expect(diagnostic.target.block != null);
            try std.testing.expect(diagnostic.target.callee != null);
            try std.testing.expect(diagnostic.target.handler != null);
        }
    }
    try std.testing.expect(!rejected_valid);
}

fn storedCapabilityHandler(
    b: *source.Builder,
    unit: source.Id,
    r: source.Id,
    effect: source.Id,
    cap: source.Id,
    cell: source.Id,
) !source.Id {
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = unit,
        .capture_bound = &.{ unit, cap, cell },
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
        .owned_regions = &.{r},
    } } });
    const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ unit, token }, unit, &.{}, &.{});
    try b.define(clause, try b.term(.{ .fail = try b.constant(void, {}) }));
    const handler = try b.handler(.{
        .mode = .deep,
        .input = unit,
        .answer = unit,
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    return handler;
}

fn storedCapabilityBody(
    b: *source.Builder,
    form: usize,
    unit: source.Id,
    r: source.Id,
    cap: source.Id,
    cell: source.Id,
) !source.Id {
    const inner = try b.declare(&.{ cap, cap, cell }, unit, &.{}, &.{r});
    const stored = try b.reference(b.parameter(inner, if (form % 2 == 0) 0 else 1));
    const target = try b.reference(b.parameter(inner, 2));
    const write = if (form < 2) try b.pure(try b.primitive(
        unit,
        .cell_set,
        &.{ target, stored },
        0,
    )) else blk: {
        const helper = try b.declare(&.{ cell, cap }, unit, &.{}, &.{r});
        try b.define(
            helper,
            try b.pure(try b.primitive(
                unit,
                .cell_set,
                &.{
                    try b.reference(b.parameter(helper, 0)),
                    try b.reference(b.parameter(helper, 1)),
                },
                0,
            )),
        );
        break :blk try b.term(.{ .call = .{
            .function = helper,
            .arguments = &.{ target, stored },
        } });
    };
    try b.define(inner, write);
    const inner_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{ cap, cap, cell },
        .result = unit,
        .regions = &.{r},
    } } });
    return b.lambda(inner, inner_type);
}

fn storedCapabilityModule(
    b: *source.Builder,
    unit: source.Id,
    r: source.Id,
    region: source.Id,
    effect: source.Id,
    cap: source.Id,
    cell: source.Id,
    handler: source.Id,
    inner_body: source.Id,
) !source.Module {
    const outer = try b.declare(&.{cap}, unit, &.{effect}, &.{});
    const scope = try b.declare(&.{region}, unit, &.{effect}, &.{r});
    const older = try b.reference(b.parameter(outer, 0));
    const allocated = try b.variable(cell);
    const installed = try b.term(.{ .handle = .{
        .handler = handler,
        .body = inner_body,
        .arguments = &.{ older, try b.reference(allocated) },
    } });
    const read = try b.primitive(cap, .cell_get, &.{try b.reference(allocated)}, 0);
    const use = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = read,
        .payload = try b.constant(void, {}),
    } });
    const allocation = try b.pure(try b.primitive(
        cell,
        .cell_new,
        &.{ try b.reference(b.parameter(scope, 0)), older },
        0,
    ));
    try b.define(
        scope,
        try b.bind(allocated, allocation, try b.bind(try b.variable(unit), installed, use)),
    );
    const scope_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = unit,
        .effects = &.{effect},
        .capture_bound = &.{cap},
        .regions = &.{r},
    } } });
    try b.define(
        outer,
        try b.term(.{ .with_region = .{
            .region = r,
            .body = try b.lambda(scope, scope_type),
        } }),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = unit,
        .effects = &.{effect},
    } } });
    const main = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handler,
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    const module = b.module(main, unit);
    return module;
}

test "a nested handler cannot leave its fresh capability in an older cell" {
    for (0..4) |form| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const unit = try b.scalar(void);
        const r = b.region();
        const region = try b.schema(.{ .internal = .{ .region = r } });
        const effect = try b.effect(.{
            .identity = "stored-capability",
            .payload = unit,
            .result = unit,
            .external = false,
        });
        const cap = try b.schema(.{ .internal = .{ .capability = effect } });
        const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = cap, .region = r } } });
        const handler = try storedCapabilityHandler(&b, unit, r, effect, cap, cell);
        const inner_body = try storedCapabilityBody(&b, form, unit, r, cap, cell);
        const module = try storedCapabilityModule(
            &b,
            unit,
            r,
            region,
            effect,
            cap,
            cell,
            handler,
            inner_body,
        );
        if (form % 2 == 1) {
            var compiled = try source.lower(std.testing.allocator, module);
            defer compiled.deinit();
        } else if (source.lower(std.testing.allocator, module)) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.ExpectedCapabilityStoreRejection;
        } else |err| try std.testing.expectEqual(error.InvalidOwnership, err);
    }
}

fn successorRowHandlers(
    b: *source.Builder,
    comptime correct: bool,
    unit: source.Id,
    handled: source.Id,
    residual: source.Id,
    before: source.Id,
    after: source.Id,
) !struct { successor: source.Id, initial: source.Id } {
    const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const successor_clause = try b.declare(
        &.{ unit, after },
        unit,
        if (correct) &.{residual} else &.{},
        &.{},
    );
    try b.define(
        successor_clause,
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(successor_clause, 1)),
            .argument = try b.constant(void, {}),
        } }),
    );
    const successor = try b.handler(.{
        .mode = .deep,
        .input = unit,
        .answer = unit,
        .effects = if (correct) &.{residual} else &.{},
        .return_function = returns,
        .clauses = &.{.{ .effect = handled, .function = successor_clause, .resumption = after }},
    });
    const first_clause = try b.declare(&.{ unit, before }, unit, &.{residual}, &.{});
    try b.define(
        first_clause,
        try b.term(.{ .resume_with = .{
            .resumption = try b.reference(b.parameter(first_clause, 1)),
            .argument = try b.constant(void, {}),
            .handler = successor,
        } }),
    );
    const initial = try b.handler(.{
        .mode = .shallow,
        .input = unit,
        .answer = unit,
        .effects = &.{residual},
        .return_function = returns,
        .clauses = &.{.{ .effect = handled, .function = first_clause, .resumption = before }},
    });
    return .{ .successor = successor, .initial = initial };
}

fn successorRowBody(
    b: *source.Builder,
    unit: source.Id,
    handled: source.Id,
    residual: source.Id,
    cap: source.Id,
) !source.Id {
    const body = try b.declare(&.{cap}, unit, &.{ handled, residual }, &.{});
    const operation = try b.term(.{ .perform = .{
        .effect = handled,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } });
    const final = try b.term(.{ .perform = .{
        .effect = residual,
        .payload = try b.constant(void, {}),
    } });
    const first_result = try b.variable(unit);
    const second_result = try b.variable(unit);
    try b.define(
        body,
        try b.bind(first_result, operation, try b.bind(second_result, operation, final)),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{cap},
        .result = unit,
        .effects = &.{ handled, residual },
    } } });
    return b.lambda(body, body_type);
}

fn successorRowExample(
    b: *source.Builder,
    comptime correct: bool,
    comptime initial_successor: bool,
) !source.Module {
    const unit = try b.scalar(void);
    const handled = try b.effect(.{
        .identity = "review/successor-A",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const residual = try b.effect(.{
        .identity = "review/successor-B",
        .payload = unit,
        .result = unit,
        .external = true,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = handled } });
    const before = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = handled,
        .input = unit,
        .answer = unit,
        .mode = .shallow,
        .use = .linear,
        .handled = &.{handled},
        .effects = &.{ handled, residual },
        .escaping = &.{residual},
        .capture_bound = &.{ unit, cap },
    } } });
    const after = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = handled,
        .input = unit,
        .answer = unit,
        .mode = .deep,
        .use = .linear,
        .handled = &.{handled},
        .effects = if (correct) &.{residual} else &.{},
        .capture_bound = &.{ unit, cap },
    } } });
    const handlers = try successorRowHandlers(b, correct, unit, handled, residual, before, after);
    const successor = handlers.successor;
    const initial = handlers.initial;
    const body_value = try successorRowBody(b, unit, handled, residual, cap);
    const entry = try b.declare(&.{}, unit, &.{residual}, &.{});
    try b.define(
        entry,
        try b.term(.{ .handle = .{
            .handler = if (initial_successor) successor else initial,
            .body = body_value,
        } }),
    );
    return b.module(entry, unit);
}

test "initial and successor installations preserve resumption effect bounds" {
    inline for (.{ false, true }) |complete| inline for (.{ false, true }) |initial| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try successorRowExample(&b, complete, initial);
        if (complete) {
            var compiled = try source.lower(std.testing.allocator, module);
            defer compiled.deinit();
        } else {
            try std.testing.expectError(
                error.InvalidEffect,
                source.lower(std.testing.allocator, module),
            );
        }
    };
}
