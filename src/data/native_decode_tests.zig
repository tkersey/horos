//! Public native codec policy coverage. Large cases run sequentially.
const std = @import("std");
const data = @import("root.zig");
const a = std.testing.allocator;

test "native BPI3 BMO1 and invocation decoders admit allocator-backed large values" {
    const count = 65 << 20;
    var measure: data.wire.Writer = .{};
    try measure.natural(count);
    const value = try a.alloc(u8, measure.position + count);
    defer a.free(value);
    var writer: data.wire.Writer = .{ .output = value };
    try writer.natural(count);
    @memset(value[writer.position..], 0x39);
    const program: data.activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .bytes, .unit },
        .constants = &.{.{ .schema = 0, .bytes = value }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{.{ .destination = 0, .opcode = .constant }},
            .terminator = .{ .return_value = 0 },
        }},
    };
    {
        const image = try a.alloc(u8, try data.program_image.encodedLength(program));
        defer a.free(image);
        _ = try data.program_image.encode(a, program, image);
        try std.testing.expect(image.len > 64 << 20);
        var decoded = try data.program_image.decode(a, image);
        defer decoded.deinit();
        try std.testing.expectEqualSlices(u8, value, decoded.program.constants[0].bytes);
        const admitted = try data.program_image.Admitted.decode(a, image);
        defer admitted.deinit();
        try std.testing.expectEqualSlices(u8, value, admitted.program().constants[0].bytes);
        try std.testing.expectError(
            error.Capacity,
            data.program_image.decodeLimited(a, image, .{ .max_decoded_bytes = 64 << 20 }),
        );
    }
    {
        const object: data.component.Object = .{
            .program = program,
            .exports = &.{.{ .name = "main", .reference = .{ .kind = .function, .id = 0 } }},
            .borrows = &.{.{ .function = 0 }},
        };
        const bytes = try a.alloc(u8, try data.component.encodedLength(object));
        defer a.free(bytes);
        _ = try data.component.encode(a, object, bytes);
        var decoded = try data.component.decode(a, bytes);
        defer decoded.deinit();
        try std.testing.expectEqualSlices(u8, value, decoded.object.program.constants[0].bytes);
    }
    const schema = try data.schema.encodeOwned(a, &.{.bytes}, 0);
    defer a.free(schema);
    const request = try data.invocation.request(.{
        .program_identity = @splat(1),
        .pending_state_digest = @splat(2),
        .effect = 0,
        .semantic_identity = "large-result",
        .payload_schema = schema,
        .resume_schema = schema,
        .payload = value,
    });
    try envelope(data.invocation.Request, request);
    const result: data.invocation.Result = .{
        .request_identity = request.request_identity,
        .value = value,
    };
    try data.invocation.validateResult(a, request, result);
    try envelope(data.invocation.Result, result);
    try envelope(data.invocation.Input, .{ .image = &.{}, .instance = .{ .initial_args = value } });
    try envelope(data.invocation.Outcome, .{ .completed = value });
}

fn envelope(comptime T: type, value: T) !void {
    const bytes = try data.invocation.encodeOwned(T, a, value);
    defer a.free(bytes);
    var decoded = try data.invocation.decode(T, a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(value, decoded.value);
    try std.testing.expectError(
        error.Capacity,
        data.invocation.decodeLimited(T, a, bytes, .{ .max_bytes = 64 << 20 }),
    );
}

test "native schema decoding admits records above the former allocation budget" {
    // The compact encoding fits below 64 MiB, but its native tag array makes
    // the charged input-plus-record total exceed the old default.
    const tags = try a.alloc(u32, 9 << 20);
    defer a.free(tags);
    for (tags, 0..) |*tag, i| tag.* = @intCast(i);
    const bytes = try data.schema.encodeOwned(a, &.{.{ .enumeration = tags }}, 0);
    defer a.free(bytes);
    try std.testing.expect(bytes.len < 64 << 20);
    try std.testing.expectError(error.Capacity, data.schema.decodeLimited(a, bytes, 64 << 20));
    var decoded = try data.schema.decode(a, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u32, tags, decoded.descriptor.types[0].enumeration);
}
