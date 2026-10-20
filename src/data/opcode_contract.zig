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
pub fn describe(opcode: p.Opcode) Description {
    return switch (opcode) {
        .constant => .{
            .operand_encoding = .{ .fixed = 0 },
            .possible_wire_faults = &.{},
            .failure_count_encoding = .implied_one,
            .immediate_role = .constant,
        },
        .move, .boolean_not, .clone_resumption, .package, .unpack, .integer_bit_not, .enum_tag => .{
            .operand_encoding = .{ .fixed = 1 },
            .possible_wire_faults = &.{},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .integer_add, .integer_sub, .integer_mul => .{
            .operand_encoding = .{ .fixed = 2 },
            .possible_wire_faults = &.{.arithmetic_overflow},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .integer_div, .integer_rem => .{
            .operand_encoding = .{ .fixed = 2 },
            .possible_wire_faults = &.{ .arithmetic_overflow, .division_by_zero },
            .failure_count_encoding = .implied_two,
            .immediate_role = .numeric,
        },
        .integer_bit_and, .integer_bit_or, .integer_bit_xor, .equal, .less => .{
            .operand_encoding = .{ .fixed = 2 },
            .possible_wire_faults = &.{},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .integer_convert => .{
            .operand_encoding = .{ .fixed = 1 },
            .possible_wire_faults = &.{.arithmetic_overflow},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .variant_payload => .{
            .operand_encoding = .counted,
            .possible_wire_faults = &.{.invalid_variant},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .sequence_set => .{
            .operand_encoding = .counted,
            .possible_wire_faults = &.{.invalid_index},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .sequence_append, .sequence_concat, .blob_concat => .{
            .operand_encoding = .counted,
            .possible_wire_faults = &.{.capacity_exceeded},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .blob_slice => .{
            .operand_encoding = .counted,
            .possible_wire_faults = &.{ .capacity_exceeded, .invalid_utf8 },
            .failure_count_encoding = .counted,
            .immediate_role = .numeric,
        },
        .text_scalar => .{
            .operand_encoding = .counted,
            .possible_wire_faults = &.{.invalid_utf8},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
        .computation => .{
            .operand_encoding = .counted,
            .possible_wire_faults = &.{},
            .failure_count_encoding = .implied_one,
            .immediate_role = .constructor,
        },
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
        => .{
            .operand_encoding = .counted,
            .possible_wire_faults = &.{},
            .failure_count_encoding = .implied_one,
            .immediate_role = .numeric,
        },
    };
}
test "opcode representation description analyzes every current numeric tag" {
    inline for (std.meta.tags(p.Opcode)) |opcode| {
        const description = describe(opcode);
        try std.testing.expect(@backingInt(opcode) < 64);
        try std.testing.expect(description.possible_wire_faults.len <= 2);
    }
}
