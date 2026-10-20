// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const compression = @import("context_compression.zig");
const own = @import("activation_ownership.zig");
const a = std.testing.allocator;
pub const xor_chain: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                              .unit,
        .{ .vector = .{ .element = 0, .maximum = 4096 } }, .{ .product = &.{ 0, 2 } },
        .{ .sum = &.{ 1, 3 } },
    },
    .constants = &.{.{ .schema = 1, .bytes = &.{} }},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 2, 0, 0 } }, .result = 0 },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 2, 0, 4, 3, 0, 2, 0, 0 } },
            .result = 0,
        },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{ 0, 1 },
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 2, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 2, .opcode = .sequence_pop, .operands = &.{0} }},
            .terminator = .{ .switch_variant = .{
                .value = 2,
                .cases = &.{ .{ .block = 3 }, .{ .block = 4 } },
            } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{ .function = 1, .instructions = &.{
            .{
                .destination = 3,
                .opcode = .variant_payload,
                .operands = &.{2},
                .immediate = 1,
                .failures = &.{.{ .kind = .invalid_variant, .value = 0 }},
            },
            .{ .destination = 4, .opcode = .field, .operands = &.{3}, .immediate = 0 },
            .{ .destination = 5, .opcode = .field, .operands = &.{3}, .immediate = 1 },
        }, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{ 5, 1 },
            .next = .{ .block = 5, .assignments = &.{.{ .destination = 6, .source = .returned }} },
        } } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 7,
                .opcode = .integer_bit_xor,
                .operands = &.{ 4, 6 },
            }},
            .terminator = .{ .return_value = 7 },
        },
    },
};
pub fn booleanChain(allocator: std.mem.Allocator) !ir.Program {
    var program = xor_chain;
    program.schemas = &.{
        .boolean,                                          .unit,
        .{ .vector = .{ .element = 5, .maximum = 4096 } }, .{ .product = &.{ 5, 2 } },
        .{ .sum = &.{ 1, 3 } },                            .{ .product = &.{ 0, 0 } },
    };
    const functions = try allocator.dupe(ir.Function, program.functions);
    functions[1].layout.slots = &.{ 2, 0, 4, 3, 5, 2, 0, 0, 0, 0 };
    program.functions = functions;
    const blocks = try allocator.dupe(ir.Block, program.blocks);
    blocks[5].instructions = &.{
        .{ .destination = 8, .opcode = .field, .operands = &.{4}, .immediate = 0 },
        .{ .destination = 9, .opcode = .field, .operands = &.{4}, .immediate = 1 },
        .{ .destination = 7, .opcode = .select, .operands = &.{ 6, 9, 8 } },
    };
    program.blocks = blocks;
    return program;
}
test "XOR and Boolean return contexts become admitted summary loops" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]ir.Program{ xor_chain, try booleanChain(arena.allocator()) }) |original| {
        var admitted = try own.analyze(a, original);
        admitted.deinit();
        var candidate = (try compression.construct(a, original, .{})).?;
        defer candidate.deinit();
        try compression.validate(a, original, candidate.program, candidate.sites, .{});
        var stats: compression.Statistics = .{};
        var result = try compression.run(a, original, &stats, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), stats.contexts_compressed);
        for (result.program.blocks) |block| if (block.terminator == .call) try std.testing.expect(
            block.terminator.call.function != block.function,
        );
    }
}
test "independently admitted wrong identity and reversed Boolean composition are rejected" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try booleanChain(arena.allocator());
    var candidate = (try compression.construct(a, original, .{})).?;
    defer candidate.deinit();
    const constants = try arena.allocator().dupe(p.Literal, candidate.program.constants);
    constants[constants.len - 1].bytes = &.{0};
    var forged = candidate.program;
    forged.constants = constants;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidContextCompression,
        compression.validate(a, original, forged, candidate.sites, .{}),
    );
    forged = candidate.program;
    const blocks = try arena.allocator().dupe(ir.Block, candidate.program.blocks);
    const ops = try arena.allocator().dupe(ir.Instruction, blocks[4].instructions);
    // Reverse composition using independently admitted scalar temporaries.
    ops[5] = .{ .destination = 6, .opcode = .select, .operands = &.{ 6, 9, 8 } };
    ops[6] = .{ .destination = 7, .opcode = .select, .operands = &.{ 7, 9, 8 } };
    const transfers = try arena.allocator().dupe(
        ir.Assignment,
        blocks[4].terminator.jump.assignments,
    );
    transfers[1].source = .{ .slot = 6 };
    transfers[2].source = .{ .slot = 7 };
    blocks[4].terminator.jump.assignments = transfers;
    blocks[4].instructions = ops;
    forged.blocks = blocks;
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidContextCompression,
        compression.validate(a, original, forged, candidate.sites, .{}),
    );
}
test "admitted swapped scalar-summary transfers fail the independent checker" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try booleanChain(arena.allocator());
    var candidate = (try compression.construct(a, original, .{})).?;
    defer candidate.deinit();
    const blocks = try arena.allocator().dupe(ir.Block, candidate.program.blocks);
    const assignments = try arena.allocator().dupe(
        ir.Assignment,
        blocks[4].terminator.jump.assignments,
    );
    const first = assignments[1].source;
    assignments[1].source = assignments[2].source;
    assignments[2].source = first;
    blocks[4].terminator.jump.assignments = assignments;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidContextCompression,
        compression.validate(a, original, forged, candidate.sites, .{}),
    );
}
test "checked arithmetic and an escaping context worker are retained" {
    var original = xor_chain;
    var blocks = xor_chain.blocks[0..6].*;
    blocks[5].instructions = &.{.{
        .destination = 7,
        .opcode = .integer_add,
        .operands = &.{ 4, 6 },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
    }};
    original.blocks = &blocks;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try compression.construct(a, original, .{}) == null);
    original = xor_chain;
    original.schemas = &.{
        xor_chain.schemas[0],
        xor_chain.schemas[1],
        xor_chain.schemas[2],
        xor_chain.schemas[3],
        xor_chain.schemas[4],
        .{ .internal = .{ .computation = .{
            .parameters = &.{ 2, 0 },
            .result = 0,
            .use = .reusable,
        } } },
    };
    original.scopes.captures = &.{.{ .fields = &.{}, .use = .reusable }};
    original.constructors = &.{.{ .function = 1, .capture = 0, .schema = 5 }};
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try compression.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try compression.run(allocator, xor_chain, null, .{});
    defer result.deinit();
}
fn booleanAllocationAttempt(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const original = try booleanChain(arena.allocator());
    var result = try compression.run(allocator, original, null, .{});
    defer result.deinit();
}
test "Boolean scalar summary cleans up every allocation failure" {
    try @import("allocation_testing.zig").check(a, booleanAllocationAttempt, .{});
}
test "context construction cleans allocation failures, bounds work and rejects invalid originals" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var baseline = try @import("coalescing.zig").run(a, xor_chain, .{});
    defer baseline.deinit();
    var stats: compression.Statistics = .{};
    var limited = try compression.run(a, xor_chain, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
    var invalid = xor_chain;
    invalid.roots.entry = 100;
    try std.testing.expectError(
        error.InvalidReference,
        compression.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}

test "an intermediate user yield and failing mask evaluation retain their contexts" {
    var original = xor_chain;
    var yielding: [7]ir.Block = undefined;
    @memcpy(yielding[0..6], xor_chain.blocks);
    yielding[4].terminator.call.next.block = 6;
    yielding[6] = .{
        .function = 1,
        .instructions = &.{},
        .terminator = .{ .yield_value = .{ .block = 5 } },
    };
    original.blocks = &yielding;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try compression.construct(a, original, .{}) == null);
    var failing = xor_chain.blocks[0..6].*;
    var ops: [4]ir.Instruction = undefined;
    @memcpy(ops[0..3], failing[4].instructions);
    ops[3] = .{
        .destination = 4,
        .opcode = .integer_add,
        .operands = &.{ 4, 1 },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
    };
    failing[4].instructions = &ops;
    original.blocks = &failing;
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try compression.construct(a, original, .{}) == null);
}
test "effectful mask observation and handler-owned context identity are not compressed" {
    var original = xor_chain;
    original.effects = &.{.{
        .identity = "context.observe-mask",
        .payload = 0,
        .result = 1,
        .external = true,
    }};
    var functions = xor_chain.functions[0..2].*;
    functions[0].effects = &.{0};
    functions[1].effects = &.{0};
    original.functions = &functions;
    var blocks: [7]ir.Block = undefined;
    @memcpy(blocks[0..6], xor_chain.blocks);
    blocks[6] = .{ .function = 1, .instructions = &.{}, .terminator = blocks[4].terminator };
    blocks[4].terminator = .{ .perform = .{ .effect = 0, .payload = 4, .next = .{ .block = 6 } } };
    original.blocks = &blocks;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try compression.construct(a, original, .{}) == null);
    original = xor_chain;
    original.handlers = &.{.{
        .mode = .deep,
        .input = 0,
        .answer = 0,
        .return_function = 1,
        .state = &.{2},
        .clauses = &.{},
    }};
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try compression.construct(a, original, .{}) == null);
}
