// Copyright (c) 2026 Boundary contributors. MIT license.
//! Reader/local retains both the scoped body and the outside continuation.
const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const cache_key = @import("../../authoring/cache_key.zig");
pub const Family = opaque {
    pub fn ask(self: *const Family) *const a.Operation {
        return familyData(self).ask;
    }
    pub fn local(self: *const Family) *const a.Operation {
        return familyData(self).local;
    }
    pub fn askCapability(self: *const Family) *const a.Schema {
        return familyData(self).ask_capability;
    }
    pub fn localCapability(self: *const Family) *const a.Schema {
        return familyData(self).local_capability;
    }
    pub fn inside(self: *const Family) *const a.Schema {
        return familyData(self).inside;
    }
};
const FamilyData = struct {
    ask: *const a.Operation,
    local: *const a.Operation,
    ask_capability: *const a.Schema,
    local_capability: *const a.Schema,
    environment: *const a.Schema,
    inside: *const a.Schema,
    inside_result: *const a.Schema,
    inside_captures: []const *const a.Schema,
    residual: []const *const a.Operation,
    regions: []const *const a.Region,
    interpretations: std.ArrayList(Cached) = .empty,
};
fn familyData(f: *const Family) *FamilyData {
    return @ptrCast(@alignCast(@constCast(f)));
}
pub const Reader = struct {
    handler: *const a.Handler,
    inside_handler: *const a.Handler,
    resumptions: []const *const a.Schema,
};
// Context, nominal operations and family schemas belong to the immutable family.
// Every input that varies between interpretation lookups is present in this key.
const Key = struct { result: *const a.Schema, captures: a.CaptureBounds };
const KeyOps = cache_key.KeyOps(Key, cache_key.DefaultPolicy);
const Cached = struct { key: Key, value: Reader };
pub fn family(
    c: *a.Context,
    identity: []const u8,
    environment: *const a.Schema,
    inside_result: *const a.Schema,
    inside_captures: []const *const a.Schema,
    residual: []const *const a.Operation,
    regions: []const *const a.Region,
) a.Error!*const Family {
    const allocator = a.interop.builder(c).allocator();
    const ask = try c.local(
        try allocator.print("{s}/ask", .{identity}),
        try c.scalar(void),
        environment,
        .linear,
    );
    const declaration = try c.declareSchema(.callable);
    const inside = declaration.schema();
    const local = try c.scoped(
        try allocator.print("{s}/local", .{identity}),
        environment,
        inside_result,
        .linear,
        &.{.{ .name = "inside", .schema = inside }},
    );
    const ask_capability = try c.capability(ask);
    const local_capability = try c.capability(local);
    const bound = try allocator.alloc(*const a.Schema, inside_captures.len + 1);
    @memcpy(bound[0..inside_captures.len], inside_captures);
    bound[inside_captures.len] = inside;
    const effects = try allocator.alloc(*const a.Operation, residual.len + 2);
    @memcpy(effects[0..residual.len], residual);
    @memcpy(effects[residual.len..], &[_]*const a.Operation{ ask, local });
    try c.defineCallable(
        declaration,
        &.{
            .{ .name = "ask", .schema = ask_capability },
            .{ .name = "local", .schema = local_capability },
        },
        inside_result,
        effects,
        .{ .use = .linear, .captures = bound, .regions = regions },
    );
    const saved = try allocator.create(FamilyData);
    saved.* = .{
        .ask = ask,
        .local = local,
        .ask_capability = ask_capability,
        .local_capability = local_capability,
        .environment = environment,
        .inside = inside,
        .inside_result = inside_result,
        .inside_captures = bound,
        .residual = try allocator.dupe(*const a.Operation, residual),
        .regions = try allocator.dupe(*const a.Region, regions),
    };
    return @ptrCast(saved);
}
pub fn interpret(
    c: *a.Context,
    reader: *const Family,
    result: *const a.Schema,
    captures: a.CaptureBounds,
) a.Error!Reader {
    const f = familyData(reader);
    _ = try c.capability(f.ask);
    const key: Key = .{ .result = result, .captures = captures };
    for (f.interpretations.items) |entry| if (KeyOps.eql(entry.key, key)) return entry.value;
    const allocator = a.interop.builder(c).allocator();
    const count: usize = if (result == f.inside_result and std.mem.eql(
        *const a.Schema,
        captures.body,
        f.inside_captures,
    )) 1 else 2;
    const declarations = try allocator.alloc(*const a.SchemaDeclaration, count * 2);
    const tokens = try allocator.alloc(*const a.Schema, declarations.len);
    for (declarations, tokens) |*slot, *token| {
        slot.* = try c.declareSchema(.resumption);
        token.* = slot.*.schema();
    }
    const bound = try allocator.alloc(*const a.Schema, captures.continuation.len + 3 + tokens.len);
    @memcpy(bound[0..captures.continuation.len], captures.continuation);
    @memcpy(
        bound[captures.continuation.len..][0..3],
        &[_]*const a.Schema{ f.ask_capability, f.local_capability, f.inside },
    );
    @memcpy(bound[captures.continuation.len + 3 ..], tokens);
    var handlers: [2]*const a.Handler = undefined;
    for (handlers[0..count], 0..) |*handler, index| {
        const answer = if (index == 0) result else f.inside_result;
        handler.* = try c.handlerSet(&.{
            .{ .name = "ask", .operation = f.ask },
            .{ .name = "local", .operation = f.local },
        }, answer, answer, .{
            .mode = .deep,
            .use = .linear,
            .residual = f.residual,
            .return_effects = &.{},
            .captures = bound,
            .body_captures = if (index == 0) captures.body else f.inside_captures,
            .borrowed_regions = f.regions,
            .state = &.{.{ .name = "environment", .schema = f.environment }},
            .resumption_slots = declarations[index * 2 ..][0..2],
        });
        const returns_fn = try c.returnFunction(handler.*);
        const returns = try c.body(returns_fn);
        try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
        const asks_fn = try c.clauseFunctionFor(handler.*, f.ask);
        const asks = try c.body(asks_fn);
        try c.define(
            asks_fn,
            try asks.ret(try asks.resumeValue(
                try asks.parameter("resumption"),
                try asks.parameter("environment"),
            )),
        );
    }
    for (handlers[0..count]) |handler| {
        const clause_fn = try c.clauseFunctionFor(handler, f.local);
        const clause = try c.body(clause_fn);
        const inner = try clause.handleWith(
            handlers[count - 1],
            try clause.parameter("inside"),
            &.{.{ .name = "environment", .value = try clause.parameter("payload") }},
        );
        try c.define(
            clause_fn,
            try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), inner)),
        );
    }
    const value: Reader = .{
        .handler = handlers[0],
        .inside_handler = handlers[count - 1],
        .resumptions = tokens,
    };
    try f.interpretations.append(
        allocator,
        .{ .key = try KeyOps.snapshot(allocator, key), .value = value },
    );
    return value;
}
