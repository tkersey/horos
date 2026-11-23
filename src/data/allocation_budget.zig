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

fn reserve(self: *AllocationBudget, bytes: usize) bool {
    if (bytes == 0) return true;
    self.exhausted = bytes > self.remaining.*;
    if (self.exhausted) return false;
    self.remaining.* -= bytes;
    return true;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self: *AllocationBudget = @ptrCast(@alignCast(ctx));
    if (!self.reserve(len)) return null;
    return self.parent.rawAlloc(len, alignment, ra) orelse {
        self.remaining.* += len;
        return null;
    };
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
    if (!self.reserve(growth)) return false;
    if (!self.parent.rawResize(memory, alignment, len, ra)) {
        self.remaining.* += growth;
        return false;
    }
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
    if (!self.reserve(growth)) return null;
    const result = self.parent.rawRemap(memory, alignment, len, ra) orelse {
        self.remaining.* += growth;
        return null;
    };
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

test "allocation refusal tracks the current growth request through recovery and cleanup" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var remaining: usize = 12;
    var cap: AllocationBudget = .{
        .parent = backing.allocator(),
        .remaining = &remaining,
        .accounting = .live,
    };
    const a = cap.allocator();
    const first = try a.alloc(u8, 4);
    defer a.free(first);
    try std.testing.expect(!a.resize(first, 13));
    try std.testing.expect(cap.exhausted);
    const second = try a.alloc(u8, 4);
    try std.testing.expect(!cap.exhausted);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 5));
    try std.testing.expect(cap.exhausted);
    a.free(second);
    try std.testing.expect(cap.exhausted);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 5));
    try std.testing.expect(!cap.exhausted);
}

test "nested allocation budgets reserve and refund growth in delegation order" {
    for ([_]@FieldType(AllocationBudget, "accounting"){ .live, .cumulative }) |accounting| {
        var memory: [16]u8 = undefined;
        var backing = std.heap.FixedBufferAllocator.init(&memory);
        var remaining: usize = 12;
        var parent: AllocationBudget = .{
            .parent = backing.allocator(),
            .remaining = &remaining,
            .accounting = accounting,
        };
        var child: AllocationBudget = .{
            .parent = parent.allocator(),
            .remaining = &remaining,
            .accounting = accounting,
        };
        const a = child.allocator();
        try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 7));
        try std.testing.expect(parent.exhausted and !child.exhausted);
        try std.testing.expectEqual(12, remaining);
        var bytes = try a.alloc(u8, 3);
        try std.testing.expectEqual(6, remaining);
        try std.testing.expect(!parent.exhausted and !child.exhausted);
        try std.testing.expect(!a.resize(bytes, 7));
        try std.testing.expectEqual(6, remaining);
        try std.testing.expect(a.remap(bytes, 7) == null);
        try std.testing.expectEqual(6, remaining);
        try std.testing.expect(a.resize(bytes, 4));
        bytes.len = 4;
        bytes = a.remap(bytes, 6).?;
        try std.testing.expectEqual(0, remaining);
        try std.testing.expect(a.resize(bytes, 2));
        bytes.len = 2;
        a.free(bytes);
        try std.testing.expectEqual(@as(usize, if (accounting == .live) 12 else 0), remaining);
    }
}

test "nested limits preserve independent allowances on refused and successful requests" {
    var available: usize = 3;
    var parent: AllocationBudget = .{ .parent = std.testing.allocator, .remaining = &available };
    var remaining: usize = 7;
    var child: AllocationBudget = .{ .parent = parent.allocator(), .remaining = &remaining };
    const a = child.allocator();
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 4));
    try std.testing.expectEqual(3, available);
    try std.testing.expectEqual(7, remaining);
    const bytes = try a.alloc(u8, 3);
    defer a.free(bytes);
    try std.testing.expectEqual(0, available);
    try std.testing.expectEqual(4, remaining);
}
