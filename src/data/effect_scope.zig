// Copyright (c) 2026 Boundary contributors. MIT license.
//! Effect-family subtraction requires evidence that the body can only select
//! the fresh attachment. These dependencies describe executable access to older
//! capabilities, including access through recursive holders and latent calls.
const std = @import("std");
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
    const ambient = try allocator.alloc(bool, image.effects.len);
    @memset(ambient, false);
    // An unknown implementation is not evidence of local-only interpretation.
    for (imports) |function| for (image.functions[@intCast(function)].effects) |effect| {
        if (effect >= ambient.len) return error.InvalidEffect;
        ambient[@intCast(effect)] = true;
    };
    for (image.blocks) |block| if (block.terminator == .perform) {
        const operation = block.terminator.perform;
        if (operation.effect >= image.effects.len) return error.InvalidEffect;
        if (operation.capability == null) ambient[@intCast(operation.effect)] = true;
    };
    const length = std.math.mul(
        usize,
        image.schemas.len,
        image.effects.len,
    ) catch return error.InvalidLength;
    const dependencies = try allocator.alloc(bool, length);
    @memset(dependencies, false);
    const facts: Facts = .{
        .ambient = ambient,
        .dependencies = dependencies,
        .width = image.effects.len,
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (image.schemas, 0..) |schema, id| for (image.effects, 0..) |_, effect| {
            const index = id * facts.width + effect;
            if (!dependencies[index] and dependency(image, facts, schema, effect)) {
                dependencies[index] = true;
                changed = true;
            }
        };
    }
    return facts;
}

fn any(facts: Facts, fields: []const p.Id, effect: p.Id) bool {
    for (fields) |field| if (facts.contains(field, effect)) return true;
    return false;
}
fn dependency(image: anytype, facts: Facts, schema: p.Schema, effect: p.Id) bool {
    return switch (schema) {
        .product, .sum => |fields| any(facts, fields, effect),
        .seq => |element| facts.contains(element, effect),
        .vector => |vector| facts.contains(vector.element, effect),
        .array => |array| facts.contains(array.element, effect),
        .internal => |internal| switch (internal) {
            .capability => |family| family == effect,
            .cell => |cell| facts.contains(cell.element, effect),
            .suspension_package => |token| facts.contains(token, effect),
            .computation => |signature| blk: {
                if (any(facts, signature.capture_bound, effect) or
                    facts.contains(signature.result, effect))
                    break :blk true;
                if (std.mem.indexOfScalar(
                    p.Id,
                    signature.effects,
                    effect,
                ) == null) break :blk false;
                if (facts.ambient[@intCast(effect)]) break :blk true;
                // An explicit capability parameter is supplied by the caller;
                // it is not an attachment hidden inside this computation value.
                for (signature.parameters) |parameter| {
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
            .resumption => |signature| std.mem.indexOfScalar(
                p.Id,
                signature.effects,
                effect,
            ) != null or facts.contains(signature.answer, effect),
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
