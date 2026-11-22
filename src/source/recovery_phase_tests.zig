// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const phase = @import("recovery_phases.zig");
const ir = data.activation;
const Binding = source.RecoveryBinding;
const a = std.testing.allocator;

const program: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 2 },
    .schemas = &.{ .u64, .{ .product = &.{0} }, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 1, 1, 0, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{ 1, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{0},
            .next = .{ .block = 1, .assignments = &.{
                .{ .destination = 2, .source = .returned },
                .{ .destination = 1, .source = .{ .slot = 0 } },
            } },
        } } },
        .{ .function = 0, .instructions = &.{.{
            .opcode = .field,
            .operands = &.{1},
            .destination = 3,
        }}, .terminator = .{ .return_value = 3 } },
        .{ .function = 1, .instructions = &.{.{
            .opcode = .field,
            .operands = &.{0},
            .destination = 1,
        }}, .terminator = .{ .return_value = 1 } },
    },
};

const module: source.Module = .{
    .entry = 0,
    .failure = 2,
    .schemas = program.schemas,
    .constants = &.{},
    .effects = &.{},
    .handlers = &.{},
    .region_count = 0,
    .variables = &.{ 1, 1 },
    .values = &.{},
    .terms = &.{},
    .functions = &.{
        .{ .parameters = &.{0}, .result = 0 },
        .{ .parameters = &.{1}, .result = 0 },
    },
};

fn formalBinding(function: u64) Binding {
    return .{
        .source_function = function,
        .variable = function,
        .source_schema = 1,
        .function = function,
        .slot = 0,
        .schema = 1,
    };
}

const parameters = [_]Binding{ formalBinding(0), formalBinding(1) };
const formals = [_]phase.Formal{.{ .function = 0, .ordinal = 0 }};

test "recovery caller cuts distinguish argument liveness from retention and absence" {
    var blocks = program.blocks[0..3].*;
    blocks[1].instructions = &.{.{ .opcode = .move, .operands = &.{2}, .destination = 3 }};
    var candidate = program;
    candidate.blocks = &blocks;
    var before = try data.activation_ownership.analyze(a, program);
    defer before.deinit();
    var after = try data.activation_ownership.analyze(a, candidate);
    defer after.deinit();
    for (program.blocks, 0..) |block, id| {
        if (block.function != 0) continue;
        for (before.live[id], after.live[id]) |old, new| {
            try std.testing.expectEqual(before.pool.contains(old, 0), after.pool.contains(new, 0));
        }
    }
    try std.testing.expect(before.pool.contains(before.live[0][0], 0));
    try std.testing.expect(!after.pool.contains(after.live[1][0], 0));
    var work: u64 = 1_000_000;
    try phase.validate(
        a,
        module,
        &parameters,
        &formals,
        program,
        &before,
        program,
        &before,
        null,
        &work,
    );
    try std.testing.expectError(error.RecoveryLiveness, phase.validate(
        a,
        module,
        &parameters,
        &formals,
        program,
        &before,
        candidate,
        &after,
        null,
        &work,
    ));
    try std.testing.expectError(error.RecoveryLiveness, phase.validate(
        a,
        module,
        &parameters,
        &formals,
        candidate,
        &after,
        program,
        &before,
        null,
        &work,
    ));
}

test "recovery phases reject forged formal origins and out of range roles" {
    var facts = try data.activation_ownership.analyze(a, program);
    defer facts.deinit();
    var work: u64 = 1000;
    var forged = parameters;
    forged[0].slot = 1;
    try std.testing.expectError(error.InvalidCorrespondence, phase.validate(
        a,
        module,
        &forged,
        &formals,
        program,
        &facts,
        program,
        &facts,
        null,
        &work,
    ));
    forged = parameters;
    forged[0].variable = 1;
    try std.testing.expectError(error.InvalidCorrespondence, phase.validate(
        a,
        module,
        &forged,
        &formals,
        program,
        &facts,
        program,
        &facts,
        null,
        &work,
    ));
    const invalid = [_]phase.Formal{.{ .function = 0, .ordinal = 1 }};
    try std.testing.expectError(error.InvalidCorrespondence, phase.validate(
        a,
        module,
        &parameters,
        &invalid,
        program,
        &facts,
        program,
        &facts,
        null,
        &work,
    ));
}

fn aliasModule(b: *source.Builder, identical: bool) !source.Module {
    const unit = try b.scalar(void);
    const word = try b.scalar(u64);
    const entry = try b.declare(&.{word}, word, &.{}, &.{});
    const first = try b.declare(&.{word}, word, &.{}, &.{});
    const second = try b.declare(&.{word}, word, &.{}, &.{});
    for ([_]u64{ first, second }) |function| {
        const arg = try b.reference(b.parameter(function, 0));
        const operation: data.program.Opcode = if (identical or function == first)
            .integer_bit_and
        else
            .integer_bit_or;
        try b.define(function, try b.pure(try b.primitive(word, operation, &.{ arg, arg }, 0)));
    }
    const value = try b.variable(word);
    const initial = try b.reference(b.parameter(entry, 0));
    const left = try b.term(.{ .call = .{ .function = first, .arguments = &.{initial} } });
    const right = try b.term(.{ .call = .{
        .function = second,
        .arguments = &.{try b.reference(value)},
    } });
    try b.define(entry, try b.bind(value, left, right));
    return b.module(entry, unit);
}

test "recovery alias checks reject gaining or losing an unprotected caller frame" {
    var different_builder = source.Builder.init(a);
    defer different_builder.deinit();
    const different = try aliasModule(&different_builder, false);
    var same_builder = source.Builder.init(a);
    defer same_builder.deinit();
    const same = try aliasModule(&same_builder, true);
    var input = try @import("activation_lower.zig").lowerRecoveryInput(a, different);
    defer input.deinit();
    var distinct = try source.lowerObserved(a, different, .{ .recovery = true });
    defer distinct.deinit();
    var shared = try source.lowerObserved(a, same, .{ .recovery = true });
    defer shared.deinit();
    try source.recovery.validate(a, different, &distinct);
    try source.recovery.validate(a, same, &shared);
    const separate = distinct.recovery_evidence.?.correspondence;
    const merged = shared.recovery_evidence.?.correspondence;
    const roles = [_]phase.Formal{.{ .function = 1, .ordinal = 0 }};
    var work: u64 = 100_000;
    try phase.validateAliases(
        a,
        different,
        input.parameters,
        &roles,
        input.program,
        merged,
        merged,
        &work,
    );
    try std.testing.expectError(error.RecoveryLiveness, phase.validateAliases(
        a,
        different,
        input.parameters,
        &roles,
        input.program,
        separate,
        merged,
        &work,
    ));
    try std.testing.expectError(error.RecoveryLiveness, phase.validateAliases(
        a,
        different,
        input.parameters,
        &roles,
        input.program,
        merged,
        separate,
        &work,
    ));
}
