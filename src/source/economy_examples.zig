// Copyright (c) 2026 Boundary contributors. MIT license.
//! Executable economy workloads built through the public staged interface.
const source = @import("../source.zig");
const p = @import("horos_data").program;

pub fn installations(b: *source.Builder, count: usize) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "economy/read",
        .payload = unit,
        .result = integer,
        .external = false,
    });
    const capability = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = integer,
        .answer = integer,
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const returns = try b.declare(&.{ integer, integer }, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const clause = try b.declare(&.{ integer, unit, token }, integer, &.{}, &.{});
    try b.define(
        clause,
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(clause, 2)),
            .argument = try b.reference(b.parameter(clause, 0)),
        } }),
    );
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .state = &.{integer},
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    const body = try b.declare(&.{capability}, integer, &.{effect}, &.{});
    try b.define(
        body,
        try b.term(.{ .perform = .{
            .effect = effect,
            .capability = try b.reference(b.parameter(body, 0)),
            .payload = try b.constant(void, {}),
        } }),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{capability},
        .result = integer,
        .effects = &.{effect},
    } } });
    const computation = try b.lambda(body, body_type);
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    const values = try b.allocator().alloc(p.Id, count);
    for (values) |*v| v.* = try b.variable(integer);
    var sum = try b.constant(u64, 0);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    for (values) |v| sum = try b.value(.{
        .schema = integer,
        .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{ sum, try b.reference(v) },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } },
    });
    var term = try b.pure(sum);
    var index = count;
    while (index != 0) {
        index -= 1;
        const installed = try b.term(.{ .handle = .{
            .handler = handler,
            .body = computation,
            .state = &.{try b.constant(u64, index + 1)},
        } });
        term = try b.bind(values[index], installed, term);
    }
    try b.define(main, term);
    return b.module(main, unit);
}

pub fn blobCapture(b: *source.Builder) source.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const bytes = try b.schema(.bytes);
    const effect = try b.effect(.{
        .identity = "economy/capture",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const capability = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = integer,
        .capture_bound = &.{ bytes, capability },
        .handled = &.{effect},
        .mode = .deep,
        .use = .linear,
    } } });
    const returns = try b.declare(&.{integer}, integer, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ unit, token }, integer, &.{}, &.{});
    const resumed = try b.variable(integer);
    const call = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(clause, 1)),
        .argument = try b.constant(void, {}),
    } });
    const plus = try b.value(.{
        .schema = integer,
        .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{ try b.reference(resumed), try b.constant(u64, 1) },
            .failures = &.{.{
                .kind = .arithmetic_overflow,
                .value = try b.failureLiteral(try b.constant(void, {})),
            }},
        } },
    });
    try b.define(clause, try b.bind(resumed, call, try b.pure(plus)));
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    const main = try b.declare(&.{bytes}, integer, &.{}, &.{});
    const body = try b.declare(&.{capability}, integer, &.{effect}, &.{});
    const raised = try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(body, 0)),
        .payload = try b.constant(void, {}),
    } });
    const length = try b.primitive(
        integer,
        .blob_length,
        &.{try b.reference(b.parameter(main, 0))},
        0,
    );
    try b.define(body, try b.bind(try b.variable(unit), raised, try b.pure(length)));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{capability},
        .result = integer,
        .effects = &.{effect},
        .capture_bound = &.{bytes},
    } } });
    try b.define(
        main,
        try b.term(.{ .handle = .{ .handler = handler, .body = try b.lambda(body, body_type) } }),
    );
    return b.module(main, unit);
}
