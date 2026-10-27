// Copyright (c) 2026 Boundary contributors. MIT license.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const state = @import("../library/state.zig");
const choice = @import("../library/choice.zig");
pub fn local(b: *source.Builder) source.Error!source.Module {
    return build(b, true, false);
}
pub fn shared(b: *source.Builder) source.Error!source.Module {
    return build(b, false, false);
}
pub fn recursiveLocal(b: *source.Builder) source.Error!source.Module {
    return build(b, true, true);
}
pub fn recursiveShared(b: *source.Builder) source.Error!source.Module {
    return build(b, false, true);
}
fn build(
    b: *source.Builder,
    comptime choice_outside: bool,
    comptime recursive: bool,
) source.Error!source.Module {
    return authored(b, choice_outside, recursive) catch |err| return a.sourceError(err);
}
fn authored(
    b: *source.Builder,
    comptime choice_outside: bool,
    comptime recursive: bool,
) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const boolean = try c.schema(bool);
    const integer = try c.schema(u64);
    const sequence = try c.sequence(integer);
    const region = try c.region();
    const cell_schema = try c.cell(region, integer);
    const counter = try state.family(c, "example/counter", integer);
    const branch = try choice.family(c, "example/branch");
    const all = try choice.all(c, branch, integer, .{
        .captures = .{
            .continuation = &.{
                unit,
                boolean,
                integer,
                sequence,
                cell_schema,
                counter.getCapability(),
                counter.putCapability(),
                branch.capability(),
            },
            .body = if (choice_outside) &.{} else &.{
                counter.getCapability(),
                counter.putCapability(),
            },
        },
        .residual = if (choice_outside) &.{} else &.{ counter.get(), counter.put() },
        .owned_regions = if (choice_outside) &.{region} else &.{},
        .borrowed_regions = if (choice_outside) &.{} else &.{region},
    });
    return interpretState(choice_outside, recursive, .{
        .c = c,
        .unit = unit,
        .boolean = boolean,
        .integer = integer,
        .sequence = sequence,
        .region = region,
        .cell_schema = cell_schema,
        .counter = counter,
        .branch = branch,
        .all = all,
    });
}

fn interpretState(
    comptime choice_outside: bool,
    comptime recursive: bool,
    ctx: anytype,
) a.Error!source.Module {
    const interpreted = try state.interpret(
        ctx.c,
        ctx.counter,
        if (choice_outside) ctx.integer else ctx.sequence,
        ctx.region,
        .{
            .captures = .{
                .continuation = &.{
                    ctx.unit,
                    ctx.boolean,
                    ctx.integer,
                    ctx.sequence,
                    ctx.cell_schema,
                    ctx.counter.getCapability(),
                    ctx.counter.putCapability(),
                    ctx.branch.capability(),
                    ctx.all.resumption,
                },
                .body = if (choice_outside) &.{ctx.branch.capability()} else &.{},
            },
            .residual = if (choice_outside) &.{ctx.branch.effect()} else &.{},
            .answer = .value,
        },
    );
    return declareScopes(choice_outside, recursive, .{
        .c = ctx.c,
        .unit = ctx.unit,
        .integer = ctx.integer,
        .sequence = ctx.sequence,
        .region = ctx.region,
        .cell_schema = ctx.cell_schema,
        .counter = ctx.counter,
        .branch = ctx.branch,
        .all = ctx.all,
        .interpreted = interpreted,
    });
}

fn declareScopes(
    comptime choice_outside: bool,
    comptime recursive: bool,
    ctx: anytype,
) a.Error!source.Module {
    const scope_schema = try ctx.c.regionBodySchema(
        ctx.region,
        .{},
        if (choice_outside) ctx.integer else ctx.sequence,
        if (choice_outside) &.{ctx.branch.effect()} else &.{},
        .{ .use = .linear, .captures = if (choice_outside) &.{ctx.branch.capability()} else &.{} },
    );
    const scope_fn = try ctx.c.functionFor("state region", scope_schema);
    const state_schema = try ctx.c.handledSchema(ctx.interpreted.handler);
    const state_fn = try ctx.c.functionFor("state work", state_schema);
    const choice_schema = try ctx.c.handledSchema(ctx.all.handler);
    const choice_fn = try ctx.c.functionFor("choice work", choice_schema);
    var scope_body: @TypeOf(try ctx.c.body(scope_fn)) = undefined;
    var state_body: @TypeOf(try ctx.c.body(state_fn)) = undefined;
    var choice_body: @TypeOf(try ctx.c.body(choice_fn)) = undefined;
    if (choice_outside) {
        choice_body = try ctx.c.body(choice_fn);
        scope_body = try choice_body.closureBody(scope_fn);
        state_body = try scope_body.closureBody(state_fn);
    } else {
        scope_body = try ctx.c.body(scope_fn);
        state_body = try scope_body.closureBody(state_fn);
        choice_body = try state_body.closureBody(choice_fn);
    }
    return defineChoiceWork(choice_outside, recursive, .{
        .c = ctx.c,
        .unit = ctx.unit,
        .sequence = ctx.sequence,
        .region = ctx.region,
        .cell_schema = ctx.cell_schema,
        .counter = ctx.counter,
        .branch = ctx.branch,
        .all = ctx.all,
        .interpreted = ctx.interpreted,
        .scope_schema = scope_schema,
        .scope_fn = scope_fn,
        .state_schema = state_schema,
        .state_fn = state_fn,
        .choice_schema = choice_schema,
        .choice_fn = choice_fn,
        .scope_body = scope_body,
        .state_body = state_body,
        .choice_body = choice_body,
    });
}

fn defineChoiceWork(
    comptime choice_outside: bool,
    comptime recursive: bool,
    ctx: anytype,
) a.Error!source.Module {
    const work = if (choice_outside) ctx.state_body else ctx.choice_body;
    const caps = .{
        try ctx.state_body.parameter("get"),
        try ctx.state_body.parameter("put"),
        try ctx.choice_body.parameter("capability"),
    };
    const value = if (recursive) try recursiveWork(
        ctx.c,
        work,
        ctx.counter,
        ctx.branch,
        ctx.region,
        caps,
    ) else blk: {
        _ = try work.performLocal(ctx.branch.effect(), caps[2], try work.constant(void, {}));
        const before = try work.performLocal(
            ctx.counter.get(),
            caps[0],
            try work.constant(void, {}),
        );
        const after = try work.checkedAdd(
            before,
            try work.constant(u64, 1),
            try ctx.c.literalFailure(void, {}),
        );
        _ = try work.performLocal(ctx.counter.put(), caps[1], after);
        break :blk after;
    };
    if (choice_outside) {
        try ctx.c.define(ctx.state_fn, try ctx.state_body.ret(value));
    } else {
        try ctx.c.define(ctx.choice_fn, try ctx.choice_body.ret(value));
        try ctx.c.define(
            ctx.state_fn,
            try ctx.state_body.ret(try ctx.state_body.handleWith(
                ctx.all.handler,
                try ctx.state_body.lambda(ctx.choice_fn, ctx.choice_schema),
                .{},
            )),
        );
    }
    return initializeState(choice_outside, .{
        .c = ctx.c,
        .unit = ctx.unit,
        .sequence = ctx.sequence,
        .region = ctx.region,
        .cell_schema = ctx.cell_schema,
        .all = ctx.all,
        .interpreted = ctx.interpreted,
        .scope_schema = ctx.scope_schema,
        .scope_fn = ctx.scope_fn,
        .state_schema = ctx.state_schema,
        .state_fn = ctx.state_fn,
        .choice_schema = ctx.choice_schema,
        .choice_fn = ctx.choice_fn,
        .scope_body = ctx.scope_body,
        .choice_body = ctx.choice_body,
    });
}

fn initializeState(
    comptime choice_outside: bool,
    ctx: anytype,
) a.Error!source.Module {
    const cell = try ctx.scope_body.newCell(
        ctx.cell_schema,
        try ctx.scope_body.parameter("region"),
        try ctx.scope_body.constant(u64, 0),
    );
    try ctx.c.define(
        ctx.scope_fn,
        try ctx.scope_body.ret(try ctx.scope_body.handleWith(
            ctx.interpreted.handler,
            try ctx.scope_body.lambda(ctx.state_fn, ctx.state_schema),
            .{ .state = cell },
        )),
    );
    if (choice_outside) try ctx.c.define(
        ctx.choice_fn,
        try ctx.choice_body.ret(try ctx.choice_body.withRegion(
            ctx.region,
            try ctx.choice_body.lambda(ctx.scope_fn, ctx.scope_schema),
            .{},
        )),
    );
    const main = try ctx.c.function("entry", .{}, ctx.sequence, &.{});
    const entry = try ctx.c.body(main);
    const result = if (choice_outside)
        try entry.handleWith(
            ctx.all.handler,
            try entry.lambda(ctx.choice_fn, ctx.choice_schema),
            .{},
        )
    else
        try entry.withRegion(ctx.region, try entry.lambda(ctx.scope_fn, ctx.scope_schema), .{});
    try ctx.c.define(main, try entry.ret(result));
    return ctx.c.module(main, ctx.unit);
}
fn recursiveWork(
    c: *a.Context,
    parent: anytype,
    counter: *const state.Family(a.Shape(u64)),
    branch: *const choice.Family,
    region: *const a.Region,
    caps: anytype,
) a.Error!*const a.Value(a.Shape(u64)) {
    const integer = try c.schema(u64);
    const signature = try c.callable(.{ .remaining = integer }, integer, &.{
        counter.get(),
        counter.put(),
        branch.effect(),
    }, .{
        .use = .reusable,
        .captures = &.{ counter.getCapability(), counter.putCapability(), branch.capability() },
        .regions = &.{region},
    });
    const even = try c.functionFor("even", signature);
    const functions = [_]@TypeOf(even){ even, try c.functionFor("odd", signature) };
    const fault = try c.literalFailure(void, {});
    for (functions, 0..) |function, index| {
        const body = try parent.closureBody(function);
        const count = try body.parameter("remaining");
        const done = try body.branch();
        const step = try body.branch();
        const final = try done.performLocal(counter.get(), caps[0], try done.constant(void, {}));
        _ = try step.performLocal(branch.effect(), caps[2], try step.constant(void, {}));
        const before = try step.performLocal(counter.get(), caps[0], try step.constant(void, {}));
        const after = try step.checkedAdd(before, try step.constant(u64, 1), fault);
        _ = try step.performLocal(counter.put(), caps[1], after);
        const remaining = try step.checked(
            .subtract,
            count,
            try step.constant(u64, 1),
            .{ .overflow = fault },
        );
        const next = try step.call(functions[1 - index], .{ .remaining = remaining });
        try c.define(
            function,
            try body.ret(try body.conditional(
                try body.equal(count, try body.constant(u64, 0)),
                try done.ret(final),
                try step.ret(next),
            )),
        );
    }
    return parent.call(functions[0], .{ .remaining = try parent.constant(u64, 2) });
}
