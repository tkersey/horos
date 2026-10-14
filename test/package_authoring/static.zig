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
    if (comptime selected("option_handler")) {
        const operation = try c.local("option", integer, integer, .linear);
        _ = try c.handler(operation, integer, integer, .{ .mode = .deep, .use = .linear, .return_effect = .{} });
    } else if (comptime selected("option_handler_set")) {
        const operation = try c.local("option", integer, integer, .linear);
        _ = try c.handlerSet(.{ .capability = operation }, integer, integer, .{ .mode = .deep, .use = .linear, .return_effect = .{} });
    } else if (comptime selected("option_responder")) {
        const operation = try c.local("option", integer, integer, .linear);
        const response = try c.function("reply", .{ .payload = integer }, integer, .{});
        _ = try c.responder(operation, integer, response, .{ .mode = .deep, .use = .linear, .return_effect = .{} });
    } else if (comptime selected("option_callable")) {
        _ = try c.callable(.{}, integer, .{}, .{ .use = .reusable, .capture = .{} });
    } else if (comptime selected("option_define_callable")) {
        const schema = try c.callable(.{}, integer, .{}, .{ .use = .reusable });
        const slot = try c.declareSchema(.callable, a.ShapeOf(@TypeOf(schema)));
        try c.defineCallable(slot, .{}, integer, .{}, .{ .use = .reusable, .capture = .{} });
    } else if (comptime selected("option_region_body")) {
        _ = try c.regionBodySchema(try c.region(), .{}, integer, .{}, .{ .use = .reusable, .capture = .{} });
    } else if (comptime selected("option_append")) {
        const sequence = try b.sequenceValue(try c.sequence(integer), .{});
        _ = try b.append(sequence, value, .{ .capcity = null });
    } else if (comptime selected("option_concat")) {
        const sequence = try b.sequenceValue(try c.sequence(integer), .{});
        _ = try b.concat(sequence, sequence, .{ .capcity = null });
    } else if (comptime selected("option_convert")) {
        _ = try b.convertInteger(integer, value, .{ .overflw = null });
    } else if (comptime selected("option_blob")) {
        const bytes = try c.schema(native.Bytes(null));
        const blob = try a.interop.encodedLiteral(c, bytes, &.{0});
        _ = try b.blobSlice(bytes, blob, value, value, .{ .capacity = try c.literalFailure(void, {}), .capcity = null });
    } else if (comptime selected("option_arithmetic")) {
        _ = try b.checked(.add, value, value, .{ .overflow = try c.literalFailure(void, {}), .division_by_zerro = null });
    } else if (comptime selected("option_choice_all")) {
        const choice = try horos.library.choice.family(c, "options");
        _ = try horos.library.choice.all(c, choice, integer, .{ .captures = .{ .continuation = .{} }, .capture = .{} });
    } else if (comptime selected("option_choice_first")) {
        const choice = try horos.library.choice.family(c, "options");
        _ = try horos.library.choice.first(c, choice, integer, .{ .captures = .{ .continuation = .{} }, .capture = .{} });
    } else if (comptime selected("option_search")) {
        const search = try horos.library.search.family(c, "options");
        _ = try horos.library.search.interpret(c, search, integer, .{ .captures = .{ .continuation = .{} }, .order = .depth_first, .capture = .{} });
    } else if (comptime selected("option_generator")) {
        _ = try horos.library.generator.create(c, "options", integer, integer, integer, .{ .captures = .{ .continuation = .{} }, .capture = .{} });
    } else if (comptime selected("option_nested_capture")) {
        const choice = try horos.library.choice.family(c, "options");
        _ = try horos.library.choice.all(c, choice, integer, .{ .captures = .{ .continuation = .{}, .bodi = .{} } });
    } else if (comptime selected("option_named_record")) {
        const sequence = try b.sequenceValue(try c.sequence(integer), .{});
        _ = try b.append(sequence, value, .{null});
    } else if (comptime selected("nested")) {
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
    } else if (comptime selected("declaration_erasure")) {
        const slot = try c.declareSchema(.alternatives, a.Shape(?u64));
        try c.defineAlternatives(a.interop.erase(slot), .{ .none = try c.schema(void), .some = try c.schema(bool) });
    } else if (comptime selected("callable_declaration_erasure")) {
        const signature = try c.callable(.{ .input = integer }, integer, .{}, .{ .use = .reusable });
        const slot = try c.declareSchema(.callable, a.ShapeOf(@TypeOf(signature)));
        try c.defineCallable(a.interop.erase(slot), .{ .input = integer }, try c.schema(bool), .{}, .{ .use = .reusable });
    } else if (comptime selected("resumption_slot_pointer")) {
        const unit = try c.schema(void);
        const operation = try c.local("typed slot", unit, integer, .linear);
        const slot = try c.declareSchema(.resumption, a.Internal(.{ .resumption = a.ResumptionSignature(a.Shape(bool), a.Shape(void), .deep) }));
        _ = try c.handler(operation, unit, unit, .{ .mode = .deep, .use = .linear, .resumption_slots = &.{slot} });
    } else if (comptime selected("recursive_mismatch")) {
        const Left = struct {
            pub const contract: native.Info = .{ .sum = native.Fields(&.{ "next", "value" }, &.{ @This(), a.Shape(u64) }) };
        };
        const Right = struct {
            pub const contract: native.Info = .{ .sum = native.Fields(&.{ "next", "value" }, &.{ @This(), a.Shape(bool) }) };
        };
        const left = try c.declareSchema(.alternatives, Left);
        const right = try c.declareSchema(.alternatives, Right);
        try c.defineAlternatives(left, .{ .next = left.schema(), .value = integer });
        try c.defineAlternatives(right, .{ .next = right.schema(), .value = try c.schema(bool) });
        _ = try a.interop.refineSchema(c, right.schema(), left.schema());
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
