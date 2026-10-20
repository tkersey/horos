// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const affine = @import("affine_induction.zig");
const a = std.testing.allocator;
pub const bounded: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u8, .unit, .boolean },
    .effects = &.{},
    .constants = &.{
        .{ .schema = 0, .bytes = &.{50} },
        .{ .schema = 0, .bytes = &.{0} },
        .{ .schema = 0, .bytes = &.{5} },
        .{ .schema = 0, .bytes = &.{3} },
        .{ .schema = 0, .bytes = &.{1} },
        .{ .schema = 1, .bytes = &.{} },
    },
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{0},
        .layout = .{ .slots = &.{ 0, 0, 0, 0, 2, 0, 0, 0, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{
                .{ .destination = 1, .opcode = .constant, .immediate = 0 },
                .{ .destination = 2, .opcode = .constant, .immediate = 1 },
                .{ .destination = 3, .opcode = .constant, .immediate = 1 },
                .{ .destination = 5, .opcode = .constant, .immediate = 2 },
                .{ .destination = 6, .opcode = .constant, .immediate = 3 },
                .{ .destination = 9, .opcode = .constant, .immediate = 4 },
            },
            .terminator = .{ .jump = .{ .block = 1 } },
        },
        .{
            .function = 0,
            .instructions = &.{.{ .destination = 4, .opcode = .less, .operands = &.{ 2, 1 } }},
            .terminator = .{ .branch = .{
                .condition = 4,
                .when_true = .{ .block = 2 },
                .when_false = .{ .block = 3 },
            } },
        },
        .{ .function = 0, .instructions = &.{
            .{
                .destination = 7,
                .opcode = .integer_mul,
                .operands = &.{ 2, 5 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 5 }},
            },
            .{
                .destination = 8,
                .opcode = .integer_add,
                .operands = &.{ 7, 6 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 5 }},
            },
            .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 3, 8 } },
            .{
                .destination = 2,
                .opcode = .integer_add,
                .operands = &.{ 2, 9 },
                .failures = &.{.{ .kind = .arithmetic_overflow, .value = 5 }},
            },
        }, .terminator = .{ .jump = .{ .block = 1 } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
    },
};
pub fn lengthBound(allocator: std.mem.Allocator) !ir.Program {
    var result = bounded;
    result.schemas = &.{ .u64, .unit, .boolean, .{ .vector = .{ .element = 1, .maximum = 50 } } };
    result.constants = &.{
        .{ .schema = 0, .bytes = &.{ 50, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 5, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 3, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{} },
    };
    const functions = try allocator.dupe(ir.Function, result.functions);
    functions[0].layout.slots = &.{ 3, 0, 0, 0, 2, 0, 0, 0, 0, 0 };
    result.functions = functions;
    const blocks = try allocator.dupe(ir.Block, result.blocks);
    const entry = try allocator.dupe(ir.Instruction, blocks[0].instructions);
    entry[0] = .{ .destination = 1, .opcode = .sequence_length, .operands = &.{0} };
    blocks[0].instructions = entry;
    result.blocks = blocks;
    return result;
}
test "checked affine recurrence bounds every intermediate including the last update" {
    var candidate = (try affine.construct(a, bounded, .{})).?;
    defer candidate.deinit();
    try affine.validate(a, bounded, candidate.program, candidate.witness, .{});
    try std.testing.expectEqualSlices(
        p.Id,
        bounded.functions[0].layout.slots,
        candidate.program.functions[0].layout.slots,
    );
    var stats: affine.Statistics = .{};
    var result = try affine.run(a, bounded, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.recurrences);
    for (result.program.blocks) |block| for (block.instructions) |op| try std.testing.expect(
        op.opcode != .integer_mul,
    );
}
test "actual sequence length bounds arithmetic without becoming its capacity" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try lengthBound(arena.allocator());
    var candidate = (try affine.construct(a, original, .{})).?;
    defer candidate.deinit();
    try affine.validate(a, original, candidate.program, candidate.witness, .{});
}
test "recurrence storage cannot reuse an observed or edge-transferred product" {
    var blocks = bounded.blocks[0..4].*;
    var functions = bounded.functions[0..1].*;
    functions[0].inputs = &.{ 0, 7 };
    var observed = bounded;
    observed.functions = &functions;
    observed.blocks = &blocks;
    blocks[3].terminator = .{ .return_value = 7 };
    var admitted = try own.analyze(a, observed);
    admitted.deinit();
    try std.testing.expect(try affine.construct(a, observed, .{}) == null);
    blocks[3] = bounded.blocks[3];
    blocks[2].terminator = .{ .jump = .{
        .block = 1,
        .assignments = &.{.{ .destination = 0, .source = .{ .slot = 7 } }},
    } };
    admitted = try own.analyze(a, observed);
    admitted.deinit();
    try std.testing.expect(try affine.construct(a, observed, .{}) == null);
}
test "a final recurrence update that would overflow leaves the valid original alone" {
    var original = bounded;
    var constants = bounded.constants[0..6].*;
    constants[0].bytes = &.{51};
    original.constants = &constants;
    var admitted = try own.analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try affine.construct(a, original, .{}) == null);
}
test "admitted wrong recurrence seed and increment fail correspondence validation" {
    var candidate = (try affine.construct(a, bounded, .{})).?;
    defer candidate.deinit();
    const blocks = try a.dupe(ir.Block, candidate.program.blocks);
    defer a.free(blocks);
    const seed = try a.dupe(ir.Instruction, blocks[4].instructions);
    defer a.free(seed);
    seed[0].operands = &.{5};
    blocks[4].instructions = seed;
    var forged = candidate.program;
    forged.blocks = blocks;
    var admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineInduction,
        affine.validate(a, bounded, forged, candidate.witness, .{}),
    );
    @memcpy(blocks, candidate.program.blocks);
    const tail = try a.dupe(ir.Instruction, blocks[2].instructions);
    defer a.free(tail);
    tail[tail.len - 1].operands = &.{ 7, 9 };
    blocks[2].instructions = tail;
    admitted = try own.analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineInduction,
        affine.validate(a, bounded, forged, candidate.witness, .{}),
    );
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try affine.run(allocator, bounded, null, .{});
    defer result.deinit();
}
test "affine construction handles every allocation failure" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}
