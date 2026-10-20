// Copyright (c) 2026 Boundary contributors. MIT license.
//! Dynamic log accumulation through explicit handler-owned state.
const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const cache_key = @import("../../authoring/cache_key.zig");
pub const Writer = struct {
    answer: *const a.Schema,
    cell: *const a.Schema,
    sequence: *const a.Schema,
    handler: *const a.Handler,
    resumption: *const a.Schema,
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
    message: *const a.Schema,
    owner: *a.Context,
    interpretations: *std.ArrayList(Cached),
};
// Context, nominal operations and family schemas belong to the immutable family.
// Every input that varies between interpretation lookups is present in this key.
const Key = struct {
    result: *const a.Schema,
    region: *const a.Region,
    captures: a.CaptureBounds,
    residual: []const *const a.Operation,
};
const KeyOps = cache_key.KeyOps(Key, cache_key.DefaultPolicy);
const Cached = struct { key: Key, value: Writer };
pub fn family(c: *a.Context, identity: []const u8, message: *const a.Schema) a.Error!*const Family {
    const effect = try c.local(identity, message, try c.scalar(void), .linear);
    const entries = try a.interop.builder(c).allocator().create(std.ArrayList(Cached));
    entries.* = .empty;
    const saved = try a.interop.builder(c).allocator().create(FamilyData);
    saved.* = .{
        .effect = effect,
        .capability = try c.capability(effect),
        .message = message,
        .owner = c,
        .interpretations = entries,
    };
    return @ptrCast(saved);
}
pub fn interpret(
    c: *a.Context,
    writer: *const Family,
    result: *const a.Schema,
    region: *const a.Region,
    captures: a.CaptureBounds,
    residual: []const *const a.Operation,
) a.Error!Writer {
    const f = familyData(writer);
    _ = try c.capability(f.effect);
    if (c != f.owner) return error.ForeignHandle;
    const key: Key = .{
        .result = result,
        .region = region,
        .captures = captures,
        .residual = residual,
    };
    for (f.interpretations.items) |entry| if (KeyOps.eql(entry.key, key)) return entry.value;
    const allocator = a.interop.builder(c).allocator();
    const sequence = try c.sequence(f.message);
    const cell = try c.cell(region, sequence);
    const answer = try c.record(&.{
        .{ .name = "value", .schema = result },
        .{ .name = "log", .schema = sequence },
    });
    const bound = try allocator.alloc(*const a.Schema, captures.continuation.len + 3);
    @memcpy(bound[0..captures.continuation.len], captures.continuation);
    @memcpy(
        bound[captures.continuation.len..],
        &[_]*const a.Schema{ f.capability, cell, sequence },
    );
    const handler = try c.handler(f.effect, result, answer, .{
        .mode = .deep,
        .use = .linear,
        .residual = residual,
        .return_effects = &.{},
        .captures = bound,
        .body_captures = captures.body,
        .borrowed_regions = &.{region},
        .state = &.{.{ .name = "log", .schema = cell }},
        .obligations = true,
    });
    try defineWriter(c, handler, answer);
    const value: Writer = .{
        .answer = answer,
        .cell = cell,
        .sequence = sequence,
        .handler = handler,
        .resumption = try a.interop.resumptionSchema(c, handler),
    };
    try f.interpretations.append(
        allocator,
        .{ .key = try KeyOps.snapshot(allocator, key), .value = value },
    );
    return value;
}

fn defineWriter(c: *a.Context, handler: *const a.Handler, answer: *const a.Schema) a.Error!void {
    const returns_fn = try c.returnFunction(handler);
    const returns = try c.body(returns_fn);
    const logs = try returns.readCell(try returns.parameter("log"));
    try c.define(returns_fn, try returns.ret(try returns.product(answer, &.{
        .{ .name = "value", .value = try returns.parameter("result") },
        .{ .name = "log", .value = logs },
    })));
    const clause_fn = try c.clauseFunction(handler);
    const clause = try c.body(clause_fn);
    const target = try clause.parameter("log");
    const after = try clause.append(try clause.readCell(target), try clause.parameter("payload"));
    _ = try clause.writeCell(target, after);
    try c.define(
        clause_fn,
        try clause.ret(try clause.resumeValue(
            try clause.parameter("resumption"),
            try clause.constant(void, {}),
        )),
    );
}
