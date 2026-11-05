const std = @import("std");
const source = @import("../source.zig");
const p = @import("horos_data").program;
const a = std.testing.allocator;
const integers = .{ i8, i16, i32, i64, u8, u16, u32, u64 };

fn scalarStep(before: source.Module, after: source.Module, id: u64, fold: bool) !void {
    try source.relation.validate(a, before, after, &.{.{
        .successor = after,
        .rule = .{ .scalar = .{ .value = id, .rule = if (fold) .fold else .identity } },
    }}, .{});
}

fn identityCase(comptime T: type, opcode: p.Opcode, reversed: bool) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const shape = try b.scalar(T);
    const entry = try b.declare(&.{shape}, shape, &.{}, &.{});
    const input = try b.reference(b.parameter(entry, 0));
    const mask = try b.constant(T, if (opcode == .integer_bit_and) ~@as(T, 0) else 0);
    const operands = if (reversed) [_]u64{ mask, input } else [_]u64{ input, mask };
    const id = if (opcode == .move)
        try b.primitive(shape, opcode, &.{input}, 0)
    else if (opcode == .integer_bit_not)
        try b.primitive(shape, opcode, &.{try b.primitive(shape, opcode, &.{input}, 0)}, 0)
    else
        try b.primitive(shape, opcode, &operands, 0);
    try b.define(entry, try b.pure(id));
    const before = b.module(entry, unit);
    const after = try source.own(source.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(id)] = before.values[@intCast(input)];
    try scalarStep(before, after, id, false);
    @constCast(after.values)[@intCast(id)] = before.values[@intCast(mask)];
    try std.testing.expectError(error.InvalidRelation, scalarStep(before, after, id, false));
}

test "scalar identities preserve each signed width and both mask operand positions" {
    inline for (integers) |T| {
        for ([_]p.Opcode{
            .move, .integer_bit_not, .integer_bit_and, .integer_bit_or, .integer_bit_xor,
        }) |opcode| {
            try identityCase(T, opcode, false);
            if (opcode != .move and opcode != .integer_bit_not)
                try identityCase(T, opcode, true);
        }
    }
}

fn foldedCandidate(
    b: *source.Builder,
    before: source.Module,
    id: u64,
    bytes: []const u8,
) !source.Module {
    var after = try source.own(source.Module, b.allocator(), before);
    const constants = try b.allocator().alloc(p.Literal, before.constants.len + 1);
    @memcpy(constants[0..before.constants.len], before.constants);
    constants[before.constants.len] = .{
        .schema = before.values[@intCast(id)].schema,
        .bytes = bytes,
    };
    after.constants = constants;
    @constCast(after.values)[@intCast(id)].expression = .{ .literal = before.constants.len };
    return after;
}

fn foldingCase(comptime T: type, left: T, right: T, opcode: p.Opcode) !void {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const shape = try b.scalar(T);
    const failure = try b.failureLiteral(try b.constant(void, {}));
    const entry = try b.declare(&.{}, shape, &.{}, &.{});
    const id = try b.value(.{ .schema = shape, .expression = .{ .primitive = .{
        .opcode = opcode,
        .operands = &.{ try b.constant(T, left), try b.constant(T, right) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
    } } });
    try b.define(entry, try b.pure(id));
    const before = b.module(entry, unit);
    const expected: i128 = if (opcode == .integer_add)
        @as(i128, left) + @as(i128, right)
    else
        @as(i128, left) - @as(i128, right);
    var encoded: [@sizeOf(T)]u8 = undefined;
    const narrowed = std.math.cast(T, expected);
    std.mem.writeInt(T, &encoded, narrowed orelse 0, .little);
    const after = try foldedCandidate(&b, before, id, &encoded);
    if (narrowed == null) {
        try std.testing.expectError(error.InvalidRelation, scalarStep(before, after, id, true));
    } else {
        try scalarStep(before, after, id, true);
        encoded[0] ^= 1;
        try std.testing.expectError(error.InvalidRelation, scalarStep(before, after, id, true));
    }
}

test "scalar folds compare independent widened arithmetic at signed and unsigned boundaries" {
    inline for (integers) |T| {
        const high: T = std.math.maxInt(T);
        const low: T = std.math.minInt(T);
        const power: T = @as(T, 1) << (@bitSizeOf(T) - 2);
        for ([_]T{ low, low + 1, 0, 1, power - 1, power, power + 1, high - 1, high }) |left| {
            try foldingCase(T, left, 1, .integer_add);
            try foldingCase(T, left, 1, .integer_sub);
        }
        try foldingCase(T, 19, 4, .integer_sub);
        try foldingCase(T, 4, 19, .integer_sub);
    }
}

test "scalar idempotence requires evaluated leaves rather than repeated expression identities" {
    for ([_]p.Opcode{ .integer_bit_and, .integer_bit_or }) |opcode| {
        var b = source.Builder.init(a);
        defer b.deinit();
        const unit = try b.scalar(void);
        const shape = try b.scalar(u64);
        const entry = try b.declare(&.{shape}, shape, &.{}, &.{});
        const input = try b.reference(b.parameter(entry, 0));
        const computed = try b.primitive(shape, .integer_bit_not, &.{input}, 0);
        const id = try b.primitive(shape, opcode, &.{ input, input }, 0);
        try b.define(entry, try b.pure(id));
        const before = b.module(entry, unit);
        const after = try source.own(source.Module, b.allocator(), before);
        @constCast(after.values)[@intCast(id)] = before.values[@intCast(input)];
        try scalarStep(before, after, id, false);
        b.values.items[@intCast(id)].expression.primitive.operands = &.{ computed, computed };
        @constCast(after.values)[@intCast(id)] = before.values[@intCast(computed)];
        try std.testing.expectError(error.InvalidRelation, scalarStep(before, after, id, false));
    }
}

test "boolean complement and malformed scalar literals retain source admission" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const entry = try b.declare(&.{boolean}, boolean, &.{}, &.{});
    const input = try b.reference(b.parameter(entry, 0));
    const once = try b.primitive(boolean, .boolean_not, &.{input}, 0);
    const twice = try b.primitive(boolean, .boolean_not, &.{once}, 0);
    try b.define(entry, try b.pure(twice));
    const unused = try b.constant(bool, true);
    const enumeration = try b.schema(.{ .enumeration = &.{ 2, 7 } });
    const before = b.module(entry, unit);
    const after = try source.own(source.Module, b.allocator(), before);
    @constCast(after.values)[@intCast(twice)] = before.values[@intCast(input)];
    try scalarStep(before, after, twice, false);
    const literal = before.values[@intCast(unused)].expression.literal;
    for ([_]p.Literal{
        .{ .schema = boolean, .bytes = &.{2} },
        .{ .schema = enumeration, .bytes = &.{ 5, 0, 0, 0 } },
    }) |invalid| {
        const changed = try source.own(source.Module, b.allocator(), before);
        @constCast(changed.constants)[@intCast(literal)] = invalid;
        @constCast(changed.values)[@intCast(unused)].schema = invalid.schema;
        try std.testing.expectError(error.InvalidValue, source.relation.validate(
            a,
            changed,
            changed,
            &.{},
            .{},
        ));
    }
}

test "inlining rejects erased and reordered unused failing arguments" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const fixture = try @import("../inline_argument_case.zig").build(&b);
    const after = fixture.after;
    const first = after.functions[@intCast(after.entry)].body.?;
    const second = after.terms[@intCast(first)].bind.next;
    try std.testing.expect(after.terms[@intCast(second)] == .bind);
    for ([_]bool{ false, true }) |erase| {
        const changed = try source.own(source.Module, b.allocator(), after);
        if (erase) {
            @constCast(changed.functions)[@intCast(changed.entry)].body = second;
        } else {
            std.mem.swap(
                u64,
                &@constCast(changed.terms)[@intCast(first)].bind.value,
                &@constCast(changed.terms)[@intCast(second)].bind.value,
            );
        }
        var work: u64 = 1_000_000;
        try source.admitWithWork(a, changed, &work);
        try std.testing.expectError(error.InvalidRelation, source.relation.validate(
            a,
            fixture.before,
            changed,
            &.{.{ .successor = changed, .rule = .{ .inline_call = fixture.call } }},
            .{},
        ));
    }
}
