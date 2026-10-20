// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const pass = @import("constructor_contexts.zig");
const a = std.testing.allocator;
/// Pure recursive map: each returned constructor prepends a negated head.
pub const mapped: ir.Program = .{
    .roots = .{ .entry = 0, .result = 5, .failure = 1 },
    .schemas = &.{
        .boolean,                                          .unit,
        .{ .vector = .{ .element = 0, .maximum = 4096 } }, .{ .product = &.{ 0, 2 } },
        .{ .sum = &.{ 1, 3 } },                            .{ .vector = .{ .element = 0, .maximum = 4096 } },
    },
    .constants = &.{.{ .schema = 1, .bytes = &.{} }},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 2, 5 } }, .result = 5 },
        .{
            .entry = 2,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 2, 4, 3, 0, 2, 0, 5, 5, 5 } },
            .result = 5,
        },
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
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } },
        },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 1, .opcode = .sequence_pop, .operands = &.{0} }},
            .terminator = .{ .switch_variant = .{
                .value = 1,
                .cases = &.{ .{ .block = 3 }, .{ .block = 4 } },
            } },
        },
        .{
            .function = 1,
            .instructions = &.{.{ .destination = 6, .opcode = .sequence }},
            .terminator = .{ .return_value = 6 },
        },
        .{ .function = 1, .instructions = &.{
            .{
                .destination = 2,
                .opcode = .variant_payload,
                .operands = &.{1},
                .immediate = 1,
                .failures = &.{.{ .kind = .invalid_variant, .value = 0 }},
            },
            .{ .destination = 3, .opcode = .field, .operands = &.{2}, .immediate = 0 },
            .{ .destination = 4, .opcode = .field, .operands = &.{2}, .immediate = 1 },
            .{ .destination = 5, .opcode = .boolean_not, .operands = &.{3} },
        }, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{4},
            .next = .{ .block = 5, .assignments = &.{.{ .destination = 6, .source = .returned }} },
        } } },
        .{ .function = 1, .instructions = &.{
            .{ .destination = 7, .opcode = .sequence, .operands = &.{5} },
            .{
                .destination = 8,
                .opcode = .sequence_concat,
                .operands = &.{ 7, 6 },
                .failures = &.{.{ .kind = .capacity_exceeded, .value = 0 }},
            },
        }, .terminator = .{ .return_value = 8 } },
    },
};
pub fn paired(allocator: std.mem.Allocator) !ir.Program {
    var result = mapped;
    const schemas = try allocator.dupe(p.Schema, mapped.schemas);
    schemas[5].vector.maximum = 8192;
    result.schemas = schemas;
    const blocks = try allocator.dupe(ir.Block, mapped.blocks);
    const instructions = try allocator.dupe(ir.Instruction, blocks[5].instructions);
    instructions[0].operands = &.{ 3, 5 };
    blocks[5].instructions = instructions;
    result.blocks = blocks;
    return result;
}
test "ordered singleton and composed chunk contexts become admitted loops without new slots" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]ir.Program{ mapped, try paired(arena.allocator()) }) |original| {
        var admitted = try own.analyze(a, original);
        admitted.deinit();
        var candidate = (try pass.construct(a, original, .{})).?;
        defer candidate.deinit();
        try pass.validate(a, original, candidate.program, candidate.sites, .{});
        try std.testing.expectEqual(
            original.functions[1].layout.slots.len,
            candidate.program.functions[1].layout.slots.len,
        );
        var stats: pass.Statistics = .{};
        var checked = try pass.run(a, original, &stats, .{});
        defer checked.deinit();
        try std.testing.expectEqual(@as(usize, 1), stats.contexts_lowered);
        for (checked.program.blocks) |block| if (block.terminator == .call) try std.testing.expect(
            block.terminator.call.function != block.function,
        );
    }
}
test "admitted reversed context composition is rejected independently" {
    var candidate = (try pass.construct(a, mapped, .{})).?;
    defer candidate.deinit();
    var blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    const instructions = try a.dupe(ir.Instruction, blocks[4].instructions);
    defer a.free(instructions);
    instructions[instructions.len - 1].operands = &.{ 7, 6 };
    blocks[4].instructions = instructions;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidConstructorContext,
        pass.validate(a, mapped, forged, candidate.sites, .{}),
    );
}
test "authored capacity failure and intermediate yield retain the original construction" {
    var schemas = mapped.schemas[0..6].*;
    schemas[5].vector.maximum = 4095;
    var original = mapped;
    original.schemas = &schemas;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
    original = mapped;
    // A coherent yielded base returns its constructed empty value separately.
    const extra = try a.alloc(ir.Block, 7);
    defer a.free(extra);
    @memcpy(extra[0..6], mapped.blocks);
    extra[3].terminator = .{ .yield_value = .{ .block = 6 } };
    extra[6] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 6 } };
    original.blocks = extra;
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try pass.run(allocator, mapped, null, .{});
    defer result.deinit();
}
test "constructor context allocation cleanup and exact zero-work rollback" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
    var stats: pass.Statistics = .{};
    var limited = try pass.run(a, mapped, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    var baseline = try @import("coalescing.zig").run(a, mapped, .{});
    defer baseline.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(
        try @import("program_image.zig").identity(a, baseline.program),
        try @import("program_image.zig").identity(a, limited.program),
    );
    var invalid = mapped;
    invalid.roots.entry = 99;
    try std.testing.expectError(
        error.InvalidReference,
        pass.run(a, invalid, null, .{ .work_limit = 0 }),
    );
}

test "a failing mapper and an exposed worker retain their original continuation contexts" {
    var original = mapped;
    var schemas = mapped.schemas[0..6].*;
    schemas[0] = .u8;
    original.schemas = &schemas;
    var blocks = mapped.blocks[0..6].*;
    var instructions = mapped.blocks[4].instructions[0..4].*;
    instructions[3] = .{
        .destination = 5,
        .opcode = .integer_add,
        .operands = &.{ 3, 3 },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
    };
    blocks[4].instructions = &instructions;
    original.blocks = &blocks;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
    original = mapped;
    original.schemas = &.{
        mapped.schemas[0],
        mapped.schemas[1],
        mapped.schemas[2],
        mapped.schemas[3],
        mapped.schemas[4],
        mapped.schemas[5],
        .{ .internal = .{ .computation = .{
            .parameters = &.{2},
            .result = 5,
            .use = .reusable,
        } } },
    };
    original.scopes.captures = &.{.{ .fields = &.{}, .use = .reusable }};
    original.constructors = &.{.{ .function = 1, .capture = 0, .schema = 6 }};
    admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, .{}) == null);
}
