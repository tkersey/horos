const std = @import("std");
const protocol = @import("invocation.zig");
const testing = std.testing;

fn request() !protocol.Request {
    // Independently encoded canonical descriptors: root 0, one u64 / Boolean.
    return protocol.request(.{
        .program_identity = @as([32]u8, @splat(1)),
        .pending_state_digest = @as([32]u8, @splat(2)),
        .effect = 3,
        .semantic_identity = "operation",
        .payload_schema = &.{ 0, 1, 9 },
        .resume_schema = &.{ 0, 1, 1 },
        .payload = &.{ 42, 0, 0, 0, 0, 0, 0, 0 },
    });
}

test "ERQ3 binds nominal effect and exact state and ERS3 owns its decoded bytes" {
    const expected = try request();
    const bytes = try protocol.encodeOwned(protocol.Request, testing.allocator, expected);
    defer testing.allocator.free(bytes);
    var decoded = try protocol.decode(protocol.Request, testing.allocator, bytes);
    defer decoded.deinit();
    @memset(bytes, 0xff);
    try testing.expectEqualDeep(expected, decoded.value);
    var response: protocol.Result = .{
        .request_identity = expected.request_identity,
        .value = &.{1},
    };
    try protocol.validateResult(testing.allocator, expected, response);
    var changed = expected;
    changed.binding.effect += 1;
    changed.request_identity = try protocol.requestIdentity(changed.binding);
    try testing.expectError(
        error.InvalidResult,
        protocol.validateResult(testing.allocator, changed, response),
    );
    changed = expected;
    changed.binding.pending_state_digest[0] ^= 1;
    changed.request_identity = try protocol.requestIdentity(changed.binding);
    try testing.expectError(
        error.InvalidResult,
        protocol.validateResult(testing.allocator, changed, response),
    );
    response.value = &.{2};
    try testing.expectError(
        error.InvalidValue,
        protocol.validateResult(testing.allocator, expected, response),
    );
}

test "current envelope golden tags and owned decode" {
    const value: protocol.Input = .{
        .image = &.{},
        .instance = .{ .initial_args = &.{} },
        .quantum = 0,
    };
    const golden = "ABL_PKI3".* ++ [_]u8{ 3, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 };
    const bytes = try protocol.encodeOwned(protocol.Input, testing.allocator, value);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &golden, bytes);
    var decoded = try protocol.decode(protocol.Input, testing.allocator, &golden);
    defer decoded.deinit();
    try testing.expectEqualDeep(value, decoded.value);
    var changed = golden;
    changed[7] = '2';
    try testing.expectError(
        error.InvalidFamily,
        protocol.decode(protocol.Input, testing.allocator, &changed),
    );
    changed = golden;
    changed[10] = 1;
    try testing.expectError(
        error.InvalidFlags,
        protocol.decode(protocol.Input, testing.allocator, &changed),
    );
}

test "resident progress explicitly omits a portable checkpoint" {
    const value: protocol.Outcome = .{ .progressed = null };
    const golden = "ABL_PKO3".* ++ [_]u8{ 3, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const bytes = try protocol.encodeOwned(protocol.Outcome, testing.allocator, value);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &golden, bytes);
    var decoded = try protocol.decode(protocol.Outcome, testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expect(decoded.value == .progressed and decoded.value.progressed == null);
}

test "current envelopes reject initial replies and malformed outcomes atomically" {
    var output = @as([256]u8, @splat(0xa5));
    const input: protocol.Input = .{
        .image = &.{},
        .instance = .{ .initial_args = &.{} },
        .control = .{ .reply = &.{} },
    };
    try testing.expectError(
        error.InvalidControl,
        protocol.encode(protocol.Input, testing.allocator, input, &output),
    );
    try testing.expectError(
        error.InvalidUtf8,
        protocol.encode(
            protocol.Outcome,
            testing.allocator,
            .{ .cancelled = .{ .reason = .{ .text = &.{0xff} } } },
            &output,
        ),
    );
    try testing.expectError(
        error.InvalidOutcome,
        protocol.encode(
            protocol.Outcome,
            testing.allocator,
            .{ .needs_capacity = .{ .arena = .output, .output = .{ .bytes = 4 } } },
            &output,
        ),
    );
    for (output) |byte| try testing.expectEqual(0xa5, byte);
    const overlapping: protocol.Input = .{
        .image = output[0..3],
        .instance = .{ .initial_args = &.{} },
    };
    try testing.expectError(
        error.InvalidBuffers,
        protocol.encode(protocol.Input, testing.allocator, overlapping, &output),
    );
    for (output) |byte| try testing.expectEqual(0xa5, byte);
}

test "ERQ3 rejects mutations of every bound field before publishing bytes" {
    const expected = try request();
    for (0..7) |field| {
        var changed = expected;
        switch (field) {
            0 => changed.binding.program_identity[0] ^= 1,
            1 => changed.binding.pending_state_digest[0] ^= 1,
            2 => changed.binding.effect += 1,
            3 => changed.binding.semantic_identity = "another-operation",
            4 => changed.binding.payload_schema = &.{ 0, 1, 8 },
            5 => changed.binding.resume_schema = &.{ 0, 1, 9 },
            6 => changed.binding.payload = &.{ 43, 0, 0, 0, 0, 0, 0, 0 },
            else => unreachable,
        }
        var output = @as([256]u8, @splat(0xa5));
        try testing.expectError(
            error.InvalidRequest,
            protocol.encode(protocol.Request, testing.allocator, changed, &output),
        );
        try testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    }
    // Current cancellation is also valid before execution starts.
    const input: protocol.Input = .{
        .image = &.{},
        .instance = .{ .initial_args = &.{} },
        .control = .{ .cancel = .{ .text = "stop" } },
    };
    const bytes = try protocol.encodeOwned(protocol.Input, testing.allocator, input);
    defer testing.allocator.free(bytes);
    var decoded = try protocol.decode(protocol.Input, testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqualDeep(input, decoded.value);
}

fn failure(allocator: std.mem.Allocator) !void {
    const value = try request();
    const bytes = try protocol.encodeOwned(protocol.Request, allocator, value);
    defer allocator.free(bytes);
    var decoded = try protocol.decode(protocol.Request, allocator, bytes);
    defer decoded.deinit();
    try testing.expectEqualDeep(value, decoded.value);
}
test "current request allocation failures release schema and envelope owners" {
    try @import("allocation_testing.zig").check(testing.allocator, failure, .{});
}

fn survivesCallerRelease(comptime T: type, value: T) !void {
    const bytes = try protocol.encodeOwned(T, testing.allocator, value);
    var decoded = protocol.decode(T, testing.allocator, bytes) catch |err| {
        testing.allocator.free(bytes);
        return err;
    };
    defer decoded.deinit();
    @memset(bytes, 0xff);
    testing.allocator.free(bytes);
    try testing.expectEqualDeep(value, decoded.value);
}

test "every envelope family retains byte fields after caller overwrite and release" {
    try survivesCallerRelease(protocol.Input, .{
        .image = "image",
        .instance = .{ .state = "state" },
        .control = .{ .reply = "reply" },
        .quantum = 7,
    });
    try survivesCallerRelease(protocol.Input, .{
        .image = "image",
        .instance = .{ .initial_args = "args" },
        .control = .{ .cancel = .{ .bytes = "reason" } },
    });
    try survivesCallerRelease(protocol.Request, try request());
    try survivesCallerRelease(
        protocol.Result,
        .{ .request_identity = @as([32]u8, @splat(7)), .value = "result" },
    );
    for ([_]protocol.Outcome{
        .{ .progressed = "progress" },
        .{ .requested = .{ .state = "state", .request = "request" } },
        .{ .yielded = "yielded" },
        .{ .completed = "completed" },
        .{ .failed = .{ .value = "failed", .cancellation = .{ .text = "cancel" } } },
        .{ .cancelled = .{ .reason = .{ .bytes = "cancelled" } } },
    }) |outcome| try survivesCallerRelease(protocol.Outcome, outcome);
}

test "large command decode needs only its input extent and releases it" {
    const payload = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(payload);
    @memset(payload, 0x39);
    const bytes = try protocol.encodeOwned(protocol.Input, testing.allocator, .{
        .image = "image",
        .instance = .{ .initial_args = payload },
    });
    defer testing.allocator.free(bytes);
    const backing = try testing.allocator.alloc(u8, bytes.len);
    defer testing.allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    var decoded = try protocol.decode(protocol.Input, fixed.allocator(), bytes);
    @memset(bytes, 0xff);
    try testing.expectEqualStrings("image", decoded.value.image);
    try testing.expectEqualSlices(u8, payload, decoded.value.instance.initial_args);
    decoded.deinit();
    try testing.expectEqual(@as(usize, 0), fixed.end_index);
}
