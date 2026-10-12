// Copyright (c) 2026 Boundary contributors. MIT license.
//! DFS and BFS insert immutable alternatives at opposite ends of one worklist.
const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const cache_key = @import("../../authoring/cache_key.zig");
pub const Order = enum { depth_first, breadth_first };
pub const Family = opaque {
    pub fn pick(self: *const Family) *const a.Operation {
        return familyData(self).pick;
    }
    pub fn reject(self: *const Family) *const a.Operation {
        return familyData(self).reject;
    }
    pub fn pickCapability(self: *const Family) *const a.Schema {
        return familyData(self).pick_capability;
    }
    pub fn rejectCapability(self: *const Family) *const a.Schema {
        return familyData(self).reject_capability;
    }
};
const FamilyData = struct {
    pick: *const a.Operation,
    reject: *const a.Operation,
    pick_capability: *const a.Schema,
    reject_capability: *const a.Schema,
    interpretations: std.ArrayList(Cached) = .empty,
};
fn familyData(f: *const Family) *FamilyData {
    return @ptrCast(@alignCast(@constCast(f)));
}
pub const Search = struct { step: *const a.Schema, resumption: *const a.Schema, handler: *const a.Handler, solutions: *const a.Schema, explore: *const a.Function, queue: *const a.Schema };
pub const Options = struct {
    captures: a.CaptureBounds,
    residual: []const *const a.Operation,
    owned_regions: []const *const a.Region = &.{},
    borrowed_regions: []const *const a.Region = &.{},
    order: Order,
};
// Context, nominal operations and family schemas belong to the immutable family.
// Every input that varies between interpretation lookups is present in this key.
const Key = struct { element: *const a.Schema, options: Options };
const KeyOps = cache_key.KeyOps(Key, cache_key.DefaultPolicy);
const Cached = struct { key: Key, value: Search };
pub fn family(c: *a.Context, identity: []const u8) a.Error!*const Family {
    const allocator = a.interop.builder(c).allocator();
    const unit = try c.scalar(void);
    const pick = try c.local(try allocator.print("{s}/pick", .{identity}), unit, try c.scalar(bool), .multi);
    const reject = try c.local(try allocator.print("{s}/reject", .{identity}), unit, unit, .multi);
    const value = try allocator.create(FamilyData);
    value.* = .{ .pick = pick, .reject = reject, .pick_capability = try c.capability(pick), .reject_capability = try c.capability(reject) };
    return @ptrCast(value);
}

pub fn interpret(c: *a.Context, family_handle: *const Family, element: *const a.Schema, options: Options) a.Error!Search {
    const f = familyData(family_handle);
    _ = try c.capability(f.pick);
    const key: Key = .{ .element = element, .options = options };
    for (f.interpretations.items) |entry| if (KeyOps.eql(entry.key, key)) return entry.value;
    const allocator = a.interop.builder(c).allocator();
    const unit = try c.scalar(void);
    const boolean = try c.scalar(bool);
    const bound = try allocator.alloc(*const a.Schema, options.captures.continuation.len + 2);
    @memcpy(bound[0..options.captures.continuation.len], options.captures.continuation);
    @memcpy(bound[options.captures.continuation.len..], &[_]*const a.Schema{ f.pick_capability, f.reject_capability });
    const declaration = try c.declareSchema(.alternatives);
    const step = declaration.schema();
    const handler = try c.handlerSet(&.{ .{ .name = "pick", .operation = f.pick }, .{ .name = "reject", .operation = f.reject } }, element, step, .{
        .mode = .deep,
        .use = .multi,
        .residual = options.residual,
        .return_effects = &.{},
        .clause_effects = &.{},
        .captures = bound,
        .body_captures = options.captures.body,
        .owned_regions = options.owned_regions,
        .borrowed_regions = options.borrowed_regions,
    });
    const token = try c.resumptionSchemaFor(handler, f.pick);
    try c.defineAlternatives(declaration, &.{ .{ .name = "solution", .schema = element }, .{ .name = "branch", .schema = token }, .{ .name = "rejected", .schema = unit } });
    const returns_fn = try c.returnFunction(handler);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.variant(step, "solution", try returns.parameter("result"))));
    const pick_fn = try c.clauseFunctionFor(handler, f.pick);
    const picked = try c.body(pick_fn);
    try c.define(pick_fn, try picked.ret(try picked.variant(step, "branch", try picked.parameter("resumption"))));
    const reject_fn = try c.clauseFunctionFor(handler, f.reject);
    const rejected = try c.body(reject_fn);
    try c.define(reject_fn, try rejected.ret(try rejected.variant(step, "rejected", try rejected.constant(void, {}))));
    const solutions = try c.sequence(element);
    const task = try c.record(&.{ .{ .name = "template", .schema = token }, .{ .name = "argument", .schema = boolean } });
    const queue = try c.sequence(task);
    const explore_schema = try c.callable(&.{ .{ .name = "step", .schema = step }, .{ .name = "queue", .schema = queue }, .{ .name = "found", .schema = solutions } }, solutions, options.residual, .{ .use = .reusable, .captures = &.{}, .regions = options.borrowed_regions });
    const next_schema = try c.callable(&.{ .{ .name = "queue", .schema = queue }, .{ .name = "found", .schema = solutions } }, solutions, options.residual, .{ .use = .reusable, .captures = &.{}, .regions = options.borrowed_regions });
    const explore = try c.functionFor("explore", explore_schema);
    const advance = try c.functionFor("next search task", next_schema);
    const body = try c.body(explore);
    const current = try body.parameter("step");
    const prior = try body.parameter("queue");
    const found = try body.parameter("found");
    const solution = try body.caseOf(current, "solution");
    const branch = try body.caseOf(current, "branch");
    const failure = try body.caseOf(current, "rejected");
    const found_more = try solution.body().append(found, solution.payload());
    const after_solution = try solution.body().call(advance, &.{ .{ .name = "queue", .value = prior }, .{ .name = "found", .value = found_more } });
    const left = try branch.body().product(task, &.{ .{ .name = "template", .value = branch.payload() }, .{ .name = "argument", .value = try branch.body().constant(bool, false) } });
    const right = try branch.body().product(task, &.{ .{ .name = "template", .value = branch.payload() }, .{ .name = "argument", .value = try branch.body().constant(bool, true) } });
    const alternatives = try branch.body().sequenceValue(queue, &.{ left, right });
    const queued = if (options.order == .depth_first) try branch.body().concat(alternatives, prior) else try branch.body().concat(prior, alternatives);
    const after_branch = try branch.body().call(advance, &.{ .{ .name = "queue", .value = queued }, .{ .name = "found", .value = found } });
    const after_failure = try failure.body().call(advance, &.{ .{ .name = "queue", .value = prior }, .{ .name = "found", .value = found } });
    try c.define(explore, try body.ret(try body.match(current, &.{ try solution.ret(after_solution), try branch.ret(after_branch), try failure.ret(after_failure) })));
    const next_body = try c.body(advance);
    const done = try next_body.parameter("found");
    const popped = try next_body.pop(try next_body.parameter("queue"));
    const empty = try next_body.caseOf(popped, "empty");
    const present = try next_body.caseOf(popped, "item");
    const item = try present.body().destructure(present.payload());
    const selected = try present.body().destructure(try item.get("head"));
    const resumed = try present.body().resumeValue(try selected.get("template"), try selected.get("argument"));
    const continued = try present.body().call(explore, &.{ .{ .name = "step", .value = resumed }, .{ .name = "queue", .value = try item.get("tail") }, .{ .name = "found", .value = done } });
    try c.define(advance, try next_body.ret(try next_body.match(popped, &.{ try empty.ret(done), try present.ret(continued) })));
    const value: Search = .{ .step = step, .resumption = token, .handler = handler, .solutions = solutions, .explore = explore, .queue = queue };
    try f.interpretations.append(allocator, .{ .key = try KeyOps.snapshot(allocator, key), .value = value });
    return value;
}
pub fn collect(body: *a.Body, search: Search, step: *const a.Value) a.Error!*const a.Value {
    return body.call(search.explore, &.{ .{ .name = "step", .value = step }, .{ .name = "queue", .value = try body.sequenceValue(search.queue, &.{}) }, .{ .name = "found", .value = try body.sequenceValue(search.solutions, &.{}) } });
}
