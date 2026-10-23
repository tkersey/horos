const source = @import("source.zig");
const a = @import("authoring.zig");
const hyper = @import("library/hyper.zig");
const native = @import("horos_data").schema.native;

const Integer = a.Shape(u64);
const Task = a.Internal(.{ .callable = a.Signature(native.Fields(&.{}, &.{}), Integer) });
const Effect = a.OperationSignature(Integer, Integer, native.Fields(&.{}, &.{}));
const Types = struct {
    integer: *const a.Schema(Integer),
    task: *const a.Schema(Task),
    pair: *const hyper.Pair(Task, Task),
    state_delay: *const a.Schema(hyper.Delayed(Integer)),
    effect: *const a.Operation(Effect),
};

pub const Kind = enum { obtain, run, repeated, adaptive, dispose };

fn types(c: *a.Context) !Types {
    const integer = try c.schema(u64);
    const task = try c.declareSchema(.callable, Task);
    const state_delay = try hyper.delayed(c, integer, .{ .captures = .{integer} });
    const pair = try hyper.pair(c, task.schema(), task.schema(), .{
        .captures = .{ integer, state_delay },
    });
    const effect = try c.external("hyper/task", integer, integer);
    try c.defineCallable(task, .{}, integer, .{effect}, .{
        .use = .reusable,
        .captures = .{ integer, pair.peerForward(), pair.peerBackward() },
    });
    return .{
        .integer = integer,
        .task = task.schema(),
        .pair = pair,
        .state_delay = state_delay,
        .effect = effect,
    };
}

const Completion = struct {
    dispose: bool,
    pub fn emit(
        self: @This(),
        body: anytype,
        token: anytype,
        contribution: anytype,
    ) a.Error!*const a.Computation(Integer) {
        if (!self.dispose) return body.ret(try body.resumeValue(token, contribution));
        _ = try body.dispose(token);
        return body.ret(try body.constant(u64, 99));
    }
};

const Step = struct {
    types: Types,
    offset: u64,
    repeated: bool = false,
    adaptive: bool = false,
    dispose: bool = false,

    pub fn emit(
        self: @This(),
        body: anytype,
        query: anytype,
    ) a.Error!*const a.Computation(hyper.Delayed(Task)) {
        const c = try body.context();
        const t = self.types;
        const need = try hyper.demand.family(c, "hyper/need", t.integer, t.integer);
        const interpretation = try hyper.demand.interpretWith(body, query, need, t.integer, .{
            .captures = .{ t.integer, t.pair.peerForward(), t.pair.peerBackward() },
            .residual = .{t.effect},
        }, Completion{ .dispose = self.dispose });
        const task = try c.functionFor("participant task", t.task);
        const task_body = try body.closureBody(task);
        const work_function = try c.functionFor("requesting task", interpretation.body());
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
        _ = try initial.perform(self.types.effect, try initial.constant(u64, self.offset));
        const capability = try body.parameter("capability");
        const state = try initial.constant(u64, 1);
        const first = try hyper.demand.request(initial, need, capability, state);
        const contribution = try self.chooseContribution(initial, need, capability, state, first);
        const after = try initial.checkedAdd(
            contribution,
            try initial.constant(u64, 200),
            try c.literalFailure(void, {}),
        );
        _ = try initial.perform(self.types.effect, after);
        const result = try initial.checkedAdd(
            contribution,
            try initial.constant(u64, self.offset),
            try c.literalFailure(void, {}),
        );
        const terminal = try body.branch();
        const reply = try terminal.perform(
            self.types.effect,
            try terminal.constant(u64, self.offset + 1),
        );
        return body.ret(try body.conditional(
            condition,
            try initial.ret(result),
            try terminal.ret(reply),
        ));
    }

    fn chooseContribution(
        self: @This(),
        body: anytype,
        need: anytype,
        capability: anytype,
        state: anytype,
        first: anytype,
    ) a.Error!*const a.Value(Integer) {
        if (!self.repeated and !self.adaptive) return first;
        const c = try body.context();
        if (self.repeated) return body.checkedAdd(
            first,
            try hyper.demand.request(body, need, capability, state),
            try c.literalFailure(void, {}),
        );
        const chosen = try body.equal(first, try body.constant(u64, 15));
        const again = try body.branch();
        const second = try hyper.demand.request(again, need, capability, state);
        const total = try again.checkedAdd(first, second, try c.literalFailure(void, {}));
        const done = try body.branch();
        return body.conditional(chosen, try again.ret(total), try done.ret(first));
    }
};

pub fn build(raw: *source.Builder, kind: Kind) !source.Module {
    const c = try a.Context.init(raw);
    const t = try types(c);
    const entry = try c.function("task interaction", .{}, t.integer, .{t.effect});
    const body = try c.body(entry);
    const producer = try hyper.ana(body, t.pair, t.integer, Step{ .types = t, .offset = 10 });
    const consumer = try hyper.ana(body, t.pair.swap(), t.integer, Step{
        .types = t,
        .offset = 20,
        .repeated = kind == .repeated,
        .adaptive = kind == .adaptive,
        .dispose = kind == .dispose,
    });
    const state = try body.constant(u64, 0);
    const left = try hyper.start(body, producer, state);
    const right = try hyper.start(body, consumer, state);
    const peer = try hyper.deferValue(body, t.pair.peerForward(), left);
    const answer = try hyper.invoke(body, right, peer);
    const task = try hyper.force(body, answer);
    const result = if (kind == .obtain) try body.constant(u64, 7) else try body.apply(task, .{});
    try c.define(entry, try body.ret(result));
    return c.module(entry, try c.schema(void));
}
