const std = @import("std");
const g = @import("graph.zig");
const s = @import("process_state.zig");
const codec = @import("state_image.zig");
const testing = std.testing;

test "canonical state serialization shares bytes with digest-only and combined output" {
    const protocol = @import("invocation.zig");
    const bytes = try codec.emit(testing.allocator, fixture);
    defer testing.allocator.free(bytes);
    const expected = protocol.stateDigest(bytes);
    var digest_only = protocol.stateDigestHasher();
    const streamed = try codec.serialize(testing.allocator, fixture, .none, &digest_only);
    try testing.expect(streamed.bytes == null);
    try testing.expectEqual(bytes.len, streamed.length);
    try testing.expectEqualSlices(u8, &expected, &digest_only.finalResult());
    var combined = protocol.stateDigestHasher();
    const emitted = try codec.serialize(
        testing.allocator,
        fixture,
        .{ .allocate = testing.allocator },
        &combined,
    );
    defer testing.allocator.free(emitted.bytes.?);
    try testing.expectEqualSlices(u8, bytes, emitted.bytes.?);
    try testing.expectEqualSlices(u8, &expected, &combined.finalResult());
    var buffer: [1024]u8 = undefined;
    var buffered = protocol.stateDigestHasher();
    const written = try codec.serialize(
        testing.allocator,
        fixture,
        .{ .buffer = &buffer },
        &buffered,
    );
    try testing.expectEqualSlices(u8, bytes, written.bytes.?);
    try testing.expectEqualSlices(u8, &expected, &buffered.finalResult());
    var failed = protocol.stateDigestHasher();
    const before = failed;
    try testing.expectError(
        error.Capacity,
        codec.serialize(testing.allocator, fixture, .{ .buffer = buffer[0..1] }, &failed),
    );
    try testing.expectEqualDeep(before, failed);
}

test "PST3 rejects an encoded unreachable node instead of dropping it" {
    const state: s.State = .{
        .program_identity = @splat(0),
        .status = .active,
        .roots = .{},
        .nodes = &.{.{ .record = .{ .environment = .{ .values = &.{}, .tail = null } } }},
    };
    const record = @import("record.zig");
    const wire = @import("wire.zig");
    var measure: wire.Writer = .{};
    try record.write(s.State, state, &measure);
    var bytes: [256]u8 = undefined;
    var writer: wire.Writer = .{ .output = &bytes };
    try writer.put("ABL_PST3");
    try writer.fixed(u16, 3);
    try writer.fixed(u16, 0);
    try writer.fixed(u64, measure.position);
    try record.write(s.State, state, &writer);
    try testing.expectError(
        error.NonCanonical,
        codec.decodeGraph(testing.allocator, bytes[0..writer.position]),
    );
}

test "PST3 capacity accounts for canonical reference widths before output mutation" {
    var nodes: [130]s.Node = undefined;
    for (&nodes) |*node| node.* = .{ .record = .{ .environment = .{
        .values = &.{},
        .tail = null,
    } } };
    var aliases: [100]g.Value = undefined;
    @memset(&aliases, ref(0));
    nodes[nodes.len - 1].record.environment.values = &aliases;
    var roots: [nodes.len - 1]g.OwnedRef = undefined;
    for (&roots, 1..) |*root, id| root.* = .{ .node = .{ .id = id } };
    const state: s.State = .{
        .program_identity = @splat(0),
        .status = .active,
        .roots = .{ .detached = &roots },
        .nodes = &nodes,
    };
    const bytes = try codec.emit(testing.allocator, state);
    defer testing.allocator.free(bytes);
    // 982 predecessor graph bytes plus one activation-option tag per node.
    try testing.expectEqual(1112, bytes.len);
    var output = @as([1112]u8, @splat(0xaa));
    try testing.expectError(
        error.Capacity,
        codec.encode(testing.allocator, state, output[0 .. output.len - 1]),
    );
    try testing.expect(std.mem.allEqual(u8, &output, 0xaa));
    try testing.expectEqualSlices(u8, bytes, try codec.encode(testing.allocator, state, &output));
    var decoded = try codec.decodeGraph(testing.allocator, bytes);
    defer decoded.deinit();
    const again = try codec.emit(testing.allocator, decoded.state);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

fn ref(id: u64) g.Value {
    return .{ .schema = 0, .body = .{ .reference = .{ .id = id } } };
}
const fixture: s.State = .{
    .program_identity = @as([32]u8, @splat(7)),
    .status = .active,
    .roots = .{ .current = .{ .id = 1 } },
    .nodes = &.{
        .{ .record = .{ .region = .{ .descriptor = 0, .outer = null, .obligations = &.{} } } },
        .{ .record = .{ .control = .{ .block = 0 } }, .activation = .{
            .position = 3,
            .scope = 0,
            .bindings = &.{.{ .slot = 8, .value = ref(2) }},
            .owners = &.{},
        } },
        .{ .record = .{ .cell = .{ .schema = 0, .region = .{ .id = 0 }, .value = ref(2) } } },
        .{ .record = .{ .environment = .{ .values = &.{}, .tail = null } } }, // dead
    },
};

test "PST3 control records encode only position and context references" {
    const record = @import("record.zig");
    const wire = @import("wire.zig");
    var output: [16]u8 = undefined;
    var writer: wire.Writer = .{ .output = &output };
    try record.write(g.Control, .{
        .block = 300,
        .parent = .{ .id = 2 },
        .region = .{ .id = 4 },
    }, &writer);
    // Minimal block varint, present parent, absent evidence, present region.
    try testing.expectEqualSlices(u8, &.{ 0xac, 0x02, 1, 2, 0, 1, 4 }, output[0..writer.position]);
    writer.position = 0;
    try record.write(g.Continuation, .{
        .source_block = 7,
        .parent = .{ .id = 2 },
        .region = .{ .id = 4 },
    }, &writer);
    try testing.expectEqualSlices(u8, &.{ 7, 1, 2, 0, 1, 4 }, output[0..writer.position]);
}

test "PST3 visits frame values and cycles but excludes unreachable nodes" {
    const bytes = try codec.emit(testing.allocator, fixture);
    defer testing.allocator.free(bytes);
    var decoded = try codec.decodeGraph(testing.allocator, bytes);
    defer decoded.deinit();
    @memset(bytes, 0xa5);
    try testing.expectEqual(3, decoded.state.nodes.len);
    const frame = decoded.state.nodes[0].activation.?;
    try testing.expectEqual(3, frame.position);
    try testing.expectEqual(8, frame.bindings[0].slot);
    try testing.expectEqual(1, frame.bindings[0].value.body.reference.id);
    try testing.expectEqual(1, decoded.state.nodes[1].record.cell.value.?.body.reference.id);
    try testing.expectEqual(2, decoded.state.nodes[1].record.cell.region.id);
}

test "PST3 is independent of physical node order and unused prefix" {
    const nodes = [_]s.Node{
        fixture.nodes[3],
        .{ .record = .{ .cell = .{ .schema = 0, .region = .{ .id = 2 }, .value = ref(1) } } },
        fixture.nodes[0],
        .{ .record = .{ .control = .{ .block = 0 } }, .activation = .{
            .position = 3,
            .scope = 0,
            .bindings = &.{.{ .slot = 8, .value = ref(1) }},
            .owners = &.{},
        } },
    };
    var permuted = fixture;
    permuted.nodes = &nodes;
    permuted.roots.current = .{ .id = 3 };
    const left = try codec.emit(testing.allocator, fixture);
    defer testing.allocator.free(left);
    const right = try codec.emit(testing.allocator, permuted);
    defer testing.allocator.free(right);
    try testing.expectEqualSlices(u8, left, right);
}

test "PST3 graph shape rejects missing frames and forged owner lists atomically" {
    var nodes = fixture.nodes[0..3].*;
    var state = fixture;
    state.nodes = &nodes;
    nodes[1].activation = null;
    var output = @as([1024]u8, @splat(0xa5));
    try testing.expectError(error.InvalidState, codec.encode(testing.allocator, state, &output));
    for (output) |byte| try testing.expectEqual(0xa5, byte);
    nodes[1] = fixture.nodes[1];
    nodes[1].activation.?.owners = &.{.{ .scope = 0, .slot = 8 }};
    try testing.expectError(error.InvalidState, codec.encode(testing.allocator, state, &output));
    for (output) |byte| try testing.expectEqual(0xa5, byte);
    try testing.expectError(error.Capacity, codec.encode(testing.allocator, fixture, output[0..1]));
    for (output) |byte| try testing.expectEqual(0xa5, byte);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const bytes = try codec.emit(allocator, fixture);
    defer allocator.free(bytes);
    var decoded = try codec.decodeGraph(allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqual(3, decoded.state.nodes.len);
}
test "PST3 allocation failures release partial graph owners" {
    try @import("allocation_testing.zig").check(testing.allocator, allocationFailure, .{});
}

test "borrowed PST3 inspection retains input bytes without allocating the payload" {
    const payload: [8192]u8 = @splat(0x5a);
    const state: s.State = .{
        .program_identity = @splat(9),
        .status = .active,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &.{.{
            .record = .{ .control = .{ .block = 0 } },
            .activation = .{
                .position = 0,
                .scope = 0,
                .bindings = &.{.{
                    .slot = 0,
                    .value = .{ .schema = 0, .body = .{ .blob = .{ .id = 0 } } },
                }},
                .owners = &.{},
            },
        }},
        .blobs = &.{.{ .schema = 0, .bytes = &payload }},
    };
    const bytes = try codec.emit(testing.allocator, state);
    defer testing.allocator.free(bytes);
    var storage: [4096]u8 = undefined;
    var buffer = std.heap.FixedBufferAllocator.init(&storage);
    var decoded = try codec.decodeGraphBorrowed(buffer.allocator(), bytes, .{});
    defer decoded.deinit();
    try testing.expectEqualSlices(u8, &payload, decoded.state.blobs[0].bytes);
    const start = @intFromPtr(bytes.ptr);
    const blob = @intFromPtr(decoded.state.blobs[0].bytes.ptr);
    try testing.expect(blob >= start and blob + payload.len <= start + bytes.len);
    try testing.expectEqualSlices(u8, bytes, decoded.input);
}

test "PST3 framing and decoded allocation budget reject malformed input" {
    const bytes = try codec.emit(testing.allocator, fixture);
    defer testing.allocator.free(bytes);
    for (0..bytes.len) |length| {
        if (codec.decodeGraph(testing.allocator, bytes[0..length])) |result| {
            var owner = result;
            owner.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
        if (codec.decodeGraphBorrowed(testing.allocator, bytes[0..length], .{})) |result| {
            var owner = result;
            owner.deinit();
            return error.AcceptedTruncatedState;
        } else |_| {}
    }
    try testing.expectError(
        error.Capacity,
        codec.decodeGraphLimited(testing.allocator, bytes, .{ .max_decoded_bytes = bytes.len }),
    );
    for ([_][]const u8{ "ABL_PST1", "ABL_PST2", "ABL_BPI1", "ABL_BPI2", "ABL_BPC1" }) |family| {
        @memcpy(bytes[0..8], family);
        try testing.expectError(error.InvalidFamily, codec.decodeGraph(testing.allocator, bytes));
    }
    @memcpy(bytes[0..8], "ABL_PST3");
    bytes[10] = 1;
    try testing.expectError(error.InvalidFlags, codec.decodeGraph(testing.allocator, bytes));
}

test "PST3 terminal unit golden is independently specified" {
    const state: s.State = .{
        .program_identity = @as([32]u8, @splat(0)),
        .status = .completed,
        .roots = .{ .exit = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .exit = .{ .reason = .{ .normal = .{
            .schema = 0,
            .body = .{ .scalar = @as([8]u8, @splat(0)) },
        } } } } }},
    };
    const golden = "ABL_PST3".* ++ [_]u8{ 3, 0, 0, 0, 59, 0, 0, 0, 0, 0, 0, 0 } ++
        @as([32]u8, @splat(0)) ++ // Program identity
        [_]u8{ 4, 0, 0, 0, 1, 0, 0 } ++ // status and roots
        [_]u8{ 1, 23, 0, 0, 0 } ++ // node count, exit, normal, schema, scalar
        @as([8]u8, @splat(0)) ++ // scalar padding
        [_]u8{ 0, 0, 0, 0, 0, 0, 0 }; // exit fields, absent activation, blobs
    const bytes = try codec.emit(testing.allocator, state);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &golden, bytes);
    var decoded = try codec.decodeGraph(testing.allocator, &golden);
    defer decoded.deinit();
    try testing.expectEqualDeep(state, decoded.state);
}

test "PST3 keeps equal node identities distinct while interning immutable blobs" {
    var nodes = fixture.nodes[0..3].*;
    nodes[1].activation.?.bindings = &.{
        .{ .slot = 0, .value = ref(0) },
        .{ .slot = 1, .value = ref(2) },
    };
    nodes[0].record = .{ .environment = .{
        .values = &.{.{ .schema = 0, .body = .{ .blob = .{ .id = 0 } } }},
        .tail = null,
    } };
    nodes[2].record = .{ .environment = .{
        .values = &.{.{ .schema = 0, .body = .{ .blob = .{ .id = 1 } } }},
        .tail = null,
    } };
    var state = fixture;
    state.nodes = &nodes;
    state.blobs = &.{ .{ .schema = 0, .bytes = "payload" }, .{ .schema = 0, .bytes = "payload" } };
    const bytes = try codec.emit(testing.allocator, state);
    defer testing.allocator.free(bytes);
    var decoded = try codec.decodeGraph(testing.allocator, bytes);
    defer decoded.deinit();
    @memset(bytes, 0xff);
    try testing.expectEqual(3, decoded.state.nodes.len);
    try testing.expectEqual(1, decoded.state.blobs.len);
    try testing.expectEqualStrings("payload", decoded.state.blobs[0].bytes);
    const bindings = decoded.state.nodes[0].activation.?.bindings;
    try testing.expect(bindings[0].value.body.reference.id != bindings[1].value.body.reference.id);
}
