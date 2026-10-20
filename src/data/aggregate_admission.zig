// Copyright (c) 2026 Boundary contributors. MIT license.
//! Total immutable aggregate operations and their ownership interfaces.
const p = @import("program.zig");
const a = @import("admission.zig");

pub fn element(shape: p.Schema) a.Error!p.Id {
    return switch (shape) {
        .seq => |id| id,
        .vector => |vector| vector.element,
        .array => |array| array.element,
        else => error.TypeMismatch,
    };
}

pub fn instruction(image: anytype, op: anytype, slots: []const p.Id) a.Error!void {
    const result = image.schemas[@intCast(op.result_type)];
    const operands = op.operands;
    if (op.opcode != .field and
        op.opcode != .variant and
        op.opcode != .variant_payload and
        op.immediate != 0)
        return error.InvalidProgram;
    switch (op.opcode) {
        .product => {
            if (result != .product) return error.TypeMismatch;
            try a.arguments(slots, operands, result.product);
        },
        .field => {
            if (operands.len != 1) return error.TypeMismatch;
            const source = image.schemas[@intCast(slots[@intCast(operands[0])])];
            if (source != .product or op.immediate >= source.product.len or source.product[
                @intCast(op.immediate)
            ] != op.result_type) return error.TypeMismatch;
        },
        .variant => {
            if (result != .sum or operands.len != 1 or op.immediate >= result.sum.len or slots[
                @intCast(operands[0])
            ] != result.sum[
                @intCast(op.immediate)
            ]) return error.TypeMismatch;
        },
        .variant_tag => {
            if (operands.len != 1 or result != .u64 or image.schemas[
                @intCast(slots[
                    @intCast(operands[0])
                ])
            ] != .sum) return error.TypeMismatch;
        },
        .variant_payload => {
            if (operands.len != 1) return error.TypeMismatch;
            const source = image.schemas[@intCast(slots[@intCast(operands[0])])];
            if (source != .sum or op.immediate >= source.sum.len or source.sum[
                @intCast(op.immediate)
            ] != op.result_type) return error.TypeMismatch;
        },
        .select => {
            if (operands.len != 3 or image.schemas[
                @intCast(slots[
                    @intCast(operands[0])
                ])
            ] != .boolean or slots[
                @intCast(operands[1])
            ] != op.result_type or slots[
                @intCast(operands[2])
            ] != op.result_type) return error.TypeMismatch;
        },
        .sequence => {
            const item = try element(result);
            if (result == .vector and
                operands.len > result.vector.maximum)
                return error.TypeMismatch;
            if (result == .array and operands.len != result.array.length) return error.TypeMismatch;
            for (operands) |operand| if (slots[
                @intCast(operand)
            ] != item) return error.TypeMismatch;
        },
        .sequence_length => {
            if (operands.len != 1 or (result != .u64 and result != .u32)) return error.TypeMismatch;
            const source = image.schemas[@intCast(slots[@intCast(operands[0])])];
            _ = try element(source);
            if (result == .u32) {
                const bound = switch (source) {
                    .vector => |x| x.maximum,
                    .array => |x| x.length,
                    else => return error.TypeMismatch,
                };
                if (bound > @import("std").math.maxInt(u32)) return error.TypeMismatch;
            }
        },
        .sequence_get => {
            if (operands.len != 2 or image.schemas[
                @intCast(slots[
                    @intCast(operands[1])
                ])
            ] != .u64) return error.TypeMismatch;
            const item = try element(image.schemas[@intCast(slots[@intCast(operands[0])])]);
            try optional(image, result, item);
        },
        .sequence_append, .sequence_concat => {
            if ((result != .seq and result != .vector) or operands.len != 2 or slots[
                @intCast(operands[0])
            ] != op.result_type) return error.TypeMismatch;
            if (slots[
                @intCast(operands[1])
            ] != (if (op.opcode == .sequence_append) try element(
                result,
            ) else op.result_type)) return error.TypeMismatch;
        },
        .sequence_set, .sequence_take => {
            if (operands.len != (if (op.opcode == .sequence_set) @as(
                usize,
                3,
            ) else 2) or slots[@intCast(operands[0])] != op.result_type) return error.TypeMismatch;
            const item = try element(result);
            if (image.schemas[
                @intCast(slots[
                    @intCast(operands[1])
                ])
            ] != .u64) return error.TypeMismatch;
            if (op.opcode == .sequence_set) {
                if (slots[@intCast(operands[2])] != item) return error.TypeMismatch;
            } else if (result == .array) return error.TypeMismatch;
        },
        .sequence_pop => {
            if (operands.len != 1 or result != .sum or result.sum.len != 2 or image.schemas[
                @intCast(result.sum[0])
            ] != .unit) return error.TypeMismatch;
            const source_id = slots[@intCast(operands[0])];
            if (image.schemas[@intCast(source_id)] == .array) return error.TypeMismatch;
            const item = try element(image.schemas[@intCast(source_id)]);
            const pair = image.schemas[@intCast(result.sum[1])];
            if (pair != .product or
                pair.product.len != 2 or
                pair.product[0] != item or
                pair.product[1] != source_id)
                return error.TypeMismatch;
        },
        .sequence_pop_last => {
            if (operands.len != 1 or
                result != .product or
                result.product.len != 2)
                return error.TypeMismatch;
            const source = slots[@intCast(operands[0])];
            if (result.product[0] != source or image.schemas[
                @intCast(source)
            ] == .array) return error.TypeMismatch;
            const item = try element(image.schemas[@intCast(source)]);
            try optional(image, image.schemas[@intCast(result.product[1])], item);
        },
        else => return error.UnsupportedInstruction,
    }
}

pub fn optional(image: anytype, shape: p.Schema, item: p.Id) a.Error!void {
    if (shape != .sum or shape.sum.len != 2 or image.schemas[
        @intCast(shape.sum[0])
    ] != .unit or shape.sum[1] != item) return error.TypeMismatch;
}
