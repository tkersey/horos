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
    const scalar = try operation(
        b,
        text,
        .text_scalar,
        &.{try b.constant(u32, 0xe9)},
        0,
        &.{.invalid_utf8},
    );
    const joined = try operation(
        b,
        text_four,
        .blob_concat,
        &.{ x, scalar },
        0,
        &.{.capacity_exceeded},
    );
    cases[0] = try b.primitive(integer, .blob_length, &.{joined}, 0);
    const surrogate = try operation(
        b,
        text,
        .text_scalar,
        &.{try b.constant(u32, 0xd800)},
        0,
        &.{.invalid_utf8},
    );
    cases[1] = try b.primitive(integer, .blob_length, &.{surrogate}, 0);
    const too_long = try operation(
        b,
        text_two,
        .blob_concat,
        &.{ e, x },
        0,
        &.{.capacity_exceeded},
    );
    cases[2] = try b.primitive(integer, .blob_length, &.{too_long}, 0);
    const split = try operation(
        b,
        text_two,
        .blob_slice,
        &.{ e, try b.constant(u64, 1), try b.constant(u64, 2) },
        0,
        &.{ .capacity_exceeded, .invalid_utf8 },
    );
    cases[3] = try b.primitive(integer, .blob_length, &.{split}, 0);
    const bytes = try b.literal(.{ .schema = raw, .bytes = &.{ 4, 0, 1, 2, 3 } });
    const reversed = try operation(
        b,
        raw,
        .blob_slice,
        &.{ bytes, try b.constant(u64, 3), try b.constant(u64, 1) },
        0,
        &.{.capacity_exceeded},
    );
    cases[4] = try b.primitive(integer, .blob_length, &.{reversed}, 0);
    const pushed = try operation(
        b,
        vector,
        .sequence_append,
        &.{ values, try b.constant(u8, 7) },
        0,
        &.{.capacity_exceeded},
    );
    cases[5] = try b.primitive(integer, .sequence_length, &.{pushed}, 0);
    const replaced = try operation(
        b,
        vector,
        .sequence_set,
        &.{ values, try b.constant(u64, 2), try b.constant(u8, 7) },
        0,
        &.{.invalid_index},
    );
    cases[6] = try b.primitive(integer, .sequence_length, &.{replaced}, 0);
    const none = try b.primitive(optional, .variant, &.{try b.constant(void, {})}, 0);
    cases[7] = try wide(
        b,
        try operation(b, byte, .variant_payload, &.{none}, 1, &.{.invalid_variant}),
        false,
    );
    cases[8] = try wide(
        b,
        try operation(
            b,
            signed,
            .integer_rem,
            &.{ try b.constant(i8, -128), try b.constant(i8, -1) },
            0,
            &.{ .arithmetic_overflow, .division_by_zero },
        ),
        true,
    );
    cases[9] = try wide(
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
    cases[10] = try operation(
        b,
        integer,
        .integer_div,
        &.{ try b.constant(u64, 1), try b.constant(u64, 0) },
        0,
        &.{ .arithmetic_overflow, .division_by_zero },
    );
    const popped = try b.primitive(pair, .sequence_pop_last, &.{values}, 0);
    const last = try b.primitive(optional, .field, &.{popped}, 1);
    cases[11] = try wide(
        b,
        try operation(b, byte, .variant_payload, &.{last}, 1, &.{.invalid_variant}),
        false,
    );
    const taken = try b.primitive(
        vector,
        .sequence_take,
        &.{ values, try b.constant(u64, @import("std").math.maxInt(u64)) },
        0,
    );
    cases[12] = try b.primitive(integer, .sequence_length, &.{taken}, 0);
    const ff = try b.primitive(raw, .blob_from_byte, &.{try b.constant(u8, 0xff)}, 0);
    const ff_copy = try b.literal(.{ .schema = raw, .bytes = &.{ 1, 0xff } });
    cases[13] = try wide(b, try b.primitive(signed, .blob_compare, &.{ ff, ff_copy }, 0), true);
    const bom = try b.literal(.{ .schema = text_four, .bytes = &.{ 3, 0xef, 0xbb, 0xbf } });
    const bom_join = try operation(
        b,
        text_four,
        .blob_concat,
        &.{ bom, x },
        0,
        &.{.capacity_exceeded},
    );
    cases[14] = try b.primitive(integer, .blob_length, &.{bom_join}, 0);
    const decimal = try b.primitive(
        text,
        .text_integer,
        &.{try b.constant(i64, @import("std").math.minInt(i64))},
        0,
    );
    cases[15] = try b.primitive(integer, .blob_length, &.{decimal}, 0);
    cases[16] = try wide(
        b,
        try b.primitive(byte, .integer_bit_not, &.{try b.constant(u8, 0x0f)}, 0),
        false,
    );
    cases[17] = try b.primitive(
        integer,
        .select,
        &.{ try b.constant(bool, false), try b.constant(u64, 5), try b.constant(u64, 9) },
        0,
    );
    const missing = try b.primitive(
        optional,
        .sequence_get,
        &.{ values, try b.constant(u64, 7) },
        0,
    );
    cases[18] = try wide(
        b,
        try operation(b, byte, .variant_payload, &.{missing}, 1, &.{.invalid_variant}),
        false,
    );
    var body = try b.pure(cases[cases.len - 1]);
    var index = cases.len - 1;
    while (index != 0) {
        index -= 1;
        const selected = try b.primitive(
            boolean,
            .equal,
            &.{ input, try b.constant(u8, @intCast(index)) },
            0,
        );
        body = try b.term(.{ .conditional = .{
            .condition = selected,
            .when_true = try b.pure(cases[index]),
            .when_false = body,
        } });
    }
    try b.define(main, body);
    return b.module(main, byte);
}
