// Copyright (c) 2026 Boundary contributors. MIT license.
//! Owned generators are ordinary deep handlers and recursive source data.
const std = @import("std");
const source = @import("../../source.zig");
const a = @import("../../authoring/runtime.zig");
const p = @import("horos_data").program;
const Error = source.Error;
pub const Generator = struct { input: p.Id, result: p.Id, effect: p.Id, capability: p.Id, element: p.Id, answer: p.Id, yielded: p.Id, package: p.Id, resumption: p.Id, handler: p.Id };
pub const Scope = struct {
    captures: []const p.Id = &.{},
    owned_regions: []const p.Id = &.{},
    borrowed_regions: []const p.Id = &.{},
    residual: source.Row = .{ .effects = &.{} },
};

/// Bidirectional owned exchange: supplied input advances to the next offered
/// output or completion. It never returns the preceding output again.
pub fn defineExchange(builder: *source.Builder, identity: []const u8, input: p.Id, element: p.Id, result: p.Id, captures: []const p.Id, owned_regions: []const p.Id, borrowed_regions: []const p.Id, residual: source.Row) Error!Generator {
    const instance = try builder.specialization(Generator, "boundary.library.exchange/v1", .{ identity, input, element, result, captures, owned_regions, borrowed_regions, residual });
    if (instance.cached) |value| return value;
    const value = authoredExchange(builder, identity, input, element, result, captures, owned_regions, borrowed_regions, residual) catch |err| return a.sourceError(err);
    return instance.finish(builder, value);
}

pub const Exchange = opaque {
    pub fn input(self: *const Exchange) *const a.Schema {
        return exchangeData(self).input;
    }
    pub fn element(self: *const Exchange) *const a.Schema {
        return exchangeData(self).element;
    }
    pub fn result(self: *const Exchange) *const a.Schema {
        return exchangeData(self).result;
    }
    pub fn effect(self: *const Exchange) *const a.Operation {
        return exchangeData(self).effect;
    }
    pub fn capability(self: *const Exchange) *const a.Schema {
        return exchangeData(self).capability;
    }
    pub fn answer(self: *const Exchange) *const a.Schema {
        return exchangeData(self).answer;
    }
    pub fn yielded(self: *const Exchange) *const a.Schema {
        return exchangeData(self).yielded;
    }
    pub fn package(self: *const Exchange) *const a.Schema {
        return exchangeData(self).package;
    }
    pub fn resumption(self: *const Exchange) *const a.Schema {
        return exchangeData(self).resumption;
    }
    pub fn handler(self: *const Exchange) *const a.Handler {
        return exchangeData(self).handler;
    }
};
fn exchangeData(value: *const Exchange) *ExchangeData {
    return @ptrCast(@alignCast(@constCast(value)));
}
const ExchangeData = struct {
    owner: *a.Context,
    pipelines: std.ArrayList(PipelineCache) = .empty,
    input: *const a.Schema,
    element: *const a.Schema,
    result: *const a.Schema,
    effect: *const a.Operation,
    capability: *const a.Schema,
    answer: *const a.Schema,
    yielded: *const a.Schema,
    package: *const a.Schema,
    resumption: *const a.Schema,
    handler: *const a.Handler,
    fn sourceIds(self: @This(), c: *a.Context) a.Error!Generator {
        return .{ .input = try a.interop.schemaId(c, self.input), .result = try a.interop.schemaId(c, self.result), .effect = try a.interop.operationId(c, self.effect), .capability = try a.interop.schemaId(c, self.capability), .element = try a.interop.schemaId(c, self.element), .answer = try a.interop.schemaId(c, self.answer), .yielded = try a.interop.schemaId(c, self.yielded), .package = try a.interop.schemaId(c, self.package), .resumption = try a.interop.schemaId(c, self.resumption), .handler = try a.interop.handlerId(c, self.handler) };
    }
};
pub const Options = struct {
    captures: a.CaptureBounds,
    owned_regions: []const *const a.Region = &.{},
    borrowed_regions: []const *const a.Region = &.{},
    residual: []const *const a.Operation = &.{},
    parameters: []const a.Field = &.{},
    body_use: p.Use = .linear,
};

/// Declare a typed owned exchange. Reuse this definition for every endpoint
/// sharing its nominal operation and recursive answer contract.
pub fn create(c: *a.Context, identity: []const u8, input: *const a.Schema, element: *const a.Schema, result: *const a.Schema, options: Options) a.Error!*const Exchange {
    return makeExchange(c, identity, input, element, result, options.captures.continuation, options.owned_regions, options.borrowed_regions, options.residual, options.parameters, options.captures.body, options.body_use);
}

fn schemas(c: *a.Context, ids: []const p.Id) a.Error![]const *const a.Schema {
    const values = try a.interop.builder(c).allocator().alloc(*const a.Schema, ids.len);
    for (ids, values) |id, *value| value.* = try a.interop.schema(c, id);
    return values;
}
fn operations(c: *a.Context, ids: []const p.Id) a.Error![]const *const a.Operation {
    const values = try a.interop.builder(c).allocator().alloc(*const a.Operation, ids.len);
    for (ids, values) |id, *value| value.* = try a.interop.operation(c, id);
    return values;
}
fn regionHandles(c: *a.Context, ids: []const p.Id) a.Error![]const *const a.Region {
    const values = try a.interop.builder(c).allocator().alloc(*const a.Region, ids.len);
    for (ids, values) |id, *value| value.* = try a.interop.region(c, id);
    return values;
}
fn authoredExchange(b: *source.Builder, identity: []const u8, input: p.Id, element: p.Id, result: p.Id, captures: []const p.Id, owned_regions: []const p.Id, borrowed_regions: []const p.Id, residual: source.Row) a.Error!Generator {
    const c = try a.Context.init(b);
    const value = try makeExchange(c, identity, try a.interop.schema(c, input), try a.interop.schema(c, element), try a.interop.schema(c, result), try schemas(c, captures), try regionHandles(c, owned_regions), try regionHandles(c, borrowed_regions), try operations(c, residual.effects), &.{}, &.{}, .linear);
    return exchangeData(value).sourceIds(c);
}
fn makeExchange(c: *a.Context, identity: []const u8, input: *const a.Schema, element: *const a.Schema, result: *const a.Schema, captures: []const *const a.Schema, owned: []const *const a.Region, borrowed: []const *const a.Region, residual: []const *const a.Operation, parameters: []const a.Field, body_captures: []const *const a.Schema, body_use: p.Use) a.Error!*const Exchange {
    const effect = try c.local(identity, element, input, .linear);
    const capability = try c.capability(effect);
    const bound = try a.interop.builder(c).allocator().alloc(*const a.Schema, captures.len + 1);
    @memcpy(bound[0..captures.len], captures);
    bound[captures.len] = capability;
    const answer_declaration = try c.declareSchema(.alternatives);
    const answer = answer_declaration.schema();
    const handler = try c.handler(effect, result, answer, .{
        .mode = .deep,
        .use = .linear,
        .residual = residual,
        .return_effects = &.{},
        .clause_effects = &.{},
        .captures = bound,
        .body_captures = body_captures,
        .body_use = body_use,
        .owned_regions = owned,
        .borrowed_regions = borrowed,
        .obligations = true,
        .body_parameters = parameters,
    });
    const resumption = try c.resumptionSchemaFor(handler, effect);
    const package = try c.suspensionPackage(resumption);
    const yielded = try c.record(&.{ .{ .name = "value", .schema = element }, .{ .name = "future", .schema = package } });
    try c.defineAlternatives(answer_declaration, &.{ .{ .name = "done", .schema = result }, .{ .name = "yielded", .schema = yielded } });
    const returns_fn = try c.returnFunction(handler);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.variant(answer, "done", try returns.parameter("result"))));
    const clause_fn = try c.clauseFunction(handler);
    const clause = try c.body(clause_fn);
    const suspended = try clause.package(try clause.parameter("resumption"));
    const offered = try clause.product(yielded, &.{ .{ .name = "value", .value = try clause.parameter("payload") }, .{ .name = "future", .value = suspended } });
    try c.define(clause_fn, try clause.ret(try clause.variant(answer, "yielded", offered)));
    const saved = try a.interop.builder(c).allocator().create(ExchangeData);
    saved.* = .{ .owner = c, .input = input, .result = result, .effect = effect, .capability = capability, .element = element, .answer = answer, .yielded = yielded, .package = package, .resumption = resumption, .handler = handler };
    return @ptrCast(saved);
}

pub fn next(builder: *source.Builder, generator: Generator, package: p.Id) Error!p.Id {
    return builder.term(.{ .resume_value = .{ .resumption = try builder.primitive(generator.resumption, .unpack, &.{package}, 0), .argument = try builder.constant(void, {}) } });
}
pub fn close(builder: *source.Builder, generator: Generator, package: p.Id) Error!p.Id {
    return builder.term(.{ .dispose = try builder.primitive(generator.resumption, .unpack, &.{package}, 0) });
}

pub fn start(builder: *source.Builder, definition: Generator, body: p.Id, arguments: []const p.Id) Error!p.Id {
    return builder.term(.{ .handle = .{ .handler = definition.handler, .body = body, .arguments = arguments } });
}

pub fn offer(builder: *source.Builder, definition: Generator, capability: p.Id, outgoing: p.Id) Error!p.Id {
    return builder.term(.{ .perform = .{ .effect = definition.effect, .capability = capability, .payload = outgoing } });
}

/// Consume the old endpoint package and return its successor or completion.
pub fn exchange(builder: *source.Builder, definition: Generator, package: p.Id, input: p.Id) Error!p.Id {
    return builder.term(.{ .resume_value = .{ .resumption = try builder.primitive(definition.resumption, .unpack, &.{package}, 0), .argument = input } });
}

/// A derived sequential pipeline. Construction emits code only; start consumes
/// both running packages and its first input. Later exchange/close use generator.
pub const Pipeline = struct { generator: *const Exchange, start: *const a.Function };
const PipelineCache = struct { identity: []const u8, right: *const Exchange, value: Pipeline };

/// Compose two checked exchanges in the same authoring context. Repeated
/// construction of the same named pair shares one generated pipeline.
pub fn pipeline(c: *a.Context, identity: []const u8, left: *const Exchange, right: *const Exchange) a.Error!Pipeline {
    const l = exchangeData(left);
    const r = exchangeData(right);
    if (l.owner != c or r.owner != c) return error.ForeignHandle;
    const left_ids = try l.sourceIds(c);
    const right_ids = try r.sourceIds(c);
    if (left_ids.element != right_ids.input or left_ids.result != right_ids.result) return error.TypeMismatch;
    for (l.pipelines.items) |cached| {
        if (cached.right == right and std.mem.eql(u8, cached.identity, identity)) return cached.value;
    }
    const b = a.interop.builder(c);
    const lr = b.schemas.items[@intCast(left_ids.resumption)].internal.resumption;
    const rr = b.schemas.items[@intCast(right_ids.resumption)].internal.resumption;
    const effects = try (source.Row{ .effects = lr.effects }).unionWith(b.allocator(), .{ .effects = rr.effects });
    const owned = try unionRegions(b, lr.owned_regions, rr.owned_regions);
    const borrowed = try unionRegions(b, try borrowedRegions(b, left_ids), try borrowedRegions(b, right_ids));
    const result = try composeIn(c, identity, endpoint(l), endpoint(r), effects, owned, borrowed);
    try l.pipelines.append(b.allocator(), .{ .identity = try b.allocator().dupe(u8, identity), .right = right, .value = result });
    return result;
}

const Endpoint = struct { input: *const a.Schema, element: *const a.Schema, result: *const a.Schema, package: *const a.Schema };
fn endpoint(value: *const ExchangeData) Endpoint {
    return .{ .input = value.input, .element = value.element, .result = value.result, .package = value.package };
}
fn composeIn(c: *a.Context, identity: []const u8, left: Endpoint, right: Endpoint, residual: source.Row, owned_regions: []const p.Id, borrowed_regions: []const p.Id) a.Error!Pipeline {
    const lp = left.package;
    const rp = right.package;
    const input = left.input;
    const result = left.result;
    const element = right.element;
    const left_answer_schema = (lp.resultSchema() orelse return error.InvalidCategory).resultSchema() orelse return error.InvalidSchema;
    const right_answer_schema = (rp.resultSchema() orelse return error.InvalidCategory).resultSchema() orelse return error.InvalidSchema;
    if (left_answer_schema.fields().len != 2 or right_answer_schema.fields().len != 2) return error.InvalidSchema;
    const left_parts_schema = left_answer_schema.fields()[1].schema;
    const right_parts_schema = right_answer_schema.fields()[1].schema;
    if (left_parts_schema.fields().len != 2 or right_parts_schema.fields().len != 2) return error.InvalidSchema;
    const effects = try operations(c, residual.effects);
    const borrowed = try regionHandles(c, borrowed_regions);
    const parameters = &[_]a.Field{ .{ .name = "left", .schema = lp }, .{ .name = "right", .schema = rp }, .{ .name = "input", .schema = input } };
    const generated = try makeExchange(c, identity, input, element, result, &.{ lp, rp, input, left.element, element, result, try c.scalar(void) }, try regionHandles(c, owned_regions), borrowed, effects, parameters, &.{}, .linear);
    const g = exchangeData(generated);
    const loop_schema = try c.handledSchema(g.handler);
    const loop_fn = try c.functionFor("exchange pipeline", loop_schema);
    const loop = try c.body(loop_fn);
    const capability = try loop.parameter("capability");
    const right_package = try loop.parameter("right");
    const left_answer = try loop.resumeValue(try loop.unpack(try loop.parameter("left")), try loop.parameter("input"));
    const left_done = try loop.caseOf(left_answer, left_answer_schema.fields()[0].name);
    _ = try left_done.body().dispose(try left_done.body().unpack(right_package));
    const left_yield = try loop.caseOf(left_answer, left_answer_schema.fields()[1].name);
    const left_parts = try left_yield.body().destructure(left_yield.payload());
    const next_left = try left_parts.get(left_parts_schema.fields()[1].name);
    const right_answer = try left_yield.body().resumeValue(try left_yield.body().unpack(right_package), try left_parts.get(left_parts_schema.fields()[0].name));
    const right_done = try left_yield.body().caseOf(right_answer, right_answer_schema.fields()[0].name);
    _ = try right_done.body().dispose(try right_done.body().unpack(next_left));
    const right_yield = try left_yield.body().caseOf(right_answer, right_answer_schema.fields()[1].name);
    const right_parts = try right_yield.body().destructure(right_yield.payload());
    const next_input = try right_yield.body().performLocal(g.effect, capability, try right_parts.get(right_parts_schema.fields()[0].name));
    const continued = try right_yield.body().call(loop_fn, &.{ .{ .name = "capability", .value = capability }, .{ .name = "left", .value = next_left }, .{ .name = "right", .value = try right_parts.get(right_parts_schema.fields()[1].name) }, .{ .name = "input", .value = next_input } });
    const after_right = try left_yield.body().match(right_answer, &.{ try right_done.ret(right_done.payload()), try right_yield.ret(continued) });
    try c.define(loop_fn, try loop.ret(try loop.match(left_answer, &.{ try left_done.ret(left_done.payload()), try left_yield.ret(after_right) })));
    const entry_schema = try c.callable(parameters, g.answer, effects, .{ .use = .linear, .captures = &.{}, .regions = borrowed });
    const entry_fn = try c.functionFor("start exchange pipeline", entry_schema);
    const entry = try c.body(entry_fn);
    try c.define(entry_fn, try entry.ret(try entry.handleWithArguments(g.handler, try entry.lambda(loop_fn, loop_schema), &.{
        .{ .name = "left", .value = try entry.parameter("left") },   .{ .name = "right", .value = try entry.parameter("right") },
        .{ .name = "input", .value = try entry.parameter("input") },
    }, &.{})));
    return .{ .generator = generated, .start = entry_fn };
}

fn borrowedRegions(b: *source.Builder, g: Generator) Error![]const p.Id {
    if (g.handler >= b.handlers.items.len) return error.InvalidReference;
    const function = b.handlers.items[@intCast(g.handler)].return_function;
    if (function >= b.functions.items.len) return error.InvalidReference;
    return b.functions.items[@intCast(function)].regions;
}
fn unionRegions(b: *source.Builder, left: []const p.Id, right: []const p.Id) Error![]const p.Id {
    var values: std.ArrayList(p.Id) = .empty;
    try values.appendSlice(b.allocator(), left);
    try values.appendSlice(b.allocator(), right);
    std.mem.sort(p.Id, values.items, {}, std.sort.asc(p.Id));
    var count: usize = 0;
    for (values.items) |id| if (count == 0 or values.items[count - 1] != id) {
        values.items[count] = id;
        count += 1;
    };
    values.items.len = count;
    return values.toOwnedSlice(b.allocator());
}

test "typed exchange pipelines preserve ownership, compatibility and definition sharing" {
    const testing = std.testing;
    try testing.expect(@typeInfo(Exchange) == .@"opaque");
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const integer = try c.scalar(u64);
    const boolean = try c.scalar(bool);
    const options: Options = .{ .captures = .{ .continuation = &.{integer} } };
    const left = try create(c, "typed/left", integer, integer, integer, options);
    const right = try create(c, "typed/right", integer, integer, integer, options);
    const joined = try pipeline(c, "typed/pair", left, right);
    const functions = b.functions.items.len;
    const repeated = try pipeline(c, "typed/pair", left, right);
    try testing.expect(joined.generator == repeated.generator);
    try testing.expect(joined.start == repeated.start);
    try testing.expectEqual(functions, b.functions.items.len);
    _ = try pipeline(c, "typed/three", joined.generator, right);
    const wrong_input = try create(c, "typed/input", boolean, integer, integer, options);
    try testing.expectError(error.TypeMismatch, pipeline(c, "typed/bad-input", left, wrong_input));
    const wrong_result = try create(c, "typed/result", integer, integer, boolean, options);
    try testing.expectError(error.TypeMismatch, pipeline(c, "typed/bad-result", left, wrong_result));
    const foreign = try a.Context.init(&b);
    try testing.expectError(error.ForeignHandle, pipeline(foreign, "typed/foreign", left, right));
    // Pipeline start consumes owned packages, so its public artifact is a
    // callable component, not a byte-input/byte-result Program entry.
    var compiled = try source.component.compileObserved(testing.allocator, b.module(try a.interop.functionId(c, joined.start), try a.interop.schemaId(c, try c.scalar(void))), .{
        .exports = &.{.{ .name = "start", .reference = .{ .kind = .function, .id = try a.interop.functionId(c, joined.start) } }},
    }, .{});
    defer compiled.deinit();
}
