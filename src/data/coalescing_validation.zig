// Copyright (c) 2026 Boundary contributors. MIT license.
//! Raw-record correspondence checks, independent of discovery keys and rewriting.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const witness = @import("coalescing_witness.zig");
const equal = @import("record.zig").equal;
const Diagnostic = @import("admission.zig").Diagnostic;
pub const Error = witness.Error;

fn require(ok: bool) Error!void {
    if (!ok) return error.InvalidCorrespondence;
}

// A new field cannot silently inherit structural equality or be omitted.
fn fields(comptime T: type, comptime names: []const []const u8) void {
    const actual = @typeInfo(T).@"struct".field_names;
    if (actual.len != names.len) @compileError("classify new coalescing field: " ++ @typeName(T));
    for (actual, names) |field_name, name|
        if (!std.mem.eql(u8, field_name, name))
            @compileError("classify changed coalescing field: " ++ @typeName(T));
}

/// Check actual emitted records against an admitted live original and a temporary
/// correspondence. This establishes structural preservation, not output admission.
/// Output admission must still derive fresh ownership/borrow facts before publication.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: witness.Witness,
) Error!void {
    return validateDiagnosed(allocator, original, candidate, map, null);
}

/// Locations refer to the current round's original records, never discovery keys.
pub fn validateDiagnosed(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    map: witness.Witness,
    diagnostic: ?*Diagnostic,
) Error!void {
    if (diagnostic) |d| d.* = .{};
    try witness.checkDomains(allocator, original, candidate, map);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const check: Check = .{
        .allocator = arena.allocator(),
        .maps = map.final,
        .diagnostic = diagnostic,
    };
    comptime fields(ir.Program, &.{
        "roots",    "schemas", "constants",    "effects", "functions", "blocks",
        "handlers", "scopes",  "constructors",
    });
    comptime fields(p.Roots, &.{ "profile", "entry", "result", "failure" });
    try require(original.roots.profile == candidate.roots.profile);
    try check.ref(.function, original.roots.entry, candidate.roots.entry);
    try check.ref(.schema, original.roots.result, candidate.roots.result);
    try check.ref(.schema, original.roots.failure, candidate.roots.failure);
    try checkCatalogues(check, original, candidate);
    for (original.functions, map.locals, 0..) |function, local, id| {
        if (diagnostic) |d| d.* = .{ .phase = .function, .function = id };
        try check.function(function, candidate.functions[try check.id(.function, id)], local);
    }
    for (original.blocks, 0..) |block, id| {
        if (diagnostic) |d| d.* = .{ .phase = .block, .function = block.function, .block = id };
        if (block.function >= map.locals.len) return error.InvalidCorrespondence;
        const local: Body = .{ .check = check, .local = map.locals[@intCast(block.function)] };
        try local.block(block, candidate.blocks[try check.id(.block, id)]);
    }
}

fn checkCatalogues(check: Check, original: ir.Program, candidate: ir.Program) Error!void {
    inline for (.{
        .{ r.Kind.schema, "schemas", Check.schema },
        .{ r.Kind.constant, "constants", Check.literal },
        .{ r.Kind.effect, "effects", Check.effect },
        .{ r.Kind.handler, "handlers", Check.handler },
        .{ r.Kind.constructor, "constructors", Check.constructor },
    }) |item| for (@field(original, item[1]), 0..) |record, id| {
        if (check.diagnostic) |d| d.* = switch (item[0]) {
            .schema => .{ .phase = .schema, .schema = id },
            .constant => .{ .phase = .constant },
            .effect => .{ .phase = .effect, .effect = id },
            .handler => .{ .phase = .handler, .handler = id },
            .constructor => .{
                .phase = .constructor,
                .function = record.function,
                .capture = record.capture,
                .schema = record.schema,
            },
            else => @compileError("classify new coalescing catalogue diagnostic"),
        };
        try item[2](check, record, @field(candidate, item[1])[try check.id(item[0], id)]);
    };
    comptime fields(p.ScopeCatalog, &.{ "captures", "region_count", "resources" });
    for (original.scopes.captures, 0..) |record, id| {
        if (check.diagnostic) |d| d.* = .{ .phase = .capture, .capture = id };
        try check.capture(record, candidate.scopes.captures[try check.id(.capture, id)]);
    }
    for (original.scopes.resources, 0..) |record, id| {
        if (check.diagnostic) |d| d.* = .{ .phase = .region };
        try check.resource(record, candidate.scopes.resources[try check.id(.resource, id)]);
    }
}

const Check = struct {
    allocator: std.mem.Allocator,
    maps: r.Maps,
    diagnostic: ?*Diagnostic = null,

    fn id(self: Check, kind: r.Kind, old: p.Id) Error!usize {
        const map = self.maps[@backingInt(kind)];
        if (old >= map.len) return error.InvalidCorrespondence;
        return std.math.cast(usize, map[@intCast(old)]) orelse error.InvalidCorrespondence;
    }
    fn ref(self: Check, kind: r.Kind, old: p.Id, new: p.Id) Error!void {
        try require(try self.id(kind, old) == new);
    }
    fn ids(self: Check, kind: r.Kind, old: []const p.Id, new: []const p.Id, set: bool) Error!void {
        const mapped = try self.allocator.alloc(p.Id, old.len);
        for (mapped, old) |*target, source| target.* = try self.id(kind, source);
        var length = mapped.len;
        if (set) {
            std.mem.sort(p.Id, mapped, {}, std.sort.asc(p.Id));
            length = 0;
            for (mapped) |value| if (length == 0 or mapped[length - 1] != value) {
                mapped[length] = value;
                length += 1;
            };
        }
        try require(std.mem.eql(p.Id, mapped[0..length], new));
    }
    fn schema(self: Check, old: p.Schema, new: p.Schema) Error!void {
        try require(std.meta.activeTag(old) == std.meta.activeTag(new));
        switch (old) {
            .unit,
            .boolean,
            .i8,
            .i16,
            .i32,
            .i64,
            .u8,
            .u16,
            .u32,
            .u64,
            .bytes,
            .text,
            .bounded_bytes,
            .bounded_text,
            .enumeration,
            => try require(equal(p.Schema, old, new)),
            .product => |v| try self.ids(.schema, v, new.product, false),
            .sum => |v| try self.ids(.schema, v, new.sum, false),
            .seq => |v| try self.ref(.schema, v, new.seq),
            .vector => |v| {
                comptime fields(@TypeOf(v), &.{ "element", "maximum" });
                try require(v.maximum == new.vector.maximum);
                try self.ref(.schema, v.element, new.vector.element);
            },
            .array => |v| {
                comptime fields(@TypeOf(v), &.{ "element", "length" });
                try require(v.length == new.array.length);
                try self.ref(.schema, v.element, new.array.element);
            },
            .internal => |v| try self.internal(v, new.internal),
        }
    }
    fn internal(self: Check, old: p.Internal, new: p.Internal) Error!void {
        try require(std.meta.activeTag(old) == std.meta.activeTag(new));
        switch (old) {
            .computation => |v| try self.computation(v, new.computation),
            .resumption => |v| try self.resumption(v, new.resumption),
            .capability => |v| try self.ref(.effect, v, new.capability),
            .region => |v| try self.ref(.region, v, new.region),
            .abstract_resource => |v| try self.ref(.resource, v, new.abstract_resource),
            .suspension_package => |v| try self.ref(.schema, v, new.suspension_package),
            .cell => |v| {
                comptime fields(@TypeOf(v), &.{ "element", "region" });
                try self.ref(.schema, v.element, new.cell.element);
                try self.ref(.region, v.region, new.cell.region);
            },
            .borrowed => |v| {
                comptime fields(@TypeOf(v), &.{ "value", "region" });
                try self.ref(.schema, v.value, new.borrowed.value);
                try self.ref(.region, v.region, new.borrowed.region);
            },
        }
    }
    fn computation(self: Check, old: p.ComputationType, new: p.ComputationType) Error!void {
        comptime fields(p.ComputationType, &.{
            "parameters", "result", "effects", "capture_bound", "use", "regions",
        });
        try require(old.use == new.use);
        try self.ids(.schema, old.parameters, new.parameters, false);
        try self.ref(.schema, old.result, new.result);
        try self.ids(.effect, old.effects, new.effects, true);
        try self.ids(.schema, old.capture_bound, new.capture_bound, true);
        try self.ids(.region, old.regions, new.regions, true);
    }
    fn resumption(self: Check, old: p.ResumptionType, new: p.ResumptionType) Error!void {
        comptime fields(p.ResumptionType, &.{
            "effect",   "input", "answer", "effects",       "capture_bound", "handled",
            "escaping", "mode",  "use",    "owned_regions", "obligations",
        });
        try require(old.mode == new.mode and old.use == new.use and
            old.obligations == new.obligations);
        try self.ref(.effect, old.effect, new.effect);
        try self.ref(.schema, old.input, new.input);
        try self.ref(.schema, old.answer, new.answer);
        try self.ids(.effect, old.effects, new.effects, true);
        try self.ids(.schema, old.capture_bound, new.capture_bound, true);
        try self.ids(.effect, old.handled, new.handled, false);
        try self.ids(.effect, old.escaping, new.escaping, true);
        try self.ids(.region, old.owned_regions, new.owned_regions, true);
    }
    fn literal(self: Check, old: p.Literal, new: p.Literal) Error!void {
        comptime fields(p.Literal, &.{ "schema", "bytes" });
        try self.ref(.schema, old.schema, new.schema);
        try require(std.mem.eql(u8, old.bytes, new.bytes));
    }
    fn effect(self: Check, old: p.Effect, new: p.Effect) Error!void {
        comptime fields(p.Effect, &.{
            "identity",         "payload", "result",
            "use_site_effects", "bodies",  "control_use",
            "external",
        });
        try require(std.mem.eql(u8, old.identity, new.identity) and
            old.control_use == new.control_use and old.external == new.external);
        try self.ref(.schema, old.payload, new.payload);
        try self.ref(.schema, old.result, new.result);
        try self.ids(.effect, old.use_site_effects, new.use_site_effects, false);
        try self.ids(.schema, old.bodies, new.bodies, false);
    }
    fn capture(self: Check, old: p.Capture, new: p.Capture) Error!void {
        comptime fields(p.Capture, &.{ "fields", "owned_regions", "borrowed_regions", "use" });
        try require(old.use == new.use);
        try require(old.fields.len == new.fields.len);
        for (old.fields, new.fields, 0..) |source, target, index| {
            if (self.diagnostic) |d| d.field = index;
            try self.ref(.schema, source, target);
        }
        if (self.diagnostic) |d| d.field = null;
        try self.ids(.region, old.owned_regions, new.owned_regions, true);
        try self.ids(.region, old.borrowed_regions, new.borrowed_regions, true);
    }
    fn constructor(self: Check, old: p.Constructor, new: p.Constructor) Error!void {
        comptime fields(p.Constructor, &.{ "function", "capture", "schema" });
        try self.ref(.function, old.function, new.function);
        try self.ref(.capture, old.capture, new.capture);
        try self.ref(.schema, old.schema, new.schema);
    }
    fn resource(self: Check, old: p.Resource, new: p.Resource) Error!void {
        comptime fields(p.Resource, &.{ "representation", "introducers", "eliminators" });
        try self.ref(.schema, old.representation, new.representation);
        try self.ids(.function, old.introducers, new.introducers, true);
        try self.ids(.function, old.eliminators, new.eliminators, true);
    }
    fn handler(self: Check, old: ir.Handler, new: ir.Handler) Error!void {
        comptime fields(ir.Handler, &.{
            "mode", "input", "answer", "return_function", "clauses", "state", "effects",
        });
        comptime fields(ir.Clause, &.{ "effect", "function", "resumption", "strategy" });
        try require(old.mode == new.mode and old.clauses.len == new.clauses.len);
        try self.ref(.schema, old.input, new.input);
        try self.ref(.schema, old.answer, new.answer);
        try self.ref(.function, old.return_function, new.return_function);
        try self.ids(.schema, old.state, new.state, false);
        try self.ids(.effect, old.effects, new.effects, true);
        for (old.clauses, new.clauses) |a, b| {
            try require(a.strategy == b.strategy);
            try self.ref(.effect, a.effect, b.effect);
            try self.ref(.function, a.function, b.function);
            try self.ref(.schema, a.resumption, b.resumption);
        }
    }
    fn function(self: Check, old: ir.Function, new: ir.Function, local: witness.Local) Error!void {
        comptime fields(ir.Function, &.{
            "entry", "inputs", "layout", "custody", "result", "effects", "regions",
        });
        comptime fields(ir.Layout, &.{"slots"});
        comptime fields(ir.CustodyScope, &.{"parent"});
        const body: Body = .{ .check = self, .local = local };
        try self.ref(.block, old.entry, new.entry);
        try body.slots(old.inputs, new.inputs);
        try self.ref(.schema, old.result, new.result);
        try self.ids(.effect, old.effects, new.effects, true);
        try self.ids(.region, old.regions, new.regions, true);
        for (old.layout.slots, local.slots) |schema_id, slot|
            try self.ref(.schema, schema_id, new.layout.slots[@intCast(slot)]);
        for (old.custody, local.custody) |scope, scope_id| {
            const target = new.custody[@intCast(scope_id)].parent;
            try require((scope.parent == null) == (target == null));
            if (scope.parent) |parent|
                try require(try localId(local.custody, parent) == target.?);
        }
    }
};

fn localId(map: []const p.Id, id: p.Id) Error!p.Id {
    if (id >= map.len) return error.InvalidCorrespondence;
    return map[@intCast(id)];
}

const Body = struct {
    check: Check,
    local: witness.Local,

    fn slot(self: Body, old: p.Id, new: p.Id) Error!void {
        if (self.check.diagnostic) |d| d.slot = old;
        try require(try localId(self.local.slots, old) == new);
        if (self.check.diagnostic) |d| d.slot = null;
    }
    fn optionalSlot(self: Body, old: ?p.Id, new: ?p.Id) Error!void {
        try require((old == null) == (new == null));
        if (old) |id| try self.slot(id, new.?);
    }
    fn slots(self: Body, old: []const p.Id, new: []const p.Id) Error!void {
        try require(old.len == new.len);
        for (old, new) |a, b| try self.slot(a, b);
    }
    fn edge(self: Body, old: ir.Edge, new: ir.Edge) Error!void {
        comptime fields(ir.Edge, &.{ "block", "assignments" });
        comptime fields(ir.Assignment, &.{ "destination", "source" });
        try self.check.ref(.block, old.block, new.block);
        try require(old.assignments.len == new.assignments.len);
        for (old.assignments, new.assignments) |a, b| {
            try self.slot(a.destination, b.destination);
            try require(std.meta.activeTag(a.source) == std.meta.activeTag(b.source));
            switch (a.source) {
                .returned => {},
                .slot => |id| try self.slot(id, b.source.slot),
            }
        }
    }
    fn block(self: Body, old: ir.Block, new: ir.Block) Error!void {
        comptime fields(ir.Block, &.{ "function", "custody", "instructions", "terminator" });
        try self.check.ref(.function, old.function, new.function);
        try require(try localId(self.local.custody, old.custody) == new.custody);
        try require(old.instructions.len == new.instructions.len);
        for (old.instructions, new.instructions, 0..) |a, b, index| {
            if (self.check.diagnostic) |d| d.instruction = index;
            try self.instruction(a, b);
        }
        if (self.check.diagnostic) |d| {
            d.instruction = null;
            d.terminator = std.meta.activeTag(old.terminator);
        }
        try self.terminator(old.terminator, new.terminator);
    }
    fn instruction(self: Body, old: ir.Instruction, new: ir.Instruction) Error!void {
        comptime fields(ir.Instruction, &.{
            "destination", "opcode", "operands", "immediate", "failures",
        });
        comptime fields(p.InstructionFailure, &.{ "kind", "value" });
        try require(old.opcode == new.opcode and old.failures.len == new.failures.len);
        try self.slot(old.destination, new.destination);
        try self.slots(old.operands, new.operands);
        for (old.failures, new.failures) |a, b| {
            try require(a.kind == b.kind);
            try self.check.ref(.constant, a.value, b.value);
        }
        switch (old.opcode) {
            .constant => try self.check.ref(.constant, old.immediate, new.immediate),
            .computation => try self.check.ref(.constructor, old.immediate, new.immediate),
            .move,
            .integer_add,
            .integer_sub,
            .integer_mul,
            .integer_div,
            .equal,
            .less,
            .boolean_not,
            .product,
            .field,
            .variant,
            .variant_tag,
            .variant_payload,
            .sequence,
            .sequence_length,
            .sequence_get,
            .sequence_append,
            .sequence_concat,
            .sequence_pop,
            .cell_new,
            .cell_get,
            .cell_set,
            .clone_resumption,
            .package,
            .unpack,
            .resource_pack,
            .resource_unpack,
            .integer_rem,
            .integer_bit_not,
            .integer_bit_and,
            .integer_bit_or,
            .integer_bit_xor,
            .integer_convert,
            .enum_tag,
            .blob_length,
            .blob_concat,
            .blob_slice,
            .blob_compare,
            .blob_byte,
            .text_scalar,
            .text_integer,
            .sequence_set,
            .sequence_take,
            .blob_from_byte,
            .sequence_pop_last,
            .select,
            => try require(old.immediate == new.immediate),
        }
    }
    fn perform(self: Body, old: ir.Perform, new: ir.Perform) Error!void {
        comptime fields(ir.Perform, &.{
            "effect", "capability", "payload", "bodies", "use_site_capabilities", "next",
        });
        try self.check.ref(.effect, old.effect, new.effect);
        try self.optionalSlot(old.capability, new.capability);
        try self.slot(old.payload, new.payload);
        try self.slots(old.bodies, new.bodies);
        try self.slots(old.use_site_capabilities, new.use_site_capabilities);
        try self.edge(old.next, new.next);
    }
    fn terminator(self: Body, old: ir.Terminator, new: ir.Terminator) Error!void {
        try require(std.meta.activeTag(old) == std.meta.activeTag(new));
        // Anonymous payload fields are classified below by their semantic roles.
        switch (old) {
            .return_value => |v| try self.slot(v, new.return_value),
            .fail => |v| try self.slot(v, new.fail),
            .jump => |v| try self.edge(v, new.jump),
            .yield_value => |v| try self.edge(v, new.yield_value),
            .perform => |v| try self.perform(v, new.perform),
            inline .branch,
            .switch_variant,
            .unpack_product,
            .call,
            .apply,
            .handle,
            .resume_value,
            .resume_with,
            .resume_computation,
            .dispose,
            .protect,
            .with_region,
            => |v, tag| try self.controlPayload(tag, v, @field(new, @tagName(tag))),
        }
    }
    fn controlPayload(
        self: Body,
        comptime tag: p.TerminatorTag,
        old: anytype,
        new: @TypeOf(old),
    ) Error!void {
        const names: []const []const u8 = comptime switch (tag) {
            .branch => &.{ "condition", "when_true", "when_false" },
            .switch_variant => &.{ "value", "cases" },
            .unpack_product => &.{ "value", "destinations", "next" },
            .call => &.{ "function", "arguments", "next" },
            .apply => &.{ "computation", "arguments", "next" },
            .handle => &.{ "handler", "body", "arguments", "state", "next" },
            .resume_value => &.{ "resumption", "argument", "next" },
            .resume_with => &.{ "resumption", "argument", "handler", "state", "next" },
            .resume_computation => &.{ "resumption", "computation", "next" },
            .dispose => &.{ "owned", "next" },
            .protect => &.{ "body", "cleanup", "arguments", "resource", "loan_region", "next" },
            .with_region => &.{ "region", "body", "arguments", "next" },
            else => @compileError("control payload requires explicit classification"),
        };
        comptime fields(@TypeOf(old), names);
        inline for (
            @typeInfo(@TypeOf(old)).@"struct".field_names,
            @typeInfo(@TypeOf(old)).@"struct".field_types,
        ) |field_name, FieldType| {
            const a = @field(old, field_name);
            const b = @field(new, field_name);
            if (comptime std.mem.eql(u8, field_name, "function")) {
                try self.check.ref(.function, a, b);
            } else if (comptime std.mem.eql(u8, field_name, "handler")) {
                try self.check.ref(.handler, a, b);
            } else if (comptime std.mem.eql(u8, field_name, "region")) {
                try self.check.ref(.region, a, b);
            } else if (comptime std.mem.eql(u8, field_name, "loan_region")) {
                try require((a == null) == (b == null));
                if (a) |id| try self.check.ref(.region, id, b.?);
            } else if (FieldType == ir.Edge) {
                try self.edge(a, b);
            } else if (FieldType == []const ir.Edge) {
                try require(a.len == b.len);
                for (a, b) |x, y| try self.edge(x, y);
            } else if (FieldType == []const p.Id) {
                try self.slots(a, b);
            } else if (FieldType == ?p.Id) {
                try self.optionalSlot(a, b);
            } else if (FieldType == p.Id) {
                try self.slot(a, b);
            } else @compileError("unclassified control field");
        }
    }
};
