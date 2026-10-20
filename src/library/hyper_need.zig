// Copyright (c) 2026 Boundary contributors. MIT license.
//! Internal partner requests interpreted by the ordinary algebraic-effect machinery.
const source = @import("../source.zig");
const hyper = @import("hyper.zig");
const Id = source.Id;

pub const Family = struct { effect: Id, capability: Id, state: Id, contribution: Id };
pub const Interpretation = struct { handler: Id, body: Id, resumption: Id };
pub const Options = struct {
    captures: []const Id = &.{},
    residual: source.Row = .{ .effects = &.{} },
    regions: []const Id = &.{},
    obligations: bool = false,
};

/// Each call creates a nominal family. Its explicit lexical capability selects
/// the defining handler even when another same-shaped family is nested nearby.
pub fn family(
    b: *source.Builder,
    identity: []const u8,
    state: Id,
    contribution: Id,
) source.Error!Family {
    if (state >= b.schemas.items.len or contribution >= b.schemas.items.len)
        return error.InvalidReference;
    const effect = try b.effect(.{
        .identity = identity,
        .payload = state,
        .result = contribution,
        .external = false,
    });
    return .{
        .effect = effect,
        .state = state,
        .contribution = contribution,
        .capability = try b.schema(.{ .internal = .{ .capability = effect } }),
    };
}

pub fn request(b: *source.Builder, need: Family, capability: Id, next_state: Id) source.Error!Id {
    return b.term(.{ .perform = .{
        .effect = need.effect,
        .capability = capability,
        .payload = next_state,
    } });
}

/// Interpret Need<S,A> by demanding the counterpart task and returning its actual
/// result to the waiting one-shot continuation. The query's maker preserves the
/// current participant at the requested successor state. No host routing occurs.
pub fn interpret(
    b: *source.Builder,
    query: hyper.Query,
    need: Family,
    result: Id,
    options: Options,
) source.Error!Interpretation {
    return interpretWith(b, query, need, result, options, Resume);
}

/// Choose the disposition of the actual owned requester after its counterpart
/// returns. Completion is staged code; it must consume the linear resumption by
/// resuming or disposing it. It cannot replace the saved caller with host state.
pub fn interpretWith(
    b: *source.Builder,
    query: hyper.Query,
    need: Family,
    result: Id,
    options: Options,
    comptime Completion: type,
) source.Error!Interpretation {
    if (result >= b.schemas.items.len) return error.InvalidReference;
    const task = try returned(b, query.types.answer_backward);
    if (try returned(b, task) != need.contribution) return error.TypeMismatch;
    const bound = try b.allocator().alloc(Id, options.captures.len + 2);
    @memcpy(bound[0..options.captures.len], options.captures);
    bound[options.captures.len] = need.capability;
    bound[options.captures.len + 1] = query.types.peer_backward;
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = need.effect,
        .input = need.contribution,
        .answer = result,
        .effects = options.residual.effects,
        .handled = &.{need.effect},
        .capture_bound = bound,
        .mode = .deep,
        .use = .linear,
        .obligations = options.obligations,
    } } });
    const returns = try b.declare(
        &.{ query.types.peer_backward, result },
        result,
        &.{},
        options.regions,
    );
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 1))));
    const clause = try b.declare(
        &.{ query.types.peer_backward, need.state, token },
        result,
        options.residual.effects,
        options.regions,
    );
    try clauseBody(b, query, clause, task, Completion);
    const row = try options.residual.unionWith(b.allocator(), .{ .effects = &.{need.effect} });
    const body = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{need.capability},
        .result = result,
        .effects = row.effects,
        .use = .linear,
        .regions = options.regions,
        .capture_bound = options.captures,
    } } });
    const handler = try b.handler(.{
        .mode = .deep,
        .input = result,
        .answer = result,
        .return_function = returns,
        .effects = options.residual.effects,
        .state = &.{query.types.peer_backward},
        .clauses = &.{.{ .effect = need.effect, .function = clause, .resumption = token }},
    });
    return .{ .handler = handler, .body = body, .resumption = token };
}

fn returned(b: *source.Builder, id: Id) source.Error!Id {
    if (id >= b.schemas.items.len) return error.InvalidReference;
    const schema = b.schemas.items[@intCast(id)];
    if (schema != .internal or schema.internal != .computation or
        schema.internal.computation.parameters.len != 0) return error.TypeMismatch;
    return schema.internal.computation.result;
}

const Resume = struct {
    pub fn emit(b: *source.Builder, token: Id, contribution: Id) source.Error!Id {
        return b.term(.{ .resume_value = .{ .resumption = token, .argument = contribution } });
    }
};

fn clauseBody(
    b: *source.Builder,
    original: hyper.Query,
    clause: Id,
    task: Id,
    comptime Completion: type,
) source.Error!void {
    var query = original;
    query.peer = try b.reference(b.parameter(clause, 0));
    const delayed = try b.variable(query.types.answer_backward);
    const selected = try b.variable(task);
    const contribution = try b.variable(try returned(b, task));
    const resumed = try Completion.emit(
        b,
        try b.reference(b.parameter(clause, 2)),
        try b.reference(contribution),
    );
    try b.define(
        clause,
        try b.bind(
            delayed,
            try query.ask(b, try b.reference(b.parameter(clause, 1))),
            try b.bind(
                selected,
                try hyper.force(b, try b.reference(delayed)),
                try b.bind(contribution, try hyper.force(b, try b.reference(selected)), resumed),
            ),
        ),
    );
}

pub fn handle(
    b: *source.Builder,
    interpretation: Interpretation,
    peer: Id,
    body: Id,
) source.Error!Id {
    return b.term(.{ .handle = .{
        .handler = interpretation.handler,
        .body = body,
        .state = &.{peer},
    } });
}

test "hyper demand families retain nominal identity despite equal display names" {
    const std = @import("std");
    var b = source.Builder.init(std.testing.allocator);
    defer b.deinit();
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    try std.testing.expectError(
        error.InvalidReference,
        family(&b, "invalid", b.schemas.items.len, unit),
    );
    const left = try family(&b, "same-name", boolean, unit);
    const right = try family(&b, "same-name", boolean, unit);
    try std.testing.expect(left.effect != right.effect);
    try std.testing.expect(left.capability != right.capability);
    const entry = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(entry, try b.pure(try b.constant(void, {})));
    const helper = try b.declare(&.{left.capability}, unit, &.{right.effect}, &.{});
    try b.define(
        helper,
        try request(
            &b,
            right,
            try b.reference(b.parameter(helper, 0)),
            try b.constant(bool, true),
        ),
    );
    try std.testing.expectError(
        error.TypeMismatch,
        source.lower(std.testing.allocator, b.module(entry, unit)),
    );
}
