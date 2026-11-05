const source = @import("source.zig");

pub const Fixture = struct {
    module: source.Module,
    generator: u64,
    target: u64,
    difference: u64,
    raw: u64,
};

pub fn build(b: *source.Builder, raw_entry: bool) !Fixture {
    const unit = try b.scalar(void);
    const word = try b.scalar(i64);
    const computation = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = word,
        .capture_bound = &.{word},
    } } });
    const generator = try b.declare(&.{ word, word }, computation, &.{}, &.{});
    const target = try b.declare(&.{}, word, &.{}, &.{});
    const first = try b.reference(b.parameter(generator, 0));
    const second = try b.reference(b.parameter(generator, 1));
    const difference = try b.value(.{ .schema = word, .expression = .{ .primitive = .{
        .opcode = .integer_sub,
        .operands = &.{ first, second },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
    try b.define(target, try b.pure(difference));
    try b.define(generator, try b.pure(try b.lambda(target, computation)));
    const entry = try b.declare(&.{}, word, &.{}, &.{});
    const left = try b.constant(i64, 19);
    const right = try b.constant(i64, 4);
    const raw = try b.primitive(computation, .computation, &.{ left, right }, 0);
    const closure = try b.variable(computation);
    const apply = try b.term(.{ .apply = .{
        .computation = if (raw_entry) raw else try b.reference(closure),
        .arguments = &.{},
    } });
    try b.define(entry, if (raw_entry) apply else try b.bind(closure, try b.term(.{ .call = .{
        .function = generator,
        .arguments = &.{ left, right },
    } }), apply));
    return .{
        .module = b.module(entry, unit),
        .generator = generator,
        .target = target,
        .difference = difference,
        .raw = raw,
    };
}
