// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const wire = @import("wire.zig");
const body_record = @import("program_record.zig");

pub const Error = body_record.Error || error{InvalidReference};

pub const Kind = enum(u8) {
    context = 0,
    residual = 1,

    pub fn join(left: Kind, right: Kind) Kind {
        return if (left == right) left else .residual;
    }
};

pub const Hint = struct {
    function: p.Id,
    slot: p.Id,
    kind: Kind,

    fn precedes(left: Hint, right: Hint) bool {
        if (left.function != right.function) return left.function < right.function;
        return left.slot < right.slot;
    }

    fn sameBinding(left: Hint, right: Hint) bool {
        return left.function == right.function and left.slot == right.slot;
    }
};

pub fn validate(program: ir.Program, hints: []const Hint) Error!void {
    for (hints, 0..) |hint, index| {
        if (hint.function >= program.functions.len) return error.InvalidReference;
        const slots = program.functions[@intCast(hint.function)].layout.slots;
        if (hint.slot >= slots.len) return error.InvalidReference;
        if (index != 0 and !hints[index - 1].precedes(hint)) return error.NonCanonical;
    }
}

pub fn normalize(hints: []Hint) []Hint {
    std.mem.sort(Hint, hints, {}, struct {
        fn lessThan(_: void, left: Hint, right: Hint) bool {
            return left.precedes(right);
        }
    }.lessThan);
    var length: usize = 0;
    for (hints) |hint| {
        if (length != 0 and hints[length - 1].sameBinding(hint)) {
            hints[length - 1].kind = hints[length - 1].kind.join(hint.kind);
            continue;
        }
        hints[length] = hint;
        length += 1;
    }
    return hints[0..length];
}

pub fn write(hints: []const Hint, writer: *wire.Writer) Error!void {
    std.debug.assert(hints.len != 0);
    try writer.natural(hints.len);
    for (hints) |hint| {
        try writer.natural(hint.function);
        try writer.natural(hint.slot);
        try writer.natural(@backingInt(hint.kind));
    }
}

pub fn read(
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    budget: *body_record.Budget,
) Error![]const Hint {
    const count = try reader.count();
    if (count == 0) return error.NonCanonical;
    if (count > reader.input.len - reader.position) return error.Truncated;
    try budget.account(Hint, count);
    const hints = try allocator.alloc(Hint, count);
    for (hints) |*hint| {
        const function = try reader.natural();
        const slot = try reader.natural();
        hint.* = .{ .function = function, .slot = slot, .kind = switch (try reader.natural()) {
            @backingInt(Kind.context) => .context,
            @backingInt(Kind.residual) => .residual,
            else => return error.InvalidTag,
        } };
    }
    return hints;
}
