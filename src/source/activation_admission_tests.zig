// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const lower = @import("activation_lower.zig").lower;
const data = @import("horos_data");
const p = data.program;
const ir = data.activation;
const testing = std.testing;

fn check(image: ir.Program) !void {
    var facts = try data.activation_ownership.analyze(testing.allocator, image);
    defer facts.deinit();
}

test "tail clause admission rejects cycles suspension and shallow forgery" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.branchingTail(&builder));
    defer compiled.deinit();
    var image = compiled.program;
    const clause = image.handlers[0].clauses[0];
    const entry = image.functions[@intCast(clause.function)].entry;
    const blocks = try testing.allocator.dupe(ir.Block, image.blocks);
    defer testing.allocator.free(blocks);
    image.blocks = blocks;
    const original = blocks[@intCast(entry)];
    blocks[@intCast(entry)].terminator = .{ .jump = .{ .block = entry } };
    try testing.expectError(error.InvalidProgram, check(image));
    blocks[@intCast(entry)].terminator = .{ .yield_value = .{ .block = entry } };
    try testing.expectError(error.InvalidProgram, check(image));
    blocks[@intCast(entry)] = original;
    const handlers = try testing.allocator.dupe(ir.Handler, image.handlers);
    defer testing.allocator.free(handlers);
    image.handlers = handlers;
    handlers[0].mode = .shallow;
    try testing.expectError(error.TypeMismatch, check(image));
    // A matching forged signature must still fail the tail-strategy law, not
    // merely the earlier handler/signature consistency check.
    const schemas = try testing.allocator.dupe(p.Schema, image.schemas);
    defer testing.allocator.free(schemas);
    image.schemas = schemas;
    schemas[@intCast(clause.resumption)].internal.resumption.mode = .shallow;
    try testing.expectError(error.InvalidProgram, check(image));
}

test "stable admission rejects forged operation types and missing arithmetic failures" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.installations(&builder, 1));
    defer compiled.deinit();
    var image = compiled.program;
    const blocks = try testing.allocator.dupe(ir.Block, image.blocks);
    defer testing.allocator.free(blocks);
    image.blocks = blocks;
    for (blocks) |*block| {
        for (block.instructions, 0..) |instruction, index| {
            if (instruction.opcode != .integer_add) continue;
            const operations = try testing.allocator.dupe(ir.Instruction, block.instructions);
            defer testing.allocator.free(operations);
            block.instructions = operations;
            try check(image);
            operations[index].failures = &.{};
            try testing.expectError(error.InvalidProgram, check(image));
            operations[index] = instruction;
            operations[index].opcode = .boolean_not;
            operations[index].operands = instruction.operands[0..1];
            operations[index].failures = &.{};
            try testing.expectError(error.TypeMismatch, check(image));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "stable admission rejects an emitter that hides a residual effect" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.deep(&builder));
    defer compiled.deinit();
    var image = compiled.program;
    const functions = try testing.allocator.dupe(ir.Function, image.functions);
    defer testing.allocator.free(functions);
    image.functions = functions;
    for (image.blocks) |block| {
        if (block.terminator != .perform) continue;
        functions[@intCast(block.function)].effects = &.{};
        try testing.expectError(error.InvalidEffect, check(image));
        return;
    }
    return error.TestUnexpectedResult;
}

test "stable admission rejects a falsely weakened callable capture bound" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.lexical(&builder));
    defer compiled.deinit();
    var image = compiled.program;
    const schemas = try testing.allocator.dupe(p.Schema, image.schemas);
    defer testing.allocator.free(schemas);
    image.schemas = schemas;
    for (schemas) |*schema| {
        if (schema.* != .internal or schema.internal != .computation or
            schema.internal.computation.capture_bound.len == 0) continue;
        schema.internal.computation.capture_bound = &.{};
        try testing.expectError(error.InvalidOwnership, check(image));
        return;
    }
    return error.TestUnexpectedResult;
}

test "stable admission enforces nominal resource elimination authority" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.resourceScalar(&builder));
    defer compiled.deinit();
    var image = compiled.program;
    const resources = try testing.allocator.dupe(p.Resource, image.scopes.resources);
    defer testing.allocator.free(resources);
    image.scopes.resources = resources;
    try testing.expect(resources.len != 0);
    for (resources) |*resource| resource.eliminators = &.{};
    try testing.expectError(error.InvalidOwnership, check(image));
}

test "stable admission preserves ordinary-discard rejection and failure custody" {
    const edges = @import("custody_edge_example.zig");
    for (0..edges.count) |index| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const entry = try edges.scenario(&builder, index, false);
        try testing.expectError(
            error.InvalidOwnership,
            lower(testing.allocator, builder.module(entry, try builder.scalar(u64))),
        );
        var failing = source.Builder.init(testing.allocator);
        defer failing.deinit();
        const failed = try edges.scenario(&failing, index, true);
        var compiled = try lower(
            testing.allocator,
            failing.module(failed, try failing.scalar(u64)),
        );
        defer compiled.deinit();
        try testing.expect(compiled.program.blocks.len != 0);
    }
}

test "stable admission uses declared input destinations for real function calls" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const main = try builder.declare(&.{ integer, integer }, integer, &.{}, &.{});
    const helper = try builder.declare(&.{ integer, integer }, integer, &.{}, &.{});
    try builder.define(
        helper,
        try builder.pure(try builder.reference(builder.parameter(helper, 1))),
    );
    try builder.define(main, try builder.term(.{ .call = .{
        .function = helper,
        .arguments = &.{
            try builder.reference(builder.parameter(main, 0)),
            try builder.reference(builder.parameter(main, 0)),
        },
    } }));
    var compiled = try lower(testing.allocator, builder.module(main, unit));
    defer compiled.deinit();
    var image = compiled.program;
    const functions = try testing.allocator.dupe(ir.Function, image.functions);
    defer testing.allocator.free(functions);
    image.functions = functions;
    functions[@intCast(helper)].inputs = &.{ 1, 0 };
    try check(image);
    functions[@intCast(helper)].inputs = &.{ 0, 0 };
    try testing.expectError(error.DuplicateDestination, check(image));
}

test "stable lowering records custody exit before a sibling binding scope" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const queue = try builder.schema(.{ .seq = try builder.resource(integer) });
    const empty = try builder.primitive(queue, .sequence, &.{}, 0);
    const outer = try builder.variable(queue);
    const inner = try builder.variable(queue);
    const later = try builder.variable(queue);
    const observed = try builder.variable(integer);
    const value = try builder.bind(
        inner,
        try builder.pure(empty),
        try builder.pure(try builder.constant(u64, 0)),
    );
    const failure = try builder.term(.{ .fail = try builder.constant(u64, 9) });
    const next = try builder.bind(later, try builder.pure(empty), failure);
    const entry = try builder.declare(&.{}, integer, &.{}, &.{});
    try builder.define(
        entry,
        try builder.bind(
            outer,
            try builder.pure(empty),
            try builder.bind(observed, value, next),
        ),
    );
    var compiled = try lower(testing.allocator, builder.module(entry, integer));
    defer compiled.deinit();
    const image = compiled.program;
    const function = image.functions[@intCast(entry)];
    try testing.expectEqual(4, function.custody.len);
    try testing.expectEqual(@as(?p.Id, null), function.custody[0].parent);
    try testing.expectEqual(@as(?p.Id, 0), function.custody[1].parent);
    try testing.expectEqual(@as(?p.Id, 1), function.custody[2].parent);
    try testing.expectEqual(@as(?p.Id, 1), function.custody[3].parent);
    var exited = false;
    var failed_in_sibling = false;
    for (image.blocks) |block| {
        if (block.terminator == .jump and block.custody == 2) {
            const target = image.blocks[@intCast(block.terminator.jump.block)];
            exited = exited or target.custody == 1;
        }
        if (block.terminator == .fail) failed_in_sibling = block.custody == 3;
    }
    try testing.expect(exited and failed_in_sibling);
}

test "stable admission rejects corrupt custody trees and block scope references" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const edges = @import("custody_edge_example.zig");
    const entry = try edges.scenario(&builder, 8, true);
    var compiled = try lower(testing.allocator, builder.module(entry, try builder.scalar(u64)));
    defer compiled.deinit();
    var image = compiled.program;
    const functions = try testing.allocator.dupe(ir.Function, image.functions);
    defer testing.allocator.free(functions);
    image.functions = functions;
    for (functions) |*function| {
        if (function.custody.len <= 1) continue;
        const original = function.custody;
        const scopes = try testing.allocator.dupe(ir.CustodyScope, original);
        defer testing.allocator.free(scopes);
        function.custody = scopes;
        scopes[1].parent = 1;
        try testing.expectError(error.InvalidReference, check(image));
        function.custody = &.{};
        try testing.expectError(error.InvalidProgram, check(image));
        function.custody = original;
        const blocks = try testing.allocator.dupe(ir.Block, image.blocks);
        defer testing.allocator.free(blocks);
        image.blocks = blocks;
        blocks[@intCast(function.entry)].custody = original.len;
        try testing.expectError(error.InvalidProgram, check(image));
        return;
    }
    return error.TestUnexpectedResult;
}

test "stable clause payload admission distinguishes an older capability from its own delimiter" {
    inline for (.{ false, true }) |older| inline for (.{ false, true }) |delegated| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try @import("clause_payload_example.zig").variant(
            &builder,
            older,
            delegated,
        );
        if (older) {
            var compiled = try lower(testing.allocator, module);
            defer compiled.deinit();
        } else try testing.expectError(error.InvalidOwnership, lower(testing.allocator, module));
    };
}

test "stable resource borrow cannot escape a protected body for an immediate caller read" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const original = try source.examples.resourceScalar(&b);
    const main_bind = try @import("fixture_inspection.zig").resourceEntry(&b, original.entry);
    const protected = main_bind.next;
    const body_value = b.terms.items[@intCast(protected)].protect.body;
    const body_function = b.values.items[@intCast(body_value)].expression.lambda;
    const parameter = b.parameter(body_function, 0);
    const borrowed = b.variables.items[@intCast(parameter)];
    var signature = b.schemas.items[
        @intCast(b.values.items[
            @intCast(body_value)
        ].schema)
    ].internal.computation;
    signature.result = borrowed;
    b.values.items[
        @intCast(body_value)
    ].schema = try b.schema(.{ .internal = .{ .computation = signature } });
    b.functions.items[@intCast(body_function)].result = borrowed;
    b.functions.items[@intCast(body_function)].body = try b.pure(try b.reference(parameter));
    const escaped = try b.variable(borrowed);
    const read = try b.term(.{ .call = .{
        .function = b.resources.items[0].eliminators[0],
        .arguments = &.{try b.reference(escaped)},
    } });
    const next = try b.bind(escaped, protected, read);
    b.functions.items[@intCast(original.entry)].body = try b.bind(
        main_bind.variable,
        main_bind.value,
        next,
    );
    try testing.expectError(
        error.InvalidOwnership,
        lower(testing.allocator, b.module(original.entry, original.failure)),
    );
}
