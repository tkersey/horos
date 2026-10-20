// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const testing = std.testing;
const ir = @import("activation.zig");
const p = @import("program.zig");
const r = @import("relocation.zig");
const w = @import("coalescing_witness.zig");
const validation = @import("coalescing_validation.zig");

pub const original: ir.Program = .{
    .roots = .{ .entry = 2, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 2, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 0,
            .arguments = &.{0},
            .next = .{ .block = 3 },
        } } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{0},
            .next = .{ .block = 4 },
        } } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    },
};
const candidate: ir.Program = .{
    .roots = .{ .entry = 1, .result = 0, .failure = 1 },
    .schemas = original.schemas,
    .constants = &.{},
    .effects = &.{},
    .functions = &.{
        original.functions[0],
        .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
    },
    .blocks = &.{
        original.blocks[0],
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 0,
            .arguments = &.{0},
            .next = .{ .block = 2 },
        } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 0,
            .arguments = &.{0},
            .next = .{ .block = 3 },
        } } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    },
};
const witness: w.Witness = .{
    .representatives = .{
        &.{ 0, 1 }, &.{}, &.{}, &.{ 0, 0, 2 }, &.{ 0, 0, 2, 3, 4 },
        &.{},       &.{}, &.{}, &.{},          &.{},
    },
    .final = .{
        &.{ 0, 1 }, &.{}, &.{}, &.{ 0, 0, 1 }, &.{ 0, 0, 1, 2, 3 },
        &.{},       &.{}, &.{}, &.{},          &.{},
    },
    .locals = &.{
        .{ .slots = &.{0}, .custody = &.{0} },
        .{ .slots = &.{0}, .custody = &.{0} },
        .{ .slots = &.{0}, .custody = &.{0} },
    },
};

fn domainCase(allocator: std.mem.Allocator) !void {
    try w.checkDomains(allocator, original, candidate, witness);
}

test "coalescing witness domains cover separately admitted original and shared candidate" {
    var before = try @import("activation_ownership.zig").analyze(testing.allocator, original);
    defer before.deinit();
    var after = try @import("activation_ownership.zig").analyze(testing.allocator, candidate);
    defer after.deinit();
    try domainCase(testing.allocator);
    try validation.validate(testing.allocator, original, candidate, witness);
    try @import("allocation_testing.zig").check(testing.allocator, domainCase, .{});
}

test "coalescing raw validator rejects separately admissible wrong output" {
    const before: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{.{ .schema = 0, .bytes = &.{ 41, 0, 0, 0, 0, 0, 0, 0 } }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{.{ .opcode = .constant, .destination = 0 }},
            .terminator = .{ .return_value = 0 },
        }},
    };
    const maps: r.Maps = .{ &.{ 0, 1 }, &.{0}, &.{}, &.{0}, &.{0}, &.{}, &.{}, &.{}, &.{}, &.{} };
    const identity: w.Witness = .{
        .representatives = maps,
        .final = maps,
        .locals = witness.locals[0..1],
    };
    var checked = try @import("activation_ownership.zig").analyze(testing.allocator, before);
    checked.deinit();
    try validation.validate(testing.allocator, before, before, identity);
    var after = before;
    after.constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }};
    checked = try @import("activation_ownership.zig").analyze(testing.allocator, after);
    checked.deinit();
    try w.checkDomains(testing.allocator, before, after, identity);
    try testing.expectError(
        error.InvalidCorrespondence,
        validation.validate(testing.allocator, before, after, identity),
    );
}

fn validationCase(allocator: std.mem.Allocator) !void {
    try validation.validate(allocator, original, candidate, witness);
}

test "coalescing raw validation releases temporary storage on allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, validationCase, .{});
}

test "coalescing raw validator rejects mutated control and a code merge in description profile" {
    var after = candidate;
    var blocks = candidate.blocks[0..4].*;
    blocks[1].terminator.call.next.block = 3;
    after.blocks = &blocks;
    try testing.expectError(
        error.InvalidCorrespondence,
        validation.validate(testing.allocator, original, after, witness),
    );
    var changed = witness;
    changed.profile = .descriptions;
    try testing.expectError(
        error.InvalidCorrespondence,
        validation.validate(testing.allocator, original, candidate, changed),
    );
}

test "coalescing raw validator accepts consistent slot renaming including unused slots" {
    var before = original;
    var functions = original.functions[0..3].*;
    functions[0].layout.slots = &.{ 0, 0 };
    functions[1].layout.slots = &.{ 0, 0 };
    functions[1].inputs = &.{1};
    before.functions = &functions;
    var blocks = original.blocks[0..5].*;
    blocks[1].terminator = .{ .return_value = 1 };
    before.blocks = &blocks;
    var after = candidate;
    var final_functions = candidate.functions[0..2].*;
    final_functions[0].layout.slots = &.{ 0, 0 };
    after.functions = &final_functions;
    var locals = witness.locals[0..3].*;
    locals[0].slots = &.{ 0, 1 };
    locals[1].slots = &.{ 1, 0 };
    var changed = witness;
    changed.locals = &locals;
    var facts = try @import("activation_ownership.zig").analyze(testing.allocator, before);
    facts.deinit();
    facts = try @import("activation_ownership.zig").analyze(testing.allocator, after);
    facts.deinit();
    try validation.validate(testing.allocator, before, after, changed);
    locals[1].slots = &.{ 0, 1 };
    try testing.expectError(
        error.InvalidCorrespondence,
        validation.validate(testing.allocator, before, after, changed),
    );
    locals[1].slots = &.{ 1, 0 };
    locals[0].slots = &.{ 1, 0 }; // A representative must retain physical layout.
    try testing.expectError(
        error.InvalidCorrespondence,
        validation.validate(testing.allocator, before, after, changed),
    );
}

fn identityCase(allocator: std.mem.Allocator) !void {
    const maps = try r.identityMaps(allocator, try r.sizes(original));
    defer for (maps) |map| allocator.free(map);
    for (maps) |map| for (map, 0..) |id, index| try testing.expectEqual(index, id);
}

test "coalescing shared identity maps clean up each allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, identityCase, .{});
}

test "coalescing witness domains reject missing cyclic foreign and uncovered mappings" {
    const bad_maps = [_][]const p.Id{
        &.{ 0, 0 }, &.{ 0, 0, r.missing }, &.{ 0, 0, 2 }, &.{ 0, 1, 1 },
    };
    for (bad_maps) |map| {
        var changed = witness;
        changed.final[@backingInt(r.Kind.function)] = map;
        try testing.expectError(
            error.InvalidCorrespondence,
            w.checkDomains(testing.allocator, original, candidate, changed),
        );
    }
    var changed = witness;
    changed.representatives[@backingInt(r.Kind.function)] = &.{ 1, 0, 2 };
    try testing.expectError(
        error.InvalidCorrespondence,
        w.checkDomains(testing.allocator, original, candidate, changed),
    );
    changed = witness;
    changed.final[@backingInt(r.Kind.block)] = &.{ 0, 0, 1, 1, 3 };
    try testing.expectError(
        error.InvalidCorrespondence,
        w.checkDomains(testing.allocator, original, candidate, changed),
    );
}

test "coalescing witness domains reject local nonbijections and authority merges" {
    var changed = witness;
    var locals = witness.locals[0..3].*;
    locals[0].slots = &.{1};
    changed.locals = &locals;
    try testing.expectError(
        error.InvalidCorrespondence,
        w.checkDomains(testing.allocator, original, candidate, changed),
    );
    locals[0] = witness.locals[0];
    locals[1].custody = &.{};
    try testing.expectError(
        error.InvalidCorrespondence,
        w.checkDomains(testing.allocator, original, candidate, changed),
    );
    inline for (.{ @as(p.Id, 0), @as(p.Id, 1) }) |privileged| {
        var before = original;
        var after = candidate;
        before.scopes.resources = &.{.{
            .representation = 0,
            .introducers = &.{privileged},
            .eliminators = &.{},
        }};
        after.scopes.resources = &.{.{
            .representation = 0,
            .introducers = &.{0},
            .eliminators = &.{},
        }};
        changed = witness;
        changed.representatives[@backingInt(r.Kind.resource)] = &.{0};
        changed.final[@backingInt(r.Kind.resource)] = &.{0};
        try testing.expectError(
            error.InvalidCorrespondence,
            w.checkDomains(testing.allocator, before, after, changed),
        );
    }
}
