const std = @import("std");
const a = @import("../authoring.zig");
const source = @import("../source.zig");

test "checked environmental operation imports and sites retain validated contracts" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const number = try c.schema(u64);
    const unit = try c.schema(void);
    const number_id = try a.interop.schemaId(c, number);
    const effect = try raw.effect(.{ .identity = "checked external", .payload = number_id, .result = number_id });
    const operation = try a.interop.externalOperation(c, effect, number, number);
    try std.testing.expectError(error.SchemaMismatch, a.interop.externalOperation(c, effect, unit, number));
    const local = try raw.effect(.{ .identity = "local", .payload = number_id, .result = number_id, .external = false });
    try std.testing.expectError(error.InvalidCategory, a.interop.externalOperation(c, local, number, number));
    const owner = try c.function("environment owner", .{}, number, .{operation});
    const owner_body = try c.body(owner);
    const site = try a.interop.performSite(owner_body, operation, try owner_body.constant(u64, 7));
    try std.testing.expect(@TypeOf(site.value) == *const a.Value(a.Shape(u64)));
    try std.testing.expectEqual(effect, raw.terms.items[@intCast(site.term)].perform.effect);
    try c.define(owner, try owner_body.ret(site.value));
}

test "replacement retains schema through parameter nested field call ret and define" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const Request = struct { input: u64, offset: u64 };
    const integer = try c.schema(u64);
    const request = try c.schema(Request);
    const run = try c.function("run", .{ .request = request, .enabled = try c.schema(bool) }, integer, .{});
    const body = try c.body(run);
    const input = try body.field(try body.parameter("request"), "input");
    try std.testing.expect(@TypeOf(input) == *const a.Value(a.Shape(u64)));
    try c.define(run, try body.ret(input));
    const entry = try c.function("entry", .{}, integer, .{});
    const caller = try c.body(entry);
    const value = try caller.product(request, .{ .offset = try caller.constant(u64, 2), .input = try caller.constant(u64, 19) });
    const answer = try caller.call(run, .{ .enabled = try caller.constant(bool, true), .request = value });
    try std.testing.expect(@TypeOf(answer) == @TypeOf(input));
    try c.define(entry, try caller.ret(answer));
    var compiled = try source.lower(std.testing.allocator, try c.module(entry, try c.schema(void)));
    defer compiled.deinit();
    const composed = try c.record(.{ .input = integer, .offset = integer });
    try std.testing.expect(@TypeOf(composed) == @TypeOf(request));
    try std.testing.expectEqual(try a.interop.schemaId(c, request), try a.interop.schemaId(c, composed));
    try std.testing.expect(@TypeOf((try request.fields()).input) == @TypeOf(integer));
}

test "replacement shape identity does not confer context or lexical ownership" {
    var left = source.Builder.init(std.testing.allocator);
    defer left.deinit();
    var right = source.Builder.init(std.testing.allocator);
    defer right.deinit();
    const c = try a.Context.init(&left);
    const other = try a.Context.init(&right);
    const integer = try c.schema(u64);
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const branch = try body.branch();
    const local = try branch.constant(u64, 7);
    try std.testing.expectError(error.OutOfScope, body.ret(local));
    try std.testing.expectError(error.ForeignHandle, other.function("bad", .{}, integer, .{}));
}

test "replacement body parameters are independent from intermediate branch results" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const record = try c.schema(struct { flag: bool });
    const entry = try c.function("entry", .{}, record, .{});
    const body = try c.body(entry);
    const yes = try body.branch();
    const no = try body.branch();
    const flag = try body.conditional(try body.constant(bool, true), try yes.ret(try yes.constant(bool, false)), try no.ret(try no.constant(bool, true)));
    try c.define(entry, try body.ret(try body.product(record, .{ .flag = flag })));
    var compiled = try source.lower(std.testing.allocator, try c.module(entry, try c.schema(void)));
    defer compiled.deinit();
}

test "replacement runtime collections snapshot names and retain known function results" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    var name = [_]u8{ 'k', 'e', 'y' };
    const parameters = try a.interop.RuntimeNamed(.schema).init(c, &.{.{ .name = &name, .handle = a.interop.erase(integer) }});
    name[0] = 'x';
    const run = try c.function("runtime names", parameters, integer, .{});
    const body = try c.body(run);
    try c.define(run, try body.ret(try a.interop.parameter(body, "key")));
    const entry = try c.function("entry", .{}, integer, .{});
    const caller = try c.body(entry);
    const args = try a.interop.RuntimeNamed(.value).init(c, &.{.{ .name = "key", .handle = a.interop.erase(try caller.constant(u64, 42)) }});
    const answer = try caller.call(run, args);
    try std.testing.expect(@TypeOf(answer) == *const a.Value(a.Shape(u64)));
    try c.define(entry, try caller.ret(answer));
    var compiled = try source.lower(std.testing.allocator, try c.module(entry, try c.schema(void)));
    defer compiled.deinit();
}

test "replacement explicit unknown child preserves known surrounding names and shapes" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const mixed = try c.record(.{ .count = try c.schema(u64), .other = a.interop.erase(try c.schema(bool)) });
    const entry = try c.function("entry", .{ .input = mixed }, try c.schema(u64), .{});
    const body = try c.body(entry);
    const input = try body.parameter("input");
    const count = try body.field(input, "count");
    const other = try body.field(input, "other");
    try std.testing.expect(@TypeOf(count) == *const a.Value(a.Shape(u64)));
    try std.testing.expect(@TypeOf(other) == *const a.Value(a.Dynamic));
    try c.define(entry, try body.ret(count));
}

test "replacement effect signatures retain replies and arithmetic retains operands" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const lookup = try c.external("lookup", try c.schema(bool), integer);
    const entry = try c.function("entry", .{}, integer, .{lookup});
    const body = try c.body(entry);
    const reply = try body.perform(lookup, try body.constant(bool, true));
    const sum = try body.checkedAdd(reply, try body.constant(u64, 1), try c.literalFailure(u8, 1));
    try std.testing.expect(@TypeOf(sum) == *const a.Value(a.Shape(u64)));
    try c.define(entry, try body.ret(sum));
    var compiled = try source.lower(std.testing.allocator, try c.module(entry, try c.schema(u8)));
    defer compiled.deinit();
}

test "replacement cases retain payload and result through named matching" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const optional = try c.schema(?u64);
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const value = try body.variant(optional, "some", try body.constant(u64, 42));
    const some = try body.caseOf(value, "some");
    const none = try body.caseOf(value, "none");
    try std.testing.expect(@TypeOf(some.payload()) == *const a.Value(a.Shape(u64)));
    const answer = try body.match(value, .{
        .some = try some.ret(some.payload()),
        .none = try none.ret(try none.body().constant(u64, 0)),
    });
    try std.testing.expect(@TypeOf(answer) == *const a.Value(a.Shape(u64)));
    try c.define(entry, try body.ret(answer));
    var compiled = try source.lower(std.testing.allocator, try c.module(entry, try c.schema(void)));
    defer compiled.deinit();
}

test "replacement rejects erased completed cases swapped under the wrong names" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const optional = try c.schema(?u64);
    const entry = try c.function("entry", .{}, integer, .{});
    const body = try c.body(entry);
    const value = try body.variant(optional, "some", try body.constant(u64, 42));
    const some = try a.interop.caseOf(body, value, "some");
    const none = try a.interop.caseOf(body, value, "none");
    const finished_some = a.interop.erase(try some.ret(some.payload()));
    const finished_none = a.interop.erase(try none.ret(try none.body().constant(u64, 0)));
    try std.testing.expectError(error.InvalidBranch, body.match(value, .{ .some = finished_none, .none = finished_some }));
}

test "replacement callable composition retains captured and returned shape" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const entry = try c.function("entry", .{ .input = integer }, integer, .{});
    const body = try c.body(entry);
    const value = try body.parameter("input");
    const callable = try c.callable(.{}, integer, .{}, .{ .use = .reusable, .captures = .{integer} });
    const nested = try c.functionFor("nested", callable);
    const inner = try body.closureBody(nested);
    try c.define(nested, try inner.ret(value));
    const answer = try body.apply(try body.lambda(nested, callable), .{});
    try std.testing.expect(@TypeOf(answer) == @TypeOf(value));
    try c.define(entry, try body.ret(answer));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement same-shaped capability does not authorize another nominal effect" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const first = try c.local("same", unit, integer, .linear);
    const second = try c.local("same", unit, integer, .linear);
    const first_cap = try c.capability(first);
    const second_cap = try c.capability(second);
    try std.testing.expect(@TypeOf(first_cap) == @TypeOf(second_cap));
    const entry = try c.function("entry", .{ .capability = second_cap }, integer, .{ first, second });
    const body = try c.body(entry);
    try std.testing.expectError(error.SchemaMismatch, body.performLocal(first, try body.parameter("capability"), try body.constant(void, {})));
}

fn finishHandler(c: *a.Context, op: anytype, h: anytype) !void {
    const returned = try c.returnFunction(h);
    const rb = try c.body(returned);
    const result = try rb.parameter("result");
    try std.testing.expect(@TypeOf(result) == *const a.Value(a.Shape(u64)));
    try c.define(returned, try rb.ret(try rb.equal(result, try rb.constant(u64, 7))));
    const clause = try c.clauseFunctionFor(h, op);
    const cb = try c.body(clause);
    const token = try cb.parameter("resumption");
    const first = try cb.resumeValue(token, try cb.constant(u64, 7));
    const second = try cb.resumeValue(token, try cb.constant(u64, 7));
    const H = a.ShapeOf(@TypeOf(h));
    if (comptime H.mode == .deep) {
        try std.testing.expect(@TypeOf(first) == *const a.Value(a.Shape(bool)));
        try c.define(clause, try cb.ret(try cb.equal(first, second)));
    } else {
        try std.testing.expect(@TypeOf(first) == *const a.Value(a.Shape(u64)));
        const installed = try cb.resumeWith(token, try cb.constant(u64, 7), h, .{});
        try std.testing.expect(@TypeOf(installed) == *const a.Value(a.Shape(bool)));
        try c.define(clause, try cb.ret(try cb.equal(installed, try cb.equal(first, second))));
    }
    const work_schema = try c.handledSchema(h);
    const work = try c.functionFor("work", work_schema);
    const wb = try c.body(work);
    const answer = try wb.performLocal(op, try wb.parameter("capability"), try wb.constant(void, {}));
    try c.define(work, try wb.ret(answer));
    const entry = try c.function("entry", .{}, try c.schema(bool), .{op});
    const eb = try c.body(entry);
    const handled = try eb.handleWith(h, try eb.lambda(work, work_schema), .{});
    try std.testing.expect(@TypeOf(handled) == *const a.Value(a.Shape(bool)));
    try c.define(entry, try eb.ret(handled));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement deep handler retains transformed answer and multi-shot resumption" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const op = try c.local("choose", try c.schema(void), integer, .multi);
    const h = try c.handler(op, integer, try c.schema(bool), .{ .mode = .deep, .use = .multi });
    try finishHandler(c, op, h);
}

fn runtimeHandlerMode(mode: @import("horos_data").program.Mode) !void {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const op = try c.local("choose", try c.schema(void), integer, .multi);
    const slot = try c.declareSchema(.resumption, a.Dynamic);
    const selected = try c.handler(op, integer, try c.schema(bool), .{ .mode = mode, .use = .multi, .residual = .{op}, .captures = .{ integer, try c.schema(bool), slot.schema() }, .resumption_slots = .{slot} });
    try std.testing.expect(@typeInfo(@TypeOf(selected)) == .@"union");
    switch (selected) {
        .deep => |h| {
            try std.testing.expect(mode == .deep);
            try finishHandler(c, op, h);
        },
        .shallow => |h| {
            try std.testing.expect(mode == .shallow);
            try finishHandler(c, op, h);
        },
    }
}

test "replacement runtime handler mode preserves a typed discriminator" {
    try runtimeHandlerMode(.deep);
    try runtimeHandlerMode(.shallow);
}

test "replacement runtime named cases retain checked arm ownership" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const sum = try c.alternatives(.{ .left = integer, .right = integer });
    const entry = try c.function("entry", .{}, integer, .{});
    const b = try c.body(entry);
    const value = try b.variant(sum, "left", try b.constant(u64, 11));
    const left = try b.caseOf(value, "left");
    const right = try b.caseOf(value, "right");
    const cases = try a.interop.RuntimeNamed(.finished_case).init(c, &.{
        .{ .name = "right", .handle = a.interop.erase(try right.ret(right.payload())) },
        .{ .name = "left", .handle = a.interop.erase(try left.ret(left.payload())) },
    });
    const result = try b.match(value, cases);
    try std.testing.expect(@TypeOf(result) == *const a.Value(a.Dynamic));
    try c.define(entry, try b.ret(result));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement explicit clone retains reply and answer and rejects multi source" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const op = try c.local("clone", try c.schema(void), integer, .multi);
    const h = try c.handler(op, integer, integer, .{ .mode = .deep, .use = .linear });
    const original = try c.resumptionSchemaFor(h, op);
    const target = try c.cloneableResumption(original);
    try std.testing.expectError(error.InvalidOwnership, c.cloneableResumption(target));
    const returned = try c.returnFunction(h);
    const rb = try c.body(returned);
    try c.define(returned, try rb.ret(try rb.parameter("result")));
    const clause = try c.clauseFunction(h);
    const cb = try c.body(clause);
    const template = try cb.cloneResumption(target, try cb.parameter("resumption"));
    _ = try cb.resumeValue(template, try cb.constant(u64, 4));
    const result = try cb.resumeValue(template, try cb.constant(u64, 7));
    try std.testing.expect(@TypeOf(result) == *const a.Value(a.Shape(u64)));
    try c.define(clause, try cb.ret(result));
    const schema = try c.handledSchema(h);
    const work = try c.functionFor("work", schema);
    const wb = try c.body(work);
    try c.define(work, try wb.ret(try wb.performLocal(op, try wb.parameter("capability"), try wb.constant(void, {}))));
    const entry = try c.function("entry", .{}, integer, .{});
    const eb = try c.body(entry);
    try c.define(entry, try eb.ret(try eb.handleWith(h, try eb.lambda(work, schema), .{})));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement recursive typed declarations retain pending lifecycle" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const S = a.Shape(union(enum) { empty: void, value: u64 });
    const slot = try c.declareSchema(.alternatives, S);
    try std.testing.expectError(error.UndefinedSchema, slot.schema().fields());
    try c.defineAlternatives(slot, .{ .empty = try c.schema(void), .value = try c.schema(u64) });
    try std.testing.expect(@TypeOf((try slot.schema().fields()).value) == *const a.Schema(a.Shape(u64)));
    try std.testing.expectError(error.SchemaAlreadyDefined, c.defineAlternatives(slot, .{ .empty = try c.schema(void), .value = try c.schema(u64) }));
    const entry = try c.function("entry", .{}, slot.schema(), .{});
    const b = try c.body(entry);
    try c.define(entry, try b.ret(try b.variant(slot.schema(), "value", try b.constant(u64, 7))));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement encoded literals are global checked values with reachable validation" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unrelated = try c.declareSchema(.alternatives, a.Dynamic);
    const schema = try c.schema(struct { number: u64 });
    const literal = try a.interop.encodedLiteral(c, schema, &.{ 9, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expect(@TypeOf(literal) == *const a.Value(a.Shape(struct { number: u64 })));
    try std.testing.expectError(error.InvalidValue, a.interop.encodedLiteral(c, schema, &.{9}));
    const f = try c.function("one", .{}, schema, .{});
    const b = try c.body(f);
    try std.testing.expectEqual(try a.interop.valueId(c, literal), try a.interop.valueId(b, literal));
    try std.testing.expectError(error.OutOfScope, a.interop.valueId(c, try b.constant(u64, 3)));
    try c.define(f, try b.ret(literal));
    const g = try c.function("two", .{}, schema, .{});
    const gb = try c.body(g);
    try std.testing.expectError(error.OutOfScope, a.interop.literalFailure(c, try gb.constant(u64, 3)));
    try c.define(g, try gb.ret(literal));
    _ = try a.interop.literalFailure(c, literal);
    var other_raw = source.Builder.init(std.testing.allocator);
    defer other_raw.deinit();
    const other = try a.Context.init(&other_raw);
    try std.testing.expectError(error.ForeignHandle, a.interop.literalFailure(other, literal));
    try std.testing.expectError(error.ForeignHandle, a.interop.valueId(other, literal));
    try c.defineAlternatives(unrelated, .{ .done = try c.schema(void) });
    var compiled = try c.compile(std.testing.allocator, g, try c.schema(void));
    defer compiled.deinit();
}

test "replacement finite and absent sequence bounds preserve elements and fault policy" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const native = @import("horos_data").schema.native;
    const integer = try c.schema(u64);
    const sequence = try c.schema(native.Vector(u64, null));
    const vector = try c.schema(native.Vector(u64, 3));
    const entry = try c.function("entry", .{}, integer, .{});
    const b = try c.body(entry);
    const one = try b.constant(u64, 1);
    const fail = try c.literalFailure(u8, 3);
    const empty = try b.sequenceValue(sequence, .{});
    const appended = try b.append(empty, one, .{});
    const bounded = try b.append(try b.sequenceValue(vector, .{}), one, .{ .capacity = fail });
    const doubled = try b.concat(bounded, bounded, .{ .capacity = fail });
    const changed = try b.sequenceSet(doubled, try b.constant(u64, 0), one, fail);
    const sliced = try b.sequenceTake(changed, one);
    const option = try b.sequenceGet(sliced, try b.constant(u64, 0));
    const present = try b.caseOf(option, "some");
    try std.testing.expect(@TypeOf(present.payload()) == *const a.Value(a.Shape(u64)));
    present.body().abandon();
    const popped = try b.pop(appended);
    const item = try b.caseOf(popped, "item");
    const parts = try item.body().destructure(item.payload());
    try std.testing.expect(@TypeOf(try parts.get("head")) == *const a.Value(a.Shape(u64)));
    item.body().abandon();
    try c.define(entry, try b.ret(try b.sequenceLength(sliced)));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(u8));
    defer compiled.deinit();
}

test "replacement explicit positional mapping validates schema without relabeling named handles" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const expected = try c.schema(struct { count: u64 });
    const other = try c.schema(struct { total: u64 });
    const imported = try a.interop.schema(c, try a.interop.schemaId(c, expected));
    try std.testing.expectError(error.SchemaMismatch, a.interop.refineSchema(c, imported, expected));
    const mapped = try a.interop.mapSchema(c, imported, expected);
    try std.testing.expect(@TypeOf(mapped) == @TypeOf(expected));
    try std.testing.expectError(error.SchemaMismatch, a.interop.mapSchema(c, a.interop.erase(other), expected));
    const vector = try c.schema(@import("horos_data").schema.native.Vector(struct { count: u64 }, 2));
    const renamed = try c.schema(@import("horos_data").schema.native.Vector(struct { total: u64 }, 2));
    try std.testing.expectError(error.SchemaMismatch, a.interop.refineSchema(c, a.interop.erase(renamed), vector));
    const fields = try a.interop.fields(c, expected);
    try std.testing.expectEqual(@as(usize, 1), fields.len());
    try std.testing.expectEqualStrings("count", fields.at(0).?.name);
    try std.testing.expect(fields.at(1) == null);
    const entry = try c.function("entry", .{}, expected, .{});
    const b = try c.body(entry);
    const value = try b.product(expected, .{ .count = try b.constant(u64, 8) });
    const refined = try a.interop.refineValue(b, a.interop.erase(value), expected);
    try std.testing.expect(@TypeOf(refined) == @TypeOf(value));
    try std.testing.expectError(error.SchemaMismatch, a.interop.mapValue(b, a.interop.erase(value), other));
    try c.define(entry, try b.ret(refined));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement checked scalar blob and record operations retain their result contracts" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const native = @import("horos_data").schema.native;
    const integer = try c.schema(u64);
    const entry = try c.function("entry", .{}, integer, .{});
    const b = try c.body(entry);
    const fault = try c.literalFailure(u8, 1);
    const narrow = try b.convertInteger(try c.schema(u8), try b.constant(u64, 7), .{ .overflow = fault });
    const wide = try b.convertInteger(integer, narrow, .{});
    const bits = try b.bitwise(.xor, wide, try b.bitNot(wide));
    const negative = try b.booleanNot(try b.constant(bool, false));
    _ = try b.select(negative, bits, wide);
    const text = try b.textInteger(wide);
    const scalar = try b.textScalar(try b.constant(u32, 65), fault);
    const combined = try b.blobConcat(try c.schema(native.Text(64)), text, scalar, fault);
    const sliced = try b.blobSlice(try c.schema(native.Text(null)), combined, try b.constant(u64, 0), try b.constant(u64, 1), .{ .capacity = fault, .invalid_utf8 = fault });
    try std.testing.expect(@TypeOf(sliced) == *const a.Value(a.Shape(native.Text(null))));
    const bytes = try b.blobFromByte(narrow);
    _ = try b.blobByte(bytes, try b.constant(u64, 0));
    _ = try b.blobCompare(text, scalar);
    const record = try c.schema(struct { first: u64, second: bool });
    const initial = try b.product(record, .{ .first = wide, .second = negative });
    const changed = try b.update(initial, .{ .first = try b.blobLength(sliced) });
    try c.define(entry, try b.ret(try b.field(changed, "first")));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(u8));
    defer compiled.deinit();
}

test "replacement region callable and reusable result reflection keep nested shapes" {
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const r = try c.region();
    const sig = try c.regionBodySchema(r, .{ .seed = integer }, integer, .{}, .{ .use = .linear });
    const f = try c.functionFor("region work", sig);
    const b = try c.body(f);
    const cell = try b.newCell(try c.cell(r, integer), try b.parameter("region"), try b.parameter("seed"));
    try c.define(f, try b.ret(try b.readCell(cell)));
    const entry = try c.function("entry", .{}, integer, .{});
    const eb = try c.body(entry);
    const result = try eb.withRegion(r, try eb.lambda(f, sig), .{ .seed = try eb.constant(u64, 7) });
    try std.testing.expect(@TypeOf(result) == *const a.Value(a.Shape(u64)));
    try c.define(entry, try eb.ret(result));
    const cleanup = try c.cleanupInfo(try c.schema(u8));
    try std.testing.expect(@TypeOf((try cleanup.fields()).@"2") == *const a.Schema(a.Shape(@import("horos_data").schema.native.Vector(u8, null))));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement State runtime policies expose distinct typed answers" {
    const State = @import("../library/state.zig");
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const state = try State.family(c, "state", try c.schema(u64));
    const region = try c.region();
    for ([_]State.Answer{ .value, .with_state, .optional }) |policy| {
        const selected = try State.interpret(c, state, try c.schema(bool), region, .{ .continuation = .{} }, .{}, policy);
        switch (selected) {
            .value => |v| try std.testing.expect(@TypeOf(v.answer) == *const a.Schema(a.Shape(bool))),
            .with_state => |v| {
                try std.testing.expect(@TypeOf((try v.answer.fields()).value) == *const a.Schema(a.Shape(bool)));
                try std.testing.expect(@TypeOf((try v.answer.fields()).state) == *const a.Schema(a.Shape(u64)));
            },
            .optional => |v| try std.testing.expect(@TypeOf((try v.answer.fields()).some) == *const a.Schema(a.Shape(bool))),
        }
    }
}

test "replacement Choice library retains its answer and resumption through composition" {
    const Choice = @import("../library/choice.zig");
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const choice = try Choice.family(c, "choose");
    const integer = try c.schema(u64);
    const interpreted = try Choice.all(c, choice, integer, .{ .captures = .{ .continuation = .{} } });
    try std.testing.expect(@TypeOf(try interpreted.answer.resultSchema()) == *const a.Schema(a.Shape(u64)));
    const sig = try c.handledSchema(interpreted.handler);
    const work = try c.functionFor("work", sig);
    const wb = try c.body(work);
    const selected = try wb.performLocal(choice.effect(), try wb.parameter("capability"), try wb.constant(void, {}));
    const result = try wb.select(selected, try wb.constant(u64, 1), try wb.constant(u64, 2));
    try c.define(work, try wb.ret(result));
    const entry = try c.function("entry", .{}, interpreted.answer, .{});
    const eb = try c.body(entry);
    try c.define(entry, try eb.ret(try eb.handleWith(interpreted.handler, try eb.lambda(work, sig), .{})));
    var compiled = try c.compile(std.testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "replacement recursive library results preserve known schemas" {
    const Reader = @import("../library/reader.zig");
    const Writer = @import("../library/writer.zig");
    const Raise = @import("../library/raise.zig");
    const Search = @import("../library/search.zig");
    const Generator = @import("../library/generator.zig");
    const Scheduler = @import("../library/scheduler.zig");
    var raw = source.Builder.init(std.testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const region = try c.region();
    const reader = try Reader.family(c, "reader", integer, boolean, .{}, .{}, .{});
    const reading = try Reader.interpret(c, reader, integer, .{ .continuation = .{} });
    const inside = try c.functionFor("inside type", reader.inside());
    const inside_body = try c.body(inside);
    const cap = try inside_body.parameter("local");
    try std.testing.expect(@TypeOf(cap) == *const a.Value(a.ShapeOf(@TypeOf(reader.localCapability()))));
    inside_body.abandon();
    const read_return = try c.returnFunction(reading.handler);
    try std.testing.expect(a.ShapeOf(@TypeOf(read_return)).result == a.Shape(u64));
    const writer = try Writer.family(c, "writer", boolean);
    const writing = try Writer.interpret(c, writer, integer, region, .{ .continuation = .{} }, .{});
    try std.testing.expect(@TypeOf((try writing.answer.fields()).value) == @TypeOf(integer));
    try std.testing.expect(@TypeOf(try (try writing.answer.fields()).log.resultSchema()) == @TypeOf(boolean));
    const raised = try Raise.family(c, "raise", boolean);
    const catching = try Raise.catching(c, raised, integer, .{ .continuation = .{} }, .{}, .{});
    try std.testing.expect(@TypeOf((try catching.answer.fields()).failure) == @TypeOf(boolean));
    const search = try Search.family(c, "search");
    const searching = try Search.interpret(c, search, integer, .{ .captures = .{ .continuation = .{} }, .order = .breadth_first });
    try std.testing.expect(@TypeOf((try searching.step.fields()).solution) == @TypeOf(integer));
    try std.testing.expect(@TypeOf(try searching.resumption.resultSchema()) == @TypeOf(searching.step));
    const options = .{ .captures = .{ .continuation = .{integer} } };
    const left = try Generator.create(c, "left", integer, boolean, unit, options);
    const right = try Generator.create(c, "right", boolean, integer, unit, options);
    const pipeline = try Generator.pipeline(c, "pipeline", left, right);
    try std.testing.expect(@TypeOf(pipeline.generator.input()) == @TypeOf(integer));
    try std.testing.expect(@TypeOf(pipeline.generator.element()) == @TypeOf(integer));
    try std.testing.expect(@TypeOf((try pipeline.generator.answer().fields()).done) == @TypeOf(unit));
    try std.testing.expect(@TypeOf(try pipeline.generator.resumption().resultSchema()) == @TypeOf(pipeline.generator.answer()));
    const tasks = try Generator.create(c, "tasks", unit, unit, unit, options);
    const fifo = try Scheduler.fifo(c, tasks, .{}, .{region});
    try std.testing.expect(@TypeOf(try fifo.queue.resultSchema()) == @TypeOf(tasks.package()));
    const join = try Scheduler.joinType(c, integer, region);
    const awaiting = try Scheduler.awaiting(c, tasks, join, .{region});
    try std.testing.expect(a.ShapeOf(@TypeOf(awaiting)).result == a.Shape(u64));
}
