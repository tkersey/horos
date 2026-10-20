// Copyright (c) 2026 Boundary contributors. MIT license.
//! Independently emitted object witnesses, with no emitter cache or shared builder.
const std = @import("std");
const source = @import("source.zig");
const data = @import("horos_data");
const Id = data.program.Id;
pub const Kind = enum {
    leaf,
    client,
    region_leaf,
    resource_leaf,
    effect_leaf,
    effect_import_leaf,
    effect_client,
};

pub fn emit(a: std.mem.Allocator, kind: Kind) ![]u8 {
    var builder = source.Builder.init(a);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    var compiled = switch (kind) {
        .leaf => try leaf(a, &builder, integer, unit),
        .client, .effect_client => try client(a, &builder, integer, unit, kind == .effect_client),
        .region_leaf, .resource_leaf => try nominalLeaf(a, &builder, integer, unit, kind),
        .effect_leaf, .effect_import_leaf => try effectLeaf(
            a,
            &builder,
            integer,
            unit,
            kind == .effect_import_leaf,
        ),
    };
    defer compiled.deinit();
    const bytes = try a.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer a.free(bytes);
    _ = try compiled.encode(a, bytes);
    return bytes;
}

fn addTen(b: *source.Builder, integer: Id, value: Id) !Id {
    return b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ value, try b.constant(u64, 10) },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
}

fn nominalLeaf(
    a: std.mem.Allocator,
    b: *source.Builder,
    integer: Id,
    unit: Id,
    kind: Kind,
) !source.component.Compiled {
    const main = try b.declare(&.{integer}, integer, &.{}, &.{});
    const argument = try b.reference(b.parameter(main, 0));
    if (kind == .resource_leaf) {
        const resource = try b.resource(integer);
        try b.resourceAuthority(resource, &.{main}, &.{main});
        const wrapped = try b.primitive(resource, .resource_pack, &.{argument}, 0);
        const value = try b.primitive(integer, .resource_unpack, &.{wrapped}, 0);
        try b.define(main, try b.pure(try addTen(b, integer, value)));
    } else {
        const region = b.region();
        const token = try b.schema(.{ .internal = .{ .region = region } });
        const cell_type = try b.schema(.{ .internal = .{ .cell = .{
            .element = integer,
            .region = region,
        } } });
        const inside = try b.declare(&.{token}, integer, &.{}, &.{region});
        const cell = try b.variable(cell_type);
        const allocated = try b.primitive(cell_type, .cell_new, &.{
            try b.reference(b.parameter(inside, 0)), argument,
        }, 0);
        const read = try b.primitive(integer, .cell_get, &.{try b.reference(cell)}, 0);
        try b.define(
            inside,
            try b.bind(cell, try b.pure(allocated), try b.pure(try addTen(b, integer, read))),
        );
        const shape = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{token},
            .result = integer,
            .capture_bound = &.{integer},
            .regions = &.{region},
            .use = .linear,
        } } });
        try b.define(main, try b.term(.{ .with_region = .{
            .region = region,
            .body = try b.lambda(inside, shape),
        } }));
    }
    return source.component.compileObserved(a, b.module(main, unit), .{
        .exports = &.{.{ .name = "main", .reference = .{ .kind = .function, .id = main } }},
    }, .{});
}

fn leaf(
    a: std.mem.Allocator,
    b: *source.Builder,
    integer: Id,
    unit: Id,
) !source.component.Compiled {
    const main = try b.declare(&.{integer}, integer, &.{}, &.{});
    const helper = try b.declare(&.{integer}, integer, &.{}, &.{});
    const shape = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{integer},
        .result = integer,
        .capture_bound = &.{integer},
        .use = .reusable,
    } } });
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const sum = try b.value(.{ .schema = integer, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{
            try b.reference(b.parameter(helper, 0)),
            try b.reference(b.parameter(main, 0)),
        },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
    } } });
    try b.define(helper, try b.pure(sum));
    const closure = try b.variable(shape);
    const apply = try b.term(.{ .apply = .{
        .computation = try b.reference(closure),
        .arguments = &.{try b.constant(u64, 10)},
    } });
    try b.define(main, try b.bind(closure, try b.pure(try b.lambda(helper, shape)), apply));
    return source.component.compileObserved(a, b.module(main, unit), .{
        .exports = &.{.{ .name = "main", .reference = .{ .kind = .function, .id = main } }},
    }, .{});
}

fn effectLeaf(
    a: std.mem.Allocator,
    b: *source.Builder,
    integer: Id,
    unit: Id,
    imported: bool,
) !source.component.Compiled {
    const effect = try b.effect(.{
        .identity = "coalescing/component-read",
        .payload = integer,
        .result = integer,
    });
    const main = try b.declare(&.{integer}, integer, &.{effect}, &.{});
    try b.define(
        main,
        try b.term(.{ .perform = .{
            .effect = effect,
            .payload = try b.reference(b.parameter(main, 0)),
        } }),
    );
    const read: data.component.Symbol = .{
        .name = "read",
        .reference = .{ .kind = .effect, .id = effect },
    };
    return source.component.compileObserved(a, b.module(main, unit), .{
        .imports = if (imported) &.{read} else &.{},
        .exports = &.{ .{ .name = "main", .reference = .{ .kind = .function, .id = main } }, read },
    }, .{});
}

fn client(
    a: std.mem.Allocator,
    b: *source.Builder,
    integer: Id,
    unit: Id,
    external: bool,
) !source.component.Compiled {
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    var effects: [2]Id = undefined;
    if (external) for (&effects) |*effect| {
        effect.* = try b.effect(.{
            .identity = "coalescing/component-read",
            .payload = integer,
            .result = integer,
        });
    };
    const first = try b.declare(&.{integer}, integer, if (external) effects[0..1] else &.{}, &.{});
    const second = try b.declare(&.{integer}, integer, if (external) effects[1..2] else &.{}, &.{});
    const main = try b.declare(&.{}, pair, if (external) &effects else &.{}, &.{});
    const left = try b.variable(integer);
    const right = try b.variable(integer);
    const call_left = try b.term(.{ .call = .{
        .function = first,
        .arguments = &.{try b.constant(u64, 3)},
    } });
    const call_right = try b.term(.{ .call = .{
        .function = second,
        .arguments = &.{try b.constant(u64, 7)},
    } });
    const result = try b.primitive(
        pair,
        .product,
        &.{ try b.reference(left), try b.reference(right) },
        0,
    );
    try b.define(
        main,
        try b.bind(left, call_left, try b.bind(right, call_right, try b.pure(result))),
    );
    var imports: [4]data.component.Symbol = undefined;
    imports[0] = .{ .name = "a", .reference = .{ .kind = .function, .id = first } };
    imports[1] = .{ .name = "b", .reference = .{ .kind = .function, .id = second } };
    if (external) {
        imports[2] = .{ .name = "a-read", .reference = .{ .kind = .effect, .id = effects[0] } };
        imports[3] = .{ .name = "b-read", .reference = .{ .kind = .effect, .id = effects[1] } };
    }
    return source.component.compileObserved(a, b.module(main, unit), .{
        .imports = imports[0..@as(usize, if (external) 4 else 2)],
        .borrows = &.{ .{ .function = first }, .{ .function = second } },
        .exports = &.{.{ .name = "main", .reference = .{ .kind = .function, .id = main } }},
    }, .{});
}
