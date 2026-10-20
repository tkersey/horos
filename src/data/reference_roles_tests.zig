const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const access = @import("slot_access.zig");
test "portable roles count repeated slot reads and writes without confusing global IDs" {
    const edge: ir.Edge = .{
        .block = 7,
        .assignments = &.{
            .{ .destination = 7, .source = .{ .slot = 7 } },
            .{ .destination = 7, .source = .returned },
            .{ .destination = 8, .source = .{ .slot = 7 } },
        },
    };
    const cases = [_]struct { term: ir.Terminator, reads: usize, writes: usize }{
        .{ .term = .{ .return_value = 7 }, .reads = 1, .writes = 0 },
        .{ .term = .{ .fail = 7 }, .reads = 1, .writes = 0 },
        .{ .term = .{ .jump = edge }, .reads = 2, .writes = 2 },
        .{ .term = .{ .yield_value = edge }, .reads = 2, .writes = 2 },
        .{
            .term = .{ .branch = .{ .condition = 7, .when_true = edge, .when_false = edge } },
            .reads = 5,
            .writes = 4,
        },
        .{
            .term = .{ .switch_variant = .{ .value = 7, .cases = &.{ edge, edge } } },
            .reads = 5,
            .writes = 4,
        },
        .{
            .term = .{ .unpack_product = .{
                .value = 7,
                .destinations = &.{ 7, 7 },
                .next = edge,
            } },
            .reads = 3,
            .writes = 4,
        },
        .{
            .term = .{ .call = .{ .function = 7, .arguments = &.{ 7, 7 }, .next = edge } },
            .reads = 4,
            .writes = 2,
        },
        .{
            .term = .{ .perform = .{
                .effect = 7,
                .capability = 7,
                .payload = 7,
                .bodies = &.{ 7, 7 },
                .use_site_capabilities = &.{ 7, 7 },
                .next = edge,
            } },
            .reads = 8,
            .writes = 2,
        },
        .{
            .term = .{ .apply = .{ .computation = 7, .arguments = &.{7}, .next = edge } },
            .reads = 4,
            .writes = 2,
        },
        .{
            .term = .{ .handle = .{
                .handler = 7,
                .body = 7,
                .arguments = &.{7},
                .state = &.{7},
                .next = edge,
            } },
            .reads = 5,
            .writes = 2,
        },
        .{
            .term = .{ .resume_value = .{ .resumption = 7, .argument = 7, .next = edge } },
            .reads = 4,
            .writes = 2,
        },
        .{
            .term = .{ .resume_with = .{
                .resumption = 7,
                .argument = 7,
                .handler = 7,
                .state = &.{7},
                .next = edge,
            } },
            .reads = 5,
            .writes = 2,
        },
        .{
            .term = .{ .resume_computation = .{
                .resumption = 7,
                .computation = 7,
                .next = edge,
            } },
            .reads = 4,
            .writes = 2,
        },
        .{ .term = .{ .dispose = .{ .owned = 7, .next = edge } }, .reads = 3, .writes = 2 },
        .{
            .term = .{ .protect = .{
                .body = 7,
                .cleanup = 7,
                .arguments = &.{7},
                .resource = 7,
                .loan_region = 7,
                .next = edge,
            } },
            .reads = 6,
            .writes = 2,
        },
        .{
            .term = .{ .with_region = .{
                .region = 7,
                .body = 7,
                .arguments = &.{7},
                .next = edge,
            } },
            .reads = 4,
            .writes = 2,
        },
    };
    try std.testing.expectEqual(std.meta.tags(p.TerminatorTag).len, cases.len);
    for (cases) |case| {
        const found = access.terminator(case.term, 7);
        try std.testing.expectEqual(case.reads, found.reads);
        try std.testing.expectEqual(case.writes, found.writes);
    }
}
