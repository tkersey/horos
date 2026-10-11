const std = @import("std");
const horos = @import("../root.zig");
const source = horos.source;
const choice = horos.library.choice;
const typed = horos.authoring;
const ChoiceOperation = struct { effect: Id, capability: Id };
const cleanup = horos.library.cleanup;
const Id = horos.data.program.Id;
const Mode = enum { handler_state, edge, unit_state };
const Resource = struct { owned: Id, borrowed: Id, loan: Id, acquire: Id, finalizer: Id, info: Id };

fn resource(b: *source.Builder, unit: Id) !Resource {
    const owned = try b.resource(unit);
    const loan = b.region();
    const borrowed = try b.schema(.{ .internal = .{
        .borrowed = .{ .value = owned, .region = loan },
    } });
    const acquire = try b.declare(&.{}, owned, &.{}, &.{});
    const info = try cleanup.exitInfo(b, unit);
    const finalizer = try b.declare(&.{ info, owned }, unit, &.{}, &.{});
    try b.resourceAuthority(owned, &.{acquire}, &.{finalizer});
    const owned_value = try b.primitive(owned, .resource_pack, &.{try b.constant(void, {})}, 0);
    try b.define(acquire, try b.pure(owned_value));
    const value = try b.reference(b.parameter(finalizer, 1));
    try b.define(finalizer, try b.pure(try b.primitive(unit, .resource_unpack, &.{value}, 0)));
    return .{
        .owned = owned,
        .borrowed = borrowed,
        .loan = loan,
        .acquire = acquire,
        .finalizer = finalizer,
        .info = info,
    };
}

fn closure(
    b: *source.Builder,
    function: Id,
    parameters: []const Id,
    result: Id,
    effects: []const Id,
    regions: []const Id,
) !Id {
    const schema = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = parameters,
        .result = result,
        .effects = effects,
        .regions = regions,
    } } });
    return b.lambda(function, schema);
}

fn innerBody(b: *source.Builder, r: Resource, c: ChoiceOperation, unit: Id, mode: Mode) !Id {
    const inside = try b.declare(&.{ c.capability, r.borrowed }, unit, &.{c.effect}, &.{r.loan});
    const chosen = try b.variable(try b.scalar(bool));
    const operation = try b.term(.{ .perform = .{
        .effect = c.effect,
        .capability = try b.reference(b.parameter(inside, 0)),
        .payload = try b.constant(void, {}),
    } });
    const sink = try b.declare(&.{r.borrowed}, unit, &.{}, &.{r.loan});
    try b.define(sink, try b.pure(try b.constant(void, {})));
    const after = if (mode == .edge)
        try b.term(.{ .call = .{
            .function = sink,
            .arguments = &.{try b.reference(b.parameter(inside, 1))},
        } })
    else
        try b.pure(try b.constant(void, {}));
    try b.define(inside, try b.bind(chosen, operation, after));
    return closure(b, inside, &.{ c.capability, r.borrowed }, unit, &.{c.effect}, &.{r.loan});
}

fn outerBody(b: *source.Builder, r: Resource, c: ChoiceOperation, unit: Id, mode: Mode) !Id {
    const state = if (mode == .handler_state) r.borrowed else unit;
    const returns = try b.declare(&.{ state, unit }, unit, &.{}, &.{r.loan});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const inner = try b.handler(.{
        .mode = .deep,
        .input = unit,
        .answer = unit,
        .return_function = returns,
        .state = &.{state},
        .clauses = &.{},
    });
    const outer = try b.declare(&.{ c.capability, r.borrowed }, unit, &.{c.effect}, &.{r.loan});
    const borrowed = try b.reference(b.parameter(outer, 1));
    try b.define(outer, try b.term(.{ .handle = .{
        .handler = inner,
        .body = try innerBody(b, r, c, unit, mode),
        .arguments = &.{ try b.reference(b.parameter(outer, 0)), borrowed },
        .state = &.{if (mode == .handler_state) borrowed else try b.constant(void, {})},
    } }));
    return closure(b, outer, &.{ c.capability, r.borrowed }, unit, &.{c.effect}, &.{r.loan});
}

fn program(b: *source.Builder, mode: Mode) !source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const sequence = try b.schema(.{ .seq = unit });
    const r = try resource(b, unit);
    const author = try typed.Context.init(b);
    const family = try choice.family(author, "test/outer-choice");
    const c: ChoiceOperation = .{ .effect = try typed.interop.operationId(author, family.effect()), .capability = try typed.interop.schemaId(author, family.capability()) };
    const capture_ids = [_]Id{ unit, boolean, sequence, c.capability };
    var captures: [capture_ids.len]*const typed.Schema(typed.Dynamic) = undefined;
    for (capture_ids, &captures) |id, *schema| schema.* = try typed.interop.schema(author, id);
    const interpreted = try choice.all(author, family, try author.schema(void), .{ .captures = .{ .continuation = &captures }, .residual = &.{}, .borrowed_regions = &.{try typed.interop.region(author, r.loan)} });
    const all = .{ .handler = try typed.interop.handlerId(author, interpreted.handler) };
    const protected_body = try b.declare(&.{r.borrowed}, sequence, &.{}, &.{r.loan});
    try b.define(protected_body, try b.term(.{ .handle = .{
        .handler = all.handler,
        .body = try outerBody(b, r, c, unit, mode),
        .arguments = &.{try b.reference(b.parameter(protected_body, 0))},
    } }));
    const entry = try b.declare(&.{}, sequence, &.{}, &.{});
    const owned = try b.variable(r.owned);
    const body = try closure(b, protected_body, &.{r.borrowed}, sequence, &.{}, &.{r.loan});
    const finalizer = try closure(b, r.finalizer, &.{ r.info, r.owned }, unit, &.{}, &.{});
    const protected = try b.term(.{ .protect = .{ .resource = try b.reference(owned), .loan_region = r.loan, .body = body, .cleanup = finalizer } });
    const acquired = try b.term(.{ .call = .{ .function = r.acquire, .arguments = &.{} } });
    try b.define(entry, try b.bind(owned, acquired, protected));
    return b.module(entry, unit);
}

test "multi capture checks protected borrows in handler state and continuation edges" {
    for ([_]Mode{ .handler_state, .edge }) |mode| {
        var b = source.Builder.init(std.testing.allocator);
        defer b.deinit();
        const module = try program(&b, mode);
        try std.testing.expectError(
            error.InvalidOwnership,
            horos.program.compile(std.testing.allocator, module),
        );
    }
}

test "multi capture permits safe handler state inside a protected resource scope" {
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const module = try program(&b, .unit_state);
    var compiled = try horos.program.compile(std.testing.allocator, module);
    defer compiled.deinit();
}
