// Copyright (c) 2026 Boundary contributors. MIT license.
//! Staged source construction. Zig emit functions build terms and lexical lambdas;
//! their native bodies are never inspected or translated.
const std = @import("std");
pub const component = @import("source/component.zig");
pub const component_examples = @import("source/component_examples.zig");
const data = @import("horos_data");
const p = data.program;
pub const ast = @import("source/ast.zig");
pub const Id = p.Id;
pub const Module = ast.Module;
pub const Compiled = @import("source/activation_lower.zig").Construction;
pub const RecoveryBinding = @import("source/activation_lower.zig").RecoveryBinding;
pub const recovery = @import("source/recovery.zig");
pub const examples = @import("source/examples.zig");
pub const lower = @import("source/activation_lower.zig").lower;
/// Direct stable-slot construction with BPI3 encoding and pure admission.
pub const lowerObserved = @import("source/activation_lower.zig").lowerObserved;
pub const Diagnostic = @import("source/diagnostic.zig").Diagnostic;
pub const CompileOptions = @import("source/diagnostic.zig").Options;
pub const CompileStage = @import("source/diagnostic.zig").Stage;
pub const Error = data.closed_compilation.Error ||
    data.admission.Error ||
    data.activation_flow.Error ||
    error{ UndefinedFunction, InvalidSource, UnboundVariable };

/// Application.emit constructs a checked source Module. Its Zig body runs only
/// while authoring; the result contains all executable code as portable data.
pub fn emit(allocator: std.mem.Allocator, comptime Application: type) !Compiled {
    var builder = Builder.init(allocator);
    defer builder.deinit();
    return lower(allocator, try Application.emit(&builder));
}

pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    schemas: std.ArrayList(p.Schema) = .empty,
    constants: std.ArrayList(p.Literal) = .empty,
    effects: std.ArrayList(p.Effect) = .empty,
    handlers: std.ArrayList(p.Handler) = .empty,
    resources: std.ArrayList(p.Resource) = .empty,
    variables: std.ArrayList(p.Id) = .empty,
    values: std.ArrayList(ast.Value) = .empty,
    terms: std.ArrayList(ast.Term) = .empty,
    functions: std.ArrayList(ast.Function) = .empty,
    region_count: p.Id = 0,
    specializations: std.StringHashMapUnmanaged(*const anyopaque) = .empty,

    pub fn init(parent_allocator: std.mem.Allocator) Builder {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_allocator) };
    }
    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn allocator(self: *Builder) std.mem.Allocator {
        return self.arena.allocator();
    }
    /// Staged type/effect evidence selects one shared declaration set. Runtime
    /// arguments and handler installation state are supplied to the emitted
    /// computations; they do not belong in specialization evidence.
    pub fn specialization(
        self: *Builder,
        comptime Result: type,
        comptime template: []const u8,
        evidence: anytype,
    ) Error!Specialization(Result) {
        const key = try std.json.Stringify.valueAlloc(
            self.allocator(),
            .{
                .template = template,
                .result = @typeName(Result),
                .evidence_type = @typeName(@TypeOf(evidence)),
                .evidence = evidence,
            },
            .{},
        );
        if (self.specializations.get(key)) |pointer| {
            self.allocator().free(key);
            const cached_result: *const Result = @ptrCast(@alignCast(pointer));
            return .{ .key = &.{}, .cached = cached_result.* };
        }
        return .{ .key = key, .cached = null };
    }
    pub fn schema(self: *Builder, shape: p.Schema) Error!p.Id {
        for (self.schemas.items, 0..) |present, id| if (equal(p.Schema, present, shape)) return id;
        const id = self.schemas.items.len;
        try self.schemas.append(self.allocator(), try own(p.Schema, self.allocator(), shape));
        return id;
    }
    /// Reserve a recursive type binder. An unfilled binder is uninhabited and
    /// rejected by admission; it cannot silently acquire a scalar representation.
    pub fn reserveSchema(self: *Builder) Error!p.Id {
        const id = self.schemas.items.len;
        try self.schemas.append(self.allocator(), .{ .sum = &.{} });
        return id;
    }
    pub fn defineSchema(self: *Builder, id: p.Id, shape: p.Schema) Error!void {
        if (id >= self.schemas.items.len or self.schemas.items[
            @intCast(id)
        ] != .sum or self.schemas.items[
            @intCast(id)
        ].sum.len != 0) return error.InvalidSource;
        self.schemas.items[@intCast(id)] = try own(p.Schema, self.allocator(), shape);
    }
    pub fn primitive(
        self: *Builder,
        schema_id: p.Id,
        opcode: p.Opcode,
        operands: []const p.Id,
        immediate: p.Id,
    ) Error!p.Id {
        return self.value(.{
            .schema = schema_id,
            .expression = .{ .primitive = .{
                .opcode = opcode,
                .operands = operands,
                .immediate = immediate,
            } },
        });
    }
    pub fn cloneResumption(self: *Builder, owned: p.Id, template_schema: p.Id) Error!p.Id {
        return self.primitive(template_schema, .clone_resumption, &.{owned}, 0);
    }
    pub fn failureLiteral(self: *const Builder, value_id: p.Id) Error!p.Id {
        if (value_id >= self.values.items.len or self.values.items[
            @intCast(value_id)
        ].expression != .literal) return error.InvalidSource;
        return self.values.items[@intCast(value_id)].expression.literal;
    }
    pub fn scalar(self: *Builder, comptime T: type) Error!p.Id {
        return self.schema(switch (T) {
            void => .unit,
            bool => .boolean,
            i8 => .i8,
            i16 => .i16,
            i32 => .i32,
            i64 => .i64,
            u8 => .u8,
            u16 => .u16,
            u32 => .u32,
            u64 => .u64,
            else => @compileError("use schema() for structured portable types"),
        });
    }
    pub fn literal(self: *Builder, wanted: p.Literal) Error!p.Id {
        var id: p.Id = self.constants.items.len;
        for (self.constants.items, 0..) |present, index| if (equal(p.Literal, present, wanted)) {
            id = index;
            break;
        };
        if (id == self.constants.items.len) try self.constants.append(
            self.allocator(),
            try own(p.Literal, self.allocator(), wanted),
        );
        return self.value(.{ .schema = wanted.schema, .expression = .{ .literal = id } });
    }
    pub fn constant(self: *Builder, comptime T: type, value_item: T) Error!p.Id {
        const schema_id = try self.scalar(T);
        var bytes = @as([8]u8, @splat(0));
        if (T == bool) bytes[0] = @intFromBool(value_item) else if (T != void) std.mem.writeInt(
            T,
            bytes[0..@sizeOf(T)],
            value_item,
            .little,
        );
        return self.literal(.{
            .schema = schema_id,
            .bytes = bytes[0..data.scalar.width(self.schemas.items[@intCast(schema_id)]).?],
        });
    }
    pub fn variable(self: *Builder, schema_id: p.Id) Error!p.Id {
        const id = self.variables.items.len;
        try self.variables.append(self.allocator(), schema_id);
        return id;
    }
    pub fn reference(self: *Builder, variable_id: p.Id) Error!p.Id {
        if (variable_id >= self.variables.items.len) return error.InvalidReference;
        return self.value(.{
            .schema = self.variables.items[@intCast(variable_id)],
            .expression = .{ .variable = variable_id },
        });
    }
    pub fn value(self: *Builder, expression: ast.Value) Error!p.Id {
        const id = self.values.items.len;
        try self.values.append(self.allocator(), try own(ast.Value, self.allocator(), expression));
        return id;
    }
    pub fn term(self: *Builder, expression: ast.Term) Error!p.Id {
        const id = self.terms.items.len;
        try self.terms.append(self.allocator(), try own(ast.Term, self.allocator(), expression));
        return id;
    }
    pub fn pure(self: *Builder, value_id: p.Id) Error!p.Id {
        return self.term(.{ .value = value_id });
    }
    pub fn bind(self: *Builder, variable_id: p.Id, first: p.Id, next: p.Id) Error!p.Id {
        return self.term(.{ .bind = .{ .variable = variable_id, .value = first, .next = next } });
    }
    pub fn declare(
        self: *Builder,
        parameters: []const p.Id,
        result: p.Id,
        effects: []const p.Id,
        regions: []const p.Id,
    ) Error!p.Id {
        const variables = try self.allocator().alloc(p.Id, parameters.len);
        for (
            variables,
            parameters,
        ) |*variable_id, schema_id| variable_id.* = try self.variable(schema_id);
        const id = self.functions.items.len;
        try self.functions.append(
            self.allocator(),
            .{
                .parameters = variables,
                .result = result,
                .effects = try self.allocator().dupe(p.Id, effects),
                .regions = try self.allocator().dupe(p.Id, regions),
            },
        );
        return id;
    }
    pub fn define(self: *Builder, function: p.Id, body: p.Id) Error!void {
        if (function >= self.functions.items.len or
            body >= self.terms.items.len or
            self.functions.items[
                @intCast(function)
            ].body != null)
            return error.InvalidSource;
        self.functions.items[@intCast(function)].body = body;
    }
    pub fn parameter(self: *const Builder, function: p.Id, index: usize) p.Id {
        return self.functions.items[@intCast(function)].parameters[index];
    }
    pub fn lambda(self: *Builder, function: p.Id, schema_id: p.Id) Error!p.Id {
        return self.value(.{ .schema = schema_id, .expression = .{ .lambda = function } });
    }
    pub fn effect(self: *Builder, signature: p.Effect) Error!p.Id {
        const id = self.effects.items.len;
        try self.effects.append(self.allocator(), try own(p.Effect, self.allocator(), signature));
        return id;
    }
    pub fn handler(self: *Builder, definition: p.Handler) Error!p.Id {
        const id = self.handlers.items.len;
        try self.handlers.append(
            self.allocator(),
            try own(p.Handler, self.allocator(), definition),
        );
        return id;
    }
    pub fn region(self: *Builder) p.Id {
        defer self.region_count += 1;
        return self.region_count;
    }
    pub fn resource(self: *Builder, representation: p.Id) Error!p.Id {
        const id = self.resources.items.len;
        try self.resources.append(
            self.allocator(),
            .{ .representation = representation, .introducers = &.{}, .eliminators = &.{} },
        );
        return self.schema(.{ .internal = .{ .abstract_resource = id } });
    }
    pub fn resourceAuthority(
        self: *Builder,
        schema_id: p.Id,
        introducers: []const p.Id,
        eliminators: []const p.Id,
    ) Error!void {
        if (schema_id >= self.schemas.items.len) return error.InvalidReference;
        const shape = self.schemas.items[@intCast(schema_id)];
        if (shape != .internal or shape.internal != .abstract_resource) return error.TypeMismatch;
        const resource_id = shape.internal.abstract_resource;
        if (resource_id >= self.resources.items.len) return error.InvalidReference;
        const descriptor = &self.resources.items[@intCast(resource_id)];
        if (descriptor.introducers.len != 0 or
            descriptor.eliminators.len != 0)
            return error.InvalidOwnership;
        descriptor.introducers = try self.allocator().dupe(p.Id, introducers);
        descriptor.eliminators = try self.allocator().dupe(p.Id, eliminators);
    }
    pub fn module(self: *const Builder, entry: p.Id, failure: p.Id) ast.Module {
        return .{
            .entry = entry,
            .failure = failure,
            .schemas = self.schemas.items,
            .constants = self.constants.items,
            .effects = self.effects.items,
            .handlers = self.handlers.items,
            .region_count = self.region_count,
            .resources = self.resources.items,
            .variables = self.variables.items,
            .values = self.values.items,
            .terms = self.terms.items,
            .functions = self.functions.items,
        };
    }
};

pub fn Specialization(comptime Result: type) type {
    return struct {
        key: []const u8,
        cached: ?Result,
        pub fn finish(self: @This(), builder: *Builder, result: Result) Error!Result {
            if (self.cached) |value| return value;
            const saved = try builder.allocator().create(Result);
            saved.* = try own(Result, builder.allocator(), result);
            try builder.specializations.put(builder.allocator(), self.key, saved);
            return saved.*;
        }
    };
}

/// Row-polymorphic Zig helpers pass a row value without inspecting its members.
pub const Row = struct {
    effects: []const p.Id,
    /// Preserve left multiplicities and add only missing right IDs, as before.
    /// Canonical sorted rows take linear work; unsorted inputs are sorted in
    /// private copies so caller-owned evidence remains unchanged.
    pub fn unionWith(self: Row, allocator: std.mem.Allocator, other: Row) Error!Row {
        _ = std.math.add(usize, self.effects.len, other.effects.len) catch return error.OutOfMemory;
        const left = try sortedRow(allocator, self.effects);
        defer if (left.owned) allocator.free(left.ids);
        const right = try sortedRow(allocator, other.effects);
        defer if (right.owned) allocator.free(right.ids);
        const count = mergeRows(left.ids, right.ids, null);
        const output = try allocator.alloc(p.Id, count);
        const written = mergeRows(left.ids, right.ids, output);
        std.debug.assert(written == count);
        return .{ .effects = output };
    }
    const SortedRow = struct { ids: []const p.Id, owned: bool };
    fn sortedRow(allocator: std.mem.Allocator, ids: []const p.Id) Error!SortedRow {
        var ordered = true;
        if (ids.len > 1) for (1..ids.len) |i| {
            if (ids[i - 1] > ids[i]) {
                ordered = false;
                break;
            }
        };
        if (ordered) return .{ .ids = ids, .owned = false };
        const copy = try allocator.dupe(p.Id, ids);
        std.mem.sort(p.Id, copy, {}, std.sort.asc(p.Id));
        return .{ .ids = copy, .owned = true };
    }
    fn mergeRows(left: []const p.Id, right: []const p.Id, output: ?[]p.Id) usize {
        var l: usize = 0;
        var r: usize = 0;
        var count: usize = 0;
        while (l < left.len or r < right.len) {
            const from_left = l < left.len and (r == right.len or left[l] <= right[r]);
            const id = if (from_left) left[l] else right[r];
            if (output) |values| values[count] = id;
            count += 1;
            if (from_left) l += 1;
            // Right duplicates, including those already represented on the
            // left, must not add another occurrence. Left duplicates survive.
            while (r < right.len and right[r] == id) r += 1;
        }
        return count;
    }
    pub fn subtract(self: Row, allocator: std.mem.Allocator, removed: Row) Error!Row {
        var values: std.ArrayList(p.Id) = .empty;
        errdefer values.deinit(allocator);
        for (self.effects) |effect| if (std.mem.indexOfScalar(
            p.Id,
            removed.effects,
            effect,
        ) == null) try values.append(allocator, effect);
        return .{ .effects = try values.toOwnedSlice(allocator) };
    }
};

pub fn own(
    comptime T: type,
    allocator: std.mem.Allocator,
    value_item: T,
) std.mem.Allocator.Error!T {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| blk: {
            if (pointer.size != .slice) @compileError("source records contain only owned slices");
            const output = try allocator.alloc(pointer.child, value_item.len);
            for (output, value_item) |*to, from| to.* = try own(pointer.child, allocator, from);
            break :blk output;
        },
        .@"struct" => blk: {
            var output: T = undefined;
            inline for (
                @typeInfo(T).@"struct".field_names,
                @typeInfo(T).@"struct".field_types,
            ) |field_name, FieldType| @field(output, field_name) = try own(
                FieldType,
                allocator,
                @field(value_item, field_name),
            );
            break :blk output;
        },
        .@"union" => blk: {
            inline for (
                @typeInfo(T).@"union".field_names,
                @typeInfo(T).@"union".field_types,
            ) |field_name, FieldType| if (std.mem.eql(
                u8,
                @tagName(value_item),
                field_name,
            )) break :blk @unionInit(
                T,
                field_name,
                try own(FieldType, allocator, @field(value_item, field_name)),
            );
            unreachable;
        },
        .optional => |optional| if (value_item) |present| try own(
            optional.child,
            allocator,
            present,
        ) else null,
        .array => |array| blk: {
            // Preserve the complete array, including any sentinel outside len.
            var output = value_item;
            for (&output, value_item) |*to, from| to.* = try own(array.child, allocator, from);
            break :blk output;
        },
        else => value_item,
    };
}
fn equal(comptime T: type, left: T, right: T) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| blk: {
            if (left.len != right.len) break :blk false;
            for (left, right) |a, b| if (!equal(pointer.child, a, b)) break :blk false;
            break :blk true;
        },
        .@"struct" => blk: {
            inline for (
                @typeInfo(T).@"struct".field_names,
                @typeInfo(T).@"struct".field_types,
            ) |field_name, FieldType| if (!equal(
                FieldType,
                @field(left, field_name),
                @field(right, field_name),
            )) break :blk false;
            break :blk true;
        },
        .@"union" => blk: {
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) break :blk false;
            inline for (
                @typeInfo(T).@"union".field_names,
                @typeInfo(T).@"union".field_types,
            ) |field_name, FieldType| if (std.mem.eql(
                u8,
                @tagName(left),
                field_name,
            )) break :blk equal(FieldType, @field(left, field_name), @field(right, field_name));
            unreachable;
        },
        .optional => if (left) |present| if (right) |other| equal(
            @typeInfo(T).optional.child,
            present,
            other,
        ) else false else right == null,
        .void => true,
        else => left == right,
    };
}

test "row merge preserves the original duplicate policy order and caller storage" {
    const a = std.testing.allocator;
    const cases = [_]Row{
        .{ .effects = &.{} },                           .{ .effects = &.{0} },
        .{ .effects = &.{ 3, 1, 1, 0 } },               .{ .effects = &.{ 2, 2, 4 } },
        .{ .effects = &.{ std.math.maxInt(p.Id), 0 } },
    };
    for (cases) |left| for (cases) |right| {
        var expected: std.ArrayList(p.Id) = .empty;
        defer expected.deinit(a);
        try expected.appendSlice(a, left.effects);
        for (right.effects) |id| if (std.mem.indexOfScalar(
            p.Id,
            expected.items,
            id,
        ) == null) try expected.append(a, id);
        std.mem.sort(p.Id, expected.items, {}, std.sort.asc(p.Id));
        const left_before = try a.dupe(p.Id, left.effects);
        defer a.free(left_before);
        const right_before = try a.dupe(p.Id, right.effects);
        defer a.free(right_before);
        const result = try left.unionWith(a, right);
        defer a.free(result.effects);
        try std.testing.expectEqualSlices(p.Id, expected.items, result.effects);
        try std.testing.expectEqualSlices(p.Id, left_before, left.effects);
        try std.testing.expectEqualSlices(p.Id, right_before, right.effects);
    };
}
fn rowAllocationAttempt(a: std.mem.Allocator) !void {
    const result = try (Row{ .effects = &.{ 4, 1, 1, 0 } }).unionWith(
        a,
        .{ .effects = &.{ 8, 2, 2, 0 } },
    );
    defer a.free(result.effects);
}
test "row merge frees every failed allocation without mutating evidence" {
    try @import("allocation_testing.zig").check(std.testing.allocator, rowAllocationAttempt, .{});
}

test "raw literal edits remain visible to subsequent lookup and existing source occurrences" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.constant(u64, 1);
    _ = try builder.constant(u64, 2);
    builder.constants.items[0].bytes = &.{ 2, 0, 0, 0, 0, 0, 0, 0 };
    const found = try builder.constant(u64, 2);
    try std.testing.expectEqual(@as(p.Id, 0), try builder.failureLiteral(found));
    builder.constants.items[0].bytes = &.{ 3, 0, 0, 0, 0, 0, 0, 0 };
    const index = builder.values.items[@intCast(found)].expression.literal;
    try std.testing.expectEqual(@as(u8, 3), builder.constants.items[@intCast(index)].bytes[0]);
}

pub const specialize = @import("source/specialize.zig");
