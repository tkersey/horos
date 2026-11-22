const std = @import("std");
const AllocationBudget = @This();

parent: std.mem.Allocator,
remaining: *usize,
exhausted: bool = false,
accounting: enum { cumulative, live } = .cumulative,

pub fn allocator(self: *AllocationBudget) std.mem.Allocator {
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
    self.release(memory.len -| len);
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
    self.release(memory.len -| len);
    return result;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
    self.parent.rawFree(memory, alignment, ra);
    self.release(memory.len);
}

fn release(self: *AllocationBudget, bytes: usize) void {
    if (self.accounting == .live) self.remaining.* += bytes;
}
