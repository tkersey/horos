const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const relation = @import("relation.zig");
const Error = relation.Error;

pub const Rule = union(enum) {
    relocation: relation.Relocation.Maps,
    identity,
    scalar: relation.Scalar,
    inline_call: u64,
    product_layout: []const relation.Layout,
    specialization: []const u8,
};
pub const Step = struct { successor: source.ast.Module, rule: Rule };

pub fn decode(
    a: std.mem.Allocator,
    record: Step,
    remaining: *usize,
) Error!relation.Step {
    var budget: AllocationBudget = .{ .parent = a, .remaining = remaining };
    return decodeOwned(budget.allocator(), record) catch |err| {
        if (err == error.OutOfMemory and budget.exhausted) return error.Capacity;
        return err;
    };
}

fn decodeOwned(a: std.mem.Allocator, record: Step) Error!relation.Step {
    const rule: relation.Rule = switch (record.rule) {
        .specialization => |bytes| blk: {
            const owned = try a.dupe(u8, bytes);
            var reader: data.wire.Reader = .{ .input = owned };
            const proof = try data.record.read(relation.Specialization, &reader, a);
            try reader.finish();
            break :blk .{ .specialization = proof };
        },
        inline else => |payload, tag| @unionInit(
            relation.Rule,
            @tagName(tag),
            try source.own(@TypeOf(payload), a, payload),
        ),
    };
    return .{ .successor = try source.own(source.ast.Module, a, record.successor), .rule = rule };
}

const AllocationBudget = struct {
    parent: std.mem.Allocator,
    remaining: *usize,
    exhausted: bool = false,

    fn allocator(self: *AllocationBudget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn permits(self: *AllocationBudget, bytes: usize) bool {
        if (bytes <= self.remaining.*) return true;
        self.exhausted = true;
        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        if (!self.permits(len)) return null;
        const result = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.remaining.* -= len;
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) bool {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        const growth = len -| memory.len;
        if (!self.permits(growth)) return false;
        if (!self.parent.rawResize(memory, alignment, len, ra)) return false;
        self.remaining.* -= growth;
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        const growth = len -| memory.len;
        if (!self.permits(growth)) return null;
        const result = self.parent.rawRemap(memory, alignment, len, ra) orelse return null;
        self.remaining.* -= growth;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ra);
    }
};
pub fn encode(a: std.mem.Allocator, step: relation.Step) Error!Step {
    const rule: Rule = switch (step.rule) {
        .specialization => |proof| blk: {
            var measure: data.wire.Writer = .{};
            try data.record.writeAlloc(relation.Specialization, a, proof, &measure);
            const bytes = try a.alloc(u8, measure.position);
            var writer: data.wire.Writer = .{ .output = bytes };
            try data.record.writeAlloc(relation.Specialization, a, proof, &writer);
            break :blk .{ .specialization = bytes };
        },
        inline else => |payload, tag| @unionInit(
            Rule,
            @tagName(tag),
            try source.own(@TypeOf(payload), a, payload),
        ),
    };
    return .{ .successor = try source.own(source.ast.Module, a, step.successor), .rule = rule };
}
