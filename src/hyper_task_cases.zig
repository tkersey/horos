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

pub const Kind = enum {
    describe,
    obtain,
    run,
    repeated,
    adaptive,
    dispose,
    multishot,
    cleanup_run,
    cleanup_dispose,
};

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
    cleanup: bool = false,

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
            .obligations = self.cleanup,
        }, Completion{ .dispose = self.dispose });
        const task = try c.functionFor("participant task", t.task);
        const task_body = try body.closureBody(task);
        const work_function = try c.functionFor("requesting task", interpretation.body());
        const work_body = try task_body.closureBody(work_function);
        try c.define(work_function, if (self.cleanup)
            try self.protectedWork(work_body, query, need)
        else
            try self.work(work_body, query, need));
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

    fn protectedWork(
        self: @This(),
        body: anytype,
        query: anytype,
        need: anytype,
    ) a.Error!*const a.Computation(Integer) {
        const c = try body.context();
        const t = self.types;
        const schema = try c.callable(.{ .capability = need.capability() }, t.integer, .{
            need.effect(), t.effect,
        }, .{
            .use = .linear,
            .captures = .{ t.integer, t.pair.peerForward(), t.pair.peerBackward() },
        });
        const function = try c.functionFor("protected task work", schema);
        const nested = try body.closureBody(function);
        try c.define(function, try self.work(nested, query, need));
        const unit = try c.schema(void);
        const cleanup_schema = try c.callable(.{ .exit = try c.cleanupInfo(unit) }, unit, .{
            t.effect,
        }, .{ .use = .linear });
        const cleanup = try c.functionFor("task cleanup", cleanup_schema);
        const finalizer = try c.body(cleanup);
        _ = try finalizer.perform(t.effect, try finalizer.constant(u64, self.offset + 300));
        try c.define(cleanup, try finalizer.ret(try finalizer.constant(void, {})));
        return body.ret(try body.protect(
            try body.lambda(function, schema),
            try body.lambda(cleanup, cleanup_schema),
            .{ .capability = try body.parameter("capability") },
        ));
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
        .dispose = kind == .dispose or kind == .cleanup_dispose,
        .cleanup = kind == .cleanup_run or kind == .cleanup_dispose,
    });
    const state = try body.constant(u64, 0);
    const left = try hyper.start(body, producer, state);
    const right = try hyper.start(body, consumer, state);
    const peer = try hyper.deferValue(body, t.pair.peerForward(), left);
    const answer = try hyper.invoke(body, right, peer);
    if (kind == .describe) {
        try c.define(entry, try body.ret(try body.constant(u64, 7)));
        return c.module(entry, try c.schema(void));
    }
    const task = try hyper.force(body, answer);
    const result = switch (kind) {
        .obtain => try body.constant(u64, 7),
        .multishot => try multishot(body, t, task),
        else => try body.apply(task, .{}),
    };
    try c.define(entry, try body.ret(result));
    return c.module(entry, try c.schema(void));
}

fn multishot(body: anytype, t: Types, task: *const a.Value(Task)) !*const a.Value(Integer) {
    const c = try body.context();
    const choose = try c.local("task branch", try c.schema(void), t.integer, .multi);
    const handler = try c.handler(choose, t.integer, t.integer, .{
        .use = .multi,
        .mode = .deep,
        .captures = .{ t.integer, t.task },
        .body_captures = .{t.task},
        .residual = .{t.effect},
        .return_effects = .{},
    });
    const returns = try c.returnFunction(handler);
    const returned = try c.body(returns);
    try c.define(returns, try returned.ret(try returned.parameter("result")));
    const clause = try c.clauseFunction(handler);
    const branch = try c.body(clause);
    const token = try branch.parameter("resumption");
    const first = try branch.resumeValue(token, try branch.constant(u64, 1));
    const second = try branch.resumeValue(token, try branch.constant(u64, 2));
    const total = try branch.checkedAdd(first, second, try c.literalFailure(void, {}));
    try c.define(clause, try branch.ret(total));
    const schema = try c.handledSchema(handler);
    const function = try c.functionFor("task branch body", schema);
    const nested = try body.closureBody(function);
    const choice = try nested.performLocal(
        choose,
        try nested.parameter("capability"),
        try nested.constant(void, {}),
    );
    const result = try nested.apply(task, .{});
    try c.define(function, try nested.ret(try nested.checkedAdd(
        choice,
        result,
        try c.literalFailure(void, {}),
    )));
    return body.handleWith(handler, try body.lambda(function, schema), .{});
}
