//! Two live one-shot tokens of the same type, under distinct installations.
//! The inner clause yields while its caller still owns the outer token.
const source = @import("../source.zig");
pub fn build(b: *source.Builder) source.Error!source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const integer = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "example/nested-linear",
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
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{capability},
        .result = integer,
        .effects = &.{effect},
    } } });
    const main = try b.declare(&.{}, integer, &.{}, &.{});
    const body = try b.declare(&.{capability}, integer, &.{effect}, &.{});
    const returns = try b.declare(&.{ boolean, integer }, integer, &.{}, &.{});
    const clause = try b.declare(&.{ boolean, unit, token }, integer, &.{}, &.{});
    try b.define(
        body,
        try b.term(.{ .perform = .{
            .effect = effect,
            .capability = try b.reference(b.parameter(body, 0)),
            .payload = try b.constant(void, {}),
        } }),
    );
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const handler = try b.handler(.{
        .mode = .deep,
        .input = integer,
        .answer = integer,
        .return_function = returns,
        .state = &.{boolean},
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    const suspended = try b.reference(b.parameter(clause, 2));
    const resumed = try b.term(.{ .resume_value = .{
        .resumption = suspended,
        .argument = try b.constant(u64, 1),
    } });
    const inner = try b.term(.{ .yield_then = resumed });
    const result = try b.variable(integer);
    const nested = try b.term(.{ .handle = .{
        .handler = handler,
        .body = try b.lambda(body, computation),
        .state = &.{try b.constant(bool, true)},
    } });
    const outer = try b.bind(
        result,
        nested,
        try b.term(.{ .resume_value = .{
            .resumption = suspended,
            .argument = try b.reference(result),
        } }),
    );
    try b.define(
        clause,
        try b.term(.{ .conditional = .{
            .condition = try b.reference(b.parameter(clause, 0)),
            .when_true = inner,
            .when_false = outer,
        } }),
    );
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handler,
            .body = try b.lambda(body, computation),
            .state = &.{try b.constant(bool, false)},
        } }),
    );
    return b.module(main, unit);
}
