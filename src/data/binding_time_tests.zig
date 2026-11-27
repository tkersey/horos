const std = @import("std");
const image = @import("program_image.zig");
const binding_time = @import("binding_time.zig");
const ir = @import("activation.zig");
const state_admission = @import("state_admission.zig");
const compilation = @import("closed_compilation.zig");
const witness = @import("coalescing_witness.zig");
const relocation_missing = @import("relocation.zig").missing;
const testing = std.testing;
const Hint = binding_time.Hint;

const example: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }},
    .effects = &.{},
    .functions = &.{.{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 }},
    .blocks = &.{.{
        .function = 0,
        .instructions = &.{.{ .destination = 0, .opcode = .constant }},
        .terminator = .{ .return_value = 0 },
    }},
};

const golden = "ABL_BPI3".* ++ [_]u8{
    3, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0,
    1, 0, 0, 1, 2,  9, 0, 1, 0, 8, 1, 42,
    0, 1, 0, 0, 0,  1, 0, 0, 1, 0, 1, 0,
    0, 0, 0, 0, 0,  0, 0, 0,
};

const hinted_golden = "ABL_BPI3".* ++ [_]u8{
    3, 0, 0, 0, 36, 0, 0, 0, 0, 0, 0, 0,
    1, 0, 0, 1, 2,  9, 0, 1, 0, 8, 1, 42,
    0, 1, 0, 0, 0,  1, 0, 0, 1, 0, 1, 0,
    0, 0, 0, 0, 0,  0, 0, 0, 1, 0, 0, 1,
};

const residual_result = [_]Hint{.{ .function = 0, .slot = 0, .kind = .residual }};
const hinted_example: image.Image = .{ .program = example, .hints = &residual_result };

const pair: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{},
        .layout = .{ .slots = &.{ 0, 0 } },
        .result = 0,
    }},
    .blocks = &.{.{
        .function = 0,
        .instructions = &.{
            .{ .destination = 0, .opcode = .constant },
            .{ .destination = 1, .opcode = .move, .operands = &.{0} },
        },
        .terminator = .{ .return_value = 1 },
    }},
};

fn imageIdentity(bytes: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(image.identity_domain);
    hash.update(bytes);
    return hash.finalResult();
}

test "a program without hints keeps the exact pre-hint encoding and identity" {
    var output: [256]u8 = undefined;
    const plain = try image.encode(testing.allocator, .unhinted(example), &output);
    try testing.expectEqualSlices(u8, &golden, plain);
    try testing.expectEqual(golden.len, try image.encodedLength(.unhinted(example)));
    try testing.expectEqual(
        imageIdentity(&golden),
        try image.identity(testing.allocator, .unhinted(example)),
    );
    var decoded = try image.decode(testing.allocator, &golden);
    defer decoded.deinit();
    try testing.expectEqual(0, decoded.hints.len);
}

test "binding-time hints are recorded beside unchanged executable records" {
    var output: [256]u8 = undefined;
    const encoded = try image.encode(testing.allocator, hinted_example, &output);
    try testing.expectEqualSlices(u8, &hinted_golden, encoded);
    var bytes = hinted_golden;
    var decoded = try image.decode(testing.allocator, &bytes);
    defer decoded.deinit();
    @memset(&bytes, 0xff);
    try testing.expectEqualDeep(example, decoded.program);
    try testing.expectEqualSlices(Hint, &residual_result, decoded.hints);
    try testing.expectEqualSlices(
        u8,
        &golden,
        try image.encode(testing.allocator, .unhinted(decoded.program), &output),
    );
    const hinted = try image.identity(testing.allocator, hinted_example);
    try testing.expectEqual(imageIdentity(&hinted_golden), hinted);
    try testing.expectEqual(hinted, decoded.identity);
    try testing.expectEqual(imageIdentity(&golden), try image.identity(
        testing.allocator,
        .unhinted(example),
    ));
    const admitted = try image.Admitted.decode(testing.allocator, &hinted_golden);
    defer admitted.deinit();
    try testing.expectEqualSlices(Hint, &residual_result, admitted.image().hints);
    try testing.expectEqual(hinted, admitted.identity());
}

fn expectRejected(expected: anyerror, bytes: []const u8) !void {
    try testing.expectError(expected, image.decode(testing.allocator, bytes));
    try testing.expectError(expected, image.Admitted.decode(testing.allocator, bytes));
}

fn framed(comptime body: []const u8) [body.len + 20]u8 {
    var result: [body.len + 20]u8 = undefined;
    @memcpy(result[0..8], "ABL_BPI3");
    std.mem.writeInt(u16, result[8..10], 3, .little);
    std.mem.writeInt(u16, result[10..12], 0, .little);
    std.mem.writeInt(u64, result[12..20], body.len, .little);
    @memcpy(result[20..], body);
    return result;
}

test "forged hint tables reject unknown kinds and missing bindings" {
    const body = golden[20..];
    try expectRejected(error.InvalidTag, &framed(body ++ [_]u8{ 1, 0, 0, 2 }));
    try expectRejected(error.InvalidTag, &framed(body ++ [_]u8{ 1, 0, 0, 2, 0 }));
    try expectRejected(error.InvalidReference, &framed(body ++ [_]u8{ 1, 1, 0, 0 }));
    try expectRejected(error.InvalidReference, &framed(body ++ [_]u8{ 1, 0, 1, 0 }));
    try expectRejected(error.NonCanonical, &framed(body ++ [_]u8{0}));
    try expectRejected(error.NonCanonical, &framed(body ++ [_]u8{ 1, 0, 0, 0, 0 }));
    try expectRejected(error.NonCanonical, &framed(body ++ [_]u8{ 1, 0x80, 0, 0, 1 }));
    try expectRejected(error.Truncated, &framed(body ++ [_]u8{ 1, 0, 0 }));
    try expectRejected(error.Truncated, &framed(body ++ [_]u8{ 2, 0, 0, 1 }));
    var flagged = hinted_golden;
    flagged[10] = 1;
    try expectRejected(error.InvalidFlags, &flagged);
}

test "forged hint tables reject repeated and unordered bindings" {
    var output: [256]u8 = undefined;
    const plain = try image.encode(testing.allocator, .unhinted(pair), &output);
    var storage: [256]u8 = undefined;
    for ([_][]const u8{
        &.{ 2, 0, 0, 0, 0, 0, 1 },
        &.{ 2, 0, 0, 0, 0, 0, 0 },
        &.{ 2, 0, 1, 0, 0, 0, 0 },
    }) |table| {
        const length = plain.len + table.len;
        @memcpy(storage[0..plain.len], plain);
        @memcpy(storage[plain.len..length], table);
        std.mem.writeInt(u64, storage[12..20], length - 20, .little);
        try expectRejected(error.NonCanonical, storage[0..length]);
    }
    const ordered = [_]Hint{
        .{ .function = 0, .slot = 0, .kind = .context },
        .{ .function = 0, .slot = 1, .kind = .residual },
    };
    const encoded = try image.encode(
        testing.allocator,
        .{ .program = pair, .hints = &ordered },
        &storage,
    );
    var decoded = try image.decode(testing.allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqualSlices(Hint, &ordered, decoded.hints);
}

test "encoding rejects invalid in-memory hint tables before writing output" {
    var output = @as([256]u8, @splat(0xa5));
    const unordered = [_]Hint{
        .{ .function = 0, .slot = 1, .kind = .context },
        .{ .function = 0, .slot = 0, .kind = .context },
    };
    const repeated = [_]Hint{
        .{ .function = 0, .slot = 1, .kind = .context },
        .{ .function = 0, .slot = 1, .kind = .residual },
    };
    const missing = [_]Hint{.{ .function = 0, .slot = 2, .kind = .context }};
    const absent = [_]Hint{.{ .function = 1, .slot = 0, .kind = .context }};
    inline for (.{
        .{ error.NonCanonical, &unordered },
        .{ error.NonCanonical, &repeated },
        .{ error.InvalidReference, &missing },
        .{ error.InvalidReference, &absent },
    }) |case| {
        const forged: image.Image = .{ .program = pair, .hints = case[1] };
        try testing.expectError(case[0], image.encode(testing.allocator, forged, &output));
        try testing.expectError(case[0], image.identity(testing.allocator, forged));
    }
    try testing.expectEqualSlices(u8, &(@as([256]u8, @splat(0xa5))), &output);
}

test "normalization orders bindings and joins conflicting kinds to residual" {
    var hints = [_]Hint{
        .{ .function = 1, .slot = 0, .kind = .context },
        .{ .function = 0, .slot = 2, .kind = .context },
        .{ .function = 0, .slot = 2, .kind = .residual },
        .{ .function = 0, .slot = 1, .kind = .context },
        .{ .function = 1, .slot = 0, .kind = .context },
    };
    try testing.expectEqualSlices(Hint, &.{
        .{ .function = 0, .slot = 1, .kind = .context },
        .{ .function = 0, .slot = 2, .kind = .residual },
        .{ .function = 1, .slot = 0, .kind = .context },
    }, binding_time.normalize(&hints));
    try testing.expectEqual(binding_time.Kind.context, binding_time.Kind.context.join(.context));
    try testing.expectEqual(binding_time.Kind.residual, binding_time.Kind.context.join(.residual));
    try testing.expectEqual(binding_time.Kind.residual, binding_time.Kind.residual.join(.context));
}

fn hintedAllocation(allocator: std.mem.Allocator) !void {
    var decoded = try image.decode(allocator, &hinted_golden);
    defer decoded.deinit();
    try testing.expectEqualSlices(Hint, &residual_result, decoded.hints);
    const admitted = try image.Admitted.decode(allocator, &hinted_golden);
    defer admitted.deinit();
    try testing.expectEqualSlices(Hint, &residual_result, admitted.image().hints);
}

test "hinted image decoding releases every owner on allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, hintedAllocation, .{});
}

test "the decoding budget charges the hint table" {
    var plain = try image.decode(testing.allocator, &golden);
    defer plain.deinit();
    var hinted = try image.decode(testing.allocator, &hinted_golden);
    defer hinted.deinit();
    const table_bytes = hinted_golden.len - golden.len;
    try testing.expectEqual(
        plain.decoded_bytes + table_bytes + @sizeOf(Hint),
        hinted.decoded_bytes,
    );
    try testing.expectError(
        error.Capacity,
        image.decodeLimited(testing.allocator, &hinted_golden, .{
            .max_decoded_bytes = hinted.decoded_bytes - 1,
        }),
    );
    var exact = try image.decodeLimited(testing.allocator, &hinted_golden, .{
        .max_decoded_bytes = hinted.decoded_bytes,
    });
    exact.deinit();
}

fn hintedState(identity: [32]u8) @import("process_state.zig").State {
    return .{
        .program_identity = identity,
        .status = .active,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .control = .{ .block = 0 } }, .activation = .{
            .position = 1,
            .scope = 0,
            .owners = &.{},
            .bindings = &.{.{
                .slot = 0,
                .value = .{ .schema = 0, .body = .{ .scalar = .{ 42, 0, 0, 0, 0, 0, 0, 0 } } },
            }},
        } }},
    };
}

test "a hinted program has one identity across every identity function" {
    var decoded = try image.decode(testing.allocator, &hinted_golden);
    defer decoded.deinit();
    const admitted = try image.Admitted.decode(testing.allocator, &hinted_golden);
    defer admitted.deinit();
    try testing.expectEqual(decoded.identity, admitted.identity());
    try testing.expectEqual(
        decoded.identity,
        try image.identity(testing.allocator, decoded.image()),
    );
    try testing.expectEqual(
        decoded.identity,
        try image.identity(testing.allocator, admitted.image()),
    );
    var verified = try image.identityWithFlow(testing.allocator, decoded.image(), null);
    defer verified.deinit();
    try testing.expectEqual(decoded.identity, verified.identity);
}

test "stable and admitted state validation agree for a hinted program" {
    const admitted = try image.Admitted.decode(testing.allocator, &hinted_golden);
    defer admitted.deinit();
    const state = hintedState(admitted.identity());
    try state_admission.validateAdmitted(testing.allocator, admitted, state);
    try state_admission.validateStable(testing.allocator, admitted.image(), state);
    const erased = hintedState(try image.identity(
        testing.allocator,
        .unhinted(admitted.program()),
    ));
    try testing.expectError(
        error.InvalidState,
        state_admission.validateAdmitted(testing.allocator, admitted, erased),
    );
    try testing.expectError(
        error.InvalidState,
        state_admission.validateStable(testing.allocator, admitted.image(), erased),
    );
}

test "closed compilation bounds the emitted hinted image" {
    const length = try image.encodedLength(hinted_example);
    try testing.expectError(error.Capacity, compilation.run(
        testing.allocator,
        hinted_example,
        .{ .max_image_bytes = length - 1 },
    ));
    var stats: compilation.Statistics = .{};
    var result = try compilation.run(
        testing.allocator,
        hinted_example,
        .{ .max_image_bytes = length, .statistics = &stats },
    );
    defer result.deinit();
    try testing.expectEqualSlices(Hint, &residual_result, result.hints);
    try testing.expectEqual(length, stats.original_bytes);
    try testing.expectEqual(length, stats.final_bytes);
    try testing.expectError(error.InvalidCorrespondence, compilation.run(
        testing.allocator,
        hinted_example,
        .{ .contract = .semantic },
    ));
}

fn expectRelocated(
    expected: anyerror![]const Hint,
    hints: []const Hint,
    functions: []const u64,
) !void {
    const unary: witness.Local = .{ .slots = &.{0}, .custody = &.{} };
    const locals = [_]witness.Local{ unary, unary };
    const actual = binding_time.relocate(
        testing.allocator,
        testing.allocator,
        hints,
        example,
        functions,
        &locals,
    );
    const wanted = expected catch |err| return testing.expectError(err, actual);
    const relocated = try actual;
    defer testing.allocator.free(relocated);
    try testing.expectEqualSlices(Hint, wanted, relocated);
}

test "relocation joins a binding merged with an unhinted twin to residual" {
    const context = [_]Hint{.{ .function = 0, .slot = 0, .kind = .context }};
    const twins = [_]Hint{
        .{ .function = 0, .slot = 0, .kind = .context },
        .{ .function = 1, .slot = 0, .kind = .context },
    };
    const residual = [_]Hint{.{ .function = 0, .slot = 0, .kind = .residual }};
    try expectRelocated(&residual, &context, &.{ 0, 0 });
    try expectRelocated(&context, &twins, &.{ 0, 0 });
    try expectRelocated(&context, &context, &.{ 0, relocation_missing });
    try expectRelocated(&.{}, &context, &.{ relocation_missing, 0 });
    try expectRelocated(error.InvalidCorrespondence, &context, &.{ 1, 0 });
    try expectRelocated(error.InvalidCorrespondence, &twins, &.{0});
}
