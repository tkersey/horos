//! Complete portable control reference roles. These describe representation,
//! not transformation validity or simultaneous-assignment semantics.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
pub const Role = enum { slot_read, slot_write, function, effect, handler, region, block, edge, assignment, source, nonreference };
pub const Cardinality = enum { one, optional, list };
const Field = struct { name: []const u8, Type: type, role: Role, cardinality: Cardinality };
fn field(comptime name: []const u8, comptime T: type, comptime role: Role, comptime cardinality: Cardinality) Field {
    return .{ .name = name, .Type = T, .role = role, .cardinality = cardinality };
}
const edge_fields = &[_]Field{ field("block", p.Id, .block, .one), field("assignments", []const ir.Assignment, .assignment, .list) };
const assignment_fields = &[_]Field{ field("destination", p.Id, .slot_write, .one), field("source", ir.Source, .source, .one) };
fn fields(comptime tag: p.TerminatorTag) []const Field {
    return switch (tag) {
        .return_value, .fail, .jump, .yield_value => &.{},
        .branch => &.{ field("condition", p.Id, .slot_read, .one), field("when_true", ir.Edge, .edge, .one), field("when_false", ir.Edge, .edge, .one) },
        .switch_variant => &.{ field("value", p.Id, .slot_read, .one), field("cases", []const ir.Edge, .edge, .list) },
        .unpack_product => &.{ field("value", p.Id, .slot_read, .one), field("destinations", []const p.Id, .slot_write, .list), field("next", ir.Edge, .edge, .one) },
        .call => &.{ field("function", p.Id, .function, .one), field("arguments", []const p.Id, .slot_read, .list), field("next", ir.Edge, .edge, .one) },
        .perform => &.{ field("effect", p.Id, .effect, .one), field("capability", ?p.Id, .slot_read, .optional), field("payload", p.Id, .slot_read, .one), field("bodies", []const p.Id, .slot_read, .list), field("use_site_capabilities", []const p.Id, .slot_read, .list), field("next", ir.Edge, .edge, .one) },
        .apply => &.{ field("computation", p.Id, .slot_read, .one), field("arguments", []const p.Id, .slot_read, .list), field("next", ir.Edge, .edge, .one) },
        .handle => &.{ field("handler", p.Id, .handler, .one), field("body", p.Id, .slot_read, .one), field("arguments", []const p.Id, .slot_read, .list), field("state", []const p.Id, .slot_read, .list), field("next", ir.Edge, .edge, .one) },
        .resume_value => &.{ field("resumption", p.Id, .slot_read, .one), field("argument", p.Id, .slot_read, .one), field("next", ir.Edge, .edge, .one) },
        .resume_with => &.{ field("resumption", p.Id, .slot_read, .one), field("argument", p.Id, .slot_read, .one), field("handler", p.Id, .handler, .one), field("state", []const p.Id, .slot_read, .list), field("next", ir.Edge, .edge, .one) },
        .resume_computation => &.{ field("resumption", p.Id, .slot_read, .one), field("computation", p.Id, .slot_read, .one), field("next", ir.Edge, .edge, .one) },
        .dispose => &.{ field("owned", p.Id, .slot_read, .one), field("next", ir.Edge, .edge, .one) },
        .protect => &.{ field("body", p.Id, .slot_read, .one), field("cleanup", p.Id, .slot_read, .one), field("arguments", []const p.Id, .slot_read, .list), field("resource", ?p.Id, .slot_read, .optional), field("loan_region", ?p.Id, .region, .optional), field("next", ir.Edge, .edge, .one) },
        .with_region => &.{ field("region", p.Id, .region, .one), field("body", p.Id, .slot_read, .one), field("arguments", []const p.Id, .slot_read, .list), field("next", ir.Edge, .edge, .one) },
    };
}
pub fn validateFields(comptime T: type, comptime expected: []const Field) void {
    if (@typeInfo(T) != .@"struct") @compileError("portable reference roles: expected a record");
    const actual = @typeInfo(T).@"struct";
    if (actual.field_names.len != expected.len) @compileError("portable reference roles: unclassified or missing field");
    for (actual.field_names, actual.field_types, expected) |name, Type, wanted| {
        if (!std.mem.eql(u8, name, wanted.name)) @compileError("portable reference roles: changed field name or declaration order");
        if (Type != wanted.Type) @compileError("portable reference roles: changed type of " ++ name);
    }
}
pub fn validateTerminatorPayload(comptime tag: p.TerminatorTag, comptime T: type) void {
    switch (tag) {
        .return_value, .fail => if (T != p.Id) @compileError("portable reference roles: changed slot payload type"),
        .jump, .yield_value => {
            if (T != ir.Edge) @compileError("portable reference roles: changed edge payload type");
            validateFields(T, edge_fields);
        },
        else => validateFields(T, fields(tag)),
    }
}
fn ErrorOf(comptime T: type) type {
    return @typeInfo(T).pointer.child.VisitError;
}
fn visitFields(value: anytype, comptime description: []const Field, visitor: anytype) ErrorOf(@TypeOf(visitor))!void {
    comptime validateFields(@TypeOf(value), description);
    inline for (description) |rule| try visitor.reference(rule.role, rule.cardinality, @field(value, rule.name));
}
pub fn visitTerminator(value: ir.Terminator, visitor: anytype) ErrorOf(@TypeOf(visitor))!void {
    switch (value) {
        inline else => |payload, tag| {
            comptime validateTerminatorPayload(tag, @TypeOf(payload));
            switch (tag) {
                .return_value, .fail => try visitor.reference(.slot_read, .one, payload),
                .jump, .yield_value => try visitor.reference(.edge, .one, payload),
                else => try visitFields(payload, fields(tag), visitor),
            }
        },
    }
}
pub fn visitEdge(value: ir.Edge, visitor: anytype) ErrorOf(@TypeOf(visitor))!void {
    return visitFields(value, edge_fields, visitor);
}
pub fn visitAssignment(value: ir.Assignment, visitor: anytype) ErrorOf(@TypeOf(visitor))!void {
    return visitFields(value, assignment_fields, visitor);
}
pub fn visitSource(value: ir.Source, visitor: anytype) ErrorOf(@TypeOf(visitor))!void {
    comptime validateSource(ir.Source);
    switch (value) {
        .slot => |id| try visitor.reference(.slot_read, .one, id),
        .returned => try visitor.reference(.nonreference, .one, {}),
    }
}
fn mapFields(value: anytype, comptime description: []const Field, mapper: anytype) ErrorOf(@TypeOf(mapper))!@TypeOf(value) {
    comptime validateFields(@TypeOf(value), description);
    var result: @TypeOf(value) = undefined;
    inline for (description) |rule| @field(result, rule.name) = try mapper.reference(rule.role, rule.cardinality, @field(value, rule.name));
    return result;
}
pub fn mapTerminator(value: ir.Terminator, mapper: anytype) ErrorOf(@TypeOf(mapper))!ir.Terminator {
    return switch (value) {
        inline else => |payload, tag| blk: {
            comptime validateTerminatorPayload(tag, @TypeOf(payload));
            const mapped = switch (tag) {
                .return_value, .fail => try mapper.reference(.slot_read, .one, payload),
                .jump, .yield_value => try mapper.reference(.edge, .one, payload),
                else => try mapFields(payload, fields(tag), mapper),
            };
            break :blk @unionInit(ir.Terminator, @tagName(tag), mapped);
        },
    };
}
pub fn mapEdge(value: ir.Edge, mapper: anytype) ErrorOf(@TypeOf(mapper))!ir.Edge {
    return mapFields(value, edge_fields, mapper);
}
pub fn mapAssignment(value: ir.Assignment, mapper: anytype) ErrorOf(@TypeOf(mapper))!ir.Assignment {
    return mapFields(value, assignment_fields, mapper);
}
pub fn mapSource(value: ir.Source, mapper: anytype) ErrorOf(@TypeOf(mapper))!ir.Source {
    comptime validateSource(ir.Source);
    return switch (value) {
        .slot => |id| .{ .slot = try mapper.reference(.slot_read, .one, id) },
        .returned => .returned,
    };
}
pub fn validateSource(comptime T: type) void {
    const info = @typeInfo(T).@"union";
    if (info.field_names.len != 2 or !std.mem.eql(u8, info.field_names[0], "slot") or !std.mem.eql(u8, info.field_names[1], "returned") or info.field_types[0] != p.Id or info.field_types[1] != void) @compileError("portable reference roles: changed assignment source");
}
pub fn validateEdge(comptime T: type) void {
    validateFields(T, edge_fields);
}
pub fn validateAssignment(comptime T: type) void {
    validateFields(T, assignment_fields);
}
test "portable reference roles cover every control tag and nested record field" {
    comptime {
        for (std.meta.tags(p.TerminatorTag)) |tag| validateTerminatorPayload(tag, @FieldType(ir.Terminator, @tagName(tag)));
        validateEdge(ir.Edge);
        validateAssignment(ir.Assignment);
        validateSource(ir.Source);
    }
}
