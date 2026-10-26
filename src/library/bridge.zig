//! Private bridge between structural library results and shared runtime graphs.
const std = @import("std");
pub const a = @import("../authoring.zig");
pub const raw = @import("../authoring/runtime.zig");
pub const native = @import("horos_data").schema.native;
pub const Empty = native.Fields(&.{}, &.{});
const Family = enum { schema, operation, region };
pub const Unit = a.Shape(void);
pub fn context(c: *a.Context) *raw.Context {
    return @ptrCast(c);
}
pub fn body(value: anytype) *raw.Body {
    const S = a.ShapeOf(@TypeOf(value));
    if (@TypeOf(value) != *a.Body(S))
        @compileError("Horos library: expected a canonical body handle");
    return @ptrCast(value);
}
pub fn schemaShape(comptime T: type) type {
    const S = a.ShapeOf(T);
    if (T != *const a.Schema(S)) @compileError("Horos library: expected a canonical schema handle");
    return S;
}
pub fn schema(value: anytype) *const raw.Schema {
    _ = comptime schemaShape(@TypeOf(value));
    return @ptrCast(value);
}
pub inline fn option(
    options: anytype,
    comptime name: []const u8,
    default: anytype,
) (if (@hasField(@TypeOf(options), name))
    @FieldType(@TypeOf(options), name)
else
    @TypeOf(default)) {
    return if (@hasField(@TypeOf(options), name)) @field(options, name) else default;
}
inline fn count(comptime T: type) ?usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_types.len,
        .array => |ar| ar.len,
        .pointer => |ptr| if (ptr.size == .slice) null else count(ptr.child),
        else => @compileError("Horos library: expected a handle tuple, array, or slice"),
    };
}
fn Handle(comptime family: Family) type {
    return switch (family) {
        .schema => raw.Schema,
        .operation => raw.Operation,
        .region => raw.Region,
    };
}
fn checked(comptime family: Family, value: anytype) *const Handle(family) {
    const S = a.ShapeOf(@TypeOf(value));
    const Canonical = switch (family) {
        .schema => a.Schema(S),
        .operation => a.Operation(S),
        .region => a.Region,
    };
    if (@TypeOf(value) != *const Canonical)
        @compileError("Horos library: wrong canonical handle family");
    return @ptrCast(value);
}
pub fn List(comptime family: Family, comptime T: type) type {
    const n = count(T);
    return struct {
        owned: [n orelse 0]*const Handle(family) = undefined,
        borrowed: []const *const Handle(family) = &.{},
        pub fn slice(self: *const @This()) []const *const Handle(family) {
            return if (n == null) self.borrowed else &self.owned;
        }
    };
}
pub fn list(comptime family: Family, items: anytype) List(family, @TypeOf(items)) {
    const T = @TypeOf(items);
    var out: List(family, T) = .{};
    if (comptime count(T) == null) {
        const S = a.ShapeOf(@typeInfo(T).pointer.child);
        const Canonical = switch (family) {
            .schema => a.Schema(S),
            .operation => a.Operation(S),
            .region => a.Region,
        };
        if (@typeInfo(T).pointer.child != *const Canonical) @compileError(
            "Horos library: wrong canonical handle family",
        );
        out.borrowed = @as([*]const *const Handle(family), @ptrCast(items.ptr))[0..items.len];
    } else if (comptime @typeInfo(T) == .@"struct") {
        inline for (
            @typeInfo(T).@"struct".field_names,
            0..,
        ) |name, i| out.owned[i] = checked(family, @field(items, name));
    } else {
        inline for (items, 0..) |value, i| out.owned[i] = checked(family, value);
    }
    return out;
}
pub fn CaptureLists(comptime T: type) type {
    comptime @import("../authoring/option_contract.zig").check(
        "capture bounds",
        T,
        &.{ "continuation", "body" },
    );
    return struct {
        continuation: List(.schema, @FieldType(T, "continuation")),
        body: List(.schema, if (@hasField(T, "body")) @FieldType(T, "body") else @TypeOf(.{})),
        pub fn value(self: *const @This()) raw.CaptureBounds {
            return .{ .continuation = self.continuation.slice(), .body = self.body.slice() };
        }
    };
}
pub fn captures(items: anytype) CaptureLists(@TypeOf(items)) {
    return .{
        .continuation = list(.schema, items.continuation),
        .body = list(.schema, option(items, "body", .{})),
    };
}
pub fn sequence(comptime S: type) type {
    return native.Contract(.{ .sequence = .{ .element = S, .maximum = null } });
}
pub fn optional(comptime S: type) type {
    return native.Contract(.{ .sum = native.Fields(&.{ "none", "some" }, &.{ Unit, S }) });
}
pub fn resumption(comptime Reply: type, comptime Answer: type) type {
    return a.Internal(.{ .resumption = a.ResumptionSignature(Reply, Answer, .deep) });
}

pub fn namedShape(comptime T: type) type {
    if (T == *const a.interop.RuntimeNamed(.schema)) return a.Dynamic;
    if (@typeInfo(T) != .@"struct") @compileError("Horos library: expected named schema handles");
    const fields = @typeInfo(T).@"struct";
    if (fields.is_tuple and fields.field_types.len != 0) @compileError(
        "Horos library: expected named schema handles",
    );
    var children: [fields.field_types.len]type = undefined;
    for (fields.field_types, 0..) |Child, i| children[i] = schemaShape(Child);
    return native.Fields(fields.field_names, &children);
}
pub fn NamedSchemas(comptime T: type) type {
    const dynamic = T == *const a.interop.RuntimeNamed(.schema);
    return struct {
        owned: [if (dynamic) 0 else @typeInfo(T).@"struct".field_types.len]raw.Field = undefined,
        borrowed: []const raw.Field = &.{},
        pub fn slice(self: *const @This()) []const raw.Field {
            return if (dynamic) self.borrowed else &self.owned;
        }
    };
}
pub fn named(c: *a.Context, fields: anytype) a.Error!NamedSchemas(@TypeOf(fields)) {
    var result: NamedSchemas(@TypeOf(fields)) = .{};
    if (comptime @TypeOf(fields) == *const a.interop.RuntimeNamed(.schema)) {
        const entries = try a.interop.builder(c).allocator().alloc(raw.Field, fields.len());
        for (entries, 0..) |*out, i| {
            const entry = fields.at(i).?;
            out.* = .{ .name = entry.name, .schema = schema(entry.handle) };
        }
        result.borrowed = entries;
    } else {
        inline for (
            @typeInfo(@TypeOf(fields)).@"struct".field_names,
            0..,
        ) |name, i| result.owned[i] = .{ .name = name, .schema = schema(@field(fields, name)) };
    }
    return result;
}
