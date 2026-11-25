// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const p = @import("program.zig");
const wire = @import("wire.zig");
const region_admission = @import("region_admission.zig");
const resource_admission = @import("resource_admission.zig");
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const ContinuationDiagnostic = @import("diagnostic.zig").Continuation;
pub const Origins = @import("diagnostic.zig").Origins;

pub const Error = wire.Error || std.mem.Allocator.Error || error{
    InvalidSchema,
    InvalidValue,
    InvalidProgram,
    InvalidReference,
    TypeMismatch,
    InvalidEffect,
    UnsupportedProfile,
    UnsupportedInstruction,
    InvalidOwnership,
    ValueWorkLimit,
    RelationLimit,
};

pub fn spend(work: ?*u64, count: u64) error{RelationLimit}!void {
    const left = work orelse return;
    if (count > left.*) return error.RelationLimit;
    left.* -= count;
}

pub fn schemaWork(work: ?*u64, schema: p.Schema) Error!void {
    try spend(work, 1);
    switch (schema) {
        .enumeration => |items| try spend(work, items.len),
        .product, .sum => |items| try spend(work, items.len),
        .internal => |internal| switch (internal) {
            .computation => |v| {
                try spend(work, v.parameters.len);
                try spend(work, v.capture_bound.len);
            },
            .resumption => |v| try spend(work, v.capture_bound.len),
            else => {},
        },
        else => {},
    }
}

pub const SchemaFacts = struct { minimum: []const u64, exportable: []const bool };

pub fn schemaAt(catalog: []const p.Schema, id: p.Id) Error!p.Schema {
    if (id >= catalog.len) return error.InvalidSchema;
    return catalog[@intCast(id)];
}

/// Least fixed points admit productive recursive data, never unguarded cycles.
pub fn schemas(allocator: std.mem.Allocator, catalog: []const p.Schema) Error!SchemaFacts {
    return schemasWithWork(allocator, catalog, null);
}

pub fn schemasWithWork(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    work: ?*u64,
) Error!SchemaFacts {
    try spend(work, catalog.len);
    const minimum = try allocator.alloc(u64, catalog.len);
    errdefer allocator.free(minimum);
    const exportable = try allocator.alloc(bool, catalog.len);
    errdefer allocator.free(exportable);
    @memset(minimum, std.math.maxInt(u64));
    @memset(exportable, true);
    for (catalog) |schema| {
        try schemaWork(work, schema);
        try references(catalog, schema);
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (catalog, 0..) |schema, index| {
            try schemaWork(work, schema);
            const width = minimumWidth(schema, minimum);
            const public = exportableSchema(schema, exportable);
            if (width < minimum[index]) {
                minimum[index] = width;
                changed = true;
            }
            if (!public and exportable[index]) {
                exportable[index] = false;
                changed = true;
            }
        }
    }
    for (minimum) |width| if (width == std.math.maxInt(u64)) return error.InvalidSchema;
    return .{ .minimum = minimum, .exportable = exportable };
}

pub fn references(catalog: []const p.Schema, schema: p.Schema) Error!void {
    switch (schema) {
        .enumeration => |tags| {
            for (
                tags,
                0..,
            ) |tag, index| if (index != 0 and tags[index - 1] >= tag) return error.InvalidSchema;
        },
        .product, .sum => |fields| {
            for (fields) |id| _ = try schemaAt(catalog, id);
            if (schema == .sum and fields.len == 0) return error.InvalidSchema;
        },
        .seq => |id| {
            _ = try schemaAt(catalog, id);
        },
        .vector => |vector| {
            _ = try schemaAt(catalog, vector.element);
        },
        .array => |array| {
            _ = try schemaAt(catalog, array.element);
        },
        .internal => |internal| switch (internal) {
            .computation => |computation| {
                for (computation.parameters) |id| _ = try schemaAt(catalog, id);
                for (computation.capture_bound) |id| _ = try schemaAt(catalog, id);
                _ = try schemaAt(catalog, computation.result);
            },
            .resumption => |resumption| {
                _ = try schemaAt(catalog, resumption.input);
                _ = try schemaAt(catalog, resumption.answer);
                for (resumption.capture_bound) |id| _ = try schemaAt(catalog, id);
            },
            .cell => |cell| {
                _ = try schemaAt(catalog, cell.element);
            },
            .suspension_package => |id| {
                const inner = try schemaAt(catalog, id);
                if (inner != .internal or
                    inner.internal != .resumption or
                    (inner.internal.resumption.use != .linear and
                        inner.internal.resumption.use != .affine))
                    return error.InvalidSchema;
            },
            .borrowed => |borrowed| {
                _ = try schemaAt(catalog, borrowed.value);
            },
            else => {},
        },
        else => {},
    }
}

fn minimumWidth(schema: p.Schema, minimum: []const u64) u64 {
    return switch (schema) {
        .unit, .internal => 0,
        .boolean, .i8, .u8 => 1,
        .i16, .u16 => 2,
        .i32, .u32, .enumeration => 4,
        .i64, .u64 => 8,
        .bytes, .text, .bounded_bytes, .bounded_text, .seq, .vector => 1,
        .array => |array| if (array.length == 0) 0 else std.math.mul(
            u64,
            minimum[@intCast(array.element)],
            array.length,
        ) catch std.math.maxInt(u64),
        .product => |fields| blk: {
            var size: u64 = 0;
            for (fields) |id| size = std.math.add(u64, size, minimum[@intCast(id)]) catch
                break :blk std.math.maxInt(u64);
            break :blk size;
        },
        .sum => |fields| blk: {
            var size: u64 = std.math.maxInt(u64);
            for (fields) |id| size = @min(size, minimum[@intCast(id)]);
            break :blk std.math.add(u64, size, 1) catch std.math.maxInt(u64);
        },
    };
}

fn exportableSchema(schema: p.Schema, public: []const bool) bool {
    return switch (schema) {
        .internal => false,
        .product, .sum => |fields| blk: {
            for (fields) |id| if (!public[@intCast(id)]) break :blk false;
            break :blk true;
        },
        .seq => |id| public[@intCast(id)],
        .vector => |vector| public[@intCast(vector.element)],
        .array => |array| public[@intCast(array.element)],
        else => true,
    };
}

pub fn value(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    facts: SchemaFacts,
    literal: p.Literal,
) Error!void {
    return valueWithWork(allocator, catalog, facts, literal, null);
}

pub fn valueWithWork(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    facts: SchemaFacts,
    literal: p.Literal,
    work: ?*u64,
) Error!void {
    var reader: wire.Reader = .{ .input = literal.bytes };
    _ = readValueMetered(allocator, catalog, facts, literal.schema, &reader, work) catch |err|
        return if (err == error.ValueWorkLimit) error.RelationLimit else err;
    try reader.finish();
}

/// Reads one canonical value from a sequence of schema-directed arguments.
/// The returned bytes borrow the reader's input. No computation is evaluated.
pub fn readValue(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    facts: SchemaFacts,
    schema: p.Id,
    reader: *wire.Reader,
) Error![]const u8 {
    return readValueMetered(allocator, catalog, facts, schema, reader, null);
}

pub fn readValueWithWork(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    facts: SchemaFacts,
    schema: p.Id,
    reader: *wire.Reader,
    remaining: *u64,
) Error![]const u8 {
    return readValueMetered(allocator, catalog, facts, schema, reader, remaining);
}

fn valueWork(remaining: ?*u64, count: usize) Error!void {
    const left = remaining orelse return;
    if (count > left.*) return error.ValueWorkLimit;
    left.* -= @intCast(count);
}

fn readValueMetered(
    allocator: std.mem.Allocator,
    catalog: []const p.Schema,
    facts: SchemaFacts,
    schema: p.Id,
    reader: *wire.Reader,
    remaining: ?*u64,
) Error![]const u8 {
    _ = try schemaAt(catalog, schema);
    if (!facts.exportable[@intCast(schema)]) return error.InvalidValue;
    if (reader.position > reader.input.len) return error.Truncated;
    const start = reader.position;
    var pending: ValueTasks = .{ .allocator = allocator };
    defer pending.deinit();
    try valueWork(remaining, 1);
    try pending.push(.{ .schema = schema, .count = 1 });
    while (pending.pop()) |task|
        try readValueRun(catalog, facts, task, reader, &pending, remaining);
    return reader.input[start..reader.position];
}

const ValueTask = struct { schema: p.Id, count: u64 };

const ValueTasks = struct {
    allocator: std.mem.Allocator,
    local: [local_tasks_max]ValueTask = undefined,
    local_count: usize = 0,
    spilled: std.ArrayList(ValueTask) = .empty,

    const local_tasks_max = 64;

    fn deinit(self: *ValueTasks) void {
        self.spilled.deinit(self.allocator);
    }

    inline fn push(self: *ValueTasks, task: ValueTask) Error!void {
        if (self.spilled.items.len == 0 and self.local_count < local_tasks_max) {
            self.local[self.local_count] = task;
            self.local_count += 1;
        } else try self.spilled.append(self.allocator, task);
    }

    fn pop(self: *ValueTasks) ?ValueTask {
        if (self.spilled.pop()) |task| return task;
        if (self.local_count == 0) return null;
        self.local_count -= 1;
        return self.local[self.local_count];
    }
};

fn readValueRun(
    catalog: []const p.Schema,
    facts: SchemaFacts,
    first: ValueTask,
    reader: *wire.Reader,
    pending: *ValueTasks,
    remaining: ?*u64,
) Error!void {
    var next: ?ValueTask = first;
    while (next) |task| {
        const index: usize = @intCast(task.schema);
        const minimum = facts.minimum[index];
        const shape = &catalog[index];
        try valueWork(remaining, 1);
        if (task.count == 0 or minimum == 0) return;
        if (exceedsInput(reader, task.count, minimum)) return error.InvalidValue;
        if (remaining == null and integer(shape.*)) {
            reader.position += @intCast(task.count * minimum);
            return;
        }
        if (task.count > 1) try valueWork(remaining, 1);
        if (try readValueLeaf(shape, minimum, reader, remaining)) {
            next = if (task.count == 1)
                null
            else
                .{ .schema = task.schema, .count = task.count - 1 };
        } else {
            if (task.count > 1)
                try pending.push(.{ .schema = task.schema, .count = task.count - 1 });
            next = try readValueComposite(shape, reader, pending, remaining);
        }
    }
}

fn exceedsInput(reader: *const wire.Reader, count: u64, minimum: u64) bool {
    const required = std.math.mul(u64, count, minimum) catch return true;
    return required > reader.input.len - reader.position;
}

fn readValueLeaf(
    shape: *const p.Schema,
    minimum: u64,
    reader: *wire.Reader,
    remaining: ?*u64,
) Error!bool {
    switch (shape.*) {
        .unit => {},
        .boolean => {
            if (try reader.byte() > 1) return error.InvalidValue;
        },
        .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64 => {
            _ = try reader.take(@intCast(minimum));
        },
        .enumeration => |tags| {
            const bytes = try reader.take(4);
            const tag = std.mem.readInt(u32, bytes[0..4], .little);
            try valueWork(remaining, tags.len);
            if (!enumerationContains(tags, tag)) return error.InvalidValue;
        },
        .bytes => {
            _ = try reader.bytes();
        },
        .text => {
            _ = try readValueText(reader, remaining);
        },
        .bounded_bytes => |maximum| {
            if ((try reader.bytes()).len > maximum) return error.InvalidValue;
        },
        .bounded_text => |maximum| {
            if ((try readValueText(reader, remaining)).len > maximum) return error.InvalidValue;
        },
        else => return false,
    }
    return true;
}

fn enumerationContains(tags: []const u32, tag: u32) bool {
    if (tag < tags.len and tags[tag] == tag) return true;
    return std.mem.indexOfScalar(u32, tags, tag) != null;
}

fn readValueText(reader: *wire.Reader, remaining: ?*u64) Error![]const u8 {
    if (remaining != null) {
        var measured = reader.*;
        try valueWork(remaining, (try measured.bytes()).len);
    }
    return reader.text();
}

fn readValueComposite(
    shape: *const p.Schema,
    reader: *wire.Reader,
    pending: *ValueTasks,
    remaining: ?*u64,
) Error!?ValueTask {
    try valueWork(remaining, if (shape.* == .product) shape.product.len else 1);
    switch (shape.*) {
        .product => |fields| {
            if (fields.len == 0) return null;
            var i = fields.len;
            while (i != 1) {
                i -= 1;
                try pending.push(.{ .schema = fields[i], .count = 1 });
            }
            return .{ .schema = fields[0], .count = 1 };
        },
        .sum => |fields| {
            const tag = try reader.count();
            if (tag >= fields.len) return error.InvalidValue;
            return .{ .schema = fields[tag], .count = 1 };
        },
        .seq => |element| return .{ .schema = element, .count = try reader.natural() },
        .vector => |vector| {
            const count = try reader.natural();
            if (count > vector.maximum) return error.InvalidValue;
            return .{ .schema = vector.element, .count = count };
        },
        .array => |array| return .{ .schema = array.element, .count = array.length },
        else => return error.InvalidValue,
    }
}

pub fn slotType(slots: []const p.Id, id: p.Id) Error!p.Id {
    if (id >= slots.len) return error.InvalidReference;
    return slots[@intCast(id)];
}

pub fn arguments(slots: []const p.Id, supplied: []const p.Id, expected: []const p.Id) Error!void {
    return argumentsWithWork(slots, supplied, expected, null);
}

pub fn argumentsWithWork(
    slots: []const p.Id,
    supplied: []const p.Id,
    expected: []const p.Id,
    work: ?*u64,
) Error!void {
    try spend(work, supplied.len);
    if (supplied.len != expected.len) return error.TypeMismatch;
    for (
        supplied,
        expected,
    ) |slot, schema| if (try slotType(slots, slot) != schema) return error.TypeMismatch;
}

pub fn edge(
    image: @import("activation.zig").Program,
    owner: p.Id,
    slots: []const p.Id,
    next: @import("activation.zig").Edge,
    returned: ?p.Id,
) Error!void {
    return edgeWithWork(image, owner, slots, next, returned, null);
}

pub fn edgeWithWork(
    image: @import("activation.zig").Program,
    owner: p.Id,
    slots: []const p.Id,
    next: @import("activation.zig").Edge,
    returned: ?p.Id,
    work: ?*u64,
) Error!void {
    try spend(work, next.assignments.len);
    if (next.block >= image.blocks.len) return error.InvalidReference;
    if (image.blocks[@intCast(next.block)].function != owner) return error.TypeMismatch;
    for (next.assignments) |assignment| {
        const expected = try slotType(slots, assignment.destination);
        const actual = switch (assignment.source) {
            .slot => |slot| try slotType(slots, slot),
            .returned => returned orelse return error.TypeMismatch,
        };
        if (actual != expected) return error.TypeMismatch;
    }
}

pub fn validateInstruction(
    image: anytype,
    function: p.Id,
    instruction: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
) Error!void {
    return validateInstructionWithWork(image, function, instruction, slots, uses, null);
}

pub fn validateInstructionWithWork(
    image: anytype,
    function: p.Id,
    instruction: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
    work: ?*u64,
) Error!void {
    switch (instruction.opcode) {
        .resource_pack, .resource_unpack => {
            try spend(work, instruction.failures.len);
            try instructionFailures(image, instruction, slots);
            try resource_admission.instructionWithWork(image, function, instruction, slots, work);
        },
        else => try validateInstructionShapeWithWork(image, instruction, slots, uses, work),
    }
}

pub fn validateInstructionShape(
    image: anytype,
    instruction: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
) Error!void {
    return validateInstructionShapeWithWork(image, instruction, slots, uses, null);
}

pub fn validateInstructionShapeWithWork(
    image: anytype,
    instruction: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
    work: ?*u64,
) Error!void {
    try spend(work, instruction.operands.len);
    try spend(work, instruction.failures.len);
    try instructionFailures(image, instruction, slots);
    return validateShape(image, instruction, slots, uses, work);
}

fn validateShape(
    image: anytype,
    instruction: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
    work: ?*u64,
) Error!void {
    switch (instruction.opcode) {
        .constant,
        .move,
        .integer_add,
        .integer_sub,
        .integer_mul,
        .integer_div,
        .integer_rem,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .equal,
        .less,
        .integer_bit_not,
        .integer_convert,
        .enum_tag,
        .boolean_not,
        => try scalarInstruction(image, instruction, slots),
        .computation, .package, .unpack, .clone_resumption => try internalInstruction(
            image,
            instruction,
            slots,
            work,
        ),
        .product,
        .field,
        .variant,
        .variant_tag,
        .variant_payload,
        .select,
        .sequence,
        .sequence_length,
        .sequence_get,
        .sequence_append,
        .sequence_concat,
        .sequence_pop,
        .sequence_set,
        .sequence_take,
        .sequence_pop_last,
        => try @import("aggregate_admission.zig").instruction(image, instruction, slots),
        .blob_length,
        .blob_concat,
        .blob_slice,
        .blob_compare,
        .blob_byte,
        .text_scalar,
        .text_integer,
        .blob_from_byte,
        => try @import("blob_admission.zig").instruction(image, instruction, slots),
        .cell_new, .cell_get, .cell_set => try region_admission.instructionWithWork(
            image,
            instruction,
            slots,
            uses,
            work,
        ),
        .resource_pack, .resource_unpack => _ = try resource_admission.instructionShape(
            image,
            instruction,
            slots,
        ),
    }
}

fn internalInstruction(
    image: anytype,
    instruction: anytype,
    slots: []const p.Id,
    work: ?*u64,
) Error!void {
    const operands = instruction.operands;
    const result = instruction.result_type;
    switch (instruction.opcode) {
        .computation => {
            if (instruction.immediate >= image.constructors.len) return error.InvalidReference;
            const constructor = image.constructors[@intCast(instruction.immediate)];
            if (constructor.schema != result) return error.TypeMismatch;
            try arguments(
                slots,
                operands,
                image.scopes.captures[@intCast(constructor.capture)].fields,
            );
        },
        .package, .unpack => {
            if (operands.len != 1 or instruction.immediate != 0) return error.InvalidProgram;
            const input = slots[@intCast(operands[0])];
            const shape = image.schemas[
                @intCast(if (instruction.opcode == .package) result else input)
            ];
            if (shape != .internal or
                shape.internal != .suspension_package or
                shape.internal.suspension_package != (if (instruction.opcode == .package)
                    input
                else
                    result))
                return error.TypeMismatch;
        },
        .clone_resumption => {
            if (operands.len != 1 or instruction.immediate != 0) return error.InvalidProgram;
            if (!try @import("contracts.zig").cloneCompatibleWithWork(
                image,
                slots[@intCast(operands[0])],
                result,
                work,
            )) return error.InvalidOwnership;
        },
        else => return error.UnsupportedInstruction,
    }
}

fn scalarInstruction(image: anytype, instruction: anytype, slots: []const p.Id) Error!void {
    const operands = instruction.operands;
    const result = instruction.result_type;
    switch (instruction.opcode) {
        .constant => {
            if (operands.len != 0 or
                instruction.immediate >= image.constants.len)
                return error.InvalidReference;
            if (image.constants[
                @intCast(instruction.immediate)
            ].schema != result) return error.TypeMismatch;
        },
        .move => {
            if (operands.len != 1 or instruction.immediate != 0) return error.InvalidProgram;
            if (slots[@intCast(operands[0])] != result) return error.TypeMismatch;
        },
        .integer_add,
        .integer_sub,
        .integer_mul,
        .integer_div,
        .integer_rem,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .equal,
        .less,
        => {
            try binaryInstruction(image, instruction, slots);
        },
        .integer_bit_not, .integer_convert, .enum_tag => {
            if (operands.len != 1 or instruction.immediate != 0) return error.InvalidProgram;
            const source_id = slots[@intCast(operands[0])];
            const source = image.schemas[@intCast(source_id)];
            const target = image.schemas[@intCast(result)];
            if (instruction.opcode == .enum_tag) {
                if (source != .enumeration or target != .u32) return error.TypeMismatch;
            } else {
                if (!integer(source) or !integer(target)) return error.TypeMismatch;
                if (instruction.opcode == .integer_bit_not and
                    source_id != result)
                    return error.TypeMismatch;
            }
        },
        .boolean_not => {
            if (operands.len != 1 or instruction.immediate != 0) return error.InvalidProgram;
            if (image.schemas[
                @intCast(result)
            ] != .boolean or slots[
                @intCast(operands[0])
            ] != result) return error.TypeMismatch;
        },
        else => return error.UnsupportedInstruction,
    }
}

fn binaryInstruction(image: anytype, instruction: anytype, slots: []const p.Id) Error!void {
    const operands = instruction.operands;
    const result = instruction.result_type;
    if (operands.len != 2 or instruction.immediate != 0) return error.InvalidProgram;
    const left = slots[@intCast(operands[0])];
    if (left != slots[@intCast(operands[1])]) return error.TypeMismatch;
    if (!integer(
        image.schemas[
            @intCast(left)
        ],
    ) and !(instruction.opcode == .equal and image.schemas[
        @intCast(left)
    ] == .boolean)) return error.TypeMismatch;
    const comparison = instruction.opcode == .equal or instruction.opcode == .less;
    if (comparison) {
        if (image.schemas[@intCast(result)] != .boolean) return error.TypeMismatch;
    } else if (result != left) return error.TypeMismatch;
}

fn instructionFailures(image: anytype, instruction: anytype, slots: []const p.Id) Error!void {
    const needed: []const p.Fault = switch (instruction.opcode) {
        .integer_add, .integer_sub, .integer_mul => &.{.arithmetic_overflow},
        .integer_convert => if (instruction.operands.len == 1 and !@import(
            "scalar.zig",
        ).conversionCanFail(
            image.schemas[@intCast(slots[@intCast(instruction.operands[0])])],
            image.schemas[@intCast(instruction.result_type)],
        )) &.{} else &.{.arithmetic_overflow},
        .integer_div, .integer_rem => &.{ .arithmetic_overflow, .division_by_zero },
        .sequence_set => &.{.invalid_index},
        .variant_payload => &.{.invalid_variant},
        .sequence_append, .sequence_concat => if (image.schemas[
            @intCast(instruction.result_type)
        ] == .vector) &.{.capacity_exceeded} else &.{},
        .blob_concat => &.{.capacity_exceeded},
        .blob_slice => if (@import("blob_admission.zig").isText(
            image.schemas[
                @intCast(instruction.result_type)
            ],
        )) &.{ .capacity_exceeded, .invalid_utf8 } else &.{.capacity_exceeded},
        .text_scalar => &.{.invalid_utf8},
        else => &.{},
    };
    if (instruction.failures.len != needed.len) return error.InvalidProgram;
    for (instruction.failures, needed) |failure, kind| {
        if (failure.kind != kind or
            failure.value >= image.constants.len)
            return error.InvalidProgram;
        if (image.constants[
            @intCast(failure.value)
        ].schema != image.roots.failure) return error.TypeMismatch;
    }
}

pub fn integer(schema: p.Schema) bool {
    return switch (schema) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
        else => false,
    };
}
