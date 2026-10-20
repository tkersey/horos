const std = @import("std");
const horos = @import("../root.zig");
const source = horos.source;
const Mode = enum { same, distinct, bound, borrowed };

fn program(b: *source.Builder, mode: Mode) !source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const closure_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .use = .affine,
    } } });
    const closure = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(closure, try b.pure(try b.constant(u64, 7)));
    const pair = if (mode == .borrowed)
        try b.schema(.{ .seq = closure_type })
    else
        try b.schema(.{ .product = &.{ integer, closure_type } });
    const output = try b.schema(.{ .product = &.{ integer, integer } });
    const variable = try b.variable(pair);
    const reference = try b.reference(variable);
    const opcode: horos.data.program.Opcode = if (mode == .borrowed)
        .sequence_length
    else
        .field;
    const projected = try b.primitive(integer, opcode, &.{reference}, 0);
    const copied = try b.variable(integer);
    const first = if (mode == .bound) try b.reference(copied) else projected;
    const second = if (mode == .distinct)
        try b.primitive(integer, .field, &.{reference}, 0)
    else
        first;
    var body = try b.pure(try b.primitive(output, .product, &.{ first, second }, 0));
    if (mode == .bound) body = try b.bind(copied, try b.pure(projected), body);
    const initial = if (mode == .borrowed)
        try b.primitive(pair, .sequence, &.{try b.lambda(closure, closure_type)}, 0)
    else
        try b.primitive(pair, .product, &.{
            try b.constant(u64, 42), try b.lambda(closure, closure_type),
        }, 0);
    const entry = try b.declare(&.{}, output, &.{}, &.{});
    try b.define(entry, try b.bind(variable, try b.pure(initial), body));
    return b.module(entry, unit);
}

test "consuming projections cannot hide repeated owned uses behind an expression ID" {
    for ([_]Mode{ .same, .distinct }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try program(&b, mode);
        {
            try std.testing.expectError(
                error.UnavailableSlot,
                horos.program.compileObserved(std.testing.allocator, module, .{}),
            );
        }
    }
}

test "binding a projected result and reusing borrowing observers remain valid" {
    for ([_]Mode{ .bound, .borrowed }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try program(&b, mode);
        var result = try horos.program.compile(std.testing.allocator, module);
        defer result.deinit();
    }
}

const BorrowMode = enum { same, distinct, bound, live };

fn borrowProgram(b: *source.Builder, mode: BorrowMode) !source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const closure_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .use = .affine,
    } } });
    const closure = try b.declare(&.{}, integer, &.{}, &.{});
    try b.define(closure, try b.pure(try b.constant(u64, 7)));
    const sequence = try b.schema(.{ .seq = closure_type });
    const output = try b.schema(.{ .product = &.{ integer, integer, integer } });
    const variable = try b.variable(sequence);
    const reference = try b.reference(variable);
    const length = try b.primitive(integer, .sequence_length, &.{reference}, 0);
    const copied = try b.variable(integer);
    const first = if (mode == .bound) try b.reference(copied) else length;
    const last = if (mode == .distinct)
        try b.primitive(integer, .sequence_length, &.{reference}, 0)
    else
        first;
    const taken = try b.primitive(sequence, .sequence_take, &.{
        reference, try b.constant(u64, 0),
    }, 0);
    const middle = if (mode == .live)
        length
    else
        try b.primitive(integer, .sequence_length, &.{taken}, 0);
    var body = try b.pure(try b.primitive(output, .product, &.{ first, middle, last }, 0));
    if (mode == .bound) body = try b.bind(copied, try b.pure(length), body);
    const initial = try b.primitive(sequence, .sequence, &.{
        try b.lambda(closure, closure_type),
    }, 0);
    const entry = try b.declare(&.{}, output, &.{}, &.{});
    try b.define(entry, try b.bind(variable, try b.pure(initial), body));
    return b.module(entry, unit);
}

test "borrow expression sharing cannot conceal use after consumption" {
    for ([_]BorrowMode{ .same, .distinct }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try borrowProgram(&b, mode);
        {
            try std.testing.expectError(
                error.UnavailableSlot,
                horos.program.compileObserved(std.testing.allocator, module, .{}),
            );
        }
    }
}

test "bound observer results and observations of live owners remain valid" {
    for ([_]BorrowMode{ .bound, .live }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try borrowProgram(&b, mode);
        var result = try horos.program.compile(std.testing.allocator, module);
        defer result.deinit();
    }
}
