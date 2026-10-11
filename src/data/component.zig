// Copyright (c) 2026 Boundary contributors. MIT license.
//! Relocatable first-order component records. Objects cannot execute in Kosmos.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const relocation = @import("relocation.zig");
const record = @import("record.zig");
const program_record = @import("program_record.zig");
const wire = @import("wire.zig");
pub const Symbol = struct { name: []const u8, reference: relocation.Reference };
pub const Object = struct {
    program: ir.Program,
    imports: []const Symbol = &.{},
    exports: []const Symbol,
    borrows: []const @import("borrow_contract.zig").Summary = &.{},
};
pub const Error = @import("activation_ownership.zig").Error || record.Error || error{ InvalidSymbol, DuplicateSymbol, InvalidImport };
pub const magic = "ABL_BMO1";
pub const identity_domain = "boundary.component/v1\x00";
/// Budget includes declared regions, which otherwise cost only one wire integer.
pub const max_catalog_entries = 1 << 20;

fn symbols(program: ir.Program, values: []const Symbol) Error!void {
    const counts = try relocation.sizes(program);
    var previous: ?[]const u8 = null;
    for (values) |symbol| {
        if (symbol.name.len == 0 or !std.unicode.utf8ValidateSlice(symbol.name)) return error.InvalidSymbol;
        if (previous) |prior| if (!std.mem.lessThan(u8, prior, symbol.name)) return error.DuplicateSymbol;
        previous = symbol.name;
        if (symbol.reference.id >= counts[@backingInt(symbol.reference.kind)]) return error.InvalidReference;
    }
}

/// The callable contracts of an imported/exported handler or constructor are
/// interface obligations even when their functions have no separate symbol.
pub fn interfaceFunctions(allocator: std.mem.Allocator, object: Object) Error![]const p.Id {
    var result: std.ArrayList(p.Id) = .empty;
    errdefer result.deinit(allocator);
    for ([_][]const Symbol{ object.imports, object.exports }) |list| {
        try symbols(object.program, list);
        for (list) |symbol| switch (symbol.reference.kind) {
            .function => try result.append(allocator, symbol.reference.id),
            .constructor => try result.append(allocator, object.program.constructors[@intCast(symbol.reference.id)].function),
            .handler => {
                const handler = object.program.handlers[@intCast(symbol.reference.id)];
                try result.append(allocator, handler.return_function);
                for (handler.clauses) |clause| try result.append(allocator, clause.function);
            },
            else => {},
        };
    }
    std.mem.sort(p.Id, result.items, {}, std.sort.asc(p.Id));
    var count: usize = 0;
    for (result.items) |id| {
        if (count != 0 and result.items[count - 1] == id) continue;
        result.items[count] = id;
        count += 1;
    }
    result.items.len = count;
    return result.toOwnedSlice(allocator);
}

/// Check every local definition and declaration, including unreachable ones.
/// Local code is checked under explicit imported borrow contracts. Closed link
/// admission also derives the actual guarantees independently of declarations.
pub fn validate(allocator: std.mem.Allocator, object: Object) Error!void {
    var entries: usize = 0;
    for (try relocation.sizes(object.program)) |count| {
        entries = std.math.add(usize, entries, count) catch return error.Capacity;
        if (entries > max_catalog_entries) return error.Capacity;
    }
    try symbols(object.program, object.imports);
    try symbols(object.program, object.exports);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var imports: std.ArrayList(p.Id) = .empty;
    var seen: std.AutoHashMapUnmanaged(relocation.Reference, void) = .empty;
    for (object.imports) |symbol| {
        if ((try seen.getOrPut(scratch.allocator(), symbol.reference)).found_existing) return error.InvalidImport;
        switch (symbol.reference.kind) {
            .function => try imports.append(scratch.allocator(), symbol.reference.id),
            .resource => {
                const resource = object.program.scopes.resources[@intCast(symbol.reference.id)];
                if (resource.introducers.len != 0 or resource.eliminators.len != 0) return error.InvalidOwnership;
            },
            .schema, .effect, .region, .handler, .constructor => {},
            .constant, .block, .capture => return error.InvalidImport,
        }
    }
    if (std.mem.indexOfScalar(p.Id, imports.items, object.program.roots.entry) != null) return error.InvalidImport;
    var facts = try @import("activation_ownership.zig").analyzeComponent(allocator, object.program, imports.items, object.borrows);
    facts.deinit();
    for (try interfaceFunctions(scratch.allocator(), object)) |function| {
        for (object.borrows) |summary| {
            if (summary.function == function) break;
        } else return error.InvalidOwnership;
    }
}

fn write(object: Object, writer: *wire.Writer) Error!void {
    var context: program_record.Context = .{};
    try program_record.write(ir.Program, object.program, writer, &context);
    try record.write([]const Symbol, object.imports, writer);
    try record.write([]const Symbol, object.exports, writer);
    try record.write([]const @import("borrow_contract.zig").Summary, object.borrows, writer);
}
pub fn encodedLength(object: Object) Error!usize {
    var writer: wire.Writer = .{ .position = wire.header_length };
    try write(object, &writer);
    return writer.position;
}
pub fn encode(allocator: std.mem.Allocator, object: Object, output: []u8) Error![]const u8 {
    try validate(allocator, object);
    const length = try encodedLength(object);
    if (length > output.len) return error.Capacity;
    if (record.overlaps(Object, object, output[0..length])) return error.InvalidBuffers;
    var writer: wire.Writer = .{ .output = output[0..length] };
    try writer.put(magic);
    try writer.fixed(u16, 1);
    try writer.fixed(u16, 0);
    try writer.fixed(u64, length - wire.header_length);
    try write(object, &writer);
    return output[0..length];
}
pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    object: Object,
    identity: [32]u8,
    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error!Decoded {
    if (input.len < wire.header_length) return error.Truncated;
    if (input.len > 64 << 20) return error.Capacity;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const bytes = try arena.allocator().dupe(u8, input);
    var reader: wire.Reader = .{ .input = bytes };
    if (!std.mem.eql(u8, try reader.take(8), magic)) return error.InvalidFamily;
    if (try reader.fixed(u16) != 1) return error.UnsupportedVersion;
    if (try reader.fixed(u16) != 0) return error.InvalidFlags;
    if (try reader.fixed(u64) != bytes.len - wire.header_length) return error.InvalidLength;
    var budget: program_record.Budget = .{ .used = bytes.len, .maximum = 64 << 20 };
    var context: program_record.Context = .{};
    const program = try program_record.read(ir.Program, &reader, arena.allocator(), &budget, &context);
    var remaining = budget.maximum - budget.used;
    const imports = try record.readBounded([]const Symbol, &reader, arena.allocator(), &remaining);
    const exports = try record.readBounded([]const Symbol, &reader, arena.allocator(), &remaining);
    const borrows = try record.readBounded([]const @import("borrow_contract.zig").Summary, &reader, arena.allocator(), &remaining);
    try reader.finish();
    const object: Object = .{ .program = program, .imports = imports, .exports = exports, .borrows = borrows };
    try validate(allocator, object);
    var comparison: wire.Writer = .{ .expected = bytes[wire.header_length..] };
    try write(object, &comparison);
    if (comparison.position != bytes.len - wire.header_length) return error.NonCanonical;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(identity_domain);
    hash.update(bytes);
    return .{ .arena = arena, .object = object, .identity = hash.finalResult() };
}
