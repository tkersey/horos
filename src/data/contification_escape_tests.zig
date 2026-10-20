// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const joins = @import("contification.zig");
const a = std.testing.allocator;
pub const returned: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64, .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{0},
            .use = .reusable,
        } } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 2, 0 } },
            .result = 0,
        },
        .{ .entry = 3, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 2 } }, .result = 2 },
        .{ .entry = 4, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{0},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 2,
                .arguments = &.{1},
                .next = .{
                    .block = 2,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 1,
                .opcode = .computation,
                .operands = &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .return_value = 1 },
        },
        .{
            .function = 2,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .integer_bit_xor,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .return_value = 2 },
        },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
    .constructors = &.{.{ .function = 2, .capture = 0, .schema = 2 }},
};
pub const retained: ir.Program = .{
    .roots = returned.roots,
    .schemas = returned.schemas,
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        returned.functions[0],
        .{ .entry = 2, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
        .{ .entry = 4, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .computation,
                .operands = &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .handle = .{
                .handler = 0,
                .body = 2,
                .arguments = &.{1},
                .state = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .yield_value = .{ .block = 3 } } },
        .{
            .function = 1,
            .instructions = returned.blocks[4].instructions,
            .terminator = .{ .return_value = 2 },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    },
    .handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 2,
        .clauses = &.{},
    }},
    .scopes = returned.scopes,
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
};
test "returned helper value and handler-retained capture remain first class" {
    for ([_]ir.Program{ returned, retained }) |original| {
        var admitted = try @import("activation_ownership.zig").analyze(a, original);
        defer admitted.deinit();
        try std.testing.expect(try joins.construct(a, original, .{}) == null);
        var result = try joins.run(a, original, null, .{});
        defer result.deinit();
        var baseline = try @import("coalescing.zig").run(a, original, .{});
        defer baseline.deinit();
        try std.testing.expectEqual(
            try @import("program_image.zig").identity(a, baseline.program),
            try @import("program_image.zig").identity(a, result.program),
        );
    }
}
