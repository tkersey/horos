// Copyright (c) 2026 Boundary contributors. MIT license.
//! Public staged authoring of scalar/collection success and authored-fault paths.
const source = @import("../source.zig");
const p = @import("horos_data").program;
const Error = source.Error;

fn operation(
    b: *source.Builder,
    result: p.Id,
    opcode: p.Opcode,
    operands: []const p.Id,
    immediate: p.Id,
    roles: []const p.Fault,
) Error!p.Id {
    var failures: [2]p.InstructionFailure = undefined;
    for (
        roles,
        0..,
    ) |role, index| failures[index] = .{
        .kind = role,
        .value = try b.failureLiteral(try b.constant(u8, @backingInt(role))),
    };
    return b.value(.{
        .schema = result,
        .expression = .{ .primitive = .{
            .opcode = opcode,
            .operands = operands,
            .immediate = immediate,
            .failures = failures[0..roles.len],
        } },
    });
}
fn wide(b: *source.Builder, value: p.Id, can_fail: bool) Error!p.Id {
    return operation(
        b,
        try b.scalar(u64),
        .integer_convert,
        &.{value},
        0,
        if (can_fail) &.{.arithmetic_overflow} else &.{},
    );
}
pub fn build(b: *source.Builder) Error!source.ast.Module {
    const byte = try b.scalar(u8);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const signed = try b.scalar(i8);
    const text = try b.schema(.text);
    const text_two = try b.schema(.{ .bounded_text = 2 });
    const text_four = try b.schema(.{ .bounded_text = 4 });
    const raw = try b.schema(.bytes);
    const vector = try b.schema(.{ .vector = .{ .element = byte, .maximum = 2 } });
    const optional = try b.schema(.{ .sum = &.{ try b.scalar(void), byte } });
    const pair = try b.schema(.{ .product = &.{ vector, optional } });
    const main = try b.declare(&.{byte}, integer, &.{}, &.{});
    const input = try b.reference(b.parameter(main, 0));
    const e = try b.literal(.{ .schema = text_two, .bytes = &.{ 2, 0xc3, 0xa9 } });
    const x = try b.literal(.{ .schema = text_two, .bytes = &.{ 1, 'x' } });
    const values = try b.primitive(
        vector,
        .sequence,
        &.{ try b.constant(u8, 9), try b.constant(u8, 8) },
        0,
    );
    var cases: [19]p.Id = undefined;
    return textCases(b, .{
        .byte = byte,
        .integer = integer,
        .boolean = boolean,
        .signed = signed,
        .text = text,
        .text_two = text_two,
        .text_four = text_four,
        .raw = raw,
        .vector = vector,
        .optional = optional,
        .pair = pair,
        .main = main,
        .input = input,
        .e = e,
        .x = x,
        .values = values,
        .cases = &cases,
    });
}

fn textCases(
    b: *source.Builder,
    ctx: anytype,
) Error!source.ast.Module {
    const scalar = try operation(
        b,
        ctx.text,
        .text_scalar,
        &.{try b.constant(u32, 0xe9)},
        0,
        &.{.invalid_utf8},
    );
    const joined = try operation(
        b,
        ctx.text_four,
        .blob_concat,
        &.{ ctx.x, scalar },
        0,
        &.{.capacity_exceeded},
    );
    ctx.cases[0] = try b.primitive(ctx.integer, .blob_length, &.{joined}, 0);
    const surrogate = try operation(
        b,
        ctx.text,
        .text_scalar,
        &.{try b.constant(u32, 0xd800)},
        0,
        &.{.invalid_utf8},
    );
    ctx.cases[1] = try b.primitive(ctx.integer, .blob_length, &.{surrogate}, 0);
    const too_long = try operation(
        b,
        ctx.text_two,
        .blob_concat,
        &.{ ctx.e, ctx.x },
        0,
        &.{.capacity_exceeded},
    );
    ctx.cases[2] = try b.primitive(ctx.integer, .blob_length, &.{too_long}, 0);
    return collectionFaultCases(b, .{
        .byte = ctx.byte,
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .signed = ctx.signed,
        .text = ctx.text,
        .text_two = ctx.text_two,
        .text_four = ctx.text_four,
        .raw = ctx.raw,
        .vector = ctx.vector,
        .optional = ctx.optional,
        .pair = ctx.pair,
        .main = ctx.main,
        .input = ctx.input,
        .e = ctx.e,
        .x = ctx.x,
        .values = ctx.values,
        .cases = ctx.cases,
    });
}

fn collectionFaultCases(
    b: *source.Builder,
    ctx: anytype,
) Error!source.ast.Module {
    const split = try operation(
        b,
        ctx.text_two,
        .blob_slice,
        &.{ ctx.e, try b.constant(u64, 1), try b.constant(u64, 2) },
        0,
        &.{ .capacity_exceeded, .invalid_utf8 },
    );
    ctx.cases[3] = try b.primitive(ctx.integer, .blob_length, &.{split}, 0);
    const bytes = try b.literal(.{ .schema = ctx.raw, .bytes = &.{ 4, 0, 1, 2, 3 } });
    const reversed = try operation(
        b,
        ctx.raw,
        .blob_slice,
        &.{ bytes, try b.constant(u64, 3), try b.constant(u64, 1) },
        0,
        &.{.capacity_exceeded},
    );
    ctx.cases[4] = try b.primitive(ctx.integer, .blob_length, &.{reversed}, 0);
    const pushed = try operation(
        b,
        ctx.vector,
        .sequence_append,
        &.{ ctx.values, try b.constant(u8, 7) },
        0,
        &.{.capacity_exceeded},
    );
    ctx.cases[5] = try b.primitive(ctx.integer, .sequence_length, &.{pushed}, 0);
    const replaced = try operation(
        b,
        ctx.vector,
        .sequence_set,
        &.{ ctx.values, try b.constant(u64, 2), try b.constant(u8, 7) },
        0,
        &.{.invalid_index},
    );
    ctx.cases[6] = try b.primitive(ctx.integer, .sequence_length, &.{replaced}, 0);
    return scalarFaultCases(b, .{
        .byte = ctx.byte,
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .signed = ctx.signed,
        .text = ctx.text,
        .text_four = ctx.text_four,
        .raw = ctx.raw,
        .vector = ctx.vector,
        .optional = ctx.optional,
        .pair = ctx.pair,
        .main = ctx.main,
        .input = ctx.input,
        .x = ctx.x,
        .values = ctx.values,
        .cases = ctx.cases,
    });
}

fn scalarFaultCases(
    b: *source.Builder,
    ctx: anytype,
) Error!source.ast.Module {
    const none = try b.primitive(ctx.optional, .variant, &.{try b.constant(void, {})}, 0);
    ctx.cases[7] = try wide(
        b,
        try operation(b, ctx.byte, .variant_payload, &.{none}, 1, &.{.invalid_variant}),
        false,
    );
    ctx.cases[8] = try wide(
        b,
        try operation(
            b,
            ctx.signed,
            .integer_rem,
            &.{ try b.constant(i8, -128), try b.constant(i8, -1) },
            0,
            &.{ .arithmetic_overflow, .division_by_zero },
        ),
        true,
    );
    ctx.cases[9] = try wide(
        b,
        try operation(
            b,
            try b.scalar(i64),
            .integer_convert,
            &.{try b.constant(u64, @import("std").math.maxInt(u64))},
            0,
            &.{.arithmetic_overflow},
        ),
        true,
    );
    ctx.cases[10] = try operation(
        b,
        ctx.integer,
        .integer_div,
        &.{ try b.constant(u64, 1), try b.constant(u64, 0) },
        0,
        &.{ .arithmetic_overflow, .division_by_zero },
    );
    return collectionSuccessCases(b, .{
        .byte = ctx.byte,
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .signed = ctx.signed,
        .text = ctx.text,
        .text_four = ctx.text_four,
        .raw = ctx.raw,
        .vector = ctx.vector,
        .optional = ctx.optional,
        .pair = ctx.pair,
        .main = ctx.main,
        .input = ctx.input,
        .x = ctx.x,
        .values = ctx.values,
        .cases = ctx.cases,
    });
}

fn collectionSuccessCases(
    b: *source.Builder,
    ctx: anytype,
) Error!source.ast.Module {
    const popped = try b.primitive(ctx.pair, .sequence_pop_last, &.{ctx.values}, 0);
    const last = try b.primitive(ctx.optional, .field, &.{popped}, 1);
    ctx.cases[11] = try wide(
        b,
        try operation(b, ctx.byte, .variant_payload, &.{last}, 1, &.{.invalid_variant}),
        false,
    );
    const taken = try b.primitive(
        ctx.vector,
        .sequence_take,
        &.{ ctx.values, try b.constant(u64, @import("std").math.maxInt(u64)) },
        0,
    );
    ctx.cases[12] = try b.primitive(ctx.integer, .sequence_length, &.{taken}, 0);
    const ff = try b.primitive(ctx.raw, .blob_from_byte, &.{try b.constant(u8, 0xff)}, 0);
    const ff_copy = try b.literal(.{ .schema = ctx.raw, .bytes = &.{ 1, 0xff } });
    ctx.cases[13] = try wide(
        b,
        try b.primitive(ctx.signed, .blob_compare, &.{ ff, ff_copy }, 0),
        true,
    );
    const bom = try b.literal(.{ .schema = ctx.text_four, .bytes = &.{ 3, 0xef, 0xbb, 0xbf } });
    const bom_join = try operation(
        b,
        ctx.text_four,
        .blob_concat,
        &.{ bom, ctx.x },
        0,
        &.{.capacity_exceeded},
    );
    ctx.cases[14] = try b.primitive(ctx.integer, .blob_length, &.{bom_join}, 0);
    const decimal = try b.primitive(
        ctx.text,
        .text_integer,
        &.{try b.constant(i64, @import("std").math.minInt(i64))},
        0,
    );
    ctx.cases[15] = try b.primitive(ctx.integer, .blob_length, &.{decimal}, 0);
    ctx.cases[16] = try wide(
        b,
        try b.primitive(ctx.byte, .integer_bit_not, &.{try b.constant(u8, 0x0f)}, 0),
        false,
    );
    return selectionCases(b, .{
        .byte = ctx.byte,
        .integer = ctx.integer,
        .boolean = ctx.boolean,
        .optional = ctx.optional,
        .main = ctx.main,
        .input = ctx.input,
        .values = ctx.values,
        .cases = ctx.cases,
    });
}

fn selectionCases(
    b: *source.Builder,
    ctx: anytype,
) Error!source.ast.Module {
    ctx.cases[17] = try b.primitive(
        ctx.integer,
        .select,
        &.{ try b.constant(bool, false), try b.constant(u64, 5), try b.constant(u64, 9) },
        0,
    );
    const missing = try b.primitive(
        ctx.optional,
        .sequence_get,
        &.{ ctx.values, try b.constant(u64, 7) },
        0,
    );
    ctx.cases[18] = try wide(
        b,
        try operation(b, ctx.byte, .variant_payload, &.{missing}, 1, &.{.invalid_variant}),
        false,
    );
    return dispatchCases(b, .{
        .byte = ctx.byte,
        .boolean = ctx.boolean,
        .main = ctx.main,
        .input = ctx.input,
        .cases = ctx.cases,
    });
}

fn dispatchCases(
    b: *source.Builder,
    ctx: anytype,
) Error!source.ast.Module {
    var body = try b.pure(ctx.cases[ctx.cases.len - 1]);
    var index = ctx.cases.len - 1;
    while (index != 0) {
        index -= 1;
        const selected = try b.primitive(
            ctx.boolean,
            .equal,
            &.{ ctx.input, try b.constant(u8, @intCast(index)) },
            0,
        );
        body = try b.term(.{ .conditional = .{
            .condition = selected,
            .when_true = try b.pure(ctx.cases[index]),
            .when_false = body,
        } });
    }
    try b.define(ctx.main, body);
    return b.module(ctx.main, ctx.byte);
}
