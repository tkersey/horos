// Copyright (c) 2026 Boundary contributors. MIT license.
//! Catch explicitly discharges the abandoned continuation before returning failure.
const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const cache_key = @import("../../authoring/cache_key.zig");
pub const Raise = struct {
    answer: *const a.Schema,
    resumption: *const a.Schema,
    handler: *const a.Handler,
};
pub const Family = opaque {
    pub fn effect(self: *const Family) *const a.Operation {
        return familyData(self).effect;
    }
    pub fn capability(self: *const Family) *const a.Schema {
        return familyData(self).capability;
    }
};
fn familyData(self: *const Family) *const FamilyData {
    return @ptrCast(@alignCast(self));
}
const FamilyData = struct {
    effect: *const a.Operation,
    capability: *const a.Schema,
    failure: *const a.Schema,
    owner: *a.Context,
    interpretations: *std.ArrayList(Cached),
};
// Context, nominal operations and family schemas belong to the immutable family.
// Every input that varies between interpretation lookups is present in this key.
const Key = struct {
    result: *const a.Schema,
    captures: a.CaptureBounds,
    residual: []const *const a.Operation,
    regions: []const *const a.Region,
};
const KeyOps = cache_key.KeyOps(Key, cache_key.DefaultPolicy);
const Cached = struct { key: Key, value: Raise };
pub fn family(c: *a.Context, identity: []const u8, failure: *const a.Schema) a.Error!*const Family {
    const effect = try c.local(identity, failure, try c.scalar(void), .linear);
    const entries = try a.interop.builder(c).allocator().create(std.ArrayList(Cached));
    entries.* = .empty;
    const saved = try a.interop.builder(c).allocator().create(FamilyData);
    saved.* = .{
        .effect = effect,
        .capability = try c.capability(effect),
        .failure = failure,
        .owner = c,
        .interpretations = entries,
    };
    return @ptrCast(saved);
}
pub fn catching(
    c: *a.Context,
    raised: *const Family,
    result: *const a.Schema,
    captures: a.CaptureBounds,
    residual: []const *const a.Operation,
    regions: []const *const a.Region,
) a.Error!Raise {
    const f = familyData(raised);
    _ = try c.capability(f.effect);
    if (c != f.owner) return error.ForeignHandle;
    const key: Key = .{
        .result = result,
        .captures = captures,
        .residual = residual,
        .regions = regions,
    };
    for (f.interpretations.items) |entry| if (KeyOps.eql(entry.key, key)) return entry.value;
    const allocator = a.interop.builder(c).allocator();
    const answer = try c.alternatives(&.{
        .{ .name = "failure", .schema = f.failure },
        .{ .name = "value", .schema = result },
    });
    const bound = try allocator.alloc(*const a.Schema, captures.continuation.len + 1);
    @memcpy(bound[0..captures.continuation.len], captures.continuation);
    bound[captures.continuation.len] = f.capability;
    const handler = try c.handler(f.effect, result, answer, .{
        .mode = .deep,
        .use = .linear,
        .residual = residual,
        .return_effects = &.{},
        .captures = bound,
        .body_captures = captures.body,
        .borrowed_regions = regions,
        .obligations = true,
    });
    const returns_fn = try c.returnFunction(handler);
    const returns = try c.body(returns_fn);
    try c.define(
        returns_fn,
        try returns.ret(try returns.variant(answer, "value", try returns.parameter("result"))),
    );
    const clause_fn = try c.clauseFunction(handler);
    const clause = try c.body(clause_fn);
    _ = try clause.dispose(try clause.parameter("resumption"));
    try c.define(
        clause_fn,
        try clause.ret(try clause.variant(answer, "failure", try clause.parameter("payload"))),
    );
    const value: Raise = .{
        .answer = answer,
        .resumption = try a.interop.resumptionSchema(c, handler),
        .handler = handler,
    };
    try f.interpretations.append(
        allocator,
        .{ .key = try KeyOps.snapshot(allocator, key), .value = value },
    );
    return value;
}
