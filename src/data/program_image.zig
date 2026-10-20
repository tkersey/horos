// Copyright (c) 2026 Boundary contributors. MIT license.
//! The successor image encodes stable records directly, with no legacy fallback.
const std = @import("std");
const ir = @import("activation.zig");
const wire = @import("wire.zig");
const record = @import("record.zig");
const body_record = @import("program_record.zig");
const admission = @import("activation_ownership.zig");
const flow = @import("activation_flow.zig");
const sets = @import("analysis_sets.zig");
pub const Error = admission.Error || body_record.Error;
pub const magic = "ABL_BPI3";
pub const identity_domain = "boundary.program/v3\x00";
/// Native defaults follow the allocator; finite budgets are caller policy.
pub const Limits = struct { max_decoded_bytes: usize = std.math.maxInt(usize) };

pub fn encodedLength(program: ir.Program) Error!usize {
    var writer: wire.Writer = .{ .position = wire.header_length };
    var context: body_record.Context = .{};
    try body_record.write(ir.Program, program, &writer, &context);
    return writer.position;
}

fn write(program: ir.Program, length: usize, writer: *wire.Writer) Error!void {
    try writer.put(magic);
    try writer.fixed(u16, 3);
    try writer.fixed(u16, 0);
    try writer.fixed(u64, length - wire.header_length);
    var context: body_record.Context = .{};
    try body_record.write(ir.Program, program, writer, &context);
}

/// Full admission, sizing and overlap checks precede the first output write.
pub fn encode(allocator: std.mem.Allocator, program: ir.Program, output: []u8) Error![]const u8 {
    var checked = try admission.analyze(allocator, program);
    defer checked.deinit();
    const length = try encodedLength(program);
    if (output.len < length) return error.Capacity;
    if (record.overlaps(ir.Program, program, output[0..length])) return error.InvalidBuffers;
    var writer: wire.Writer = .{ .output = output[0..length] };
    try write(program, length, &writer);
    std.debug.assert(writer.position == length);
    return output[0..length];
}

/// Domain-separated identity over the admitted compact structural encoding.
pub fn identity(allocator: std.mem.Allocator, program: ir.Program) Error![32]u8 {
    var checked = try admission.analyze(allocator, program);
    defer checked.deinit();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(identity_domain);
    var writer: wire.Writer = .{ .hasher = &hash };
    try write(program, try encodedLength(program), &writer);
    return hash.finalResult();
}

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    block_catalog: []ir.Block,
    program: ir.Program,
    bytes: []const u8,
    identity: [32]u8,
    decoded_bytes: usize,

    pub fn deinit(self: *Decoded) void {
        self.arena.child_allocator.free(self.block_catalog);
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error!Decoded {
    return decodeLimited(allocator, input, .{});
}

pub fn decodeLimited(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) Error!Decoded {
    var checked = try decodeChecked(allocator, input, limits);
    checked.analysis.deinit();
    return checked.decoded;
}

const Checked = struct {
    decoded: Decoded,
    analysis: flow.Facts,
    fn deinit(self: *Checked) void {
        self.analysis.deinit();
        self.decoded.deinit();
    }
};
fn decodeChecked(allocator: std.mem.Allocator, input: []const u8, limits: Limits) Error!Checked {
    if (input.len < wire.header_length) return error.Truncated;
    if (input.len > limits.max_decoded_bytes) return error.Capacity;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var block_catalog: []ir.Block = &.{};
    errdefer allocator.free(block_catalog);
    const owned = try arena.allocator().dupe(u8, input);
    var reader: wire.Reader = .{ .input = owned };
    if (!std.mem.eql(u8, try reader.take(8), magic)) return error.InvalidFamily;
    if (try reader.fixed(u16) != 3) return error.UnsupportedVersion;
    if (try reader.fixed(u16) != 0) return error.InvalidFlags;
    if (try reader.fixed(u64) != owned.len - wire.header_length) return error.InvalidLength;
    var context: body_record.Context = .{};
    var budget: body_record.Budget = .{ .used = owned.len, .maximum = limits.max_decoded_bytes };
    const program = try body_record.readProgram(
        &reader,
        arena.allocator(),
        allocator,
        &block_catalog,
        &budget,
        &context,
    );
    try reader.finish();
    var checked = try admission.analyze(allocator, program);
    errdefer checked.deinit();
    // Re-emission checks every omitted default and compressed spelling. The hash
    // receives those same bytes; neither path expands old live interfaces.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(identity_domain);
    var canonical: wire.Writer = .{ .expected = owned, .hasher = &hash };
    try write(program, owned.len, &canonical);
    if (canonical.position != owned.len) return error.NonCanonical;
    return .{
        .decoded = .{
            .arena = arena,
            .block_catalog = block_catalog,
            .program = program,
            .bytes = owned,
            .identity = hash.finalResult(),
            .decoded_bytes = budget.used,
        },
        .analysis = checked,
    };
}

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    facts: flow.View,
    pub fn deinit(self: *Analysis) void {
        self.facts.pool.deinit();
        self.allocator.destroy(self.facts.pool);
        self.* = undefined;
    }
};
const AdmittedStorage = struct {
    allocator: std.mem.Allocator,
    decoded: Decoded,
    analysis: flow.Facts,
    schemas: @import("admission.zig").SchemaFacts,
    uses: @import("traits.zig").Facts,
    effects: @import("effect_scope.zig").Facts,
};

/// Immutable reusable admission owner. Construction accepts bytes only, never
/// caller-supplied facts, identity, or a mutable Decoded lookalike.
pub const Admitted = opaque {
    fn storage(self: *const Admitted) *const AdmittedStorage {
        return @ptrCast(@alignCast(self));
    }
    pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error!*Admitted {
        var checked = try decodeChecked(allocator, input, .{});
        errdefer checked.deinit();
        const derived = checked.analysis.arena.allocator();
        const schemas = try @import("admission.zig").schemas(
            derived,
            checked.decoded.program.schemas,
        );
        const uses = try @import("traits.zig").derive(derived, checked.decoded.program.schemas);
        const effects = try @import("effect_scope.zig").derive(derived, checked.decoded.program);
        const owner = try allocator.create(AdmittedStorage);
        owner.* = .{
            .allocator = allocator,
            .decoded = checked.decoded,
            .analysis = checked.analysis,
            .schemas = schemas,
            .uses = uses,
            .effects = effects,
        };
        return @ptrCast(owner);
    }
    pub fn deinit(self: *Admitted) void {
        const owner: *AdmittedStorage = @ptrCast(@alignCast(self));
        const allocator = owner.allocator;
        owner.analysis.deinit();
        owner.decoded.deinit();
        allocator.destroy(owner);
    }
    pub fn program(self: *const Admitted) ir.Program {
        return self.storage().decoded.program;
    }
    pub fn identity(self: *const Admitted) [32]u8 {
        return self.storage().decoded.identity;
    }
    pub fn schemaFacts(self: *const Admitted) @import("admission.zig").SchemaFacts {
        return self.storage().schemas;
    }
    pub fn traits(self: *const Admitted) @import("traits.zig").Facts {
        return self.storage().uses;
    }
    pub fn effectFacts(self: *const Admitted) @import("effect_scope.zig").Facts {
        return self.storage().effects;
    }
    pub fn storageBytes(self: *const Admitted) usize {
        const owner = self.storage();
        const catalogs = owner.decoded.block_catalog.len * @sizeOf(ir.Block);
        return @sizeOf(AdmittedStorage) +
            owner.decoded.arena.queryCapacity() +
            catalogs +
            owner.analysis.arena.queryCapacity() +
            owner.analysis.pool.storageBytes();
    }
    /// Per-consumer mutable set nodes; all original maps remain shared read-only.
    /// This analysis borrows the admitted owner for its entire lifetime.
    pub fn analysis(self: *const Admitted, allocator: std.mem.Allocator) Error!Analysis {
        const original = &self.storage().analysis;
        const pool = try allocator.create(sets.Pool);
        errdefer allocator.destroy(pool);
        pool.* = sets.Pool.overlay(allocator, try original.pool.readOnly());
        return .{
            .allocator = allocator,
            .facts = .{ .pool = pool, .positions = original.positions, .live = original.live },
        };
    }
};
