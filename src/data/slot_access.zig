// Copyright (c) 2026 Boundary contributors. MIT license.
//! Exact stable-slot reads and writes. Edge assignments remain simultaneous.
const ir = @import("activation.zig");
const p = @import("program.zig");
const roles = @import("reference_roles.zig");
pub const Access = struct { reads: usize = 0, writes: usize = 0 };
fn Slots(comptime Sink: type) type {
    return struct {
        const Self = @This();
        pub const VisitError = error{};
        sink: *Sink,
        pub fn reference(
            self: *Self,
            comptime role: roles.Role,
            comptime cardinality: roles.Cardinality,
            value: anytype,
        ) VisitError!void {
            if (comptime cardinality == .list) {
                for (value) |item| try self.referenceOne(role, item);
            } else if (comptime cardinality == .optional) {
                if (value) |item| try self.referenceOne(role, item);
            } else try self.referenceOne(role, value);
        }
        fn referenceOne(self: *Self, comptime role: roles.Role, value: anytype) VisitError!void {
            switch (role) {
                .slot_read, .slot_write => self.sink.observe(role, value),
                .edge => try roles.visitEdge(value, self),
                .assignment => try roles.visitAssignment(value, self),
                .source => try roles.visitSource(value, self),
                .function, .effect, .handler, .region, .block, .nonreference => {},
            }
        }
    };
}
fn visit(term: ir.Terminator, sink: anytype) void {
    var visitor: Slots(@TypeOf(sink.*)) = .{ .sink = sink };
    roles.visitTerminator(term, &visitor) catch |err| switch (err) {};
}
const Counter = struct {
    slot: p.Id,
    result: Access = .{},
    fn observe(self: *Counter, comptime role: roles.Role, slot: p.Id) void {
        const matched = @intFromBool(slot == self.slot);
        if (role == .slot_read) self.result.reads += matched else self.result.writes += matched;
    }
};
pub fn terminator(term: ir.Terminator, slot: p.Id) Access {
    var counter: Counter = .{ .slot = slot };
    visit(term, &counter);
    return counter.result;
}
const Writes = struct {
    written: []bool,
    fn observe(self: *Writes, comptime role: roles.Role, slot: p.Id) void {
        if (role == .slot_write) self.written[@intCast(slot)] = true;
    }
};
pub fn markWrites(term: ir.Terminator, written: []bool) void {
    var writes: Writes = .{ .written = written };
    visit(term, &writes);
}
