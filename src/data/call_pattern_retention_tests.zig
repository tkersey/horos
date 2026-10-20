// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const patterns = @import("call_patterns.zig");
const own = @import("activation_ownership.zig");
const closed = @import("closed_compilation.zig");
const a = std.testing.allocator;
const callable: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                  .unit, .boolean,
        .{ .internal = .{ .computation = .{
            .parameters = &.{0},
            .result = 0,
            .capture_bound = &.{2},
            .use = .reusable,
        } } },
        .{ .internal = .{ .capability = 0 } },
        .{ .internal = .{ .resumption = .{
            .effect = 0,
            .input = 1,
            .answer = 0,
            .handled = &.{0},
            .capture_bound = &.{ 0, 1, 3, 4 },
            .mode = .deep,
            .use = .linear,
        } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{4},
            .result = 0,
            .effects = &.{0},
            .capture_bound = &.{ 0, 2 },
            .use = .reusable,
        } } },
    },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{} },
    },
    .effects = &.{.{ .identity = "review", .payload = 1, .result = 1, .external = false }},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 2, 0, 6, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 2, 0, 4, 3, 0 } },
            .result = 0,
            .effects = &.{0},
        },
        .{
            .entry = 4,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 3, 4, 0, 1, 0, 2 } },
            .result = 0,
            .effects = &.{0},
        },
        .{ .entry = 9, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 2, 0, 0 } }, .result = 0 },
        .{ .entry = 12, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 13, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 1, 5, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 2,
                .opcode = .computation,
                .operands = &.{ 0, 1 },
                .immediate = 1,
            }},
            .terminator = .{ .handle = .{
                .handler = 0,
                .body = 2,
                .arguments = &.{},
                .state = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 3,
                .opcode = .computation,
                .operands = &.{0},
                .immediate = 0,
            }},
            .terminator = .{ .call = .{
                .function = 2,
                .arguments = &.{ 3, 2, 1 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{
            .function = 2,
            .instructions = &.{
                .{ .destination = 4, .opcode = .constant, .immediate = 0 },
                .{ .destination = 5, .opcode = .equal, .operands = &.{ 2, 4 } },
            },
            .terminator = .{ .branch = .{
                .condition = 5,
                .when_true = .{ .block = 8 },
                .when_false = .{ .block = 5 },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 3, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .perform = .{
                .effect = 0,
                .capability = 1,
                .payload = 3,
                .next = .{ .block = 6 },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 0,
                .arguments = &.{2},
                .next = .{
                    .block = 7,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 2,
                .arguments = &.{ 0, 1, 4 },
                .next = .{
                    .block = 8,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{
            .function = 3,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 0,
                .when_true = .{ .block = 10 },
                .when_false = .{ .block = 11 },
            } },
        },
        .{
            .function = 3,
            .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 0 }},
            .terminator = .{ .return_value = 2 },
        },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{
            .function = 5,
            .instructions = &.{},
            .terminator = .{ .resume_value = .{
                .resumption = 1,
                .argument = 0,
                .next = .{
                    .block = 14,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
    .scopes = .{ .captures = &.{
        .{ .fields = &.{2}, .use = .reusable },
        .{ .fields = &.{ 2, 0 }, .use = .reusable },
    } },
    .constructors = &.{
        .{ .function = 3, .capture = 0, .schema = 3 },
        .{ .function = 1, .capture = 1, .schema = 6 },
    },
    .handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 4,
        .clauses = &.{.{ .effect = 0, .function = 5, .resumption = 5 }},
    }},
};
const variant: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{
        .u64, .boolean, .unit, .{ .sum = &.{0} }, .{ .internal = .{ .capability = 0 } },
        .{ .internal = .{ .resumption = .{
            .effect = 0,
            .input = 2,
            .answer = 0,
            .handled = &.{0},
            .capture_bound = &.{ 1, 3, 4 },
            .mode = .deep,
            .use = .linear,
        } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{4},
            .result = 0,
            .effects = &.{0},
            .capture_bound = &.{ 0, 1 },
            .use = .reusable,
        } } },
    },
    .constants = &.{ .{ .schema = 1, .bytes = &.{1} }, .{ .schema = 2, .bytes = &.{} } },
    .effects = &.{.{
        .identity = "retained variant",
        .payload = 2,
        .result = 2,
        .external = false,
    }},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 1, 3, 6, 0 } },
            .result = 0,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 0, 1, 4, 3, 0 } },
            .result = 0,
            .effects = &.{0},
        },
        .{
            .entry = 4,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = &.{ 3, 1, 4, 1, 2, 0 } },
            .result = 0,
            .effects = &.{0},
        },
        .{ .entry = 9, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 10, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 2, 5, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 3,
                .opcode = .computation,
                .operands = &.{ 0, 1 },
            }},
            .terminator = .{ .handle = .{
                .handler = 0,
                .body = 3,
                .arguments = &.{},
                .state = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 3, .opcode = .variant, .operands = &.{0} }},
            .terminator = .{ .call = .{
                .function = 2,
                .arguments = &.{ 3, 1, 2 },
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 1,
                .when_true = .{ .block = 5 },
                .when_false = .{ .block = 7 },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 4, .opcode = .constant, .immediate = 1 }},
            .terminator = .{ .perform = .{
                .effect = 0,
                .capability = 2,
                .payload = 4,
                .next = .{ .block = 6 },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{.{
                .destination = 5,
                .opcode = .variant_payload,
                .operands = &.{0},
                .failures = &.{.{ .kind = .invalid_variant, .value = 1 }},
            }},
            .terminator = .{ .return_value = 5 },
        },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 3, .opcode = .constant }},
            .terminator = .{ .call = .{
                .function = 2,
                .arguments = &.{ 0, 3, 2 },
                .next = .{
                    .block = 8,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 5 } },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{
            .function = 4,
            .instructions = &.{},
            .terminator = .{ .resume_value = .{
                .resumption = 1,
                .argument = 0,
                .next = .{
                    .block = 11,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
    .scopes = .{ .captures = &.{.{ .fields = &.{ 0, 1 }, .use = .reusable }} },
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 6 }},
    .handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 3,
        .clauses = &.{.{ .effect = 0, .function = 4, .resumption = 5 }},
    }},
};

test "retained call-pattern representations preserve admitted inputs" {
    for ([_]ir.Program{ callable, variant }) |original| {
        var admitted = try own.analyze(a, original);
        admitted.deinit();
        var baseline = try closed.run(a, original, .{});
        defer baseline.deinit();
        if (try patterns.construct(a, original, .{})) |value| {
            var candidate = value;
            defer candidate.deinit();
            for (candidate.variants) |item|
                try std.testing.expect(item.key.function != 2 or item.key.parameter != 0);
            try patterns.validate(
                a,
                original,
                candidate.program,
                candidate.variants,
                candidate.sites,
                1000000,
            );
        }
        var direct = try patterns.run(a, original, null, .{});
        defer direct.deinit();
        var compiled = try closed.run(a, original, .{ .contract = .semantic });
        defer compiled.deinit();
    }
}

test "retained call-pattern compatible replacement schemas still specialize" {
    for ([_]ir.Program{ callable, variant }, 0..) |original, kind| {
        var schemas = original.schemas[0..7].*;
        schemas[5].internal.resumption.capture_bound = if (kind == 0)
            &.{ 0, 1, 2, 3, 4 }
        else
            &.{ 0, 1, 3, 4 };
        var compatible = original;
        compatible.schemas = &schemas;
        var candidate = (try patterns.construct(a, compatible, .{})).?;
        defer candidate.deinit();
        var selected = false;
        for (candidate.variants) |item| {
            if (item.key.function == 2 and item.key.parameter == 0) selected = true;
        }
        try std.testing.expect(selected);
        try patterns.validate(
            a,
            compatible,
            candidate.program,
            candidate.variants,
            candidate.sites,
            1000000,
        );
        var compiled = try closed.run(a, compatible, .{ .contract = .semantic });
        defer compiled.deinit();
    }
}

test "retained call-pattern observations never admit invalid originals" {
    var schemas = callable.schemas[0..7].*;
    schemas[5].internal.resumption.capture_bound = &.{};
    var invalid = callable;
    invalid.schemas = &schemas;
    try std.testing.expectError(error.InvalidOwnership, own.analyze(a, invalid));
    try std.testing.expectError(error.InvalidOwnership, patterns.construct(a, invalid, .{}));
    try std.testing.expectError(error.InvalidOwnership, patterns.run(a, invalid, null, .{}));
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var schemas = callable.schemas[0..7].*;
    schemas[5].internal.resumption.capture_bound = &.{ 0, 1, 2, 3, 4 };
    var compatible = callable;
    compatible.schemas = &schemas;
    var candidate = (try patterns.construct(allocator, compatible, .{})).?;
    defer candidate.deinit();
}

fn limitedAllocationAttempt(allocator: std.mem.Allocator) !void {
    const candidate = patterns.construct(
        allocator,
        callable,
        .{ .work_limit = 100 },
    ) catch |err| switch (err) {
        error.CallPatternLimit, error.SemanticWorkLimit => return,
        else => return err,
    };
    if (candidate) |value| {
        var result = value;
        result.deinit();
    }
}

test "retained call-pattern observation allocation failure and work limits remain explicit" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    try @import("allocation_testing.zig").check(a, limitedAllocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, callable, .{});
    defer baseline.deinit();
    for ([_]u64{ 0, 1, 4 }) |limit| {
        var stats: patterns.Statistics = .{};
        var result = try patterns.run(a, callable, &stats, .{ .work_limit = limit });
        defer result.deinit();
        try std.testing.expect(stats.work_limit);
        try std.testing.expectEqual(
            try @import("program_image.zig").identity(a, baseline.program),
            try @import("program_image.zig").identity(a, result.program),
        );
    }
}

test "retained call-pattern candidate admission still rejects incompatible capture schemas" {
    var schemas = callable.schemas[0..7].*;
    schemas[5].internal.resumption.capture_bound = &.{ 0, 1, 2, 3, 4 };
    var compatible = callable;
    compatible.schemas = &schemas;
    var candidate = (try patterns.construct(a, compatible, .{})).?;
    defer candidate.deinit();
    var invalid = candidate.program;
    var changed = try a.dupe(@import("program.zig").Schema, candidate.program.schemas);
    defer a.free(changed);
    changed[5].internal.resumption.capture_bound =
        callable.schemas[5].internal.resumption.capture_bound;
    invalid.schemas = changed;
    try std.testing.expectError(
        error.InvalidOwnership,
        patterns.validate(a, compatible, invalid, candidate.variants, candidate.sites, 1000000),
    );
}
