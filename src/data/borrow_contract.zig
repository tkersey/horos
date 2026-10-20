// Copyright (c) 2026 Boundary contributors. MIT license.
//! Component assume/guarantee contracts over the borrow solver's input vocabulary.
//! Returned and written sources are conservative whole-result bounds. Requirements
//! retain both projections exactly: widening an owner would change its lifetime.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const flow = @import("borrow_flow.zig");
const a = @import("admission.zig");
const relocate = @import("relocation.zig");
const equal = @import("record.zig").equal;

pub const Projection = struct {
    source: union(enum) { input: p.Id, ambient: flow.Ambient },
    path: []const flow.Step = &.{},
};
pub const Requirement = struct { value: Projection, owner: Projection, bound: flow.Bound };
pub const Write = struct { schema: p.Id, sources: []const Projection };
pub const Summary = struct {
    function: p.Id,
    returned: []const Projection = &.{},
    requirements: []const Requirement = &.{},
    writes: []const Write = &.{},
};

pub fn validate(solver: anytype, summary: Summary) a.Error!void {
    if (summary.function >= solver.program.functions.len) return error.InvalidReference;
    for (summary.returned) |source| _ = try solver.contractSource(summary.function, source);
    for (summary.requirements) |pair| {
        _ = try solver.contractSource(summary.function, pair.value);
        _ = try solver.contractSource(summary.function, pair.owner);
    }
    var previous: ?p.Id = null;
    for (summary.writes) |write| {
        if (write.schema >= solver.program.schemas.len) return error.InvalidReference;
        const shape = solver.program.schemas[@intCast(write.schema)];
        if (shape != .internal or shape.internal != .cell) return error.InvalidSchema;
        if (previous) |prior| if (write.schema <= prior) return error.NonCanonical;
        previous = write.schema;
        for (write.sources) |source| _ = try solver.contractSource(summary.function, source);
    }
}

fn describe(solver: anytype, source: flow.Source) a.Error!Projection {
    if (source.stable_slot) return error.InvalidProgram;
    var path: std.ArrayList(flow.Step) = .empty;
    var cursor = source.path;
    while (cursor != 0) {
        const item = solver.paths.items[cursor - 1];
        try path.append(solver.allocator, item.step);
        cursor = item.tail;
    }
    return .{
        .source = if (source.ambient) |ambient|
            .{ .ambient = ambient }
        else
            .{ .input = source.parameter },
        .path = try path.toOwnedSlice(solver.allocator),
    };
}

fn sources(solver: anytype, values: []const flow.Source) a.Error![]const Projection {
    const result = try solver.allocator.alloc(Projection, values.len);
    for (result, values) |*out, value| out.* = try describe(solver, value);
    return result;
}

/// Infer from actual first-order code under already validated imported contracts.
/// The caller supplies an arena; no returned projection borrows solver arrays.
pub fn infer(solver: anytype, function: p.Id) a.Error!Summary {
    const start = solver.entry(function);
    const returned = try sources(solver, try solver.returned(start));
    const pairs = try solver.required(start);
    const requirements = try solver.allocator.alloc(Requirement, pairs.len);
    for (requirements, pairs) |*out, pair| out.* = .{
        .value = try describe(solver, pair.value),
        .owner = try describe(solver, pair.owner),
        .bound = pair.bound,
    };
    var writes: std.ArrayList(Write) = .empty;
    for (solver.program.schemas, 0..) |schema, id| {
        if (schema != .internal or schema.internal != .cell) continue;
        const values = try solver.written(start, id);
        if (values.len == 0) continue;
        try writes.append(
            solver.allocator,
            .{ .schema = id, .sources = try sources(solver, values) },
        );
    }
    return .{
        .function = function,
        .returned = returned,
        .requirements = requirements,
        .writes = try writes.toOwnedSlice(solver.allocator),
    };
}

fn contains(bound: []const Projection, actual: Projection) bool {
    for (bound) |declared| {
        if (!equal(@TypeOf(actual.source), declared.source, actual.source)) continue;
        if (declared.path.len > actual.path.len) continue;
        if (equal([]const flow.Step, declared.path, actual.path[0..declared.path.len])) return true;
    }
    return false;
}

pub fn check(solver: anytype, declared: Summary) a.Error!void {
    try validate(solver, declared);
    const actual = try infer(solver, declared.function);
    for (actual.returned) |value| if (!contains(declared.returned, value))
        return error.InvalidOwnership;
    for (actual.requirements) |pair| {
        for (declared.requirements) |allowed| {
            if (equal(Requirement, pair, allowed)) break;
        } else return error.InvalidOwnership;
    }
    for (actual.writes) |write| {
        for (declared.writes) |allowed| {
            if (allowed.schema != write.schema) continue;
            for (write.sources) |value| if (!contains(allowed.sources, value))
                return error.InvalidOwnership;
            break;
        } else return error.InvalidOwnership;
    }
}

fn projection(mapper: relocate.Mapper, value: Projection) a.Error!Projection {
    const path = try mapper.allocator.dupe(flow.Step, value.path);
    for (path) |*step| switch (step.*) {
        .environment => |*v| v.constructor = try mapper.id(.constructor, v.constructor),
        .handler_state => |*v| v.handler = try mapper.id(.handler, v.handler),
        .use_site => |*v| v.schema = try mapper.id(.schema, v.schema),
        .body_result => |*v| v.* = try mapper.id(.schema, v.*),
        else => {},
    };
    return .{ .source = value.source, .path = path };
}

fn projections(mapper: relocate.Mapper, values: []const Projection) a.Error![]const Projection {
    const result = try mapper.allocator.alloc(Projection, values.len);
    for (result, values) |*out, value| out.* = try projection(mapper, value);
    return result;
}

pub fn relocated(mapper: relocate.Mapper, value: Summary) a.Error!Summary {
    const requirements = try mapper.allocator.alloc(Requirement, value.requirements.len);
    for (requirements, value.requirements) |*out, pair| out.* = .{
        .value = try projection(mapper, pair.value),
        .owner = try projection(mapper, pair.owner),
        .bound = pair.bound,
    };
    const writes = try mapper.allocator.alloc(Write, value.writes.len);
    for (writes, value.writes) |*out, write| out.* = .{
        .schema = try mapper.id(.schema, write.schema),
        .sources = try projections(mapper, write.sources),
    };
    // Schema unification can merge write targets; comparison accepts their union.
    std.mem.sort(Write, writes, {}, struct {
        fn less(_: void, left: Write, right: Write) bool {
            return left.schema < right.schema;
        }
    }.less);
    var count: usize = 0;
    for (writes) |write| {
        if (count != 0 and writes[count - 1].schema == write.schema) {
            const prior = &writes[count - 1];
            const joined = try mapper.allocator.alloc(
                Projection,
                prior.sources.len + write.sources.len,
            );
            @memcpy(joined[0..prior.sources.len], prior.sources);
            @memcpy(joined[prior.sources.len..], write.sources);
            prior.sources = joined;
        } else {
            writes[count] = write;
            count += 1;
        }
    }
    return .{
        .function = try mapper.id(.function, value.function),
        .returned = try projections(mapper, value.returned),
        .requirements = requirements,
        .writes = writes[0..count],
    };
}
