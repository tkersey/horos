// Copyright (c) 2026 Boundary contributors. MIT license.
//! The same row-polymorphic choice library composes with two unrelated results
//! from a finite indexed environmental family.
const source = @import("../source.zig");
const a = @import("../authoring.zig");
const choice = @import("../library/choice.zig");
const p = @import("horos_data").program;

pub fn build(b: *source.Builder) source.Error!source.Module {
    return buildTypedDeclarations(b) catch |err| return a.sourceError(err);
}

fn buildTypedDeclarations(b: *source.Builder) a.Error!source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const c = try a.Context.init(b);
    const payload = try a.interop.schema(c, unit);
    // The independent source-IR fixture consumes checked operation declarations;
    // its explicit terms continue to exercise row-polymorphic source semantics.
    const family = [_]p.Id{
        try a.interop.operationId(
            c,
            try c.external("example/indexed/number", payload, try a.interop.schema(c, integer)),
        ),
        try a.interop.operationId(
            c,
            try c.external("example/indexed/flag", payload, try a.interop.schema(c, boolean)),
        ),
    };
    const choice_family = try choice.family(c, "example/row-polymorphic-choice");
    const choose = .{
        .effect = try a.interop.operationId(c, choice_family.effect()),
        .capability = try a.interop.schemaId(c, choice_family.capability()),
    };
    const built = try defineInterpretations(b, c, family, integer, boolean, choice_family, choose);
    const terms = built.terms;
    const answers = built.answers;
    const result = try b.schema(.{ .product = &answers });
    const main = try b.declare(&.{}, result, &family, &.{});
    const first = try b.variable(answers[0]);
    const second = try b.variable(answers[1]);
    try b.define(
        main,
        try b.bind(
            first,
            terms[0],
            try b.bind(
                second,
                terms[1],
                try b.pure(try b.primitive(
                    result,
                    .product,
                    &.{ try b.reference(first), try b.reference(second) },
                    0,
                )),
            ),
        ),
    );
    return b.module(main, unit);
}

fn defineInterpretations(
    b: *source.Builder,
    c: *a.Context,
    family: [2]p.Id,
    integer: p.Id,
    boolean: p.Id,
    choice_family: anytype,
    choose: anytype,
) a.Error!struct { terms: [2]p.Id, answers: [2]p.Id } {
    var terms: [2]p.Id = undefined;
    var answers: [2]p.Id = undefined;
    for (family, [_]p.Id{ integer, boolean }, 0..) |effect, result, index| {
        const interpreted = try choice.first(
            c,
            choice_family,
            try a.interop.schema(c, result),
            .{
                .captures = .{ .continuation = &.{} },
                .residual = &.{try a.interop.operation(c, effect)},
            },
        );
        const interpretation = .{
            .answer = try a.interop.schemaId(c, interpreted.answer),
            .handler = try a.interop.handlerId(c, interpreted.handler),
        };
        answers[index] = interpretation.answer;
        const body = try b.declare(
            &.{choose.capability},
            result,
            &.{ effect, choose.effect },
            &.{},
        );
        const picked = try b.term(.{ .perform = .{
            .effect = choose.effect,
            .capability = try b.reference(b.parameter(body, 0)),
            .payload = try b.constant(void, {}),
        } });
        const indexed = try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.constant(void, {}),
        } });
        try b.define(body, try b.bind(try b.variable(boolean), picked, indexed));
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{choose.capability},
            .result = result,
            .effects = &.{ effect, choose.effect },
        } } });
        terms[index] = try b.term(.{ .handle = .{
            .handler = interpretation.handler,
            .body = try b.lambda(body, body_type),
        } });
    }
    return .{ .terms = terms, .answers = answers };
}
