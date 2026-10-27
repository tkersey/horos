const std = @import("std");
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const hyper = @import("hyper.zig");
const native = @import("horos_data").schema.native;

const Integer = a.Shape(u64);
const Task = a.Internal(.{ .callable = a.Signature(native.Fields(&.{}, &.{}), Integer) });
const Effect = a.OperationSignature(Integer, Integer, native.Fields(&.{}, &.{}));
pub const Mode = enum { obtain, resume_once, repeated, dispose, duplicate_resume };

const Types = struct {
    integer: *const a.Schema(Integer),
    task: *const a.Schema(Task),
    pair: *const hyper.Pair(Task, Task),
    effect: *const a.Operation(Effect),
    unused_linear: *const a.Schema(Task),
    borrowed_regions: []const *const a.Region,
};

fn types(c: *a.Context) !Types {
    return typesInRegions(c, &.{});
}

fn typesInRegions(c: *a.Context, regions: []const *const a.Region) !Types {
    const integer = try c.schema(u64);
    const task = try c.declareSchema(.callable, Task);
    const state_delay = try hyper.delayed(c, integer, .{ .captures = .{integer} });
    const pair = try hyper.pair(c, task.schema(), task.schema(), .{
        .captures = .{ integer, state_delay },
    });
    const effect = try c.external("hyper/captured", integer, integer);
    try c.defineCallable(task, .{}, integer, .{effect}, .{
        .use = .reusable,
        .captures = .{ integer, pair.peerForward(), pair.peerBackward() },
        .regions = regions,
    });
    return .{
        .integer = integer,
        .task = task.schema(),
        .pair = pair,
        .effect = effect,
        .unused_linear = try c.callable(.{}, integer, .{}, .{ .use = .linear }),
        .borrowed_regions = regions,
    };
}

const Completion = struct {
    seed: *const a.Value(Integer),
    effect: *const a.Operation(Effect),
    dispose: bool,
    duplicate_resume: bool,

    pub fn emit(
        self: @This(),
        body: anytype,
        token: anytype,
        contribution: anytype,
    ) a.Error!*const a.Computation(Integer) {
        const c = try body.context();
        _ = try body.perform(self.effect, self.seed);
        const result = if (self.dispose) blk: {
            _ = try body.dispose(token);
            break :blk self.seed;
        } else try body.resumeValue(token, contribution);
        if (self.duplicate_resume) _ = try body.resumeValue(token, contribution);
        const after = try body.checkedAdd(
            self.seed,
            try body.constant(u64, 100),
            try c.literalFailure(void, {}),
        );
        _ = try body.perform(self.effect, after);
        return body.ret(result);
    }
};

const Step = struct {
    types: Types,
    seed: *const a.Value(Integer),
    mode: Mode,
    emissions: *usize,

    pub fn emit(
        self: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(Task)) {
        self.emissions.* += 1;
        const c = try body.context();
        const t = self.types;
        const need = try hyper.demand.family(c, "captured need", t.integer, t.integer);
        const interpretation = try hyper.demand.interpretWith(body, query, need, t.integer, .{
            .captures = .{
                t.integer, t.pair.peerForward(), t.pair.peerBackward(), t.unused_linear,
            },
            .residual = .{t.effect},
            .borrowed_regions = t.borrowed_regions,
        }, Completion{
            .seed = self.seed,
            .effect = t.effect,
            .dispose = self.mode == .dispose,
            .duplicate_resume = self.mode == .duplicate_resume,
        });
        const task = try c.functionFor("captured task", t.task);
        const task_body = try body.closureBody(task);
        const work_function = try c.functionFor("captured work", interpretation.body());
        const work_body = try task_body.closureBody(work_function);
        try c.define(work_function, try self.work(work_body, query, need));
        const handled = try hyper.demand.handle(
            task_body,
            interpretation,
            try task_body.lambda(work_function, interpretation.body()),
        );
        try c.define(task, try task_body.ret(handled));
        return body.ret(try hyper.deferValue(
            body,
            query.types().answerForward(),
            try body.lambda(task, t.task),
        ));
    }

    fn work(
        self: @This(),
        body: anytype,
        query: anytype,
        need: anytype,
    ) a.Error!*const a.Computation(Integer) {
        const c = try body.context();
        const condition = try body.equal(query.state(), try body.constant(u64, 0));
        const initial = try body.branch();
        _ = try initial.perform(self.types.effect, self.seed);
        var total = self.seed;
        const count: u8 = if (self.mode == .repeated) 2 else 1;
        for (0..count) |_| {
            const contribution = try hyper.demand.request(
                initial,
                need,
                try body.parameter("capability"),
                try initial.constant(u64, 1),
            );
            total = try initial.checkedAdd(total, contribution, try c.literalFailure(void, {}));
        }
        _ = try initial.perform(self.types.effect, total);
        const terminal = try body.branch();
        const reply = try terminal.perform(self.types.effect, self.seed);
        return body.ret(try body.conditional(
            condition,
            try initial.ret(total),
            try terminal.ret(reply),
        ));
    }
};

pub fn build(raw: *source.Builder, mode: Mode) !source.Module {
    const c = try a.Context.init(raw);
    const t = try types(c);
    const entry = try c.function("captured interaction", .{
        .producer = t.integer,
        .consumer = t.integer,
    }, t.integer, .{t.effect});
    const body = try c.body(entry);
    const task = try interactionTask(body, t, mode);
    const result = if (mode == .obtain)
        try body.constant(u64, 7)
    else
        try body.apply(task, .{});
    try c.define(entry, try body.ret(result));
    return c.module(entry, try c.schema(void));
}

fn interactionTask(body: anytype, t: Types, mode: Mode) !*const a.Value(Task) {
    var emissions: usize = 0;
    const producer = try hyper.ana(body, t.pair, t.integer, Step{
        .types = t,
        .seed = try body.parameter("producer"),
        .mode = .resume_once,
        .emissions = &emissions,
    });
    const consumer = try hyper.ana(body, t.pair.swap(), t.integer, Step{
        .types = t,
        .seed = try body.parameter("consumer"),
        .mode = mode,
        .emissions = &emissions,
    });
    const state = try body.constant(u64, 0);
    const left = try hyper.start(body, producer, state);
    const right = try hyper.start(body, consumer, state);
    _ = try hyper.start(body, producer, try body.constant(u64, 1));
    if (emissions != 2) return error.UnexpectedStepReemission;
    const peer = try hyper.deferValue(body, t.pair.peerForward(), left);
    return hyper.force(body, try hyper.invoke(body, right, peer));
}

test "typed Need response preserves one shot resumption ownership" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    try std.testing.expectError(error.UnavailableSlot, build(&raw, .duplicate_resume));
}

test "typed Need captured response construction handles allocation failures" {
    try @import("../allocation_testing.zig").check(
        std.testing.allocator,
        capturedResponseAllocation,
        .{},
    );
}

fn capturedResponseAllocation(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const t = try types(c);
    const entry = try c.function("captured allocation", .{ .seed = t.integer }, t.integer, .{
        t.effect,
    });
    const body = try c.body(entry);
    var emissions: usize = 0;
    _ = try hyper.ana(body, t.pair, t.integer, Step{
        .types = t,
        .seed = try body.parameter("seed"),
        .mode = .resume_once,
        .emissions = &emissions,
    });
    try std.testing.expectEqual(@as(usize, 1), emissions);
}

test "typed Need response borrows only the active task region" {
    try regionCapture(false);
    try std.testing.expectError(error.InvalidEffect, regionCapture(true));
}

fn regionCapture(comptime escape: bool) !void {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const region = try c.region();
    const t = try typesInRegions(c, &.{region});
    const scoped_schema = try c.regionBodySchema(region, .{
        .producer = t.integer,
        .consumer = t.integer,
    }, if (escape) t.task else t.integer, .{t.effect}, .{ .use = .linear });
    const scoped_function = try c.functionFor("captured region", scoped_schema);
    const scoped = try c.body(scoped_function);
    const task = try interactionTask(scoped, t, .resume_once);
    const result = if (escape) task else try scoped.apply(task, .{});
    try c.define(scoped_function, try scoped.ret(result));
    const entry = try c.function("captured region entry", .{
        .producer = t.integer,
        .consumer = t.integer,
    }, t.integer, .{t.effect});
    const body = try c.body(entry);
    const observed = try body.withRegion(
        region,
        try body.lambda(scoped_function, scoped_schema),
        .{
            .producer = try body.parameter("producer"),
            .consumer = try body.parameter("consumer"),
        },
    );
    const final = if (escape) try body.apply(observed, .{}) else observed;
    try c.define(entry, try body.ret(final));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

const Cell = a.Internal(.{ .cell = Integer });

const TaskLocalCompletion = struct {
    cell: *const a.Value(Cell),
    capture: bool,
    effect: *const a.Operation(Effect),

    pub fn emit(
        self: @This(),
        body: anytype,
        token: anytype,
        contribution: anytype,
    ) a.Error!*const a.Computation(Integer) {
        if (self.capture) _ = try body.perform(self.effect, try body.readCell(self.cell));
        return body.ret(try body.resumeValue(token, contribution));
    }
};

const TaskLocalStep = struct {
    types: Types,
    capture: bool,

    pub fn emit(
        self: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(Task)) {
        const c = try body.context();
        const t = self.types;
        const region = try c.region();
        const cell_type = try c.cell(region, t.integer);
        const task = try c.functionFor("task local capture", t.task);
        const task_body = try body.closureBody(task);
        const scoped_type = try c.regionBodySchema(region, .{}, t.integer, .{t.effect}, .{
            .use = .linear,
            .captures = .{ t.integer, t.pair.peerForward(), t.pair.peerBackward() },
        });
        const scoped_function = try c.functionFor("task local capture region", scoped_type);
        const scoped = try task_body.closureBody(scoped_function);
        const cell = try scoped.newCell(
            cell_type,
            try scoped.parameter("region"),
            try scoped.constant(u64, 7),
        );
        const need = try hyper.demand.family(c, "task local need", t.integer, t.integer);
        const interpretation = try hyper.demand.interpretWith(scoped, query, need, t.integer, .{
            .captures = .{
                t.integer, t.pair.peerForward(), t.pair.peerBackward(), cell_type, t.unused_linear,
            },
            .residual = .{t.effect},
            .borrowed_regions = .{region},
        }, TaskLocalCompletion{ .cell = cell, .capture = self.capture, .effect = t.effect });
        const work_function = try c.functionFor("task local work", interpretation.body());
        const work_body = try scoped.closureBody(work_function);
        try c.define(work_function, try self.work(work_body, query, need));
        const handled = try hyper.demand.handle(
            scoped,
            interpretation,
            try scoped.lambda(work_function, interpretation.body()),
        );
        try c.define(scoped_function, try scoped.ret(handled));
        const result = try task_body.withRegion(
            region,
            try task_body.lambda(scoped_function, scoped_type),
            .{},
        );
        try c.define(task, try task_body.ret(result));
        return body.ret(try hyper.deferValue(
            body,
            query.types().answerForward(),
            try body.lambda(task, t.task),
        ));
    }

    fn work(
        _: @This(),
        body: anytype,
        query: anytype,
        need: anytype,
    ) a.Error!*const a.Computation(Integer) {
        const initial = try body.branch();
        const contribution = try hyper.demand.request(
            initial,
            need,
            try body.parameter("capability"),
            try initial.constant(u64, 1),
        );
        const terminal = try body.branch();
        return body.ret(try body.conditional(
            try body.equal(query.state(), try body.constant(u64, 0)),
            try initial.ret(contribution),
            try terminal.ret(try terminal.constant(u64, 13)),
        ));
    }
};

pub fn buildTaskLocal(raw: *source.Builder, capture: bool) !source.Module {
    const c = try a.Context.init(raw);
    const t = try types(c);
    const entry = try c.function("task local capture entry", .{}, t.integer, .{t.effect});
    const body = try c.body(entry);
    const left_maker = try hyper.ana(body, t.pair, t.integer, TaskLocalStep{
        .types = t,
        .capture = capture,
    });
    const right_maker = try hyper.ana(body, t.pair.swap(), t.integer, TaskLocalStep{
        .types = t,
        .capture = capture,
    });
    const left = try hyper.start(body, left_maker, try body.constant(u64, 0));
    const right = try hyper.start(body, right_maker, try body.constant(u64, 0));
    const task = try hyper.force(body, try hyper.invoke(
        body,
        right,
        try hyper.deferValue(body, t.pair.peerForward(), left),
    ));
    try c.define(entry, try body.ret(try body.apply(task, .{})));
    return c.module(entry, try c.schema(void));
}

test "typed Need completion captures a cell allocated inside its task" {
    for ([_]bool{ false, true }) |capture| {
        var raw = source.Builder.init(std.testing.allocator);
        defer raw.deinit();
        _ = try buildTaskLocal(&raw, capture);
    }
}
