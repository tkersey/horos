// Copyright (c) 2026 Boundary contributors. MIT license.
//! Immutable sets of bounded IDs used by analysis, not serialized authority.
//! Contiguous runs are one node; sparse subsets of an aligned 64-ID word use a
//! bitmap leaf. Larger sets share canonical binary subtrees. A path splits at a
//! strictly decreasing bit, never at a previous set version.
const std = @import("std");
pub const Member = u64;
// Private analysis indexes are bounded independently of full-width members.
// Four billion nodes exceed the qualified runtime budgets; exhaustion fails
// before publishing a root and does not narrow the represented member domain.
pub const Root = u32;
pub const empty: Root = 0;
pub const Error = std.mem.Allocator.Error || error{ InvalidReference, RelationLimit };

const Node = struct {
    low: Member,
    high: Member,
    // Runs have zero payload. Word leaves have nonzero bits; split trees have
    // two nonempty roots and span multiple words. No cached count or kind tag.
    payload: extern union {
        word: u64,
        tree: extern struct {
            left: Root,
            right: Root,
        },
    } = .{ .tree = .{ .left = empty, .right = empty } },

    comptime {
        // Both initialized root lanes must fill the word used for equality.
        std.debug.assert(2 * @bitSizeOf(Root) == @bitSizeOf(u64));
    }

    fn isRun(self: Node) bool {
        return self.payload.word == 0;
    }
    fn isWord(self: Node) bool {
        return !self.isRun() and (self.low >> 6) == ((self.high - 1) >> 6);
    }
    fn wordBits(self: Node) u64 {
        if (self.isWord()) return self.payload.word;
        std.debug.assert(self.isRun() and (self.low >> 6) == ((self.high - 1) >> 6));
        const base = self.low & ~@as(u64, 63);
        const high = self.high - base;
        const upper: u64 = if (high == 64) std.math.maxInt(u64) else (@as(
            u64,
            1,
        ) << @intCast(high)) - 1;
        return upper & ~((@as(u64, 1) << @intCast(self.low - base)) - 1);
    }
};

const CompactNode = struct {
    low: u32,
    high: u32,
    payload: u64,

    fn expand(self: CompactNode) Node {
        return .{ .low = self.low, .high = self.high, .payload = .{ .word = self.payload } };
    }
};

// The pool's declared member limit selects storage, never its public ID width.
// Large-domain pools keep the full representation, including in overlays.
const Nodes = union(enum) {
    compact: std.ArrayList(CompactNode),
    wide: std.ArrayList(Node),

    pub fn len(self: Nodes) usize {
        return switch (self) {
            inline else => |list| list.items.len,
        };
    }
    pub fn capacity(self: Nodes) usize {
        return switch (self) {
            inline else => |list| list.capacity,
        };
    }
    fn get(self: Nodes, index: usize) Node {
        return switch (self) {
            .compact => |list| list.items[index].expand(),
            .wide => |list| list.items[index],
        };
    }
    fn ensureUnusedCapacity(self: *Nodes, allocator: std.mem.Allocator, limit: Member) Error!void {
        if (self.len() == 0 and self.capacity() == 0 and limit > std.math.maxInt(u32))
            self.* = .{ .wide = .empty };
        switch (self.*) {
            inline else => |*list| try list.ensureUnusedCapacity(allocator, 1),
        }
    }
    fn appendAssumeCapacity(self: *Nodes, value: Node) void {
        switch (self.*) {
            .compact => |*list| list.appendAssumeCapacity(.{
                .low = @intCast(value.low),
                .high = @intCast(value.high),
                .payload = value.payload.word,
            }),
            .wide => |*list| list.appendAssumeCapacity(value),
        }
    }
    fn deinit(self: *Nodes, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*list| list.deinit(allocator),
        }
    }
};

const NodeContext = struct {
    pub fn hash(_: NodeContext, node_: Node) u64 {
        // Bounds/cardinality remain part of exact equality. Canonical children
        // already determine them, so hashing their duplicate fields is needless.
        const kind: u64 = if (node_.isRun()) 0 else if (node_.isWord()) 1 else 2;
        const key: [2]u64 = switch (kind) {
            0 => .{ node_.low, node_.high },
            1 => .{ node_.low & ~@as(u64, 63), node_.payload.word },
            else => .{ node_.payload.tree.left, node_.payload.tree.right },
        };
        return std.hash.Wyhash.hash(kind, std.mem.asBytes(&key));
    }
    pub fn eql(_: NodeContext, a: Node, b: Node) bool {
        return a.low == b.low and a.high == b.high and a.payload.word == b.payload.word;
    }
};

// Keys are stable node IDs; the canonical node has one physical owner.
const RootContext = struct {
    pool: *const Pool,
    pub fn hash(self: RootContext, root: Root) u64 {
        return NodeContext.hash(.{}, self.pool.node(root));
    }
    pub fn eql(_: RootContext, a: Root, b: Root) bool {
        return a == b;
    }
};
const LookupContext = struct {
    pool: *const Pool,
    hash_value: u64,
    pub fn hash(self: LookupContext, _: Node) u64 {
        return self.hash_value;
    }
    pub fn eql(self: LookupContext, value: Node, root: Root) bool {
        return NodeContext.eql(.{}, value, self.pool.node(root));
    }
};

test "canonical equality distinguishes runs from sparse sets with the same bounds" {
    var pool: Pool = .{ .allocator = std.testing.allocator, .limit = 128 };
    defer pool.deinit();
    const dense_word = try pool.run(0, 3);
    const sparse_word = try pool.unite(try pool.run(0, 1), try pool.run(2, 3));
    const dense_tree = try pool.run(0, 65);
    const sparse_tree = try pool.unite(try pool.run(0, 1), try pool.run(64, 65));
    try std.testing.expect(!NodeContext.eql(.{}, pool.node(dense_word), pool.node(sparse_word)));
    try std.testing.expect(!NodeContext.eql(.{}, pool.node(dense_tree), pool.node(sparse_tree)));
    try std.testing.expectEqual(3, pool.count(dense_word));
    try std.testing.expectEqual(65, pool.count(dense_tree));
    try std.testing.expectEqual(2, pool.count(sparse_word));
    try std.testing.expectEqual(2, pool.count(sparse_tree));
}

pub const Pool = struct {
    work: ?*u64 = null,
    allocator: std.mem.Allocator,
    limit: Member,
    // Native compaction is qualified independently; wasm32 keeps its untagged array.
    nodes: if (@sizeOf(usize) > 4)
        Nodes
    else
        std.ArrayList(Node) = if (@sizeOf(usize) > 4)
        .{ .compact = .empty }
    else
        .empty,
    interned: std.HashMapUnmanaged(Root, void, RootContext, 80) = .empty,
    visits: usize = 0,
    retained_bytes: usize = 0,
    base: ?*const ReadOnly = null,

    /// The owner must keep this root pool immutable and alive while borrowed.
    /// Only one base is permitted; lookup never walks a version chain.
    fn spend(self: *const Pool, count_: usize) Error!void {
        @import("admission.zig").spend(self.work, count_) catch return error.RelationLimit;
    }

    pub fn readOnly(self: *const Pool) Error!*const ReadOnly {
        if (self.base != null) return error.InvalidReference;
        return @ptrCast(self);
    }
    pub fn overlay(allocator: std.mem.Allocator, base: *const ReadOnly) Pool {
        return .{ .allocator = allocator, .limit = base.pool().limit, .base = base };
    }
    pub inline fn nodeCount(self: *const Pool) usize {
        return if (comptime @sizeOf(usize) > 4) self.nodes.len() else self.nodes.items.len;
    }
    pub inline fn nodeCapacity(self: *const Pool) usize {
        return if (comptime @sizeOf(usize) > 4) self.nodes.capacity() else self.nodes.capacity;
    }
    inline fn nodeAt(self: *const Pool, index: usize) Node {
        return if (comptime @sizeOf(usize) > 4) self.nodes.get(index) else self.nodes.items[index];
    }
    inline fn ensureNodeCapacity(self: *Pool) Error!void {
        if (comptime @sizeOf(usize) > 4) {
            try self.nodes.ensureUnusedCapacity(self.bufferAllocator(), self.limit);
        } else try self.nodes.ensureUnusedCapacity(self.bufferAllocator(), 1);
    }
    fn baseCount(self: *const Pool) usize {
        return if (self.base) |base| base.pool().nodeCount() else 0;
    }

    pub fn deinit(self: *Pool) void {
        self.nodes.deinit(self.bufferAllocator());
        self.interned.deinit(self.bufferAllocator());
        std.debug.assert(self.retained_bytes == 0);
        self.* = undefined;
    }

    /// Owned backing capacity for the node array and interning table. Allocator
    /// overhead is excluded, consistently with ArenaAllocator.queryCapacity.
    pub fn storageBytes(self: *const Pool) usize {
        return self.retained_bytes;
    }

    // Unmanaged containers retain no allocator/context pointer. Each operation
    // borrows this Pool only until its allocation or deallocation returns.
    fn bufferAllocator(self: *Pool) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocateBuffer,
                .resize = resizeBuffer,
                .remap = remapBuffer,
                .free = freeBuffer,
            },
        };
    }
    fn allocateBuffer(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *Pool = @ptrCast(@alignCast(context));
        const bytes = self.allocator.rawAlloc(length, alignment, ra) orelse return null;
        self.retained_bytes += length;
        return bytes;
    }
    fn resizeBuffer(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        length: usize,
        ra: usize,
    ) bool {
        const self: *Pool = @ptrCast(@alignCast(context));
        if (!self.allocator.rawResize(bytes, alignment, length, ra)) return false;
        self.retained_bytes = self.retained_bytes - bytes.len + length;
        return true;
    }
    fn remapBuffer(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        length: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *Pool = @ptrCast(@alignCast(context));
        const result = self.allocator.rawRemap(bytes, alignment, length, ra) orelse return null;
        self.retained_bytes = self.retained_bytes - bytes.len + length;
        return result;
    }
    fn freeBuffer(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Pool = @ptrCast(@alignCast(context));
        self.allocator.rawFree(bytes, alignment, ra);
        self.retained_bytes -= bytes.len;
    }

    inline fn node(self: *const Pool, root: Root) Node {
        const count_ = self.baseCount();
        std.debug.assert(root != empty and root <= count_ + self.nodeCount());
        if (root <= count_) return self.base.?.pool().nodeAt(root - 1);
        return self.nodeAt(root - count_ - 1);
    }

    /// Membership projection for IDs 0 through 63. Higher IDs are intentionally
    /// omitted; the caller must not use this as a complete mask for larger layouts.
    pub fn lowWord(self: *const Pool, root: Root) u64 {
        var current = root;
        while (current != empty) {
            const value = self.node(current);
            if (value.low >= 64) return 0;
            if (value.isWord()) return value.payload.word;
            if (!value.isRun()) {
                std.debug.assert(self.node(value.payload.tree.right).low >= 64);
                current = value.payload.tree.left;
                continue;
            }
            const high = @min(value.high, 64);
            const upper: u64 = if (high ==
                64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(high)) -
                    1;
            const lower = (@as(u64, 1) << @intCast(value.low)) - 1;
            return upper & ~lower;
        }
        return 0;
    }

    fn intern(self: *Pool, value: Node) Error!Root {
        try self.spend(1);
        const hash = NodeContext.hash(.{}, value);
        if (self.base) |base| if (base.pool().interned.getKeyAdapted(
            value,
            LookupContext{ .pool = base.pool(), .hash_value = hash },
        )) |root| return root;
        const lookup: LookupContext = .{ .pool = self, .hash_value = hash };
        // A separate index-space bound is needed only when Root is narrower.
        // At pointer width, the checked additions below already enforce it.
        if (comptime @sizeOf(Root) < @sizeOf(usize)) {
            if (self.baseCount() >= std.math.maxInt(Root) or
                self.nodeCount() >= std.math.maxInt(Root) - self.baseCount())
            {
                if (self.interned.getKeyAdapted(value, lookup)) |root| return root;
                return error.OutOfMemory;
            }
        }
        if (self.nodeCount() == self.nodeCapacity() or self.interned.available == 0) {
            // Existing roots never require allocation, including at capacity.
            if (self.interned.getKeyAdapted(value, lookup)) |root| return root;
            try self.spend(std.math.add(usize, self.nodeCount(), 1) catch
                return error.RelationLimit);
            try self.ensureNodeCapacity();
            try self.interned.ensureUnusedCapacityContext(
                self.bufferAllocator(),
                1,
                .{ .pool = self },
            );
        }
        std.debug.assert(value.low < value.high and value.high <= self.limit);
        const local = std.math.add(usize, self.nodeCount(), 1) catch return error.OutOfMemory;
        const index = std.math.add(usize, self.baseCount(), local) catch return error.OutOfMemory;
        // The narrower-index guard above bounds this conversion.
        const root: Root = @intCast(index);
        const entry = self.interned.getOrPutAssumeCapacityAdapted(value, lookup);
        if (entry.found_existing) return entry.key_ptr.*;
        // All fallible work is complete. The temporary empty key cannot escape
        // this sequential Pool operation before the owning node is published.
        self.nodes.appendAssumeCapacity(value);
        entry.key_ptr.* = root;
        return root;
    }

    pub fn run(self: *Pool, low: Member, high: Member) Error!Root {
        if (low > high or high > self.limit) return error.InvalidReference;
        if (low == high) return empty;
        return self.intern(.{ .low = low, .high = high });
    }

    // One canonical leaf for each noncontiguous subset of an aligned word.
    // Full intervals still use run nodes, including intervals spanning words.
    fn word(self: *Pool, base: Member, bits: u64) Error!Root {
        if (bits == 0) return empty;
        const low = base + @ctz(bits);
        const high = base + (64 - @as(u64, @clz(bits)));
        const count_: u64 = @popCount(bits);
        if (count_ == high - low) return self.run(low, high);
        return self.intern(.{ .low = low, .high = high, .payload = .{ .word = bits } });
    }

    pub fn insert(self: *Pool, root: Root, member: Member) Error!Root {
        if (member >= self.limit) return error.InvalidReference;
        return self.changeMember(.insert, root, member);
    }

    fn insertedLeaf(self: *Pool, root: Root, member: Member) Error!?Root {
        if (root == empty) return try self.run(member, member + 1);
        const value = self.node(root);
        if (value.isRun()) {
            if (member >= value.low and member < value.high) return root;
            if (member + 1 == value.low or member == value.high)
                return try self.run(@min(value.low, member), @max(value.high, member + 1));
        }
        const low = @min(value.low, member);
        const high = @max(value.high, member + 1);
        if ((low >> 6) == ((high - 1) >> 6)) {
            const before = value.wordBits();
            const after = before | (@as(u64, 1) << @intCast(member & 63));
            return if (before == after) root else try self.word(low & ~@as(u64, 63), after);
        }
        return null;
    }

    /// Exact cardinality: constant time for leaves, otherwise visits the tree.
    pub fn count(self: *const Pool, root: Root) Member {
        if (root == empty) return 0;
        var pending: [@bitSizeOf(Member) + 1]Root = undefined;
        pending[0] = root;
        var length: usize = 1;
        var result: Member = 0;
        while (length != 0) {
            length -= 1;
            const value = self.node(pending[length]);
            if (value.isRun())
                result +=
                    value.high -
                    value.low
            else if (value.isWord())
                result +=
                    @popCount(value.payload.word)
            else {
                std.debug.assert(length + 2 <= pending.len);
                pending[length] = value.payload.tree.right;
                pending[length + 1] = value.payload.tree.left;
                length += 2;
            }
        }
        return result;
    }

    fn countWithWork(self: *const Pool, root: Root) Error!Member {
        if (root == empty) return 0;
        var pending: [@bitSizeOf(Member) + 1]Root = undefined;
        pending[0] = root;
        var length: usize = 1;
        var result: Member = 0;
        while (length != 0) {
            try self.spend(1);
            length -= 1;
            const value = self.node(pending[length]);
            if (value.isRun())
                result +=
                    value.high -
                    value.low
            else if (value.isWord())
                result +=
                    @popCount(value.payload.word)
            else {
                std.debug.assert(length + 2 <= pending.len);
                pending[length] = value.payload.tree.right;
                pending[length + 1] = value.payload.tree.left;
                length += 2;
            }
        }
        return result;
    }

    pub fn first(self: *const Pool, root: Root) ?Member {
        return if (root == empty) null else self.node(root).low;
    }

    pub fn contains(self: *const Pool, root: Root, member: Member) bool {
        var current = root;
        while (current != empty) {
            const value = self.node(current);
            if (member < value.low or member >= value.high) return false;
            if (value.isWord()) return value.payload.word & (@as(
                u64,
                1,
            ) << @intCast(member & 63)) != 0;
            if (value.isRun()) return true;
            current = if (member < split(
                value.low,
                value.high,
            )) value.payload.tree.left else value.payload.tree.right;
        }
        return false;
    }

    pub fn unite(self: *Pool, a: Root, b: Root) Error!Root {
        return self.combine(.unite, a, b);
    }

    pub fn intersect(self: *Pool, a: Root, b: Root) Error!Root {
        return self.combine(.intersect, a, b);
    }

    pub fn difference(self: *Pool, a: Root, b: Root) Error!Root {
        return self.combine(.difference, a, b);
    }

    const Combination = enum { unite, intersect, difference };
    const CombineFrame = struct {
        left: [2]Root,
        right: [2]Root = undefined,
        low: Root = empty,
        phase: enum { enter, lower, upper } = .enter,
    };

    fn combine(self: *Pool, comptime operation: Combination, a: Root, b: Root) Error!Root {
        var pending: [@bitSizeOf(Member) + 1]CombineFrame = undefined;
        pending[0] = .{ .left = .{ a, b } };
        var length: usize = 1;
        var result: Root = empty;
        while (length != 0) {
            try self.spend(1);
            const frame = &pending[length - 1];
            switch (frame.phase) {
                .enter => {
                    try self.spend(1);
                    self.visits +|= 1;
                    const leaf = try switch (operation) {
                        .unite => self.uniteLeaf(frame.left[0], frame.left[1]),
                        .intersect => self.intersectLeaf(frame.left[0], frame.left[1]),
                        .difference => self.differenceLeaf(frame.left[0], frame.left[1]),
                    };
                    if (leaf) |value| {
                        result = value;
                        length -= 1;
                        continue;
                    }
                    const left = self.node(frame.left[0]);
                    const right = self.node(frame.left[1]);
                    const middle = split(@min(left.low, right.low), @max(left.high, right.high));
                    const x = try self.partition(frame.left[0], middle);
                    const y = try self.partition(frame.left[1], middle);
                    frame.right = .{ x[1], y[1] };
                    frame.phase = .lower;
                    std.debug.assert(length < pending.len);
                    pending[length] = .{ .left = .{ x[0], y[0] } };
                    length += 1;
                },
                .lower => {
                    frame.low = result;
                    frame.phase = .upper;
                    std.debug.assert(length < pending.len);
                    pending[length] = .{ .left = frame.right };
                    length += 1;
                },
                .upper => {
                    result = try self.join(frame.low, result);
                    length -= 1;
                },
            }
        }
        return result;
    }

    fn uniteLeaf(self: *Pool, a: Root, b: Root) Error!?Root {
        if (a == empty or a == b) return b;
        if (b == empty) return a;
        const left = self.node(a);
        const right = self.node(b);
        if (left.isRun() and left.low <= right.low and left.high >= right.high) return a;
        if (right.isRun() and right.low <= left.low and right.high >= left.high) return b;
        if (left.isRun() and right.isRun() and
            left.low <= right.high and right.low <= left.high)
            return try self.run(@min(left.low, right.low), @max(left.high, right.high));
        const low_bound = @min(left.low, right.low);
        if ((low_bound >> 6) == ((@max(left.high, right.high) - 1) >> 6))
            return try self.word(low_bound & ~@as(u64, 63), left.wordBits() | right.wordBits());
        return null;
    }

    fn intersectLeaf(self: *Pool, a: Root, b: Root) Error!?Root {
        if (a == empty or b == empty) return empty;
        if (a == b) return a;
        const left = self.node(a);
        const right = self.node(b);
        if (left.high <= right.low or right.high <= left.low) return empty;
        if (left.isRun() and left.low <= right.low and left.high >= right.high) return b;
        if (right.isRun() and right.low <= left.low and right.high >= left.high) return a;
        if (left.isRun() and right.isRun())
            return try self.run(@max(left.low, right.low), @min(left.high, right.high));
        const low_bound = @min(left.low, right.low);
        if ((low_bound >> 6) == ((@max(left.high, right.high) - 1) >> 6))
            return try self.word(low_bound & ~@as(u64, 63), left.wordBits() & right.wordBits());
        return null;
    }

    fn differenceLeaf(self: *Pool, a: Root, b: Root) Error!?Root {
        if (a == empty or a == b) return empty;
        if (b == empty) return a;
        const left = self.node(a);
        const right = self.node(b);
        if (left.high <= right.low or right.high <= left.low) return a;
        if (right.isRun() and right.low <= left.low and right.high >= left.high) return empty;
        if (left.isRun() and right.isRun()) {
            const low = try self.run(left.low, @max(left.low, right.low));
            const high = try self.run(@min(left.high, right.high), left.high);
            return try self.unite(low, high);
        }
        const low_bound = @min(left.low, right.low);
        if ((low_bound >> 6) == ((@max(left.high, right.high) - 1) >> 6))
            return try self.word(low_bound & ~@as(u64, 63), left.wordBits() & ~right.wordBits());
        return null;
    }

    pub fn remove(self: *Pool, root: Root, member: Member) Error!Root {
        return self.changeMember(.remove, root, member);
    }

    fn removedLeaf(self: *Pool, root: Root, member: Member) Error!?Root {
        if (root == empty) return empty;
        const value = self.node(root);
        if (member < value.low or member >= value.high) return root;
        if (value.isWord()) return try self.word(
            value.low & ~@as(u64, 63),
            value.payload.word & ~(@as(u64, 1) << @intCast(member & 63)),
        );
        if (value.isRun()) {
            const left = try self.run(value.low, member);
            const right = try self.run(member + 1, value.high);
            return try self.unite(left, right);
        }
        return null;
    }

    const Change = enum { insert, remove };
    const ChangeFrame = struct {
        root: Root,
        children: [2]Root,
        selected: u1,
    };

    fn changeMember(
        self: *Pool,
        comptime operation: Change,
        root: Root,
        member: Member,
    ) Error!Root {
        var pending: [@bitSizeOf(Member)]ChangeFrame = undefined;
        var length: usize = 0;
        var current = root;
        var result: Root = empty;
        for (0..pending.len + 1) |_| {
            try self.spend(1);
            self.visits +|= 1;
            const leaf = try switch (operation) {
                .insert => self.insertedLeaf(current, member),
                .remove => self.removedLeaf(current, member),
            };
            if (leaf) |value| {
                result = value;
                break;
            }
            const value = self.node(current);
            const middle = switch (operation) {
                .insert => split(@min(value.low, member), @max(value.high, member + 1)),
                .remove => split(value.low, value.high),
            };
            const children = try self.partition(current, middle);
            const selected: u1 = @intFromBool(member >= middle);
            std.debug.assert(length < pending.len);
            pending[length] = .{ .root = current, .children = children, .selected = selected };
            length += 1;
            current = children[selected];
        } else unreachable;
        while (length != 0) {
            try self.spend(1);
            length -= 1;
            var frame = pending[length];
            if (operation == .insert and frame.children[frame.selected] == result) {
                result = frame.root;
                continue;
            }
            frame.children[frame.selected] = result;
            result = try self.join(frame.children[0], frame.children[1]);
        }
        return result;
    }

    pub fn excluding(self: *Pool, root: Root, members: []const Member) Error!Root {
        var result = root;
        for (members) |member| result = try self.remove(result, member);
        return result;
    }

    pub fn merge(self: *Pool, target: *Root, other: Root, excluded: []const Member) Error!bool {
        const result = try self.unite(target.*, try self.excluding(other, excluded));
        const changed = result != target.*;
        target.* = result;
        return changed;
    }

    fn partition(self: *Pool, root: Root, middle: Member) Error![2]Root {
        if (root == empty) return .{ empty, empty };
        const value = self.node(root);
        if (value.high <= middle) return .{ root, empty };
        if (value.low >= middle) return .{ empty, root };
        if (value.isRun()) return .{
            try self.run(value.low, middle), try self.run(middle, value.high),
        };
        // The caller splits at the highest differing bit of the combined span.
        // Any crossing non-run has that same split; no version-chain traversal.
        std.debug.assert(split(value.low, value.high) == middle);
        return .{ value.payload.tree.left, value.payload.tree.right };
    }

    fn join(self: *Pool, left: Root, right: Root) Error!Root {
        if (left == empty) return right;
        if (right == empty) return left;
        const a = self.node(left);
        const b = self.node(right);
        const middle = split(a.low, b.high);
        std.debug.assert(a.high <= middle and b.low >= middle);
        if (a.isRun() and b.isRun() and a.high == b.low) return self.run(a.low, b.high);
        if ((a.low >> 6) == ((b.high - 1) >> 6)) return self.word(
            a.low & ~@as(u64, 63),
            a.wordBits() | b.wordBits(),
        );
        return self.intern(.{
            .low = a.low,
            .high = b.high,
            .payload = .{ .tree = .{ .left = left, .right = right } },
        });
    }

    /// Materialize only when an actual consumer needs the individual members.
    /// Caller owns the slice; no slice into reallocating pool storage escapes.
    pub fn materialize(self: *const Pool, allocator: std.mem.Allocator, root: Root) Error![]Member {
        const length = std.math.cast(usize, try self.countWithWork(root)) orelse
            return error.OutOfMemory;
        try self.spend(length);
        const result = try allocator.alloc(Member, length);
        var traversal = self.iterator(root);
        for (result) |*member| member.* = traversal.next().?;
        std.debug.assert(traversal.next() == null);
        return result;
    }

    pub fn iterator(self: *const Pool, root: Root) Iterator {
        var result: Iterator = .{ .pool = self };
        if (root != empty) {
            result.pending[0] = root;
            result.length = 1;
        }
        return result;
    }
};

/// No mutable pool fields escape through an admitted owner's shared base.
pub const ReadOnly = opaque {
    pub fn nodeCount(self: *const ReadOnly) usize {
        return self.pool().nodeCount();
    }
    fn pool(self: *const ReadOnly) *const Pool {
        return @ptrCast(@alignCast(self));
    }
};

fn split(low: Member, high: Member) Member {
    std.debug.assert(high - low >= 2);
    const last = high - 1;
    const bit: u6 = @intCast(63 - @clz(low ^ last));
    const width = @as(Member, 1) << bit;
    return last & ~(width - 1);
}

pub const Iterator = struct {
    pool: *const Pool,
    pending: [65]Root = undefined,
    length: usize = 0,
    cursor: Member = 0,
    end: Member = 0,
    bits: u64 = 0,
    word_base: Member = 0,

    pub fn next(self: *Iterator) ?Member {
        while (self.cursor == self.end) {
            if (self.bits != 0) {
                const bit = @ctz(self.bits);
                self.bits &= self.bits - 1;
                return self.word_base + bit;
            }
            if (self.length == 0) return null;
            self.length -= 1;
            const value = self.pool.node(self.pending[self.length]);
            if (value.isWord()) {
                self.bits = value.payload.word;
                self.word_base = value.low & ~@as(u64, 63);
            } else if (value.isRun()) {
                self.cursor = value.low;
                self.end = value.high;
            } else {
                std.debug.assert(self.length + 2 <= self.pending.len);
                self.pending[self.length] = value.payload.tree.right;
                self.pending[self.length + 1] = value.payload.tree.left;
                self.length += 2;
            }
        }
        const result = self.cursor;
        self.cursor += 1;
        return result;
    }
};
