// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
pub fn equal(comptime T: type, left: T, right: T) bool {
    @setEvalBranchQuota(10000);
    return equalFields(T, left, right);
}

inline fn equalFields(comptime T: type, left: T, right: T) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| if (!equalFields(
                FieldType,
                @field(left, field_name),
                @field(right, field_name),
            )) break :blk false;
            break :blk true;
        },
        .@"union" => switch (left) {
            inline else => |value, tag| switch (right) {
                tag => |other| equalFields(
                    @TypeOf(value),
                    value,
                    other,
                ),
                else => false,
            },
        },
        .pointer => |info| blk: {
            if (info.size != .slice) break :blk left == right;
            if (left.len != right.len) break :blk false;
            for (left, right) |x, y| if (!equalFields(info.child, x, y)) break :blk false;
            break :blk true;
        },
        .optional => |info| if (left) |value| if (right) |other| equalFields(
            info.child,
            value,
            other,
        ) else false else right == null,
        .array => |info| blk: {
            for (left, right) |x, y| if (!equalFields(info.child, x, y)) break :blk false;
            break :blk true;
        },
        else => left == right,
    };
}
