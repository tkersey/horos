const std = @import("std");
const record = @import("record.zig");
const wire = @import("wire.zig");
const Tag = enum(u8) { leaf = 3, branch = 11 };
const Node = union(Tag) {
    leaf: []const u8,
    branch: struct { prefix: ?u64, children: []const Node, suffix: [2]u8 },
};

test "recursive record canonical sparse tags borrow byte leaves" {
    const value: Node = .{ .branch = .{
        .prefix = 128,
        .children = &.{ .{ .leaf = "ab" }, .{ .leaf = "c" } },
        .suffix = .{ 7, 9 },
    } };
    const expected = [_]u8{ 11, 1, 128, 1, 2, 3, 2, 'a', 'b', 3, 1, 'c', 7, 9 };
    var bytes: [expected.len]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.writeAlloc(Node, std.testing.allocator, value, &writer);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
    var sizing: wire.Writer = .{};
    try record.writeAlloc(Node, std.testing.allocator, value, &sizing);
    try std.testing.expectEqual(bytes.len, sizing.position);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var hashed: wire.Writer = .{ .hasher = &hash, .expected = &bytes };
    try record.writeAlloc(Node, std.testing.allocator, value, &hashed);
    try std.testing.expectEqual(wire.digest(&bytes), hash.finalResult());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = &bytes };
    var budget: usize = 2 * @sizeOf(Node);
    const decoded = try record.readBounded(Node, &reader, arena.allocator(), &budget);
    try std.testing.expectEqual(0, budget);
    try reader.finish();
    try std.testing.expect(try record.equalAlloc(Node, std.testing.allocator, value, decoded));
    try std.testing.expectEqual(bytes[7..9].ptr, decoded.branch.children[0].leaf.ptr);
    try std.testing.expect(try record.overlapsAlloc(Node, std.testing.allocator, decoded, &bytes));
    try std.testing.expect(try record.overlapsAlloc(
        Node,
        std.testing.allocator,
        decoded,
        std.mem.sliceAsBytes(decoded.branch.children),
    ));
}

fn deepNodes(nodes: []Node) void {
    nodes[nodes.len - 1] = .{ .leaf = "end" };
    for (0..nodes.len - 1) |offset| {
        const index = nodes.len - offset - 2;
        nodes[index] = .{ .branch = .{
            .prefix = null,
            .children = nodes[index + 1 ..][0..1],
            .suffix = .{ 7, 9 },
        } };
    }
}

test "recursive record deep continuations preserve order without native recursion" {
    const nodes = try std.testing.allocator.alloc(Node, 8192);
    defer std.testing.allocator.free(nodes);
    deepNodes(nodes);
    var measured: wire.Writer = .{};
    try record.writeAlloc(Node, std.testing.allocator, nodes[0], &measured);
    const bytes = try std.testing.allocator.alloc(u8, measured.position);
    defer std.testing.allocator.free(bytes);
    var writer: wire.Writer = .{ .output = bytes };
    try record.writeAlloc(Node, std.testing.allocator, nodes[0], &writer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = bytes };
    const decoded = try record.read(Node, &reader, arena.allocator());
    try reader.finish();
    try std.testing.expect(try record.equalAlloc(Node, std.testing.allocator, nodes[0], decoded));
    try std.testing.expect(!try record.overlapsAlloc(Node, std.testing.allocator, nodes[0], bytes));
    nodes[nodes.len - 1] = .{ .leaf = "changed" };
    try std.testing.expect(!try record.equalAlloc(Node, std.testing.allocator, nodes[0], decoded));
}

test "recursive record write preserves partial byte and expected failure positions" {
    const node: Node = .{ .branch = .{
        .prefix = 128,
        .children = &.{.{ .leaf = "ab" }},
        .suffix = .{ 7, 9 },
    } };
    const expected = [_]u8{ 11, 1, 128, 1, 1, 3, 2, 'a', 'b', 7, 9 };
    var bytes: [expected.len]u8 = undefined;
    for (0..expected.len) |capacity| {
        var writer: wire.Writer = .{ .output = bytes[0..capacity] };
        try std.testing.expectError(error.Capacity, record.writeAlloc(
            Node,
            std.testing.allocator,
            node,
            &writer,
        ));
        const position = if (capacity == 8) 7 else if (capacity == 10) 9 else capacity;
        try std.testing.expectEqual(position, writer.position);
        try std.testing.expectEqualSlices(u8, expected[0..position], bytes[0..position]);
    }
    var wrong = expected;
    wrong[8] = 0;
    var compared: wire.Writer = .{ .expected = &wrong };
    try std.testing.expectError(error.NonCanonical, record.writeAlloc(
        Node,
        std.testing.allocator,
        node,
        &compared,
    ));
    try std.testing.expectEqual(7, compared.position);
}

test "recursive record count admission precedes payload allocation and budget debit" {
    const Row = struct { nodes: []const @This() };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var budget: usize = 0;
    var truncated: wire.Reader = .{ .input = &.{2} };
    try std.testing.expectError(error.Truncated, record.readBounded(
        []const Row,
        &truncated,
        failing.allocator(),
        &budget,
    ));
    try std.testing.expectEqual(0, failing.alloc_index);
    var capacity: wire.Reader = .{ .input = &.{ 1, 0 } };
    try std.testing.expectError(error.Capacity, record.readBounded(
        []const Row,
        &capacity,
        failing.allocator(),
        &budget,
    ));
    try std.testing.expectEqual(0, budget);
    try std.testing.expectEqual(0, failing.alloc_index);
    budget = @sizeOf(Row);
    capacity.position = 0;
    try std.testing.expectError(error.OutOfMemory, record.readBounded(
        []const Row,
        &capacity,
        failing.allocator(),
        &budget,
    ));
    try std.testing.expectEqual(0, budget);
}

fn failTraversal(allocator: std.mem.Allocator, node: Node) !void {
    var measured: wire.Writer = .{};
    try record.writeAlloc(Node, allocator, node, &measured);
    try std.testing.expect(try record.equalAlloc(Node, allocator, node, node));
    try std.testing.expect(!try record.overlapsAlloc(Node, allocator, node, "unrelated"));
}

fn failDecode(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = bytes };
    _ = try record.read(Node, &reader, arena.allocator());
    try reader.finish();
}

test "recursive record allocation failures retain errors and release traversal scratch" {
    var nodes: [80]Node = undefined;
    deepNodes(&nodes);
    try @import("allocation_testing.zig").check(std.testing.allocator, failTraversal, .{nodes[0]});
    var bytes: [512]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.writeAlloc(Node, std.testing.allocator, nodes[0], &writer);
    try @import("allocation_testing.zig").check(
        std.testing.allocator,
        failDecode,
        .{bytes[0..writer.position]},
    );
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!try record.equalAlloc(
        Node,
        failing.allocator(),
        nodes[0],
        .{ .leaf = "different tag" },
    ));
    try std.testing.expectEqual(0, failing.alloc_index);
    try std.testing.expectError(error.OutOfMemory, record.equalAlloc(
        Node,
        failing.allocator(),
        nodes[0],
        nodes[0],
    ));
}

const Mixed = struct {
    flags: [2]bool,
    numbers: []const u64,
    category: enum(u8) { known = 7, _ },
    child: ?union(enum) { done, rows: []const Mixed },
};

test "recursive record mixed arrays enums options and void preserve observations" {
    const value: Mixed = .{
        .flags = .{ true, false },
        .numbers = &.{ 0, 127, 128 },
        .category = .known,
        .child = .done,
    };
    const expected = [_]u8{ 1, 0, 3, 0, 127, 128, 1, 7, 1, 0 };
    var bytes: [expected.len]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.writeAlloc(Mixed, std.testing.allocator, value, &writer);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = &bytes };
    const decoded = try record.read(Mixed, &reader, arena.allocator());
    try std.testing.expect(try record.equalAlloc(Mixed, std.testing.allocator, value, decoded));
    var different = value;
    different.flags[1] = true;
    try std.testing.expect(!try record.equalAlloc(Mixed, std.testing.allocator, value, different));
    different = value;
    different.numbers = &.{ 0, 127 };
    try std.testing.expect(!try record.equalAlloc(Mixed, std.testing.allocator, value, different));
    different = value;
    different.child = null;
    try std.testing.expect(!try record.equalAlloc(Mixed, std.testing.allocator, value, different));
    different.child = .{ .rows = &.{} };
    try std.testing.expect(!try record.equalAlloc(Mixed, std.testing.allocator, value, different));
    bytes[7] = 8;
    reader.position = 0;
    try std.testing.expectError(error.InvalidTag, record.read(Mixed, &reader, arena.allocator()));
}

test "recursive record sizing overflow preserves the numeric sequence boundary" {
    const Recursive = struct { numbers: []const u64, rows: []const @This() };
    const value: Recursive = .{ .numbers = &.{ 128, 128 }, .rows = &.{} };
    var measured: wire.Writer = .{ .position = std.math.maxInt(usize) - 4 };
    try std.testing.expectError(error.InvalidLength, record.writeAlloc(
        Recursive,
        std.testing.allocator,
        value,
        &measured,
    ));
    try std.testing.expectEqual(std.math.maxInt(usize) - 3, measured.position);
}

test "finite allocator entrypoints retain allocation free operations" {
    const Finite = struct { values: []const u64, name: ?[]const u8 };
    const value: Finite = .{ .values = &.{ 128, 256 }, .name = "name" };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var writer: wire.Writer = .{};
    try record.writeAlloc(Finite, failing.allocator(), value, &writer);
    try std.testing.expect(try record.equalAlloc(Finite, failing.allocator(), value, value));
    try std.testing.expect(try record.overlapsAlloc(Finite, failing.allocator(), value, "name"));
    try std.testing.expectEqual(0, failing.alloc_index);
}

test "recursive record delegates packed finite fields without bitfield pointers" {
    const Packed = struct {
        flags: packed struct { a: u4, b: u4 },
        rows: []const @This(),
    };
    const value: Packed = .{
        .flags = .{ .a = 1, .b = 2 },
        .rows = &.{.{ .flags = .{ .a = 3, .b = 4 }, .rows = &.{} }},
    };
    var bytes: [6]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.writeAlloc(Packed, std.testing.allocator, value, &writer);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1, 3, 4, 0 }, &bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = &bytes };
    const decoded = try record.read(Packed, &reader, arena.allocator());
    try reader.finish();
    try std.testing.expect(try record.equalAlloc(Packed, std.testing.allocator, value, decoded));
    try std.testing.expectEqual(@as(u4, 4), decoded.rows[0].flags.b);
    try std.testing.expect(!try record.overlapsAlloc(Packed, std.testing.allocator, value, &bytes));
}

test "recursive record preserves finite sentinel slice observation modes" {
    const Labeled = struct { label: [:0]const u8, rows: []const @This() };
    const label: [2:0]u8 = .{ 'a', 'b' };
    const value: Labeled = .{
        .label = &label,
        .rows = &.{.{ .label = "c", .rows = &.{} }},
    };
    var bytes: [7]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.writeAlloc(Labeled, std.testing.allocator, value, &writer);
    try std.testing.expectEqualSlices(u8, &.{ 2, 'a', 'b', 1, 1, 'c', 0 }, &bytes);
    try std.testing.expect(try record.equalAlloc(Labeled, std.testing.allocator, value, value));
    try std.testing.expect(try record.overlapsAlloc(Labeled, std.testing.allocator, value, &label));
    try std.testing.expect(!try record.overlapsAlloc(
        Labeled,
        std.testing.allocator,
        value,
        label[2..3],
    ));
}

test "recursive record callbacks retain underaligned elements and fields" {
    const Row = struct { value: u64, rows: []align(1) const @This() align(1) };
    var backing: [@sizeOf(Row) + 1]u8 align(@alignOf(Row)) = undefined;
    const child: *align(1) Row = @ptrCast(&backing[1]);
    child.* = .{ .value = 7, .rows = &.{} };
    const value: Row = .{
        .value = 3,
        .rows = @as([*]align(1) const Row, @ptrCast(child))[0..1],
    };
    var bytes: [4]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.writeAlloc(Row, std.testing.allocator, value, &writer);
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 7, 0 }, &bytes);
    try std.testing.expect(try record.equalAlloc(Row, std.testing.allocator, value, value));
    try std.testing.expect(try record.overlapsAlloc(
        Row,
        std.testing.allocator,
        value,
        backing[1..],
    ));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = &bytes };
    const decoded = try record.read(Row, &reader, arena.allocator());
    try reader.finish();
    try std.testing.expect(try record.equalAlloc(Row, std.testing.allocator, value, decoded));
}

test "recursive record callbacks retain volatile recursive elements" {
    const Row = struct { value: u32, rows: []const volatile @This() };
    var children: [1]Row = .{.{ .value = 7, .rows = &.{} }};
    const value: Row = .{ .value = 3, .rows = &children };
    var bytes: [4]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try record.writeAlloc(Row, std.testing.allocator, value, &writer);
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 7, 0 }, &bytes);
    try std.testing.expect(try record.equalAlloc(Row, std.testing.allocator, value, value));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = &bytes };
    const decoded = try record.read(Row, &reader, arena.allocator());
    try reader.finish();
    try std.testing.expect(try record.equalAlloc(Row, std.testing.allocator, value, decoded));
    children[0].value = 8;
    try std.testing.expect(!try record.equalAlloc(Row, std.testing.allocator, value, decoded));
}

test "recursive record equality retains volatile finite byte slice semantics" {
    const Row = struct { label: []const volatile u8, rows: []const @This() };
    var left: [2]u8 = .{ 'a', 'b' };
    var right = left;
    const first: Row = .{ .label = &.{}, .rows = &.{.{ .label = &left, .rows = &.{} }} };
    const second: Row = .{ .label = &.{}, .rows = &.{.{ .label = &right, .rows = &.{} }} };
    try std.testing.expect(try record.equalAlloc(Row, std.testing.allocator, first, second));
    right[1] = 'c';
    try std.testing.expect(!try record.equalAlloc(Row, std.testing.allocator, first, second));
}
