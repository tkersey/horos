const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const wire = @import("wire.zig");
const records = @import("program_record.zig");
const golden = @embedFile("testdata/opcode-records.bin");
fn operandCount(op: p.Opcode) usize {
    return switch (op) {
        .constant => 0,
        .move,
        .integer_bit_not,
        .integer_convert,
        .enum_tag,
        .boolean_not,
        .package,
        .unpack,
        .clone_resumption,
        => 1,
        else => 2,
    };
}
fn faults(op: p.Opcode) []const p.Fault {
    return switch (op) {
        .integer_add, .integer_sub, .integer_mul, .integer_convert => &.{.arithmetic_overflow},
        .integer_div, .integer_rem => &.{ .arithmetic_overflow, .division_by_zero },
        .variant_payload => &.{.invalid_variant},
        .sequence_set => &.{.invalid_index},
        .sequence_append, .sequence_concat, .blob_concat => &.{.capacity_exceeded},
        .blob_slice => &.{ .capacity_exceeded, .invalid_utf8 },
        .text_scalar => &.{.invalid_utf8},
        else => &.{},
    };
}
test "all opcode wire forms match the captured baseline instruction vectors" {
    var expected: wire.Writer = .{ .expected = golden };
    var expected_context: records.Context = .{};
    inline for (std.meta.tags(p.Opcode)) |opcode| {
        for (0..2) |mode| {
            var failures: [2]p.InstructionFailure = undefined;
            const possible = faults(opcode);
            const count = if (mode == 0) 0 else possible.len;
            for (
                failures[0..count],
                possible[0..count],
                0..,
            ) |*failure, kind, index| failure.* = .{ .kind = kind, .value = index + 1 };
            const instruction: ir.Instruction = .{
                .destination = 2,
                .opcode = opcode,
                .operands = (&[_]p.Id{ 5, 6 })[0..operandCount(opcode)],
                .immediate = if (mode == 1) 7 else 0,
                .failures = failures[0..count],
            };
            try records.write(ir.Instruction, instruction, &expected, &expected_context);
            var storage: [128]u8 = undefined;
            var writer: wire.Writer = .{ .output = &storage };
            var context: records.Context = .{};
            try records.write(ir.Instruction, instruction, &writer, &context);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var reader: wire.Reader = .{ .input = storage[0..writer.position] };
            var budget: records.Budget = .{ .maximum = 1 << 20 };
            const decoded = try records.read(
                ir.Instruction,
                &reader,
                arena.allocator(),
                &budget,
                &context,
            );
            try std.testing.expectEqualDeep(instruction, decoded);
            try std.testing.expectEqual(writer.position, reader.position);
            if (possible.len == 0) {
                storage[0] |= 128;
                storage[writer.position] = 0;
                reader = .{ .input = storage[0 .. writer.position + 1] };
                try std.testing.expectError(
                    error.InvalidTag,
                    records.read(ir.Instruction, &reader, arena.allocator(), &budget, &context),
                );
                try std.testing.expectEqual(writer.position, reader.position);
            }
        }
    }
    try std.testing.expectEqual(golden.len, expected.position);
}
fn expectDecodeError(bytes: []const u8, expected_error: anyerror, position: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = bytes };
    var budget: records.Budget = .{ .maximum = 1 << 20 };
    var context: records.Context = .{};
    try std.testing.expectError(
        expected_error,
        records.read(ir.Instruction, &reader, arena.allocator(), &budget, &context),
    );
    try std.testing.expectEqual(position, reader.position);
}
test "opcode parser preserves unknown tags failure counts budgets and failure advancement" {
    for (48..64) |unknown| for ([_]u8{ 0, 64, 128, 192 }) |flags| {
        try expectDecodeError(&.{ @as(u8, @intCast(unknown)) | flags, 0 }, error.InvalidTag, 1);
    };
    try expectDecodeError(
        &.{ @backingInt(p.Opcode.blob_slice) | 128, 0, 0, 3 },
        error.InvalidLength,
        4,
    );
    try expectDecodeError(
        &.{ @backingInt(p.Opcode.integer_div) | 128, 0, 0, 0, 1 },
        error.Truncated,
        5,
    );
    var reader: wire.Reader = .{ .input = &.{ @backingInt(p.Opcode.move), 0, 0 } };
    var budget: records.Budget = .{ .maximum = 0 };
    var context: records.Context = .{};
    try std.testing.expectError(
        error.Capacity,
        records.read(ir.Instruction, &reader, std.testing.allocator, &budget, &context),
    );
    try std.testing.expectEqual(@as(usize, 2), reader.position);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    var output: [16]u8 = undefined;
    var writer: wire.Writer = .{ .output = &output };
    try std.testing.expectError(
        error.InvalidTag,
        records.write(
            ir.Instruction,
            .{
                .destination = 0,
                .opcode = .integer_add,
                .operands = &.{ 0, 0 },
                .failures = &.{.{ .kind = .division_by_zero, .value = 0 }},
            },
            &writer,
            &context,
        ),
    );
    try std.testing.expectEqualSlices(u8, &.{ 130, 0, 0, 0 }, output[0..writer.position]);
}

test "schema dependent admission faults stay independent of possible wire faults" {
    const admission = @import("admission.zig");
    const schemas = [_]p.Schema{
        .unit,                                          .u8,           .u64, .bytes, .text,
        .{ .vector = .{ .element = 2, .maximum = 3 } }, .{ .seq = 2 },
    };
    const constants = [_]p.Literal{.{ .schema = 0, .bytes = &.{} }};
    const image = .{
        .schemas = &schemas,
        .constants = &constants,
        .roots = .{ .failure = @as(u64, 0) },
    };
    const capacity = [_]p.InstructionFailure{.{ .kind = .capacity_exceeded, .value = 0 }};
    const text_faults = [_]p.InstructionFailure{
        .{ .kind = .capacity_exceeded, .value = 0 },
        .{ .kind = .invalid_utf8, .value = 0 },
    };
    const overflow = [_]p.InstructionFailure{.{ .kind = .arithmetic_overflow, .value = 0 }};
    inline for (.{ @as(u64, 3), @as(u64, 4) }) |result| {
        const valid: []const p.InstructionFailure = if (result == 3) &capacity else &text_faults;
        const invalid: []const p.InstructionFailure = if (result == 3) &text_faults else &capacity;
        try admission.validateInstruction(
            image,
            0,
            .{
                .opcode = p.Opcode.blob_slice,
                .result_type = result,
                .operands = &[_]p.Id{ 0, 1, 2 },
                .immediate = @as(u64, 0),
                .failures = valid,
            },
            &.{ result, 2, 2 },
            undefined,
        );
        try std.testing.expectError(
            error.InvalidProgram,
            admission.validateInstruction(
                image,
                0,
                .{
                    .opcode = p.Opcode.blob_slice,
                    .result_type = result,
                    .operands = &[_]p.Id{ 0, 1, 2 },
                    .immediate = @as(u64, 0),
                    .failures = invalid,
                },
                &.{ result, 2, 2 },
                undefined,
            ),
        );
    }
    inline for (.{ @as(u64, 5), @as(u64, 6) }) |result| {
        const valid: []const p.InstructionFailure = if (result == 5) &capacity else &.{};
        const invalid: []const p.InstructionFailure = if (result == 5) &.{} else &capacity;
        try admission.validateInstruction(
            image,
            0,
            .{
                .opcode = p.Opcode.sequence_append,
                .result_type = result,
                .operands = &[_]p.Id{ 0, 1 },
                .immediate = @as(u64, 0),
                .failures = valid,
            },
            &.{ result, 2 },
            undefined,
        );
        try std.testing.expectError(
            error.InvalidProgram,
            admission.validateInstruction(
                image,
                0,
                .{
                    .opcode = p.Opcode.sequence_append,
                    .result_type = result,
                    .operands = &[_]p.Id{ 0, 1 },
                    .immediate = @as(u64, 0),
                    .failures = invalid,
                },
                &.{ result, 2 },
                undefined,
            ),
        );
    }
    inline for (.{ @as(u64, 1), @as(u64, 2) }) |result| {
        const from: u64 = if (result == 1) 2 else 1;
        const valid: []const p.InstructionFailure = if (result == 1) &overflow else &.{};
        const invalid: []const p.InstructionFailure = if (result == 1) &.{} else &overflow;
        try admission.validateInstruction(
            image,
            0,
            .{
                .opcode = p.Opcode.integer_convert,
                .result_type = result,
                .operands = &[_]p.Id{0},
                .immediate = @as(u64, 0),
                .failures = valid,
            },
            &.{from},
            undefined,
        );
        try std.testing.expectError(
            error.InvalidProgram,
            admission.validateInstruction(
                image,
                0,
                .{
                    .opcode = p.Opcode.integer_convert,
                    .result_type = result,
                    .operands = &[_]p.Id{0},
                    .immediate = @as(u64, 0),
                    .failures = invalid,
                },
                &.{from},
                undefined,
            ),
        );
    }
}
