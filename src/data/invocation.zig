// Copyright (c) 2026 Boundary contributors. MIT license.
//! Current invocation/external-interaction envelopes. No execution lives here.
const std = @import("std");
const wire = @import("wire.zig");
const record = @import("record.zig");
const schema = @import("schema.zig");
pub const Error = schema.Error || error{
    InvalidRequest,
    InvalidResult,
    InvalidControl,
    InvalidOutcome,
};
pub const ReasonTag = enum(u8) { text = 0, bytes = 1 };
pub const Reason = union(ReasonTag) { text: []const u8, bytes: []const u8 };
pub const InstanceTag = enum(u8) { initial_args = 0, state = 1 };
pub const Instance = union(InstanceTag) { initial_args: []const u8, state: []const u8 };
pub const ControlTag = enum(u8) { none = 0, reply = 1, resume_yield = 2, cancel = 3 };
pub const Control = union(ControlTag) {
    none,
    reply: []const u8,
    resume_yield,
    cancel: Reason,
};
pub const Input = struct {
    image: []const u8,
    instance: Instance,
    control: Control = .none,
    /// Null runs to a public boundary. Zero applies explicit control, then polls.
    quantum: ?u64 = null,
};
pub const Bound = struct {
    bytes: u64 = 0,
    provenance: enum(u8) { not_observed = 0, exact = 1, lower_bound = 2 } = .not_observed,
};
pub const Capacity = struct {
    arena: enum(u8) { input = 0, working = 1, output = 2, memory = 3 },
    input: Bound = .{},
    working: Bound = .{},
    output: Bound = .{},
    memory_pages: Bound = .{},
};
pub const Outcome = union(enum(u8)) {
    progressed: ?[]const u8,
    requested: struct { state: ?[]const u8, request: []const u8 },
    yielded: ?[]const u8,
    completed: []const u8,
    failed: struct {
        value: []const u8,
        cleanup_failures: []const u8 = &.{0},
        cancellation: ?Reason = null,
    },
    cancelled: struct { reason: Reason, cleanup_failures: []const u8 = &.{0} },
    needs_capacity: Capacity,
};
pub const Binding = struct {
    program_identity: [32]u8,
    pending_state_digest: [32]u8,
    effect: u64,
    semantic_identity: []const u8,
    payload_schema: []const u8,
    resume_schema: []const u8,
    payload: []const u8,
};
pub const Request = struct { binding: Binding, request_identity: [32]u8 };
pub const Result = struct { request_identity: [32]u8, value: []const u8 };
pub const Limits = struct { max_bytes: usize = std.math.maxInt(usize) };

fn magic(comptime T: type) *const [8]u8 {
    return if (T == Input)
        "ABL_PKI3"
    else if (T == Outcome)
        "ABL_PKO3"
    else if (T == Request)
        "ABL_ERQ3"
    else if (T == Result)
        "ABL_ERS3"
    else
        @compileError("not an invocation record");
}
pub fn encodedLength(comptime T: type, value: T) Error!usize {
    var writer: wire.Writer = .{ .position = wire.header_length };
    try record.write(T, value, &writer);
    return writer.position;
}
pub fn encode(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: T,
    output: []u8,
) Error![]const u8 {
    try validate(T, allocator, value);
    const length = try encodedLength(T, value);
    if (output.len < length) return error.Capacity;
    if (record.overlaps(T, value, output[0..length])) return error.InvalidBuffers;
    var writer: wire.Writer = .{ .output = output[0..length] };
    try writer.put(magic(T));
    try writer.fixed(u16, 3);
    try writer.fixed(u16, 0);
    try writer.fixed(u64, length - wire.header_length);
    try record.write(T, value, &writer);
    return output[0..length];
}
pub fn encodeOwned(comptime T: type, allocator: std.mem.Allocator, value: T) Error![]u8 {
    const bytes = try allocator.alloc(u8, try encodedLength(T, value));
    errdefer allocator.free(bytes);
    _ = try encode(T, allocator, value, bytes);
    return bytes;
}
pub fn Owned(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        value: T,
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.bytes);
            self.* = undefined;
        }
    };
}
pub fn decode(comptime T: type, allocator: std.mem.Allocator, input: []const u8) Error!Owned(T) {
    return decodeLimited(T, allocator, input, .{});
}
pub fn decodeLimited(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!Owned(T) {
    if (input.len < wire.header_length) return error.Truncated;
    if (input.len > limits.max_bytes) return error.Capacity;
    const bytes = try allocator.dupe(u8, input);
    errdefer allocator.free(bytes);
    var reader: wire.Reader = .{ .input = bytes };
    if (!std.mem.eql(u8, try reader.take(8), magic(T))) return error.InvalidFamily;
    if (try reader.fixed(u16) != 3) return error.UnsupportedVersion;
    if (try reader.fixed(u16) != 0) return error.InvalidFlags;
    if (try reader.fixed(u64) != bytes.len - wire.header_length) return error.InvalidLength;
    // Envelope fields are byte slices and fixed records; decoding them allocates
    // no nested record arrays. Their only backing is the owned input above.
    var remaining: usize = 0;
    const value = try record.readBounded(T, &reader, allocator, &remaining);
    try reader.finish();
    try validate(T, allocator, value);
    return .{ .allocator = allocator, .bytes = bytes, .value = value };
}

/// Seed the same domain for byte-backed and streaming canonical PST3 hashing.
pub fn stateDigestHasher() std.crypto.hash.sha2.Sha256 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("boundary.pending-state/v3\x00");
    return hash;
}
pub fn stateDigest(canonical_state: []const u8) [32]u8 {
    var hash = stateDigestHasher();
    hash.update(canonical_state);
    return hash.finalResult();
}
pub fn requestIdentity(binding: Binding) Error![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("boundary.effect-request/v3\x00");
    var writer: wire.Writer = .{ .hasher = &hash };
    try record.write(Binding, binding, &writer);
    return hash.finalResult();
}
pub fn request(binding: Binding) Error!Request {
    return .{ .binding = binding, .request_identity = try requestIdentity(binding) };
}
fn reason(value: Reason) Error!void {
    if (value == .text and !std.unicode.utf8ValidateSlice(value.text)) return error.InvalidUtf8;
}
pub fn validate(comptime T: type, allocator: std.mem.Allocator, value: T) Error!void {
    if (T == Input) {
        if (value.instance == .initial_args and
            (value.control == .reply or
                value.control == .resume_yield))
            return error.InvalidControl;
        if (value.control == .cancel) try reason(value.control.cancel);
    } else if (T == Request) {
        const binding = value.binding;
        if (binding.semantic_identity.len == 0 or !std.unicode.utf8ValidateSlice(
            binding.semantic_identity,
        )) return error.InvalidRequest;
        if (!std.mem.eql(
            u8,
            &value.request_identity,
            &try requestIdentity(binding),
        )) return error.InvalidRequest;
        var payload = try schema.decode(allocator, binding.payload_schema);
        defer payload.deinit();
        var resumed = try schema.decode(allocator, binding.resume_schema);
        defer resumed.deinit();
        try schema.validateValue(allocator, payload.descriptor, binding.payload);
    } else if (T == Outcome) {
        const failures = switch (value) {
            .failed => |failure| blk: {
                if (failure.cancellation) |why| try reason(why);
                break :blk failure.cleanup_failures;
            },
            .cancelled => |cancelled| blk: {
                try reason(cancelled.reason);
                break :blk cancelled.cleanup_failures;
            },
            .needs_capacity => |capacity| {
                for ([_]Bound{
                    capacity.input,
                    capacity.working,
                    capacity.output,
                    capacity.memory_pages,
                }) |bound|
                    if (bound.provenance == .not_observed and
                        bound.bytes != 0)
                        return error.InvalidOutcome;
                return;
            },
            else => return,
        };
        var reader: wire.Reader = .{ .input = failures };
        const count = try reader.count();
        if (count > failures.len - reader.position) return error.Truncated;
        for (0..count) |_| _ = try reader.bytes();
        try reader.finish();
    } else if (T != Result) @compileError("not an invocation record");
}

/// The runtime must reconstruct the Request from its own admitted pending State.
/// A caller's self-consistent Request is not proof of that State binding.
pub fn validateResult(allocator: std.mem.Allocator, expected: Request, result: Result) Error!void {
    try validate(Request, allocator, expected);
    if (!std.mem.eql(
        u8,
        &result.request_identity,
        &expected.request_identity,
    )) return error.InvalidResult;
    var descriptor = try schema.decode(allocator, expected.binding.resume_schema);
    defer descriptor.deinit();
    try schema.validateValue(allocator, descriptor.descriptor, result.value);
}
