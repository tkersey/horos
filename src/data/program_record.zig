// Copyright (c) 2026 Boundary contributors. MIT license.
//! BPI3 record grammar. This never constructs a predecessor Program or interface.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const wire = @import("wire.zig");
const record = @import("record.zig");
const opcode_contract = @import("opcode_contract.zig");
const sequence = @import("compact_sequence.zig");
pub const Error = record.Error;

pub const Budget = struct {
    used: usize = 0,
    maximum: usize,
    pub fn account(self: *Budget, comptime T: type, count: usize) Error!void {
        const size = std.math.mul(usize, @sizeOf(T), count) catch return error.InvalidLength;
        const next = std.math.add(usize, self.used, size) catch return error.InvalidLength;
        if (next > self.maximum) return error.Capacity;
        self.used = next;
    }
};
pub const Context = struct { previous_function: p.Id = 0 };

/// The image owner may allocate a large outer block catalog exactly. Nested
/// records still belong to its arena; the out allocation is owned on failure too.
pub fn readProgram(
    reader: *wire.Reader,
    arena: std.mem.Allocator,
    catalog: std.mem.Allocator,
    blocks: *[]ir.Block,
    budget: *Budget,
    context: *Context,
) Error!ir.Program {
    var result: ir.Program = undefined;
    inline for (
        @typeInfo(ir.Program).@"struct".field_names,
        @typeInfo(ir.Program).@"struct".field_types,
    ) |field_name, FieldType| {
        if (comptime std.mem.eql(u8, field_name, "blocks")) {
            const count = try reader.count();
            if (count > reader.input.len - reader.position) return error.Truncated;
            try budget.account(ir.Block, count);
            const exact = count >= 4096 / @sizeOf(ir.Block);
            const output = try (if (exact) catalog else arena).alloc(ir.Block, count);
            if (exact) blocks.* = output;
            for (output) |*block| block.* = try read(ir.Block, reader, arena, budget, context);
            result.blocks = output;
        } else @field(result, field_name) = try read(FieldType, reader, arena, budget, context);
    }
    return result;
}

comptime {
    fields(
        ir.Program,
        &.{
            "roots",
            "schemas",
            "constants",
            "effects",
            "functions",
            "blocks",
            "handlers",
            "scopes",
            "constructors",
        },
    );
    fields(
        ir.Function,
        &.{ "entry", "inputs", "layout", "custody", "result", "effects", "regions" },
    );
    fields(
        ir.Handler,
        &.{ "mode", "input", "answer", "return_function", "clauses", "state", "effects" },
    );
    fields(ir.Block, &.{ "function", "custody", "instructions", "terminator" });
    fields(ir.Instruction, &.{ "destination", "opcode", "operands", "immediate", "failures" });
    fields(ir.Edge, &.{ "block", "assignments" });
    fields(ir.Assignment, &.{ "destination", "source" });
    fields(p.Literal, &.{ "schema", "bytes" });
    for (@typeInfo(p.Opcode).@"enum".field_values) |field_value| std.debug.assert(field_value < 64);
}
fn fields(comptime T: type, comptime names: []const []const u8) void {
    const declared = @typeInfo(T).@"struct".field_names;
    std.debug.assert(declared.len == names.len);
    for (declared, names) |field_name, name| std.debug.assert(std.mem.eql(u8, field_name, name));
}

pub fn write(comptime T: type, value: T, writer: *wire.Writer, context: *Context) Error!void {
    if (T == ir.Function) return writeFunction(value, writer, context);
    if (T == ir.Block) return writeBlock(value, writer, context);
    if (T == ir.Instruction) return writeInstruction(value, writer);
    if (T == ir.Edge) return writeEdge(value, writer);
    if (T == p.Literal) return writeLiteral(value, writer);
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.child == p.Id) return sequence.write(p.Id, value, writer);
            try writer.natural(value.len);
            if (info.child == u8) return writer.put(value);
            for (value) |element| try write(info.child, element, writer, context);
        },
        .@"struct" => |info| inline for (
            info.field_names,
            info.field_types,
        ) |field_name, FieldType| {
            // Retired optional forwarding field: accepted images always encoded zero.
            if (T == ir.Handler and comptime std.mem.eql(u8, field_name, "state"))
                try writer.byte(0);
            try write(FieldType, @field(value, field_name), writer, context);
        },
        .@"union" => {
            try writer.natural(@backingInt(std.meta.activeTag(value)));
            switch (value) {
                inline else => |payload| try write(@TypeOf(payload), payload, writer, context),
            }
        },
        .optional => |info| {
            try writer.byte(@intFromBool(value != null));
            if (value) |present| try write(info.child, present, writer, context);
        },
        else => try record.write(T, value, writer),
    }
}

pub fn read(
    comptime T: type,
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    budget: *Budget,
    context: *Context,
) Error!T {
    if (T == ir.Function) return readFunction(reader, allocator, budget, context);
    if (T == ir.Block) return readBlock(reader, allocator, budget, context);
    if (T == ir.Instruction) return readInstruction(reader, allocator, budget, context);
    if (T == ir.Edge) return readEdge(reader, allocator, budget);
    if (T == p.Literal) return readLiteral(reader, allocator, budget);
    return switch (@typeInfo(T)) {
        .pointer => |info| blk: {
            if (info.child == p.Id) {
                var probe = reader.*;
                try budget.account(p.Id, try probe.count());
                var requested: usize = 0;
                break :blk try sequence.read(p.Id, true, reader, allocator, &requested);
            }
            const count = try reader.count();
            if (count > reader.input.len - reader.position) return error.Truncated;
            if (info.child == u8) break :blk try reader.take(count);
            try budget.account(info.child, count);
            const output = try allocator.alloc(info.child, count);
            for (output) |*element| element.* = try read(
                info.child,
                reader,
                allocator,
                budget,
                context,
            );
            break :blk output;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |field_name, FieldType| {
                if (T == ir.Handler and comptime std.mem.eql(u8, field_name, "state"))
                    if (try reader.byte() != 0) return error.InvalidFlags;
                @field(result, field_name) = try read(FieldType, reader, allocator, budget, context);
            }
            break :blk result;
        },
        .@"union" => |info| blk: {
            const tag = try reader.natural();
            inline for (info.field_names, info.field_types) |field_name, FieldType| {
                if (tag == @backingInt(@field(info.tag_type.?, field_name)))
                    break :blk @unionInit(
                        T,
                        field_name,
                        try read(FieldType, reader, allocator, budget, context),
                    );
            }
            break :blk error.InvalidTag;
        },
        .optional => |info| switch (try reader.byte()) {
            0 => null,
            1 => try read(info.child, reader, allocator, budget, context),
            else => error.InvalidTag,
        },
        else => try record.read(T, reader, allocator),
    };
}

fn writeFunction(value: ir.Function, writer: *wire.Writer, context: *Context) Error!void {
    const scopes = value.custody.len != 1 or value.custody[0].parent != null;
    const flags: u8 = @as(u8, @intFromBool(value.effects.len != 0)) |
        (@as(u8, @intFromBool(value.regions.len != 0)) << 1) |
        (@as(u8, @intFromBool(scopes)) << 2);
    try writer.byte(flags);
    try writer.natural(value.entry);
    try write([]const p.Id, value.inputs, writer, context);
    try write([]const p.Id, value.layout.slots, writer, context);
    try writer.natural(value.result);
    if (flags & 1 != 0) try write([]const p.Id, value.effects, writer, context);
    if (flags & 2 != 0) try write([]const p.Id, value.regions, writer, context);
    if (flags & 4 != 0) try write([]const ir.CustodyScope, value.custody, writer, context);
}
fn readFunction(
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    budget: *Budget,
    context: *Context,
) Error!ir.Function {
    const flags = try reader.byte();
    if (flags & ~@as(u8, 7) != 0) return error.InvalidFlags;
    return .{
        .entry = try reader.natural(),
        .inputs = try read([]const p.Id, reader, allocator, budget, context),
        .layout = .{ .slots = try read([]const p.Id, reader, allocator, budget, context) },
        .result = try reader.natural(),
        .effects = if (flags & 1 != 0) try read(
            []const p.Id,
            reader,
            allocator,
            budget,
            context,
        ) else &.{},
        .regions = if (flags & 2 != 0) try read(
            []const p.Id,
            reader,
            allocator,
            budget,
            context,
        ) else &.{},
        .custody = if (flags & 4 != 0)
            try read([]const ir.CustodyScope, reader, allocator, budget, context)
        else
            &.{.{}},
    };
}

fn writeBlock(value: ir.Block, writer: *wire.Writer, context: *Context) Error!void {
    const flags: u8 = @as(u8, @intFromBool(value.function != context.previous_function)) |
        (@as(u8, @intFromBool(value.custody != 0)) << 1);
    try writer.byte(flags);
    if (flags & 1 != 0) try writer.natural(value.function);
    if (flags & 2 != 0) try writer.natural(value.custody);
    context.previous_function = value.function;
    try write([]const ir.Instruction, value.instructions, writer, context);
    try write(ir.Terminator, value.terminator, writer, context);
}
fn readBlock(
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    budget: *Budget,
    context: *Context,
) Error!ir.Block {
    const flags = try reader.byte();
    if (flags & ~@as(u8, 3) != 0) return error.InvalidFlags;
    const owner = if (flags & 1 != 0) try reader.natural() else context.previous_function;
    const custody = if (flags & 2 != 0) try reader.natural() else 0;
    context.previous_function = owner;
    return .{
        .function = owner,
        .custody = custody,
        .instructions = try read([]const ir.Instruction, reader, allocator, budget, context),
        .terminator = try read(ir.Terminator, reader, allocator, budget, context),
    };
}

fn writeEdge(value: ir.Edge, writer: *wire.Writer) Error!void {
    try writer.natural(value.block);
    if (value.assignments.len == 1 and value.assignments[0].source == .returned) {
        try writer.natural(1);
        return writer.natural(value.assignments[0].destination);
    }
    const count = std.math.mul(u64, value.assignments.len, 2) catch return error.InvalidLength;
    try writer.natural(count);
    for (value.assignments) |assignment| {
        try writer.natural(assignment.destination);
        try writer.natural(switch (assignment.source) {
            .returned => 0,
            .slot => |slot| std.math.add(u64, slot, 1) catch return error.InvalidLength,
        });
    }
}
fn readEdge(reader: *wire.Reader, allocator: std.mem.Allocator, budget: *Budget) Error!ir.Edge {
    const block = try reader.natural();
    const header = try reader.count();
    if (header != 1 and header & 1 != 0) return error.InvalidTag;
    const count = if (header == 1) 1 else header / 2;
    if (count > reader.input.len - reader.position) return error.Truncated;
    try budget.account(ir.Assignment, count);
    const assignments = try allocator.alloc(ir.Assignment, count);
    for (assignments) |*assignment| {
        const destination = try reader.natural();
        const source = if (header == 1) 0 else try reader.natural();
        assignment.* = .{
            .destination = destination,
            .source = if (source == 0) .returned else .{ .slot = source - 1 },
        };
    }
    return .{ .block = block, .assignments = assignments };
}

fn faultKind(opcode: p.Opcode, index: usize) Error!p.Fault {
    const kinds = opcode_contract.describe(opcode).possible_wire_faults;
    return if (index < kinds.len) kinds[index] else error.InvalidTag;
}
fn writeInstruction(value: ir.Instruction, writer: *wire.Writer) Error!void {
    const header: u8 = @backingInt(value.opcode) |
        @as(u8, if (value.immediate != 0) 64 else 0) |
        @as(u8, if (value.failures.len != 0) 128 else 0);
    try writer.byte(header);
    try writer.natural(value.destination);
    if (operandCount(value.opcode)) |count| {
        if (value.operands.len != count) return error.InvalidLength;
        for (value.operands) |operand| try writer.natural(operand);
    } else try sequence.write(p.Id, value.operands, writer);
    if (header & 64 != 0) try writer.natural(value.immediate);
    if (value.failures.len == 0) return;
    if (opcode_contract.describe(
        value.opcode,
    ).failure_count_encoding == .counted) try writer.natural(value.failures.len);
    for (value.failures, 0..) |failure, index| {
        if (failure.kind != try faultKind(value.opcode, index)) return error.InvalidTag;
        try writer.natural(failure.value);
    }
}
fn readInstruction(
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    budget: *Budget,
    context: *Context,
) Error!ir.Instruction {
    const header = try reader.byte();
    const opcode = std.enums.fromInt(p.Opcode, header & 63) orelse return error.InvalidTag;
    const destination = try reader.natural();
    const operands = if (operandCount(opcode)) |count| blk: {
        try budget.account(p.Id, count);
        const operands = try allocator.alloc(p.Id, count);
        for (operands) |*operand| operand.* = try reader.natural();
        break :blk operands;
    } else try read([]const p.Id, reader, allocator, budget, context);
    const immediate = if (header & 64 != 0) try reader.natural() else 0;
    const count: usize = if (header & 128 == 0) 0 else switch (opcode_contract.describe(
        opcode,
    ).failure_count_encoding) {
        .implied_two => 2,
        .counted => try reader.count(),
        .implied_one => 1,
    };
    if (count > 2) return error.InvalidLength;
    try budget.account(p.InstructionFailure, count);
    const failures = try allocator.alloc(p.InstructionFailure, count);
    for (failures, 0..) |*failure, index| failure.* = .{
        .kind = try faultKind(opcode, index),
        .value = try reader.natural(),
    };
    return .{
        .destination = destination,
        .opcode = opcode,
        .operands = operands,
        .immediate = immediate,
        .failures = failures,
    };
}

fn operandCount(opcode: p.Opcode) ?usize {
    return switch (opcode_contract.describe(opcode).operand_encoding) {
        .fixed => |n| n,
        .counted => null,
    };
}

fn writeLiteral(value: p.Literal, writer: *wire.Writer) Error!void {
    try writer.natural(value.schema);
    try writer.natural(value.bytes.len);
    if (value.bytes.len == 8) {
        const bits = std.mem.readInt(u64, value.bytes[0..8], .little);
        var measure: wire.Writer = .{};
        try measure.natural(bits);
        const small = measure.position < 8;
        try writer.byte(@intFromBool(small));
        if (small) return writer.natural(bits);
    }
    try writer.put(value.bytes);
}
fn readLiteral(
    reader: *wire.Reader,
    allocator: std.mem.Allocator,
    budget: *Budget,
) Error!p.Literal {
    const schema = try reader.natural();
    const count = try reader.count();
    if (count == 8) switch (try reader.byte()) {
        0 => {},
        1 => {
            const bits = try reader.natural();
            try budget.account(u8, 8);
            const bytes = try allocator.alloc(u8, 8);
            std.mem.writeInt(u64, bytes[0..8], bits, .little);
            return .{ .schema = schema, .bytes = bytes };
        },
        else => return error.InvalidTag,
    };
    return .{ .schema = schema, .bytes = try reader.take(count) };
}
