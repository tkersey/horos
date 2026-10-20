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
    const interpreted = (try state.interpret(
        c,
        counter,
        if (choice_outside) integer else sequence,
        region,
        .{
            .continuation = &.{
                unit,
                boolean,
                integer,
                sequence,
                cell_schema,
                counter.getCapability(),
                counter.putCapability(),
                branch.capability(),
                all.resumption,
            },
            .body = if (choice_outside) &.{branch.capability()} else &.{},
        },
        if (choice_outside) &.{branch.effect()} else &.{},
        .value,
    )).value;
    const scope_schema = try c.regionBodySchema(
        region,
        .{},
        if (choice_outside) integer else sequence,
        if (choice_outside) &.{branch.effect()} else &.{},
        .{ .use = .linear, .captures = if (choice_outside) &.{branch.capability()} else &.{} },
    );
    const scope_fn = try c.functionFor("state region", scope_schema);
    const state_schema = try c.handledSchema(interpreted.handler);
    const state_fn = try c.functionFor("state work", state_schema);
    const choice_schema = try c.handledSchema(all.handler);
    const choice_fn = try c.functionFor("choice work", choice_schema);
    var scope_body: @TypeOf(try c.body(scope_fn)) = undefined;
    var state_body: @TypeOf(try c.body(state_fn)) = undefined;
    var choice_body: @TypeOf(try c.body(choice_fn)) = undefined;
    if (choice_outside) {
        choice_body = try c.body(choice_fn);
        scope_body = try choice_body.closureBody(scope_fn);
        state_body = try scope_body.closureBody(state_fn);
    } else {
        scope_body = try c.body(scope_fn);
        state_body = try scope_body.closureBody(state_fn);
        choice_body = try state_body.closureBody(choice_fn);
    }
    const work = if (choice_outside) state_body else choice_body;
    const caps = .{
        try state_body.parameter("get"),
        try state_body.parameter("put"),
        try choice_body.parameter("capability"),
    };
    const value = if (recursive) try recursiveWork(
        c,
        work,
        counter,
        branch,
        region,
        caps,
    ) else blk: {
        _ = try work.performLocal(branch.effect(), caps[2], try work.constant(void, {}));
        const before = try work.performLocal(counter.get(), caps[0], try work.constant(void, {}));
        const after = try work.checkedAdd(
            before,
            try work.constant(u64, 1),
            try c.literalFailure(void, {}),
        );
        _ = try work.performLocal(counter.put(), caps[1], after);
        break :blk after;
    };
    if (choice_outside) {
        try c.define(state_fn, try state_body.ret(value));
    } else {
        try c.define(choice_fn, try choice_body.ret(value));
        try c.define(
            state_fn,
            try state_body.ret(try state_body.handleWith(
                all.handler,
                try state_body.lambda(choice_fn, choice_schema),
                .{},
            )),
        );
    }
    const cell = try scope_body.newCell(
        cell_schema,
        try scope_body.parameter("region"),
        try scope_body.constant(u64, 0),
    );
    try c.define(
        scope_fn,
        try scope_body.ret(try scope_body.handleWith(
            interpreted.handler,
            try scope_body.lambda(state_fn, state_schema),
            .{ .state = cell },
        )),
    );
    if (choice_outside) try c.define(
        choice_fn,
        try choice_body.ret(try choice_body.withRegion(
            region,
            try choice_body.lambda(scope_fn, scope_schema),
            .{},
        )),
    );
    const main = try c.function("entry", .{}, sequence, &.{});
    const entry = try c.body(main);
    const result = if (choice_outside)
        try entry.handleWith(all.handler, try entry.lambda(choice_fn, choice_schema), .{})
    else
        try entry.withRegion(region, try entry.lambda(scope_fn, scope_schema), .{});
    try c.define(main, try entry.ret(result));
    return c.module(main, unit);
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
