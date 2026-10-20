const std = @import("std");
const ir = @import("activation.zig");
const eliminate = @import("handler_elimination.zig");
const own = @import("activation_ownership.zig");
const a = std.testing.allocator;
pub const identity: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64, .unit,
        .{ .internal = .{ .computation = .{
            .parameters = &.{},
            .result = 0,
            .capture_bound = &.{0},
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
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 3, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 1, .opcode = .integer_bit_not, .operands = &.{1} },
                .{ .destination = 2, .opcode = .computation, .operands = &.{0} },
            },
            .terminator = .{ .handle = .{
                .handler = 0,
                .body = 2,
                .arguments = &.{},
                .state = &.{1},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    },
    .handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 2,
        .state = &.{0},
        .clauses = &.{},
    }},
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 2 }},
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
};
fn attempt(allocator: std.mem.Allocator) !void {
    var result = try eliminate.run(allocator, identity, null, .{});
    defer result.deinit();
}
test "empty identity handler disappears without deleting state evaluation" {
    try @import("allocation_testing.zig").check(a, attempt, .{});
    var stats: eliminate.Statistics = .{};
    var result = try eliminate.run(a, identity, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.installations_removed);
    try std.testing.expectEqual(@as(usize, 0), result.program.handlers.len);
    var state_evaluated = false;
    for (result.program.blocks) |block|
        for (block.instructions) |op|
            if (op.opcode == .integer_bit_not) {
                state_evaluated = true;
            };
    try std.testing.expect(state_evaluated);
    var limited = try eliminate.run(a, identity, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(@as(usize, 1), limited.program.handlers.len);
    var invalid = identity;
    invalid.roots.entry = 99;
    try std.testing.expectError(
        error.InvalidReference,
        eliminate.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}
test "nonidentity return calls are preserved and shallow handlers are retained" {
    var original = identity;
    var blocks = identity.blocks[0..4].*;
    blocks[3].terminator = .{ .return_value = 0 };
    original.blocks = &blocks;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    var stats: eliminate.Statistics = .{};
    var retained = try eliminate.run(a, original, &stats, .{});
    defer retained.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.installations_removed);
    try std.testing.expectEqual(@as(usize, 1), stats.return_calls_preserved);
    var candidate = try eliminate.construct(a, original, .{});
    defer candidate.deinit();
    try eliminate.validate(a, original, candidate.program, 1_000_000);
    const Mutation = struct {
        fn allocation(allocator: std.mem.Allocator, program: ir.Program) !void {
            var result = try eliminate.run(allocator, program, null, .{});
            defer result.deinit();
        }
    };
    try @import("allocation_testing.zig").check(a, Mutation.allocation, .{original});
    const altered = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(altered);
    const bridge = original.blocks.len;
    const arguments = candidate.program.blocks[bridge].terminator.call.arguments;
    const swapped = [_]@import("program.zig").Id{ arguments[1], arguments[0] };
    altered[bridge].terminator.call.arguments = &swapped;
    var wrong_order = candidate.program;
    wrong_order.blocks = altered;
    admitted = try own.analyze(a, wrong_order);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidHandlerElimination,
        eliminate.validate(a, original, wrong_order, 1_000_000),
    );
    var forged = original;
    var rewritten = blocks;
    const handle = blocks[0].terminator.handle;
    rewritten[0].terminator = .{ .apply = .{
        .computation = handle.body,
        .arguments = handle.arguments,
        .next = handle.next,
    } };
    forged.blocks = &rewritten;
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidHandlerElimination,
        eliminate.validate(a, original, forged, 1_000_000),
    );
    var shallow = identity;
    var handlers = identity.handlers[0..1].*;
    handlers[0].mode = .shallow;
    shallow.handlers = &handlers;
    admitted = try own.analyze(a, shallow);
    admitted.deinit();
    var shallow_result = try eliminate.run(a, shallow, &stats, .{});
    defer shallow_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.installations_removed);
}
