const source = @import("source.zig");
const a = @import("authoring.zig");
const hyper = @import("library/hyper.zig");
const native = @import("horos_data").schema.native;

pub const Output = struct { value: u64, flag: bool };

fn Transform(comptime Input: type, comptime Result: type) type {
    return a.Function(a.Signature(
        native.Fields(&.{"argument"}, &.{hyper.Delayed(Input)}),
        hyper.Delayed(Result),
    ));
}

fn rightTransform(
    c: *a.Context,
    types: *const hyper.Pair(a.Shape(u8), a.Shape(u64)),
) a.Error!*const Transform(a.Shape(u8), a.Shape(u64)) {
    const transform = try c.function("widen and add", .{
        .argument = types.answerBackward(),
    }, types.answerForward(), .{});
    const body = try c.body(transform);
    const argument = try body.parameter("argument");
    const answer = try c.functionFor("right answer", types.answerForward());
    const nested = try body.closureBody(answer);
    const input = try hyper.force(nested, argument);
    const wide = try nested.convertInteger(types.output(), input, .{});
    const result = try nested.checkedAdd(
        wide,
        try nested.constant(u64, 3),
        try c.literalFailure(void, {}),
    );
    try c.define(answer, try nested.ret(result));
    try c.define(transform, try body.ret(try body.lambda(answer, types.answerForward())));
    return transform;
}

fn leftTransform(
    c: *a.Context,
    types: *const hyper.Pair(a.Shape(u64), a.Shape(Output)),
) a.Error!*const Transform(a.Shape(u64), a.Shape(Output)) {
    const transform = try c.function("double and mark", .{
        .argument = types.answerBackward(),
    }, types.answerForward(), .{});
    const body = try c.body(transform);
    const argument = try body.parameter("argument");
    const answer = try c.functionFor("left answer", types.answerForward());
    const nested = try body.closureBody(answer);
    const input = try hyper.force(nested, argument);
    const result = try nested.product(types.output(), .{
        .value = try nested.checkedAdd(input, input, try c.literalFailure(void, {})),
        .flag = try nested.equal(input, try nested.constant(u64, 10)),
    });
    try c.define(answer, try nested.ret(result));
    try c.define(transform, try body.ret(try body.lambda(answer, types.answerForward())));
    return transform;
}

pub fn build(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const interfaces = try hyper.group(c, .{
        .input = try c.schema(u8),
        .middle = try c.schema(u64),
        .output = try c.schema(Output),
    }, .{});
    const ab = interfaces.get("input", "middle");
    const bc = interfaces.get("middle", "output");
    const ac = interfaces.get("input", "output");
    const right_transform = try rightTransform(c, ab);
    const left_transform = try leftTransform(c, bc);
    const entry = try c.function("entry", .{ .input = ab.input() }, bc.output(), .{});
    const body = try c.body(entry);
    const right_tail = try hyper.base(body, ab, try hyper.deferValue(
        body,
        ab.answerForward(),
        try body.constant(u64, 101),
    ));
    const left_tail = try hyper.base(body, bc, try hyper.deferValue(
        body,
        bc.answerForward(),
        try body.product(bc.output(), .{
            .value = try body.constant(u64, 900),
            .flag = try body.constant(bool, false),
        }),
    ));
    const right = try hyper.push(
        body,
        ab,
        right_transform,
        try hyper.deferValue(body, ab.peerForward(), right_tail),
    );
    const left = try hyper.push(
        body,
        bc,
        left_transform,
        try hyper.deferValue(body, bc.peerForward(), left_tail),
    );
    const combined = try hyper.compose(body, interfaces, "input", "middle", "output", left, right);
    const input = try hyper.deferValue(body, ac.answerBackward(), try body.parameter("input"));
    const result = try hyper.force(body, try hyper.project(body, ac, combined, input));
    try c.define(entry, try body.ret(result));
    return c.module(entry, try c.schema(void));
}
