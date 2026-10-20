// Copyright (c) 2026 Boundary contributors. MIT license.
//! One get/put interpretation owns explicit cell state and one answer policy.
const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const cache_key = @import("../../authoring/cache_key.zig");
pub const Answer = enum { value, with_state, optional };
pub const Interpretation = struct {
    handler: *const a.Handler,
    answer: *const a.Schema,
    cell: *const a.Schema,
};
pub const Family = opaque {
    pub fn get(self: *const Family) *const a.Operation {
        return familyData(self).get;
    }
    pub fn put(self: *const Family) *const a.Operation {
        return familyData(self).put;
    }
    pub fn getCapability(self: *const Family) *const a.Schema {
        return familyData(self).get_capability;
    }
    pub fn putCapability(self: *const Family) *const a.Schema {
        return familyData(self).put_capability;
    }
};
const FamilyData = struct {
    get: *const a.Operation,
    put: *const a.Operation,
    get_capability: *const a.Schema,
    put_capability: *const a.Schema,
    element: *const a.Schema,
    interpretations: std.ArrayList(Cached) = .empty,
};
// Context, nominal operations and family schemas belong to the immutable family.
// Every input that varies between interpretation lookups is present in this key.
const Key = struct {
    result: *const a.Schema,
    region: *const a.Region,
    captures: a.CaptureBounds,
    residual: []const *const a.Operation,
    disposition: Answer,
};
const KeyOps = cache_key.KeyOps(Key, cache_key.DefaultPolicy);
const Cached = struct { key: Key, value: Interpretation };
fn familyData(f: *const Family) *FamilyData {
    return @ptrCast(@alignCast(@constCast(f)));
}
pub fn family(c: *a.Context, identity: []const u8, element: *const a.Schema) a.Error!*const Family {
    const allocator = a.interop.builder(c).allocator();
    const unit = try c.scalar(void);
    const get = try c.local(try allocator.print("{s}/get", .{identity}), unit, element, .linear);
    const put = try c.local(try allocator.print("{s}/put", .{identity}), element, unit, .linear);
    const saved = try allocator.create(FamilyData);
    saved.* = .{
        .get = get,
        .put = put,
        .get_capability = try c.capability(get),
        .put_capability = try c.capability(put),
        .element = element,
    };
    return @ptrCast(saved);
}
pub fn interpret(
    c: *a.Context,
    state: *const Family,
    result: *const a.Schema,
    region: *const a.Region,
    captures: a.CaptureBounds,
    residual: []const *const a.Operation,
    disposition: Answer,
) a.Error!Interpretation {
    const f = familyData(state);
    _ = try c.capability(f.get);
    const key: Key = .{
        .result = result,
        .region = region,
        .captures = captures,
        .residual = residual,
        .disposition = disposition,
    };
    for (f.interpretations.items) |entry| if (KeyOps.eql(entry.key, key)) return entry.value;
    const allocator = a.interop.builder(c).allocator();
    const cell = try c.cell(region, f.element);
    const answer = switch (disposition) {
        .value => result,
        .with_state => try c.record(&.{
            .{ .name = "value", .schema = result },
            .{ .name = "state", .schema = f.element },
        }),
        .optional => try c.alternatives(&.{
            .{ .name = "none", .schema = try c.scalar(void) },
            .{ .name = "some", .schema = result },
        }),
    };
    const handler = try c.handlerSet(&.{
        .{ .name = "get", .operation = f.get },
        .{ .name = "put", .operation = f.put },
    }, result, answer, .{
        .mode = .deep,
        .use = .linear,
        .residual = residual,
        .return_effects = &.{},
        .captures = captures.continuation,
        .body_captures = captures.body,
        .borrowed_regions = &.{region},
        .state = &.{.{ .name = "state", .schema = cell }},
    });
    const returns_fn = try c.returnFunction(handler);
    const returns = try c.body(returns_fn);
    const returned = try returns.parameter("result");
    try c.define(returns_fn, try returns.ret(switch (disposition) {
        .value => returned,
        .with_state => try returns.product(
            answer,
            &.{
                .{ .name = "value", .value = returned },
                .{
                    .name = "state",
                    .value = try returns.readCell(try returns.parameter("state")),
                },
            },
        ),
        .optional => try returns.variant(answer, "some", returned),
    }));
    for ([_]*const a.Operation{ f.get, f.put }, 0..) |operation, index| {
        const clause_fn = try c.clauseFunctionFor(handler, operation);
        const clause = try c.body(clause_fn);
        const target = try clause.parameter("state");
        const reply = if (index == 0) try clause.readCell(target) else blk: {
            _ = try clause.writeCell(target, try clause.parameter("payload"));
            break :blk try clause.constant(void, {});
        };
        try c.define(
            clause_fn,
            try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), reply)),
        );
    }
    const value: Interpretation = .{ .handler = handler, .answer = answer, .cell = cell };
    try f.interpretations.append(
        allocator,
        .{ .key = try KeyOps.snapshot(allocator, key), .value = value },
    );
    return value;
}
