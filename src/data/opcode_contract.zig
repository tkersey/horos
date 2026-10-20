//! Fixed BPI3 representation facts. Semantic arity, required faults and
//! optimizer/ownership policy remain with their independent owners.
const std = @import("std");
const p = @import("program.zig");
pub const OperandEncoding = union(enum) { fixed: u8, counted };
pub const FailureCountEncoding = enum { implied_one, implied_two, counted };
pub const ImmediateRole = enum { constant, constructor, numeric };
pub const Description = struct {
    operand_encoding: OperandEncoding,
    possible_wire_faults: []const p.Fault,
    /// Applies only when the wire failure-list flag is present, including an
    /// impossible flag on a no-fault opcode (which must still reject one entry).
    failure_count_encoding: FailureCountEncoding,
    immediate_role: ImmediateRole,
};
const unary = representation(.{ .fixed = 1 }, &.{}, .implied_one, .numeric);
const binary = representation(.{ .fixed = 2 }, &.{}, .implied_one, .numeric);
const overflowing = representation(
    .{ .fixed = 2 },
    &.{.arithmetic_overflow},
    .implied_one,
    .numeric,
);
const division = representation(
    .{ .fixed = 2 },
    &.{ .arithmetic_overflow, .division_by_zero },
    .implied_two,
    .numeric,
);

pub fn describe(opcode: p.Opcode) Description {
    return switch (opcode) {
        .constant => representation(.{ .fixed = 0 }, &.{}, .implied_one, .constant),
        .move,
        .boolean_not,
        .clone_resumption,
        .package,
        .unpack,
        .integer_bit_not,
        .enum_tag,
        => unary,
        .integer_add, .integer_sub, .integer_mul => overflowing,
        .integer_div, .integer_rem => division,
        .integer_bit_and, .integer_bit_or, .integer_bit_xor, .equal, .less => binary,
        .integer_convert => representation(
            .{ .fixed = 1 },
            &.{.arithmetic_overflow},
            .implied_one,
            .numeric,
        ),
        .variant_payload => representation(.counted, &.{.invalid_variant}, .implied_one, .numeric),
        .sequence_set => representation(.counted, &.{.invalid_index}, .implied_one, .numeric),
        .sequence_append, .sequence_concat, .blob_concat => representation(
            .counted,
            &.{.capacity_exceeded},
            .implied_one,
            .numeric,
        ),
        .blob_slice => representation(
            .counted,
            &.{ .capacity_exceeded, .invalid_utf8 },
            .counted,
            .numeric,
        ),
        .text_scalar => representation(.counted, &.{.invalid_utf8}, .implied_one, .numeric),
        .computation => representation(.counted, &.{}, .implied_one, .constructor),
        .product,
        .field,
        .variant,
        .variant_tag,
        .sequence,
        .sequence_length,
        .sequence_get,
        .sequence_pop,
        .cell_new,
        .cell_get,
        .cell_set,
        .resource_pack,
        .resource_unpack,
        .blob_length,
        .blob_compare,
        .blob_byte,
        .text_integer,
        .sequence_take,
        .blob_from_byte,
        .sequence_pop_last,
        .select,
        => representation(.counted, &.{}, .implied_one, .numeric),
    };
}

fn representation(
    operands: OperandEncoding,
    faults: []const p.Fault,
    failures: FailureCountEncoding,
    immediate: ImmediateRole,
) Description {
    return .{
        .operand_encoding = operands,
        .possible_wire_faults = faults,
        .failure_count_encoding = failures,
        .immediate_role = immediate,
    };
}

test "opcode representation description analyzes every current numeric tag" {
    inline for (std.meta.tags(p.Opcode)) |opcode| {
        const description = describe(opcode);
        try std.testing.expect(@backingInt(opcode) < 64);
        try std.testing.expect(description.possible_wire_faults.len <= 2);
    }
}
