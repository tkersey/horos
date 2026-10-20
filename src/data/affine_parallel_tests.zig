const std = @import("std");
const ir = @import("activation.zig");
const base = @import("affine_capture_tests.zig").rotating;

pub const cyclic: ir.Program = .{
    .roots = base.roots,
    .schemas = base.schemas,
    .constants = base.constants,
    .effects = base.effects,
    .functions = base.functions,
    .scopes = base.scopes,
    .constructors = base.constructors,
    .blocks = &.{
        base.blocks[0], base.blocks[1],
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .branch = .{
                .condition = 4,
                .when_true = .{ .block = 3 },
                .when_false = .{ .block = 4 },
            } },
        },
        .{
            .function = 1,
            .instructions = base.blocks[3].instructions,
            .terminator = .{
                .jump = .{
                    .block = 2,
                    .assignments = &.{
                        .{ .destination = 0, .source = .{ .slot = 1 } },
                        .{ .destination = 1, .source = .{ .slot = 2 } },
                        .{ .destination = 2, .source = .{ .slot = 5 } },
                        .{ .destination = 4, .source = .{ .slot = 6 } },
                    },
                },
            },
        },
        base.blocks[5],
    },
};

test "parallel capture back edge is an admitted two-coordinate synthesis opportunity" {
    const a = std.testing.allocator;
    var admitted = try @import("activation_ownership.zig").analyze(a, cyclic);
    defer admitted.deinit();
    var stats: @import("affine_state.zig").Statistics = .{};
    var result = try @import("affine_state.zig").run(a, cyclic, 0, &stats, 100000, .{});
    defer result.deinit();
    try std.testing.expectEqual(.applied, stats.outcome);
    try std.testing.expectEqual(@as(usize, 2), stats.reduced_words);
}

test "independent acceptance rejects a well-typed wrong parallel state transfer" {
    const a = std.testing.allocator;
    var candidate = (try @import("affine_emit.zig").construct(a, cyclic, 0, 100000)).?;
    defer candidate.deinit();
    var changed = candidate.program;
    const blocks = try a.dupe(ir.Block, changed.blocks);
    defer a.free(blocks);
    const assignments = try a.dupe(ir.Assignment, blocks[3].terminator.jump.assignments);
    defer a.free(assignments);
    assignments[0].source = .{ .slot = assignments[0].destination };
    blocks[3].terminator.jump.assignments = assignments;
    changed.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, changed);
    defer admitted.deinit();
    try std.testing.expectError(
        error.InvalidAffineCandidate,
        @import("affine_validate.zig").validate(
            a,
            cyclic,
            changed,
            0,
            candidate.basis,
            candidate.input_bias,
            100000,
        ),
    );
}
