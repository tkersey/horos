//! Each mode is forced through the extracted package's sole public interface.
const std = @import("std");
const horos = @import("horos");
const a = horos.authoring;
const native = horos.data.schema.native;
const mode = @import("rejection_mode").value;
fn selected(comptime name: []const u8) bool {
    return std.mem.eql(u8, mode, name);
}
pub fn main(init: std.process.Init) !void {
    var raw = horos.source.Builder.init(init.gpa);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const f = try c.function("caller", .{}, integer, .{});
    const b = try c.body(f);
    const value = try b.constant(u64, 1);
    if (comptime selected("nested")) {
        const expected = try c.schema(struct { count: u64 });
        const actual = try c.schema(struct { count: bool });
        const target = try c.function("target", .{ .input = expected }, integer, .{});
        _ = try b.call(target, .{ .input = try b.product(actual, .{ .count = try b.constant(bool, true) }) });
    } else if (comptime selected("missing") or selected("extra")) {
        const record = try c.record(.{ .count = integer });
        if (comptime selected("missing")) _ = try b.product(record, .{}) else _ = try b.product(record, .{ .count = value, .extra = value });
    } else if (comptime selected("name")) {
        const record = try c.record(.{ .count = integer });
        _ = try b.field(try b.product(record, .{ .count = value }), "absent");
    } else if (comptime selected("category")) {
        _ = try c.record(.{ .count = value });
    } else if (comptime selected("fake_schema")) {
        const Fake = opaque {
            pub const horos_handle = a.Schema(a.Shape(u64)).horos_handle;
        };
        const fake: *const Fake = undefined;
        _ = try c.record(.{ .count = fake });
    } else if (comptime selected("fake_value")) {
        const Fake = opaque {
            pub const horos_handle = a.Value(a.Shape(u64)).horos_handle;
        };
        const fake: *const Fake = undefined;
        _ = try b.ret(fake);
    } else if (comptime selected("branch")) {
        const yes = try b.branch();
        const no = try b.branch();
        _ = try b.conditional(try b.constant(bool, true), try yes.ret(value), try no.ret(try no.constant(bool, false)));
    } else if (comptime selected("text_bound") or selected("text_bytes")) {
        const text = try c.schema(native.Text(null));
        const other = if (comptime selected("text_bound")) try c.schema(native.Text(0)) else try c.schema(native.Bytes(null));
        const target = try c.function("target", .{ .input = text }, integer, .{});
        _ = try b.call(target, .{ .input = try a.interop.encodedLiteral(c, other, &.{0}) });
    } else if (comptime selected("enum_tags")) {
        const left = try c.schema(enum(u32) { first = 2, last = 9 });
        const right = try c.schema(enum(u32) { first = 2, last = 10 });
        const target = try c.function("target", .{ .input = left }, integer, .{});
        _ = try b.call(target, .{ .input = try a.interop.encodedLiteral(c, right, &.{2}) });
    } else if (comptime selected("array_length")) {
        _ = try b.sequenceValue(try c.schema([2]u64), .{value});
    } else if (comptime selected("pending_unknown")) {
        const declaration = try c.declareSchema(.alternatives, a.Shape(?u64));
        try c.defineAlternatives(declaration, .{ .none = try c.schema(void), .some = a.interop.erase(integer) });
    } else if (comptime selected("native_pointer")) {
        _ = try c.schema(*u64);
    } else if (comptime selected("native_recursive")) {
        const Node = struct { children: []const @This() };
        _ = try c.schema(Node);
    } else if (comptime selected("match_arm")) {
        const sum = try c.alternatives(.{ .no = integer, .yes = integer });
        const input = try b.variant(sum, "no", value);
        const no = try b.caseOf(input, "no");
        const yes = try b.caseOf(input, "yes");
        _ = try b.match(input, .{ .no = try yes.ret(value), .yes = try no.ret(value) });
    } else if (comptime selected("failure_category")) {
        _ = try b.checkedAdd(value, value, value);
    } else @compileError("unknown static rejection mode");
}
