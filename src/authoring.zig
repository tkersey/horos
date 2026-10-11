//! Checked authoring with normalized structural interfaces and shared runtime ownership.
const std = @import("std");
const runtime = @import("authoring/runtime.zig");
const source = @import("source.zig");
const data = @import("horos_data");
const native = data.schema.native;
const p = data.program;
pub const Error = runtime.Error;
pub const Dynamic = struct {};
pub const Shape = native.Shape;
pub const sourceError = runtime.sourceError;
pub const Diagnostic = struct {
    code: ?anyerror = null,
    entity: []const u8 = "",
    relationship: []const u8 = "",
    expected: ?*const Schema(Dynamic) = null,
    actual: ?*const Schema(Dynamic) = null,
    source: ?source.Diagnostic = null,
    fn fromRaw(value: runtime.Diagnostic) Diagnostic {
        return .{ .code = value.code, .entity = value.entity, .relationship = value.relationship, .expected = @ptrCast(value.expected), .actual = @ptrCast(value.actual), .source = value.source };
    }
    fn raw(self: Diagnostic) runtime.Diagnostic {
        return .{ .code = self.code, .entity = self.entity, .relationship = self.relationship, .expected = @ptrCast(self.expected), .actual = @ptrCast(self.actual), .source = self.source };
    }
    pub fn render(self: Diagnostic, writer: *std.Io.Writer) !void {
        return self.raw().render(writer);
    }
    pub fn renderAlloc(self: Diagnostic, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return self.raw().renderAlloc(allocator);
    }
};
pub const Region = runtime.Region;
pub const Arithmetic = runtime.Arithmetic;
pub const SchemaKind = runtime.SchemaKind;

pub const Family = enum { schema, value, function, body, computation, operation, failure_literal, case, finished_case, region, handler, declaration, product_parts };
const Metadata = struct { family: Family, shape: type };

fn Simple(comptime family: Family, comptime S: type) type {
    return opaque {
        pub const horos_handle: Metadata = .{ .family = family, .shape = S };
    };
}
pub fn Value(comptime S: type) type {
    return Simple(.value, S);
}
pub fn Function(comptime S: type) type {
    return Simple(.function, S);
}
pub fn Computation(comptime S: type) type {
    return Simple(.computation, S);
}
pub fn Operation(comptime S: type) type {
    return Simple(.operation, S);
}
pub fn FailureLiteral(comptime S: type) type {
    return Simple(.failure_literal, S);
}
pub fn Handler(comptime S: type) type {
    return Simple(.handler, S);
}
pub fn FinishedCase(comptime S: type) type {
    return Simple(.finished_case, S);
}

fn canonical(comptime family: Family, comptime S: type) type {
    return switch (family) {
        .schema => Schema(S),
        .body => Body(S),
        .case => Case(S),
        .declaration => SchemaDeclaration(S),
        .product_parts => ProductParts(S),
        .region => Region,
        else => Simple(family, S),
    };
}

/// A declaration with the right spelling is insufficient: only the canonical
/// opaque type produced by the corresponding factory passes this check.
fn metadata(comptime T: type) Metadata {
    @setEvalBranchQuota(10000);
    if (@typeInfo(T) != .pointer or @typeInfo(T).pointer.size != .one)
        @compileError("Horos authoring: expected a canonical handle pointer");
    const Child = @typeInfo(T).pointer.child;
    if (Child == Region) return .{ .family = .region, .shape = Dynamic };
    if (@typeInfo(Child) != .@"opaque" or !@hasDecl(Child, "horos_handle"))
        @compileError("Horos authoring: expected a canonical handle pointer");
    if (@TypeOf(Child.horos_handle) != Metadata)
        @compileError("Horos authoring: expected a canonical handle pointer");
    const m = Child.horos_handle;
    if (Child != canonical(m.family, m.shape))
        @compileError("Horos authoring: expected a canonical handle pointer");
    return m;
}

fn index(comptime family: Family, comptime T: type) type {
    const m = metadata(T);
    if (m.family != family) @compileError("Horos authoring: wrong handle family; expected " ++ @tagName(family));
    return m.shape;
}

pub fn ShapeOf(comptime T: type) type {
    return metadata(T).shape;
}

fn rawType(comptime family: Family) type {
    return switch (family) {
        .schema => runtime.Schema,
        .value => runtime.Value,
        .function => runtime.Function,
        .body => runtime.Body,
        .computation => runtime.Computation,
        .operation => runtime.Operation,
        .failure_literal => runtime.FailureLiteral,
        .case => runtime.Case,
        .finished_case => runtime.FinishedCase,
        .region => runtime.Region,
        .handler => runtime.Handler,
        .declaration => runtime.SchemaDeclaration,
        .product_parts => runtime.ProductParts,
    };
}
fn erased(comptime family: Family, value: anytype) *const rawType(family) {
    _ = comptime index(family, @TypeOf(value));
    return @ptrCast(value);
}
fn rawContext(c: *Context) *runtime.Context {
    return @ptrCast(c);
}

fn fieldsInfo(comptime T: type, comptime operation: []const u8) std.lang.Type.Struct {
    if (@typeInfo(T) != .@"struct") @compileError("Horos " ++ operation ++ ": expected a named struct of handles");
    const fields = @typeInfo(T).@"struct";
    if (fields.is_tuple and fields.field_types.len != 0)
        @compileError("Horos " ++ operation ++ ": expected a named struct of handles");
    return fields;
}

fn namedShape(comptime family: Family, comptime T: type) type {
    if (T == *const interop.RuntimeNamed(family)) return Dynamic;
    const fields = fieldsInfo(T, "declaration");
    var children: [fields.field_types.len]type = undefined;
    for (fields.field_types, 0..) |Child, i| children[i] = index(family, Child);
    return native.Fields(fields.field_names, &children);
}

fn Collection(comptime family: Family, comptime T: type) type {
    const Raw = RawNamed(family);
    const dynamic = T == *const interop.RuntimeNamed(family);
    const count = if (dynamic) 0 else fieldsInfo(T, "named collection").field_types.len;
    return struct {
        owned: [count]Raw = undefined,
        borrowed: []const Raw = &.{},
        fn slice(self: *const @This()) []const Raw {
            return if (dynamic) self.borrowed else &self.owned;
        }
    };
}

fn packSchemas(values: anytype) Collection(.schema, @TypeOf(values)) {
    if (comptime @TypeOf(values) == *const interop.RuntimeNamed(.schema)) {
        const stored: *const NamedData(.schema) = @ptrCast(@alignCast(values));
        return .{ .borrowed = stored.entries };
    }
    return .{ .owned = schemas(values) };
}

fn packArguments(comptime Fields: type, values: anytype, comptime operation: []const u8) Collection(.value, @TypeOf(values)) {
    if (comptime @TypeOf(values) == *const interop.RuntimeNamed(.value)) {
        const stored: *const NamedData(.value) = @ptrCast(@alignCast(values));
        return .{ .borrowed = stored.entries };
    }
    return .{ .owned = arguments(Fields, values, operation) };
}

fn recordShape(comptime kind: enum { product, sum }, comptime T: type) type {
    const Fields = namedShape(.schema, T);
    return if (Fields == Dynamic) Dynamic else native.Contract(@unionInit(native.Info, @tagName(kind), Fields));
}

fn schemas(values: anytype) [fieldsInfo(@TypeOf(values), "declaration").field_types.len]runtime.Field {
    const fields = comptime fieldsInfo(@TypeOf(values), "declaration");
    var result: [fields.field_types.len]runtime.Field = undefined;
    inline for (fields.field_names, 0..) |name, i|
        result[i] = .{ .name = name, .schema = erased(.schema, @field(values, name)) };
    return result;
}

fn listCount(comptime T: type) ?usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_types.len,
        .array => |array| array.len,
        .optional => |o| listCount(o.child),
        .null => 0,
        .pointer => |pointer| if (pointer.size == .slice) null else listCount(pointer.child),
        else => @compileError("Horos handle collection: expected a tuple, array, or slice"),
    };
}
fn HandleList(comptime family: Family, comptime T: type) type {
    const count = listCount(T);
    return struct {
        present: bool = true,
        owned: [count orelse 0]*const rawType(family) = undefined,
        borrowed: []const *const rawType(family) = &.{},
        fn optionalSlice(self: *const @This()) ?[]const *const rawType(family) {
            return if (self.present) self.slice() else null;
        }
        fn slice(self: *const @This()) []const *const rawType(family) {
            if (!self.present) return &.{};
            return if (count == null) self.borrowed else &self.owned;
        }
    };
}
fn handles(comptime family: Family, values: anytype) HandleList(family, @TypeOf(values)) {
    const T = @TypeOf(values);
    var list: HandleList(family, T) = .{};
    if (comptime @typeInfo(T) == .null) {
        list.present = false;
    } else if (comptime @typeInfo(T) == .optional) {
        if (values) |present| {
            const nested = handles(family, present);
            list.present = nested.present;
            if (nested.present) {
                list.owned = nested.owned;
                list.borrowed = nested.borrowed;
            }
        } else list.present = false;
    } else if (comptime listCount(T) == null) {
        _ = comptime index(family, @typeInfo(T).pointer.child);
        list.borrowed = @as([*]const *const rawType(family), @ptrCast(values.ptr))[0..values.len];
    } else if (comptime @typeInfo(T) == .@"struct") {
        inline for (@typeInfo(T).@"struct".field_names, 0..) |name, i| list.owned[i] = erased(family, @field(values, name));
    } else {
        inline for (values, 0..) |value, i| list.owned[i] = erased(family, value);
    }
    return list;
}
fn OptionType(comptime T: type, comptime name: []const u8, comptime Default: type) type {
    return if (@hasField(T, name)) @FieldType(T, name) else Default;
}
inline fn option(options: anytype, comptime name: []const u8, default: anytype) OptionType(@TypeOf(options), name, @TypeOf(default)) {
    return if (@hasField(@TypeOf(options), name)) @field(options, name) else default;
}

fn optionalFailure(value: anytype) ?*const runtime.FailureLiteral {
    return switch (@typeInfo(@TypeOf(value))) {
        .null => null,
        .optional => if (value) |present| erased(.failure_literal, present) else null,
        else => erased(.failure_literal, value),
    };
}

fn mismatch(comptime path: []const u8) noreturn {
    @compileError("Horos " ++ path ++ ": incompatible schema shape");
}

const ShapePair = struct { expected: type, actual: type };
const ShapeRelation = enum { compatible, declaration };

fn compatible(comptime Expected: type, comptime Actual: type, comptime path: []const u8) void {
    compareShapes(Expected, Actual, path, .compatible, &.{});
}

// A declaration promises facts that must survive completion. Ordinary uses may
// instead defer unknown portions to the runtime compatibility owner.
fn declarationCompatible(comptime Expected: type, comptime Actual: type, comptime path: []const u8) void {
    compareShapes(Expected, Actual, path, .declaration, &.{});
}

fn compareShapes(comptime Expected: type, comptime Actual: type, comptime path: []const u8, comptime relation: ShapeRelation, comptime ancestors: []const ShapePair) void {
    if (Expected == Actual or Expected == Dynamic) return;
    if (Actual == Dynamic) {
        if (relation == .declaration) @compileError("Horos " ++ path ++ ": refine the unknown input before fulfilling a known declaration shape");
        return;
    }
    // Shape descriptions can be finite recursive graphs (Search and Reader).
    // Re-entering the same pair adds no obligation; sibling fields still run.
    for (ancestors) |pair| if (pair.expected == Expected and pair.actual == Actual) return;
    const next = ancestors ++ [_]ShapePair{.{ .expected = Expected, .actual = Actual }};
    if (@hasDecl(Expected, "internal") or @hasDecl(Actual, "internal")) {
        if (!@hasDecl(Expected, "internal") or !@hasDecl(Actual, "internal")) mismatch(path);
        const left = Expected.internal;
        const right = Actual.internal;
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) mismatch(path);
        switch (left) {
            .region => {},
            .callable => |signature| compareSignatures(signature, right.callable, path, relation, next),
            .capability => |signature| {
                if (signature == Dynamic) return;
                if (right.capability == Dynamic) {
                    if (relation == .declaration) @compileError("Horos " ++ path ++ ": unknown capability cannot fulfill a known declaration shape");
                    return;
                }
                compareShapes(signature.payload, right.capability.payload, path ++ ".payload", relation, next);
                compareShapes(signature.result, right.capability.result, path ++ ".reply", relation, next);
                compareFields(signature.bodies, right.capability.bodies, path ++ ".bodies", relation, next);
            },
            .resumption => |signature| {
                if (signature == Dynamic) return;
                if (right.resumption == Dynamic) {
                    if (relation == .declaration) @compileError("Horos " ++ path ++ ": unknown resumption cannot fulfill a known declaration shape");
                    return;
                }
                if (signature.mode != right.resumption.mode) mismatch(path ++ ".mode");
                compareShapes(signature.reply, right.resumption.reply, path ++ ".reply", relation, next);
                compareShapes(signature.result, right.resumption.result, path ++ ".result", relation, next);
            },
            .cell, .resource, .borrowed, .package => |element, tag| compareShapes(element, @field(right, @tagName(tag)), path ++ ".element", relation, next),
        }
        return;
    }
    const left = Expected.contract;
    const right = Actual.contract;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) mismatch(path);
    switch (left) {
        .product, .sum => |Fields, tag| {
            const lhs = @typeInfo(Fields).@"struct";
            const rhs = @typeInfo(@field(right, @tagName(tag))).@"struct";
            if (lhs.field_types.len != rhs.field_types.len) mismatch(path);
            for (lhs.field_names, lhs.field_types, rhs.field_names, rhs.field_types) |ln, L, rn, R| {
                if (!std.mem.eql(u8, ln, rn)) mismatch(path ++ "." ++ ln);
                compareShapes(L, R, path ++ "." ++ ln, relation, next);
            }
        },
        .array => |array| {
            if (array.length != right.array.length) mismatch(path);
            compareShapes(array.element, right.array.element, path ++ ".element", relation, next);
        },
        .sequence => |sequence| {
            if (sequence.maximum != right.sequence.maximum) mismatch(path);
            compareShapes(sequence.element, right.sequence.element, path ++ ".element", relation, next);
        },
        else => mismatch(path),
    }
}
fn compareFields(comptime Expected: type, comptime Actual: type, comptime path: []const u8, comptime relation: ShapeRelation, comptime ancestors: []const ShapePair) void {
    if (Expected == Actual or Expected == Dynamic) return;
    if (Actual == Dynamic) {
        if (relation == .declaration) @compileError("Horos " ++ path ++ ": runtime names cannot fulfill a known declaration without refinement");
        return;
    }
    compareShapes(native.Contract(.{ .product = Expected }), native.Contract(.{ .product = Actual }), path, relation, ancestors);
}
fn compatibleSignature(comptime Expected: type, comptime Actual: type, comptime path: []const u8) void {
    compareSignatures(Expected, Actual, path, .compatible, &.{});
}
fn compareSignatures(comptime Expected: type, comptime Actual: type, comptime path: []const u8, comptime relation: ShapeRelation, comptime ancestors: []const ShapePair) void {
    if (Expected == Actual or Expected == Dynamic) return;
    if (Actual == Dynamic) {
        if (relation == .declaration) @compileError("Horos " ++ path ++ ": unknown callable cannot fulfill a known declaration shape");
        return;
    }
    compareFields(Expected.parameters, Actual.parameters, path ++ ".parameters", relation, ancestors);
    compareShapes(Expected.result, Actual.result, path ++ ".result", relation, ancestors);
}

pub const InternalInfo = union(enum) {
    callable: type,
    capability: type,
    cell: type,
    region,
    resource: type,
    borrowed: type,
    package: type,
    resumption: type,
};
pub fn Internal(comptime description: InternalInfo) type {
    return struct {
        pub const internal = description;
    };
}
fn internalChild(comptime S: type, comptime kind: std.meta.Tag(InternalInfo), comptime operation: []const u8) type {
    if (S == Dynamic) return Dynamic;
    if (!@hasDecl(S, "internal") or std.meta.activeTag(S.internal) != kind)
        @compileError("Horos " ++ operation ++ ": expected " ++ @tagName(kind) ++ " shape");
    return @field(S.internal, @tagName(kind));
}
fn callableSignature(comptime S: type, comptime operation: []const u8) type {
    return internalChild(S, .callable, operation);
}
fn resourceRepresentation(comptime S: type) type {
    if (S == Dynamic) return Dynamic;
    const Resource = if (@hasDecl(S, "internal") and S.internal == .borrowed) S.internal.borrowed else S;
    return internalChild(Resource, .resource, "unpackResource");
}

fn child(comptime Fields: type, comptime name: []const u8, comptime operation: []const u8) type {
    if (Fields == Dynamic) return Dynamic;
    if (!@hasField(Fields, name)) @compileError("Horos " ++ operation ++ "." ++ name ++ ": unknown name");
    return @FieldType(Fields, name);
}

fn productFields(comptime S: type, comptime operation: []const u8) type {
    if (S == Dynamic) return Dynamic;
    if (!@hasDecl(S, "contract") or S.contract != .product) @compileError("Horos " ++ operation ++ ": expected a product shape");
    return S.contract.product;
}
fn sumFields(comptime S: type, comptime operation: []const u8) type {
    if (S == Dynamic) return Dynamic;
    if (!@hasDecl(S, "contract") or S.contract != .sum) @compileError("Horos " ++ operation ++ ": expected a sum shape");
    return S.contract.sum;
}

fn CaseSignature(comptime Sum: type, comptime arm_index: usize) type {
    return struct {
        pub const sum = Sum;
        pub const arm = arm_index;
        pub const payload = @typeInfo(sumFields(Sum, "caseOf")).@"struct".field_types[arm_index];
    };
}
fn caseSignature(comptime S: type, comptime name: []const u8) type {
    if (S == Dynamic) return Dynamic;
    const Fields = sumFields(S, "caseOf");
    if (!@hasField(Fields, name)) @compileError("Horos caseOf." ++ name ++ ": unknown name");
    return CaseSignature(S, @backingInt(@field(FieldOrdinals(Fields).Index, name)));
}
fn FieldOrdinals(comptime Fields: type) type {
    return struct {
        const Index = std.meta.FieldEnum(Fields);
    };
}
fn casePayload(comptime S: type) type {
    return if (S == Dynamic) Dynamic else S.payload;
}
fn FinishedSignature(comptime C: type, comptime R: type) type {
    return struct {
        pub const case = C;
        pub const result = R;
    };
}
pub fn Case(comptime S: type) type {
    return opaque {
        const Self = @This();
        pub const horos_handle: Metadata = .{ .family = .case, .shape = S };
        pub fn body(self: *const Self) *Body(native.Fields(&.{}, &.{})) {
            return @ptrCast(erased(.case, self).body());
        }
        pub fn payload(self: *const Self) *const Value(casePayload(S)) {
            return @ptrCast(erased(.case, self).payload());
        }
        pub fn ret(self: *const Self, value: anytype) Error!*const FinishedCase(FinishedSignature(S, index(.value, @TypeOf(value)))) {
            return @ptrCast(try erased(.case, self).ret(erased(.value, value)));
        }
        pub fn fail(self: *const Self, returns: anytype, failure: anytype) Error!*const FinishedCase(FinishedSignature(S, index(.schema, @TypeOf(returns)))) {
            return @ptrCast(try erased(.case, self).fail(erased(.schema, returns), erased(.value, failure)));
        }
    };
}

fn matchResult(comptime Sum: type, comptime Cases: type) type {
    if (Cases == *const interop.RuntimeNamed(.finished_case)) return Dynamic;
    const supplied = fieldsInfo(Cases, "match");
    const Fields = sumFields(Sum, "match");
    if (Fields != Dynamic) {
        for (@typeInfo(Fields).@"struct".field_names) |name| if (!@hasField(Cases, name))
            @compileError("Horos match." ++ name ++ ": missing case");
        for (supplied.field_names) |name| if (!@hasField(Fields, name))
            @compileError("Horos match." ++ name ++ ": extra case");
    }
    var R: type = Dynamic;
    for (supplied.field_names, supplied.field_types) |name, T| {
        const Finished = index(.finished_case, T);
        if (Finished != Dynamic) {
            if (Finished.case != Dynamic) {
                compatible(Sum, Finished.case.sum, "match." ++ name);
                const actual_name = @typeInfo(sumFields(Finished.case.sum, "match")).@"struct".field_names[Finished.case.arm];
                if (!std.mem.eql(u8, name, actual_name)) @compileError("Horos match." ++ name ++ ": case belongs to a different arm");
            }
            compatible(R, Finished.result, "match." ++ name ++ " result");
            if (R == Dynamic) R = Finished.result;
        }
    }
    return R;
}

fn arguments(comptime Fields: type, values: anytype, comptime operation: []const u8) [fieldsInfo(@TypeOf(values), operation).field_types.len]runtime.Argument {
    const supplied = comptime fieldsInfo(@TypeOf(values), operation);
    comptime {
        if (Fields != Dynamic) {
            const expected = @typeInfo(Fields).@"struct";
            for (expected.field_names, expected.field_types) |name, S| {
                if (!@hasField(@TypeOf(values), name)) @compileError("Horos " ++ operation ++ "." ++ name ++ ": missing field");
                compatible(S, index(.value, @FieldType(@TypeOf(values), name)), operation ++ "." ++ name);
            }
            for (supplied.field_names) |name| if (!@hasField(Fields, name))
                @compileError("Horos " ++ operation ++ "." ++ name ++ ": extra field");
        }
    }
    var result: [supplied.field_types.len]runtime.Argument = undefined;
    inline for (supplied.field_names, 0..) |name, i|
        result[i] = .{ .name = name, .value = erased(.value, @field(values, name)) };
    return result;
}

pub fn Signature(comptime Parameters: type, comptime Result: type) type {
    return struct {
        pub const parameters = Parameters;
        pub const result = Result;
    };
}
pub fn OperationSignature(comptime Payload: type, comptime Reply: type, comptime Bodies: type) type {
    return struct {
        pub const payload = Payload;
        pub const result = Reply;
        pub const bodies = Bodies;
    };
}
fn parameters(comptime S: type) type {
    return if (S == Dynamic) Dynamic else S.parameters;
}
fn resultShape(comptime S: type) type {
    return if (S == Dynamic) Dynamic else S.result;
}

fn DeclarationSignature(comptime declared_kind: SchemaKind, comptime S: type) type {
    return struct {
        pub const kind = declared_kind;
        pub const shape = S;
    };
}
pub fn SchemaDeclaration(comptime S: type) type {
    return opaque {
        pub const horos_handle: Metadata = .{ .family = .declaration, .shape = S };
        pub fn schema(self: *const @This()) *const Schema(if (S == Dynamic) Dynamic else S.shape) {
            return @ptrCast(erased(.declaration, self).schema());
        }
    };
}
pub fn ProductParts(comptime S: type) type {
    return opaque {
        pub const horos_handle: Metadata = .{ .family = .product_parts, .shape = S };
        pub fn get(self: *const @This(), comptime name: []const u8) Error!*const Value(child(productFields(S, "ProductParts.get"), name, "ProductParts.get")) {
            return @ptrCast(try erased(.product_parts, self).get(name));
        }
    };
}
fn declarationShape(comptime D: type, comptime kind: SchemaKind) type {
    if (D == Dynamic) return Dynamic;
    if (D.kind != kind) @compileError("Horos declaration: wrong schema category");
    return D.shape;
}
fn reflectedFields(comptime S: type) type {
    if (S == Dynamic) return Dynamic;
    if (@hasDecl(S, "contract")) return switch (S.contract) {
        .product, .sum => |fields| fields,
        else => native.Fields(&.{}, &.{}),
    };
    return switch (S.internal) {
        .callable => |Sig| parameters(Sig),
        .resumption => |Sig| if (Sig == Dynamic) Dynamic else native.Fields(&.{"reply"}, &.{Sig.reply}),
        else => native.Fields(&.{}, &.{}),
    };
}
fn reflectedResult(comptime S: type) type {
    if (S == Dynamic) return Dynamic;
    if (@hasDecl(S, "contract")) return switch (S.contract) {
        .sequence => |v| v.element,
        .array => |v| v.element,
        else => @compileError("Horos resultSchema: schema has no result or element"),
    };
    return switch (S.internal) {
        .callable, .resumption => |Sig| resultShape(Sig),
        .cell, .resource, .borrowed, .package => |Element| Element,
        else => @compileError("Horos resultSchema: schema has no result or element"),
    };
}

pub fn Schema(comptime S: type) type {
    return opaque {
        const Self = @This();
        pub const horos_handle: Metadata = .{ .family = .schema, .shape = S };
        pub fn fields(self: *const Self) Error!SchemaFields(S) {
            const Fields = reflectedFields(S);
            var out: SchemaFields(S) = undefined;
            const stored = try erased(.schema, self).checkedFields();
            inline for (@typeInfo(Fields).@"struct".field_names, 0..) |name, i|
                @field(out, name) = @ptrCast(stored[i].schema);
            return out;
        }
        pub fn resultSchema(self: *const Self) Error!(if (S == Dynamic) ?*const Schema(Dynamic) else *const Schema(reflectedResult(S))) {
            const result = try erased(.schema, self).checkedResult();
            if (comptime S == Dynamic) return @ptrCast(result);
            return @ptrCast(result.?);
        }
        pub fn describe(self: *const Self, writer: *std.Io.Writer) !void {
            return erased(.schema, self).describe(writer);
        }
    };
}
fn SchemaFields(comptime S: type) type {
    const Fields = reflectedFields(S);
    if (Fields == Dynamic) @compileError("Horos schema fields: use interop for runtime metadata");
    const f = @typeInfo(Fields).@"struct";
    var children: [f.field_types.len]type = undefined;
    for (f.field_types, 0..) |Child, i| children[i] = *const Schema(Child);
    return native.Fields(f.field_names, &children);
}

fn joinFields(comptime A: type, comptime B: type) type {
    if (A == Dynamic or B == Dynamic) return Dynamic;
    const a = @typeInfo(A).@"struct";
    const b = @typeInfo(B).@"struct";
    for (a.field_names) |name| if (@hasField(B, name)) @compileError("Horos interface: duplicate field " ++ name);
    return native.Fields(a.field_names ++ b.field_names, a.field_types ++ b.field_types);
}
fn knownMode(comptime T: type) ?p.Mode {
    const f = fieldsInfo(T, "handler options");
    for (f.field_names, f.field_types, f.field_attrs) |name, Field, attributes| {
        if (std.mem.eql(u8, name, "mode") and attributes.@"comptime") return @as(p.Mode, attributes.defaultValue(Field).?);
    }
    return null;
}
pub fn HandlerShape(comptime Ops: type, comptime Input: type, comptime Answer: type, comptime State: type, comptime BodyParameters: type, comptime selected_mode: p.Mode) type {
    return struct {
        pub const operations = Ops;
        pub const input = Input;
        pub const result = Answer;
        pub const state = State;
        pub const body_parameters = BodyParameters;
        pub const mode = selected_mode;
    };
}
fn HandlerSignature(comptime Ops: type, comptime Input: type, comptime Answer: type, comptime Options: type, comptime selected_mode: p.Mode) type {
    return HandlerShape(Ops, Input, Answer, namedShape(.schema, OptionType(Options, "state", @TypeOf(.{}))), namedShape(.schema, OptionType(Options, "body_parameters", @TypeOf(.{}))), selected_mode);
}
fn HandlerResult(comptime Ops: type, comptime Input: type, comptime Answer: type, comptime Options: type) type {
    if (knownMode(Options)) |mode| return *const Handler(HandlerSignature(Ops, Input, Answer, Options, mode));
    return union(enum) {
        deep: *const Handler(HandlerSignature(Ops, Input, Answer, Options, .deep)),
        shallow: *const Handler(HandlerSignature(Ops, Input, Answer, Options, .shallow)),
    };
}
fn returnedHandler(comptime Ops: type, comptime Input: type, comptime Answer: type, options: anytype, raw: *const runtime.Handler) HandlerResult(Ops, Input, Answer, @TypeOf(options)) {
    if (comptime knownMode(@TypeOf(options)) != null) return @ptrCast(raw);
    return switch (options.mode) {
        .deep => .{ .deep = @ptrCast(raw) },
        .shallow => .{ .shallow = @ptrCast(raw) },
    };
}
fn validateSlot(comptime Slot: type, comptime Op: type, comptime Ops: type, comptime Input: type, comptime Answer: type, comptime Options: type) void {
    const Expected = declarationShape(index(.declaration, Slot), .resumption);
    if (knownMode(Options)) |mode| {
        const H = HandlerSignature(Ops, Input, Answer, Options, mode);
        declarationCompatible(Expected, handlerResumption(H, Op), "handler resumption declaration");
    } else if (Expected != Dynamic) @compileError("Horos handler: runtime mode requires an explicitly unknown resumption declaration");
}
fn validateResumptionSlots(comptime Options: type, comptime Ops: type, comptime Input: type, comptime Answer: type) void {
    if (!@hasField(Options, "resumption_slots")) return;
    validateSlotCollection(@FieldType(Options, "resumption_slots"), Options, Ops, Input, Answer);
}
fn validateSlotCollection(comptime Slots: type, comptime Options: type, comptime Ops: type, comptime Input: type, comptime Answer: type) void {
    switch (@typeInfo(Slots)) {
        .null => return,
        .optional => |optional| return validateSlotCollection(optional.child, Options, Ops, Input, Answer),
        .pointer => |pointer| if (pointer.size == .one) return validateSlotCollection(pointer.child, Options, Ops, Input, Answer),
        else => {},
    }
    if (@typeInfo(Slots) == .@"struct") {
        const declarations = @typeInfo(Slots).@"struct";
        if (Ops == Dynamic) {
            for (declarations.field_types) |D| validateSlot(D, Dynamic, Ops, Input, Answer, Options);
        } else {
            const ops = @typeInfo(Ops).@"struct";
            if (declarations.field_types.len != ops.field_types.len) @compileError("Horos handler: one resumption declaration is required per operation");
            for (declarations.field_types, ops.field_types) |D, Op| validateSlot(D, Op, Ops, Input, Answer, Options);
        }
    } else {
        const Slot = switch (@typeInfo(Slots)) {
            .array => |array| array.child,
            .pointer => |pointer| if (pointer.size == .slice) pointer.child else @compileError("Horos handle collection: expected a tuple, array, or slice"),
            else => @compileError("Horos handle collection: expected a tuple, array, or slice"),
        };
        if (Ops == Dynamic) validateSlot(Slot, Dynamic, Ops, Input, Answer, Options) else {
            for (@typeInfo(Ops).@"struct".field_types) |Op| validateSlot(Slot, Op, Ops, Input, Answer, Options);
        }
    }
}

fn handlerReturnSignature(comptime H: type) type {
    return if (H == Dynamic) Dynamic else Signature(joinFields(H.state, native.Fields(&.{"result"}, &.{H.input})), H.result);
}
pub fn ResumptionSignature(comptime Reply: type, comptime Result: type, comptime selected_mode: p.Mode) type {
    return struct {
        pub const reply = Reply;
        pub const result = Result;
        pub const mode = selected_mode;
    };
}
fn handlerResumption(comptime H: type, comptime Op: type) type {
    return Internal(.{ .resumption = if (H == Dynamic or Op == Dynamic) Dynamic else ResumptionSignature(Op.result, if (H.mode == .deep) H.result else H.input, H.mode) });
}
fn handlerClauseSignature(comptime H: type, comptime Op: type) type {
    if (H == Dynamic or Op == Dynamic) return Dynamic;
    const prefix = joinFields(H.state, native.Fields(&.{"payload"}, &.{Op.payload}));
    return Signature(joinFields(joinFields(prefix, Op.bodies), native.Fields(&.{"resumption"}, &.{handlerResumption(H, Op)})), H.result);
}
fn handlerBodySignature(comptime H: type) type {
    if (H == Dynamic) return Dynamic;
    if (H.operations == Dynamic) return Signature(Dynamic, H.input);
    const ops = @typeInfo(H.operations).@"struct";
    var children: [ops.field_types.len]type = undefined;
    for (ops.field_types, 0..) |Op, i| children[i] = Internal(.{ .capability = Op });
    return Signature(joinFields(native.Fields(ops.field_names, &children), H.body_parameters), H.input);
}
fn onlyOperation(comptime H: type) type {
    if (H == Dynamic or H.operations == Dynamic) return Dynamic;
    const ops = @typeInfo(H.operations).@"struct";
    if (ops.field_types.len != 1) @compileError("Horos clauseFunction: select an operation for a multi-clause handler");
    return ops.field_types[0];
}

pub const Context = opaque {
    pub fn init(raw: *source.Builder) Error!*Context {
        return @ptrCast(try runtime.Context.init(raw));
    }
    pub fn lastDiagnostic(self: *Context) Diagnostic {
        return Diagnostic.fromRaw(rawContext(self).lastDiagnostic());
    }
    pub fn schema(self: *Context, comptime T: type) Error!*const Schema(Shape(T)) {
        return @ptrCast(try rawContext(self).nativeSchema(native.info(T)));
    }
    /// Recursive edges may explicitly use Dynamic; completion still belongs to
    /// this declaration's checked runtime slot.
    pub fn declareSchema(self: *Context, comptime kind: SchemaKind, comptime S: type) Error!*const SchemaDeclaration(DeclarationSignature(kind, S)) {
        return @ptrCast(try rawContext(self).declareSchema(kind));
    }
    pub fn defineAlternatives(self: *Context, declaration: anytype, cases: anytype) Error!void {
        comptime declarationCompatible(declarationShape(index(.declaration, @TypeOf(declaration)), .alternatives), recordShape(.sum, @TypeOf(cases)), "defineAlternatives");
        const fields = packSchemas(cases);
        return rawContext(self).defineAlternatives(erased(.declaration, declaration), fields.slice());
    }
    pub fn defineCallable(self: *Context, declaration: anytype, params: anytype, returns: anytype, allowed: anytype, options: anytype) Error!void {
        comptime declarationCompatible(declarationShape(index(.declaration, @TypeOf(declaration)), .callable), Internal(.{ .callable = Signature(namedShape(.schema, @TypeOf(params)), index(.schema, @TypeOf(returns))) }), "defineCallable");
        const fields = packSchemas(params);
        const effects = handles(.operation, allowed);
        const captures = handles(.schema, option(options, "captures", .{}));
        const regions = handles(.region, option(options, "regions", .{}));
        return rawContext(self).defineCallable(erased(.declaration, declaration), fields.slice(), erased(.schema, returns), effects.slice(), .{ .use = options.use, .captures = captures.slice(), .regions = regions.slice() });
    }
    pub fn record(self: *Context, values: anytype) Error!*const Schema(recordShape(.product, @TypeOf(values))) {
        const fields = packSchemas(values);
        return @ptrCast(try rawContext(self).record(fields.slice()));
    }
    pub fn alternatives(self: *Context, values: anytype) Error!*const Schema(recordShape(.sum, @TypeOf(values))) {
        const fields = packSchemas(values);
        return @ptrCast(try rawContext(self).alternatives(fields.slice()));
    }
    pub fn external(self: *Context, name: []const u8, payload: anytype, reply: anytype) Error!*const Operation(OperationSignature(index(.schema, @TypeOf(payload)), index(.schema, @TypeOf(reply)), native.Fields(&.{}, &.{}))) {
        return @ptrCast(try rawContext(self).external(name, erased(.schema, payload), erased(.schema, reply)));
    }
    pub fn local(self: *Context, name: []const u8, payload: anytype, reply: anytype, use: p.Use) Error!*const Operation(OperationSignature(index(.schema, @TypeOf(payload)), index(.schema, @TypeOf(reply)), native.Fields(&.{}, &.{}))) {
        return @ptrCast(try rawContext(self).local(name, erased(.schema, payload), erased(.schema, reply), use));
    }
    pub fn scoped(self: *Context, name: []const u8, payload: anytype, reply: anytype, use: p.Use, bodies: anytype) Error!*const Operation(OperationSignature(index(.schema, @TypeOf(payload)), index(.schema, @TypeOf(reply)), namedShape(.schema, @TypeOf(bodies)))) {
        const fields = packSchemas(bodies);
        return @ptrCast(try rawContext(self).scoped(name, erased(.schema, payload), erased(.schema, reply), use, fields.slice()));
    }
    pub fn sequence(self: *Context, element: anytype) Error!*const Schema(native.Contract(.{ .sequence = .{ .element = index(.schema, @TypeOf(element)), .maximum = null } })) {
        return @ptrCast(try rawContext(self).sequence(erased(.schema, element)));
    }
    pub fn region(self: *Context) Error!*const Region {
        return rawContext(self).region();
    }
    pub fn regionSchema(self: *Context, region_handle: *const Region) Error!*const Schema(Internal(.region)) {
        return @ptrCast(try rawContext(self).regionSchema(region_handle));
    }
    pub fn capability(self: *Context, operation: anytype) Error!*const Schema(Internal(.{ .capability = index(.operation, @TypeOf(operation)) })) {
        return @ptrCast(try rawContext(self).capability(erased(.operation, operation)));
    }
    pub fn cell(self: *Context, region_handle: *const Region, element: anytype) Error!*const Schema(Internal(.{ .cell = index(.schema, @TypeOf(element)) })) {
        return @ptrCast(try rawContext(self).cell(region_handle, erased(.schema, element)));
    }
    pub fn resource(self: *Context, representation: anytype) Error!*const Schema(Internal(.{ .resource = index(.schema, @TypeOf(representation)) })) {
        return @ptrCast(try rawContext(self).resource(erased(.schema, representation)));
    }
    pub fn borrowed(self: *Context, representation: anytype, region_handle: *const Region) Error!*const Schema(Internal(.{ .borrowed = index(.schema, @TypeOf(representation)) })) {
        return @ptrCast(try rawContext(self).borrowed(erased(.schema, representation), region_handle));
    }
    pub fn callable(self: *Context, params: anytype, returns: anytype, allowed: anytype, options: anytype) Error!*const Schema(Internal(.{ .callable = Signature(namedShape(.schema, @TypeOf(params)), index(.schema, @TypeOf(returns))) })) {
        const fields = packSchemas(params);
        const effects = handles(.operation, allowed);
        const captures = handles(.schema, option(options, "captures", .{}));
        const regions = handles(.region, option(options, "regions", .{}));
        return @ptrCast(try rawContext(self).callable(fields.slice(), erased(.schema, returns), effects.slice(), .{
            .use = options.use,
            .captures = captures.slice(),
            .regions = regions.slice(),
        }));
    }
    pub fn regionBodySchema(self: *Context, region_handle: *const Region, params: anytype, returns: anytype, allowed: anytype, options: anytype) Error!*const Schema(Internal(.{ .callable = Signature(joinFields(native.Fields(&.{"region"}, &.{Internal(.region)}), namedShape(.schema, @TypeOf(params))), index(.schema, @TypeOf(returns))) })) {
        const fields = packSchemas(params);
        const effects = handles(.operation, allowed);
        const captures = handles(.schema, option(options, "captures", .{}));
        const regions = handles(.region, option(options, "regions", .{}));
        return @ptrCast(try rawContext(self).regionBodySchema(region_handle, fields.slice(), erased(.schema, returns), effects.slice(), .{ .use = options.use, .captures = captures.slice(), .regions = regions.slice() }));
    }
    pub fn cleanupInfo(self: *Context, failure: anytype) Error!*const Schema(CleanupShape(index(.schema, @TypeOf(failure)))) {
        return @ptrCast(try rawContext(self).cleanupInfo(erased(.schema, failure)));
    }
    pub fn twice(self: *Context, schema_handle: anytype) Error!*const Function(Signature(native.Fields(&.{"callable"}, &.{index(.schema, @TypeOf(schema_handle))}), PairShape(resultShape(callableSignature(index(.schema, @TypeOf(schema_handle)), "twice"))))) {
        const Sig = callableSignature(index(.schema, @TypeOf(schema_handle)), "twice");
        if (comptime Sig != Dynamic and Sig.parameters != Dynamic and @typeInfo(Sig.parameters).@"struct".field_types.len != 0) @compileError("Horos twice: requires a zero-argument callable");
        return @ptrCast(try rawContext(self).twice(erased(.schema, schema_handle)));
    }
    pub fn functionFor(self: *Context, name: []const u8, schema_handle: anytype) Error!*const Function(callableSignature(index(.schema, @TypeOf(schema_handle)), "functionFor")) {
        return @ptrCast(try rawContext(self).functionFor(name, erased(.schema, schema_handle)));
    }
    pub fn resourceAuthority(self: *Context, schema_handle: anytype, introducers: anytype, eliminators: anytype) Error!void {
        _ = comptime internalChild(index(.schema, @TypeOf(schema_handle)), .resource, "resourceAuthority");
        const ins = handles(.function, introducers);
        const outs = handles(.function, eliminators);
        return rawContext(self).resourceAuthority(erased(.schema, schema_handle), ins.slice(), outs.slice());
    }
    pub fn handler(self: *Context, operation: anytype, input: anytype, answer: anytype, options: anytype) Error!HandlerResult(namedShape(.operation, @TypeOf(.{ .capability = operation })), index(.schema, @TypeOf(input)), index(.schema, @TypeOf(answer)), @TypeOf(options)) {
        return self.handlerSet(.{ .capability = operation }, input, answer, options);
    }
    pub fn handlerSet(self: *Context, operations: anytype, input: anytype, answer: anytype, options: anytype) Error!HandlerResult(namedShape(.operation, @TypeOf(operations)), index(.schema, @TypeOf(input)), index(.schema, @TypeOf(answer)), @TypeOf(options)) {
        const ops = packNamed(.operation, operations);
        const residual = handles(.operation, option(options, "residual", .{}));
        const escaping = handles(.operation, option(options, "escaping", .{}));
        const captures = handles(.schema, option(options, "captures", .{}));
        const body_captures = handles(.schema, option(options, "body_captures", .{}));
        const owned_regions = handles(.region, option(options, "owned_regions", .{}));
        const borrowed_regions = handles(.region, option(options, "borrowed_regions", .{}));
        const state = packSchemas(option(options, "state", .{}));
        const body_parameters = packSchemas(option(options, "body_parameters", .{}));
        const return_effects = handles(.operation, option(options, "return_effects", .{}));
        const clause_effects = handles(.operation, option(options, "clause_effects", .{}));
        const slots = handles(.declaration, option(options, "resumption_slots", .{}));
        comptime validateResumptionSlots(@TypeOf(options), namedShape(.operation, @TypeOf(operations)), index(.schema, @TypeOf(input)), index(.schema, @TypeOf(answer)));
        const raw = try rawContext(self).handlerSet(ops.slice(), erased(.schema, input), erased(.schema, answer), .{
            .mode = options.mode,
            .use = options.use,
            .resumption_slots = if (@hasField(@TypeOf(options), "resumption_slots")) slots.optionalSlice() else null,
            .residual = residual.slice(),
            .escaping = escaping.slice(),
            .captures = captures.slice(),
            .body_captures = body_captures.slice(),
            .body_use = option(options, "body_use", p.Use.linear),
            .owned_regions = owned_regions.slice(),
            .borrowed_regions = borrowed_regions.slice(),
            .state = state.slice(),
            .body_parameters = body_parameters.slice(),
            .return_effects = if (@hasField(@TypeOf(options), "return_effects")) return_effects.optionalSlice() else null,
            .clause_effects = if (@hasField(@TypeOf(options), "clause_effects")) clause_effects.optionalSlice() else null,
            .obligations = option(options, "obligations", false),
        });
        return returnedHandler(namedShape(.operation, @TypeOf(operations)), index(.schema, @TypeOf(input)), index(.schema, @TypeOf(answer)), options, raw);
    }
    pub fn responder(self: *Context, operation: anytype, answer: anytype, responder_function: anytype, options: anytype) Error!HandlerResult(namedShape(.operation, @TypeOf(.{ .capability = operation })), index(.schema, @TypeOf(answer)), index(.schema, @TypeOf(answer)), @TypeOf(options)) {
        comptime {
            const Op = index(.operation, @TypeOf(operation));
            const F = index(.function, @TypeOf(responder_function));
            if (F != Dynamic and F.parameters != Dynamic) {
                const fields = @typeInfo(F.parameters).@"struct";
                if (fields.field_types.len != 1) @compileError("Horos responder: requires one payload parameter");
                if (Op != Dynamic) compatible(Op.payload, fields.field_types[0], "responder payload");
            }
            if (F != Dynamic and Op != Dynamic) compatible(Op.result, F.result, "responder reply");
        }
        const state = packSchemas(option(options, "state", .{}));
        try rawContext(self).validateResponder(erased(.operation, operation), erased(.function, responder_function), state.slice().len);
        const selected = try self.handler(operation, answer, answer, options);
        if (comptime knownMode(@TypeOf(options)) != null) {
            try rawContext(self).finishResponder(erased(.handler, selected), erased(.operation, operation), erased(.function, responder_function));
        } else switch (selected) {
            inline else => |h| try rawContext(self).finishResponder(erased(.handler, h), erased(.operation, operation), erased(.function, responder_function)),
        }
        return selected;
    }
    pub fn returnFunction(self: *Context, handler_handle: anytype) Error!*const Function(handlerReturnSignature(index(.handler, @TypeOf(handler_handle)))) {
        return @ptrCast(try rawContext(self).returnFunction(erased(.handler, handler_handle)));
    }
    pub fn clauseFunction(self: *Context, handler_handle: anytype) Error!*const Function(handlerClauseSignature(index(.handler, @TypeOf(handler_handle)), onlyOperation(index(.handler, @TypeOf(handler_handle))))) {
        return @ptrCast(try rawContext(self).clauseFunction(erased(.handler, handler_handle)));
    }
    pub fn clauseFunctionFor(self: *Context, handler_handle: anytype, operation: anytype) Error!*const Function(handlerClauseSignature(index(.handler, @TypeOf(handler_handle)), index(.operation, @TypeOf(operation)))) {
        return @ptrCast(try rawContext(self).clauseFunctionFor(erased(.handler, handler_handle), erased(.operation, operation)));
    }
    pub fn resumptionSchemaFor(self: *Context, handler_handle: anytype, operation: anytype) Error!*const Schema(handlerResumption(index(.handler, @TypeOf(handler_handle)), index(.operation, @TypeOf(operation)))) {
        return @ptrCast(try rawContext(self).resumptionSchemaFor(erased(.handler, handler_handle), erased(.operation, operation)));
    }
    pub fn handledSchema(self: *Context, handler_handle: anytype) Error!*const Schema(Internal(.{ .callable = handlerBodySignature(index(.handler, @TypeOf(handler_handle))) })) {
        return @ptrCast(try rawContext(self).handledSchema(erased(.handler, handler_handle)));
    }
    pub fn cloneableResumption(self: *Context, resumption: anytype) Error!*const Schema(index(.schema, @TypeOf(resumption))) {
        _ = comptime internalChild(index(.schema, @TypeOf(resumption)), .resumption, "cloneableResumption");
        return @ptrCast(try rawContext(self).cloneableResumption(erased(.schema, resumption)));
    }
    pub fn suspensionPackage(self: *Context, resumption: anytype) Error!*const Schema(Internal(.{ .package = index(.schema, @TypeOf(resumption)) })) {
        _ = comptime internalChild(index(.schema, @TypeOf(resumption)), .resumption, "suspensionPackage");
        return @ptrCast(try rawContext(self).suspensionPackage(erased(.schema, resumption)));
    }
    pub fn literalFailure(self: *Context, comptime T: type, value: T) Error!*const FailureLiteral(Shape(T)) {
        return @ptrCast(try rawContext(self).literalFailure(T, value));
    }
    pub fn function(self: *Context, name: []const u8, params: anytype, returns: anytype, allowed: anytype) Error!*const Function(Signature(namedShape(.schema, @TypeOf(params)), index(.schema, @TypeOf(returns)))) {
        const fields = packSchemas(params);
        const effects = handles(.operation, allowed);
        return @ptrCast(try rawContext(self).function(name, fields.slice(), erased(.schema, returns), effects.slice()));
    }
    pub fn body(self: *Context, function_handle: anytype) Error!*Body(parameters(index(.function, @TypeOf(function_handle)))) {
        return @ptrCast(try rawContext(self).body(erased(.function, function_handle)));
    }
    pub fn define(self: *Context, function_handle: anytype, computation: anytype) Error!void {
        comptime compatible(resultShape(index(.function, @TypeOf(function_handle))), index(.computation, @TypeOf(computation)), "define result");
        return rawContext(self).define(erased(.function, function_handle), erased(.computation, computation));
    }
    pub fn module(self: *Context, entry: anytype, failure: anytype) Error!source.Module {
        return rawContext(self).module(erased(.function, entry), erased(.schema, failure));
    }
    pub fn compile(self: *Context, allocator: std.mem.Allocator, entry: anytype, failure: anytype) Error!source.Compiled {
        return rawContext(self).compile(allocator, erased(.function, entry), erased(.schema, failure));
    }
    pub fn compileWithOptions(self: *Context, allocator: std.mem.Allocator, entry: anytype, failure: anytype, options: data.coalescing.Options) Error!source.Compiled {
        return rawContext(self).compileWithOptions(allocator, erased(.function, entry), erased(.schema, failure), options);
    }
    pub fn compileWithCompilation(self: *Context, allocator: std.mem.Allocator, entry: anytype, failure: anytype, options: data.closed_compilation.Options) Error!source.Compiled {
        return rawContext(self).compileWithCompilation(allocator, erased(.function, entry), erased(.schema, failure), options);
    }
};

pub fn Body(comptime Parameters: type) type {
    return opaque {
        const Self = @This();
        pub const horos_handle: Metadata = .{ .family = .body, .shape = Parameters };
        fn raw(self: *Self) *runtime.Body {
            return @ptrCast(self);
        }
        pub fn parameter(self: *Self, comptime name: []const u8) Error!*const Value(child(Parameters, name, "parameter")) {
            return @ptrCast(try self.raw().parameter(name));
        }
        pub fn constant(self: *Self, comptime T: type, value: T) Error!*const Value(Shape(T)) {
            return @ptrCast(try self.raw().constant(T, value));
        }
        pub fn field(self: *Self, value: anytype, comptime name: []const u8) Error!*const Value(child(productFields(index(.value, @TypeOf(value)), "field"), name, "field")) {
            return @ptrCast(try self.raw().field(erased(.value, value), name));
        }
        pub fn variant(self: *Self, schema_handle: anytype, comptime name: []const u8, payload: anytype) Error!*const Value(index(.schema, @TypeOf(schema_handle))) {
            comptime compatible(child(sumFields(index(.schema, @TypeOf(schema_handle)), "variant"), name, "variant"), index(.value, @TypeOf(payload)), "variant." ++ name);
            return @ptrCast(try self.raw().variant(erased(.schema, schema_handle), name, erased(.value, payload)));
        }
        pub fn caseOf(self: *Self, sum: anytype, comptime name: []const u8) Error!*const Case(caseSignature(index(.value, @TypeOf(sum)), name)) {
            return @ptrCast(try self.raw().caseOf(erased(.value, sum), name));
        }
        pub fn match(self: *Self, sum: anytype, cases: anytype) Error!*const Value(matchResult(index(.value, @TypeOf(sum)), @TypeOf(cases))) {
            const packed_cases = packNamed(.finished_case, cases);
            return @ptrCast(try self.raw().matchNamed(erased(.value, sum), packed_cases.slice()));
        }
        pub fn destructure(self: *Self, value: anytype) Error!*const ProductParts(index(.value, @TypeOf(value))) {
            _ = comptime productFields(index(.value, @TypeOf(value)), "destructure");
            return @ptrCast(try self.raw().destructure(erased(.value, value)));
        }
        pub fn product(self: *Self, schema_handle: anytype, values: anytype) Error!*const Value(index(.schema, @TypeOf(schema_handle))) {
            const args = packArguments(productFields(index(.schema, @TypeOf(schema_handle)), "product"), values, "product");
            return @ptrCast(try self.raw().product(erased(.schema, schema_handle), args.slice()));
        }
        pub fn call(self: *Self, function_handle: anytype, values: anytype) Error!*const Value(resultShape(index(.function, @TypeOf(function_handle)))) {
            const args = packArguments(parameters(index(.function, @TypeOf(function_handle))), values, "call");
            return @ptrCast(try self.raw().call(erased(.function, function_handle), args.slice()));
        }
        pub fn perform(self: *Self, operation: anytype, payload: anytype) Error!*const Value(resultShape(index(.operation, @TypeOf(operation)))) {
            const Op = index(.operation, @TypeOf(operation));
            if (comptime Op != Dynamic) comptime compatible(Op.payload, index(.value, @TypeOf(payload)), "perform payload");
            return @ptrCast(try self.raw().perform(erased(.operation, operation), erased(.value, payload)));
        }
        pub fn performLocal(self: *Self, operation: anytype, capability: anytype, payload: anytype) Error!*const Value(resultShape(index(.operation, @TypeOf(operation)))) {
            const Op = index(.operation, @TypeOf(operation));
            if (comptime Op != Dynamic) comptime compatible(Op.payload, index(.value, @TypeOf(payload)), "performLocal payload");
            comptime compatible(Internal(.{ .capability = Op }), index(.value, @TypeOf(capability)), "performLocal capability");
            return @ptrCast(try self.raw().performLocal(erased(.operation, operation), erased(.value, capability), erased(.value, payload)));
        }
        pub fn performScoped(self: *Self, operation: anytype, capability: anytype, payload: anytype, bodies: anytype) Error!*const Value(resultShape(index(.operation, @TypeOf(operation)))) {
            const Op = index(.operation, @TypeOf(operation));
            if (comptime Op != Dynamic) comptime compatible(Op.payload, index(.value, @TypeOf(payload)), "performScoped payload");
            comptime compatible(Internal(.{ .capability = Op }), index(.value, @TypeOf(capability)), "performScoped capability");
            const args = packArguments(if (Op == Dynamic) Dynamic else Op.bodies, bodies, "performScoped bodies");
            return @ptrCast(try self.raw().performScoped(erased(.operation, operation), erased(.value, capability), erased(.value, payload), args.slice()));
        }
        pub fn closureBody(self: *Self, function_handle: anytype) Error!*Body(parameters(index(.function, @TypeOf(function_handle)))) {
            return @ptrCast(try self.raw().closureBody(erased(.function, function_handle)));
        }
        pub fn lambda(self: *Self, function_handle: anytype, schema_handle: anytype) Error!*const Value(index(.schema, @TypeOf(schema_handle))) {
            comptime compatibleSignature(callableSignature(index(.schema, @TypeOf(schema_handle)), "lambda"), index(.function, @TypeOf(function_handle)), "lambda");
            return @ptrCast(try self.raw().lambda(erased(.function, function_handle), erased(.schema, schema_handle)));
        }
        pub fn apply(self: *Self, callable: anytype, values: anytype) Error!*const Value(resultShape(callableSignature(index(.value, @TypeOf(callable)), "apply"))) {
            const args = packArguments(parameters(callableSignature(index(.value, @TypeOf(callable)), "apply")), values, "apply");
            return @ptrCast(try self.raw().apply(erased(.value, callable), args.slice()));
        }
        pub fn cloneResumption(self: *Self, target: anytype, resumption: anytype) Error!*const Value(index(.schema, @TypeOf(target))) {
            _ = comptime internalChild(index(.schema, @TypeOf(target)), .resumption, "cloneResumption");
            comptime compatible(index(.schema, @TypeOf(target)), index(.value, @TypeOf(resumption)), "cloneResumption target");
            return @ptrCast(try self.raw().cloneResumption(erased(.schema, target), erased(.value, resumption)));
        }
        pub fn resumeValue(self: *Self, resumption: anytype, reply: anytype) Error!*const Value(resultShape(internalChild(index(.value, @TypeOf(resumption)), .resumption, "resumeValue"))) {
            const R = internalChild(index(.value, @TypeOf(resumption)), .resumption, "resumeValue");
            if (comptime R != Dynamic) comptime compatible(R.reply, index(.value, @TypeOf(reply)), "resumeValue reply");
            return @ptrCast(try self.raw().resumeValue(erased(.value, resumption), erased(.value, reply)));
        }
        pub fn resumeWith(self: *Self, resumption: anytype, reply: anytype, successor: anytype, state: anytype) Error!*const Value(resultShape(index(.handler, @TypeOf(successor)))) {
            const R = internalChild(index(.value, @TypeOf(resumption)), .resumption, "resumeWith");
            const H = index(.handler, @TypeOf(successor));
            comptime {
                if (R != Dynamic) {
                    if (R.mode != .shallow) @compileError("Horos resumeWith: requires a shallow resumption");
                    compatible(R.reply, index(.value, @TypeOf(reply)), "resumeWith reply");
                    if (H != Dynamic) compatible(R.result, H.input, "resumeWith successor input");
                }
            }
            const args = packArguments(if (H == Dynamic) Dynamic else H.state, state, "resumeWith state");
            return @ptrCast(try self.raw().resumeWith(erased(.value, resumption), erased(.value, reply), erased(.handler, successor), args.slice()));
        }
        pub fn handleWith(self: *Self, handler_handle: anytype, callable: anytype, state: anytype) Error!*const Value(resultShape(index(.handler, @TypeOf(handler_handle)))) {
            return self.handleWithArguments(handler_handle, callable, .{}, state);
        }
        pub fn handleWithArguments(self: *Self, handler_handle: anytype, callable: anytype, args: anytype, state: anytype) Error!*const Value(resultShape(index(.handler, @TypeOf(handler_handle)))) {
            const H = index(.handler, @TypeOf(handler_handle));
            comptime compatibleSignature(handlerBodySignature(H), callableSignature(index(.value, @TypeOf(callable)), "handleWith"), "handleWith body");
            const arguments_list = packArguments(if (H == Dynamic) Dynamic else H.body_parameters, args, "handleWith arguments");
            const states = packArguments(if (H == Dynamic) Dynamic else H.state, state, "handleWith state");
            return @ptrCast(try self.raw().handleWithArguments(erased(.handler, handler_handle), erased(.value, callable), arguments_list.slice(), states.slice()));
        }
        pub fn package(self: *Self, resumption: anytype) Error!*const Value(Internal(.{ .package = index(.value, @TypeOf(resumption)) })) {
            _ = comptime internalChild(index(.value, @TypeOf(resumption)), .resumption, "package");
            return @ptrCast(try self.raw().package(erased(.value, resumption)));
        }
        pub fn unpack(self: *Self, package_value: anytype) Error!*const Value(internalChild(index(.value, @TypeOf(package_value)), .package, "unpack")) {
            return @ptrCast(try self.raw().unpack(erased(.value, package_value)));
        }
        pub fn resumePackage(self: *Self, package_value: anytype, reply: anytype) Error!*const Value(resultShape(internalChild(internalChild(index(.value, @TypeOf(package_value)), .package, "resumePackage"), .resumption, "resumePackage"))) {
            const R = internalChild(internalChild(index(.value, @TypeOf(package_value)), .package, "resumePackage"), .resumption, "resumePackage");
            comptime compatible(if (R == Dynamic) Dynamic else R.reply, index(.value, @TypeOf(reply)), "resumePackage reply");
            return @ptrCast(try self.raw().resumePackage(erased(.value, package_value), erased(.value, reply)));
        }
        pub fn dispose(self: *Self, owned: anytype) Error!*const Value(Shape(void)) {
            return @ptrCast(try self.raw().dispose(erased(.value, owned)));
        }
        pub fn disposePackage(self: *Self, package_value: anytype) Error!*const Value(Shape(void)) {
            return @ptrCast(try self.raw().disposePackage(erased(.value, package_value)));
        }
        pub fn withRegion(self: *Self, region_handle: *const Region, work: anytype, args: anytype) Error!*const Value(resultShape(callableSignature(index(.value, @TypeOf(work)), "withRegion"))) {
            const Sig = callableSignature(index(.value, @TypeOf(work)), "withRegion");
            comptime compatible(Internal(.region), firstParameter(parameters(Sig), "withRegion"), "withRegion token");
            const packed_args = packArguments(dropFirst(parameters(Sig), "withRegion"), args, "withRegion arguments");
            return @ptrCast(try self.raw().withRegion(region_handle, erased(.value, work), packed_args.slice()));
        }
        pub fn protect(self: *Self, work: anytype, cleanup: anytype, args: anytype) Error!*const Value(resultShape(callableSignature(index(.value, @TypeOf(work)), "protect"))) {
            const Sig = callableSignature(index(.value, @TypeOf(work)), "protect");
            const Cleanup = callableSignature(index(.value, @TypeOf(cleanup)), "protect cleanup");
            comptime if (Cleanup != Dynamic and Cleanup.parameters != Dynamic and @typeInfo(Cleanup.parameters).@"struct".field_types.len != 1) @compileError("Horos protect: cleanup requires one exit-information parameter");
            const packed_args = packArguments(parameters(Sig), args, "protect arguments");
            return @ptrCast(try self.raw().protect(erased(.value, work), erased(.value, cleanup), packed_args.slice()));
        }
        pub fn bracket(self: *Self, resource: anytype, region_handle: *const Region, work: anytype, cleanup: anytype, args: anytype) Error!*const Value(resultShape(callableSignature(index(.value, @TypeOf(work)), "bracket"))) {
            const S = index(.value, @TypeOf(resource));
            const Sig = callableSignature(index(.value, @TypeOf(work)), "bracket");
            const Cleanup = callableSignature(index(.value, @TypeOf(cleanup)), "bracket cleanup");
            comptime {
                _ = internalChild(S, .resource, "bracket resource");
                compatible(Internal(.{ .borrowed = S }), firstParameter(parameters(Sig), "bracket"), "bracket loan");
                if (Cleanup != Dynamic) {
                    compatible(Shape(void), Cleanup.result, "bracket cleanup result");
                    if (Cleanup.parameters != Dynamic) {
                        const fields = @typeInfo(Cleanup.parameters).@"struct";
                        if (fields.field_types.len != 2) @compileError("Horos bracket: cleanup requires exit-information and resource parameters");
                        compatible(S, fields.field_types[1], "bracket cleanup owner");
                    }
                }
            }
            const packed_args = packArguments(dropFirst(parameters(Sig), "bracket"), args, "bracket arguments");
            return @ptrCast(try self.raw().bracket(erased(.value, resource), region_handle, erased(.value, work), erased(.value, cleanup), packed_args.slice()));
        }
        pub fn newCell(self: *Self, schema_handle: anytype, region_value: anytype, initial: anytype) Error!*const Value(index(.schema, @TypeOf(schema_handle))) {
            comptime compatible(internalChild(index(.schema, @TypeOf(schema_handle)), .cell, "newCell"), index(.value, @TypeOf(initial)), "newCell initial");
            comptime compatible(Internal(.region), index(.value, @TypeOf(region_value)), "newCell region");
            return @ptrCast(try self.raw().newCell(erased(.schema, schema_handle), erased(.value, region_value), erased(.value, initial)));
        }
        pub fn readCell(self: *Self, cell_value: anytype) Error!*const Value(internalChild(index(.value, @TypeOf(cell_value)), .cell, "readCell")) {
            return @ptrCast(try self.raw().readCell(erased(.value, cell_value)));
        }
        pub fn writeCell(self: *Self, cell_value: anytype, value: anytype) Error!*const Value(Shape(void)) {
            comptime compatible(internalChild(index(.value, @TypeOf(cell_value)), .cell, "writeCell"), index(.value, @TypeOf(value)), "writeCell value");
            return @ptrCast(try self.raw().writeCell(erased(.value, cell_value), erased(.value, value)));
        }
        pub fn packResource(self: *Self, schema_handle: anytype, representation: anytype) Error!*const Value(index(.schema, @TypeOf(schema_handle))) {
            comptime compatible(internalChild(index(.schema, @TypeOf(schema_handle)), .resource, "packResource"), index(.value, @TypeOf(representation)), "packResource representation");
            return @ptrCast(try self.raw().packResource(erased(.schema, schema_handle), erased(.value, representation)));
        }
        pub fn unpackResource(self: *Self, value: anytype) Error!*const Value(resourceRepresentation(index(.value, @TypeOf(value)))) {
            return @ptrCast(try self.raw().unpackResource(erased(.value, value)));
        }
        pub fn sequenceValue(self: *Self, schema_handle: anytype, items: anytype) Error!*const Value(index(.schema, @TypeOf(schema_handle))) {
            const S = index(.schema, @TypeOf(schema_handle));
            comptime {
                checkElements(sequenceElement(S, "sequenceValue"), @TypeOf(items), "sequenceValue");
                if (S != Dynamic) if (listCount(@TypeOf(items))) |count| {
                    if (S.contract == .array and count != S.contract.array.length) @compileError("Horos sequenceValue: wrong array length");
                    if (S.contract == .sequence) if (S.contract.sequence.maximum) |maximum| {
                        if (count > maximum) @compileError("Horos sequenceValue: vector maximum exceeded");
                    };
                };
            }
            const values = handles(.value, items);
            return @ptrCast(try self.raw().sequenceValue(erased(.schema, schema_handle), values.slice()));
        }
        pub fn sequenceLength(self: *Self, sequence: anytype) Error!*const Value(Shape(u64)) {
            _ = comptime sequenceElement(index(.value, @TypeOf(sequence)), "sequenceLength");
            return @ptrCast(try self.raw().sequenceLength(erased(.value, sequence)));
        }
        pub fn sequenceGet(self: *Self, sequence: anytype, offset: anytype) Error!*const Value(OptionalShape(sequenceElement(index(.value, @TypeOf(sequence)), "sequenceGet"))) {
            comptime compatible(Shape(u64), index(.value, @TypeOf(offset)), "sequenceGet index");
            return @ptrCast(try self.raw().sequenceGet(erased(.value, sequence), erased(.value, offset)));
        }
        pub fn sequenceSet(self: *Self, sequence: anytype, offset: anytype, element: anytype, failure: anytype) Error!*const Value(index(.value, @TypeOf(sequence))) {
            comptime compatible(Shape(u64), index(.value, @TypeOf(offset)), "sequenceSet index");
            comptime compatible(sequenceElement(index(.value, @TypeOf(sequence)), "sequenceSet"), index(.value, @TypeOf(element)), "sequenceSet element");
            return @ptrCast(try self.raw().sequenceSet(erased(.value, sequence), erased(.value, offset), erased(.value, element), erased(.failure_literal, failure)));
        }
        pub fn sequenceTake(self: *Self, sequence: anytype, length: anytype) Error!*const Value(index(.value, @TypeOf(sequence))) {
            comptime requireSequence(index(.value, @TypeOf(sequence)), "sequenceTake");
            comptime compatible(Shape(u64), index(.value, @TypeOf(length)), "sequenceTake length");
            return @ptrCast(try self.raw().sequenceTake(erased(.value, sequence), erased(.value, length)));
        }
        pub fn append(self: *Self, sequence: anytype, element: anytype, options: anytype) Error!*const Value(index(.value, @TypeOf(sequence))) {
            const S = index(.value, @TypeOf(sequence));
            comptime compatible(sequenceElement(S, "append"), index(.value, @TypeOf(element)), "append element");
            return @ptrCast(try self.raw().appendChecked(erased(.value, sequence), erased(.value, element), capacityFailure(S, options, "append")));
        }
        pub fn concat(self: *Self, left: anytype, right: anytype, options: anytype) Error!*const Value(index(.value, @TypeOf(left))) {
            const S = index(.value, @TypeOf(left));
            comptime compatible(S, index(.value, @TypeOf(right)), "concat operands");
            return @ptrCast(try self.raw().concatChecked(erased(.value, left), erased(.value, right), capacityFailure(S, options, "concat")));
        }
        pub fn pop(self: *Self, sequence: anytype) Error!*const Value(PopShape(index(.value, @TypeOf(sequence)))) {
            return @ptrCast(try self.raw().pop(erased(.value, sequence)));
        }
        pub fn sequencePopLast(self: *Self, sequence: anytype) Error!*const Value(PopLastShape(index(.value, @TypeOf(sequence)))) {
            return @ptrCast(try self.raw().sequencePopLast(erased(.value, sequence)));
        }
        pub fn update(self: *Self, value: anytype, replacements: anytype) Error!*const Value(index(.value, @TypeOf(value))) {
            comptime {
                const Fields = productFields(index(.value, @TypeOf(value)), "update");
                if (@TypeOf(replacements) != *const interop.RuntimeNamed(.value)) {
                    const supplied = fieldsInfo(@TypeOf(replacements), "update");
                    for (supplied.field_names, supplied.field_types) |name, T| compatible(child(Fields, name, "update"), index(.value, T), "update." ++ name);
                }
            }
            const args = packArguments(Dynamic, replacements, "update");
            return @ptrCast(try self.raw().update(erased(.value, value), args.slice()));
        }
        pub fn convertInteger(self: *Self, target: anytype, value: anytype, options: anytype) Error!*const Value(index(.schema, @TypeOf(target))) {
            const Target = index(.schema, @TypeOf(target));
            const From = index(.value, @TypeOf(value));
            comptime {
                requireInteger(Target, "convertInteger target");
                requireInteger(From, "convertInteger source");
                if (Target != Dynamic and From != Dynamic) {
                    const needed = data.scalar.conversionCanFail(@unionInit(p.Schema, @typeName(From.contract.integer), {}), @unionInit(p.Schema, @typeName(Target.contract.integer), {}));
                    if (needed != @hasField(@TypeOf(options), "overflow")) @compileError("Horos convertInteger: overflow failure required exactly for a narrowing conversion");
                }
            }
            return @ptrCast(try self.raw().convertInteger(erased(.schema, target), erased(.value, value), if (@hasField(@TypeOf(options), "overflow")) erased(.failure_literal, options.overflow) else null));
        }
        pub fn booleanNot(self: *Self, value: anytype) Error!*const Value(Shape(bool)) {
            comptime compatible(Shape(bool), index(.value, @TypeOf(value)), "booleanNot");
            return @ptrCast(try self.raw().booleanNot(erased(.value, value)));
        }
        pub fn bitNot(self: *Self, value: anytype) Error!*const Value(index(.value, @TypeOf(value))) {
            comptime requireInteger(index(.value, @TypeOf(value)), "bitNot");
            return @ptrCast(try self.raw().bitNot(erased(.value, value)));
        }
        pub fn bitwise(self: *Self, operation: @typeInfo(@TypeOf(runtime.Body.bitwise)).@"fn".param_types[1].?, left: anytype, right: anytype) Error!*const Value(index(.value, @TypeOf(left))) {
            comptime requireInteger(index(.value, @TypeOf(left)), "bitwise");
            comptime compatible(index(.value, @TypeOf(left)), index(.value, @TypeOf(right)), "bitwise operands");
            return @ptrCast(try self.raw().bitwise(operation, erased(.value, left), erased(.value, right)));
        }
        pub fn textInteger(self: *Self, value: anytype) Error!*const Value(Shape(native.Text(null))) {
            comptime requireInteger(index(.value, @TypeOf(value)), "textInteger");
            return @ptrCast(try self.raw().textInteger(erased(.value, value)));
        }
        pub fn textScalar(self: *Self, value: anytype, failure: anytype) Error!*const Value(Shape(native.Text(null))) {
            comptime compatible(Shape(u32), index(.value, @TypeOf(value)), "textScalar");
            return @ptrCast(try self.raw().textScalar(erased(.value, value), erased(.failure_literal, failure)));
        }
        pub fn blobFromByte(self: *Self, value: anytype) Error!*const Value(Shape(native.Bytes(null))) {
            comptime compatible(Shape(u8), index(.value, @TypeOf(value)), "blobFromByte");
            return @ptrCast(try self.raw().blobFromByte(erased(.value, value)));
        }
        pub fn blobConcat(self: *Self, target: anytype, left: anytype, right: anytype, failure: anytype) Error!*const Value(index(.schema, @TypeOf(target))) {
            comptime compatibleBlob(index(.schema, @TypeOf(target)), index(.value, @TypeOf(left)), "blobConcat left");
            comptime compatibleBlob(index(.schema, @TypeOf(target)), index(.value, @TypeOf(right)), "blobConcat right");
            return @ptrCast(try self.raw().blobConcat(erased(.schema, target), erased(.value, left), erased(.value, right), erased(.failure_literal, failure)));
        }
        pub fn blobSlice(self: *Self, target: anytype, value: anytype, start: anytype, length: anytype, options: anytype) Error!*const Value(index(.schema, @TypeOf(target))) {
            const S = index(.schema, @TypeOf(target));
            comptime {
                compatibleBlob(S, index(.value, @TypeOf(value)), "blobSlice value");
                compatible(Shape(u64), index(.value, @TypeOf(start)), "blobSlice start");
                compatible(Shape(u64), index(.value, @TypeOf(length)), "blobSlice length");
                if (S != Dynamic and (S.contract == .text) != @hasField(@TypeOf(options), "invalid_utf8")) @compileError("Horos blobSlice: invalid_utf8 failure required exactly for text");
            }
            return @ptrCast(try self.raw().blobSlice(erased(.schema, target), erased(.value, value), erased(.value, start), erased(.value, length), erased(.failure_literal, options.capacity), if (@hasField(@TypeOf(options), "invalid_utf8")) erased(.failure_literal, options.invalid_utf8) else null));
        }
        pub fn blobLength(self: *Self, blob: anytype) Error!*const Value(Shape(u64)) {
            comptime requireBlob(index(.value, @TypeOf(blob)), "blobLength");
            return @ptrCast(try self.raw().blobLength(erased(.value, blob)));
        }
        pub fn blobByte(self: *Self, blob: anytype, offset: anytype) Error!*const Value(OptionalShape(Shape(u8))) {
            comptime requireBlob(index(.value, @TypeOf(blob)), "blobByte");
            comptime compatible(Shape(u64), index(.value, @TypeOf(offset)), "blobByte index");
            return @ptrCast(try self.raw().blobByte(erased(.value, blob), erased(.value, offset)));
        }
        pub fn blobCompare(self: *Self, left: anytype, right: anytype) Error!*const Value(Shape(i8)) {
            comptime requireBlob(index(.value, @TypeOf(left)), "blobCompare");
            comptime compatible(index(.value, @TypeOf(left)), index(.value, @TypeOf(right)), "blobCompare operands");
            return @ptrCast(try self.raw().blobCompare(erased(.value, left), erased(.value, right)));
        }
        pub fn enumTag(self: *Self, value: anytype) Error!*const Value(Shape(u32)) {
            const S = index(.value, @TypeOf(value));
            if (comptime S != Dynamic) if (!@hasDecl(S, "contract") or S.contract != .enumeration) @compileError("Horos enumTag: expected enumeration");
            return @ptrCast(try self.raw().enumTag(erased(.value, value)));
        }
        pub fn variantTag(self: *Self, value: anytype) Error!*const Value(Shape(u64)) {
            _ = comptime sumFields(index(.value, @TypeOf(value)), "variantTag");
            return @ptrCast(try self.raw().variantTag(erased(.value, value)));
        }
        pub fn variantPayload(self: *Self, value: anytype, comptime name: []const u8, failure: anytype) Error!*const Value(child(sumFields(index(.value, @TypeOf(value)), "variantPayload"), name, "variantPayload")) {
            return @ptrCast(try self.raw().variantPayload(erased(.value, value), name, erased(.failure_literal, failure)));
        }
        pub fn yieldNow(self: *Self) Error!*const Value(Shape(void)) {
            return @ptrCast(try self.raw().yieldNow());
        }
        pub fn checked(self: *Self, operation: Arithmetic, left: anytype, right: anytype, failures: anytype) Error!*const Value(index(.value, @TypeOf(left))) {
            comptime requireInteger(index(.value, @TypeOf(left)), "checked arithmetic");
            comptime compatible(index(.value, @TypeOf(left)), index(.value, @TypeOf(right)), "checked arithmetic operands");
            return @ptrCast(try self.raw().checked(operation, erased(.value, left), erased(.value, right), .{
                .overflow = erased(.failure_literal, failures.overflow),
                .division_by_zero = if (@hasField(@TypeOf(failures), "division_by_zero")) optionalFailure(failures.division_by_zero) else null,
            }));
        }
        pub fn equal(self: *Self, left: anytype, right: anytype) Error!*const Value(Shape(bool)) {
            comptime compatible(index(.value, @TypeOf(left)), index(.value, @TypeOf(right)), "equal operands");
            return @ptrCast(try self.raw().equal(erased(.value, left), erased(.value, right)));
        }
        pub fn less(self: *Self, left: anytype, right: anytype) Error!*const Value(Shape(bool)) {
            comptime compatible(index(.value, @TypeOf(left)), index(.value, @TypeOf(right)), "less operands");
            comptime requireInteger(index(.value, @TypeOf(left)), "less");
            return @ptrCast(try self.raw().less(erased(.value, left), erased(.value, right)));
        }
        pub fn select(self: *Self, condition: anytype, yes: anytype, no: anytype) Error!*const Value(index(.value, @TypeOf(yes))) {
            comptime compatible(Shape(bool), index(.value, @TypeOf(condition)), "select condition");
            comptime compatible(index(.value, @TypeOf(yes)), index(.value, @TypeOf(no)), "select operands");
            return @ptrCast(try self.raw().select(erased(.value, condition), erased(.value, yes), erased(.value, no)));
        }
        pub fn checkedAdd(self: *Self, left: anytype, right: anytype, failure: anytype) Error!*const Value(index(.value, @TypeOf(left))) {
            comptime compatible(index(.value, @TypeOf(left)), index(.value, @TypeOf(right)), "checkedAdd operands");
            comptime requireInteger(index(.value, @TypeOf(left)), "checkedAdd");
            return @ptrCast(try self.raw().checkedAdd(erased(.value, left), erased(.value, right), erased(.failure_literal, failure)));
        }
        pub fn branch(self: *Self) Error!*Body(native.Fields(&.{}, &.{})) {
            return @ptrCast(try self.raw().branch());
        }
        pub fn block(self: *Self, computation: anytype) Error!*const Value(index(.computation, @TypeOf(computation))) {
            return @ptrCast(try self.raw().block(erased(.computation, computation)));
        }
        pub fn conditional(self: *Self, condition: anytype, yes: anytype, no: anytype) Error!*const Value(index(.computation, @TypeOf(yes))) {
            comptime compatible(Shape(bool), index(.value, @TypeOf(condition)), "conditional condition");
            comptime compatible(index(.computation, @TypeOf(yes)), index(.computation, @TypeOf(no)), "conditional result");
            return @ptrCast(try self.raw().conditional(erased(.value, condition), erased(.computation, yes), erased(.computation, no)));
        }
        pub fn ret(self: *Self, value: anytype) Error!*const Computation(index(.value, @TypeOf(value))) {
            return @ptrCast(try self.raw().ret(erased(.value, value)));
        }
        pub fn fail(self: *Self, returns: anytype, failure: anytype) Error!*const Computation(index(.schema, @TypeOf(returns))) {
            return @ptrCast(try self.raw().fail(erased(.schema, returns), erased(.value, failure)));
        }
        pub fn abandon(self: *Self) void {
            self.raw().abandon();
        }
    };
}

pub const interop = struct {
    pub fn NamedEntry(comptime family: Family) type {
        return struct { name: []const u8, handle: *const canonical(family, Dynamic) };
    }
    pub fn RuntimeNamed(comptime family: Family) type {
        _ = RawNamed(family);
        return opaque {
            const Self = @This();
            pub fn len(self: *const Self) usize {
                const stored: *const NamedData(family) = @ptrCast(@alignCast(self));
                return stored.entries.len;
            }
            pub fn at(self: *const Self, offset: usize) ?NamedEntry(family) {
                const stored: *const NamedData(family) = @ptrCast(@alignCast(self));
                if (offset >= stored.entries.len) return null;
                const item = stored.entries[offset];
                return .{ .name = item.name, .handle = @ptrCast(if (family == .schema) item.schema else if (family == .operation) item.operation else item.value) };
            }
            pub fn init(c: *Context, entries: []const NamedEntry(family)) Error!*const Self {
                const Raw = RawNamed(family);
                const allocator = builder(c).arena.child_allocator;
                const temporary = try runtime.interop.namedTemporary(rawContext(c), Raw, entries.len);
                defer allocator.free(temporary);
                for (entries, temporary) |entry, *target| {
                    target.* = if (family == .schema)
                        .{ .name = entry.name, .schema = erased(.schema, entry.handle) }
                    else if (family == .operation)
                        .{ .name = entry.name, .operation = erased(.operation, entry.handle) }
                    else
                        .{ .name = entry.name, .value = erased(family, entry.handle) };
                }
                const saved = switch (family) {
                    .schema => try runtime.interop.namedFields(rawContext(c), temporary),
                    .value => try runtime.interop.namedArguments(rawContext(c), temporary),
                    .operation => try runtime.interop.namedOperations(rawContext(c), temporary),
                    .finished_case => try runtime.interop.namedCases(rawContext(c), temporary),
                    else => unreachable,
                };
                return @ptrCast(try runtime.interop.namedStorage(rawContext(c), NamedData(family), .{ .entries = saved }));
            }
        };
    }
    pub fn field(body: anytype, value: anytype, name: []const u8) Error!*const Value(Dynamic) {
        _ = comptime index(.body, @TypeOf(body));
        const raw_body: *runtime.Body = @ptrCast(body);
        return @ptrCast(try raw_body.field(erased(.value, value), name));
    }
    /// Select a destructured field at runtime, retaining the consuming unpack.
    pub fn get(parts: anytype, name: []const u8) Error!*const Value(Dynamic) {
        return @ptrCast(try erased(.product_parts, parts).get(name));
    }
    /// The arm is runtime-selected; the checked result retains the whole sum.
    pub fn variant(body: anytype, schema_handle: anytype, name: []const u8, payload: anytype) Error!*const Value(index(.schema, @TypeOf(schema_handle))) {
        _ = comptime index(.body, @TypeOf(body));
        _ = comptime sumFields(index(.schema, @TypeOf(schema_handle)), "interop.variant");
        const raw_body: *runtime.Body = @ptrCast(body);
        return @ptrCast(try raw_body.variant(erased(.schema, schema_handle), name, erased(.value, payload)));
    }
    pub fn parameter(body: anytype, name: []const u8) Error!*const Value(Dynamic) {
        _ = comptime index(.body, @TypeOf(body));
        const raw_body: *runtime.Body = @ptrCast(body);
        return @ptrCast(try raw_body.parameter(name));
    }
    pub fn caseOf(body: anytype, sum: anytype, name: []const u8) Error!*const Case(Dynamic) {
        _ = comptime index(.body, @TypeOf(body));
        const raw_body: *runtime.Body = @ptrCast(body);
        return @ptrCast(try raw_body.caseOf(erased(.value, sum), name));
    }
    pub fn variantPayload(body: anytype, sum: anytype, name: []const u8, failure: anytype) Error!*const Value(Dynamic) {
        _ = comptime index(.body, @TypeOf(body));
        const raw_body: *runtime.Body = @ptrCast(body);
        return @ptrCast(try raw_body.variantPayload(erased(.value, sum), name, erased(.failure_literal, failure)));
    }
    pub fn schema(c: *Context, id: p.Id) Error!*const Schema(Dynamic) {
        return @ptrCast(try runtime.interop.schema(rawContext(c), id));
    }
    pub fn refineSchema(c: *Context, current: anytype, expected: anytype) Error!*const Schema(index(.schema, @TypeOf(expected))) {
        comptime compatible(index(.schema, @TypeOf(expected)), index(.schema, @TypeOf(current)), "refineSchema");
        return @ptrCast(try runtime.interop.refineSchema(rawContext(c), erased(.schema, current), erased(.schema, expected), false));
    }
    /// Imported portable fields have positions, not authoring names. This
    /// explicit mapping validates their contract and supplies expected names.
    pub fn mapSchema(c: *Context, imported: anytype, expected: anytype) Error!*const Schema(index(.schema, @TypeOf(expected))) {
        return @ptrCast(try runtime.interop.refineSchema(rawContext(c), erased(.schema, imported), erased(.schema, expected), true));
    }
    pub fn refineValue(body: anytype, value: anytype, expected: anytype) Error!*const Value(index(.schema, @TypeOf(expected))) {
        _ = comptime index(.body, @TypeOf(body));
        comptime compatible(index(.schema, @TypeOf(expected)), index(.value, @TypeOf(value)), "refineValue");
        return @ptrCast(try runtime.interop.refineValue(@ptrCast(body), erased(.value, value), erased(.schema, expected), false));
    }
    pub fn mapValue(body: anytype, value: anytype, expected: anytype) Error!*const Value(index(.schema, @TypeOf(expected))) {
        _ = comptime index(.body, @TypeOf(body));
        return @ptrCast(try runtime.interop.refineValue(@ptrCast(body), erased(.value, value), erased(.schema, expected), true));
    }
    pub fn refineFunction(c: *Context, function_handle: anytype, expected: anytype) Error!*const Function(callableSignature(index(.schema, @TypeOf(expected)), "refineFunction")) {
        comptime compatibleSignature(callableSignature(index(.schema, @TypeOf(expected)), "refineFunction"), index(.function, @TypeOf(function_handle)), "refineFunction");
        return @ptrCast(try runtime.interop.refineFunction(rawContext(c), erased(.function, function_handle), erased(.schema, expected)));
    }
    pub fn declaredFunction(c: *Context, id: p.Id) Error!*const Function(Dynamic) {
        return @ptrCast(try runtime.interop.declaredFunction(rawContext(c), id));
    }
    pub fn externalOperation(c: *Context, id: p.Id, payload: anytype, result: anytype) Error!*const Operation(OperationSignature(index(.schema, @TypeOf(payload)), index(.schema, @TypeOf(result)), native.Fields(&.{}, &.{}))) {
        return @ptrCast(try runtime.interop.externalOperation(rawContext(c), id, erased(.schema, payload), erased(.schema, result)));
    }
    pub fn performSite(body: anytype, operation_handle: anytype, payload: anytype) Error!struct { value: *const Value(resultShape(index(.operation, @TypeOf(operation_handle)))), term: p.Id } {
        _ = comptime index(.body, @TypeOf(body));
        const Op = index(.operation, @TypeOf(operation_handle));
        if (comptime Op != Dynamic) comptime compatible(Op.payload, index(.value, @TypeOf(payload)), "performSite");
        const site = try runtime.interop.performSite(@ptrCast(body), erased(.operation, operation_handle), erased(.value, payload));
        return .{ .value = @ptrCast(site.value), .term = site.term };
    }
    pub fn operation(c: *Context, id: p.Id) Error!*const Operation(Dynamic) {
        return @ptrCast(try runtime.interop.operation(rawContext(c), id));
    }
    pub fn region(c: *Context, id: p.Id) Error!*const Region {
        return runtime.interop.region(rawContext(c), id);
    }
    pub fn operationId(c: *Context, operation_handle: anytype) Error!p.Id {
        return runtime.interop.operationId(rawContext(c), erased(.operation, operation_handle));
    }
    pub fn functionId(c: *Context, function_handle: anytype) Error!p.Id {
        return runtime.interop.functionId(rawContext(c), erased(.function, function_handle));
    }
    pub fn resumptionSchema(c: *Context, handler_handle: anytype) Error!*const Schema(Dynamic) {
        return @ptrCast(try runtime.interop.resumptionSchema(rawContext(c), erased(.handler, handler_handle)));
    }
    pub fn handlerId(c: *Context, handler_handle: anytype) Error!p.Id {
        return runtime.interop.handlerId(rawContext(c), erased(.handler, handler_handle));
    }
    pub fn regionId(c: *Context, region_handle: *const Region) Error!p.Id {
        return runtime.interop.regionId(rawContext(c), region_handle);
    }
    pub fn failureLiteralId(c: *Context, literal: anytype) Error!p.Id {
        return runtime.interop.failureLiteralId(rawContext(c), erased(.failure_literal, literal));
    }
    /// Context access requires a global value; Body access also checks lexical use.
    pub fn valueId(owner: anytype, value: anytype) Error!p.Id {
        if (comptime @TypeOf(owner) == *Context) return runtime.interop.globalValueId(rawContext(owner), erased(.value, value));
        _ = comptime index(.body, @TypeOf(owner));
        return runtime.interop.valueId(@ptrCast(owner), erased(.value, value));
    }
    pub fn computationId(c: *Context, computation: anytype) Error!p.Id {
        return runtime.interop.computationId(rawContext(c), erased(.computation, computation));
    }
    pub fn fields(c: *Context, schema_handle: anytype) Error!*const RuntimeNamed(.schema) {
        _ = try schemaId(c, schema_handle);
        const entries = try erased(.schema, schema_handle).checkedFields();
        return @ptrCast(try runtime.interop.namedStorage(rawContext(c), NamedData(.schema), .{ .entries = entries }));
    }
    pub fn resultSchema(c: *Context, schema_handle: anytype) Error!*const Schema(Dynamic) {
        _ = try schemaId(c, schema_handle);
        return @ptrCast((try erased(.schema, schema_handle).checkedResult()) orelse return error.InvalidSchema);
    }
    /// Bytes are validated against the reachable expected contract before the
    /// checked runtime owner creates a scope-free immutable literal.
    pub fn encodedLiteral(c: *Context, expected: anytype, bytes: []const u8) Error!*const Value(index(.schema, @TypeOf(expected))) {
        return @ptrCast(try runtime.interop.encodedLiteral(rawContext(c), erased(.schema, expected), bytes));
    }
    pub fn literalFailure(c: *Context, value: anytype) Error!*const FailureLiteral(index(.value, @TypeOf(value))) {
        return @ptrCast(try runtime.interop.checkedLiteralFailure(rawContext(c), erased(.value, value)));
    }
    pub fn builder(c: *Context) *source.Builder {
        return runtime.interop.builder(rawContext(c));
    }
    pub fn schemaId(c: *Context, schema_handle: anytype) Error!p.Id {
        return runtime.interop.schemaId(rawContext(c), erased(.schema, schema_handle));
    }
    pub fn erase(value: anytype) (if (metadata(@TypeOf(value)).family == .body) *Body(Dynamic) else *const canonical(metadata(@TypeOf(value)).family, Dynamic)) {
        const info = comptime metadata(@TypeOf(value));
        if (comptime info.family == .declaration and info.shape != Dynamic and info.shape.shape != Dynamic)
            @compileError("Horos authoring: cannot erase a declaration with a known completion shape");
        return @ptrCast(value);
    }
};

fn RawNamed(comptime family: Family) type {
    return switch (family) {
        .schema => runtime.Field,
        .value => runtime.Argument,
        .operation => runtime.HandledOperation,
        .finished_case => runtime.NamedCase,
        else => @compileError("Horos runtime named collection: unsupported family"),
    };
}
fn packNamed(comptime family: Family, values: anytype) Collection(family, @TypeOf(values)) {
    if (comptime @TypeOf(values) == *const interop.RuntimeNamed(family)) {
        const stored: *const NamedData(family) = @ptrCast(@alignCast(values));
        return .{ .borrowed = stored.entries };
    }
    const fields = comptime fieldsInfo(@TypeOf(values), "named collection");
    var result: Collection(family, @TypeOf(values)) = .{};
    inline for (fields.field_names, 0..) |name, i| {
        result.owned[i] = if (family == .operation)
            .{ .name = name, .operation = erased(family, @field(values, name)) }
        else
            .{ .name = name, .value = erased(family, @field(values, name)) };
    }
    return result;
}

fn NamedData(comptime family: Family) type {
    return struct { entries: []const RawNamed(family) };
}

fn sequenceElement(comptime S: type, comptime operation: []const u8) type {
    if (S == Dynamic) return Dynamic;
    if (!@hasDecl(S, "contract")) @compileError("Horos " ++ operation ++ ": expected a sequence, vector, or array");
    return switch (S.contract) {
        .sequence => |v| v.element,
        .array => |v| v.element,
        else => @compileError("Horos " ++ operation ++ ": expected a sequence, vector, or array"),
    };
}
fn requireSequence(comptime S: type, comptime operation: []const u8) void {
    _ = sequenceElement(S, operation);
    if (S != Dynamic and S.contract != .sequence) @compileError("Horos " ++ operation ++ ": arrays cannot change length");
}
fn requireBlob(comptime S: type, comptime operation: []const u8) void {
    if (S == Dynamic) return;
    if (!@hasDecl(S, "contract") or (S.contract != .text and S.contract != .bytes)) @compileError("Horos " ++ operation ++ ": expected text or bytes");
}
fn OptionalShape(comptime S: type) type {
    return native.Contract(.{ .sum = native.Fields(&.{ "none", "some" }, &.{ Shape(void), S }) });
}
fn PopShape(comptime S: type) type {
    requireSequence(S, "pop");
    return native.Contract(.{ .sum = native.Fields(&.{ "empty", "item" }, &.{ Shape(void), native.Contract(.{ .product = native.Fields(&.{ "head", "tail" }, &.{ sequenceElement(S, "pop"), S }) }) }) });
}
fn PopLastShape(comptime S: type) type {
    requireSequence(S, "sequencePopLast");
    return native.Contract(.{ .product = native.Fields(&.{ "rest", "last" }, &.{ S, OptionalShape(sequenceElement(S, "sequencePopLast")) }) });
}
fn compatibleBlob(comptime Target: type, comptime Source: type, comptime operation: []const u8) void {
    requireBlob(Target, operation);
    requireBlob(Source, operation);
    if (Target != Dynamic and Source != Dynamic and std.meta.activeTag(Target.contract) != std.meta.activeTag(Source.contract)) mismatch(operation);
}
fn capacityFailure(comptime S: type, options: anytype, comptime operation: []const u8) ?*const runtime.FailureLiteral {
    comptime {
        requireSequence(S, operation);
        if (S != Dynamic) {
            const needed = S.contract.sequence.maximum != null;
            if (needed != @hasField(@TypeOf(options), "capacity")) @compileError("Horos " ++ operation ++ ": capacity failure required exactly for a bounded vector");
        }
    }
    return if (@hasField(@TypeOf(options), "capacity")) erased(.failure_literal, options.capacity) else null;
}
fn checkElements(comptime S: type, comptime T: type, comptime operation: []const u8) void {
    switch (@typeInfo(T)) {
        .@"struct" => |fields| for (fields.field_types) |Item| compatible(S, index(.value, Item), operation ++ " element"),
        .array => |array| compatible(S, index(.value, array.child), operation ++ " element"),
        .pointer => |ptr| if (ptr.size == .slice) compatible(S, index(.value, ptr.child), operation ++ " element") else checkElements(S, ptr.child, operation),
        else => @compileError("Horos " ++ operation ++ ": expected handle tuple, array, or slice"),
    }
}

fn firstParameter(comptime Fields: type, comptime operation: []const u8) type {
    if (Fields == Dynamic) return Dynamic;
    const f = @typeInfo(Fields).@"struct";
    if (f.field_types.len == 0) @compileError("Horos " ++ operation ++ ": missing implicit first parameter");
    return f.field_types[0];
}
fn dropFirst(comptime Fields: type, comptime operation: []const u8) type {
    if (Fields == Dynamic) return Dynamic;
    _ = firstParameter(Fields, operation);
    const f = @typeInfo(Fields).@"struct";
    return native.Fields(f.field_names[1..], f.field_types[1..]);
}
fn PairShape(comptime S: type) type {
    return native.Contract(.{ .product = native.Fields(&.{ "first", "second" }, &.{ S, S }) });
}
fn CleanupShape(comptime Failure: type) type {
    const Unit = Shape(void);
    const Reason = native.Contract(.{ .sum = native.Fields(&.{ "0", "1" }, &.{ Shape(native.Text(null)), Shape(native.Bytes(null)) }) });
    const Primary = native.Contract(.{ .sum = native.Fields(&.{ "0", "1", "2", "3" }, &.{ Unit, Failure, Reason, Unit }) });
    const Cancel = native.Contract(.{ .sum = native.Fields(&.{ "0", "1" }, &.{ Unit, Reason }) });
    return native.Contract(.{ .product = native.Fields(&.{ "0", "1", "2" }, &.{ Primary, Cancel, native.Contract(.{ .sequence = .{ .element = Failure, .maximum = null } }) }) });
}

fn requireInteger(comptime S: type, comptime operation: []const u8) void {
    if (S == Dynamic) return;
    if (!@hasDecl(S, "contract") or S.contract != .integer) @compileError("Horos " ++ operation ++ ": expected an integer shape");
}
