//! Synthetic heterogeneous live interfaces, authored through the public builder.
const horos = @import("horos");
const std = @import("std");
const p = horos.data.program;

pub fn mixed(
    b: *horos.source.Builder,
    count: usize,
    rotation: usize,
    reverse: bool,
) !horos.source.Module {
    return variedMixed(b, count, .{ .rotation = rotation, .reverse_operands = reverse });
}

pub const MixedVariation = struct {
    rotation: usize = 0,
    seed: ?u64 = null,
    reverse_operands: bool = false,
    reverse_declarations: bool = false,
    copies: usize = 2,
};

pub fn variedMixed(
    b: *horos.source.Builder,
    count: usize,
    variation: MixedVariation,
) !horos.source.Module {
    const unit = try b.scalar(void);
    const kinds = [_]p.Id{ try b.scalar(bool), try b.scalar(u64), try b.scalar(u32) };
    var effects: [3]p.Id = undefined;
    for (
        &effects,
        kinds,
        [_][]const u8{ "compact/bool", "compact/u64", "compact/u32" },
    ) |*effect, kind, name| {
        effect.* = try b.effect(.{ .identity = name, .payload = unit, .result = kind });
    }
    const variables = try b.allocator().alloc(p.Id, count);
    const total = std.math.add(usize, count, variation.copies) catch return error.InvalidLength;
    const schemas = try b.allocator().alloc(p.Id, total);
    const values = try b.allocator().alloc(p.Id, total);
    for (0..count) |index| {
        const position = if (variation.reverse_declarations) count - index - 1 else index;
        variables[position] = try b.variable(kinds[kindIndex(position, variation)]);
    }
    for (0..count) |index| {
        const source = if (variation.reverse_operands) count - index - 1 else index;
        schemas[index] = kinds[kindIndex(source, variation)];
        values[index] = try b.reference(variables[source]);
    }
    for (count..total) |index| {
        schemas[index] = kinds[kindIndex(0, variation)];
        values[index] = try b.reference(variables[0]);
    }
    const result = try b.schema(.{ .product = schemas });
    const entry = try b.declare(&.{}, result, &effects, &.{});
    var term = try b.pure(try b.primitive(result, .product, values, 0));
    var index = count;
    while (index != 0) {
        index -= 1;
        const request = try b.term(.{ .perform = .{
            .effect = effects[kindIndex(index, variation)],
            .payload = try b.constant(void, {}),
        } });
        term = try b.bind(variables[index], request, term);
    }
    try b.define(entry, term);
    return b.module(entry, unit);
}

fn kindIndex(index: usize, variation: MixedVariation) usize {
    const seed = variation.seed orelse return (index + variation.rotation) % 3;
    // Deterministic test-data mixer; wrapping is intentional, not authored arithmetic.
    var bits = @as(u64, index) *% 0x9e3779b97f4a7c15 +% seed;
    bits ^= bits >> 30;
    bits *%= 0xbf58476d1ce4e5b9;
    return @intCast((bits ^ (bits >> 27)) % 3);
}

/// The existing stored-constant workload: one 64 KiB payload referenced twice.
pub fn storedConstant(b: *horos.source.Builder, length: usize) !horos.source.Module {
    const bytes_type = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ bytes_type, bytes_type } });
    var measured: horos.data.wire.Writer = .{};
    try measured.natural(length);
    const total = std.math.add(usize, measured.position, length) catch return error.InvalidLength;
    const bytes = try b.allocator().alloc(u8, total);
    @memset(bytes, 0x5a);
    var writer: horos.data.wire.Writer = .{ .output = bytes };
    try writer.natural(length);
    const first = try b.literal(.{ .schema = bytes_type, .bytes = bytes });
    const second = try b.literal(.{ .schema = bytes_type, .bytes = bytes });
    const entry = try b.declare(&.{}, pair, &.{}, &.{});
    try b.define(entry, try b.pure(try b.primitive(pair, .product, &.{ first, second }, 0)));
    return b.module(entry, unit);
}
