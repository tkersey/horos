const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const admission = @import("admission.zig");

const example: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 0 },
    .schemas = &.{.u64},
    .constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }},
    .effects = &.{},
    .functions = &.{.{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 }},
    .blocks = &.{.{
        .function = 0,
        .instructions = &.{.{ .opcode = .constant, .destination = 0 }},
        .terminator = .{ .return_value = 0 },
    }},
};
fn admit(allocator: std.mem.Allocator, program: ir.Program) !void {
    var flow = try @import("activation_ownership.zig").analyze(allocator, program);
    defer flow.deinit();
}
fn borrowFlowExample() ir.Program {
    return .{
        .roots = .{ .entry = 2, .result = 0, .failure = 0 },
        .schemas = &.{ .unit, .{ .internal = .{ .region = 0 } } },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{
            .{
                .entry = 0,
                .inputs = &.{0},
                .layout = .{ .slots = &.{1} },
                .result = 1,
                .regions = &.{0},
            },
            .{
                .entry = 1,
                .inputs = &.{0},
                .layout = .{ .slots = &.{1} },
                .result = 1,
                .regions = &.{0},
            },
            .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        },
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        },
        .scopes = .{ .region_count = 1 },
    };
}

test "settled borrow queries reuse results without allocating again" {
    const borrows = @import("borrow_flow.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = borrowFlowExample();
    try admit(arena.allocator(), program);
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    const facts = try admission.schemas(allocator, program.schemas);
    var flow = try borrows.StableFlow.init(allocator, program, facts.exportable);
    const expected = [_]borrows.Source{.{ .parameter = 0 }};
    try std.testing.expectEqualSlices(borrows.Source, &expected, try flow.returned(0));
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqualSlices(borrows.Source, &expected, try flow.returned(0));
    try std.testing.expect(!failing.has_induced_failure);
}

test "a failed borrow query settles fully when the same query is retried" {
    const borrows = @import("borrow_flow.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const program = borrowFlowExample();
    try admit(arena.allocator(), program);
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    const facts = try admission.schemas(allocator, program.schemas);
    var flow = try borrows.StableFlow.init(allocator, program, facts.exportable);
    _ = try flow.returned(0);
    // Reserve the new query so the injected failure occurs inside settlement.
    try flow.queries.ensureUnusedCapacity(allocator, 1);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, flow.returned(1));
    try std.testing.expect(failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    const expected = [_]borrows.Source{.{ .parameter = 0 }};
    try std.testing.expectEqualSlices(borrows.Source, &expected, try flow.returned(1));
}

test "borrow validation batches independent function requirements" {
    const borrows = @import("borrow_flow.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var costs: [2]usize = undefined;
    for ([_]usize{ 8, 64 }, 0..) |count, sample| {
        var program = borrowFlowExample();
        var functions: [65]ir.Function = undefined;
        var blocks: [65]ir.Block = undefined;
        for (0..count) |index| {
            functions[index] = program.functions[0];
            functions[index].entry = index;
            blocks[index] = program.blocks[0];
            blocks[index].function = index;
        }
        functions[count] = program.functions[2];
        functions[count].entry = count;
        blocks[count] = program.blocks[2];
        blocks[count].function = count;
        program.roots.entry = count;
        program.functions = functions[0 .. count + 1];
        program.blocks = blocks[0 .. count + 1];
        try admit(arena.allocator(), program);
        const facts = try admission.schemas(arena.allocator(), program.schemas);
        var counted = std.testing.FailingAllocator.init(arena.allocator(), .{});
        try borrows.validate(counted.allocator(), program, facts.exportable, null);
        costs[sample] = counted.allocations;
    }
    // Eight times as many independent functions must not cause quadratic
    // repetitions of the already completed analyses.
    try std.testing.expect(costs[1] <= costs[0] * 16);
}

test "internal operation resumption values remain first-order" {
    var program = example;
    program.schemas = &.{ .u64, .{ .internal = .{ .capability = 0 } } };
    program.effects = &.{.{
        .identity = "internal-result",
        .payload = 0,
        .result = 1,
        .external = false,
    }};
    try std.testing.expectError(error.InvalidEffect, admit(std.testing.allocator, program));
    program.effects = &.{.{
        .identity = "internal-result",
        .payload = 1,
        .result = 0,
        .external = false,
    }};
    try admit(std.testing.allocator, program);
}

test "productive recursive schemas and zero-width sequences have finite validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const catalog: []const p.Schema = &.{
        .unit,
        .{ .sum = &.{ 0, 2 } },
        .{ .product = &.{ 0, 1 } },
        .{ .seq = 0 },
    };
    const facts = try admission.schemas(arena.allocator(), catalog);
    try admission.value(
        arena.allocator(),
        catalog,
        facts,
        .{ .schema = 1, .bytes = &.{ 1, 1, 0 } },
    );
    try admission.value(
        arena.allocator(),
        catalog,
        facts,
        .{ .schema = 3, .bytes = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 } },
    );
    try std.testing.expectError(
        error.InvalidSchema,
        admission.schemas(arena.allocator(), &.{.{ .product = &.{0} }}),
    );
}

test "fixed arrays and bounded byte domains retain their exact external contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const types: []const p.Schema = &.{
        .u8,
        .{ .array = .{ .element = 0, .length = 2 } },
        .{ .bounded_bytes = 2 },
        .{ .bounded_text = 2 },
        .unit,
        .{ .array = .{ .element = 4, .length = std.math.maxInt(u64) } },
    };
    const facts = try admission.schemas(allocator, types);
    try admission.value(allocator, types, facts, .{ .schema = 1, .bytes = &.{ 4, 5 } });
    try std.testing.expectError(
        error.InvalidValue,
        admission.value(allocator, types, facts, .{ .schema = 1, .bytes = &.{4} }),
    );
    try std.testing.expectError(
        error.NonCanonical,
        admission.value(allocator, types, facts, .{ .schema = 1, .bytes = &.{ 4, 5, 6 } }),
    );
    try admission.value(allocator, types, facts, .{ .schema = 2, .bytes = &.{ 2, 0xff, 0 } });
    try admission.value(allocator, types, facts, .{ .schema = 3, .bytes = &.{ 2, 0xc3, 0xa9 } });
    try std.testing.expectError(
        error.InvalidValue,
        admission.value(allocator, types, facts, .{ .schema = 2, .bytes = &.{ 3, 1, 2, 3 } }),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        admission.value(allocator, types, facts, .{ .schema = 3, .bytes = &.{ 1, 0xff } }),
    );
    try admission.value(allocator, types, facts, .{ .schema = 5, .bytes = &.{} });
}

test "finite and empty enumerations reject every undeclared value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const types: []const p.Schema = &.{ .{ .enumeration = &.{ 2, 7 } }, .{ .enumeration = &.{} } };
    const facts = try admission.schemas(allocator, types);
    try admission.value(allocator, types, facts, .{ .schema = 0, .bytes = &.{ 7, 0, 0, 0 } });
    try std.testing.expectError(
        error.InvalidValue,
        admission.value(allocator, types, facts, .{ .schema = 0, .bytes = &.{ 5, 0, 0, 0 } }),
    );
    try std.testing.expectError(
        error.InvalidValue,
        admission.value(allocator, types, facts, .{ .schema = 1, .bytes = &.{ 0, 0, 0, 0 } }),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        admission.schemas(allocator, &.{.{ .enumeration = &.{ 7, 2 } }}),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        admission.schemas(allocator, &.{.{ .enumeration = &.{ 2, 2 } }}),
    );
}
