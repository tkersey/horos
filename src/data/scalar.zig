// Copyright (c) 2026 Boundary contributors. MIT license.
//! Normative pure scalar helpers shared by admission and production evaluation.
const std = @import("std");
const p = @import("program.zig");
pub const Fault = p.Fault;
pub const Error = error{ InvalidScalar, NotInteger };
pub const Result = union(enum) { value: [8]u8, fault: Fault };

pub fn width(schema: p.Schema) ?usize {
    return switch (schema) {
        .unit => 0,
        .boolean, .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32, .enumeration => 4,
        .i64, .u64 => 8,
        else => null,
    };
}

pub fn fromBytes(schema: p.Schema, bytes: []const u8) Error![8]u8 {
    if (bytes.len != (width(schema) orelse return error.InvalidScalar)) return error.InvalidScalar;
    if (schema == .boolean and bytes[0] > 1) return error.InvalidScalar;
    if (schema == .enumeration and std.mem.indexOfScalar(u32, schema.enumeration, std.mem.readInt(u32, bytes[0..4], .little)) == null) return error.InvalidScalar;
    var result = @as([8]u8, @splat(0));
    @memcpy(result[0..bytes.len], bytes);
    return result;
}

pub fn validate(schema: p.Schema, bytes: [8]u8) Error!void {
    const length = width(schema) orelse return error.InvalidScalar;
    if (schema == .boolean and bytes[0] > 1) return error.InvalidScalar;
    if (schema == .enumeration and std.mem.indexOfScalar(u32, schema.enumeration, std.mem.readInt(u32, bytes[0..4], .little)) == null) return error.InvalidScalar;
    for (bytes[length..]) |byte| if (byte != 0) return error.InvalidScalar;
}

pub fn integer(schema: p.Schema, bytes: [8]u8) Error!i128 {
    try validate(schema, bytes);
    return switch (schema) {
        .i8 => std.mem.readInt(i8, bytes[0..1], .little),
        .i16 => std.mem.readInt(i16, bytes[0..2], .little),
        .i32 => std.mem.readInt(i32, bytes[0..4], .little),
        .i64 => std.mem.readInt(i64, &bytes, .little),
        .u8 => bytes[0],
        .u16 => std.mem.readInt(u16, bytes[0..2], .little),
        .u32 => std.mem.readInt(u32, bytes[0..4], .little),
        .u64 => std.mem.readInt(u64, &bytes, .little),
        else => error.NotInteger,
    };
}

fn encode(comptime T: type, value: i128) ?[8]u8 {
    const narrowed = std.math.cast(T, value) orelse return null;
    var output = @as([8]u8, @splat(0));
    std.mem.writeInt(T, output[0..@sizeOf(T)], narrowed, .little);
    return output;
}

pub fn fromInteger(schema: p.Schema, value: i128) ?[8]u8 {
    return switch (schema) {
        .i8 => encode(i8, value),
        .i16 => encode(i16, value),
        .i32 => encode(i32, value),
        .i64 => encode(i64, value),
        .u8 => encode(u8, value),
        .u16 => encode(u16, value),
        .u32 => encode(u32, value),
        .u64 => encode(u64, value),
        else => null,
    };
}

const integer_schemas = [_]p.Schema{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 };
fn conversionIndex(schema: p.Schema) ?usize {
    inline for (integer_schemas, 0..) |known, index| if (std.meta.activeTag(schema) == std.meta.activeTag(known)) return index;
    return null;
}
const conversion_fallibility = table: {
    @setEvalBranchQuota(10000);
    var result: [integer_schemas.len][integer_schemas.len]bool = undefined;
    for (integer_schemas, 0..) |source, i| for (integer_schemas, 0..) |target, j| {
        result[i][j] = intervalConversionCanFail(source, target);
    };
    break :table result;
};
pub fn conversionCanFail(source: p.Schema, target: p.Schema) bool {
    if (conversionIndex(source)) |from| if (conversionIndex(target)) |to| return conversion_fallibility[from][to];
    return intervalConversionCanFail(source, target);
}
fn intervalConversionCanFail(source: p.Schema, target: p.Schema) bool {
    const source_width = width(source) orelse return true;
    const signed = switch (source) {
        .i8, .i16, .i32, .i64 => true,
        else => false,
    };
    const bits: u7 = @intCast(source_width * 8 - @intFromBool(signed));
    const minimum: i128 = if (signed) -(@as(i128, 1) << bits) else 0;
    const maximum = (@as(i128, 1) << bits) - 1;
    return fromInteger(target, minimum) == null or fromInteger(target, maximum) == null;
}

pub fn binary(op: p.Opcode, schema: p.Schema, left: [8]u8, right: [8]u8) Error!Result {
    if (op == .equal and schema == .boolean) {
        try validate(schema, left);
        try validate(schema, right);
        var result = @as([8]u8, @splat(0));
        result[0] = @intFromBool(left[0] == right[0]);
        return .{ .value = result };
    }
    const a = try integer(schema, left);
    const b = try integer(schema, right);
    if (op == .integer_bit_and or op == .integer_bit_or or op == .integer_bit_xor) {
        var output = @as([8]u8, @splat(0));
        for (output[0..width(schema).?], 0..) |*byte, index| byte.* = switch (op) {
            .integer_bit_and => left[index] & right[index],
            .integer_bit_or => left[index] | right[index],
            .integer_bit_xor => left[index] ^ right[index],
            else => unreachable,
        };
        return .{ .value = output };
    }
    if (op == .equal or op == .less) {
        var result = @as([8]u8, @splat(0));
        result[0] = @intFromBool(if (op == .equal) a == b else a < b);
        return .{ .value = result };
    }
    const value = switch (op) {
        .integer_add => std.math.add(i128, a, b) catch return .{ .fault = .arithmetic_overflow },
        .integer_sub => std.math.sub(i128, a, b) catch return .{ .fault = .arithmetic_overflow },
        .integer_mul => std.math.mul(i128, a, b) catch return .{ .fault = .arithmetic_overflow },
        .integer_div, .integer_rem => blk: {
            if (b == 0) return .{ .fault = .division_by_zero };
            // Both operations reject the signed minimum divided by -1.
            if (b == -1 and fromInteger(schema, -a) == null) return .{ .fault = .arithmetic_overflow };
            break :blk if (op == .integer_div) @divTrunc(a, b) else @rem(a, b);
        },
        else => return error.NotInteger,
    };
    return .{ .value = fromInteger(schema, value) orelse return .{ .fault = .arithmetic_overflow } };
}

pub fn unary(op: p.Opcode, source: p.Schema, target: p.Schema, input: [8]u8) Error!Result {
    try validate(source, input);
    if (op == .enum_tag) {
        if (source != .enumeration or target != .u32) return error.InvalidScalar;
        return .{ .value = input };
    }
    const value = try integer(source, input);
    if (op == .integer_convert) return .{ .value = fromInteger(target, value) orelse return .{ .fault = .arithmetic_overflow } };
    if (op != .integer_bit_not) return error.NotInteger;
    var output = @as([8]u8, @splat(0));
    for (output[0..width(source).?], 0..) |*byte, index| byte.* = ~input[index];
    return .{ .value = output };
}

test "scalar operations preserve fixed widths and report authored arithmetic faults" {
    const max = fromInteger(.u64, std.math.maxInt(u64)).?;
    const one = fromInteger(.u64, 1).?;
    try std.testing.expectEqual(Fault.arithmetic_overflow, (try binary(.integer_add, .u64, max, one)).fault);
    const zero = fromInteger(.u64, 0).?;
    try std.testing.expectEqual(Fault.division_by_zero, (try binary(.integer_div, .u64, one, zero)).fault);
    const minimum = fromInteger(.i64, std.math.minInt(i64)).?;
    const negative_one = fromInteger(.i64, -1).?;
    try std.testing.expectEqual(Fault.arithmetic_overflow, (try binary(.integer_div, .i64, minimum, negative_one)).fault);
    const negative = fromInteger(.i8, -3).?;
    try std.testing.expectEqual(@as(i128, -3), try integer(.i8, negative));
}

test "remainder overflow, bit widths, and checked conversions preserve scalar domains" {
    inline for (.{ p.Schema.i8, .i16, .i32, .i64 }) |shape| {
        const bits = width(shape).? * 8;
        const minimum: i128 = -(@as(i128, 1) << @intCast(bits - 1));
        const negative_one = fromInteger(shape, -1).?;
        try std.testing.expectEqual(Fault.arithmetic_overflow, (try binary(.integer_rem, shape, fromInteger(shape, minimum).?, negative_one)).fault);
        try std.testing.expectEqual(@as(i128, 0), try integer(shape, (try binary(.integer_rem, shape, fromInteger(shape, minimum + 1).?, negative_one)).value));
        try std.testing.expectEqual(@as(i128, -1), try integer(shape, (try binary(.integer_rem, shape, fromInteger(shape, -5).?, fromInteger(shape, 2).?)).value));
    }
    inline for (.{ p.Schema.u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 }) |shape| {
        const zero = fromInteger(shape, 0).?;
        const inverse = (try unary(.integer_bit_not, shape, shape, zero)).value;
        try validate(shape, inverse);
        try std.testing.expectEqualSlices(u8, &zero, &(try binary(.integer_bit_xor, shape, inverse, inverse)).value);
    }
    try std.testing.expect(!conversionCanFail(.u32, .u64));
    try std.testing.expect(!conversionCanFail(.i32, .i64));
    try std.testing.expect(conversionCanFail(.u64, .i64));
    try std.testing.expect(conversionCanFail(.i64, .u64));
    try std.testing.expectEqual(Fault.arithmetic_overflow, (try unary(.integer_convert, .u64, .i64, fromInteger(.u64, std.math.maxInt(u64)).?)).fault);
    try std.testing.expectEqual(Fault.arithmetic_overflow, (try unary(.integer_convert, .i64, .u64, fromInteger(.i64, -1).?)).fault);
}

test "conversion table matches independently expressed mathematical ranges for all 64 pairs" {
    const types = .{ i8, i16, i32, i64, u8, u16, u32, u64 };
    inline for (types, integer_schemas) |Source, from| inline for (types, integer_schemas) |Target, to| {
        const expected = @as(i128, std.math.minInt(Source)) < @as(i128, std.math.minInt(Target)) or @as(i128, std.math.maxInt(Source)) > @as(i128, std.math.maxInt(Target));
        try std.testing.expectEqual(expected, conversionCanFail(from, to));
    };
    // Preserve the public predicate's historical noninteger domain exactly.
    try std.testing.expect(!conversionCanFail(.unit, .u8));
    try std.testing.expect(!conversionCanFail(.boolean, .u8));
    try std.testing.expect(conversionCanFail(.boolean, .i8));
    try std.testing.expect(!conversionCanFail(.{ .enumeration = &.{ 1, 7 } }, .u32));
    try std.testing.expect(conversionCanFail(.{ .enumeration = &.{ 1, 7 } }, .i32));
    try std.testing.expect(conversionCanFail(.bytes, .u64));
    try std.testing.expect(conversionCanFail(.u8, .boolean));
}
