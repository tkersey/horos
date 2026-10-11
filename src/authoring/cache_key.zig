//! Complete identity-aware keys for local authoring caches. No graph validation
//! or row normalization occurs during lookup or snapshot.
const std = @import("std");
const a = @import("../authoring.zig");
const raw = @import("runtime.zig");
pub const DefaultPolicy = struct {
    pub fn leaf(comptime T: type) bool {
        if (T == *const raw.Schema or T == *const raw.Operation or T == *const raw.Region) return true;
        if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one) return false;
        const Child = @typeInfo(T).pointer.child;
        if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "horos_handle")) return false;
        const metadata = Child.horos_handle;
        return switch (metadata.family) {
            .schema => T == *const a.Schema(metadata.shape),
            .operation => T == *const a.Operation(metadata.shape),
            else => false,
        };
    }
    pub fn eql(comptime T: type, left: T, right: T) bool {
        return left == right;
    }
    pub fn snapshot(comptime T: type, _: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
        return value;
    }
    pub fn release(comptime T: type, _: std.mem.Allocator, _: T) void {}
};

pub fn KeyOps(comptime Key: type, comptime Policy: type) type {
    comptime validate(Key, Policy);
    return struct {
        pub fn eql(left: Key, right: Key) bool {
            return equal(Key, Policy, left, right);
        }
        pub fn snapshot(allocator: std.mem.Allocator, value: Key) std.mem.Allocator.Error!Key {
            return copy(Key, Policy, allocator, value);
        }
    };
}
fn validate(comptime T: type, comptime Policy: type) void {
    if (Policy.leaf(T)) return;
    switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => {},
        .optional => |o| validate(o.child, Policy),
        .array => |ar| validate(ar.child, Policy),
        .@"struct" => |s| for (s.field_types, s.field_attrs) |Field, attr| {
            if (attr.@"comptime") @compileError("Horos cache key: comptime fields are not runtime key inputs");
            validate(Field, Policy);
        },
        .pointer => |ptr| {
            if (ptr.size != .slice or ptr.sentinel_ptr != null) @compileError("Horos cache key: pointer needs an explicit identity or ownership policy");
            validate(ptr.child, Policy);
        },
        else => @compileError("Horos cache key: unsupported field type " ++ @typeName(T)),
    }
}
fn equal(comptime T: type, comptime Policy: type, left: T, right: T) bool {
    if (comptime Policy.leaf(T)) return Policy.eql(T, left, right);
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => left == right,
        .optional => |o| if (left) |value| if (right) |other| equal(o.child, Policy, value, other) else false else right == null,
        .@"struct" => |s| blk: {
            inline for (s.field_names, s.field_types) |name, Field| if (!equal(Field, Policy, @field(left, name), @field(right, name))) break :blk false;
            break :blk true;
        },
        .array => |ar| blk: {
            for (left, right) |l, r| if (!equal(ar.child, Policy, l, r)) break :blk false;
            break :blk true;
        },
        .pointer => |ptr| blk: {
            if (left.len != right.len) break :blk false;
            for (left, right) |l, r| if (!equal(ptr.child, Policy, l, r)) break :blk false;
            break :blk true;
        },
        else => unreachable,
    };
}
fn copy(comptime T: type, comptime Policy: type, allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
    if (comptime Policy.leaf(T)) return Policy.snapshot(T, allocator, value);
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => value,
        .optional => |o| if (value) |present| try copy(o.child, Policy, allocator, present) else null,
        .@"struct" => |s| blk: {
            var output: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (s.field_names, s.field_types, 0..) |name, Field, i| {
                if (i < initialized) release(Field, Policy, allocator, @field(output, name));
            };
            inline for (s.field_names, s.field_types) |name, Field| {
                @field(output, name) = try copy(Field, Policy, allocator, @field(value, name));
                initialized += 1;
            }
            break :blk output;
        },
        .array => |ar| blk: {
            var output: T = undefined;
            var initialized: usize = 0;
            errdefer for (output[0..initialized]) |item| release(ar.child, Policy, allocator, item);
            for (&output, value) |*out, item| {
                out.* = try copy(ar.child, Policy, allocator, item);
                initialized += 1;
            }
            break :blk output;
        },
        .pointer => |ptr| blk: {
            const output = try allocator.alloc(ptr.child, value.len);
            var initialized: usize = 0;
            errdefer {
                for (output[0..initialized]) |item| release(ptr.child, Policy, allocator, item);
                allocator.free(output);
            }
            for (output, value) |*out, item| {
                out.* = try copy(ptr.child, Policy, allocator, item);
                initialized += 1;
            }
            break :blk output;
        },
        else => unreachable,
    };
}
fn release(comptime T: type, comptime Policy: type, allocator: std.mem.Allocator, value: T) void {
    if (comptime Policy.leaf(T)) return Policy.release(T, allocator, value);
    switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => {},
        .optional => |o| if (value) |present| release(o.child, Policy, allocator, present),
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, Field| release(Field, Policy, allocator, @field(value, name)),
        .array => |ar| for (value) |item| release(ar.child, Policy, allocator, item),
        .pointer => |ptr| {
            for (value) |item| release(ptr.child, Policy, allocator, item);
            allocator.free(value);
        },
        else => unreachable,
    }
}

const TestKey = struct { enabled: bool, order: enum { first, last }, count: u64, nested: struct { names: []const []const u8, optional: ?[2]u32 } };
fn snapshotAttempt(allocator: std.mem.Allocator) !void {
    const key: TestKey = .{ .enabled = true, .order = .first, .count = 7, .nested = .{ .names = &.{ "alpha", "beta" }, .optional = .{ 1, 2 } } };
    const saved = try KeyOps(TestKey, DefaultPolicy).snapshot(allocator, key);
    defer release(TestKey, DefaultPolicy, allocator, saved);
    try std.testing.expect(KeyOps(TestKey, DefaultPolicy).eql(key, saved));
}
test "cache key snapshots release every partial nested allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotAttempt, .{});
}
test "cache key snapshot owns nested slices and compares every record field" {
    const Ops = KeyOps(TestKey, DefaultPolicy);
    var text = [_]u8{ 'a', 'b' };
    var names = [_][]const u8{&text};
    var key: TestKey = .{ .enabled = true, .order = .first, .count = 7, .nested = .{ .names = &names, .optional = .{ 1, 2 } } };
    const saved = try Ops.snapshot(std.testing.allocator, key);
    defer release(TestKey, DefaultPolicy, std.testing.allocator, saved);
    inline for (.{ "enabled", "order", "count", "nested" }) |name| {
        var changed = key;
        if (comptime std.mem.eql(u8, name, "enabled")) changed.enabled = false;
        if (comptime std.mem.eql(u8, name, "order")) changed.order = .last;
        if (comptime std.mem.eql(u8, name, "count")) changed.count += 1;
        if (comptime std.mem.eql(u8, name, "nested")) changed.nested.optional = null;
        try std.testing.expect(!Ops.eql(key, changed));
    }
    text[0] = 'z';
    names[0] = "changed";
    key.nested.optional = .{ 2, 1 };
    try std.testing.expectEqualStrings("ab", saved.nested.names[0]);
    try std.testing.expect(!Ops.eql(key, saved));
}
