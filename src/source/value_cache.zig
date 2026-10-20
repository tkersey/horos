// Copyright (c) 2026 Boundary contributors. MIT license.
//! Sharing permission for value expressions within one uninterrupted code block.
const std = @import("std");
const data = @import("horos_data");
const ast = @import("ast.zig");
const Error = @import("../source.zig").Error;

pub fn derive(
    allocator: std.mem.Allocator,
    source: ast.Module,
    traits: data.traits.Facts,
) Error![]bool {
    const cacheable = try allocator.alloc(bool, source.values.len);
    for (source.values, 0..) |value, id|
        cacheable[id] = switch (value.expression) {
            .variable, .literal => true,
            .lambda => traits.copy[@intCast(value.schema)],
            .primitive => |primitive| blk: {
                if (!traits.copy[@intCast(value.schema)]) break :blk false;
                switch (primitive.opcode) {
                    .cell_new,
                    .cell_get,
                    .cell_set,
                    .clone_resumption,
                    .package,
                    .unpack,
                    .resource_pack,
                    .resource_unpack,
                    => break :blk false,
                    else => {},
                }
                for (primitive.operands) |operand| {
                    if (!cacheable[@intCast(operand)]) break :blk false;
                    // Even a borrow requires its owner to remain live at this occurrence.
                    if (!traits.copy[
                        @intCast(source.values[
                            @intCast(operand)
                        ].schema)
                    ]) break :blk false;
                }
                break :blk true;
            },
        };
    return cacheable;
}
