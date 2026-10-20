// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const pass = @import("equality_saturation.zig");
const a = std.testing.allocator;
pub const projected: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit, .{ .product = &.{ 0, 0 } } },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 0, 2, 0, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } },
        .{ .destination = 3, .opcode = .field, .operands = &.{2}, .immediate = 0 },
        .{ .destination = 4, .opcode = .integer_bit_xor, .operands = &.{ 3, 1 } },
        .{ .destination = 5, .opcode = .integer_bit_xor, .operands = &.{ 4, 0 } },
    }, .terminator = .{ .return_value = 5 } }},
};
pub const shared_product: ir.Program = .{
    .roots = .{ .entry = 0, .result = 3, .failure = 1 },
    .schemas = &.{ .u64, .unit, .{ .product = &.{ 0, 0 } }, .{ .product = &.{ 2, 2 } } },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 0, 2, 3, 2, 3 } },
        .result = 3,
    }},
    .blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 2, .opcode = .product, .operands = &.{ 0, 1 } },
        .{ .destination = 3, .opcode = .product, .operands = &.{ 2, 2 } },
        .{ .destination = 4, .opcode = .field, .operands = &.{3}, .immediate = 0 },
        .{ .destination = 5, .opcode = .product, .operands = &.{ 2, 4 } },
    }, .terminator = .{ .return_value = 5 } }},
};
test "projection and XOR laws interact through typed product classes" {
    var candidate = (try pass.construct(a, projected, null, .{})).?;
    defer candidate.deinit();
    try pass.validate(a, projected, candidate.program, candidate.proof, .{});
    var projection = false;
    for (candidate.proof.steps) |step| {
        projection = projection or step.law == .projection;
    }
    try std.testing.expect(projection);
    try std.testing.expectEqual(@as(usize, 0), candidate.program.blocks[0].instructions.len);
    try std.testing.expectEqual(@as(p.Id, 1), candidate.program.blocks[0].terminator.return_value);
}
test "materialization preserves expensive shared product construction" {
    var statistics: pass.Statistics = .{};
    var candidate = (try pass.construct(a, shared_product, &statistics, .{})).?;
    defer candidate.deinit();
    try pass.validate(a, shared_product, candidate.program, candidate.proof, .{});
    const ops = candidate.program.blocks[0].instructions;
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqual(@as(?u64, 3), statistics.heuristic_tree_cost);
    try std.testing.expectEqual(@as(usize, 2), statistics.materialized_instructions);
    try std.testing.expect(ops[0].opcode == .product and ops[1].opcode == .product);
    try std.testing.expectEqual(ops[1].operands[0], ops[1].operands[1]);
    var blocks = candidate.program.blocks[0..1].*;
    const changed = try a.dupe(ir.Instruction, ops);
    defer a.free(changed);
    const reversed = [_]p.Id{ changed[0].operands[1], changed[0].operands[0] };
    changed[0].operands = &reversed;
    blocks[0].instructions = changed;
    var forged = candidate.program;
    forged.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidEqualityProof,
        pass.validate(a, shared_product, forged, candidate.proof, .{}),
    );
}

test "shared compilation searches product-copy remnants after projection forwarding" {
    const compiler = @import("closed_compilation.zig");
    var result = try compiler.run(a, shared_product, .{ .contract = .semantic });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.program.blocks[0].instructions.len);
    for (result.program.blocks[0].instructions) |op| try std.testing.expect(op.opcode == .product);
}

test "regional aliases and injected internal-type nodes cannot enter equality classes" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const borrowed = try @import("rectangular_loops_tests.zig").aliasedRectangle(arena.allocator());
    var admitted = try @import("activation_ownership.zig").analyze(a, borrowed);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, borrowed, null, .{}) == null);
    var original = interaction;
    original.schemas = &.{ .u64, .unit, .{ .internal = .{ .region = 0 } } };
    original.scopes.region_count = 1;
    var candidate = (try pass.construct(a, original, null, .{})).?;
    defer candidate.deinit();
    const nodes = try a.alloc(pass.Node, candidate.proof.nodes.len + 1);
    defer a.free(nodes);
    @memcpy(nodes[0..candidate.proof.nodes.len], candidate.proof.nodes);
    nodes[nodes.len - 1] = .{ .kind = .input, .schema = 2, .value = 0 };
    var proof = candidate.proof;
    proof.nodes = nodes;
    try std.testing.expectError(
        error.InvalidEqualityProof,
        pass.validate(a, original, candidate.program, proof, .{}),
    );
}

fn productAllocationAttempt(allocator: std.mem.Allocator) !void {
    var candidate = (try pass.construct(allocator, shared_product, null, .{})).?;
    defer candidate.deinit();
    try pass.validate(allocator, shared_product, candidate.program, candidate.proof, .{});
}
test "typed product extraction and replay clean every allocation failure" {
    try @import("allocation_testing.zig").check(a, productAllocationAttempt, .{});
}
pub const interaction: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 0, 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 2, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } },
        .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 2, 0 } },
    }, .terminator = .{ .return_value = 3 } }},
};
test "typed saturation exposes cancellation through interacting XOR laws" {
    var stats: pass.Statistics = .{};
    var candidate = (try pass.construct(a, interaction, &stats, .{})).?;
    defer candidate.deinit();
    try pass.validate(a, interaction, candidate.program, candidate.proof, .{});
    try std.testing.expect(stats.saturated);
    try std.testing.expect(stats.unions > 1);
    try std.testing.expectEqual(@as(usize, 0), candidate.program.blocks[0].instructions.len);
    try std.testing.expectEqual(@as(p.Id, 1), candidate.program.blocks[0].terminator.return_value);
    std.debug.print(
        "XOR saturation nodes={d} classes={d} unions={d} rounds={d}\n",
        .{ stats.nodes, stats.classes, stats.unions, stats.rounds },
    );
}
test "cyclic XOR-zero equivalence extracts a finite input" {
    var original = interaction;
    original.constants = &.{.{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } }};
    original.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 2, .opcode = .constant },
            .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 0, 2 } },
        },
        .terminator = .{ .return_value = 3 },
    }};
    var candidate = (try pass.construct(a, original, null, .{})).?;
    defer candidate.deinit();
    try pass.validate(a, original, candidate.program, candidate.proof, .{});
    var has_zero = false;
    for (candidate.proof.steps) |step| {
        has_zero = has_zero or step.law == .zero;
    }
    try std.testing.expect(has_zero);
    try std.testing.expectEqual(@as(usize, 0), candidate.program.blocks[0].instructions.len);
    try std.testing.expectEqual(@as(p.Id, 0), candidate.program.blocks[0].terminator.return_value);
}
test "an admitted wrong extracted output and stale epoch fail replay" {
    var candidate = (try pass.construct(a, interaction, null, .{})).?;
    defer candidate.deinit();
    var blocks = candidate.program.blocks[0..1].*;
    blocks[0].terminator = .{ .return_value = 0 };
    var forged = candidate.program;
    forged.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, forged);
    admitted.deinit();
    try std.testing.expectError(
        error.InvalidEqualityProof,
        pass.validate(a, interaction, forged, candidate.proof, .{}),
    );
    var proof = candidate.proof;
    proof.epoch[0] ^= 1;
    try std.testing.expectError(
        error.InvalidEqualityProof,
        pass.validate(a, interaction, candidate.program, proof, .{}),
    );
}
test "node and work exhaustion retain independently admitted P01" {
    var stats: pass.Statistics = .{};
    var result = try pass.run(a, interaction, &stats, .{ .max_nodes = 2 });
    defer result.deinit();
    try std.testing.expect(stats.work_limit);
    var baseline = try @import("coalescing.zig").run(a, interaction, .{});
    defer baseline.deinit();
    try std.testing.expect(@import("record_equal.zig").equal(
        ir.Program,
        baseline.program,
        result.program,
    ));
    var limited = try pass.run(a, interaction, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    var invalid = interaction;
    invalid.roots.entry = 99;
    try std.testing.expectError(
        error.InvalidReference,
        pass.run(a, invalid, &stats, .{ .work_limit = 0 }),
    );
}

test "equal numeric zeros of different widths cannot be merged by a proof" {
    var original = interaction;
    original.schemas = &.{ .u8, .u64, .unit };
    original.roots = .{ .entry = 0, .result = 1, .failure = 2 };
    original.functions = &.{.{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 0, 1, 0, 1 } },
        .result = 1,
    }};
    original.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 2, .opcode = .integer_bit_xor, .operands = &.{ 0, 0 } },
            .{ .destination = 3, .opcode = .integer_bit_xor, .operands = &.{ 1, 1 } },
        },
        .terminator = .{ .return_value = 3 },
    }};
    var candidate = (try pass.construct(a, original, null, .{})).?;
    defer candidate.deinit();
    try pass.validate(a, original, candidate.program, candidate.proof, .{});
    var zeros: [2]?usize = .{ null, null };
    for (
        candidate.proof.nodes,
        0..,
    ) |node, id| if (node.kind == .literal and node.value == 0 and node.schema < 2) {
        zeros[@intCast(node.schema)] = id;
    };
    try std.testing.expect(zeros[0] != null and zeros[1] != null);
    const steps = try a.alloc(pass.Step, candidate.proof.steps.len + 1);
    defer a.free(steps);
    @memcpy(steps[0..candidate.proof.steps.len], candidate.proof.steps);
    steps[steps.len - 1] = .{ .law = .congruence, .left = zeros[0].?, .right = zeros[1].? };
    var proof = candidate.proof;
    proof.steps = steps;
    try std.testing.expectError(
        error.InvalidEqualityProof,
        pass.validate(a, original, candidate.program, proof, .{}),
    );
}
test "checked arithmetic and zero times a failing expression stay outside saturation" {
    var original = interaction;
    original.constants = &.{
        .{ .schema = 1, .bytes = &.{} },
        .{ .schema = 0, .bytes = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    };
    original.blocks = &.{.{ .function = 0, .instructions = &.{
        .{ .destination = 2, .opcode = .constant, .immediate = 1 },
        .{
            .destination = 3,
            .opcode = .integer_add,
            .operands = &.{ 0, 1 },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
        },
        .{
            .destination = 2,
            .opcode = .integer_mul,
            .operands = &.{ 2, 3 },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
        },
    }, .terminator = .{ .return_value = 2 } }};
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    admitted.deinit();
    try std.testing.expect(try pass.construct(a, original, null, .{}) == null);
}
fn allocationAttempt(allocator: std.mem.Allocator) !void {
    var result = try pass.run(allocator, interaction, null, .{});
    defer result.deinit();
}
test "saturation proof and extraction release every failed allocation" {
    try @import("allocation_testing.zig").check(a, allocationAttempt, .{});
}

test "repeated slot definitions use their actual value versions" {
    var original = interaction;
    original.blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 0, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } },
            .{ .destination = 2, .opcode = .integer_bit_xor, .operands = &.{ 0, 1 } },
        },
        .terminator = .{ .return_value = 2 },
    }};
    var candidate = (try pass.construct(a, original, null, .{})).?;
    defer candidate.deinit();
    try pass.validate(a, original, candidate.program, candidate.proof, .{});
    try std.testing.expectEqual(@as(usize, 0), candidate.program.blocks[0].instructions.len);
    try std.testing.expectEqual(@as(p.Id, 0), candidate.program.blocks[0].terminator.return_value);
}
