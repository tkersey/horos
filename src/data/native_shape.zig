//! Native representation contracts shared by authoring and value codecs.
//! A description contains structural knowledge, never a runtime schema identity.
const std = @import("std");

pub fn Text(comptime maximum: ?u64) type {
    return struct {
        pub const protean_value_kind = .text;
        pub const max_length: ?u64 = maximum;
        bytes: []const u8,
    };
}

pub fn Bytes(comptime maximum: ?u64) type {
    return struct {
        pub const protean_value_kind = .bytes;
        pub const max_length: ?u64 = maximum;
        bytes: []const u8,
    };
}

pub const Utf8 = Text(null);

pub fn Vector(comptime Element: type, comptime maximum: ?u64) type {
    return struct {
        pub const protean_value_kind = .vector;
        pub const max_length: ?u64 = maximum;
        pub const Child = Element;
        items: []const Element,
    };
}

/// Product/sum fields are a structural Zig record of canonical child contracts.
/// Enumeration is a canonical enum whose labels are derived from numeric tags.
/// These types describe portable structure; they do not describe native layout.
pub const Info = union(enum) {
    unit,
    boolean,
    integer: type,
    product: type,
    sum: type,
    enumeration: type,
    array: struct { element: type, length: u64 },
    sequence: struct { element: type, maximum: ?u64 },
    text: ?u64,
    bytes: ?u64,
};

/// The factory receives normalized descriptions, so native nominal identity and
/// incidental layout cannot create a new portable contract specialization.
pub fn Contract(comptime description: Info) type {
    return struct {
        pub const contract = description;
        pub const finite: void = requireFinite(description);
    };
}

fn requireFinite(comptime description: Info) void {
    switch (description) {
        .product, .sum => |Children| {
            for (@typeInfo(Children).@"struct".field_types) |Child|
                _ = Contract(Child.contract).finite;
        },
        .array => |array| _ = Contract(array.element.contract).finite,
        .sequence => |sequence| _ = Contract(sequence.element.contract).finite,
        else => {},
    }
}

pub fn Shape(comptime T: type) type {
    return Contract(info(T));
}

pub fn info(comptime T: type) Info {
    return NativeInfo(T).description;
}

// A declaration is evaluated once per native type. Repeated authoring signatures
// reuse classification without repeating the full diagnostic-path traversal.
// Contract still interns only the normalized description, not this native key.
fn NativeInfo(comptime T: type) type {
    return struct {
        const description: Info = blk: {
            @setEvalBranchQuota(100000);
            break :blk describe(T, "value", &.{});
        };
    };
}

/// Recognize canonical wrappers by type identity, not by a caller's marker alone.
pub fn wrapped(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "protean_value_kind") or !@hasDecl(T, "max_length")) return false;
    if (@TypeOf(T.max_length) != ?u64) return false;
    if (@TypeOf(T.protean_value_kind) != @EnumLiteral()) return false;
    if (T.protean_value_kind == .text) return T == Text(T.max_length);
    if (T.protean_value_kind == .bytes) return T == Bytes(T.max_length);
    if (T.protean_value_kind == .vector and @hasDecl(T, "Child")) {
        if (@TypeOf(T.Child) != type) return false;
        return T == Vector(T.Child, T.max_length);
    }
    return false;
}

fn invalid(comptime path: []const u8, comptime reason: []const u8) noreturn {
    @compileError("Horos native schema: " ++ path ++ ": " ++ reason);
}

fn childPath(comptime path: []const u8, comptime child: []const u8) []const u8 {
    return path ++ "." ++ child;
}

inline fn describe(
    comptime T: type,
    comptime path: []const u8,
    comptime ancestors: []const type,
) Info {
    for (ancestors) |Ancestor| if (T == Ancestor) invalid(
        path,
        "recursive native type requires an explicit runtime declaration",
    );
    const seen = ancestors ++ &[_]type{T};
    if (wrapped(T)) {
        if (T.protean_value_kind == .text) return .{ .text = T.max_length };
        if (T.protean_value_kind == .bytes) return .{ .bytes = T.max_length };
        return .{ .sequence = .{
            .element = Contract(describe(T.Child, childPath(path, "items"), seen)),
            .maximum = T.max_length,
        } };
    }
    return switch (@typeInfo(T)) {
        .void => .unit,
        .bool => .boolean,
        .int => |integer| blk: {
            switch (integer.bits) {
                8, 16, 32, 64 => {},
                else => invalid(path, "integer width must be 8, 16, 32, or 64"),
            }
            break :blk .{ .integer = @Int(integer.signedness, integer.bits) };
        },
        .@"struct" => |record| describeRecord(record, path, seen),
        .@"union" => |sum| describeSum(sum, path, seen),
        .optional => |optional| .{ .sum = Fields(&.{ "none", "some" }, &.{
            Contract(.unit), Contract(describe(optional.child, childPath(path, "some"), seen)),
        }) },
        .array => |array| .{ .array = .{
            .element = Contract(describe(array.child, childPath(path, "element"), seen)),
            .length = array.len,
        } },
        .pointer => |pointer| blk: {
            if (pointer.size != .slice or pointer.sentinel_ptr != null)
                invalid(path, "pointer must be an unsentinelled slice");
            if (pointer.child == u8) break :blk .{ .bytes = null };
            break :blk .{ .sequence = .{
                .element = Contract(describe(pointer.child, childPath(path, "element"), seen)),
                .maximum = null,
            } };
        },
        .@"enum" => describeEnumeration(T, path),
        else => invalid(path, "unsupported native type " ++ @typeName(T)),
    };
}

fn describeRecord(
    comptime record: anytype,
    comptime path: []const u8,
    comptime seen: []const type,
) Info {
    var children: [record.field_types.len]type = undefined;
    for (
        record.field_names,
        record.field_types,
        record.field_attrs,
        0..,
    ) |name, Child, attrs, index| {
        if (attrs.@"comptime") invalid(
            childPath(path, name),
            "fields must be runtime values",
        );
        children[index] = Contract(describe(Child, childPath(path, name), seen));
    }
    return .{ .product = Fields(record.field_names, &children) };
}
fn describeSum(
    comptime sum: anytype,
    comptime path: []const u8,
    comptime seen: []const type,
) Info {
    if (sum.tag_type == null) invalid(path, "union must be tagged");
    if (sum.field_types.len == 0) invalid(path, "sum must have at least one case");
    var children: [sum.field_types.len]type = undefined;
    for (sum.field_names, sum.field_types, 0..) |name, Child, index|
        children[index] = Contract(describe(Child, childPath(path, name), seen));
    return .{ .sum = Fields(sum.field_names, &children) };
}
fn describeEnumeration(comptime T: type, comptime path: []const u8) Info {
    const enumeration = @typeInfo(T).@"enum";
    if (enumeration.mode != .exhaustive) invalid(path, "enum must be exhaustive");
    if (enumeration.field_values.len == 0) return .{ .enumeration = @Enum(
        noreturn,
        .exhaustive,
        &.{},
        &.{},
    ) };
    for (enumeration.field_values) |value| {
        if (value < 0 or value > std.math.maxInt(u32)) invalid(
            path,
            "enum tag must fit u32",
        );
    }
    return .{ .enumeration = canonicalEnum(T) };
}

// Independent of diagnostic paths, so repeated uses of one enum share its
// normalized type. Decimal tags need no general-purpose formatting machinery.
inline fn enumName(comptime tag: u32) [:0]const u8 {
    const digit = [_]u8{@intCast('0' + tag % 10)};
    return if (tag < 10) digit ++ "" else enumName(tag / 10) ++ digit ++ "";
}
fn canonicalEnum(comptime T: type) type {
    const values = @typeInfo(T).@"enum".field_values;
    var tags: [values.len]u32 = undefined;
    for (values, 0..) |value, i| tags[i] = @intCast(value);
    std.mem.sort(u32, &tags, {}, std.sort.asc(u32));
    var names: [tags.len][:0]const u8 = undefined;
    for (tags, 0..) |tag, i| names[i] = enumName(tag);
    return @Enum(u32, .exhaustive, &names, &tags);
}

/// Struct construction interns the ordered names and canonical child types.
/// Do not pass native field defaults, layout, alignment, or declaration identity.
pub fn Fields(comptime names: []const [:0]const u8, comptime children: []const type) type {
    return @Struct(
        .auto,
        null,
        names,
        children,
        &(@as([names.len]std.lang.Type.Struct.FieldAttributes, @splat(.{}))),
    );
}

pub fn enumTags(comptime T: type) [@typeInfo(T).@"enum".field_values.len]u32 {
    const description = info(T);
    var tags: [@typeInfo(T).@"enum".field_values.len]u32 = undefined;
    inline for (@typeInfo(description.enumeration).@"enum".field_values, 0..) |value, index|
        tags[index] = @intCast(value);
    return tags;
}

/// Raw compiler integration folds the same contract as checked authoring.
/// Value encoding, allocation ownership, and JSON projection remain codec work.
pub inline fn lower(comptime description: Info, builder: anytype) @TypeOf(builder.schema(.unit)) {
    comptime _ = Contract(description).finite;
    return NativeLowering(description, @TypeOf(builder)).build(builder);
}

fn NativeLowering(comptime description: Info, comptime Builder: type) type {
    return struct {
        fn build(builder: Builder) @TypeOf(builder.schema(.unit)) {
            const p = @import("program.zig");
            return switch (description) {
                .unit => builder.schema(.unit),
                .boolean => builder.schema(.boolean),
                .integer => |T| builder.schema(@unionInit(p.Schema, @typeName(T), {})),
                .text => |maximum| builder.schema(
                    if (maximum) |n| .{ .bounded_text = n } else .text,
                ),
                .bytes => |maximum| builder.schema(
                    if (maximum) |n| .{ .bounded_bytes = n } else .bytes,
                ),
                .enumeration => |Tags| blk: {
                    const tags = comptime enumTags(Tags);
                    break :blk builder.schema(.{ .enumeration = &tags });
                },
                .product, .sum => |Children, kind| blk: {
                    const fields = @typeInfo(Children).@"struct";
                    var ids: [fields.field_types.len]p.Id = undefined;
                    inline for (fields.field_types, 0..) |Child, i|
                        ids[i] = try NativeLowering(Child.contract, Builder).build(builder);
                    break :blk builder.schema(@unionInit(p.Schema, @tagName(kind), &ids));
                },
                .array => |array| builder.schema(.{ .array = .{
                    .element = try NativeLowering(array.element.contract, Builder).build(builder),
                    .length = array.length,
                } }),
                .sequence => |sequence| blk: {
                    const child = try NativeLowering(sequence.element.contract, Builder).build(
                        builder,
                    );
                    break :blk builder.schema(if (sequence.maximum) |n|
                        .{ .vector = .{ .element = child, .maximum = n } }
                    else
                        .{ .seq = child });
                },
            };
        }
    };
}
