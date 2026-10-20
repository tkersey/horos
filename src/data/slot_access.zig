// Copyright (c) 2026 Boundary contributors. MIT license.
//! Exact stable-slot reads and writes. Edge assignments remain simultaneous.
const ir = @import("activation.zig");
const p = @import("program.zig");
const roles = @import("reference_roles.zig");
pub const Access = struct { reads: usize = 0, writes: usize = 0 };
const Counter = struct {
    pub const VisitError = error{};
    slot: p.Id,
    result: Access = .{},
    pub fn reference(
        self: *Counter,
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
    fn referenceOne(self: *Counter, comptime role: roles.Role, value: anytype) VisitError!void {
        switch (role) {
            .slot_read => self.result.reads += @intFromBool(value == self.slot),
            .slot_write => self.result.writes += @intFromBool(value == self.slot),
            .edge => try roles.visitEdge(value, self),
            .assignment => try roles.visitAssignment(value, self),
            .source => try roles.visitSource(value, self),
            .function, .effect, .handler, .region, .block, .nonreference => {},
        }
    }
};
pub fn terminator(term: ir.Terminator, slot: p.Id) Access {
    var counter: Counter = .{ .slot = slot };
    roles.visitTerminator(term, &counter) catch |err| switch (err) {};
    return counter.result;
}
