// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const own = @import("activation_ownership.zig");
const forwarding = @import("thunk_forwarding.zig");
const a = std.testing.allocator;
pub const wrapped: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .boolean, .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = 0,
            .capture_bound = &.{ 0, 2 },
            .use = .reusable,
        } } },
    },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 4 },
            .layout = .{ .slots = &.{ 0, 2, 2, 0, 0, 2 } },
            .result = 0,
        },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 3, .inputs = &.{0}, .layout = .{ .slots = &.{ 2, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{
            .{ .destination = 1, .opcode = .computation, .operands = &.{0}, .immediate = 0 },
            .{ .destination = 5, .opcode = .computation, .operands = &.{4}, .immediate = 0 },
            .{ .destination = 2, .opcode = .computation, .operands = &.{1}, .immediate = 1 },
        }, .terminator = .{ .apply = .{
            .computation = 2,
            .arguments = &.{},
            .next = .{ .block = 1, .assignments = &.{.{ .destination = 3, .source = .returned }} },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .apply = .{
                .computation = 0,
                .arguments = &.{},
                .next = .{
                    .block = 4,
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } },
        },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    },
    .constructors = &.{
        .{ .function = 1, .capture = 0, .schema = 2 },
        .{ .function = 2, .capture = 1, .schema = 2 },
    },
    .scopes = .{ .captures = &.{
        .{ .fields = &.{0}, .use = .reusable },
        .{ .fields = &.{2}, .use = .reusable },
    } },
};
test "forwarding is an exact captured-value law without moving any demand site" {
    var candidate = (try forwarding.construct(a, wrapped, .{})).?;
    defer candidate.deinit();
    try forwarding.validate(a, wrapped, candidate.program, .{});
    try std.testing.expectEqual(@as(usize, 1), candidate.sites.len);
    try std.testing.expectEqualSlices(
        u64,
        &.{1},
        candidate.program.blocks[0].instructions[2].operands,
    );
    try std.testing.expect(candidate.program.blocks[0].instructions[2].opcode == .move);
    try std.testing.expect(@import("record_equal.zig").equal(
        ir.Terminator,
        wrapped.blocks[0].terminator,
        candidate.program.blocks[0].terminator,
    ));
    var stats: forwarding.Statistics = .{};
    var selected = try forwarding.run(a, wrapped, &stats, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.wrappers_removed);
    try std.testing.expectEqual(@as(usize, 1), selected.program.constructors.len);
}
test "another same-schema captured thunk is not an interchangeable value" {
    var candidate = (try forwarding.construct(a, wrapped, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..5].*;
    var ops = blocks[0].instructions[0..3].*;
    ops[2].operands = &.{5};
    blocks[0].instructions = &ops;
    var forged = candidate.program;
    forged.blocks = &blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidThunkForwarding,
        forwarding.validate(a, wrapped, forged, .{}),
    );
}
test "a nonidentity return cannot be erased by treating its type as its implementation" {
    var different = wrapped;
    var blocks = wrapped.blocks[0..5].*;
    blocks[4].instructions = &.{.{ .destination = 1, .opcode = .boolean_not, .operands = &.{1} }};
    different.blocks = &blocks;
    var admitted = try own.analyze(a, different);
    admitted.deinit();
    var candidate = try forwarding.construct(a, different, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
    var forged_blocks = blocks;
    var ops = blocks[0].instructions[0..3].*;
    ops[2].opcode = .move;
    ops[2].immediate = 0;
    forged_blocks[0].instructions = &ops;
    var forged = different;
    forged.blocks = &forged_blocks;
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidThunkForwarding,
        forwarding.validate(a, different, forged, .{}),
    );
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try forwarding.run(allocator, wrapped, null, .{});
    defer result.deinit();
}
test "forwarding handles allocation failure and rolls deterministic work limits through P01" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, wrapped, .{});
    defer baseline.deinit();
    var stats: forwarding.Statistics = .{};
    var limited = try forwarding.run(a, wrapped, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
    var invalid = wrapped;
    invalid.roots.entry = 99;
    try std.testing.expectError(
        error.InvalidReference,
        forwarding.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}

test "an immediate wrapper return forwards its exact capture without a temporary" {
    var original = wrapped;
    var functions: [4]ir.Function = undefined;
    @memcpy(functions[0..3], wrapped.functions);
    functions[3] = .{
        .entry = 6,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 2, 2, 2 } },
        .result = 2,
    };
    var blocks: [7]ir.Block = undefined;
    @memcpy(blocks[0..5], wrapped.blocks);
    blocks[0].instructions = wrapped.blocks[0].instructions[0..2];
    blocks[0].terminator = .{ .call = .{
        .function = 3,
        .arguments = &.{ 1, 5 },
        .next = .{ .block = 1, .assignments = &.{.{ .destination = 2, .source = .returned }} },
    } };
    blocks[1].terminator = .{ .apply = .{
        .computation = 2,
        .arguments = &.{},
        .next = .{ .block = 5, .assignments = &.{.{ .destination = 3, .source = .returned }} },
    } };
    blocks[5] = .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } };
    blocks[6] = .{
        .function = 3,
        .instructions = &.{.{
            .destination = 2,
            .opcode = .computation,
            .operands = &.{0},
            .immediate = 1,
        }},
        .terminator = .{ .return_value = 2 },
    };
    original.functions = &functions;
    original.blocks = &blocks;
    var candidate = (try forwarding.construct(a, original, .{})).?;
    defer candidate.deinit();
    try forwarding.validate(a, original, candidate.program, .{});
    try std.testing.expectEqual(@as(usize, 0), candidate.program.blocks[6].instructions.len);
    try std.testing.expectEqual(@as(u64, 0), candidate.program.blocks[6].terminator.return_value);
    var changed = candidate.program.blocks[0..7].*;
    changed[6].terminator.return_value = 1;
    var forged = candidate.program;
    forged.blocks = &changed;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidThunkForwarding,
        forwarding.validate(a, original, forged, .{}),
    );
}
