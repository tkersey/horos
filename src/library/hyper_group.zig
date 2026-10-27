const std = @import("std");
const bridge = @import("bridge.zig");
const a = bridge.a;
const hyper = @import("hyper.zig");
const runtime = @import("runtime/hyper_group.zig");
const option_contract = @import("../authoring/option_contract.zig");

fn endpoint(comptime Fields: type, comptime name: []const u8) type {
    if (Fields == a.Dynamic) @compileError(
        "Horos hyper group: runtime endpoint selection needs interop",
    );
    if (!@hasField(Fields, name)) @compileError("Horos hyper group: unknown endpoint " ++ name);
    return @FieldType(Fields, name);
}

fn endpointIndex(comptime Fields: type, comptime name: []const u8) usize {
    _ = endpoint(Fields, name);
    for (@typeInfo(Fields).@"struct".field_names, 0..) |field, i| {
        if (std.mem.eql(u8, field, name)) return i;
    }
    @compileError("Horos hyper group: unknown endpoint " ++ name);
}

pub fn Group(comptime Fields: type) type {
    return opaque {
        pub const Endpoints = Fields;
        fn raw(self: *const @This()) *const runtime.Group {
            return @ptrCast(self);
        }
        pub fn get(
            self: *const @This(),
            comptime from: []const u8,
            comptime to: []const u8,
        ) *const hyper.Pair(endpoint(Fields, from), endpoint(Fields, to)) {
            return @ptrCast(self.raw().get(
                comptime endpointIndex(Fields, from),
                comptime endpointIndex(Fields, to),
            ));
        }
    };
}

fn groupFields(comptime T: type) type {
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
        @compileError("Horos hyper: expected a canonical group");
    const Child = @typeInfo(T).pointer.child;
    if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "Endpoints"))
        @compileError("Horos hyper: expected a canonical group");
    if (T != *const Group(Child.Endpoints))
        @compileError("Horos hyper: expected a canonical group");
    return Child.Endpoints;
}

pub fn group(
    c: *a.Context,
    endpoints: anytype,
    options: anytype,
) a.Error!*const Group(bridge.namedShape(@TypeOf(endpoints))) {
    comptime option_contract.check("hyper.group", @TypeOf(options), &.{"captures"});
    const names = try bridge.named(c, endpoints);
    const captures = bridge.list(.schema, bridge.option(options, "captures", .{}));
    return @ptrCast(try runtime.group(bridge.context(c), names.slice(), captures.slice()));
}

pub fn compose(
    body: anytype,
    interfaces: anytype,
    comptime from: []const u8,
    comptime middle: []const u8,
    comptime to: []const u8,
    left: anytype,
    right: anytype,
) a.Error!*const a.Value(hyper.Hyper(
    endpoint(groupFields(@TypeOf(interfaces)), from),
    endpoint(groupFields(@TypeOf(interfaces)), to),
)) {
    const Fields = groupFields(@TypeOf(interfaces));
    const checked_left = try a.interop.refineValue(
        body,
        left,
        interfaces.get(middle, to).forward(),
    );
    const checked_right = try a.interop.refineValue(
        body,
        right,
        interfaces.get(from, middle).forward(),
    );
    return @ptrCast(try runtime.compose(@ptrCast(body), @ptrCast(interfaces), .{
        comptime endpointIndex(Fields, from),
        comptime endpointIndex(Fields, middle),
        comptime endpointIndex(Fields, to),
    }, @ptrCast(checked_left), @ptrCast(checked_right)));
}

pub const interop = struct {
    pub fn from(
        interfaces: anytype,
        comptime input: []const u8,
        output: []const u8,
    ) a.Error!*const hyper.Pair(endpoint(groupFields(@TypeOf(interfaces)), input), a.Dynamic) {
        const raw: *const runtime.Group = @ptrCast(interfaces);
        return @ptrCast(try raw.lookup(input, output));
    }
    pub fn to(
        interfaces: anytype,
        input: []const u8,
        comptime output: []const u8,
    ) a.Error!*const hyper.Pair(a.Dynamic, endpoint(groupFields(@TypeOf(interfaces)), output)) {
        const raw: *const runtime.Group = @ptrCast(interfaces);
        return @ptrCast(try raw.lookup(input, output));
    }
    pub fn select(
        interfaces: anytype,
        input: []const u8,
        output: []const u8,
    ) a.Error!*const hyper.Pair(a.Dynamic, a.Dynamic) {
        _ = groupFields(@TypeOf(interfaces));
        const raw: *const runtime.Group = @ptrCast(interfaces);
        return @ptrCast(try raw.lookup(input, output));
    }
};

test {
    _ = @import("hyper_group_tests.zig");
}
