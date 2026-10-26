const std = @import("std");
const horos = @import("horos");
const a = horos.authoring;
const hyper = horos.library.hyper;
const native = horos.data.schema.native;
const mode = @import("rejection_mode").value;

fn selected(comptime name: []const u8) bool {
    return std.mem.eql(u8, mode, name);
}

pub fn main(init: std.process.Init) !void {
    var raw = horos.source.Builder.init(init.gpa);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const function = try c.function("caller", .{}, integer, .{});
    const body = try c.body(function);
    const value = try body.constant(u64, 1);
    if (comptime selected("hyper_pair_option")) {
        _ = try hyper.pair(c, integer, integer, .{ .capture = .{} });
    } else if (comptime selected("hyper_delayed_option")) {
        _ = try hyper.delayed(c, integer, .{ .capture = .{} });
    } else if (comptime selected("hyper_value_as_schema")) {
        _ = try hyper.pair(c, value, integer, .{});
    } else if (comptime selected("hyper_task_completion")) {
        const Task = a.Internal(.{ .callable = a.Signature(
            native.Fields(&.{}, &.{}),
            a.Shape(u64),
        ) });
        const task = try c.declareSchema(.callable, Task);
        const types = try hyper.pair(c, task.schema(), task.schema(), .{});
        try c.defineCallable(task, .{}, boolean, .{}, .{
            .use = .reusable,
            .captures = .{ types.peerForward(), types.peerBackward() },
        });
    } else try rejectValues(c, integer, boolean, body, value);
}

fn rejectValues(
    c: *a.Context,
    integer: anytype,
    boolean: anytype,
    body: anytype,
    value: anytype,
) !void {
    const types = try hyper.pair(c, integer, boolean, .{});
    if (comptime selected("hyper_force_body") or selected("hyper_invoke_body")) {
        try rejectBody(c, body, integer, value);
    } else if (comptime selected("hyper_selected_run") or selected("hyper_selected_project") or
        selected("hyper_partial_project"))
    {
        try rejectObservation(c, body, integer, boolean);
    } else if (comptime selected("hyper_identity_endpoints")) {
        _ = try hyper.identity(body, types);
    } else if (comptime selected("hyper_strict_answer")) {
        _ = try hyper.base(body, types, try body.constant(bool, false));
    } else if (comptime selected("hyper_wrong_answer")) {
        _ = try hyper.base(body, types, try hyper.deferValue(body, types.answerBackward(), value));
    } else if (comptime selected("hyper_schema_as_value")) {
        _ = try hyper.base(body, types, types.answerForward());
    } else if (comptime selected("hyper_value_as_function")) {
        _ = try hyper.make(body, types, value);
    } else if (comptime selected("hyper_counterfeit_pair")) {
        const Fake = opaque {
            pub const Input = a.Shape(u64);
            pub const Output = a.Shape(bool);
        };
        const counterfeit: *const Fake = undefined;
        _ = try hyper.base(body, counterfeit, value);
    } else if (comptime selected("hyper_reciprocal")) {
        const answer = try hyper.deferValue(
            body,
            types.answerForward(),
            try body.constant(bool, true),
        );
        const participant = try hyper.base(body, types, answer);
        const wrong_peer = try hyper.deferValue(body, types.peerForward(), participant);
        _ = try hyper.invoke(body, participant, wrong_peer);
    } else try rejectComposition(c, integer, boolean, body, value);
}

fn BodyWrapper(comptime B: type) type {
    return struct {
        body: B,
        pub fn schemaOf(
            self: *@This(),
            value: anytype,
        ) a.Error!*const a.Schema(a.ShapeOf(@TypeOf(value))) {
            return self.body.schemaOf(value);
        }
    };
}

fn rejectBody(c: *a.Context, body: anytype, integer: anytype, value: anytype) !void {
    const types = try hyper.pair(c, integer, integer, .{});
    const answer = try hyper.deferValue(body, types.answerForward(), value);
    var wrapper: BodyWrapper(@TypeOf(body)) = .{ .body = body };
    if (comptime selected("hyper_force_body")) {
        _ = try hyper.force(&wrapper, answer);
    } else {
        const participant = try hyper.base(body, types, answer);
        const peer = try hyper.deferValue(body, types.peerBackward(), participant);
        _ = try hyper.invoke(&wrapper, participant, peer);
    }
}

fn rejectObservation(c: *a.Context, body: anytype, integer: anytype, boolean: anytype) !void {
    const interfaces = try hyper.group(c, .{ .input = integer, .output = boolean }, .{});
    const types = interfaces.get("input", "output");
    const runtime_types = try hyper.ir.select(interfaces, "input", "output");
    const answer = try hyper.deferValue(body, types.answerForward(), try body.constant(bool, true));
    const participant = try hyper.base(body, types, answer);
    if (comptime selected("hyper_selected_run")) {
        _ = try hyper.run(body, runtime_types, participant);
    } else if (comptime selected("hyper_partial_project")) {
        const partial = try hyper.ir.from(interfaces, "input", "output");
        _ = try hyper.project(
            body,
            runtime_types,
            try a.interop.refineValue(body, participant, partial.forward()),
            answer,
        );
    } else {
        _ = try hyper.project(body, runtime_types, participant, answer);
    }
}

fn rejectComposition(
    c: *a.Context,
    integer: anytype,
    boolean: anytype,
    body: anytype,
    value: anytype,
) !void {
    if (comptime selected("hyper_group_option")) {
        _ = try hyper.group(c, .{ .value = integer }, .{ .capture = .{} });
    } else if (comptime selected("hyper_counterfeit_group")) {
        const Fake = opaque {
            pub const Endpoints = native.Fields(&.{"value"}, &.{a.Shape(u64)});
        };
        const counterfeit: *const Fake = undefined;
        _ = try hyper.compose(body, counterfeit, "value", "value", "value", value, value);
    } else if (comptime selected("hyper_composition_middle")) {
        const interfaces = try hyper.group(c, .{
            .input = try c.schema(u8),
            .middle = boolean,
            .output = integer,
        }, .{});
        const wrong = interfaces.get("input", "output");
        const right = interfaces.get("input", "middle");
        const left_value = try hyper.base(body, wrong, try hyper.deferValue(
            body,
            wrong.answerForward(),
            value,
        ));
        const right_value = try hyper.base(body, right, try hyper.deferValue(
            body,
            right.answerForward(),
            try body.constant(bool, true),
        ));
        _ = try hyper.compose(
            body,
            interfaces,
            "input",
            "middle",
            "output",
            left_value,
            right_value,
        );
    } else if (comptime selected("hyper_transform_result")) {
        const types = try hyper.pair(c, integer, integer, .{});
        const transform = try c.function("wrong result", .{
            .argument = types.answerBackward(),
        }, try hyper.delayed(c, boolean, .{}), .{});
        const participant = try hyper.base(body, types, try hyper.deferValue(
            body,
            types.answerForward(),
            value,
        ));
        const tail = try hyper.deferValue(body, types.peerForward(), participant);
        _ = try hyper.push(body, types, transform, tail);
    } else try rejectDefinitions(c, integer, body, value);
}

const ConstantStep = struct {
    pub fn emit(
        _: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(a.Shape(u64))) {
        return body.ret(try hyper.deferValue(body, query.types().answerForward(), query.state()));
    }
};

const WrongSuccessor = struct {
    pub fn emit(
        _: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(a.Shape(u64))) {
        const c = try body.context();
        const next = if (comptime selected("hyper_strict_successor")) query.state() else blk: {
            break :blk try hyper.deferValue(
                body,
                try hyper.delayed(c, try c.schema(bool), .{}),
                try body.constant(bool, false),
            );
        };
        return body.ret(try query.ask(body, next));
    }
};

fn rejectDefinitions(c: *a.Context, integer: anytype, body: anytype, value: anytype) !void {
    if (comptime selected("hyper_counterfeit_ana")) {
        const Fake = opaque {
            pub const State = a.Shape(u64);
            pub const Input = a.Shape(u64);
            pub const Output = a.Shape(u64);
        };
        const counterfeit: *const Fake = undefined;
        _ = try hyper.start(body, counterfeit, value);
    } else if (comptime selected("hyper_counterfeit_query")) {
        const Fake = opaque {
            pub const State = a.Shape(u64);
            pub const Input = a.Shape(u64);
            pub const Output = a.Shape(u64);
        };
        const counterfeit: *const Fake = undefined;
        const need = try hyper.demand.family(c, "counterfeit", integer, integer);
        _ = try hyper.demand.interpret(body, counterfeit, need, integer, .{});
    } else if (comptime selected("hyper_start_state")) {
        const types = try hyper.pair(c, integer, integer, .{});
        const definition = try hyper.ana(body, types, integer, ConstantStep{});
        _ = try hyper.start(body, definition, try body.constant(bool, false));
    } else if (comptime selected("hyper_strict_successor") or selected("hyper_delayed_successor")) {
        const types = try hyper.pair(c, integer, integer, .{});
        _ = try hyper.ana(body, types, integer, WrongSuccessor{});
    } else @compileError("unknown hyper static rejection mode");
}
