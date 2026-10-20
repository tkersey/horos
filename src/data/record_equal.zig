// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
pub fn equal(comptime T: type, left: T, right: T) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| if (!equal(
                FieldType,
                @field(left, field_name),
                @field(right, field_name),
            )) break :blk false;
            break :blk true;
        },
        .@"union" => blk: {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) break :blk false;
            break :blk switch (left) {
                inline else => |value, tag| equal(
                    @TypeOf(value),
                    value,
                    @field(right, @tagName(tag)),
                ),
            };
        },
        .pointer => |info| blk: {
            if (info.size != .slice) break :blk left == right;
            if (left.len != right.len) break :blk false;
            for (left, right) |x, y| if (!equal(info.child, x, y)) break :blk false;
            break :blk true;
        },
        .optional => |info| if (left) |value| if (right) |other| equal(
            info.child,
            value,
            other,
        ) else false else right == null,
        .array => |info| blk: {
            for (left, right) |x, y| if (!equal(info.child, x, y)) break :blk false;
            break :blk true;
        },
        else => left == right,
    };
}
