// Copyright (c) 2026 Boundary contributors. MIT license.
//! A later operand failure must unwind every still-owned earlier operand.
const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;
const Fixtures = @import("custody_order_example.zig").Fixtures;
const cleanup = @import("library/cleanup.zig");
const Kind = enum {
    call_arguments,
    instruction_order,
    capture_order,
    apply_arguments,
    apply_computation,
    protect_arguments,
    region_arguments,
    same_scope_instruction,
    returned_instruction,
    affine_scope,
    reusable_scope,
};
pub const count = std.enums.values(Kind).len;

pub fn build(b: *source.Builder, fixtures: Fixtures, index: usize) source.Error!p.Id {
    const kind: Kind = @fromBackingInt(@intCast(index));
    const integer = try b.scalar(u64);
    const failed = try b.term(.{ .fail = try b.constant(u64, 8) });
    const helper = try b.declare(
        &.{ fixtures.package, fixtures.package },
        integer,
        &.{fixtures.release},
        &.{},
    );
    const first = try b.reference(b.parameter(helper, 0));
    const second = try b.reference(b.parameter(helper, 1));
    const body = switch (kind) {
        .instruction_order, .same_scope_instruction, .returned_instruction => blk: {
            break :blk try instruction(b, fixtures, kind, first, second, failed);
        },
        .capture_order => try capture(b, fixtures, first, second, failed),
        .apply_computation => try computation(b, fixtures, second, failed),
        .affine_scope, .reusable_scope => try markerScope(b, fixtures, kind, second, failed),
        else => try arguments(b, fixtures, kind, first, failed),
    };
    try b.define(helper, body);
    const entry = try b.declare(&.{}, integer, &.{fixtures.release}, &.{});
    const older = try b.variable(fixtures.package);
    const younger = try b.variable(fixtures.package);
    const call = try b.term(.{ .call = .{ .function = helper, .arguments = &.{
        try b.reference(older), try b.reference(younger),
    } } });
    const first_call = try b.term(.{ .call = .{
        .function = fixtures.factory,
        .arguments = &.{try b.constant(u64, 1)},
    } });
    const second_call = try b.term(.{ .call = .{
        .function = fixtures.factory,
        .arguments = &.{try b.constant(u64, 2)},
    } });
    try b.define(entry, try b.bind(older, first_call, try b.bind(younger, second_call, call)));
    return entry;
}

fn markerScope(
    b: *source.Builder,
    f: Fixtures,
    kind: Kind,
    second: p.Id,
    failed: p.Id,
) source.Error!p.Id {
    const unit = try b.scalar(void);
    const function = try b.declare(&.{}, unit, &.{}, &.{});
    try b.define(function, try b.pure(try b.constant(void, {})));
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = unit,
        .use = if (kind == .affine_scope) .affine else .reusable,
    } } });
    const body = try instruction(b, f, .same_scope_instruction, second, second, failed);
    return b.bind(try b.variable(signature), try b.pure(try b.lambda(function, signature)), body);
}

fn overflow(b: *source.Builder, left: p.Id) source.Error!p.Id {
    return b.value(.{ .schema = try b.scalar(u64), .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ left, try b.constant(u64, std.math.maxInt(u64)) },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(u64, 8)),
        }},
    } } });
}

fn instruction(
    b: *source.Builder,
    f: Fixtures,
    kind: Kind,
    first: p.Id,
    second: p.Id,
    failed: p.Id,
) source.Error!p.Id {
    const integer = try b.scalar(u64);
    const held = try b.variable(f.package);
    const value = if (kind == .same_scope_instruction) first else try b.reference(held);
    const moved = try b.primitive(f.package, .move, &.{value}, 0);
    const sum = try b.schema(.{ .sum = &.{ try b.scalar(void), f.package } });
    const wrapped = try b.primitive(sum, .variant, &.{moved}, 1);
    const tag = try b.primitive(integer, .variant_tag, &.{wrapped}, 0);
    const observed = try b.pure(if (kind == .returned_instruction) tag else try overflow(b, tag));
    if (kind == .same_scope_instruction)
        return b.bind(try b.variable(integer), observed, failed);
    const inner = try b.bind(held, try b.pure(second), observed);
    return b.bind(try b.variable(integer), inner, failed);
}

fn capture(
    b: *source.Builder,
    f: Fixtures,
    first: p.Id,
    second: p.Id,
    failed: p.Id,
) source.Error!p.Id {
    const integer = try b.scalar(u64);
    const sink = try b.declare(&.{ f.package, f.package }, integer, &.{f.release}, &.{});
    try b.define(sink, failed);
    const closure = try b.declare(&.{}, integer, &.{f.release}, &.{});
    const later = try b.term(.{ .call = .{ .function = sink, .arguments = &.{ second, first } } });
    try b.define(closure, try b.bind(try b.variable(integer), failed, later));
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = integer,
        .effects = &.{f.release},
        .capture_bound = &.{f.package},
        .use = .linear,
    } } });
    return b.term(.{ .apply = .{
        .computation = try b.lambda(closure, signature),
        .arguments = &.{},
    } });
}

fn computation(
    b: *source.Builder,
    f: Fixtures,
    second: p.Id,
    failed: p.Id,
) source.Error!p.Id {
    const integer = try b.scalar(u64);
    const held = try b.variable(f.package);
    const closure = try b.declare(&.{integer}, integer, &.{f.release}, &.{});
    const sink = try b.declare(&.{f.package}, integer, &.{f.release}, &.{});
    try b.define(sink, failed);
    const later = try b.term(.{ .call = .{
        .function = sink,
        .arguments = &.{try b.reference(held)},
    } });
    try b.define(closure, try b.bind(try b.variable(integer), failed, later));
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{integer},
        .result = integer,
        .effects = &.{f.release},
        .capture_bound = &.{f.package},
        .use = .linear,
    } } });
    const apply = try b.term(.{ .apply = .{
        .computation = try b.lambda(closure, signature),
        .arguments = &.{try overflow(b, try b.constant(u64, 1))},
    } });
    return b.bind(held, try b.pure(second), try b.bind(try b.variable(integer), apply, failed));
}

fn arguments(
    b: *source.Builder,
    f: Fixtures,
    kind: Kind,
    first: p.Id,
    failed: p.Id,
) source.Error!p.Id {
    const integer = try b.scalar(u64);
    const region = if (kind == .region_arguments) b.region() else 0;
    const region_type = if (kind == .region_arguments)
        try b.schema(.{ .internal = .{ .region = region } })
    else
        try b.scalar(void);
    const parameters: []const p.Id = if (kind == .region_arguments)
        &.{ region_type, f.package, integer }
    else
        &.{ f.package, integer };
    const regions: []const p.Id = if (kind == .region_arguments) &.{region} else &.{};
    const body = try b.declare(parameters, integer, &.{f.release}, regions);
    try b.define(body, failed);
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = parameters,
        .result = integer,
        .effects = &.{f.release},
        .regions = regions,
    } } });
    const args = &.{ first, try overflow(b, try b.constant(u64, 1)) };
    const operation = switch (kind) {
        .call_arguments => try b.term(.{ .call = .{ .function = body, .arguments = args } }),
        .apply_arguments => try b.term(.{ .apply = .{
            .computation = try b.lambda(body, signature),
            .arguments = args,
        } }),
        .region_arguments => try b.term(.{ .with_region = .{
            .region = region,
            .body = try b.lambda(body, signature),
            .arguments = args,
        } }),
        .protect_arguments => blk: {
            const exit = try cleanup.exitInfo(b, integer);
            const unit = try b.scalar(void);
            const finalizer = try b.declare(&.{exit}, unit, &.{}, &.{});
            try b.define(finalizer, try b.pure(try b.constant(void, {})));
            const finalizer_type = try b.schema(.{ .internal = .{ .computation = .{
                .parameters = &.{exit},
                .result = unit,
                .effects = &.{},
            } } });
            break :blk try b.term(.{ .protect = .{
                .body = try b.lambda(body, signature),
                .cleanup = try b.lambda(finalizer, finalizer_type),
                .arguments = args,
            } });
        },
        else => return error.InvalidSource,
    };
    return b.bind(try b.variable(integer), operation, failed);
}
