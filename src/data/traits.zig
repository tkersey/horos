// Copyright (c) 2026 Boundary contributors. MIT license.
//! Structural usage properties. Serialized records cannot assert these facts.
const std = @import("std");
const p = @import("program.zig");
pub const Facts = struct { copy: []const bool, drop: []const bool, clone: []const bool };

/// Greatest fixed points for recursive immutable data, narrowed by owned leaves.
pub fn derive(
    allocator: std.mem.Allocator,
    schemas: []const p.Schema,
) @import("admission.zig").Error!Facts {
    for (schemas) |schema| try @import("admission.zig").references(schemas, schema);
    const copy = try allocator.alloc(bool, schemas.len);
    errdefer allocator.free(copy);
    const drop = try allocator.alloc(bool, schemas.len);
    errdefer allocator.free(drop);
    const clone = try allocator.alloc(bool, schemas.len);
    errdefer allocator.free(clone);
    @memset(copy, true);
    @memset(drop, true);
    @memset(clone, true);
    const facts: Facts = .{ .copy = copy, .drop = drop, .clone = clone };
    const mutable = .{ .copy = copy, .drop = drop, .clone = clone };
    var changed = true;
    while (changed) {
        changed = false;
        for (schemas, 0..) |schema, index| {
            const observed = properties(schema, facts);
            inline for (.{ "copy", "drop", "clone" }) |field| {
                if (!@field(observed, field) and @field(facts, field)[index]) {
                    @field(mutable, field)[index] = false;
                    changed = true;
                }
            }
        }
    }
    return facts;
}

const Properties = struct { copy: bool, drop: bool, clone: bool };
fn all(fields: []const p.Id, facts: Facts) Properties {
    var result: Properties = .{ .copy = true, .drop = true, .clone = true };
    for (fields) |id| {
        result.copy = result.copy and facts.copy[@intCast(id)];
        result.drop = result.drop and facts.drop[@intCast(id)];
        result.clone = result.clone and facts.clone[@intCast(id)];
    }
    return result;
}
fn properties(schema: p.Schema, facts: Facts) Properties {
    const unrestricted: Properties = .{ .copy = true, .drop = true, .clone = true };
    return switch (schema) {
        .product, .sum => |fields| all(fields, facts),
        .seq => |element| all(&.{element}, facts),
        .vector => |vector| all(&.{vector.element}, facts),
        .array => |array| all(&.{array.element}, facts),
        .internal => |internal| switch (internal) {
            .computation => |computation| blk: {
                var result = all(computation.capture_bound, facts);
                result.copy = result.copy and
                    (computation.use == .reusable or
                        computation.use == .multi);
                result.drop = result.drop and computation.use != .linear;
                result.clone = result.clone and
                    (computation.use == .reusable or
                        computation.use == .multi);
                break :blk result;
            },
            .resumption => |resumption| blk: {
                const captures = all(resumption.capture_bound, facts);
                break :blk .{
                    .copy = resumption.use == .multi and captures.clone and !resumption.obligations,
                    .drop = !resumption.obligations and
                        (resumption.use == .multi or
                            (resumption.use == .affine and
                                captures.drop)),
                    .clone = resumption.use == .multi and
                        captures.clone and
                        !resumption.obligations,
                };
            },
            .cell => |cell| .{
                .copy = true,
                .drop = true,
                .clone = facts.clone[@intCast(cell.element)],
            },
            .capability, .region => unrestricted,
            .borrowed => |borrow| .{
                .copy = true,
                .drop = true,
                .clone = facts.clone[@intCast(borrow.value)],
            },
            .suspension_package, .abstract_resource => .{
                .copy = false,
                .drop = false,
                .clone = false,
            },
        },
        else => unrestricted,
    };
}
