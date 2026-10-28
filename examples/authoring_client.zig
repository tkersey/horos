//! Public-package client: all generated branching and interpretation is Program code.
const std = @import("std");
const horos = @import("horos");
const a = horos.authoring;

pub const Application = struct {
    pub fn emit(raw: *horos.source.Builder) !horos.source.Module {
        const c = try a.Context.init(raw);
        const integer = try c.schema(u64);
        const boolean = try c.schema(bool);
        const unit = try c.schema(void);
        const input = try c.record(.{ .input = integer, .offset = integer });
        const lookup = try c.external("client/lookup", integer, integer);
        const question = try c.local("client/question", integer, integer, .linear);
        const capability = try c.capability(question);
        const callable = try c.callable(
            .{},
            integer,
            &.{question},
            .{ .use = .reusable, .captures = &.{ integer, capability } },
        );
        const failure = try c.literalFailure(void, {});
        const responder = try c.function(
            "lookup responder",
            .{ .key = integer },
            integer,
            &.{lookup},
        );
        const response = try c.body(responder);
        try c.define(
            responder,
            try response.ret(try response.perform(lookup, try response.parameter("key"))),
        );
        const h = try c.responder(question, integer, responder, .{
            .mode = .deep,
            .use = .linear,
            .residual = &.{lookup},
            .captures = &.{ integer, input, capability, callable },
            .body_captures = &.{integer},
        });
        const entry = try c.function(
            "entry",
            .{ .use_effect = boolean, .numbers = input },
            integer,
            &.{lookup},
        );
        const body = try c.body(entry);
        const numbers = try mixedNumbers(c, body, try body.parameter("numbers"), input);
        const x = try body.field(numbers, "input");
        const offset = try body.field(numbers, "offset");
        const yes = try body.branch();
        const no = try body.branch();
        const handled = try c.handledSchema(h);
        const work = try c.functionFor("interpreted work", handled);
        const interpreted = try yes.closureBody(work);
        const cap = try interpreted.parameter("capability");
        const query = try c.functionFor("reusable question", callable);
        const query_body = try interpreted.closureBody(query);
        try c.define(query, try query_body.ret(try query_body.performLocal(question, cap, x)));
        const ask = try interpreted.lambda(query, callable);
        const first = try interpreted.apply(ask, .{});
        const partial = try interpreted.checkedAdd(first, offset, failure);
        const second = try interpreted.apply(ask, .{});
        const result = try interpreted.checkedAdd(partial, second, failure);
        try c.define(work, try interpreted.ret(result));
        const true_result = try yes.handleWith(h, try yes.lambda(work, handled), .{});
        const false_result = try no.checkedAdd(x, offset, failure);
        const joined = try body.conditional(
            try body.parameter("use_effect"),
            try yes.ret(true_result),
            try no.ret(false_result),
        );
        try c.define(entry, try body.ret(joined));
        return c.module(entry, unit);
    }
};
fn mixedNumbers(
    c: *a.Context,
    body: anytype,
    numbers: anytype,
    input: anytype,
) !*const a.Value(a.ShapeOf(@TypeOf(input))) {
    const search = horos.library.search;
    const samples = try c.schema(horos.data.schema.native.Vector(u8, 4));
    const payload = try c.record(.{ .numbers = input, .samples = samples });
    const family = try search.family(c, "client/search");
    const searching = try search.interpret(c, family, payload, .{
        .captures = .{ .continuation = .{} },
        .order = .depth_first,
    });
    const callable = try c.callable(.{
        .step = searching.step,
        .queue = searching.queue,
        .found = searching.solutions,
    }, searching.solutions, .{}, .{ .use = .reusable, .captures = .{} });
    const record = try c.record(.{ .explore = callable, .payload = payload });
    const supplied = try body.product(record, .{
        .explore = try body.lambda(searching.explore, callable),
        .payload = try body.product(payload, .{
            .numbers = numbers,
            .samples = try body.sequenceValue(samples, .{try body.constant(u8, 7)}),
        }),
    });
    const returned = try scopedRecord(c, body, supplied, record);
    comptime if (@TypeOf(returned) != @TypeOf(supplied))
        @compileError("client: scoped record lost its named callable or payload shape");
    const solutions = try body.apply(try body.field(returned, "explore"), .{
        .step = try body.variant(searching.step, "solution", try body.field(returned, "payload")),
        .queue = try body.sequenceValue(searching.queue, .{}),
        .found = try body.sequenceValue(searching.solutions, .{}),
    });
    comptime if (a.ShapeOf(@TypeOf(solutions)) != a.ShapeOf(@TypeOf(searching.solutions)))
        @compileError("client: returned library callable lost its result shape");
    return firstNumbers(body, solutions, input);
}

fn scopedRecord(
    c: *a.Context,
    body: anytype,
    supplied: anytype,
    record: anytype,
) !*const a.Value(a.ShapeOf(@TypeOf(record))) {
    const reader = horos.library.reader;
    const unit = try c.schema(void);
    const family = try reader.family(c, "client/scoped-record", unit, unit, .{
        .inside_captures = .{},
        .residual = .{},
        .borrowed_regions = .{},
    });
    const interpreted = try reader.interpret(c, family, record, .{
        .captures = .{ .continuation = .{record}, .body = .{record} },
    });
    const inside_fn = try c.functionFor("read scoped record", family.inside());
    const inside = try c.body(inside_fn);
    try c.define(inside_fn, try inside.ret(try inside.performLocal(
        family.ask(),
        try inside.parameter("ask"),
        try inside.constant(void, {}),
    )));
    const handled = try c.handledSchema(interpreted.handler);
    const work_fn = try c.functionFor("return scoped record", handled);
    const work = try body.closureBody(work_fn);
    _ = try work.performScoped(
        family.local(),
        try work.parameter("local"),
        try work.constant(void, {}),
        .{ .inside = try work.lambda(inside_fn, family.inside()) },
    );
    try c.define(work_fn, try work.ret(supplied));
    return body.handleWith(interpreted.handler, try body.lambda(work_fn, handled), .{
        .environment = try body.constant(void, {}),
    });
}

fn firstNumbers(
    body: anytype,
    solutions: anytype,
    input: anytype,
) !*const a.Value(a.ShapeOf(@TypeOf(input))) {
    const first = try body.sequenceGet(solutions, try body.constant(u64, 0));
    const some = try body.caseOf(first, "some");
    const none = try body.caseOf(first, "none");
    const payload = some.payload();
    const samples = try some.body().field(payload, "samples");
    comptime if (a.ShapeOf(@TypeOf(samples)) != a.Shape(horos.data.schema.native.Vector(u8, 4)))
        @compileError("client: scoped payload lost its element type or bound");
    const numbers = try some.body().field(payload, "numbers");
    comptime if (a.ShapeOf(@TypeOf(numbers)) != a.ShapeOf(@TypeOf(input)))
        @compileError("client: scoped payload lost its nested named fields");
    return body.match(first, .{
        .some = try some.ret(numbers),
        .none = try none.fail(input, try none.body().constant(void, {})),
    });
}

pub fn main(init: std.process.Init) !void {
    var compiled = try horos.program.lower(init.gpa, Application);
    defer compiled.deinit();
    const bytes = try init.gpa.alloc(
        u8,
        try horos.data.program_image.encodedLength(compiled.program),
    );
    defer init.gpa.free(bytes);
    _ = try compiled.encode(init.gpa, bytes);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(bytes);
    try output.interface.flush();
}
