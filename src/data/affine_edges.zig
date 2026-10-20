// Copyright (c) 2026 Boundary contributors. MIT license.
//! Predecessor-view capture transfer for affine CFG edges.
const std = @import("std");
const ir = @import("activation.zig");
const extract = @import("affine_extract.zig");
const space = @import("affine_space.zig");

/// Capture updates may only read already available scalar values. Results from a
/// call have no affine state relation unless a separate return summary proves it.
pub fn state(
    allocator: std.mem.Allocator,
    captures: []const ir.Id,
    predecessor: []const ?extract.Expression,
    edge: ir.Edge,
    budget: *space.Budget,
) extract.Error!?[]extract.Expression {
    const result = try allocator.alloc(extract.Expression, captures.len);
    errdefer allocator.free(result);
    for (captures, result) |slot, *value| {
        try budget.charge();
        var source_slot = slot;
        for (edge.assignments) |assignment| {
            try budget.charge();
            if (assignment.destination != slot) continue;
            switch (assignment.source) {
                .slot => |input| source_slot = input,
                .returned => {
                    allocator.free(result);
                    return null;
                },
            }
        }
        value.* = predecessor[@intCast(source_slot)] orelse {
            allocator.free(result);
            return null;
        };
    }
    return result;
}

test "capture edge cycle reads one predecessor view" {
    const a = std.testing.allocator;
    var budget: space.Budget = .{ .remaining = 100 };
    const predecessor = [_]?extract.Expression{
        .{ .state = 1 },                            .{ .state = 2 }, .{ .state = 4 },
        .{ .state = 1, .input = 1, .constant = 7 },
    };
    const next = (try state(a, &.{ 0, 1, 2 }, &predecessor, .{ .block = 0, .assignments = &.{
        .{ .destination = 0, .source = .{ .slot = 1 } },
        .{ .destination = 1, .source = .{ .slot = 2 } },
        .{ .destination = 2, .source = .{ .slot = 3 } },
    } }, &budget)).?;
    defer a.free(next);
    try std.testing.expectEqualDeep(extract.Expression{ .state = 2 }, next[0]);
    try std.testing.expectEqualDeep(extract.Expression{ .state = 4 }, next[1]);
    try std.testing.expectEqualDeep(
        extract.Expression{ .state = 1, .input = 1, .constant = 7 },
        next[2],
    );
    try std.testing.expectEqualDeep(extract.Expression{ .state = 1 }, predecessor[0].?);
}
