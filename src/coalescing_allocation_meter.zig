// Copyright (c) 2026 Boundary contributors. MIT license.
//! Benchmark-only requested-byte accounting; excludes allocator metadata and RSS.
const std = @import("std");
const A = std.mem.Allocator;
const Alignment = std.mem.Alignment;
pub const Meter = struct {
    parent: A,
    live: usize = 0,
    peak: usize = 0,
    allocated: usize = 0,
    calls: usize = 0,

    pub fn allocator(self: *Meter) A {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn grow(self: *Meter, old: usize, new: usize) void {
        self.live -= old;
        self.live += new;
        if (new > old) self.allocated += new - old;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.calls += 1;
        self.grow(0, len);
        return result;
    }
    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        len: usize,
        ret: usize,
    ) bool {
        const self: *Meter = @ptrCast(@alignCast(context));
        if (!self.parent.rawResize(memory, alignment, len, ret)) return false;
        self.grow(memory.len, len);
        return true;
    }
    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        len: usize,
        ret: usize,
    ) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.parent.rawRemap(memory, alignment, len, ret) orelse return null;
        self.grow(memory.len, len);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self: *Meter = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ret);
        self.live -= memory.len;
    }
};

test "allocation meter counts retained and released storage around real allocator operations" {
    var meter: Meter = .{ .parent = std.testing.allocator };
    const a = meter.allocator();
    var first = try a.alloc(u8, 17);
    const second = try a.alloc(u8, 23);
    first = try a.realloc(first, 71);
    try std.testing.expectEqual(@as(usize, 94), meter.live);
    first = try a.realloc(first, 5);
    try std.testing.expectEqual(@as(usize, 28), meter.live);
    a.free(first);
    a.free(second);
    try std.testing.expectEqual(@as(usize, 0), meter.live);
    try std.testing.expect(meter.peak >= 94);
    try std.testing.expect(meter.allocated >= 94);
}
