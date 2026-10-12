const std = @import("std");
const source = @import("source.zig");
const a = @import("authoring.zig");
const testing = std.testing;

test "native shape lowering agrees with independently composed portable schemas" {
    const native = @import("horos_data").schema.native;
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const integer = try raw.scalar(u64);
    const unit = try raw.scalar(void);
    const record = try raw.schema(.{ .product = &.{ integer, unit } });
    const optional = try raw.schema(.{ .sum = &.{ unit, record } });
    const bounded = try raw.schema(.{ .vector = .{ .element = optional, .maximum = 2 } });
    const Input = native.Vector(?struct { count: u64, empty: void }, 2);
    try testing.expectEqual(bounded, try native.lower(native.info(Input), &raw));
    const tags = try raw.schema(.{ .enumeration = &.{ 2, 9 } });
    try testing.expectEqual(tags, try native.lower(native.info(enum(u32) { red = 9, blue = 2 }), &raw));
    try testing.expectEqual(try raw.schema(.text), try native.lower(native.info(native.Text(null)), &raw));
    try testing.expectEqual(try raw.schema(.{ .bounded_text = 0 }), try native.lower(native.info(native.Text(0)), &raw));
    try testing.expectEqual(try raw.schema(.bytes), try native.lower(native.info([]const u8), &raw));
    try testing.expectEqual(try raw.schema(.{ .array = .{ .element = integer, .length = 0 } }), try native.lower(native.info([0]u64), &raw));
}

pub fn branchWitness(raw: *source.Builder) !source.Module {
    const c = try a.Context.init(raw);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const unit = try c.schema(void);
    const lookup = try c.external("authoring/lookup", integer, integer);
    const entry = try c.function("entry", .{ .choose = boolean }, integer, &.{lookup});
    const body = try c.body(entry);
    const yes = try body.branch();
    const no = try body.branch();
    const chosen = try body.conditional(try body.parameter("choose"), try yes.ret(try yes.perform(lookup, try yes.constant(u64, 19))), try no.ret(try no.constant(u64, 42)));
    try c.define(entry, try body.ret(chosen));
    return c.module(entry, unit);
}

test "A01 authoring rejects colliding live builder handles" {
    var left = source.Builder.init(testing.allocator);
    defer left.deinit();
    var right = source.Builder.init(testing.allocator);
    defer right.deinit();
    const a1 = try a.Context.init(&left);
    const a2 = try a.Context.init(&right);
    const s1 = try a1.schema(u64);
    _ = try a2.schema(u64);
    try testing.expectError(error.ForeignHandle, a2.function("bad", .{}, s1, &.{}));
    try testing.expectEqual(error.ForeignHandle, a2.lastDiagnostic().code.?);
}

test "A02 authoring rejects sibling and escaped branch locals but joins succeed" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    const left = try body.branch();
    const right = try body.branch();
    const local = try left.constant(u64, 7);
    try testing.expectError(error.OutOfScope, right.ret(local));
    try testing.expectError(error.OutOfScope, body.ret(local));
    const inherited = try body.constant(u64, 11);
    const joined = try body.conditional(try body.constant(bool, true), try left.ret(local), try right.ret(inherited));
    try c.define(entry, try body.ret(joined));
    try testing.expectError(error.ClosedBody, body.constant(u64, 0));
    var compiled = try source.lower(testing.allocator, try c.module(entry, try c.schema(void)));
    defer compiled.deinit();
}

test "A14 authoring runtime selected named fields reject mismatches" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const record = try c.record(.{ .count = integer });
    const entry = try c.function("entry", .{ .input = record }, integer, &.{});
    const body = try c.body(entry);
    const input = try body.parameter("input");
    try testing.expectError(error.UnknownName, a.interop.field(body, input, "absent"));
    try c.define(entry, try body.ret(try body.field(input, "count")));
    var compiled = try source.lower(testing.allocator, try c.module(entry, try c.schema(void)));
    defer compiled.deinit();
}

fn allocationWitness(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    _ = try branchWitness(&raw);
}
test "A15 authoring constructors and snapshot tolerate allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, allocationWitness, .{});
}

test "authoring derived responder preserves explicit residual allowance" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const lookup = try c.external("lookup", integer, integer);
    const question = try c.local("question", integer, integer, .linear);
    const responder = try c.function("responder", .{ .key = integer }, integer, &.{lookup});
    const response = try c.body(responder);
    try c.define(responder, try response.ret(try response.perform(lookup, try response.parameter("key"))));
    const h = try c.responder(question, integer, responder, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{lookup},
        .captures = &.{},
    });
    const schema = try c.handledSchema(h);
    const work = try c.functionFor("work", schema);
    const body = try c.body(work);
    const result = try body.performLocal(question, try body.parameter("capability"), try body.constant(u64, 19));
    try c.define(work, try body.ret(result));
    const entry = try c.function("entry", .{}, integer, &.{lookup});
    const main = try c.body(entry);
    try c.define(entry, try main.ret(try main.handleWith(h, try main.lambda(work, schema), .{})));
    var compiled = try source.lower(testing.allocator, try c.module(entry, unit));
    defer compiled.deinit();
}

test "responder rejection preserves the context before generated functions are allocated" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const question = try c.local("question", integer, integer, .linear);
    const good = try c.function("good", .{ .payload = integer }, integer, .{});
    const good_body = try c.body(good);
    try c.define(good, try good_body.ret(try good_body.parameter("payload")));
    const bad = try c.function("bad", .{ .payload = unit }, unit, .{});
    const bad_body = try c.body(bad);
    try c.define(bad, try bad_body.ret(try bad_body.parameter("payload")));
    const foreign = try a.Context.init(&raw);
    const foreign_unit = try foreign.schema(void);
    const foreign_function = try foreign.function("foreign", .{ .payload = foreign_unit }, foreign_unit, .{});
    const foreign_body = try foreign.body(foreign_function);
    try foreign.define(foreign_function, try foreign_body.ret(try foreign_body.parameter("payload")));
    const count = raw.functions.items.len;
    try testing.expectError(error.SchemaMismatch, c.responder(question, integer, a.interop.erase(bad), .{ .mode = .deep, .use = .linear }));
    try testing.expectEqual(count, raw.functions.items.len);
    try testing.expectError(error.SchemaMismatch, c.responder(question, integer, good, .{ .mode = .deep, .use = .linear, .state = .{ .seed = integer } }));
    try testing.expectEqual(count, raw.functions.items.len);
    try testing.expectError(error.ForeignHandle, c.responder(question, integer, a.interop.erase(foreign_function), .{ .mode = .deep, .use = .linear }));
    try testing.expectEqual(count, raw.functions.items.len);
    _ = try c.responder(question, integer, good, .{ .mode = .deep, .use = .linear });
    const entry = try c.function("entry", .{}, unit, .{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(void, {})));
    var compiled = try c.compile(testing.allocator, entry, unit);
    defer compiled.deinit();
}

fn runtimeNamedConstruction(allocator: std.mem.Allocator, name: []const u8) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const record = try c.record(.{ .count = integer });
    const sum = try c.alternatives(.{ .selected = record });
    const entry = try c.function("entry", .{ .input = record }, sum, .{});
    const body = try c.body(entry);
    const input = try body.parameter("input");
    const parts = try body.destructure(input);
    try testing.expectError(error.UnknownName, a.interop.get(parts, "absent"));
    const count = try a.interop.get(parts, "count");
    try testing.expect(@TypeOf(count) == *const a.Value(a.Dynamic));
    const reconstructed = try body.product(record, .{ .count = count });
    try testing.expectError(error.UnknownName, a.interop.variant(body, sum, "absent", reconstructed));
    try testing.expectError(error.SchemaMismatch, a.interop.variant(body, sum, name, count));
    const branch = try body.branch();
    const local = try branch.product(record, .{ .count = count });
    try testing.expectError(error.OutOfScope, a.interop.variant(body, sum, name, local));
    branch.abandon();
    const result = try a.interop.variant(body, sum, name, reconstructed);
    try testing.expect(@TypeOf(result) == *const a.Value(a.Shape(union(enum) { selected: struct { count: u64 } })));
    try c.define(entry, try body.ret(result));
    try testing.expectError(error.ClosedBody, a.interop.get(parts, "count"));
    var compiled = try c.compile(allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

test "runtime names preserve sum shapes and checked consuming product fields" {
    try runtimeNamedConstruction(testing.allocator, "selected");
}

test "authoring nested callable captures parent named value" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const entry = try c.function("entry", .{ .x = integer }, integer, &.{});
    const body = try c.body(entry);
    const x = try body.parameter("x");
    const schema = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{integer} });
    const nested = try c.functionFor("nested", schema);
    const inner = try body.closureBody(nested);
    try c.define(nested, try inner.ret(x));
    const result = try body.apply(try body.lambda(nested, schema), .{});
    try c.define(entry, try body.ret(result));
    var compiled = try source.lower(testing.allocator, try c.module(entry, try c.schema(void)));
    defer compiled.deinit();
}

test "A06 A07 A10 A12 structured acceptance cases cross authoritative admission" {
    for (std.enums.values(@import("authoring_cases.zig").Kind)) |kind| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        var compiled = try source.lower(testing.allocator, try @import("authoring_cases.zig").build(&raw, kind));
        defer compiled.deinit();
    }
}

fn oneShot(allocator: std.mem.Allocator, sequential: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const once = try c.callable(.{}, integer, &.{}, .{ .use = .linear, .captures = &.{} });
    const work = try c.functionFor("once", once);
    const work_body = try c.body(work);
    try c.define(work, try work_body.ret(try work_body.constant(u64, 7)));
    const entry = try c.function("entry", .{ .choose = try c.schema(bool) }, integer, &.{});
    const body = try c.body(entry);
    const owned = try body.lambda(work, once);
    const result = if (sequential) blk: {
        _ = try body.apply(owned, .{});
        break :blk try body.apply(owned, .{});
    } else blk: {
        const left = try body.branch();
        const right = try body.branch();
        break :blk try body.conditional(try body.parameter("choose"), try left.ret(try left.apply(owned, .{})), try right.ret(try right.apply(owned, .{})));
    };
    try c.define(entry, try body.ret(result));
    var compiled = try c.compile(allocator, entry, unit);
    defer compiled.deinit();
}
test "A08 one shot alternatives succeed but sequential double consumption rejects" {
    try oneShot(testing.allocator, false);
    try testing.expectError(error.UnavailableSlot, oneShot(testing.allocator, true));
}

test "A09 nominal same-name operation rejects foreign capability" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const left = try c.local("same", unit, unit, .linear);
    const right = try c.local("same", unit, unit, .linear);
    const entry = try c.function("entry", .{ .cap = try c.capability(left) }, unit, &.{ left, right });
    const body = try c.body(entry);
    const cap = try body.parameter("cap");
    const payload = try body.constant(void, {});
    try testing.expectError(error.SchemaMismatch, body.performLocal(right, cap, payload));
    try testing.expectEqual(error.SchemaMismatch, c.lastDiagnostic().code.?);
    _ = try body.performLocal(left, cap, payload);
}

test "A09 A17 missing residual effect has an inspectable source relationship" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const op = try c.external("external", unit, unit);
    const entry = try c.function("limited entry", .{}, unit, &.{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.perform(op, try body.constant(void, {}))));
    try testing.expectError(error.InvalidEffect, c.compile(testing.allocator, entry, unit));
    try testing.expectEqual(error.InvalidEffect, c.lastDiagnostic().code.?);
    try testing.expect(c.lastDiagnostic().source != null);
    try testing.expect(std.mem.indexOf(u8, c.lastDiagnostic().relationship, "residual") != null);
}

test "A08 A17 exclusive capture does not become reusable by declaring its bound" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const once = try c.callable(.{}, unit, &.{}, .{ .use = .linear, .captures = &.{} });
    const reusable = try c.callable(.{}, unit, &.{}, .{ .use = .reusable, .captures = &.{once} });
    const once_fn = try c.functionFor("once", once);
    const once_body = try c.body(once_fn);
    try c.define(once_fn, try once_body.ret(try once_body.constant(void, {})));
    const entry = try c.function("entry", .{}, unit, &.{});
    const body = try c.body(entry);
    const owned = try body.lambda(once_fn, once);
    const closure = try c.functionFor("exclusive capture", reusable);
    const nested = try body.closureBody(closure);
    try c.define(closure, try nested.ret(try nested.apply(owned, .{})));
    try c.define(entry, try body.ret(try body.apply(try body.lambda(closure, reusable), .{})));
    try testing.expectError(error.InvalidOwnership, c.compile(testing.allocator, entry, unit));
    try testing.expectEqual(error.InvalidOwnership, c.lastDiagnostic().code.?);
}

test "A11 explicit reuse adds calls without duplicating definitions" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const function = try c.function("shared", .{}, integer, &.{});
    const definition = try c.body(function);
    try c.define(function, try definition.ret(try definition.constant(u64, 7)));
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    const count = raw.functions.items.len;
    var result = try body.constant(u64, 0);
    for (0..8) |_| result = try body.call(function, .{});
    try testing.expectEqual(count, raw.functions.items.len);
    try c.define(entry, try body.ret(result));
    var compiled = try c.compile(testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

fn handlerAllocation(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    _ = try @import("authoring_cases.zig").build(&raw, .transform_deep);
}
test "A15 handler construction and finalization allocation failures" {
    try @import("allocation_testing.zig").check(testing.allocator, handlerAllocation, .{});
}

fn labelBytes(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const entry = try c.function(name, .{}, integer, &.{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(u64, 42)));
    var compiled = try c.compile(allocator, entry, try c.schema(void));
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try @import("horos_data").program_image.encodedLength(compiled.program));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}
test "A17 source labels do not change executable bytes" {
    const left = try labelBytes(testing.allocator, "original");
    defer testing.allocator.free(left);
    const right = try labelBytes(testing.allocator, "renamed diagnostic label");
    defer testing.allocator.free(right);
    try testing.expectEqualSlices(u8, left, right);
}
fn diagnosticAllocation(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const entry = try c.function("named argument", .{ .input = integer }, integer, &.{});
    const caller = try c.function("caller", .{}, integer, &.{});
    const body = try c.body(caller);
    const wrong = try body.constant(bool, false);
    _ = boolean;
    _ = body.call(entry, .{ .input = a.interop.erase(wrong) }) catch |err| {
        if (err != error.SchemaMismatch) return err;
        const rendered = try c.lastDiagnostic().renderAlloc(allocator);
        defer allocator.free(rendered);
        try testing.expect(std.mem.indexOf(u8, rendered, "expected u64") != null);
        return;
    };
    return error.TestExpectedError;
}
test "A15 A17 diagnostic rendering fails cleanly under allocation pressure" {
    try @import("allocation_testing.zig").check(testing.allocator, diagnosticAllocation, .{});
}

test "structured scoped operations expose named body and state clauses" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const thunk = try c.callable(.{}, integer, &.{}, .{ .use = .linear, .captures = &.{} });
    const op = try c.scoped("scoped", unit, integer, .linear, .{ .work = thunk });
    const h = try c.handler(op, integer, integer, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{},
        .captures = &.{integer},
        .state = .{ .offset = integer },
    });
    const returns_fn = try c.returnFunction(h);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
    const clause_fn = try c.clauseFunction(h);
    const clause = try c.body(clause_fn);
    const answer = try clause.apply(try clause.parameter("work"), .{});
    const plus = try clause.checkedAdd(answer, try clause.parameter("offset"), try c.literalFailure(void, {}));
    try c.define(clause_fn, try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), plus)));
    const nested_fn = try c.functionFor("scoped work", thunk);
    const nested = try c.body(nested_fn);
    try c.define(nested_fn, try nested.ret(try nested.constant(u64, 41)));
    const schema = try c.handledSchema(h);
    const work_fn = try c.functionFor("handled", schema);
    const work = try c.body(work_fn);
    const value = try work.performScoped(op, try work.parameter("capability"), try work.constant(void, {}), .{ .work = try work.lambda(nested_fn, thunk) });
    try c.define(work_fn, try work.ret(value));
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    const result = try body.handleWith(h, try body.lambda(work_fn, schema), .{ .offset = try body.constant(u64, 1) });
    try c.define(entry, try body.ret(result));
    var compiled = try c.compile(testing.allocator, entry, unit);
    defer compiled.deinit();
}

test "A02 parent finalization and abandonment close descendant authoring" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const f = try c.function("entry", .{}, unit, &.{});
    const body = try c.body(f);
    const abandoned = try body.branch();
    const grandchild = try abandoned.branch();
    abandoned.abandon();
    try testing.expectError(error.ClosedBody, grandchild.constant(void, {}));
    const pending = try body.branch();
    try c.define(f, try body.ret(try body.constant(void, {})));
    try testing.expectError(error.ClosedBody, pending.constant(void, {}));
    var compiled = try c.compile(testing.allocator, f, unit);
    defer compiled.deinit();
}

test "A14 named-layout and branch result mismatches reject before source admission" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const first = try c.record(.{ .first = integer });
    const second = try c.record(.{ .second = integer });
    const f = try c.function("entry", .{}, first, &.{});
    const body = try c.body(f);
    const left = try body.branch();
    const right = try body.branch();
    const lv = try left.product(first, .{ .first = try left.constant(u64, 1) });
    const rv = try right.product(second, .{ .second = try right.constant(u64, 1) });
    try testing.expectError(error.SchemaMismatch, body.conditional(a.interop.erase(try body.constant(bool, true)), try left.ret(a.interop.erase(lv)), try right.ret(a.interop.erase(rv))));
    try testing.expect(c.lastDiagnostic().expected == a.interop.erase(first));
    try testing.expect(c.lastDiagnostic().actual == a.interop.erase(second));
}

fn shallowResidual(allocator: std.mem.Allocator, allow_escape: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const lookup = try c.external("lookup", integer, integer);
    const question = try c.local("question", integer, integer, .linear);
    const responder = try c.function("responder", .{ .key = integer }, integer, &.{lookup});
    const response = try c.body(responder);
    try c.define(responder, try response.ret(try response.perform(lookup, try response.parameter("key"))));
    const h = try c.responder(question, integer, responder, .{
        .mode = .shallow,
        .use = .linear,
        .residual = &.{ lookup, question },
        .escaping = if (allow_escape) &.{lookup} else &.{},
        .captures = &.{},
    });
    const schema = try c.handledSchema(h);
    const work = try c.functionFor("work", schema);
    const body = try c.body(work);
    try c.define(work, try body.ret(try body.performLocal(question, try body.parameter("capability"), try body.constant(u64, 19))));
    const entry = try c.function("entry", .{}, integer, &.{ lookup, question });
    const entry_body = try c.body(entry);
    try c.define(entry, try entry_body.ret(try entry_body.handleWith(h, try entry_body.lambda(work, schema), .{})));
    var compiled = try c.compile(allocator, entry, unit);
    defer compiled.deinit();
}
test "A06 A09 shallow residual external effects need an explicit escaping allowance" {
    try shallowResidual(testing.allocator, true);
    try testing.expectError(error.InvalidEffect, shallowResidual(testing.allocator, false));
}

fn oneShotVariant(allocator: std.mem.Allocator, twice: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const once = try c.callable(.{}, unit, &.{}, .{ .use = .linear, .captures = &.{} });
    const sum = try c.alternatives(.{ .empty = unit, .owned = once });
    const entry = try c.function("entry", .{}, unit, &.{});
    const body = try c.body(entry);
    const value = try body.variant(sum, "empty", try body.constant(void, {}));
    var result = try body.constant(void, {});
    for (0..@as(usize, if (twice) 2 else 1)) |_| {
        const empty = try body.caseOf(value, "empty");
        const owned = try body.caseOf(value, "owned");
        const used = try owned.body().apply(owned.payload(), .{});
        result = try body.match(value, .{ .empty = try empty.ret(empty.payload()), .owned = try owned.ret(used) });
    }
    try c.define(entry, try body.ret(result));
    var compiled = try c.compile(allocator, entry, unit);
    defer compiled.deinit();
}
test "A08 symbolic one-shot aggregate construction does not repeat at each use" {
    try oneShotVariant(testing.allocator, false);
    try testing.expectError(error.UnavailableSlot, oneShotVariant(testing.allocator, true));
}

test "review named cleanup descriptors retain both supplied failure layouts" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const failure = try c.record(.{ .code = integer });
    const other = try c.record(.{ .other = integer });
    const info = try c.cleanupInfo(failure);
    const other_info = try c.cleanupInfo(other);
    try testing.expect((try (try info.fields()).@"0".fields()).@"1" == failure);
    try testing.expect(try (try info.fields()).@"2".resultSchema() == failure);
    try testing.expect((try (try other_info.fields()).@"0".fields()).@"1" == other);
    try testing.expect((try (try info.fields()).@"0".fields()).@"1" == failure);
    const raw_info = try @import("library/cleanup.zig").exitInfo(&raw, try a.interop.schemaId(c, failure));
    try testing.expectEqual(raw_info, try a.interop.schemaId(c, info));
    const entry = try c.function("inspect cleanup", .{ .exit = info }, integer, &.{});
    const body = try c.body(entry);
    const primary = try body.field(try body.parameter("exit"), "0");
    const normal = try body.caseOf(primary, "0");
    const failed = try body.caseOf(primary, "1");
    const cancelled = try body.caseOf(primary, "2");
    const disposed = try body.caseOf(primary, "3");
    try c.define(entry, try body.ret(try body.match(primary, .{
        .@"0" = try normal.ret(try normal.body().constant(u64, 0)),
        .@"1" = try failed.ret(try failed.body().field(failed.payload(), "code")),
        .@"2" = try cancelled.ret(try cancelled.body().constant(u64, 0)),
        .@"3" = try disposed.ret(try disposed.body().constant(u64, 0)),
    })));
    var compiled = try c.compile(testing.allocator, entry, try c.schema(void));
    defer compiled.deinit();
}

fn importedSequence(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const sequence = try c.sequence(unit);
    const imported = try a.interop.schema(c, try a.interop.schemaId(c, sequence));
    const entry = try c.function("compatible sequence", .{ .items = imported }, sequence, &.{});
    const body = try c.body(entry);
    const result = try body.concat(try body.parameter("items"), try body.sequenceValue(sequence, &.{}), .{});
    try c.define(entry, try body.ret(result));
    _ = try c.module(entry, unit);
}
test "review compatible imported sequences compose and tolerate allocation failures" {
    try @import("allocation_testing.zig").check(testing.allocator, importedSequence, .{});
}

test "review shared schema graph comparison does not unfold a binary tree" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    var schema = a.interop.erase(unit);
    for (0..28) |_| schema = a.interop.erase(try c.record(.{ .@"0" = schema, .@"1" = schema }));
    const imported = try a.interop.schema(c, try a.interop.schemaId(c, schema));
    const consume = try c.function("consume", .{ .value = schema }, unit, &.{});
    const consume_body = try c.body(consume);
    try c.define(consume, try consume_body.ret(try consume_body.constant(void, {})));
    const entry = try c.function("entry", .{ .value = imported }, unit, &.{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.call(consume, .{ .value = try body.parameter("value") })));
    // 29 schema nodes describe 2^28 unit leaves; comparison must visit shared pairs once.
    try testing.expectEqual(@as(usize, 29), raw.schemas.items.len);
}

test "review equal raw schemas still reject different nested field names" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const named = try c.record(.{ .code = try c.schema(u64) });
    const expected = try c.sequence(named);
    const imported = try a.interop.schema(c, try a.interop.schemaId(c, expected));
    const f = try c.function("expects names", .{ .value = expected }, unit, &.{});
    const entry = try c.function("entry", .{ .value = imported }, unit, &.{});
    const body = try c.body(entry);
    try testing.expectError(error.SchemaMismatch, body.call(a.interop.erase(f), .{ .value = try body.parameter("value") }));
}

test "review importing a scoped operation preserves its operand and clause interface" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    var compiled = try source.lower(testing.allocator, try @import("authoring_cases.zig").build(&raw, .imported_scoped));
    defer compiled.deinit();
}

test "review borrowed and recursive callable metadata compose across imports" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const region = try c.region();
    const loan = try c.borrowed(unit, region);
    const imported_loan = try a.interop.schema(c, try a.interop.schemaId(c, loan));
    const consume = try c.function("consume loan", .{ .loan = loan }, unit, &.{});
    const caller = try c.function("caller", .{ .loan = imported_loan }, unit, &.{});
    const body = try c.body(caller);
    _ = try body.call(consume, .{ .loan = try body.parameter("loan") });
    const recursive_id = try raw.reserveSchema();
    try raw.defineSchema(recursive_id, .{ .internal = .{ .computation = .{
        .parameters = &.{recursive_id},
        .result = try a.interop.schemaId(c, unit),
    } } });
    const recursive = try a.interop.schema(c, recursive_id);
    const equivalent = try c.callable(try a.interop.fields(c, recursive), unit, &.{}, .{ .use = .reusable, .captures = &.{} });
    const target = try c.function("recursive consumer", .{ .f = recursive }, unit, &.{});
    const input = try c.function("recursive input", .{ .f = equivalent }, unit, &.{});
    const input_body = try c.body(input);
    _ = try input_body.call(target, .{ .f = try input_body.parameter("f") });
}

fn namedFaultPublication(allocator: std.mem.Allocator, mismatch: bool, late: bool, abandoned: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const declared = try c.record(.{ .code = integer });
    const actual = if (mismatch) a.interop.erase(try c.record(.{ .other = integer })) else a.interop.erase(declared);
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    if (late) try c.define(entry, try body.ret(try body.constant(u64, 42)));
    const target = if (late) try c.function("late helper", .{}, integer, &.{}) else entry;
    const work = if (late) try c.body(target) else if (abandoned) try body.branch() else body;
    const literal = try a.interop.encodedLiteral(c, actual, &.{ 9, 0, 0, 0, 0, 0, 0, 0 });
    const failure = try a.interop.literalFailure(c, literal);
    const result = try work.checkedAdd(try work.constant(u64, 1), try work.constant(u64, 2), failure);
    if (abandoned) {
        work.abandon();
        try c.define(entry, try body.ret(try body.constant(u64, 42)));
    } else try c.define(target, try work.ret(result));
    var compiled = try c.compile(allocator, entry, declared);
    defer compiled.deinit();
}
test "review publication checks named faults including later helpers and ignores abandoned work" {
    try namedFaultPublication(testing.allocator, false, false, false);
    try namedFaultPublication(testing.allocator, false, true, false);
    try testing.expectError(error.SchemaMismatch, namedFaultPublication(testing.allocator, true, false, false));
    try testing.expectError(error.SchemaMismatch, namedFaultPublication(testing.allocator, true, true, false));
    try namedFaultPublication(testing.allocator, true, false, true);
}

fn namedCleanupPublication(allocator: std.mem.Allocator, mismatch: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const declared = try c.record(.{ .code = integer });
    const actual = if (mismatch) a.interop.erase(try c.record(.{ .other = integer })) else a.interop.erase(declared);
    const work_schema = try c.callable(.{}, integer, &.{}, .{ .use = .linear, .captures = &.{} });
    const work = try c.functionFor("work", work_schema);
    const work_body = try c.body(work);
    try c.define(work, try work_body.ret(try work_body.constant(u64, 42)));
    const cleanup_schema = try c.callable(.{ .exit = try c.cleanupInfo(actual) }, unit, &.{}, .{ .use = .linear, .captures = &.{} });
    const cleanup = try c.functionFor("cleanup", cleanup_schema);
    const cleanup_body = try c.body(cleanup);
    try c.define(cleanup, try cleanup_body.ret(try cleanup_body.constant(void, {})));
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.protect(try body.lambda(work, work_schema), try body.lambda(cleanup, cleanup_schema), .{})));
    var compiled = try c.compile(allocator, entry, declared);
    defer compiled.deinit();
}
test "review publication checks cleanup failure interpretation" {
    try namedCleanupPublication(testing.allocator, false);
    try testing.expectError(error.SchemaMismatch, namedCleanupPublication(testing.allocator, true));
}

test "review callable and resumption compatibility retain named capture bounds" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const first = try c.callable(.{}, unit, &.{}, .{ .use = .reusable, .captures = &.{left} });
    const second = try c.callable(.{}, unit, &.{}, .{ .use = .reusable, .captures = &.{right} });
    const use = try c.function("use", .{ .work = first }, unit, &.{});
    const entry = try c.function("entry", .{ .work = second }, unit, &.{});
    const body = try c.body(entry);
    try testing.expectError(error.SchemaMismatch, body.call(a.interop.erase(use), .{ .work = try body.parameter("work") }));
    // The failed construction is intentionally followed only by teardown.
}

fn twiceSharing(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const options = .{ .use = .reusable, .captures = &.{} };
    const first = try c.callable(.{}, left, &.{}, options);
    const second = try c.callable(.{}, right, &.{}, options);
    // Equal wire shapes must not collapse distinct named authoring contracts.
    try testing.expectEqual(try a.interop.schemaId(c, first), try a.interop.schemaId(c, second));
    const one = try c.twice(first);
    const two = try c.twice(second);
    try testing.expect(a.interop.erase(one) != a.interop.erase(two));
    const definitions = raw.functions.items.len;
    for (0..16) |_| {
        try testing.expectEqual(one, try c.twice(first));
        try testing.expectEqual(two, try c.twice(second));
    }
    try testing.expectEqual(definitions, raw.functions.items.len);
    const other = try a.Context.init(&raw);
    try testing.expectError(error.ForeignHandle, other.twice(first));
}

const FailureCase = enum { matching, mismatch, discarded };
fn handlerReturnEffects(allocator: std.mem.Allocator, pure: bool, performs: bool, pure_clause: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const ask = try c.local("return-effects/ask", unit, unit, .linear);
    const read = try c.external("return-effects/read", unit, unit);
    const handler = try c.handler(ask, unit, unit, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{read},
        .return_effects = if (pure) &.{} else null,
        .clause_effects = if (pure_clause) &.{} else null,
        .captures = &.{ unit, try c.capability(ask) },
    });
    const returns = try c.returnFunction(handler);
    const returned = try c.body(returns);
    const result = try returned.parameter("result");
    try c.define(returns, try returned.ret(if (performs)
        try returned.perform(read, result)
    else
        result));
    const clause = try c.clauseFunction(handler);
    const handled = try c.body(clause);
    const reply = try handled.perform(read, try handled.parameter("payload"));
    try c.define(clause, try handled.ret(try handled.resumeValue(
        try handled.parameter("resumption"),
        reply,
    )));
    const body_schema = try c.handledSchema(handler);
    const work = try c.functionFor("work", body_schema);
    const body = try c.body(work);
    try c.define(work, try body.ret(try body.performLocal(
        ask,
        try body.parameter("capability"),
        try body.constant(void, {}),
    )));
    const entry = try c.function("entry", .{}, unit, &.{read});
    const root = try c.body(entry);
    try c.define(entry, try root.ret(try root.handleWith(
        handler,
        try root.lambda(work, body_schema),
        .{},
    )));
    const module = try c.module(entry, unit);
    const return_id = try a.interop.functionId(c, returns);
    try testing.expectEqual(@as(usize, if (pure) 0 else 1), module.functions[return_id].effects.len);
    var compiled = try c.compile(allocator, entry, unit);
    defer compiled.deinit();
}

test "handler return effects can be pure while the clause retains residual I/O" {
    try handlerReturnEffects(testing.allocator, true, false, false);
    try handlerReturnEffects(testing.allocator, false, true, false);
    try testing.expectError(error.InvalidEffect, handlerReturnEffects(testing.allocator, true, true, false));
    try testing.expectError(error.InvalidEffect, handlerReturnEffects(testing.allocator, false, false, true));
}

fn suspensionRoundtrip(allocator: std.mem.Allocator, duplicate: bool, duplicate_product: bool, direct: bool, comptime runtime_name: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    try testing.expectError(error.InvalidCategory, c.suspensionPackage(a.interop.erase(unit)));
    const ask = try c.local("package/ask", unit, unit, .linear);
    const handler = try c.handler(ask, unit, unit, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{},
        .return_effects = &.{},
        .clause_effects = &.{},
        .captures = &.{ unit, try c.capability(ask) },
    });
    const returns = try c.returnFunction(handler);
    const returned = try c.body(returns);
    try c.define(returns, try returned.ret(try returned.parameter("result")));
    const clause = try c.clauseFunction(handler);
    const body = try c.body(clause);
    const ordinary = try body.constant(void, {});
    try testing.expectError(error.InvalidCategory, body.package(a.interop.erase(ordinary)));
    try testing.expectError(error.InvalidCategory, body.unpack(a.interop.erase(ordinary)));
    try testing.expectError(error.InvalidCategory, body.resumePackage(a.interop.erase(ordinary), ordinary));
    try testing.expectError(error.InvalidCategory, body.disposePackage(ordinary));
    const packaged = try body.package(try body.parameter("resumption"));
    const box_schema = try c.record(.{ .future = try c.suspensionPackage(try a.interop.resumptionSchema(c, handler)) });
    const box = try body.product(box_schema, .{ .future = packaged });
    const parts = try body.destructure(box);
    const future = if (runtime_name) try a.interop.get(parts, "future") else try parts.get("future");
    if (direct) {
        var selected = future;
        if (duplicate or duplicate_product) _ = try body.disposePackage(future);
        if (duplicate_product) {
            const again = try body.destructure(box);
            selected = if (runtime_name) try a.interop.get(again, "future") else try again.get("future");
        }
        try c.define(clause, try body.ret(try body.resumePackage(selected, try body.parameter("payload"))));
    } else {
        var token = try body.unpack(future);
        if (duplicate) {
            _ = try body.dispose(token);
            token = try body.unpack(future);
        }
        if (duplicate_product) {
            _ = try body.dispose(token);
            const again = try body.destructure(box);
            token = try body.unpack(try again.get("future"));
        }
        try c.define(clause, try body.ret(try body.resumeValue(token, try body.parameter("payload"))));
    }
    const work_schema = try c.handledSchema(handler);
    const work = try c.functionFor("work", work_schema);
    const working = try c.body(work);
    try c.define(work, try working.ret(try working.performLocal(
        ask,
        try working.parameter("capability"),
        try working.constant(void, {}),
    )));
    const entry = try c.function("entry", .{}, unit, &.{});
    const root = try c.body(entry);
    try c.define(entry, try root.ret(try root.handleWith(
        handler,
        try root.lambda(work, work_schema),
        .{},
    )));
    var compiled = try c.compile(allocator, entry, unit);
    defer compiled.deinit();
}

test "typed suspension packaging preserves resumption custody" {
    inline for ([_]bool{ false, true }) |runtime_name| for ([_]bool{ false, true }) |direct| {
        try suspensionRoundtrip(testing.allocator, false, false, direct, runtime_name);
        for ([_]bool{ false, true }) |product| {
            if (suspensionRoundtrip(testing.allocator, !product, product, direct, runtime_name)) {
                return error.DuplicatePackageAdmitted;
            } else |err| {
                try testing.expect(err == error.UnavailableSlot or err == error.InvalidOwnership);
            }
        }
    };
}

fn sequenceConstruction(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const seq = try c.sequence(integer);
    const entry = try c.function("sequence", .{ .values = seq }, boolean, &.{});
    const body = try c.body(entry);
    const value = try body.constant(u64, 3);
    const appended = try body.append(try body.parameter("values"), value, .{});
    const popped = try body.pop(appended);
    const empty = try body.caseOf(popped, "empty");
    const item = try body.caseOf(popped, "item");
    const parts = try item.body().destructure(item.payload());
    try testing.expectError(error.UnknownName, a.interop.erase(parts).get("missing"));
    const equal = try item.body().equal(try parts.get("head"), value);
    const result = try body.match(popped, .{ .empty = try empty.ret(try empty.body().constant(bool, false)), .item = try item.ret(equal) });
    try testing.expectError(error.ClosedBody, parts.get("head"));
    try c.define(entry, try body.ret(result));
    _ = try c.module(entry, try c.schema(void));
}

test "typed sequence pop and consuming destructure preserve names and scope" {
    try sequenceConstruction(testing.allocator);
}

fn recordUpdateBytes(allocator: std.mem.Allocator, use: @import("horos_data").program.Use, comptime runtime_names: bool, empty: bool, reference: bool, duplicate: bool) ![]u8 {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const callable = try c.callable(.{}, integer, &.{}, .{ .use = use, .captures = &.{} });
    const work = try c.functionFor("task", callable);
    const task_body = try c.body(work);
    try c.define(work, try task_body.ret(try task_body.constant(u64, 7)));
    const record = try c.record(.{ .count = integer, .extra = integer, .task = callable });
    const entry = try c.function("entry", .{}, integer, &.{});
    const body = try c.body(entry);
    const original = try body.product(record, .{
        .count = try body.constant(u64, 10),
        .extra = try body.constant(u64, 5),
        .task = try body.lambda(work, callable),
    });
    const count = try body.constant(u64, 30);
    const updated = if (reference) blk: {
        const parts = try body.destructure(original);
        break :blk try body.product(record, .{
            .count = if (empty) try parts.get("count") else count,
            .extra = try parts.get("extra"),
            .task = try parts.get("task"),
        });
    } else if (runtime_names) blk: {
        const replacements = try a.interop.RuntimeNamed(.value).init(c, if (empty) &.{} else &.{.{ .name = "count", .handle = a.interop.erase(count) }});
        break :blk try body.update(original, replacements);
    } else if (empty) try body.update(original, .{}) else try body.update(original, .{ .count = count });
    const parts = try body.destructure(updated);
    const result = try body.apply(try parts.get("task"), .{});
    if (duplicate) {
        const again = try body.destructure(original);
        _ = try body.apply(try again.get("task"), .{});
    }
    const failure = try c.literalFailure(void, {});
    const total = try body.checkedAdd(try parts.get("count"), try parts.get("extra"), failure);
    try c.define(entry, try body.ret(try body.checkedAdd(total, result, failure)));
    var compiled = try c.compile(allocator, entry, unit);
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try @import("horos_data").program_image.encodedLength(compiled.program));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}

test "record updates consume owned products once through typed and runtime names" {
    for ([_]@import("horos_data").program.Use{ .affine, .linear, .reusable }) |use| {
        for ([_]bool{ false, true }) |empty| {
            const expected = try recordUpdateBytes(testing.allocator, use, false, empty, true, false);
            defer testing.allocator.free(expected);
            inline for ([_]bool{ false, true }) |runtime_names| {
                const actual = try recordUpdateBytes(testing.allocator, use, runtime_names, empty, false, false);
                defer testing.allocator.free(actual);
                try testing.expectEqualSlices(u8, expected, actual);
                if (use != .reusable) try testing.expectError(error.UnavailableSlot, recordUpdateBytes(testing.allocator, use, runtime_names, empty, false, true));
            }
        }
    }
}

fn explicitFailure(allocator: std.mem.Allocator, mode: FailureCase) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const entry = try c.function("entry", .{ .@"error" = left }, integer, &.{});
    const body = try c.body(entry);
    const failure = try body.parameter("error");
    const target = if (mode == .discarded) a.interop.erase(try body.branch()) else a.interop.erase(body);
    const finished = try target.fail(integer, failure);
    try testing.expectError(error.ClosedBody, target.constant(u64, 0));
    try c.define(entry, if (mode == .discarded)
        try body.ret(try body.constant(u64, 42))
    else
        finished);
    _ = try c.module(entry, if (mode == .matching) a.interop.erase(left) else a.interop.erase(right));
}

test "explicit failure retains names and closes only its authored body" {
    try explicitFailure(testing.allocator, .matching);
    try testing.expectError(error.SchemaMismatch, explicitFailure(testing.allocator, .mismatch));
    try explicitFailure(testing.allocator, .discarded);
}

test "typed twice shares definitions without erasing names or builder origins" {
    try twiceSharing(testing.allocator);
}

test "review twice rejection replaces stale diagnostics with its own relationship" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const linear = try c.callable(.{}, unit, &.{}, .{ .use = .linear, .captures = &.{} });
    const probe = try c.function("earlier", .{}, unit, &.{});
    const probe_body = try c.body(probe);
    try testing.expectError(error.UnknownName, a.interop.parameter(probe_body, "missing"));
    try testing.expectError(error.InvalidOwnership, c.twice(linear));
    try testing.expectEqual(error.InvalidOwnership, c.lastDiagnostic().code.?);
    try testing.expectEqualStrings("twice", c.lastDiagnostic().entity);
    const rendered = try c.lastDiagnostic().renderAlloc(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "reusable zero-argument") != null);
}

fn publicationAllocation(allocator: std.mem.Allocator) !void {
    try namedFaultPublication(allocator, false, true, false);
    try namedCleanupPublication(allocator, false);
}
test "review publication metadata and traversal tolerate allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, publicationAllocation, .{});
}

test "review resumption capture contracts preserve nested names" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const operation = try c.local("capture", unit, unit, .multi);
    const first = try c.handler(operation, unit, unit, .{ .mode = .deep, .use = .multi, .residual = &.{}, .captures = &.{left} });
    const second = try c.handler(operation, unit, unit, .{ .mode = .deep, .use = .multi, .residual = &.{}, .captures = &.{right} });
    const first_token = try c.resumptionSchemaFor(first, operation);
    const second_token = try c.resumptionSchemaFor(second, operation);
    const use = try c.function("use", .{ .token = first_token }, unit, &.{});
    const caller = try c.function("caller", .{ .token = second_token }, unit, &.{});
    const body = try c.body(caller);
    try testing.expectError(error.SchemaMismatch, body.call(a.interop.erase(use), .{ .token = try body.parameter("token") }));
}

test "review functionFor retains its full declared callable interface" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const first = try c.callable(.{}, unit, &.{}, .{ .use = .reusable, .captures = &.{left} });
    const second = try c.callable(.{}, unit, &.{}, .{ .use = .reusable, .captures = &.{right} });
    const helper = try c.functionFor("declared", first);
    const entry = try c.function("entry", .{}, unit, &.{});
    const body = try c.body(entry);
    try testing.expectError(error.SchemaMismatch, body.lambda(helper, second));
}

fn namedContinuation(allocator: std.mem.Allocator, matching: bool, retained: bool, snapshot: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const op = try c.local("suspend", unit, integer, .linear);
    const h = try c.handler(op, integer, integer, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{},
        .captures = &.{ if (matching) a.interop.erase(left) else a.interop.erase(right), integer },
        .body_captures = &.{left},
    });
    const rf = try c.returnFunction(h);
    const returns = try c.body(rf);
    try c.define(rf, try returns.ret(try returns.parameter("result")));
    const cf = try c.clauseFunction(h);
    const clause = try c.body(cf);
    try c.define(cf, try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), try clause.constant(u64, 42))));
    const entry = try c.function("entry", .{ .record = left }, integer, &.{});
    const body = try c.body(entry);
    const record = try body.parameter("record");
    const shape = try c.handledSchema(h);
    const work_fn = try c.functionFor("work", shape);
    const work = try body.closureBody(work_fn);
    const before = if (retained) null else try work.field(record, "left");
    _ = try work.performLocal(op, try work.parameter("capability"), try work.constant(void, {}));
    const result = before orelse try work.field(record, "left");
    try c.define(work_fn, try work.ret(result));
    try c.define(entry, try body.ret(try body.handleWith(h, try body.lambda(work_fn, shape), .{})));
    var compiled = if (snapshot)
        try source.lowerObserved(allocator, try c.module(entry, unit), .{})
    else
        try c.compileWithOptions(allocator, entry, unit, .{});
    compiled.deinit();
}

test "canonical coalescing preserves named captures using authoritative liveness" {
    for ([_]bool{ false, true }) |snapshot| {
        try testing.expectError(error.SchemaMismatch, namedContinuation(testing.allocator, false, true, snapshot));
        try namedContinuation(testing.allocator, true, true, snapshot);
        try namedContinuation(testing.allocator, false, false, snapshot);
    }
}

test "review named capture observation reclaims scratch and tolerates allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, namedContinuation, .{ true, true, true });
}

test "review actual generic closure captures must satisfy named callable allowance" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const shape = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{right} });
    const entry = try c.function("entry", .{ .record = left }, integer, &.{});
    const body = try c.body(entry);
    const record = try body.parameter("record");
    const helper = try c.function("generic", .{}, integer, &.{});
    const nested = try body.closureBody(helper);
    try c.define(helper, try nested.ret(try nested.field(record, "left")));
    try c.define(entry, try body.ret(try body.apply(try body.lambda(helper, shape), .{})));
    try testing.expectError(error.SchemaMismatch, c.compile(testing.allocator, entry, unit));
}

test "review abandoned lambda metadata does not constrain a live equivalent raw constructor" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const good = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{left} });
    const bad = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{right} });
    const entry = try c.function("entry", .{ .record = left }, integer, &.{});
    const body = try c.body(entry);
    const record = try body.parameter("record");
    const helper = try c.function("helper", .{}, integer, &.{});
    const nested = try body.closureBody(helper);
    try c.define(helper, try nested.ret(try nested.field(record, "left")));
    const abandoned = try body.branch();
    _ = try abandoned.lambda(helper, bad);
    abandoned.abandon();
    try c.define(entry, try body.ret(try body.apply(try body.lambda(helper, good), .{})));
    var compiled = try c.compile(testing.allocator, entry, try c.schema(void));
    compiled.deinit();
}

const ForwardScope = enum { sibling, same, global, abandoned };
fn forwardScope(allocator: std.mem.Allocator, scenario: ForwardScope, lambda: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const shape = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{} });
    const helper = try c.functionFor("forward helper", shape);
    const entry = try c.function("entry", .{ .choose = try c.schema(bool) }, integer, &.{});
    const body = try c.body(entry);
    const left = try body.branch();
    const right = try body.branch();
    const use = if (scenario == .same) left else right;
    const pending = if (lambda) try use.apply(try use.lambda(helper, shape), .{}) else try use.call(helper, .{});
    const definition = if (scenario == .global) try c.body(helper) else try left.closureBody(helper);
    try c.define(helper, try definition.ret(try definition.constant(u64, 7)));
    const left_result = try left.ret(if (scenario == .same) pending else try left.constant(u64, 11));
    const result = if (scenario == .abandoned) blk: {
        right.abandon();
        break :blk try body.block(left_result);
    } else try body.conditional(try body.parameter("choose"), left_result, try right.ret(if (scenario == .same) try right.constant(u64, 13) else pending));
    try c.define(entry, try body.ret(result));
    // Exercise raw-source publication too: callers cannot evade the obligation
    // by choosing module() instead of Context.compile().
    var compiled = try source.lower(allocator, try c.module(entry, try c.schema(void)));
    compiled.deinit();
}

test "review late function scope rejects prior sibling calls and lambdas" {
    for ([_]bool{ false, true }) |lambda| {
        try testing.expectError(error.OutOfScope, forwardScope(testing.allocator, .sibling, lambda));
        try forwardScope(testing.allocator, .same, lambda);
        try forwardScope(testing.allocator, .global, lambda);
        try forwardScope(testing.allocator, .abandoned, lambda);
    }
}

test "review pending forward scope checks tolerate allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, forwardScope, .{ .same, true });
}

test "failure literals reject foreign contexts for both arithmetic faults" {
    for ([_]bool{ false, true }) |division| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        var other = source.Builder.init(testing.allocator);
        defer other.deinit();
        const c = try a.Context.init(&raw);
        const foreign = try a.Context.init(&other);
        const integer = try c.schema(u64);
        const entry = try c.function("entry", .{}, integer, &.{});
        const body = try c.body(entry);
        const left = try body.constant(u64, 7);
        const right = try body.constant(u64, 2);
        const failure = try foreign.literalFailure(void, {});
        if (division) {
            try testing.expectError(error.ForeignHandle, body.checked(.divide, left, right, .{
                .overflow = try c.literalFailure(void, {}),
                .division_by_zero = failure,
            }));
        } else try testing.expectError(error.ForeignHandle, body.checkedAdd(left, right, failure));
    }
}

test "review publication identifies the undefined declaration instead of its entry" {
    for ([_]bool{ false, true }) |unnamed| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const unit = try c.schema(void);
        const entry = try c.function("valid entry", .{}, unit, &.{});
        const body = try c.body(entry);
        try c.define(entry, try body.ret(try body.constant(void, {})));
        if (unnamed) {
            _ = try raw.declare(&.{}, try a.interop.schemaId(c, unit), &.{}, &.{});
        } else _ = try c.function("missing helper", .{}, unit, &.{});
        try testing.expectError(error.UndefinedBody, c.module(entry, unit));
        try testing.expectEqual(error.UndefinedBody, c.lastDiagnostic().code.?);
        try testing.expectEqualStrings(if (unnamed) "unnamed source function" else "missing helper", c.lastDiagnostic().entity);
    }
}

fn snapshotGrowth(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const failure = try c.literalFailure(void, {});
    const entry = try c.function("snapshot entry", .{}, integer, &.{});
    const body = try c.body(entry);
    const result = try body.checkedAdd(
        try body.constant(u64, 7),
        try body.constant(u64, 5),
        failure,
    );
    try c.define(entry, try body.ret(result));
    const first = try c.module(entry, unit);
    const count = first.functions.len;
    var before = try source.lower(allocator, first);
    defer before.deinit();
    const length = try @import("horos_data").program_image.encodedLength(before.program);
    const expected = try allocator.alloc(u8, length);
    defer allocator.free(expected);
    _ = try before.encode(allocator, expected);
    for (0..128) |_| {
        const helper = try c.function("later helper", .{}, integer, &.{});
        const helper_body = try c.body(helper);
        try c.define(helper, try helper_body.ret(try helper_body.constant(u64, 99)));
    }
    const second = try c.module(entry, unit);
    try testing.expectEqual(count, first.functions.len);
    try testing.expectEqual(count + 128, second.functions.len);
    try testing.expectEqual(first.entry, second.entry);
    try testing.expectEqual(first.failure, second.failure);
    var after = try source.lower(allocator, first);
    defer after.deinit();
    const actual = try allocator.alloc(u8, length);
    defer allocator.free(actual);
    _ = try after.encode(allocator, actual);
    try testing.expectEqualSlices(u8, expected, actual);
    var later = try source.lower(allocator, second);
    defer later.deinit();
}

test "published snapshots survive 128 later declarations independently" {
    try snapshotGrowth(testing.allocator);
}

test "failure literal and independent growing snapshots tolerate allocation failure" {
    try @import("allocation_testing.zig").check(testing.allocator, snapshotGrowth, .{});
}

test "consolidation arithmetic requires exactly the applicable literal faults" {
    for ([_]bool{ false, true }) |division| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const integer = try c.schema(u64);
        const entry = try c.function("entry", .{}, integer, &.{});
        const body = try c.body(entry);
        const value = try body.constant(u64, 1);
        const failure = try c.literalFailure(void, {});
        try testing.expectError(error.InvalidCategory, body.checked(
            if (division) .divide else .add,
            value,
            value,
            .{ .overflow = failure, .division_by_zero = if (division) null else failure },
        ));
    }
}

test "consolidation non-Boolean branches and malformed named aggregates reject" {
    for (0..4) |kind| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const integer = try c.schema(u64);
        const entry = try c.function("entry", .{}, integer, &.{});
        const body = try c.body(entry);
        const value = try body.constant(u64, 1);
        switch (kind) {
            0 => {
                const left = try body.branch();
                const right = try body.branch();
                try testing.expectError(error.SchemaMismatch, body.conditional(
                    a.interop.erase(value),
                    a.interop.erase(try left.ret(value)),
                    a.interop.erase(try right.ret(value)),
                ));
            },
            1 => {
                const record = try c.record(.{ .x = integer });
                try testing.expectError(error.SchemaMismatch, body.product(a.interop.erase(record), .{}));
            },
            2 => {
                const record = try c.record(.{ .x = integer, .y = integer });
                try testing.expectError(error.DuplicateName, body.product(a.interop.erase(record), try a.interop.RuntimeNamed(.value).init(c, &.{ .{ .name = "x", .handle = a.interop.erase(value) }, .{ .name = "x", .handle = a.interop.erase(value) } })));
            },
            3 => {
                const variant = try c.alternatives(.{ .x = integer });
                try testing.expectError(error.SchemaMismatch, body.variant(
                    variant,
                    "x",
                    a.interop.erase(try body.constant(bool, true)),
                ));
            },
            else => unreachable,
        }
    }
}

test "consolidation raw callable and resumption schemas reject missing children" {
    for ([_]bool{ false, true }) |resumption| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const unit = try raw.schema(.unit);
        const bad = if (resumption) try raw.schema(.{ .internal = .{ .resumption = .{
            .effect = 999,
            .input = 999,
            .answer = unit,
            .handled = &.{},
            .mode = .deep,
            .use = .linear,
        } } }) else try raw.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{999},
            .result = unit,
        } } });
        try testing.expectError(error.InvalidSchema, a.interop.schema(c, bad));
    }
}

test "OOM replaces an earlier diagnostic across authoring allocation paths" {
    for (0..4) |kind| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var raw = source.Builder.init(failing.allocator());
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const unit = try c.schema(void);
        const operation = try c.local("allocation", unit, unit, .linear);
        const entry = try c.function("entry", .{}, unit, &.{});
        const body = try c.body(entry);
        const value = try body.constant(void, {});
        try testing.expectError(error.UnknownName, a.interop.parameter(body, "missing"));
        if (kind == 3) try c.define(entry, try body.ret(value));
        failing.fail_index = failing.alloc_index;
        var failed = false;
        for (0..4096) |i| {
            const outcome: a.Error!void = switch (kind) {
                0 => result: {
                    _ = c.literalFailure(u64, @intCast(i)) catch |err| break :result err;
                    break :result {};
                },
                1 => result: {
                    _ = c.record(.{ .field = unit }) catch |err| break :result err;
                    break :result {};
                },
                2 => result: {
                    _ = c.handler(operation, unit, unit, .{
                        .mode = .deep,
                        .use = .linear,
                        .residual = &.{},
                        .captures = &.{},
                    }) catch |err| break :result err;
                    break :result {};
                },
                3 => result: {
                    _ = c.module(entry, unit) catch |err| break :result err;
                    break :result {};
                },
                else => unreachable,
            };
            outcome catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expectEqual(error.OutOfMemory, c.lastDiagnostic().code.?);
                try testing.expect(c.lastDiagnostic().expected == null);
                try testing.expect(c.lastDiagnostic().actual == null);
                try testing.expectError(error.PoisonedAuthoring, c.schema(void));
                try testing.expectEqual(error.OutOfMemory, c.lastDiagnostic().code.?);
                failed = true;
                break;
            };
        }
        try testing.expect(failed);
    }
}

fn obligationAllocation(allocator: std.mem.Allocator) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const module = try @import("authoring_cases.zig").obligationsCase(&raw, true);
    var compiled = try source.lower(allocator, module);
    defer compiled.deinit();
}

test "handler cleanup obligations require explicit opt-in" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    try testing.expectError(error.InvalidOwnership, @import("authoring_cases.zig").obligationsCase(&raw, false));
    try obligationAllocation(testing.allocator);
}

fn cellConstruction(allocator: std.mem.Allocator, negatives: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const record = try c.record(.{ .count = integer });
    const different = try c.record(.{ .other = integer });
    const region = try c.region();
    const other_region = try c.region();
    const cell = try c.cell(region, record);
    const wrong_region_cell = try c.cell(other_region, record);
    const inside_type = try c.regionBodySchema(region, .{}, integer, &.{}, .{ .use = .linear, .captures = &.{} });
    const inside_fn = try c.functionFor("cell work", inside_type);
    const inside = try c.body(inside_fn);
    const token = try inside.parameter("region");
    const one = try inside.product(record, .{ .count = try inside.constant(u64, 1) });
    const wrong = try inside.product(different, .{ .other = try inside.constant(u64, 2) });
    if (negatives) try testing.expectError(error.SchemaMismatch, inside.newCell(wrong_region_cell, token, a.interop.erase(one)));
    if (negatives) try testing.expectError(error.SchemaMismatch, inside.newCell(cell, token, a.interop.erase(wrong)));
    const allocated = try inside.newCell(cell, token, one);
    if (negatives) try testing.expectError(error.SchemaMismatch, inside.writeCell(allocated, a.interop.erase(wrong)));
    if (negatives) try testing.expectError(error.InvalidCategory, inside.readCell(a.interop.erase(one)));
    _ = try inside.writeCell(allocated, one);
    const read = try inside.readCell(allocated);
    try c.define(inside_fn, try inside.ret(try inside.field(read, "count")));
    const main = try c.function("entry", .{}, integer, &.{});
    const entry = try c.body(main);
    try c.define(main, try entry.ret(try entry.withRegion(region, try entry.lambda(inside_fn, inside_type), .{})));
    const module = try c.module(main, unit);
    _ = try @import("source/check.zig").analyze(raw.allocator(), module);
    const other = try a.Context.init(&raw);
    if (negatives) try testing.expectError(error.ForeignHandle, other.cell(region, record));
    if (negatives) try testing.expectError(error.ClosedBody, inside.readCell(a.interop.erase(allocated)));
}

test "typed cells preserve named elements, nominal regions and body lifetime" {
    try cellConstruction(testing.allocator, true);
}
fn librarySharing(allocator: std.mem.Allocator) !void {
    const writer = @import("library/writer.zig");
    const raise = @import("library/raise.zig");
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const region = try c.region();
    const logs = try writer.family(c, "sharing/log", integer);
    const failures = try raise.family(c, "sharing/raise", integer);
    const first_writer = try writer.interpret(c, logs, left, region, .{ .continuation = &.{} }, &.{});
    const second_writer = try writer.interpret(c, logs, right, region, .{ .continuation = &.{} }, &.{});
    const first_raise = try raise.catching(c, failures, left, .{ .continuation = &.{} }, &.{}, &.{});
    const second_raise = try raise.catching(c, failures, right, .{ .continuation = &.{} }, &.{}, &.{});
    try testing.expect(a.interop.erase(first_writer.handler) != a.interop.erase(second_writer.handler));
    try testing.expect(a.interop.erase(first_raise.handler) != a.interop.erase(second_raise.handler));
    const count = raw.functions.items.len;
    for (0..64) |_| {
        try testing.expectEqual(first_writer.handler, (try writer.interpret(c, logs, left, region, .{ .continuation = &.{} }, &.{})).handler);
        try testing.expectEqual(first_raise.handler, (try raise.catching(c, failures, left, .{ .continuation = &.{} }, &.{}, &.{})).handler);
    }
    try testing.expectEqual(count, raw.functions.items.len);
    const other = try a.Context.init(&raw);
    try testing.expectError(error.ForeignHandle, writer.interpret(other, logs, left, region, .{ .continuation = &.{} }, &.{}));
    try testing.expectError(error.ForeignHandle, raise.catching(other, failures, left, .{ .continuation = &.{} }, &.{}, &.{}));
}
test "typed Writer and Raise preserve named contracts and share 64 installations" {
    try librarySharing(testing.allocator);
}
fn groupedHandler(allocator: std.mem.Allocator, negative: bool, older_capture: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const first = try c.local("group/first", integer, integer, .linear);
    const second = try c.local("group/second", integer, integer, .linear);
    const alias = try a.interop.operation(c, try a.interop.operationId(c, first));
    const captures = &.{ integer, try c.capability(first), try c.capability(second) };
    const options = .{ .mode = .deep, .use = .linear, .residual = &.{}, .captures = captures, .body_captures = if (older_capture) &.{try c.capability(first)} else &.{} };
    if (negative) {
        try testing.expectError(error.InvalidEffect, c.handlerSet(.{ .one = first, .alias = alias }, integer, integer, options));
        try testing.expectError(error.DuplicateName, a.interop.RuntimeNamed(.operation).init(c, &.{ .{ .name = "same", .handle = a.interop.erase(first) }, .{ .name = "same", .handle = a.interop.erase(second) } }));
        try testing.expectError(error.InvalidCategory, c.handlerSet(.{}, integer, integer, options));
    }
    // Reverse nominal-ID order: the body parameters and continuation evidence
    // retain caller order, independently of canonical sorted effect rows.
    const h = try c.handlerSet(.{ .second = second, .first = first }, integer, integer, options);
    if (negative) {
        try testing.expectError(error.InvalidCategory, c.clauseFunction(a.interop.erase(h)));
        try testing.expectError(error.InvalidCategory, a.interop.resumptionSchema(c, h));
        const foreign = try a.Context.init(&raw);
        try testing.expectError(error.ForeignHandle, foreign.clauseFunctionFor(h, first));
    }
    try testing.expectEqual(a.interop.erase(try c.clauseFunctionFor(h, first)), try c.clauseFunctionFor(h, alias));
    try testing.expectEqual(a.interop.erase(try c.resumptionSchemaFor(h, first)), a.interop.erase(try c.resumptionSchemaFor(h, alias)));
    try testing.expect(try c.resumptionSchemaFor(h, first) != try c.resumptionSchemaFor(h, second));
    const returns_fn = try c.returnFunction(h);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
    for ([_]@TypeOf(first){ first, second }) |op| {
        const f = try c.clauseFunctionFor(h, op);
        const clause = try c.body(f);
        try c.define(f, try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), try clause.parameter("payload"))));
    }
    const schema = try c.handledSchema(h);
    const f = try c.functionFor("grouped work", schema);
    const work = try c.body(f);
    const x = try work.performLocal(first, try work.parameter("first"), try work.constant(u64, 11));
    try c.define(f, try work.ret(try work.performLocal(second, try work.parameter("second"), x)));
    const entry_fn = try c.function("entry", .{}, integer, &.{});
    const entry = try c.body(entry_fn);
    try c.define(entry_fn, try entry.ret(try entry.handleWith(h, try entry.lambda(f, schema), .{})));
    var compiled = try c.compile(allocator, entry_fn, unit);
    defer compiled.deinit();
}

test "handler sets preserve positional capabilities and reject ambiguous selection" {
    try groupedHandler(testing.allocator, true, false);
    try testing.expectError(error.InvalidEffect, groupedHandler(testing.allocator, false, true));
}
fn stateSharing(allocator: std.mem.Allocator) !void {
    const state = @import("library/state.zig");
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const region = try c.region();
    const family = try state.family(c, "sharing/state", integer);
    const bound = .{ .continuation = &.{ integer, family.getCapability(), family.putCapability() } };
    const value = (try state.interpret(c, family, integer, region, bound, &.{}, .value)).value;
    const optional = (try state.interpret(c, family, integer, region, bound, &.{}, .optional)).optional;
    const paired = (try state.interpret(c, family, integer, region, bound, &.{}, .with_state)).with_state;
    try testing.expect(a.interop.erase(value.handler) != a.interop.erase(optional.handler) and a.interop.erase(optional.handler) != a.interop.erase(paired.handler));
    const body_schema = raw.schemas.items[@intCast(try a.interop.schemaId(c, try c.handledSchema(value.handler)))].internal.computation;
    try testing.expectEqual(@as(usize, 0), body_schema.capture_bound.len);
    const count = raw.functions.items.len;
    for (0..64) |_| {
        try testing.expectEqual(value.handler, ((try state.interpret(c, family, integer, region, bound, &.{}, .value)).value).handler);
        try testing.expectEqual(optional.handler, ((try state.interpret(c, family, integer, region, bound, &.{}, .optional)).optional).handler);
        try testing.expectEqual(paired.handler, ((try state.interpret(c, family, integer, region, bound, &.{}, .with_state)).with_state).handler);
    }
    try testing.expectEqual(count, raw.functions.items.len);
    const other = try a.Context.init(&raw);
    try testing.expectError(error.ForeignHandle, state.interpret(other, family, integer, region, bound, &.{}, .value));
}
test "typed State shares each answer policy through 64 installations" {
    try stateSharing(testing.allocator);
}
fn choiceSharing(allocator: std.mem.Allocator) !void {
    const choice = @import("library/choice.zig");
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const family = try choice.family(c, "sharing/typed-choice");
    const options = .{ .captures = .{ .continuation = &.{family.capability()}, .body = @as([]const *const a.Schema(a.Dynamic), &.{}) }, .residual = &.{}, .owned_regions = @as([]const *const a.Region, &.{}), .borrowed_regions = @as([]const *const a.Region, &.{}) };
    const all = try choice.all(c, family, left, options);
    const first = try choice.first(c, family, left, options);
    const other_names = try choice.all(c, family, right, options);
    try testing.expect(a.interop.erase(all.handler) != a.interop.erase(first.handler) and a.interop.erase(all.handler) != a.interop.erase(other_names.handler));
    const count = raw.functions.items.len;
    for (0..64) |_| {
        try testing.expectEqual(all.handler, (try choice.all(c, family, left, options)).handler);
        try testing.expectEqual(first.handler, (try choice.first(c, family, left, options)).handler);
    }
    try testing.expectEqual(count, raw.functions.items.len);
    const changed = .{ .captures = .{ .continuation = options.captures.continuation, .body = &.{integer} } };
    try testing.expect((try choice.all(c, family, left, changed)).handler != all.handler);
    const region = try c.region();
    const owned = try choice.all(c, family, left, .{ .captures = options.captures, .owned_regions = &.{region} });
    const borrowed = try choice.all(c, family, left, .{ .captures = options.captures, .borrowed_regions = &.{region} });
    try testing.expect(owned.handler != borrowed.handler and owned.handler != all.handler);
    const foreign = try a.Context.init(&raw);
    try testing.expectError(error.ForeignHandle, choice.all(foreign, family, left, options));
}
test "typed Choice shares definitions and preserves names, policy and region custody" {
    try choiceSharing(testing.allocator);
}
const ResourceCase = enum { valid, unauthorized_pack, unauthorized_unpack, duplicate_owner, escaping_loan, wrong_region, wrong_names };
fn resourceConstruction(allocator: std.mem.Allocator, comptime mode: ResourceCase) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const representation = try c.record(.{ .number = integer });
    const owned = try c.resource(representation);
    const region = try c.region();
    const loan = try c.borrowed(owned, region);
    const acquire = try c.function("acquire", .{}, owned, &.{});
    const release = try c.function("release", .{ .resource = owned }, unit, &.{});
    const work_schema = try c.callable(.{ .loan = loan }, if (mode == .escaping_loan) loan else integer, &.{}, .{ .use = .linear, .captures = &.{}, .regions = &.{region} });
    const work_fn = try c.functionFor("work", work_schema);
    const entry_fn = try c.function("entry", .{}, integer, &.{});
    // Authorize the outside reader so the escape case reaches loan admission,
    // rather than failing the earlier representation-authority check.
    try c.resourceAuthority(owned, if (mode == .unauthorized_pack) &.{} else &.{ acquire, acquire }, if (mode == .unauthorized_unpack) &.{ release, entry_fn } else &.{ entry_fn, work_fn, release });
    const acquire_body = try c.body(acquire);
    const payload_schema = if (mode == .wrong_names) try c.record(.{ .other = integer }) else representation;
    const payload = if (mode == .wrong_names) try acquire_body.product(payload_schema, .{ .other = try acquire_body.constant(u64, 42) }) else try acquire_body.product(payload_schema, .{ .number = try acquire_body.constant(u64, 42) });
    try c.define(acquire, try acquire_body.ret(try acquire_body.packResource(owned, a.interop.erase(payload))));
    const release_body = try c.body(release);
    _ = try release_body.unpackResource(try release_body.parameter("resource"));
    try c.define(release, try release_body.ret(try release_body.constant(void, {})));
    const work = try c.body(work_fn);
    const view = try work.parameter("loan");
    const result = if (mode == .escaping_loan) view else try work.field(try work.unpackResource(view), "number");
    try c.define(work_fn, try work.ret(result));
    const cleanup_schema = try c.callable(.{ .exit = try c.cleanupInfo(unit), .resource = owned }, unit, &.{}, .{ .use = .linear, .captures = &.{} });
    const cleanup_fn = try c.functionFor("cleanup", cleanup_schema);
    const cleanup = try c.body(cleanup_fn);
    try c.define(cleanup_fn, try cleanup.ret(try cleanup.call(release, .{ .resource = try cleanup.parameter("resource") })));
    const entry = try c.body(entry_fn);
    const acquired = try entry.call(acquire, .{});
    const protected = try entry.bracket(acquired, if (mode == .wrong_region) try c.region() else region, try entry.lambda(work_fn, work_schema), try entry.lambda(cleanup_fn, cleanup_schema), .{});
    const final = if (mode == .escaping_loan or mode == .duplicate_owner)
        try entry.field(try entry.unpackResource(if (mode == .escaping_loan) protected else acquired), "number")
    else
        protected;
    try c.define(entry_fn, try entry.ret(final));
    var compiled = try c.compile(allocator, entry_fn, unit);
    defer compiled.deinit();
}
test "typed resources preserve representation authority and exclusive bracket custody" {
    try resourceConstruction(testing.allocator, .valid);
    try testing.expectError(error.InvalidOwnership, resourceConstruction(testing.allocator, .unauthorized_pack));
    try testing.expectError(error.InvalidOwnership, resourceConstruction(testing.allocator, .unauthorized_unpack));
    try testing.expectError(error.UnavailableSlot, resourceConstruction(testing.allocator, .duplicate_owner));
    try testing.expectError(error.InvalidOwnership, resourceConstruction(testing.allocator, .escaping_loan));
    try testing.expectError(error.SchemaMismatch, resourceConstruction(testing.allocator, .wrong_region));
    try testing.expectError(error.SchemaMismatch, resourceConstruction(testing.allocator, .wrong_names));
}
test "typed resource authority rejects foreign declarations before granting rights" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const other = try a.Context.init(&raw);
    const representation = try c.schema(u64);
    try testing.expectError(error.ForeignHandle, other.resource(representation));
    const owned = try c.resource(representation);
    const second = try c.resource(representation);
    try testing.expect(try a.interop.schemaId(c, owned) != try a.interop.schemaId(c, second));
    const foreign = try other.function("foreign introducer", .{}, try other.schema(u64), &.{});
    try testing.expectError(error.ForeignHandle, c.resourceAuthority(owned, &.{foreign}, &.{}));
    try testing.expectEqual(@as(usize, 0), raw.resources.items[0].introducers.len);
    try testing.expectEqual(@as(usize, 0), raw.resources.items[0].eliminators.len);
}

fn schemaDeclarations(allocator: std.mem.Allocator, negatives: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const declaration = try c.declareSchema(.alternatives, a.Dynamic);
    const node = declaration.schema();
    const empty = if (negatives) try c.alternatives(.{}) else null;
    if (empty) |value| try testing.expect(try a.interop.schemaId(c, value) != try a.interop.schemaId(c, node));
    const entry_fn = try c.function("entry", .{}, unit, &.{});
    const entry = try c.body(entry_fn);
    try c.define(entry_fn, try entry.ret(try entry.constant(void, {})));
    if (negatives) {
        try testing.expectError(error.UndefinedSchema, c.module(entry_fn, unit));
        try testing.expectError(error.InvalidCategory, c.defineCallable(a.interop.erase(declaration), .{}, unit, &.{}, .{ .use = .linear, .captures = &.{} }));
        const foreign = try a.Context.init(&raw);
        try testing.expectError(error.ForeignHandle, foreign.defineAlternatives(declaration, .{}));
    }
    const link = try c.record(.{ .value = try c.schema(u64), .next = node });
    try c.defineAlternatives(declaration, .{ .empty = unit, .link = link });
    if (empty) |value| try testing.expectEqual(@as(usize, 0), raw.schemas.items[@intCast(try a.interop.schemaId(c, value))].sum.len);
    if (negatives) try testing.expectError(error.SchemaAlreadyDefined, c.defineAlternatives(declaration, .{}));
    if (empty != null) {
        // Empty sums are intentionally uninhabited source placeholders; the
        // alias check does not claim that they pass data admission.
        _ = try c.module(entry_fn, unit);
    } else {
        var compiled = try c.compile(allocator, entry_fn, unit);
        defer compiled.deinit();
    }
}
test "recursive declarations are single assignment and cannot alias empty sums or publish incomplete" {
    try schemaDeclarations(testing.allocator, true);
    try schemaDeclarations(testing.allocator, false);
}
fn readerConstruction(allocator: std.mem.Allocator, sharing: bool) !void {
    const reader = @import("library/reader.zig");
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const family = try reader.family(c, "typed/reader", integer, integer, &.{}, &.{}, &.{});
    const bound = .{ .continuation = &.{ unit, integer } };
    const interpretation = try reader.interpret(c, family, integer, bound);
    if (sharing) {
        const count = raw.functions.items.len;
        for (0..64) |_| try testing.expectEqual(interpretation.handler, (try reader.interpret(c, family, integer, bound)).handler);
        try testing.expectEqual(count, raw.functions.items.len);
        const foreign = try a.Context.init(&raw);
        try testing.expectError(error.ForeignHandle, reader.interpret(foreign, family, integer, bound));
    }
    const inside_fn = try c.functionFor("local read", family.inside());
    const inside = try c.body(inside_fn);
    try c.define(inside_fn, try inside.ret(try inside.performLocal(family.ask(), try inside.parameter("ask"), try inside.constant(void, {}))));
    const schema = try c.handledSchema(interpretation.handler);
    const body_fn = try c.functionFor("two environments", schema);
    const body = try c.body(body_fn);
    const local = try body.performScoped(family.local(), try body.parameter("local"), try body.constant(u64, 20), .{ .inside = try body.lambda(inside_fn, family.inside()) });
    const outer = try body.performLocal(family.ask(), try body.parameter("ask"), try body.constant(void, {}));
    try c.define(body_fn, try body.ret(try body.checkedAdd(local, outer, try c.literalFailure(void, {}))));
    const main = try c.function("entry", .{}, integer, &.{});
    const entry = try c.body(main);
    try c.define(main, try entry.ret(try entry.handleWith(interpretation.handler, try entry.lambda(body_fn, schema), .{ .environment = try entry.constant(u64, 10) })));
    var compiled = try c.compile(allocator, main, unit);
    defer compiled.deinit();
}
test "typed Reader preserves scoped local work and shares 64 installations" {
    try readerConstruction(testing.allocator, true);
}
test "recursive Reader retains distinct named answers with equal wire layouts" {
    const reader = @import("library/reader.zig");
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const inner = try c.record(.{ .inner = integer });
    const outer = try c.record(.{ .outer = integer });
    try testing.expectEqual(try a.interop.schemaId(c, inner), try a.interop.schemaId(c, outer));
    const family = try reader.family(c, "reader/names", integer, inner, &.{}, &.{}, &.{});
    const interpreted = try reader.interpret(c, family, outer, .{ .continuation = &.{ integer, inner, outer } });
    const outside_token = try c.resumptionSchemaFor(interpreted.handler, family.ask());
    const inside_token = try c.resumptionSchemaFor(interpreted.inside_handler, family.ask());
    try testing.expectEqual(outer, try outside_token.resultSchema());
    try testing.expectEqual(inner, try inside_token.resultSchema());
    try testing.expect(a.interop.erase(interpreted.handler) != a.interop.erase(interpreted.inside_handler));
}

test "handler resumption declarations enforce kind, cardinality and single assignment" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const first = try c.local("slots/first", unit, unit, .linear);
    const second = try c.local("slots/second", unit, unit, .linear);
    const slot = try c.declareSchema(.resumption, a.Dynamic);
    const wrong = try c.declareSchema(.alternatives, a.Dynamic);
    var options: struct {
        comptime mode: @import("horos_data").program.Mode = .deep,
        use: @import("horos_data").program.Use = .linear,
        resumption_slots: ?[]const *const a.SchemaDeclaration(a.Dynamic) = null,
    } = .{};
    _ = try c.handler(first, unit, unit, options);
    _ = try c.handler(first, unit, unit, .{ .mode = .deep, .use = .linear, .resumption_slots = null });
    options.resumption_slots = &.{};
    try testing.expectError(error.SchemaMismatch, c.handler(first, unit, unit, options));
    options.resumption_slots = &.{a.interop.erase(wrong)};
    try testing.expectError(error.InvalidCategory, c.handler(first, unit, unit, options));
    options.resumption_slots = &.{ a.interop.erase(slot), a.interop.erase(slot) };
    try testing.expectError(error.DuplicateName, c.handlerSet(.{ .first = first, .second = second }, unit, unit, options));
    options.resumption_slots = &.{a.interop.erase(slot)};
    const handler = try c.handler(first, unit, unit, options);
    try testing.expectEqual(slot.schema(), a.interop.erase(try c.resumptionSchemaFor(handler, first)));
    try testing.expectError(error.SchemaAlreadyDefined, c.handler(first, unit, unit, options));
}

const SlotCollection = enum { tuple, tuple_pointer, array, array_pointer, slice, optional_tuple_pointer };
fn checkSlotCollection(comptime form: SlotCollection) !void {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const ask = try c.local("slots/ask", unit, integer, .linear);
    const reply = try c.function("reply", .{ .payload = unit }, integer, .{});
    const reply_body = try c.body(reply);
    try c.define(reply, try reply_body.ret(try reply_body.constant(u64, 1)));
    const S = a.Internal(.{ .resumption = a.ResumptionSignature(a.Shape(u64), a.Shape(void), .deep) });
    const slot = try c.declareSchema(.resumption, S);
    const tuple = .{slot};
    const array = [_]@TypeOf(slot){slot};
    const slots = switch (form) {
        .tuple => tuple,
        .tuple_pointer => &tuple,
        .array => array,
        .array_pointer => &array,
        .slice => @as([]const @TypeOf(slot), &array),
        .optional_tuple_pointer => @as(?@TypeOf(&tuple), &tuple),
    };
    const h = try c.responder(ask, unit, reply, .{ .mode = .deep, .use = .linear, .resumption_slots = slots });
    try testing.expectEqual(slot.schema(), try c.resumptionSchemaFor(h, ask));
    const entry = try c.function("entry", .{}, unit, .{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(void, {})));
    var compiled = try c.compile(testing.allocator, entry, unit);
    defer compiled.deinit();
}

test "resumption slot validation accepts the canonical handle collection forms" {
    inline for (comptime std.meta.tags(SlotCollection)) |form| try checkSlotCollection(form);
}

test "absent handle collections project to empty lists without reading storage" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const operation = try c.local("optional/local", unit, unit, .linear);
    const effect = try c.external("optional/external", unit, unit);
    const tuple = .{effect};
    const array = [_]@TypeOf(effect){effect};
    inline for (.{ @TypeOf(tuple), @TypeOf(&tuple), @TypeOf(array), @TypeOf(&array), []const @TypeOf(effect) }) |Collection| {
        const absent: ?Collection = null;
        const handler = try c.handler(operation, unit, unit, .{ .mode = .deep, .use = .linear, .residual = absent, .escaping = absent });
        const returns_fn = try c.returnFunction(handler);
        const returns = try c.body(returns_fn);
        try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
        const clause_fn = try c.clauseFunction(handler);
        const clause = try c.body(clause_fn);
        try c.define(clause_fn, try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), try clause.parameter("payload"))));
        const entry = try c.function("absent", .{}, unit, absent);
        const body = try c.body(entry);
        try c.define(entry, try body.ret(try body.constant(void, {})));
        var compiled = try c.compile(testing.allocator, entry, unit);
        defer compiled.deinit();
    }
    const nested_absent: ??@TypeOf(array) = @as(?@TypeOf(array), null);
    const entry = try c.function("nested absent", .{}, unit, nested_absent);
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(void, {})));
    var compiled = try c.compile(testing.allocator, entry, unit);
    defer compiled.deinit();

    const nested_present: ??@TypeOf(array) = array;
    const supplied = try c.function("nested present", .{}, unit, nested_present);
    const supplied_body = try c.body(supplied);
    try c.define(supplied, try supplied_body.ret(try supplied_body.perform(effect, try supplied_body.constant(void, {}))));
    var supplied_compiled = try c.compile(testing.allocator, supplied, unit);
    defer supplied_compiled.deinit();

    const slot = try c.declareSchema(.resumption, a.Dynamic);
    const absent_slots: ??[1]@TypeOf(slot) = @as(?[1]@TypeOf(slot), null);
    _ = try c.handler(operation, unit, unit, .{ .mode = .deep, .use = .linear, .resumption_slots = absent_slots });
}

test "tuple pointers retain heterogeneous resumption declaration shapes and order" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const boolean = try c.schema(bool);
    const first = try c.local("slots/integer", integer, integer, .linear);
    const second = try c.local("slots/boolean", boolean, boolean, .linear);
    const first_slot = try c.declareSchema(.resumption, a.Internal(.{ .resumption = a.ResumptionSignature(a.Shape(u64), a.Shape(void), .deep) }));
    const second_slot = try c.declareSchema(.resumption, a.Internal(.{ .resumption = a.ResumptionSignature(a.Shape(bool), a.Shape(void), .deep) }));
    const h = try c.handlerSet(.{ .first = first, .second = second }, unit, unit, .{ .mode = .deep, .use = .linear, .resumption_slots = &.{ first_slot, second_slot } });
    try testing.expectEqual(first_slot.schema(), try c.resumptionSchemaFor(h, first));
    try testing.expectEqual(second_slot.schema(), try c.resumptionSchemaFor(h, second));
    const returns_fn = try c.returnFunction(h);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
    inline for (.{ first, second }) |operation| {
        const clause_fn = try c.clauseFunctionFor(h, operation);
        const clause = try c.body(clause_fn);
        try c.define(clause_fn, try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), try clause.parameter("payload"))));
    }
    const entry = try c.function("entry", .{}, unit, .{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(void, {})));
    var compiled = try c.compile(testing.allocator, entry, unit);
    defer compiled.deinit();
}

const HandlerArgumentCase = enum { valid, missing, duplicate, wrong_type };
fn handlerArguments(allocator: std.mem.Allocator, mode: HandlerArgumentCase) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const operation = try c.local("arguments/read", unit, integer, .linear);
    const h = try c.handler(operation, integer, integer, .{
        .mode = .deep,
        .use = .linear,
        .residual = &.{},
        .captures = &.{ integer, try c.capability(operation) },
        .state = .{ .seed = integer },
        .body_parameters = .{ .seed = integer, .extra = integer },
    });
    const returns_fn = try c.returnFunction(h);
    const returns = try c.body(returns_fn);
    try c.define(returns_fn, try returns.ret(try returns.parameter("result")));
    const clause_fn = try c.clauseFunction(h);
    const clause = try c.body(clause_fn);
    try c.define(clause_fn, try clause.ret(try clause.resumeValue(try clause.parameter("resumption"), try clause.parameter("seed"))));
    const schema = try c.handledSchema(h);
    const work_fn = try c.functionFor("parameterized body", schema);
    const work = try c.body(work_fn);
    const value = try work.performLocal(operation, try work.parameter("capability"), try work.constant(void, {}));
    const fault = try c.literalFailure(void, {});
    const sum = try work.checkedAdd(value, try work.parameter("seed"), fault);
    try c.define(work_fn, try work.ret(try work.checkedAdd(sum, try work.parameter("extra"), fault)));
    const main = try c.function("entry", .{}, integer, &.{});
    const entry = try c.body(main);
    const seed = if (mode == .wrong_type) a.interop.erase(try entry.constant(bool, true)) else a.interop.erase(try entry.constant(u64, 10));
    const args = try a.interop.RuntimeNamed(.value).init(c, switch (mode) {
        .missing => &.{},
        .duplicate => &.{ .{ .name = "seed", .handle = seed }, .{ .name = "seed", .handle = seed } },
        .valid, .wrong_type => &.{ .{ .name = "extra", .handle = a.interop.erase(try entry.constant(u64, 20)) }, .{ .name = "seed", .handle = seed } },
    });
    try c.define(main, try entry.ret(try entry.handleWithArguments(h, try entry.lambda(work_fn, schema), args, .{ .seed = try entry.constant(u64, 3) })));
    var compiled = try c.compile(allocator, main, unit);
    defer compiled.deinit();
}
test "handler inputs are named and separate from handler state" {
    try handlerArguments(testing.allocator, .valid);
    try testing.expectError(error.SchemaMismatch, handlerArguments(testing.allocator, .missing));
    try testing.expectError(error.DuplicateName, handlerArguments(testing.allocator, .duplicate));
    try testing.expectError(error.SchemaMismatch, handlerArguments(testing.allocator, .wrong_type));
}
fn tailReturn(allocator: std.mem.Allocator, intervening_effect: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const notify = try c.external("tail/notify", unit, unit);
    const f = try c.function("value", .{}, integer, &.{});
    const f_body = try c.body(f);
    try c.define(f, try f_body.ret(try f_body.constant(u64, 7)));
    const entry_fn = try c.function("entry", .{}, integer, if (intervening_effect) &.{notify} else &.{});
    const entry = try c.body(entry_fn);
    const value = try entry.call(f, .{});
    if (intervening_effect) _ = try entry.perform(notify, try entry.constant(void, {}));
    try c.define(entry_fn, try entry.ret(value));
    const id = try a.interop.functionId(c, entry_fn);
    const term = raw.terms.items[@intCast(raw.functions.items[@intCast(id)].body.?)];
    try testing.expect(if (intervening_effect) term == .bind else term == .call);
    var compiled = try c.compile(allocator, entry_fn, unit);
    defer compiled.deinit();
}
test "terminal identity bindings collapse without moving intervening effects" {
    try tailReturn(testing.allocator, false);
    try tailReturn(testing.allocator, true);
}
fn searchSharing(allocator: std.mem.Allocator) !void {
    const search = @import("library/search.zig");
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const left = try c.record(.{ .left = integer });
    const right = try c.record(.{ .right = integer });
    const family = try search.family(c, "sharing/search");
    var order: search.Order = .depth_first;
    _ = &order;
    var options = .{ .captures = .{ .continuation = &.{} }, .residual = &.{}, .order = order };
    const dfs = try search.interpret(c, family, left, options);
    const renamed = try search.interpret(c, family, right, options);
    options.order = .breadth_first;
    const bfs = try search.interpret(c, family, left, options);
    try testing.expect(a.interop.erase(dfs.handler) != a.interop.erase(renamed.handler) and dfs.explore != bfs.explore);
    const count = raw.functions.items.len;
    for (0..64) |_| try testing.expectEqual(bfs.explore, (try search.interpret(c, family, left, options)).explore);
    try testing.expectEqual(count, raw.functions.items.len);
    const foreign = try a.Context.init(&raw);
    try testing.expectError(error.ForeignHandle, search.interpret(foreign, family, left, options));
}
test "typed Search shares definitions without erasing names or traversal policy" {
    try searchSharing(testing.allocator);
}
test "region body contracts canonicalize region sets without changing token position" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const outer = try c.region();
    const inner = try c.region();
    const schema = try c.regionBodySchema(inner, .{}, try c.schema(void), &.{}, .{ .use = .linear, .captures = &.{}, .regions = &.{ outer, inner, outer } });
    const signature = raw.schemas.items[@intCast(try a.interop.schemaId(c, schema))].internal.computation;
    try testing.expectEqualSlices(source.Id, &.{ 0, 1 }, signature.regions);
    try testing.expectEqual(try a.interop.schemaId(c, try c.regionSchema(inner)), signature.parameters[0]);
}

fn sequenceQueries(allocator: std.mem.Allocator, negative: bool) !void {
    var raw = source.Builder.init(allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const sequence = try c.sequence(integer);
    const function = try c.function("query", .{}, integer, &.{});
    const body = try c.body(function);
    const value = try body.constant(u64, 7);
    const values = try body.sequenceValue(sequence, &.{value});
    if (negative) {
        const boolean = try body.constant(bool, true);
        try testing.expectError(error.InvalidCategory, body.less(a.interop.erase(boolean), a.interop.erase(boolean)));
        try testing.expectError(error.InvalidCategory, body.sequenceLength(a.interop.erase(value)));
        try testing.expectError(error.SchemaMismatch, body.sequenceGet(values, a.interop.erase(boolean)));
    }
    _ = try body.less(try body.constant(i64, -3), try body.constant(i64, 2));
    const length = try body.sequenceLength(values);
    const item = try body.sequenceGet(values, try body.checked(.subtract, length, try body.constant(u64, 1), .{ .overflow = try c.literalFailure(void, {}) }));
    const missing = try body.caseOf(item, "none");
    const present = try body.caseOf(item, "some");
    _ = try present.body().yieldNow();
    try c.define(function, try body.ret(try body.match(item, .{ .none = try missing.fail(integer, try missing.body().constant(void, {})), .some = try present.ret(present.payload()) })));
    if (negative) try testing.expectError(error.ClosedBody, body.yieldNow());
    var compiled = try c.compile(allocator, function, unit);
    defer compiled.deinit();
}
test "typed sequence queries, ordering, yield and failing cases preserve contracts" {
    try sequenceQueries(testing.allocator, true);
}
test "declared function recovery retains names and refuses another context or raw declaration" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const function = try c.function("named", .{ .@"named-input" = unit }, unit, &.{});
    const id = try a.interop.functionId(c, function);
    try testing.expect(a.interop.erase(function) == try a.interop.declaredFunction(c, id));
    const foreign = try a.Context.init(&raw);
    try testing.expectError(error.InvalidReference, a.interop.declaredFunction(foreign, id));
    const raw_function = try raw.declare(&.{}, try raw.scalar(void), &.{}, &.{});
    try testing.expectError(error.InvalidReference, a.interop.declaredFunction(c, raw_function));
}

test "typed byte and indexed container queries preserve categories and optional results" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const byte_id = try raw.scalar(u8);
    const shapes = [_]@import("horos_data").program.Schema{
        .bytes,                                             .text,                                                .{ .bounded_bytes = 16 }, .{ .bounded_text = 16 },
        .{ .array = .{ .element = byte_id, .length = 2 } }, .{ .vector = .{ .element = byte_id, .maximum = 2 } },
    };
    const optional = try c.alternatives(.{ .none = unit, .some = try c.schema(u8) });
    for (shapes, 0..) |shape, index| {
        const container = try a.interop.schema(c, try raw.schema(shape));
        const function = try c.function("query", .{ .value = container, .index = integer }, optional, &.{});
        const body = try c.body(function);
        const value = try body.parameter("value");
        const offset = try body.parameter("index");
        if (index < 4) {
            try testing.expectError(error.InvalidCategory, body.blobLength(a.interop.erase(offset)));
            try testing.expectError(error.SchemaMismatch, body.blobByte(value, a.interop.erase(try body.constant(bool, true))));
            _ = try body.blobLength(value);
            try c.define(function, try body.ret(try body.blobByte(value, offset)));
        } else {
            try testing.expectError(error.InvalidCategory, body.blobByte(value, a.interop.erase(offset)));
            _ = try body.sequenceLength(value);
            try c.define(function, try body.ret(try body.sequenceGet(value, offset)));
        }
        var compiled = try c.compile(testing.allocator, function, unit);
        defer compiled.deinit();
    }
}

test "typed equality primitives retain category origin and fault contracts" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const unit = try c.schema(void);
    const integer = try c.schema(u64);
    const choice = try c.alternatives(.{ .empty = unit, .number = integer });
    const enumeration = try a.interop.schema(c, try raw.schema(.{ .enumeration = &.{ 5, 12 } }));
    const bytes = try a.interop.schema(c, try raw.schema(.{ .bounded_bytes = 8 }));
    const output = try c.record(.{ .@"enum" = try c.schema(u32), .tag = integer, .payload = integer, .order = try c.schema(i8) });
    const f = try c.function("inspect portable values", .{ .choice = choice, .@"enum" = enumeration, .left = bytes, .right = bytes }, output, &.{});
    const body = try c.body(f);
    const selected = try body.parameter("choice");
    const tag = try body.parameter("enum");
    const left = try body.parameter("left");
    const fault = try c.literalFailure(void, {});
    try testing.expectError(error.InvalidCategory, body.enumTag(a.interop.erase(selected)));
    try testing.expectError(error.InvalidCategory, body.variantTag(tag));
    try testing.expectError(error.UnknownName, body.variantPayload(a.interop.erase(selected), "missing", fault));
    try testing.expectError(error.InvalidCategory, body.blobCompare(left, tag));
    const foreign = try a.Context.init(&raw);
    const foreign_fault = try foreign.literalFailure(void, {});
    try testing.expectError(error.ForeignHandle, body.variantPayload(a.interop.erase(selected), "number", foreign_fault));
    try testing.expectError(error.ForeignHandle, a.interop.failureLiteralId(c, foreign_fault));
    try testing.expectEqual(try a.interop.failureLiteralId(c, fault), try a.interop.failureLiteralId(c, try c.literalFailure(void, {})));
    try c.define(f, try body.ret(try body.product(output, .{ .@"enum" = try body.enumTag(tag), .tag = try body.variantTag(selected), .payload = try body.variantPayload(selected, "number", fault), .order = try body.blobCompare(left, try body.parameter("right")) })));
    var compiled = try c.compile(testing.allocator, f, unit);
    defer compiled.deinit();
}

test "typed eager selection checks the condition and both value contracts" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const f = try c.function("select", .{ .condition = try c.schema(bool) }, integer, &.{});
    const body = try c.body(f);
    const condition = try body.parameter("condition");
    const yes = try body.constant(u64, 1);
    const no = try body.constant(u64, 2);
    try testing.expectError(error.SchemaMismatch, body.select(a.interop.erase(yes), a.interop.erase(yes), a.interop.erase(no)));
    try testing.expectError(error.SchemaMismatch, body.select(a.interop.erase(condition), a.interop.erase(yes), a.interop.erase(condition)));
    try c.define(f, try body.ret(try body.select(condition, yes, no)));
    var compiled = try c.compile(testing.allocator, f, try c.schema(void));
    defer compiled.deinit();
}

test "typed and direct compilation share explicit contracts and mandatory P01" {
    const data = @import("horos_data");
    for ([_]bool{ false, true }) |typed| for ([_]data.closed_compilation.Contract{ .structural, .semantic }) |contract| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const integer = try c.schema(u64);
        const unit = try c.schema(void);
        const entry = try c.function("entry", .{ .x = integer }, integer, &.{});
        const body = try c.body(entry);
        const x = try body.parameter("x");
        const schema = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{integer} });
        const nested = try c.functionFor("nested", schema);
        const inner = try body.closureBody(nested);
        try c.define(nested, try inner.ret(x));
        try c.define(entry, try body.ret(try body.apply(try body.lambda(nested, schema), .{})));
        var stats: data.closed_compilation.Statistics = .{};
        var p01: data.coalescing.Statistics = .{};
        var result = if (typed)
            try c.compileWithCompilation(testing.allocator, entry, unit, .{ .contract = contract, .statistics = &stats, .coalescing = .{ .statistics = &p01 } })
        else
            try source.lowerObserved(testing.allocator, try c.module(entry, unit), .{ .contract = contract, .semantic_statistics = &stats, .coalescing = .{ .statistics = &p01 } });
        defer result.deinit();
        try testing.expect(p01.outcome != .not_run);
        if (contract == .semantic) {
            try testing.expect(stats.stages_run > 0);
            try testing.expect(stats.outcome != .work_limit);
        } else try testing.expectEqual(data.closed_compilation.Outcome.structural, stats.outcome);
    };
}

test "semantic compilation reports unmapped origins explicitly after rewriting" {
    const data = @import("horos_data");
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const entry = try c.function("entry", .{ .x = integer }, integer, &.{});
    const body = try c.body(entry);
    const x = try body.parameter("x");
    const schema = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{integer} });
    const nested = try c.functionFor("nested", schema);
    const inner = try body.closureBody(nested);
    try c.define(nested, try inner.ret(x));
    try c.define(entry, try body.ret(try body.apply(try body.lambda(nested, schema), .{})));
    var diagnostic: source.Diagnostic = .{};
    var statistics: data.closed_compilation.Statistics = .{};
    try testing.expectError(error.Capacity, source.lowerObserved(testing.allocator, try c.module(entry, unit), .{
        .contract = .semantic,
        .max_image_bytes = 0,
        .diagnostic = &diagnostic,
        .semantic_statistics = &statistics,
    }));
    try testing.expect(statistics.changed_stages > 0);
    try testing.expectEqual(@as(?data.program.Id, null), diagnostic.function);
    try testing.expectEqual(@as(?data.program.Id, null), diagnostic.variable);
    try testing.expectEqual(@as(usize, 0), diagnostic.origins.count);
    try testing.expect(diagnostic.origins.ambiguous);
    var valid = try source.lowerObserved(testing.allocator, try c.module(entry, unit), .{
        .contract = .semantic,
        .diagnostic = &diagnostic,
    });
    defer valid.deinit();
    try testing.expectEqual(source.CompileStage.complete, diagnostic.phase);
    try testing.expect(!diagnostic.origins.ambiguous);
    try testing.expectEqual(@as(?anyerror, null), diagnostic.code);
}

test "semantic typed compilation cannot erase an original named capture violation" {
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const integer = try c.schema(u64);
    const unit = try c.schema(void);
    const entry = try c.function("entry", .{ .x = integer }, integer, &.{});
    const body = try c.body(entry);
    const x = try body.parameter("x");
    const schema = try c.callable(.{}, integer, &.{}, .{ .use = .reusable, .captures = &.{} });
    const nested = try c.functionFor("nested", schema);
    const inner = try body.closureBody(nested);
    try c.define(nested, try inner.ret(x));
    try c.define(entry, try body.ret(try body.apply(try body.lambda(nested, schema), .{})));
    try testing.expectError(error.SchemaMismatch, c.compileWithCompilation(testing.allocator, entry, unit, .{ .contract = .semantic }));
}

test "typed publication resets reused compilation observations before rejection" {
    const data = @import("horos_data");
    for ([_]data.closed_compilation.Contract{ .structural, .semantic }) |contract| {
        var raw = source.Builder.init(testing.allocator);
        defer raw.deinit();
        const c = try a.Context.init(&raw);
        const unit = try c.schema(void);
        const entry = try c.function("entry", .{}, unit, &.{});
        const body = try c.body(entry);
        try c.define(entry, try body.ret(try body.constant(void, {})));
        var stats: data.closed_compilation.Statistics = .{};
        var p01: data.coalescing.Statistics = .{};
        const options: data.closed_compilation.Options = .{ .contract = contract, .statistics = &stats, .coalescing = .{ .statistics = &p01 } };
        for ([_]bool{ false, true }) |foreign| {
            var valid = try c.compileWithCompilation(testing.allocator, entry, unit, options);
            valid.deinit();
            try testing.expect(stats.outcome != .not_run);
            try testing.expect(p01.outcome != .not_run);
            var other_raw = source.Builder.init(testing.allocator);
            defer other_raw.deinit();
            const other = try a.Context.init(&other_raw);
            const other_unit = try other.schema(void);
            const undefined_entry = try other.function("undefined", .{}, other_unit, &.{});
            if (foreign) {
                try testing.expectError(error.ForeignHandle, other.compileWithCompilation(testing.allocator, entry, other_unit, options));
            } else {
                try testing.expectError(error.UndefinedBody, other.compileWithCompilation(testing.allocator, undefined_entry, other_unit, options));
            }
            try testing.expectEqualDeep(data.closed_compilation.Statistics{}, stats);
            try testing.expectEqualDeep(data.coalescing.Statistics{}, p01);
        }
    }
}

test "indexed named assembly preserves declaration-order diagnostic priority" {
    for (0..3) |which| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        var foreign = source.Builder.init(testing.allocator);
        defer foreign.deinit();
        const c = try a.Context.init(&b);
        const other = try a.Context.init(&foreign);
        const boolean = try c.schema(bool);
        const record = try c.record(.{ .a = boolean, .b = boolean });
        const main = try c.function("main", .{}, record, &.{});
        const body = try c.body(main);
        const value = try body.constant(bool, true);
        const other_boolean = try other.schema(bool);
        const other_main = try other.function("foreign", .{}, other_boolean, &.{});
        const other_body = try other.body(other_main);
        const foreign_value = try other_body.constant(bool, true);
        switch (which) {
            0 => try testing.expectError(error.UnknownName, body.product(a.interop.erase(record), try a.interop.RuntimeNamed(.value).init(c, &.{ .{ .name = "b", .handle = a.interop.erase(value) }, .{ .name = "b", .handle = a.interop.erase(value) } }))),
            1 => try testing.expectError(error.DuplicateName, body.product(a.interop.erase(record), try a.interop.RuntimeNamed(.value).init(c, &.{ .{ .name = "a", .handle = a.interop.erase(value) }, .{ .name = "a", .handle = a.interop.erase(value) } }))),
            2 => try testing.expectError(error.ForeignHandle, a.interop.RuntimeNamed(.value).init(c, &.{ .{ .name = "a", .handle = a.interop.erase(foreign_value) }, .{ .name = "unknown", .handle = a.interop.erase(value) } })),
            else => unreachable,
        }
    }
}

test "indexed field declarations check schema authority before a duplicate name" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    var foreign = source.Builder.init(testing.allocator);
    defer foreign.deinit();
    const c = try a.Context.init(&b);
    const other = try a.Context.init(&foreign);
    const local = try c.schema(bool);
    const elsewhere = try other.schema(bool);
    try testing.expectError(error.ForeignHandle, a.interop.RuntimeNamed(.schema).init(c, &.{ .{ .name = "same", .handle = a.interop.erase(local) }, .{ .name = "same", .handle = a.interop.erase(elsewhere) } }));
}

test "typed and source compilation preserve supplied profile validation and use" {
    const data = @import("horos_data");
    var raw = source.Builder.init(testing.allocator);
    defer raw.deinit();
    const c = try a.Context.init(&raw);
    const word = try c.schema(u64);
    const unit = try c.schema(void);
    const entry = try c.function("identity", .{ .x = word }, word, &.{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.parameter("x")));
    const module = try c.module(entry, unit);
    var original = try c.compile(testing.allocator, entry, unit);
    defer original.deinit();
    const counts = try testing.allocator.alloc(u64, original.program.blocks.len);
    defer testing.allocator.free(counts);
    @memset(counts, 0);
    const valid: data.closed_compilation.ProfilePolicy = .{ .record = .{
        .image_identity = try data.program_image.identity(testing.allocator, original.program),
        .block_counts = counts,
        .total = 0,
    } };
    for ([_]data.closed_compilation.Contract{ .structural, .semantic }) |contract| {
        var stats: data.closed_compilation.Statistics = .{};
        var typed = try c.compileWithCompilation(testing.allocator, entry, unit, .{ .contract = contract, .profile = valid, .statistics = &stats });
        defer typed.deinit();
        try testing.expectEqual(contract == .semantic, stats.profile_used);
        var direct = try source.lowerObserved(testing.allocator, module, .{ .contract = contract, .profile = valid, .semantic_statistics = &stats });
        defer direct.deinit();
        try testing.expectEqual(contract == .semantic, stats.profile_used);
        for (0..3) |mutation| {
            var invalid = valid;
            switch (mutation) {
                0 => invalid.record.version = 999,
                1 => invalid.record.image_identity[0] ^= 1,
                else => invalid.record.block_counts = &.{},
            }
            try testing.expectError(error.InvalidOptimizationProfile, c.compileWithCompilation(testing.allocator, entry, unit, .{ .contract = contract, .profile = invalid }));
            try testing.expectError(error.InvalidOptimizationProfile, source.lowerObserved(testing.allocator, module, .{ .contract = contract, .profile = invalid }));
        }
    }
}
