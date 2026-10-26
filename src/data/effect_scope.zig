// Copyright (c) 2026 Boundary contributors. MIT license.
//! Effect-family subtraction requires evidence that the body can only select
//! the fresh attachment. These dependencies describe executable access to older
//! capabilities, including access through recursive holders and latent calls.
const std = @import("std");
const admission = @import("admission.zig");
const p = @import("program.zig");
const Error = @import("admission.zig").Error;
pub const Facts = struct {
    ambient: []const bool,
    dependencies: []const bool,
    width: usize,
    pub fn contains(self: Facts, schema: p.Id, effect: p.Id) bool {
        return self.dependencies[
            @as(usize, @intCast(schema)) * self.width + @as(usize, @intCast(effect))
        ];
    }
};

pub fn derive(allocator: std.mem.Allocator, image: anytype) Error!Facts {
    return deriveComponent(allocator, image, &.{});
}

pub fn deriveComponent(
    allocator: std.mem.Allocator,
    image: anytype,
    imports: []const p.Id,
) Error!Facts {
    return deriveComponentWithWork(allocator, image, imports, null);
}

pub fn deriveComponentWithWork(
    allocator: std.mem.Allocator,
    image: anytype,
    imports: []const p.Id,
    work: ?*u64,
) Error!Facts {
    try admission.spend(work, 1);
    try admission.spend(work, image.effects.len);
    const ambient = try allocator.alloc(bool, image.effects.len);
    @memset(ambient, false);
    // An unknown implementation is not evidence of local-only interpretation.
    for (imports) |function| {
        try admission.spend(work, 1);
        for (image.functions[@intCast(function)].effects) |effect| {
            try admission.spend(work, 1);
            if (effect >= ambient.len) return error.InvalidEffect;
            ambient[@intCast(effect)] = true;
        }
    }
    for (image.blocks) |block| {
        try admission.spend(work, 1);
        if (block.terminator == .perform) {
            const operation = block.terminator.perform;
            if (operation.effect >= image.effects.len) return error.InvalidEffect;
            if (operation.capability == null) ambient[@intCast(operation.effect)] = true;
        }
    }
    const length = std.math.mul(
        usize,
        image.schemas.len,
        image.effects.len,
    ) catch return error.InvalidLength;
    try admission.spend(work, length);
    const dependencies = try allocator.alloc(bool, length);
    @memset(dependencies, false);
    const facts: Facts = .{
        .ambient = ambient,
        .dependencies = dependencies,
        .width = image.effects.len,
    };
    var changed = true;
    while (changed) {
        try admission.spend(work, 1);
        changed = false;
        for (image.schemas, 0..) |schema, id| {
            try admission.spend(work, 1);
            for (image.effects, 0..) |_, effect| {
                try admission.spend(work, 1);
                const index = id * facts.width + effect;
                if (!dependencies[index] and try dependency(image, facts, schema, effect, work)) {
                    dependencies[index] = true;
                    changed = true;
                }
            }
        }
    }
    return facts;
}

fn any(facts: Facts, fields: []const p.Id, effect: p.Id) bool {
    for (fields) |field| if (facts.contains(field, effect)) return true;
    return false;
}
fn dependency(
    image: anytype,
    facts: Facts,
    schema: p.Schema,
    effect: p.Id,
    work: ?*u64,
) Error!bool {
    return switch (schema) {
        .product, .sum => |fields| try anyWithWork(facts, fields, effect, work),
        .seq => |element| facts.contains(element, effect),
        .vector => |vector| facts.contains(vector.element, effect),
        .array => |array| facts.contains(array.element, effect),
        .internal => |internal| switch (internal) {
            .capability => |family| family == effect,
            .cell => |cell| facts.contains(cell.element, effect),
            .suspension_package => |token| facts.contains(token, effect),
            .computation => |signature| blk: {
                if (try anyWithWork(facts, signature.capture_bound, effect, work) or
                    facts.contains(signature.result, effect))
                    break :blk true;
                try admission.spend(work, signature.effects.len);
                if (std.mem.indexOfScalar(
                    p.Id,
                    signature.effects,
                    effect,
                ) == null) break :blk false;
                if (facts.ambient[@intCast(effect)]) break :blk true;
                // An explicit capability parameter is supplied by the caller;
                // it is not an attachment hidden inside this computation value.
                for (signature.parameters) |parameter| {
                    try admission.spend(work, 1);
                    const shape = image.schemas[@intCast(parameter)];
                    if (shape == .internal and
                        shape.internal == .capability and
                        shape.internal.capability == effect)
                        break :blk false;
                }
                break :blk true;
            },
            // Tokens expose only their declared execution and answer. Captured
            // capabilities beneath a deep delimiter cannot be projected out.
            .resumption => |signature| blk: {
                try admission.spend(work, signature.effects.len);
                break :blk std.mem.indexOfScalar(p.Id, signature.effects, effect) != null or
                    facts.contains(signature.answer, effect);
            },
            .region, .abstract_resource, .borrowed => false,
        },
        else => false,
    };
}

pub fn discharged(
    image: anytype,
    facts: Facts,
    handler: anytype,
    body: p.ComputationType,
    effect: p.Id,
) bool {
    if (facts.ambient[@intCast(effect)] or any(facts, body.capture_bound, effect)) return false;
    if (any(facts, body.parameters[handler.clauses.len..], effect)) return false;
    for (handler.clauses) |clause| if (clause.effect == effect) return true;
    _ = image;
    return false;
}

pub fn dischargedWithWork(
    image: anytype,
    facts: Facts,
    handler: anytype,
    body: p.ComputationType,
    effect: p.Id,
    work: ?*u64,
) Error!bool {
    if (facts.ambient[@intCast(effect)] or
        try anyWithWork(facts, body.capture_bound, effect, work)) return false;
    if (try anyWithWork(facts, body.parameters[handler.clauses.len..], effect, work)) return false;
    try admission.spend(work, handler.clauses.len);
    for (handler.clauses) |clause| if (clause.effect == effect) return true;
    _ = image;
    return false;
}

fn anyWithWork(facts: Facts, fields: []const p.Id, effect: p.Id, work: ?*u64) Error!bool {
    for (fields) |field| {
        try admission.spend(work, 1);
        if (facts.contains(field, effect)) return true;
    }
    return false;
}

test "bounded effect scope reserves the schema effect matrix before allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 1 });
    const image = @import("activation.zig").Program{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{ .unit, .unit, .unit, .unit },
        .constants = &.{},
        .effects = &.{.{ .identity = "effect", .payload = 0, .result = 0 }},
        .functions = &.{},
        .blocks = &.{},
    };
    var work: u64 = 2;
    try std.testing.expectError(
        error.RelationLimit,
        deriveComponentWithWork(failing.allocator(), image, &.{}, &work),
    );
    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expectEqual(@as(u64, 0), work);
    var ample: u64 = 100;
    const bounded = try deriveComponentWithWork(arena.allocator(), image, &.{}, &ample);
    const ordinary = try derive(arena.allocator(), image);
    try std.testing.expectEqualSlices(bool, ordinary.dependencies, bounded.dependencies);
}

test "bounded effect scope charges empty catalogs and zero effect traversals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var image = @import("activation.zig").Program{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{},
        .constants = &.{},
        .effects = &.{},
        .functions = &.{},
        .blocks = &.{},
    };
    var empty: u64 = 0;
    try std.testing.expectError(
        error.RelationLimit,
        deriveComponentWithWork(arena.allocator(), image, &.{}, &empty),
    );
    image.schemas = &.{ .unit, .unit, .unit };
    var work: u64 = 100;
    const facts = try deriveComponentWithWork(arena.allocator(), image, &.{}, &work);
    try std.testing.expectEqual(@as(usize, 0), facts.dependencies.len);
    try std.testing.expect(work < 100);
}
