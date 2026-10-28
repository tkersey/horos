// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked source inputs for cleanup crossing a suspended handler scope.
const std = @import("std");
const horos = @import("horos");
const Builder = horos.source.Builder;
const Id = horos.data.program.Id;
const Mode = enum { yielding, requesting, disposing };
const Handler = struct { id: Id, capability: Id };

fn handler(b: *Builder, unit: Id, boolean: Id, effect: Id, pause: Id) !Handler {
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = effect,
        .input = unit,
        .answer = unit,
        .effects = &.{pause},
        .handled = &.{effect},
        .capture_bound = &.{ unit, boolean, cap },
        .mode = .deep,
        .use = .linear,
        .obligations = true,
    } } });
    const returns = try b.declare(&.{unit}, unit, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ boolean, token }, unit, &.{pause}, &.{});
    const resuming = try b.term(.{ .resume_value = .{
        .resumption = try b.reference(b.parameter(clause, 1)),
        .argument = try b.constant(void, {}),
    } });
    const disposing = try b.term(.{ .dispose = try b.reference(b.parameter(clause, 1)) });
    try b.define(clause, try b.term(.{ .conditional = .{
        .condition = try b.reference(b.parameter(clause, 0)),
        .when_true = resuming,
        .when_false = disposing,
    } }));
    const id = try b.handler(.{
        .mode = .deep,
        .input = unit,
        .answer = unit,
        .effects = &.{pause},
        .return_function = returns,
        .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }},
    });
    return .{ .id = id, .capability = cap };
}

fn scenario(b: *Builder, mode: Mode) !horos.source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const effect = try b.effect(.{
        .identity = "regression/cleanup-scope",
        .payload = boolean,
        .result = unit,
        .external = false,
    });
    const pause = try b.effect(.{
        .identity = "regression/cleanup-pause",
        .payload = unit,
        .result = unit,
    });
    const h = try handler(b, unit, boolean, effect, pause);
    const outer = try b.declare(&.{h.capability}, unit, &.{ effect, pause }, &.{});
    const body = try b.declare(&.{}, unit, &.{ effect, pause }, &.{});
    const position = switch (mode) {
        .yielding => try b.term(.{ .yield_then = try b.pure(try b.constant(void, {})) }),
        .requesting => try b.term(.{ .perform = .{
            .effect = pause,
            .payload = try b.constant(void, {}),
        } }),
        .disposing => try b.term(.{ .perform = .{
            .effect = effect,
            .capability = try b.reference(b.parameter(outer, 0)),
            .payload = try b.constant(bool, false),
        } }),
    };
    try b.define(body, position);
    const info = try horos.source.library.cleanup.exitInfo(b, unit);
    const cleanup = try b.declare(&.{info}, unit, &.{effect}, &.{});
    try b.define(cleanup, try b.term(.{ .perform = .{
        .effect = effect,
        .capability = try b.reference(b.parameter(outer, 0)),
        .payload = try b.constant(bool, true),
    } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = unit,
        .effects = &.{ effect, pause },
        .capture_bound = &.{h.capability},
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{info},
        .result = unit,
        .effects = &.{effect},
        .capture_bound = &.{h.capability},
    } } });
    try b.define(outer, try b.term(.{ .protect = .{
        .body = try b.lambda(body, body_type),
        .cleanup = try b.lambda(cleanup, cleanup_type),
    } }));
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{h.capability},
        .result = unit,
        .effects = &.{ effect, pause },
    } } });
    const entry = try b.declare(&.{}, unit, &.{pause}, &.{});
    try b.define(entry, try b.term(.{ .handle = .{
        .handler = h.id,
        .body = try b.lambda(outer, outer_type),
    } }));
    return b.module(entry, unit);
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeByte('[');
    for (std.enums.values(Mode), 0..) |mode, index| {
        var b = Builder.init(init.gpa);
        defer b.deinit();
        const source = try scenario(&b, mode);
        var compiled = try horos.program.compile(init.gpa, source);
        defer compiled.deinit();
        if (index != 0) try output.interface.writeByte(',');
        try std.json.Stringify.value(.{ .mode = mode, .source = source }, .{
            .emit_strings_as_arrays = true,
        }, &output.interface);
    }
    try output.interface.writeAll("]\n");
    try output.interface.flush();
}
