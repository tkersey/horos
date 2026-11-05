const source = @import("source.zig");

pub const Fixture = struct { before: source.Module, after: source.Module, call: u64 };

fn argument(b: *source.Builder, shape: u64, denominator: u64, tag: u8) !u64 {
    const failure = try b.failureLiteral(try b.constant(u8, tag));
    return b.value(.{ .schema = shape, .expression = .{ .primitive = .{
        .opcode = .integer_div,
        .operands = &.{ try b.constant(u64, 1), denominator },
        .failures = &.{
            .{ .kind = .arithmetic_overflow, .value = failure },
            .{ .kind = .division_by_zero, .value = failure },
        },
    } } });
}

pub fn build(b: *source.Builder) !Fixture {
    const word = try b.scalar(u64);
    const failure = try b.scalar(u8);
    const helper = try b.declare(&.{ word, word }, word, &.{}, &.{});
    try b.define(helper, try b.pure(try b.constant(u64, 7)));
    const entry = try b.declare(&.{ word, word }, word, &.{}, &.{});
    const first = try argument(b, word, try b.reference(b.parameter(entry, 0)), 11);
    const second = try argument(b, word, try b.reference(b.parameter(entry, 1)), 22);
    const call = try b.term(.{ .call = .{ .function = helper, .arguments = &.{ first, second } } });
    try b.define(entry, call);
    const before = b.module(entry, failure);
    var work: u64 = 1_000_000;
    var ctx: source.relation.Context = .{
        .a = b.allocator(),
        .before = before,
        .expected = try source.own(source.Module, b.allocator(), before),
        .policy = .{},
        .left = &work,
    };
    try @import("source/relation_inline.zig").apply(&ctx, call);
    try source.relation.validate(b.allocator(), before, ctx.expected, &.{.{
        .successor = ctx.expected,
        .rule = .{ .inline_call = call },
    }}, .{});
    return .{ .before = before, .after = ctx.expected, .call = call };
}
