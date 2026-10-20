//! Complete source reference roles, separate from portable slot/catalog roles.
const std = @import("std");
const p = @import("horos_data").program;
const ast = @import("ast.zig");
const Tag = std.meta.Tag(ast.Term);
const MatchCase = @typeInfo(@FieldType(@FieldType(ast.Term, "match_sum"), "cases")).pointer.child;
pub const Role = enum {
    value,
    term,
    bound,
    function,
    effect,
    handler,
    region,
    match_case,
    nonreference,
};
pub const Cardinality = enum { one, optional, list };
const Field = struct { name: []const u8, Type: type, role: Role, cardinality: Cardinality };
fn field(
    comptime name: []const u8,
    comptime T: type,
    comptime role: Role,
    comptime cardinality: Cardinality,
) Field {
    return .{ .name = name, .Type = T, .role = role, .cardinality = cardinality };
}
const case_fields = &[_]Field{
    field("variable", p.Id, .bound, .one),
    field("body", p.Id, .term, .one),
};
fn fields(comptime tag: Tag) []const Field {
    return switch (tag) {
        .value, .dispose, .fail, .yield_then => &.{},
        .bind => &.{
            field("variable", p.Id, .bound, .one),
            field("value", p.Id, .term, .one),
            field("next", p.Id, .term, .one),
        },
        .conditional => &.{
            field("condition", p.Id, .value, .one),
            field("when_true", p.Id, .term, .one),
            field("when_false", p.Id, .term, .one),
        },
        .call => &.{
            field("function", p.Id, .function, .one),
            field("arguments", []const p.Id, .value, .list),
        },
        .apply => &.{
            field("computation", p.Id, .value, .one),
            field("arguments", []const p.Id, .value, .list),
        },
        .perform => &.{
            field("effect", p.Id, .effect, .one),
            field("capability", ?p.Id, .value, .optional),
            field("payload", p.Id, .value, .one),
            field("bodies", []const p.Id, .value, .list),
            field("use_site_capabilities", []const p.Id, .value, .list),
        },
        .handle => &.{
            field("handler", p.Id, .handler, .one),
            field("body", p.Id, .value, .one),
            field("arguments", []const p.Id, .value, .list),
            field("state", []const p.Id, .value, .list),
        },
        .resume_value => &.{
            field("resumption", p.Id, .value, .one),
            field("argument", p.Id, .value, .one),
        },
        .resume_with => &.{
            field("resumption", p.Id, .value, .one),
            field("argument", p.Id, .value, .one),
            field("handler", p.Id, .handler, .one),
            field("state", []const p.Id, .value, .list),
        },
        .resume_computation => &.{
            field("resumption", p.Id, .value, .one),
            field("computation", p.Id, .value, .one),
        },
        .protect => &.{
            field("body", p.Id, .value, .one),
            field("cleanup", p.Id, .value, .one),
            field("arguments", []const p.Id, .value, .list),
            field("resource", ?p.Id, .value, .optional),
            field("loan_region", ?p.Id, .region, .optional),
        },
        .with_region => &.{
            field("region", p.Id, .region, .one),
            field("body", p.Id, .value, .one),
            field("arguments", []const p.Id, .value, .list),
        },
        .match_sum => &.{
            field("value", p.Id, .value, .one),
            field("cases", []const MatchCase, .match_case, .list),
        },
        .unpack_product => &.{
            field("value", p.Id, .value, .one),
            field("variables", []const p.Id, .bound, .list),
            field("body", p.Id, .term, .one),
        },
    };
}
fn validateFields(comptime T: type, comptime expected: []const Field) void {
    if (@typeInfo(T) != .@"struct") @compileError("source reference roles: expected a record");
    const actual = @typeInfo(T).@"struct";
    if (actual.field_names.len != expected.len) @compileError(
        "source reference roles: unclassified or missing field",
    );
    for (actual.field_names, actual.field_types, expected) |name, Type, wanted| {
        if (!std.mem.eql(
            u8,
            name,
            wanted.name,
        )) @compileError("source reference roles: changed field name or declaration order");
        if (Type != wanted.Type) @compileError("source reference roles: changed type of " ++ name);
    }
}
pub fn validateTermPayload(comptime tag: Tag, comptime T: type) void {
    switch (tag) {
        .value, .dispose, .fail, .yield_then => if (T != p.Id) @compileError(
            "source reference roles: changed direct reference type",
        ),
        else => validateFields(T, fields(tag)),
    }
}
pub fn validateMatchCase(comptime T: type) void {
    validateFields(T, case_fields);
}
fn ErrorOf(comptime T: type) type {
    return @typeInfo(T).pointer.child.VisitError;
}
fn visitFields(
    value: anytype,
    comptime description: []const Field,
    comptime order: []const usize,
    visitor: anytype,
) ErrorOf(@TypeOf(visitor))!void {
    comptime validateFields(@TypeOf(value), description);
    inline for (order) |i| {
        const rule = description[i];
        try visitor.reference(rule.role, rule.cardinality, @field(value, rule.name));
    }
}
fn visitation(comptime tag: Tag) []const usize {
    return switch (tag) {
        .bind => &.{ 1, 2, 0 },
        .perform => &.{ 0, 2, 1, 3, 4 },
        .unpack_product => &.{ 0, 2, 1 },
        else => blk: {
            const n = fields(tag).len;
            const order = comptime init: {
                var value: [n]usize = undefined;
                for (&value, 0..) |*v, i| v.* = i;
                break :init value;
            };
            break :blk &order;
        },
    };
}
pub fn visitTerm(value: ast.Term, visitor: anytype) ErrorOf(@TypeOf(visitor))!void {
    switch (value) {
        inline else => |payload, tag| {
            comptime validateTermPayload(tag, @TypeOf(payload));
            switch (tag) {
                .value, .dispose, .fail => try visitor.reference(.value, .one, payload),
                .yield_then => try visitor.reference(.term, .one, payload),
                else => try visitFields(payload, fields(tag), visitation(tag), visitor),
            }
        },
    }
}
pub fn visitMatchCase(value: MatchCase, visitor: anytype) ErrorOf(@TypeOf(visitor))!void {
    return visitFields(value, case_fields, &.{ 0, 1 }, visitor);
}
test "source reference roles cover every term operation and match-arm field" {
    comptime {
        for (std.meta.tags(Tag)) |tag| {
            validateTermPayload(tag, @FieldType(ast.Term, @tagName(tag)));
            const order = visitation(tag);
            if (order.len != fields(tag).len) @compileError("source reference roles: incomplete visitation sequence");
            for (order, 0..) |i, offset| {
                if (i >= order.len) @compileError(
                    "source reference roles: invalid visitation index",
                );
                for (order[0..offset]) |prior| if (prior == i) @compileError(
                    "source reference roles: repeated visitation index",
                );
            }
        }
        validateMatchCase(MatchCase);
    }
}
