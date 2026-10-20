// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const flow = @import("activation_flow.zig");
const testing = std.testing;

fn program(
    blocks: []const ir.Block,
    layout: []const p.Id,
    inputs: []const p.Id,
    function: *ir.Function,
) ir.Program {
    function.* = .{
        .entry = 0,
        .inputs = inputs,
        .layout = .{ .slots = layout },
        .result = 0,
    };
    return .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit, .boolean, .{ .internal = .{ .resumption = .{
            .effect = 0,
            .input = 0,
            .answer = 0,
            .handled = &.{0},
            .mode = .deep,
            .use = .linear,
        } } } },
        .effects = &.{.{ .identity = "read", .payload = 1, .result = 0 }},
        .constants = &.{.{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } }},
        .functions = function[0..1],
        .blocks = blocks,
    };
}

test "activation flow rejects an uninitialized read and a partially initialized join" {
    var definition: ir.Function = undefined;
    const empty = [_]ir.Block{.{
        .function = 0,
        .instructions = &.{},
        .terminator = .{ .return_value = 0 },
    }};
    try testing.expectError(
        error.UnavailableSlot,
        flow.analyze(testing.allocator, program(&empty, &.{0}, &.{}, &definition)),
    );
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{
            .condition = 0,
            .when_true = .{ .block = 1 },
            .when_false = .{ .block = 2 },
        } } },
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .constant, .destination = 1 }},
            .terminator = .{ .jump = .{ .block = 2 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    };
    try testing.expectError(
        error.UnavailableSlot,
        flow.analyze(testing.allocator, program(&blocks, &.{ 2, 0 }, &.{0}, &definition)),
    );
}

test "activation flow keeps initialization distinct from consumed ownership" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{.{
            .opcode = .move,
            .destination = 1,
            .operands = &.{0},
        }}, .terminator = .{ .yield_value = .{ .block = 1 } } },
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .constant, .destination = 2 }},
            .terminator = .{ .return_value = 2 },
        },
    };
    var facts = try flow.analyze(
        testing.allocator,
        program(&blocks, &.{ 3, 3, 0 }, &.{0}, &definition),
    );
    defer facts.deinit();
    const entry = facts.entries[1].?;
    try testing.expect(facts.pool.contains(entry.initialized, 0));
    try testing.expect(!facts.pool.contains(entry.available, 0));
    try testing.expect(facts.pool.contains(entry.available, 1));
    try testing.expect(!facts.pool.contains(facts.live[0][1], 0));
    try testing.expect(facts.pool.contains(facts.live[0][1], 1));
}

test "activation flow rejects duplicate uses of an owner across and within blocks" {
    var definition: ir.Function = undefined;
    var operations = [_]ir.Instruction{
        .{ .opcode = .move, .destination = 1, .operands = &.{0} },
        .{ .opcode = .move, .destination = 2, .operands = &.{0} },
    };
    var blocks = [_]ir.Block{
        .{
            .function = 0,
            .instructions = &operations,
            .terminator = .{ .yield_value = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .constant, .destination = 3 }},
            .terminator = .{ .return_value = 3 },
        },
    };
    const image = program(&blocks, &.{ 3, 3, 3, 0 }, &.{0}, &definition);
    try testing.expectError(error.UnavailableSlot, flow.analyze(testing.allocator, image));
    blocks[0].instructions = operations[0..1];
    blocks[1].instructions = operations[1..];
    // Supply the ordinary result separately so the rejection identifies reuse.
    var functions = [_]ir.Function{image.functions[0]};
    functions[0].inputs = &.{ 0, 3 };
    var across = image;
    across.functions = &functions;
    try testing.expectError(error.UnavailableSlot, flow.analyze(testing.allocator, across));
}

test "activation flow admits simultaneous owned permutations and rejects duplication" {
    var definition: ir.Function = undefined;
    var assignments = [_]ir.Assignment{
        .{ .destination = 0, .source = .{ .slot = 1 } },
        .{ .destination = 1, .source = .{ .slot = 0 } },
    };
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{
            .block = 1,
            .assignments = &assignments,
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    };
    const image = program(&blocks, &.{ 3, 3, 0 }, &.{ 0, 1, 2 }, &definition);
    var facts = try flow.analyze(testing.allocator, image);
    defer facts.deinit();
    try testing.expect(facts.pool.contains(facts.entries[1].?.available, 0));
    try testing.expect(facts.pool.contains(facts.entries[1].?.available, 1));
    assignments[1].source = .{ .slot = 1 };
    try testing.expectError(error.UnavailableSlot, flow.analyze(testing.allocator, image));
}

test "activation flow rejects overwriting a live non-droppable owner" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{.{
        .function = 0,
        .instructions = &.{.{ .opcode = .move, .destination = 0, .operands = &.{1} }},
        .terminator = .{ .return_value = 2 },
    }};
    try testing.expectError(
        error.OverwrittenOwner,
        flow.analyze(
            testing.allocator,
            program(&blocks, &.{ 3, 3, 0 }, &.{ 0, 1, 2 }, &definition),
        ),
    );
}

test "activation flow reaches a loop fixed point before checking reads" {
    var definition: ir.Function = undefined;
    var body = [_]ir.Instruction{.{ .opcode = .move, .destination = 2, .operands = &.{1} }};
    var blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 1 } } },
        .{ .function = 0, .instructions = &body, .terminator = .{ .branch = .{
            .condition = 0,
            .when_true = .{ .block = 1 },
            .when_false = .{ .block = 2 },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
    };
    const image = program(&blocks, &.{ 2, 3, 3, 0 }, &.{ 0, 1, 3 }, &definition);
    try testing.expectError(error.UnavailableSlot, flow.analyze(testing.allocator, image));
    // Moving into the loop input before the backedge restores that owner.
    blocks[1].terminator.branch.when_true.assignments = &.{.{
        .destination = 1,
        .source = .{ .slot = 2 },
    }};
    // The exit branch retains slot 2; no unmodeled native loop state is used.
    var facts = try flow.analyze(testing.allocator, image);
    defer facts.deinit();
    try testing.expect(facts.pool.contains(facts.entries[1].?.available, 1));
    try testing.expect(facts.block_visits <= 6);
}

test "activation flow distinguishes unreachable continuation from initialized entry" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .fail = 0 } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    };
    const image = program(&blocks, &.{ 1, 0 }, &.{0}, &definition);
    var facts = try flow.analyze(testing.allocator, image);
    defer facts.deinit();
    try testing.expect(facts.entries[1] == null);
    var functions = [_]ir.Function{image.functions[0]};
    functions[0].entry = 1;
    var changed = image;
    changed.functions = &functions;
    try testing.expectError(error.UnavailableSlot, flow.analyze(testing.allocator, changed));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .constant, .destination = 0 }},
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var facts = try flow.analyze(allocator, program(&blocks, &.{0}, &.{}, &definition));
    defer facts.deinit();
    try testing.expect(facts.pool.contains(facts.entries[1].?.initialized, 0));
}

test "activation flow owns all analysis storage and frees partial owners on failure" {
    try @import("allocation_testing.zig").check(testing.allocator, allocationCase, .{});
}

fn cyclicParentsCase(allocator: std.mem.Allocator) !void {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{
            .condition = 0,
            .when_true = .{ .block = 1 },
            .when_false = .{ .block = 1 },
        } } },
        .{ .function = 0, .instructions = &.{.{
            .opcode = .move,
            .destination = 2,
            .operands = &.{1},
        }}, .terminator = .{ .branch = .{
            .condition = 0,
            .when_true = .{ .block = 1 },
            .when_false = .{ .block = 2 },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    };
    var facts = try flow.analyze(
        allocator,
        program(&blocks, &.{ 2, 0, 0 }, &.{ 0, 1 }, &definition),
    );
    defer facts.deinit();
    for (0..2) |block| {
        try testing.expect(facts.pool.contains(facts.live[block][0], 0));
        try testing.expect(facts.pool.contains(facts.live[block][0], 1));
        try testing.expect(!facts.pool.contains(facts.live[block][0], 2));
    }
    try testing.expect(facts.pool.contains(facts.entries[2].?.initialized, 2));
    try testing.expectEqual(1, facts.pool.count(facts.live[2][0]));
    try testing.expect(facts.pool.contains(facts.live[2][0], 2));
}

test "duplicate and cyclic predecessors preserve liveness and release partial scratch" {
    try @import("allocation_testing.zig").check(testing.allocator, cyclicParentsCase, .{});
}

test "activation liveness drops irrelevant data but retains required disposition" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 1 } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
    };
    const ordinary = program(&blocks, &.{ 0, 0 }, &.{ 0, 1 }, &definition);
    var dead = try flow.analyze(testing.allocator, ordinary);
    defer dead.deinit();
    try testing.expect(dead.pool.contains(dead.entries[1].?.initialized, 0));
    try testing.expect(!dead.pool.contains(dead.live[1][0], 0));
    try testing.expect(dead.pool.contains(dead.live[1][0], 1));
    const owned = program(&blocks, &.{ 3, 0 }, &.{ 0, 1 }, &definition);
    var retained = try flow.analyze(testing.allocator, owned);
    defer retained.deinit();
    try testing.expect(retained.pool.contains(retained.live[1][0], 0));
}

test "activation liveness reverses simultaneous assignments from the successor view" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{
            .block = 1,
            .assignments = &.{
                .{ .destination = 0, .source = .{ .slot = 1 } },
                .{ .destination = 1, .source = .{ .slot = 0 } },
            },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var facts = try flow.analyze(
        testing.allocator,
        program(&blocks, &.{ 0, 0 }, &.{ 0, 1 }, &definition),
    );
    defer facts.deinit();
    try testing.expect(facts.pool.contains(facts.live[0][0], 1));
    try testing.expect(!facts.pool.contains(facts.live[0][0], 0));
    try testing.expect(facts.pool.contains(facts.live[1][0], 0));
    try testing.expect(!facts.pool.contains(facts.live[1][0], 1));
}

test "activation flow rejects multiplying a unique returned value" {
    const functions = [_]ir.Function{
        .{
            .entry = 0,
            .inputs = &.{ 0, 3 },
            .layout = .{ .slots = &.{ 3, 3, 3, 0 } },
            .result = 0,
        },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{3} }, .result = 3 },
    };
    var blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{0},
            .next = .{
                .block = 1,
                .assignments = &.{
                    .{ .destination = 1, .source = .returned },
                    .{ .destination = 2, .source = .returned },
                },
            },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    var definition: ir.Function = undefined;
    var image = program(&blocks, &.{}, &.{}, &definition);
    image.functions = &functions;
    try testing.expectError(error.InvalidOwnership, flow.analyze(testing.allocator, image));
    blocks[0].terminator.call.next.assignments = &.{.{ .destination = 1, .source = .returned }};
    var facts = try flow.analyze(testing.allocator, image);
    defer facts.deinit();
}

test "activation flow keeps conditional cleanup custody without granting a read" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{
            .condition = 0,
            .when_true = .{ .block = 1 },
            .when_false = .{ .block = 2 },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .dispose = .{
            .owned = 1,
            .next = .{ .block = 2 },
        } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .fail = 2 } },
    };
    var facts = try flow.analyze(
        testing.allocator,
        program(&blocks, &.{ 2, 3, 1 }, &.{ 0, 1, 2 }, &definition),
    );
    defer facts.deinit();
    const entry = facts.entries[2].?;
    try testing.expect(!facts.pool.contains(entry.available, 1));
    try testing.expect(facts.pool.contains(entry.obligations, 1));
    try testing.expect(facts.pool.contains(facts.live[2][0], 1));
}

test "activation flow keeps its allocator alive for later derived-set allocations" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{.{
        .function = 0,
        .instructions = &.{},
        .terminator = .{ .return_value = 0 },
    }};
    var facts = try flow.analyze(
        testing.allocator,
        program(&blocks, &(@as([257]p.Id, @splat(0))), &.{0}, &definition),
    );
    defer facts.deinit();
    var root = facts.entries[0].?.initialized;
    for (1..257) |slot| root = try facts.pool.insert(root, slot);
    try testing.expectEqual(257, facts.pool.count(root));
    try testing.expectEqual(1, facts.pool.count(facts.entries[0].?.initialized));
}

test "liveness refreshes internal positions when a successor changes but entry does not" {
    var definition: ir.Function = undefined;
    const blocks = [_]ir.Block{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .move, .destination = 1, .operands = &.{0} }},
            .terminator = .{ .jump = .{ .block = 0 } },
        },
    };
    const image = program(&blocks, &.{ 0, 0 }, &.{0}, &definition);
    definition.entry = 1;
    var facts = try flow.analyze(testing.allocator, image);
    defer facts.deinit();
    // Reverse declaration order processes block 1 before its successor. The
    // successor later adds slot 1, which is killed by the move at block entry.
    try testing.expect(facts.pool.contains(facts.live[1][0], 0));
    try testing.expect(!facts.pool.contains(facts.live[1][0], 1));
    try testing.expect(facts.pool.contains(facts.live[1][1], 1));
    try testing.expect(!facts.pool.contains(facts.live[1][1], 0));
    try testing.expect(facts.pool.contains(facts.live[0][0], 1));
}
