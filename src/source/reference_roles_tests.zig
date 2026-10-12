const std = @import("std");
const ast = @import("ast.zig");
const check = @import("check.zig");
const Id = @import("horos_data").program.Id;
const Case = struct { term: ast.Term, values: []const Id = &.{}, terms: []const Id = &.{}, bound: []const Id = &.{} };
test "source reference collection preserves explicit order multiplicity and catalog separation" {
    const cases = [_]Case{
        .{ .term = .{ .value = 2 }, .values = &.{2} },
        .{ .term = .{ .dispose = 2 }, .values = &.{2} },
        .{ .term = .{ .fail = 2 }, .values = &.{2} },
        .{ .term = .{ .yield_then = 3 }, .terms = &.{3} },
        .{ .term = .{ .bind = .{ .variable = 1, .value = 2, .next = 3 } }, .terms = &.{ 2, 3 }, .bound = &.{1} },
        .{ .term = .{ .conditional = .{ .condition = 1, .when_true = 2, .when_false = 3 } }, .values = &.{1}, .terms = &.{ 2, 3 } },
        .{ .term = .{ .call = .{ .function = 99, .arguments = &.{ 2, 2, 3 } } }, .values = &.{ 2, 2, 3 } },
        .{ .term = .{ .apply = .{ .computation = 1, .arguments = &.{ 2, 3 } } }, .values = &.{ 1, 2, 3 } },
        .{ .term = .{ .perform = .{ .effect = 99, .capability = 1, .payload = 2, .bodies = &.{ 3, 4 }, .use_site_capabilities = &.{ 5, 6 } } }, .values = &.{ 2, 1, 3, 4, 5, 6 } },
        .{ .term = .{ .perform = .{ .effect = 99, .payload = 2 } }, .values = &.{2} },
        .{ .term = .{ .handle = .{ .handler = 99, .body = 1, .arguments = &.{ 2, 3 }, .state = &.{ 4, 5 } } }, .values = &.{ 1, 2, 3, 4, 5 } },
        .{ .term = .{ .resume_value = .{ .resumption = 1, .argument = 2 } }, .values = &.{ 1, 2 } },
        .{ .term = .{ .resume_with = .{ .resumption = 1, .argument = 2, .handler = 99, .state = &.{ 3, 4 } } }, .values = &.{ 1, 2, 3, 4 } },
        .{ .term = .{ .resume_computation = .{ .resumption = 1, .computation = 2 } }, .values = &.{ 1, 2 } },
        .{ .term = .{ .protect = .{ .body = 1, .cleanup = 2, .arguments = &.{ 3, 4 }, .resource = 5, .loan_region = 99 } }, .values = &.{ 1, 2, 3, 4, 5 } },
        .{ .term = .{ .with_region = .{ .region = 99, .body = 1, .arguments = &.{ 2, 3 } } }, .values = &.{ 1, 2, 3 } },
        .{ .term = .{ .match_sum = .{ .value = 1, .cases = &.{ .{ .variable = 2, .body = 3 }, .{ .variable = 4, .body = 5 } } } }, .values = &.{1}, .terms = &.{ 3, 5 }, .bound = &.{ 2, 4 } },
        .{ .term = .{ .unpack_product = .{ .value = 1, .variables = &.{ 2, 3 }, .body = 4 } }, .values = &.{1}, .terms = &.{4}, .bound = &.{ 2, 3 } },
    };
    for (std.meta.tags(std.meta.Tag(ast.Term))) |tag| {
        var covered = false;
        for (cases) |case| if (std.meta.activeTag(case.term) == tag) {
            covered = true;
            break;
        };
        try std.testing.expect(covered);
    }
    for (cases) |case| {
        var refs: check.References = .{ .allocator = std.testing.allocator };
        defer refs.values.deinit(std.testing.allocator);
        defer refs.terms.deinit(std.testing.allocator);
        defer refs.bound.deinit(std.testing.allocator);
        try refs.collect(case.term);
        try std.testing.expectEqualSlices(Id, case.values, refs.values.items);
        try std.testing.expectEqualSlices(Id, case.terms, refs.terms.items);
        try std.testing.expectEqualSlices(Id, case.bound, refs.bound.items);
    }
}
