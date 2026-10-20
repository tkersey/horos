// Copyright (c) 2026 Boundary contributors. MIT license.
//! Four queens uses typed construction, shared metrics and branch-local boards.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const search = @import("../library/search.zig");
pub fn dfs(b: *source.Builder) source.Error!source.Module {
    return build(b, .depth_first);
}
pub fn bfs(b: *source.Builder) source.Error!source.Module {
    return build(b, .breadth_first);
}
fn build(b: *source.Builder, order: search.Order) source.Error!source.Module {
    return authored(b, order) catch |err| return a.sourceError(err);
}
const native = @import("horos_data").schema.native;
fn safety(
    c: *a.Context,
    board: anytype,
    fault: anytype,
) a.Error!*const a.Function(a.Signature(
    native.Fields(
        &.{ "board", "column", "row" },
        &.{ a.ShapeOf(@TypeOf(board)), a.Shape(u64), a.Shape(u64) },
    ),
    a.Shape(bool),
)) {
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const function = try c.function(
        "safe placement",
        .{ .board = board, .column = integer, .row = integer },
        boolean,
        &.{},
    );
    const body = try c.body(function);
    const old = try body.parameter("board");
    const column = try body.parameter("column");
    const row = try body.parameter("row");
    const count = try body.sequenceLength(old);
    const finished = try body.branch();
    const checking = try body.branch();
    const lookup = try checking.sequenceGet(old, row);
    const missing = try checking.caseOf(lookup, "none");
    const present = try checking.caseOf(lookup, "some");
    const previous = present.payload();
    const same = try present.body().branch();
    const different = try present.body().branch();
    const left = try different.branch();
    const right = try different.branch();
    const distance = try different.conditional(
        try different.less(column, previous),
        try left.ret(try left.checked(.subtract, previous, column, .{ .overflow = fault })),
        try right.ret(try right.checked(.subtract, column, previous, .{ .overflow = fault })),
    );
    const diagonal = try different.branch();
    const next = try different.branch();
    const retried = try next.call(
        function,
        .{
            .board = old,
            .column = column,
            .row = try next.checkedAdd(row, try next.constant(u64, 1), fault),
        },
    );
    const checked = try different.conditional(
        try different.equal(
            distance,
            try different.checked(.subtract, count, row, .{ .overflow = fault }),
        ),
        try diagonal.ret(try diagonal.constant(bool, false)),
        try next.ret(retried),
    );
    const valid = try present.body().conditional(
        try present.body().equal(column, previous),
        try same.ret(try same.constant(bool, false)),
        try different.ret(checked),
    );
    // The miss is impossible on this path and remains an authored failure.
    const missing_case = try missing.fail(boolean, try missing.body().constant(void, {}));
    const result = try checking.match(
        lookup,
        .{ .none = missing_case, .some = try present.ret(valid) },
    );
    try c.define(
        function,
        try body.ret(try body.conditional(
            try body.equal(row, count),
            try finished.ret(try finished.constant(bool, true)),
            try checking.ret(result),
        )),
    );
    return function;
}
fn authored(b: *source.Builder, order: search.Order) a.Error!source.Module {
    const c = try a.Context.init(b);
    const unit = try c.schema(void);
    const boolean = try c.schema(bool);
    const integer = try c.schema(u64);
    const board = try c.sequence(integer);
    const shared = try c.region();
    const local = try c.region();
    const loan = try c.region();
    const metrics_cell = try c.cell(shared, integer);
    const board_cell = try c.cell(local, board);
    const owned = try c.resource(integer);
    const borrowed = try c.borrowed(owned, loan);
    const acquiring = try c.external("example/queens-acquire", board, integer);
    const use_payload = try c.record(.{ .handle = integer, .board = board, .attempts = integer });
    const using = try c.external("example/queens-use", use_payload, unit);
    const releasing = try c.external("example/queens-release", integer, unit);
    const residual = .{ acquiring, using, releasing };
    const family = try search.family(c, "example/queens");
    const interpretation = try search.interpret(c, family, board, .{
        .captures = .{
            .continuation = &.{
                unit,
                boolean,
                integer,
                board,
                try c.regionSchema(shared),
                try c.regionSchema(local),
                metrics_cell,
                board_cell,
            },
            .body = &.{metrics_cell},
        },
        .residual = residual,
        .owned_regions = &.{local},
        .borrowed_regions = &.{shared},
        .order = order,
    });
    const operations = .{ acquiring, using, releasing, family.pick(), family.reject() };
    const answer = try c.record(.{ .solutions = interpretation.solutions, .attempts = integer });
    const fault = try c.literalFailure(void, {});
    const safe = try safety(c, board, fault);
    const acquire = try c.function("acquire", .{ .board = board }, owned, &.{acquiring});
    const use_schema = try c.callable(
        .{ .loan = borrowed, .board = board, .attempts = integer },
        board,
        &.{using},
        .{ .use = .linear, .captures = &.{}, .regions = &.{loan} },
    );
    const use = try c.functionFor("use solution", use_schema);
    const release_schema = try c.callable(
        .{ .exit = try c.cleanupInfo(unit), .owner = owned },
        unit,
        &.{releasing},
        .{ .use = .linear, .captures = &.{} },
    );
    const release = try c.functionFor("release solution", release_schema);
    try c.resourceAuthority(owned, &.{acquire}, &.{ use, release });
    const acquire_body = try c.body(acquire);
    try c.define(
        acquire,
        try acquire_body.ret(try acquire_body.packResource(
            owned,
            try acquire_body.perform(acquiring, try acquire_body.parameter("board")),
        )),
    );
    const use_body = try c.body(use);
    _ = try use_body.perform(
        using,
        try use_body.product(
            use_payload,
            .{
                .handle = try use_body.unpackResource(try use_body.parameter("loan")),
                .board = try use_body.parameter("board"),
                .attempts = try use_body.parameter("attempts"),
            },
        ),
    );
    try c.define(use, try use_body.ret(try use_body.parameter("board")));
    const release_body = try c.body(release);
    try c.define(
        release,
        try release_body.ret(try release_body.perform(
            releasing,
            try release_body.unpackResource(try release_body.parameter("owner")),
        )),
    );
    const solve_schema = try c.callable(
        .{
            .board = board_cell,
            .metrics = metrics_cell,
            .pick = family.pickCapability(),
            .reject = family.rejectCapability(),
        },
        board,
        operations,
        .{ .use = .reusable, .captures = &.{}, .regions = &.{ shared, local } },
    );
    const solve = try c.functionFor("solve", solve_schema);
    const body = try c.body(solve);
    const cell = try body.parameter("board");
    const metrics = try body.parameter("metrics");
    const pick_cap = try body.parameter("pick");
    const reject_cap = try body.parameter("reject");
    const current = try body.readCell(cell);
    const complete = try body.branch();
    const attempt = try body.branch();
    const acquired = try complete.call(acquire, .{ .board = current });
    const completed = try complete.bracket(
        acquired,
        loan,
        try complete.lambda(use, use_schema),
        try complete.lambda(release, release_schema),
        .{ .board = current, .attempts = try complete.readCell(metrics) },
    );
    const high = try attempt.performLocal(family.pick(), pick_cap, try attempt.constant(void, {}));
    const low = try attempt.performLocal(family.pick(), pick_cap, try attempt.constant(void, {}));
    const upper = try attempt.branch();
    const lower = try attempt.branch();
    const base = try attempt.conditional(
        high,
        try upper.ret(try upper.constant(u64, 3)),
        try lower.ret(try lower.constant(u64, 1)),
    );
    const plus = try attempt.branch();
    const unchanged = try attempt.branch();
    const column = try attempt.conditional(
        low,
        try plus.ret(try plus.checkedAdd(base, try plus.constant(u64, 1), fault)),
        try unchanged.ret(base),
    );
    const count = try attempt.checkedAdd(
        try attempt.readCell(metrics),
        try attempt.constant(u64, 1),
        fault,
    );
    _ = try attempt.writeCell(metrics, count);
    const yielding = try attempt.branch();
    const continuing = try attempt.branch();
    const yielded = try yielding.yieldNow();
    _ = try attempt.conditional(
        try attempt.equal(count, try attempt.constant(u64, 1)),
        try yielding.ret(yielded),
        try continuing.ret(try continuing.constant(void, {})),
    );
    const valid = try attempt.call(
        safe,
        .{ .board = current, .column = column, .row = try attempt.constant(u64, 0) },
    );
    const accepted = try attempt.branch();
    const rejected = try attempt.branch();
    _ = try accepted.writeCell(cell, try accepted.append(current, column, .{}));
    const recurred = try accepted.call(
        solve,
        .{ .board = cell, .metrics = metrics, .pick = pick_cap, .reject = reject_cap },
    );
    _ = try rejected.performLocal(family.reject(), reject_cap, try rejected.constant(void, {}));
    const chosen = try attempt.conditional(
        valid,
        try accepted.ret(recurred),
        try rejected.ret(current),
    );
    try c.define(
        solve,
        try body.ret(try body.conditional(
            try body.equal(try body.sequenceLength(current), try body.constant(u64, 4)),
            try complete.ret(completed),
            try attempt.ret(chosen),
        )),
    );
    const outer_schema = try c.regionBodySchema(
        shared,
        .{},
        answer,
        residual,
        .{ .use = .linear, .captures = &.{} },
    );
    const outer_fn = try c.functionFor("shared metrics", outer_schema);
    const outer = try c.body(outer_fn);
    const counter = try outer.newCell(
        metrics_cell,
        try outer.parameter("region"),
        try outer.constant(u64, 0),
    );
    const handled_schema = try c.handledSchema(interpretation.handler);
    const handled_fn = try c.functionFor("search body", handled_schema);
    const handled = try outer.closureBody(handled_fn);
    const inside_schema = try c.regionBodySchema(
        local,
        .{},
        board,
        operations,
        .{
            .use = .linear,
            .captures = &.{ metrics_cell, family.pickCapability(), family.rejectCapability() },
            .regions = &.{shared},
        },
    );
    const inside_fn = try c.functionFor("branch board", inside_schema);
    const inside = try handled.closureBody(inside_fn);
    const constraints = try inside.newCell(
        board_cell,
        try inside.parameter("region"),
        try inside.sequenceValue(board, &.{}),
    );
    try c.define(
        inside_fn,
        try inside.ret(try inside.call(
            solve,
            .{
                .board = constraints,
                .metrics = counter,
                .pick = try handled.parameter("pick"),
                .reject = try handled.parameter("reject"),
            },
        )),
    );
    try c.define(
        handled_fn,
        try handled.ret(try handled.withRegion(
            local,
            try handled.lambda(inside_fn, inside_schema),
            .{},
        )),
    );
    const step = try outer.handleWith(
        interpretation.handler,
        try outer.lambda(handled_fn, handled_schema),
        .{},
    );
    const solutions = try search.collect(outer, interpretation, step);
    try c.define(
        outer_fn,
        try outer.ret(try outer.product(
            answer,
            .{ .solutions = solutions, .attempts = try outer.readCell(counter) },
        )),
    );
    const main = try c.function("entry", .{}, answer, residual);
    const entry = try c.body(main);
    try c.define(
        main,
        try entry.ret(try entry.withRegion(
            shared,
            try entry.lambda(outer_fn, outer_schema),
            .{},
        )),
    );
    return c.module(main, unit);
}
