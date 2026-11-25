// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const wire = @import("wire.zig");
const body_record = @import("program_record.zig");
const relocation = @import("relocation.zig");
const witness = @import("coalescing_witness.zig");

pub const Error = body_record.Error || error{InvalidReference};
pub const RelocationError = std.mem.Allocator.Error || error{InvalidCorrespondence};

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

fn sort(hints: []Hint) void {
    std.mem.sort(Hint, hints, {}, struct {
        fn lessThan(_: void, left: Hint, right: Hint) bool {
            return left.precedes(right);
        }
    }.lessThan);
}

pub fn normalize(hints: []Hint) []Hint {
    sort(hints);
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

pub fn relocate(
    arena: std.mem.Allocator,
    scratch: std.mem.Allocator,
    hints: []const Hint,
    target: ir.Program,
    functions: []const p.Id,
    locals: []const witness.Local,
) RelocationError![]const Hint {
    const members = try scratch.alloc(usize, target.functions.len);
    defer scratch.free(members);
    @memset(members, 0);
    for (functions) |function| {
        if (function == relocation.missing) continue;
        if (function >= members.len) return error.InvalidCorrespondence;
        members[@intCast(function)] += 1;
    }
    const placed = try scratch.alloc(Hint, hints.len);
    defer scratch.free(placed);
    const relocated = try place(placed, hints, functions, locals);
    const joined = try join(relocated, members);
    validate(target, joined) catch return error.InvalidCorrespondence;
    return arena.dupe(Hint, joined);
}

fn place(
    placed: []Hint,
    hints: []const Hint,
    functions: []const p.Id,
    locals: []const witness.Local,
) error{InvalidCorrespondence}![]Hint {
    var length: usize = 0;
    for (hints) |hint| {
        if (hint.function >= functions.len or hint.function >= locals.len)
            return error.InvalidCorrespondence;
        const function = functions[@intCast(hint.function)];
        if (function == relocation.missing) continue;
        const slots = locals[@intCast(hint.function)].slots;
        if (hint.slot >= slots.len) return error.InvalidCorrespondence;
        placed[length] = .{
            .function = function,
            .slot = slots[@intCast(hint.slot)],
            .kind = hint.kind,
        };
        length += 1;
    }
    sort(placed[0..length]);
    return placed[0..length];
}

fn join(placed: []Hint, members: []const usize) error{InvalidCorrespondence}![]Hint {
    var length: usize = 0;
    var start: usize = 0;
    while (start < placed.len) {
        const binding = placed[start];
        var kind = binding.kind;
        var end = start + 1;
        while (end < placed.len and placed[end].sameBinding(binding)) : (end += 1)
            kind = kind.join(placed[end].kind);
        const merged = members[@intCast(binding.function)];
        if (end - start > merged) return error.InvalidCorrespondence;
        if (end - start < merged) kind = .residual;
        placed[length] = .{ .function = binding.function, .slot = binding.slot, .kind = kind };
        length += 1;
        start = end;
    }
    return placed[0..length];
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
