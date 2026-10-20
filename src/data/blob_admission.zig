// Copyright (c) 2026 Boundary contributors. MIT license.
//! Type contracts for pointer-free bytes and UTF-8 operations.
const p = @import("program.zig");
const a = @import("admission.zig");

pub fn isText(shape: p.Schema) bool {
    return shape == .text or shape == .bounded_text;
}
pub fn isBytes(shape: p.Schema) bool {
    return shape == .bytes or shape == .bounded_bytes;
}
pub fn maximum(shape: p.Schema) u64 {
    return switch (shape) {
        .bounded_bytes => |n| n,
        .bounded_text => |n| n,
        else => @import("std").math.maxInt(u64),
    };
}
pub fn instruction(image: anytype, op: anytype, slots: []const p.Id) a.Error!void {
    if (op.immediate != 0) return error.InvalidProgram;
    const result = image.schemas[@intCast(op.result_type)];
    const arity: usize = switch (op.opcode) {
        .blob_slice => 3,
        .blob_concat, .blob_compare, .blob_byte => 2,
        else => 1,
    };
    if (op.operands.len != arity) return error.TypeMismatch;
    const source = image.schemas[@intCast(slots[@intCast(op.operands[0])])];
    switch (op.opcode) {
        .text_scalar => {
            if (source != .u32 or result != .text) return error.TypeMismatch;
        },
        .text_integer => {
            if (!a.integer(source) or result != .text) return error.TypeMismatch;
        },
        .blob_from_byte => {
            if (source != .u8 or result != .bytes) return error.TypeMismatch;
        },
        else => {
            if (!isText(source) and !isBytes(source)) return error.TypeMismatch;
            switch (op.opcode) {
                .blob_length => {
                    if (result != .u64 and !(result == .u32 and maximum(source) <= @import("std").math.maxInt(u32))) return error.TypeMismatch;
                },
                .blob_concat, .blob_slice => {
                    if (isText(source) != isText(result) or isBytes(source) != isBytes(result)) return error.TypeMismatch;
                    if (op.opcode == .blob_concat) {
                        const right = image.schemas[@intCast(slots[@intCast(op.operands[1])])];
                        if (isText(right) != isText(source) or isBytes(right) != isBytes(source)) return error.TypeMismatch;
                    } else for (op.operands[1..]) |slot| {
                        if (image.schemas[
                            @intCast(slots[
                                @intCast(slot)
                            ])
                        ] != .u64) return error.TypeMismatch;
                    }
                },
                .blob_compare => {
                    const right = image.schemas[@intCast(slots[@intCast(op.operands[1])])];
                    if (result != .i8 or isText(right) != isText(source) or isBytes(right) != isBytes(source)) return error.TypeMismatch;
                },
                .blob_byte => {
                    if (image.schemas[
                        @intCast(slots[
                            @intCast(op.operands[1])
                        ])
                    ] != .u64 or result != .sum or result.sum.len != 2 or image.schemas[
                        @intCast(result.sum[0])
                    ] != .unit or image.schemas[
                        @intCast(result.sum[1])
                    ] != .u8) return error.TypeMismatch;
                },
                else => return error.UnsupportedInstruction,
            }
        },
    }
}
