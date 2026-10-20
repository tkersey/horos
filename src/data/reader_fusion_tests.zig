const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const fusion = @import("reader_fusion.zig");
const a = std.testing.allocator;
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try fusion.run(allocator, readers, null, .{});
    defer result.deinit();
}
pub const readers: ir.Program = .{
    .roots = .{ .entry = 0, .result = 2, .failure = 1 },
    .schemas = &.{
        .boolean,                              .unit,
        .{ .product = &.{ 0, 0 } },            .{ .internal = .{ .capability = 0 } },
        .{ .internal = .{ .capability = 1 } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{3},
            .result = 2,
            .effects = &.{0},
            .capture_bound = &.{0},
        } } },
        .{ .internal = .{ .computation = .{
            .parameters = &.{4},
            .result = 2,
            .effects = &.{ 0, 1 },
            .capture_bound = &.{ 0, 3 },
        } } },
        .{ .internal = .{ .resumption = .{
            .effect = 0,
            .input = 0,
            .answer = 2,
            .handled = &.{0},
            .capture_bound = &.{ 0, 1, 2, 3, 4 },
            .mode = .deep,
            .use = .linear,
        } } },
        .{ .internal = .{ .resumption = .{
            .effect = 1,
            .input = 0,
            .answer = 2,
            .effects = &.{0},
            .handled = &.{1},
            .capture_bound = &.{ 0, 1, 2, 3, 4 },
            .mode = .deep,
            .use = .linear,
        } } },
    },
    .constants = &.{.{ .schema = 1, .bytes = &.{} }},
    .effects = &.{
        .{ .identity = "reader.left", .payload = 1, .result = 0, .external = false },
        .{ .identity = "reader.right", .payload = 1, .result = 0, .external = false },
    },
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 5, 2 } },
            .result = 2,
        },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 0, 0, 0, 3, 6, 2 } },
            .result = 2,
            .effects = &.{0},
        },
        .{
            .entry = 4,
            .inputs = &.{ 0, 1, 2, 3 },
            .layout = .{ .slots = &.{ 3, 0, 0, 4, 1, 0, 0, 2 } },
            .result = 2,
            .effects = &.{ 0, 1 },
        },
        .{ .entry = 11, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 2 } }, .result = 2 },
        .{ .entry = 12, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 1 } }, .result = 0 },
        .{ .entry = 13, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 1 } }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .computation,
                .operands = &.{ 1, 2, 3 },
                .immediate = 0,
            }},
            .terminator = .{ .handle = .{
                .handler = 0,
                .body = 4,
                .arguments = &.{},
                .state = &.{0},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 5 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 4,
                .opcode = .computation,
                .operands = &.{ 3, 1, 2 },
                .immediate = 1,
            }},
            .terminator = .{ .handle = .{
                .handler = 1,
                .body = 4,
                .arguments = &.{},
                .state = &.{0},
                .next = .{
                    .block = 3,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 5 } },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 4, .opcode = .constant }},
            .terminator = .{ .branch = .{
                .condition = 1,
                .when_true = .{ .block = 5 },
                .when_false = .{ .block = 6 },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .perform = .{
                .effect = 0,
                .capability = 0,
                .payload = 4,
                .next = .{
                    .block = 7,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .perform = .{
                .effect = 1,
                .capability = 3,
                .payload = 4,
                .next = .{
                    .block = 7,
                    .assignments = &.{.{ .destination = 5, .source = .returned }},
                },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 2,
                .when_true = .{ .block = 8 },
                .when_false = .{ .block = 9 },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .perform = .{
                .effect = 0,
                .capability = 0,
                .payload = 4,
                .next = .{
                    .block = 10,
                    .assignments = &.{.{ .destination = 6, .source = .returned }},
                },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{},
            .terminator = .{ .perform = .{
                .effect = 1,
                .capability = 3,
                .payload = 4,
                .next = .{
                    .block = 10,
                    .assignments = &.{.{ .destination = 6, .source = .returned }},
                },
            } },
        },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 7, .opcode = .product, .operands = &.{ 5, 6 } }},
            .terminator = .{ .return_value = 7 },
        },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    },
    .handlers = &.{
        .{
            .mode = .deep,
            .input = 2,
            .answer = 2,
            .return_function = 3,
            .state = &.{0},
            .clauses = &.{.{ .effect = 0, .function = 4, .resumption = 7, .strategy = .tail }},
        },
        .{
            .mode = .deep,
            .input = 2,
            .answer = 2,
            .return_function = 3,
            .state = &.{0},
            .effects = &.{0},
            .clauses = &.{.{ .effect = 1, .function = 5, .resumption = 8, .strategy = .tail }},
        },
    },
    .constructors = &.{
        .{ .function = 1, .capture = 0, .schema = 5 },
        .{ .function = 2, .capture = 1, .schema = 6 },
    },
    .scopes = .{ .captures = &.{
        .{ .fields = &.{ 0, 0, 0 }, .use = .reusable },
        .{ .fields = &.{ 3, 0, 0 }, .use = .reusable },
    } },
};
test "Reader law is recognized from admitted records and actual capability bindings" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var admitted = try @import("activation_ownership.zig").analyze(a, readers);
    admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const permissions = try @import("traits.zig").derive(scratch, readers.schemas);
    const schemas = try @import("admission.zig").schemas(scratch, readers.schemas);
    const shape = (try fusion.recognize(
        scratch,
        readers,
        0,
        permissions,
        schemas.exportable,
        1_000_000,
    )).?;
    try std.testing.expectEqual(@as(p.Id, 0), shape.outer_handler);
    try std.testing.expectEqual(@as(p.Id, 1), shape.inner_handler);
    try std.testing.expectEqual(@as(p.Id, 1), shape.inner_state_at_caller);
    try std.testing.expectError(
        error.ReaderFusionLimit,
        fusion.recognize(scratch, readers, 0, permissions, schemas.exportable, 0),
    );
    var candidate = (try fusion.construct(a, readers, .{})).?;
    defer candidate.deinit();
    admitted = try @import("activation_ownership.zig").analyze(a, candidate.program);
    admitted.deinit();
    try fusion.validate(a, readers, candidate.program, 0, .{});
    const combined = candidate.program.handlers[candidate.program.handlers.len - 1];
    try std.testing.expectEqualSlices(p.Id, &.{ 0, 0 }, combined.state);
    try std.testing.expectEqual(@as(p.Id, 0), combined.clauses[0].effect);
    try std.testing.expectEqual(@as(p.Id, 1), combined.clauses[1].effect);
    try std.testing.expect(
        candidate.program.blocks[
            @intCast(readers.functions[1].entry)
        ].terminator == .handle,
    );
    try std.testing.expect(candidate.program.blocks[readers.blocks.len].terminator == .call);
    const fused_body = candidate.program.functions[readers.functions.len];
    try std.testing.expectEqual(readers.functions[1].layout.slots.len, fused_body.layout.slots.len);
    try std.testing.expectEqual(@as(p.Id, 4), fused_body.inputs[4]);
    try std.testing.expectEqual(@as(p.Id, 4), fused_body.layout.slots[4]);
    try rejectReaderReordering(scratch, candidate.program);
    var stats: fusion.Statistics = .{};
    var selected = try fusion.run(a, readers, &stats, .{});
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.pairs_fused);
    try std.testing.expectEqual(@as(usize, 1), selected.program.handlers.len);
    try std.testing.expectEqual(@as(usize, 2), selected.program.handlers[0].clauses.len);
    var limited = try fusion.run(a, readers, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(@as(usize, 2), limited.program.handlers.len);
    var invalid = readers;
    invalid.roots.entry = 999;
    try std.testing.expectError(
        error.InvalidReference,
        fusion.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}

fn rejectReaderReordering(scratch: std.mem.Allocator, program: ir.Program) !void {
    var reordered = program;
    const changed = try scratch.dupe(ir.Block, program.blocks);
    changed[0].terminator.handle.state = &.{ 1, 0 };
    reordered.blocks = changed;
    var admitted = try @import("activation_ownership.zig").analyze(a, reordered);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidReaderFusion,
        fusion.validate(a, readers, reordered, 0, .{}),
    );
    @memcpy(changed, program.blocks);
    const entry = readers.blocks.len;
    const arguments = program.blocks[entry].terminator.call.arguments;
    const swapped_arguments = [_]p.Id{ arguments[0], arguments[2], arguments[1], arguments[3] };
    changed[entry].terminator.call.arguments = &swapped_arguments;
    admitted = try @import("activation_ownership.zig").analyze(a, reordered);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidReaderFusion,
        fusion.validate(a, readers, reordered, 0, .{}),
    );
    @memcpy(changed, program.blocks);
    const first_clause = program.handlers[program.handlers.len - 1].clauses[0];
    changed[
        @intCast(program.functions[
            @intCast(first_clause.function)
        ].entry)
    ].terminator = .{ .return_value = 1 };
    admitted = try @import("activation_ownership.zig").analyze(a, reordered);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidReaderFusion,
        fusion.validate(a, readers, reordered, 0, .{}),
    );
}

test "Reader fusion separates canonical rows from positional handled evidence" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var reversed = readers;
    const schemas = try scratch.dupe(p.Schema, readers.schemas);
    schemas[3].internal.capability = 1;
    schemas[4].internal.capability = 0;
    schemas[5].internal.computation.effects = &.{1};
    schemas[7].internal.resumption.effect = 1;
    schemas[7].internal.resumption.handled = &.{1};
    schemas[8].internal.resumption.effect = 0;
    schemas[8].internal.resumption.handled = &.{0};
    schemas[8].internal.resumption.effects = &.{1};
    const functions = try scratch.dupe(ir.Function, readers.functions);
    functions[1].effects = &.{1};
    const blocks = try scratch.dupe(ir.Block, readers.blocks);
    for ([_]usize{
        5,
        6,
        8,
        9,
    }) |id| blocks[id].terminator.perform.effect = 1 - blocks[id].terminator.perform.effect;
    const handlers = try scratch.dupe(ir.Handler, readers.handlers);
    handlers[0].clauses = &.{.{ .effect = 1, .function = 4, .resumption = 7, .strategy = .tail }};
    handlers[1].clauses = &.{.{ .effect = 0, .function = 5, .resumption = 8, .strategy = .tail }};
    handlers[1].effects = &.{1};
    reversed.schemas = schemas;
    reversed.functions = functions;
    reversed.blocks = blocks;
    reversed.handlers = handlers;
    reversed.effects = &.{ readers.effects[1], readers.effects[0] };
    for ([_]ir.Program{ readers, reversed }) |original| {
        try checkCanonicalReaderRows(scratch, original);
    }
}

fn checkCanonicalReaderRows(scratch: std.mem.Allocator, original: ir.Program) !void {
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    admitted.deinit();
    var candidate = (try fusion.construct(a, original, .{})).?;
    defer candidate.deinit();
    try fusion.validate(a, original, candidate.program, candidate.shape.site, .{});
    const handled = [_]p.Id{
        original.handlers[0].clauses[0].effect,
        original.handlers[1].clauses[0].effect,
    };
    try std.testing.expectEqualSlices(
        p.Id,
        &.{ 0, 1 },
        candidate.program.functions[original.functions.len].effects,
    );
    try std.testing.expectEqualSlices(
        p.Id,
        &.{ 0, 1 },
        candidate.program.schemas[original.schemas.len + 2].internal.computation.effects,
    );
    for (candidate.program.schemas[original.schemas.len..][0..2]) |schema| {
        try std.testing.expectEqualSlices(p.Id, &handled, schema.internal.resumption.handled);
    }
    var stats: fusion.Statistics = .{};
    var fused = try fusion.run(a, original, &stats, .{});
    defer fused.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.pairs_fused);
    var compiled = try @import("closed_compilation.zig").run(
        a,
        original,
        .{ .contract = .semantic },
    );
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 1), compiled.program.handlers.len);

    var wrong = candidate.program;
    const changed = try scratch.dupe(p.Schema, candidate.program.schemas);
    wrong.schemas = changed;
    changed[original.schemas.len].internal.resumption.handled = &.{ handled[1], handled[0] };
    try std.testing.expectError(
        error.InvalidEffect,
        fusion.validate(a, original, wrong, candidate.shape.site, .{}),
    );
    @memcpy(changed, candidate.program.schemas);
    changed[original.schemas.len + 2].internal.computation.effects = &.{ 1, 0 };
    try std.testing.expectError(
        error.NonCanonical,
        fusion.validate(a, original, wrong, candidate.shape.site, .{}),
    );
}

test "overlapping Reader effects are admitted but cannot use the disjoint law" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var overlapping = readers;
    const schemas = try scratch.dupe(p.Schema, readers.schemas);
    schemas[4].internal.capability = 0;
    schemas[6].internal.computation.effects = &.{0};
    schemas[8].internal.resumption.effect = 0;
    schemas[8].internal.resumption.handled = &.{0};
    const handlers = try scratch.dupe(ir.Handler, readers.handlers);
    handlers[1].clauses = &.{.{ .effect = 0, .function = 5, .resumption = 8, .strategy = .tail }};
    const functions = try scratch.dupe(ir.Function, readers.functions);
    functions[2].effects = &.{0};
    const blocks = try scratch.dupe(ir.Block, readers.blocks);
    blocks[6].terminator.perform.effect = 0;
    blocks[9].terminator.perform.effect = 0;
    overlapping.schemas = schemas;
    overlapping.functions = functions;
    overlapping.blocks = blocks;
    overlapping.handlers = handlers;
    var admitted = try @import("activation_ownership.zig").analyze(a, overlapping);
    admitted.deinit();
    var candidate = try fusion.construct(a, overlapping, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}

test "capability returned across the inner boundary blocks Reader fusion" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var escaping = readers;
    const schemas = try scratch.alloc(p.Schema, readers.schemas.len + 1);
    @memcpy(schemas[0..readers.schemas.len], readers.schemas);
    schemas[9] = .{ .product = &.{ 3, 2 } };
    schemas[6].internal.computation.result = 9;
    const functions = try scratch.alloc(ir.Function, readers.functions.len + 1);
    @memcpy(functions[0..readers.functions.len], readers.functions);
    functions[2].result = 9;
    functions[2].layout.slots = &.{ 3, 0, 0, 4, 1, 0, 0, 2, 9 };
    functions[6] = .{
        .entry = 14,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 9, 2 } },
        .result = 2,
    };
    const blocks = try scratch.alloc(ir.Block, readers.blocks.len + 1);
    @memcpy(blocks[0..readers.blocks.len], readers.blocks);
    blocks[10].instructions = &.{
        .{ .destination = 7, .opcode = .product, .operands = &.{ 5, 6 } },
        .{ .destination = 8, .opcode = .product, .operands = &.{ 0, 7 } },
    };
    blocks[10].terminator = .{ .return_value = 8 };
    blocks[14] = .{
        .function = 6,
        .instructions = &.{.{
            .destination = 2,
            .opcode = .field,
            .operands = &.{1},
            .immediate = 1,
        }},
        .terminator = .{ .return_value = 2 },
    };
    const handlers = try scratch.dupe(ir.Handler, readers.handlers);
    handlers[1].input = 9;
    handlers[1].return_function = 6;
    escaping.schemas = schemas;
    escaping.functions = functions;
    escaping.blocks = blocks;
    escaping.handlers = handlers;
    var admitted = try @import("activation_ownership.zig").analyze(a, escaping);
    admitted.deinit();
    var candidate = try fusion.construct(a, escaping, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}

test "non-reader operation action is not inferred from the effect name" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var changed = readers;
    const functions = try scratch.dupe(ir.Function, readers.functions);
    functions[4].layout.slots = &.{ 0, 1, 0 };
    const blocks = try scratch.dupe(ir.Block, readers.blocks);
    blocks[12].instructions = &.{.{ .destination = 2, .opcode = .boolean_not, .operands = &.{0} }};
    blocks[12].terminator = .{ .return_value = 2 };
    changed.functions = functions;
    changed.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, changed);
    admitted.deinit();
    var candidate = try fusion.construct(a, changed, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
}
