const std = @import("std");
const image = @import("program_image.zig");
const ir = @import("activation.zig");
const p = @import("program.zig");
const testing = std.testing;

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

// Independently transcribed from the documented grammar, not encoder output.
const golden = "ABL_BPI3".* ++ [_]u8{
    3, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0, // framing
    1, 0, 0, 1, // roots
    2, 9, 0, // schemas: u64, unit
    1, 0, 8, 1, 42, // literal: u64 42
    0, // effects
    1, 0, 0, 0, 1, 0, 0, // one function, one slot
    1, 0, 1, 0, 0, 0, 0, // one block: constant to slot 0, return 0
    0, 0, 0, 0, 0, // handlers, captures, regions, resources, constructors
};

test "immutable admitted images share facts without accepting mutable lookalikes" {
    var bytes = golden;
    const admitted = try image.Admitted.decode(testing.allocator, &bytes);
    defer admitted.deinit();
    @memset(&bytes, 0xff);
    try testing.expectEqualDeep(example, admitted.program());
    const retained = admitted.storageBytes();
    var first = try admitted.analysis(testing.allocator);
    defer first.deinit();
    var second = try admitted.analysis(testing.allocator);
    defer second.deinit();
    try testing.expect(first.facts.live.ptr == second.facts.live.ptr);
    try testing.expect(first.facts.pool != second.facts.pool);
    const root = first.facts.live[0][1];
    try testing.expect(first.facts.pool.contains(root, 0));
    try testing.expectEqual(
        @import("analysis_sets.zig").empty,
        try first.facts.pool.remove(root, 0),
    );
    try testing.expect(second.facts.pool.contains(root, 0));
    try testing.expectEqual(retained, admitted.storageBytes());
    const state: @import("process_state.zig").State = .{
        .program_identity = admitted.identity(),
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
    try @import("state_admission.zig").validateAdmitted(testing.allocator, admitted, state);
    var lookalike = admitted.program();
    lookalike.roots.entry = 999;
    try testing.expectError(
        error.InvalidReference,
        @import("state_admission.zig").validateStable(testing.allocator, lookalike, state),
    );
    try @import("state_admission.zig").validateAdmitted(testing.allocator, admitted, state);
    // Public-only values have no borrow scopes, but still require the exact
    // live frame and typed bindings at the admitted instruction position.
    try testing.expect(std.mem.allEqual(bool, admitted.schemaFacts().exportable, true));
    var nodes = state.nodes[0..1].*;
    var invalid = state;
    invalid.nodes = &nodes;
    nodes[0].activation.?.bindings = &.{};
    try testing.expectError(
        error.InvalidState,
        @import("state_admission.zig").validateAdmitted(testing.allocator, admitted, invalid),
    );
    nodes[0] = state.nodes[0];
    nodes[0].activation.?.position = 0;
    try testing.expectError(
        error.InvalidState,
        @import("state_admission.zig").validateAdmitted(testing.allocator, admitted, invalid),
    );
}

fn admittedFailure(allocator: std.mem.Allocator) !void {
    const owner = try image.Admitted.decode(allocator, &golden);
    defer owner.deinit();
    var analysis = try owner.analysis(allocator);
    defer analysis.deinit();
    try testing.expectEqualDeep(example, owner.program());
}
test "immutable admitted image allocation failures release records and facts" {
    try @import("allocation_testing.zig").check(testing.allocator, admittedFailure, .{});
}

fn retainedContractFacts(allocator: std.mem.Allocator) !void {
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit, .{ .internal = .{ .capability = 0 } } },
        .constants = &.{},
        .effects = &.{.{ .identity = "read", .payload = 0, .result = 0, .external = true }},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 0, 0 } },
            .result = 0,
            .effects = &.{0},
        }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{
                .effect = 0,
                .payload = 0,
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        },
    };
    var bytes: [256]u8 = undefined;
    const encoded = try image.encode(testing.allocator, program, &bytes);
    const owner = try image.Admitted.decode(allocator, encoded);
    defer owner.deinit();
    @memset(&bytes, 0xff);
    const churn = try allocator.alloc(u8, 1024);
    defer allocator.free(churn);
    @memset(churn, 0xa5);
    try testing.expectEqual(8, owner.schemaFacts().minimum[0]);
    try testing.expect(owner.schemaFacts().exportable[0]);
    try testing.expect(!owner.schemaFacts().exportable[2]);
    try testing.expect(owner.traits().copy[0] and owner.traits().drop[0]);
    try testing.expect(owner.effectFacts().ambient[0]);
    try testing.expect(owner.effectFacts().contains(2, 0));
    try testing.expect(!owner.effectFacts().contains(0, 0));
    try testing.expectEqualStrings("read", owner.program().effects[0].identity);
}

test "admitted schema traits and effect facts survive scratch release and failed construction" {
    try @import("allocation_testing.zig").check(testing.allocator, retainedContractFacts, .{});
}

test "BPI3 scalar and unit golden encodings" {
    var bytes: [256]u8 = undefined;
    try testing.expectEqualSlices(
        u8,
        &golden,
        try image.encode(testing.allocator, example, &bytes),
    );
    var decoded = try image.decode(testing.allocator, &golden);
    defer decoded.deinit();
    try testing.expectEqualDeep(example, decoded.program);
    var unit = example;
    unit.roots.failure = 0;
    unit.schemas = &.{.unit};
    unit.constants = &.{.{ .schema = 0, .bytes = &.{} }};
    const unit_golden = "ABL_BPI3".* ++ [_]u8{
        3, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 1,  0, 1, 0, 0, 0, 1, 0,
        0, 0, 1, 0, 0,  1, 0, 1, 0, 0, 0, 0,
        0, 0, 0, 0, 0,
    };
    try testing.expectEqualSlices(
        u8,
        &unit_golden,
        try image.encode(testing.allocator, unit, &bytes),
    );
    var decoded_unit = try image.decode(testing.allocator, &unit_golden);
    defer decoded_unit.deinit();
    try testing.expectEqualDeep(unit, decoded_unit.program);
}

test "BPI3 rejects redundant defaults and compressed expansion bombs" {
    var noncanonical: [golden.len + 1]u8 = undefined;
    @memcpy(noncanonical[0..45], golden[0..45]);
    noncanonical[12] += 1;
    noncanonical[43] = 64; // Explicit zero immediate must be omitted.
    noncanonical[45] = 0;
    @memcpy(noncanonical[46..], golden[45..]);
    try testing.expectError(error.NonCanonical, image.decode(testing.allocator, &noncanonical));

    // Replace the one-slot layout with a short repeated-ID descriptor for 2^30 slots.
    const bomb = golden[0..37].* ++ [_]u8{
        128,
        128,
        128,
        128,
        4,
        1,
        1,
        128,
        128,
        128,
        128,
        4,
        0,
    } ++ golden[39..].*;
    var framed = bomb;
    std.mem.writeInt(u64, framed[12..20], framed.len - 20, .little);
    // Expansion rejection is an explicitly selected resource policy. Canonical
    // native decoding has no implicit application-size allowance.
    try testing.expectError(
        error.Capacity,
        image.decodeLimited(testing.allocator, &framed, .{ .max_decoded_bytes = 64 << 20 }),
    );
}

test "BPI3 owns decoded records and binds identity to its canonical bytes" {
    var bytes: [256]u8 = undefined;
    const encoded = try image.encode(testing.allocator, example, &bytes);
    var decoded = try image.decode(testing.allocator, encoded);
    defer decoded.deinit();
    @memset(&bytes, 0xff);
    try testing.expectEqualDeep(example, decoded.program);
    try testing.expectEqual(try image.identity(testing.allocator, example), decoded.identity);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(image.identity_domain);
    hash.update(decoded.bytes);
    try testing.expectEqual(hash.finalResult(), decoded.identity);
}

test "BPI3 rejects output overlap and capacity without mutation" {
    var bytes = @as([256]u8, @splat(0));
    const constants = [_]p.Literal{.{ .schema = 0, .bytes = bytes[0..8] }};
    var program = example;
    program.constants = &constants;
    try testing.expectError(error.InvalidBuffers, image.encode(testing.allocator, program, &bytes));
    try testing.expectEqualSlices(u8, &(@as([256]u8, @splat(0))), &bytes);
    @memset(&bytes, 0xa5);
    try testing.expectError(error.Capacity, image.encode(testing.allocator, example, bytes[0..1]));
    try testing.expectEqualSlices(u8, &(@as([256]u8, @splat(0xa5))), &bytes);
    program = example;
    program.roots.entry = 999;
    try testing.expectError(
        error.InvalidReference,
        image.encode(testing.allocator, program, &bytes),
    );
    try testing.expectEqualSlices(u8, &(@as([256]u8, @splat(0xa5))), &bytes);
}

test "BPI3 single-bit mutations either reject or remain admitted canonical owners" {
    for (0..golden.len) |position| {
        for (0..8) |bit| {
            var mutated = golden;
            mutated[position] ^= @as(u8, 1) << @intCast(bit);
            if (image.decode(testing.allocator, &mutated)) |value| {
                var decoded = value;
                defer decoded.deinit();
                var output: [256]u8 = undefined;
                try testing.expectEqualSlices(
                    u8,
                    &mutated,
                    try image.encode(testing.allocator, decoded.program, &output),
                );
                try testing.expectEqual(
                    try image.identity(testing.allocator, decoded.program),
                    decoded.identity,
                );
            } else |_| {}
        }
    }
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var bytes = @as([256]u8, @splat(0xa5));
    const encoded = image.encode(allocator, example, &bytes) catch |err| {
        for (bytes) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
        return err;
    };
    var decoded = try image.decode(allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqualDeep(example, decoded.program);
}

test "BPI3 allocation failures release owners and leave uncommitted output intact" {
    try @import("allocation_testing.zig").check(testing.allocator, allocationFailure, .{});
}

test "BPI3 framing rejects truncation, old families, flags and trailing input" {
    var bytes: [256]u8 = undefined;
    const encoded = try image.encode(testing.allocator, example, &bytes);
    for (0..encoded.len) |length| {
        if (image.decode(testing.allocator, encoded[0..length])) |value| {
            var owner = value;
            owner.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
    for ([_][]const u8{ "ABL_BPI1", "ABL_BPI2", "ABL_BPC1", "ABL_PST1", "ABL_PST2" }) |family| {
        @memcpy(bytes[0..8], family);
        try testing.expectError(error.InvalidFamily, image.decode(testing.allocator, encoded));
    }
    @memcpy(bytes[0..8], "ABL_BPI3");
    bytes[8] = 2;
    try testing.expectError(error.UnsupportedVersion, image.decode(testing.allocator, encoded));
    bytes[8] = 3;
    bytes[10] = 1;
    try testing.expectError(error.InvalidFlags, image.decode(testing.allocator, encoded));
    bytes[10] = 0;
    try testing.expectError(
        error.InvalidLength,
        image.decode(testing.allocator, bytes[0 .. encoded.len + 1]),
    );
    try testing.expectError(
        error.Capacity,
        image.decodeLimited(testing.allocator, encoded, .{ .max_decoded_bytes = encoded.len }),
    );
}

test "admission checks the owned header even when allocation changes caller input" {
    const Mutating = struct {
        child: std.mem.Allocator,
        input: []u8,
        changed: bool = false,

        fn allocate(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.changed) {
                self.changed = true;
                self.input[10] = 1;
            }
            return self.child.rawAlloc(len, alignment, ra);
        }

        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.child.rawFree(bytes, alignment, ra);
        }
    };
    var bytes: [256]u8 = undefined;
    const encoded = try image.encode(std.testing.allocator, example, &bytes);
    var context: Mutating = .{ .child = std.testing.allocator, .input = &bytes };
    const allocator: std.mem.Allocator = .{ .ptr = &context, .vtable = &.{
        .alloc = Mutating.allocate,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = Mutating.free,
    } };
    if (image.decode(allocator, encoded)) |value| {
        var owner = value;
        owner.deinit();
        return error.AcceptedChangedHeader;
    } else |err| try std.testing.expectEqual(error.InvalidFlags, err);
}

fn bulkDecodeFailure(allocator: std.mem.Allocator, encoded: []const u8) !void {
    var decoded = try image.decode(allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 2048), decoded.program.blocks[0].instructions.len);
    try testing.expectEqualSlices(
        u8,
        example.constants[0].bytes,
        decoded.program.constants[0].bytes,
    );
}

test "large decoded arrays and owned image bytes survive caller mutation and allocation failure" {
    const instructions = try testing.allocator.alloc(ir.Instruction, 2048);
    defer testing.allocator.free(instructions);
    @memset(instructions, .{ .destination = 0, .opcode = .constant });
    var blocks = [_]ir.Block{example.blocks[0]};
    blocks[0].instructions = instructions;
    var program = example;
    program.blocks = &blocks;
    const bytes = try testing.allocator.alloc(u8, try image.encodedLength(program));
    defer testing.allocator.free(bytes);
    _ = try image.encode(testing.allocator, program, bytes);
    try testing.expect(bytes.len >= 4096);
    try @import("allocation_testing.zig").check(testing.allocator, bulkDecodeFailure, .{bytes});
    var decoded = try image.decode(testing.allocator, bytes);
    defer decoded.deinit();
    @memset(bytes, 0xff);
    try testing.expectEqual(@as(usize, 2048), decoded.program.blocks[0].instructions.len);
    try testing.expectEqualSlices(
        u8,
        example.constants[0].bytes,
        decoded.program.constants[0].bytes,
    );
    const output = try testing.allocator.alloc(u8, try image.encodedLength(decoded.program));
    defer testing.allocator.free(output);
    _ = try image.encode(testing.allocator, decoded.program, output);
    var roundtrip = try image.decode(testing.allocator, output);
    defer roundtrip.deinit();
    try testing.expectEqualDeep(decoded.program, roundtrip.program);
}

test "large outer block catalogs own exact storage and release partial decode failures" {
    var blocks: [64]ir.Block = undefined;
    for (&blocks, 0..) |*block, index| block.* = .{
        .function = 0,
        .instructions = if (index == 0) example.blocks[0].instructions else &.{},
        .terminator = if (index + 1 == blocks.len)
            .{ .return_value = 0 }
        else
            .{ .jump = .{ .block = index + 1 } },
    };
    var program = example;
    program.blocks = &blocks;
    const encoded = try testing.allocator.alloc(u8, try image.encodedLength(program));
    defer testing.allocator.free(encoded);
    _ = try image.encode(testing.allocator, program, encoded);
    var decoded = try image.decode(testing.allocator, encoded);
    defer decoded.deinit();
    try testing.expectEqual(blocks.len, decoded.block_catalog.len);
    try testing.expectEqualDeep(program, decoded.program);
    try @import("allocation_testing.zig").check(
        testing.allocator,
        decodeBlockCatalog,
        .{ encoded, false },
    );
    const truncated = try testing.allocator.dupe(u8, encoded[0 .. encoded.len - 1]);
    defer testing.allocator.free(truncated);
    std.mem.writeInt(u64, truncated[12..20], truncated.len - 20, .little);
    try @import("allocation_testing.zig").check(
        testing.allocator,
        decodeBlockCatalog,
        .{ truncated, true },
    );
    @memset(encoded, 0xff);
    try testing.expectEqualDeep(program, decoded.program);
}

fn decodeBlockCatalog(allocator: std.mem.Allocator, bytes: []const u8, truncated: bool) !void {
    var decoded = image.decode(allocator, bytes) catch |err| {
        if (truncated and err == error.Truncated) return;
        return err;
    };
    defer decoded.deinit();
    try testing.expect(!truncated);
    try testing.expectEqual(64, decoded.program.blocks.len);
    try testing.expectEqual(63, decoded.program.blocks[62].terminator.jump.block);
}

test "accepted handler bytes and retired wire tags stay fixed" {
    const codec = @import("program_record.zig");
    const wire = @import("wire.zig");
    try testing.expectEqual(@as(u8, 15), @backingInt(p.TerminatorTag.dispose));
    try testing.expectEqual(@as(u8, 16), @backingInt(p.TerminatorTag.protect));
    try testing.expectEqual(@as(u8, 17), @backingInt(p.TerminatorTag.with_region));
    // Independent record grammar: deep, input, answer, return, no clauses,
    // mandatory zero retired field, no state, no effects.
    const expected = [_]u8{ 0, 3, 4, 5, 0, 0, 0, 0 };
    const handler: ir.Handler = .{
        .mode = .deep,
        .input = 3,
        .answer = 4,
        .return_function = 5,
        .clauses = &.{},
    };
    var output: [32]u8 = undefined;
    var writer: wire.Writer = .{ .output = &output };
    var context: codec.Context = .{};
    try codec.write(ir.Handler, handler, &writer, &context);
    try testing.expectEqualSlices(u8, &expected, output[0..writer.position]);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reader: wire.Reader = .{ .input = &expected };
    var budget: codec.Budget = .{ .maximum = 1024 };
    const decoded = try codec.read(ir.Handler, &reader, arena.allocator(), &budget, &context);
    try reader.finish();
    try testing.expectEqualDeep(handler, decoded);
    for ([_]u8{ 1, 2, 255 }) |invalid| {
        var changed = expected;
        changed[5] = invalid;
        reader = .{ .input = &changed };
        try testing.expectError(
            error.InvalidFlags,
            codec.read(ir.Handler, &reader, arena.allocator(), &budget, &context),
        );
    }
    reader = .{ .input = &.{14} };
    try testing.expectError(
        error.InvalidTag,
        codec.read(ir.Terminator, &reader, arena.allocator(), &budget, &context),
    );
}
