// Copyright (c) 2026 Boundary contributors. MIT license.
//! Cleanup schema construction for explicit source-IR fixtures and generators.
//! Typed authors use Context.cleanupInfo and Body.protect/bracket.
const source = @import("../../source.zig");
const p = @import("horos_data").program;

pub fn exitInfo(builder: *source.Builder, failure: p.Id) source.Error!p.Id {
    const unit = try builder.scalar(void);
    const reason = try builder.schema(.{ .sum = &.{
        try builder.schema(.text),
        try builder.schema(.bytes),
    } });
    const primary = try builder.schema(.{ .sum = &.{ unit, failure, reason, unit } });
    return builder.schema(.{ .product = &.{
        primary,
        try builder.schema(.{ .sum = &.{ unit, reason } }),
        try builder.schema(.{ .seq = failure }),
    } });
}
