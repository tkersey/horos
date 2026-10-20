// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const lower = @import("activation_lower.zig").lower;
const data = @import("horos_data");
const ir = data.activation;
const p = data.program;
const testing = std.testing;
const check = @import("check.zig");

test "total branching tail clauses are distinct from general control" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.branchingTail(&builder));
    defer compiled.deinit();
    const clause = compiled.program.handlers[0].clauses[0];
    try testing.expect(clause.strategy == .tail);
    const function = compiled.program.functions[@intCast(clause.function)];
    try testing.expectEqual(1, function.inputs.len);
    var branches: usize = 0;
    var returns: usize = 0;
    for (compiled.program.blocks) |block| {
        if (block.function != clause.function) continue;
        if (block.terminator == .branch) branches += 1;
        if (block.terminator == .return_value) returns += 1;
        try testing.expect(block.terminator != .resume_value);
    }
    try testing.expectEqual(1, branches);
    try testing.expectEqual(2, returns);
    inline for (.{
        source.examples.deep,
        source.examples.shallow,
        source.examples.generator,
        source.examples.reentrant,
    }) |example| {
        var sibling = source.Builder.init(testing.allocator);
        defer sibling.deinit();
        var general = try lower(testing.allocator, try example(&sibling));
        defer general.deinit();
        try testing.expect(general.program.handlers[0].clauses[0].strategy == .general);
    }
}

test "immediate lexical application uses direct calls without erasing callable contracts" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const original = try source.examples.lexical(&builder);
    const main = &builder.functions.items[@intCast(original.entry)];
    const binding = builder.terms.items[@intCast(main.body.?)].bind;
    var application = builder.terms.items[@intCast(binding.next)].apply;
    application.computation = builder.terms.items[@intCast(binding.value)].value;
    main.body = try builder.term(.{ .apply = application });
    var compiled = try lower(testing.allocator, builder.module(original.entry, original.failure));
    defer compiled.deinit();
    var calls: usize = 0;
    for (compiled.program.blocks) |block| {
        for (block.instructions) |instruction| try testing.expect(
            instruction.opcode != .computation,
        );
        try testing.expect(block.terminator != .apply);
        if (block.terminator == .call) {
            calls += 1;
            try testing.expectEqual(2, block.terminator.call.arguments.len);
        }
    }
    try testing.expectEqual(1, calls);
    // The original lambda's capture bound is still checked after specialization.
    const schema = builder.values.items[@intCast(application.computation)].schema;
    builder.schemas.items[@intCast(schema)].internal.computation.capture_bound = &.{};
    try testing.expectError(
        error.InvalidOwnership,
        lower(testing.allocator, builder.module(original.entry, original.failure)),
    );
}

test "immediate application retains the capture boundary for an owned resumption" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const original = try source.examples.deep(&builder);
    const clause = builder.handlers.items[0].clauses[0];
    const definition = builder.functions.items[@intCast(clause.function)];
    const inner = try builder.declare(&.{}, definition.result, definition.effects, &.{});
    try builder.define(inner, definition.body.?);
    const signature = try builder.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = definition.result,
        .effects = definition.effects,
        .capture_bound = &.{clause.resumption},
        .use = .linear,
    } } });
    builder.functions.items[@intCast(clause.function)].body = try builder.term(.{ .apply = .{
        .computation = try builder.lambda(inner, signature),
        .arguments = &.{},
    } });
    var compiled = try lower(testing.allocator, builder.module(original.entry, original.failure));
    defer compiled.deinit();
    var found = false;
    for (compiled.program.blocks) |block| {
        if (block.function != clause.function or block.terminator != .apply) continue;
        found = true;
        try testing.expectEqual(1, block.instructions.len);
        try testing.expectEqual(p.Opcode.computation, block.instructions[0].opcode);
    }
    try testing.expect(found);
}

test "module observes declarations made while evaluating its arguments" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    try builder.define(main, try builder.pure(try builder.constant(u64, 42)));
    var compiled = try source.lower(
        testing.allocator,
        builder.module(main, try builder.scalar(void)),
    );
    defer compiled.deinit();
    try testing.expect(compiled.program.schemas[@intCast(compiled.program.roots.failure)] == .unit);
}

test "installation lowering establishes each result once without pass-through interfaces" {
    for ([_]usize{ 1, 8, 64, 128, 256 }) |count| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const input = try source.examples.installations(&builder, count);
        var compiled = try lower(testing.allocator, input);
        defer compiled.deinit();
        const image = compiled.program;
        try data.activation_structure.validate(testing.allocator, image);
        const flow = compiled.flow;
        try testing.expect(flow.block_visits <= image.blocks.len * 2);
        try testing.expect(flow.liveness_visits <= image.blocks.len * 4);
        const entry = image.functions[@intCast(image.roots.entry)];
        try testing.expectEqual(1, entry.custody.len);
        try testing.expectEqual(4 * count + 1, entry.layout.slots.len);
        try testing.expectEqual(0, entry.inputs.len);
        var blocks: usize = 0;
        var instructions: usize = 0;
        var results: usize = 0;
        var sums: usize = 0;
        for (image.blocks) |block| {
            if (block.function != image.roots.entry) continue;
            blocks += 1;
            instructions += block.instructions.len;
            switch (block.terminator) {
                .handle => |handle| {
                    try testing.expectEqual(1, handle.next.assignments.len);
                    try testing.expect(handle.next.assignments[0].source == .returned);
                    results += 1;
                },
                .jump => |edge| try testing.expectEqual(0, edge.assignments.len),
                .return_value => {
                    for (block.instructions) |operation| {
                        if (operation.opcode == .integer_add) sums += 1;
                    }
                },
                else => return error.TestUnexpectedResult,
            }
        }
        // Empty administrative jumps are threaded; real handlers remain.
        try testing.expectEqual(count + 1, blocks);
        try testing.expectEqual(3 * count + 1, instructions);
        try testing.expectEqual(count, results);
        // The checked sum still occurs after all the handler installations.
        try testing.expectEqual(count, sums);
    }
}

test "stable source analysis shares growing free-variable sets" {
    for ([_]usize{ 1, 8, 64, 128, 256, 512, 1024 }) |count| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const input = try source.examples.installations(&builder, count);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const facts = try check.analyze(arena.allocator(), input);
        // Counts cover the actual pool, including intermediate fixed-point work.
        // Logical memberships grow quadratically; stored descriptions must not.
        try testing.expect(facts.sets.nodeCount() <= 4 * count + 64);
        try testing.expect(facts.sets.visits <= 24 * count + 128);
        try testing.expectEqual(0, facts.functions[@intCast(input.entry)].items.len);
    }
}

test "stable source analysis closes mutually recursive lexical captures" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const boolean = try builder.scalar(bool);
    const unit = try builder.scalar(void);
    const main = try builder.declare(&.{integer}, integer, &.{}, &.{});
    const left = try builder.declare(&.{integer}, integer, &.{}, &.{});
    const right = try builder.declare(&.{integer}, integer, &.{}, &.{});
    const outer = builder.parameter(main, 0);
    const failure = try builder.failureLiteral(try builder.constant(void, {}));
    for ([_]p.Id{ left, right }, [_]p.Id{ right, left }) |function, other| {
        const n = try builder.reference(builder.parameter(function, 0));
        const condition = try builder.primitive(
            boolean,
            .equal,
            &.{ n, try builder.constant(u64, 0) },
            0,
        );
        const decrement = try builder.value(.{ .schema = integer, .expression = .{ .primitive = .{
            .opcode = .integer_sub,
            .operands = &.{ n, try builder.constant(u64, 1) },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } } });
        const call = try builder.term(.{ .call = .{
            .function = other,
            .arguments = &.{decrement},
        } });
        try builder.define(function, try builder.term(.{ .conditional = .{
            .condition = condition,
            .when_true = try builder.pure(try builder.reference(outer)),
            .when_false = call,
        } }));
    }
    try builder.define(main, try builder.term(.{ .call = .{
        .function = left,
        .arguments = &.{try builder.constant(u64, 3)},
    } }));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const facts = try check.analyze(arena.allocator(), builder.module(main, unit));
    try testing.expectEqualSlices(p.Id, &.{outer}, facts.functions[@intCast(left)].items);
    try testing.expectEqualSlices(p.Id, &.{outer}, facts.functions[@intCast(right)].items);
    try testing.expectEqual(0, facts.functions[@intCast(main)].items.len);
}

test "both conditional arms write the same stable join slot" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const boolean = try builder.scalar(bool);
    const unit = try builder.scalar(void);
    const main = try builder.declare(&.{boolean}, integer, &.{}, &.{});
    const binding = try builder.variable(integer);
    const left = try builder.pure(try builder.constant(u64, 17));
    const right = try builder.pure(try builder.constant(u64, 31));
    const branch = try builder.term(.{ .conditional = .{
        .condition = try builder.reference(builder.parameter(main, 0)),
        .when_true = left,
        .when_false = right,
    } });
    try builder.define(
        main,
        try builder.bind(binding, branch, try builder.pure(try builder.reference(binding))),
    );
    var compiled = try lower(testing.allocator, builder.module(main, unit));
    defer compiled.deinit();
    const image = compiled.program;
    try data.activation_structure.validate(testing.allocator, image);

    const root = image.blocks[@intCast(image.functions[@intCast(main)].entry)];
    const conditional = root.terminator.branch;
    const a = image.blocks[@intCast(conditional.when_true.block)];
    const b = image.blocks[@intCast(conditional.when_false.block)];
    try testing.expectEqual(a.terminator.jump.block, b.terminator.jump.block);
    try testing.expectEqual(
        a.terminator.jump.assignments[0].destination,
        b.terminator.jump.assignments[0].destination,
    );
    const joined = image.blocks[@intCast(a.terminator.jump.block)];
    try testing.expectEqual(
        joined.terminator.return_value,
        a.terminator.jump.assignments[0].destination,
    );
    try testing.expect(a.terminator.jump.assignments[0].source.slot !=
        b.terminator.jump.assignments[0].source.slot);
}

test "reused lexical name has distinct stable bindings" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    const name = try builder.variable(integer);
    const value = try builder.reference(name);
    const inner = try builder.bind(
        name,
        try builder.pure(try builder.constant(u64, 2)),
        try builder.pure(value),
    );
    try builder.define(
        main,
        try builder.bind(name, try builder.pure(try builder.constant(u64, 1)), inner),
    );
    var compiled = try lower(testing.allocator, builder.module(main, unit));
    defer compiled.deinit();
    const image = compiled.program;
    try data.activation_structure.validate(testing.allocator, image);

    var destinations: [2]p.Id = undefined;
    var count: usize = 0;
    var result: ?p.Id = null;
    for (image.blocks) |block| {
        for (block.instructions) |instruction| if (instruction.opcode == .constant) {
            try testing.expect(count < destinations.len);
            destinations[count] = instruction.destination;
            count += 1;
        };
        switch (block.terminator) {
            .jump => {},
            .return_value => |slot| result = slot,
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(2, count);
    try testing.expect(destinations[0] != destinations[1]);
    try testing.expectEqual(destinations[1], result.?);
}

fn ownedConstruction(allocator: std.mem.Allocator) !void {
    var builder = source.Builder.init(allocator);
    var alive = true;
    defer if (alive) builder.deinit();
    const input = try source.examples.installations(&builder, 2);
    var compiled = try lower(allocator, input);
    defer compiled.deinit();
    builder.deinit();
    alive = false;
    try testing.expectEqualStrings("economy/read", compiled.program.effects[0].identity);
    const entry = compiled.program.functions[@intCast(compiled.program.roots.entry)];
    try testing.expectEqual(9, entry.layout.slots.len);
}

test "construction owns source data and releases every partial allocation" {
    try @import("../allocation_testing.zig").check(testing.allocator, ownedConstruction, .{});
}

test "stable lowering shares pure DAG expressions without enumerating their tree" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const unit = try builder.scalar(void);
    const failure = try builder.failureLiteral(try builder.constant(void, {}));
    var value = try builder.constant(u64, 1);
    for (0..32) |_| value = try builder.value(.{
        .schema = integer,
        .expression = .{ .primitive = .{
            .opcode = .integer_add,
            .operands = &.{ value, value },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = failure }},
        } },
    });
    const main = try builder.declare(&.{}, integer, &.{}, &.{});
    try builder.define(main, try builder.pure(value));
    var compiled = try lower(testing.allocator, builder.module(main, unit));
    defer compiled.deinit();
    try testing.expectEqual(1, compiled.program.blocks.len);
    try testing.expectEqual(33, compiled.program.blocks[0].instructions.len);
    try testing.expectEqual(33, compiled.program.functions[0].layout.slots.len);
}

test "stable lowering distinguishes the successor handler answer from the resumption answer" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.successorState(&builder));
    defer compiled.deinit();
    var image = compiled.program;
    try data.activation_structure.validate(testing.allocator, image);

    const blocks = try testing.allocator.dupe(ir.Block, image.blocks);
    defer testing.allocator.free(blocks);
    image.blocks = blocks;
    for (blocks) |*block| {
        if (block.terminator != .resume_with) continue;
        const operation = block.terminator.resume_with;
        const layout = image.functions[@intCast(block.function)].layout.slots;
        const schema = layout[@intCast(operation.resumption)];
        const signature = image.schemas[@intCast(schema)].internal.resumption;
        const handler = image.handlers[@intCast(operation.handler)];
        if (signature.answer == handler.answer) continue;
        try testing.expectEqual(signature.answer, layout[@intCast(operation.argument)]);
        const assignments = [_]ir.Assignment{.{
            .destination = operation.argument,
            .source = .returned,
        }};
        block.terminator.resume_with.next.assignments = &assignments;
        try testing.expectError(
            error.TypeMismatch,
            data.activation_structure.validate(testing.allocator, image),
        );
        return;
    }
    return error.TestUnexpectedResult;
}

test "generalized-effect staged examples round-trip directly through BPI3 admission" {
    inline for (.{
        "lexical",
        "deep",
        "recursive",
        "choicesAll",
        "choicesFirst",
        "generator",
        "stateLocal",
        "stateShared",
        "ownership",
        "answers",
        "retainedScope",
        "scopedReader",
        "writerRaise",
        "schedulerFifo",
        "yieldingCleanup",
        "borrowOperands",
        "resourceScalar",
        "resourcePair",
        "boundedValues",
        "queensDfs",
        "queensBfs",
        "nested",
        "shallow",
        "injection",
        "indexed",
        "abortCustody",
        "unwind",
        "reentrant",
        "cloned",
        "shallowResumptions",
        "shallowInjection",
        "handleOperandOrder",
        "protectOperandOrder",
        "successorState",
        "clausePayload",
        "clauseAbort",
        "blobCapture",
        "scalarContracts",
    }) |name| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try lower(testing.allocator, try @field(source.examples, name)(&builder));
        defer compiled.deinit();
        try data.activation_structure.validate(testing.allocator, compiled.program);

        try testing.expect(compiled.program.blocks.len != 0);
        const bytes = try testing.allocator.alloc(
            u8,
            try data.program_image.encodedLength(compiled.program),
        );
        defer testing.allocator.free(bytes);
        _ = try compiled.encode(testing.allocator, bytes);
        var decoded = try data.program_image.decode(testing.allocator, bytes);
        defer decoded.deinit();
        try testing.expectEqualDeep(compiled.program, decoded.program);
        try testing.expectEqual(
            try data.program_image.identity(testing.allocator, compiled.program),
            decoded.identity,
        );
    }
}

test "complete BPI3 installation images stay within the fixed BPC1 anchors" {
    for ([_]usize{ 64, 128, 256 }, [_]usize{ 2805, 5574, 12102 }) |count, baseline| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        var compiled = try source.lower(
            testing.allocator,
            try source.examples.installations(&builder, count),
        );
        defer compiled.deinit();
        const length = try data.program_image.encodedLength(compiled.program);
        if (length > baseline) std.debug.print(
            "BPI3 installations {d}: {d} > {d}\n",
            .{ count, length, baseline },
        );
        try testing.expect(length <= baseline);
        const bytes = try testing.allocator.alloc(u8, length);
        defer testing.allocator.free(bytes);
        _ = try compiled.encode(testing.allocator, bytes);
        var decoded = try data.program_image.decode(testing.allocator, bytes);
        defer decoded.deinit();
        try testing.expectEqualDeep(compiled.program, decoded.program);
    }
}
test "stable construction observations preserve bytes and report source failures" {
    {
        const Trace = struct {
            stages: [7]source.CompileStage = undefined,
            count: usize = 0,
            fn enter(context: *anyopaque, stage: source.CompileStage) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.stages[self.count] = stage;
                self.count += 1;
            }
        };
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try source.examples.installations(&builder, 2);
        var plain = try source.lowerObserved(testing.allocator, module, .{});
        defer plain.deinit();
        var trace: Trace = .{};
        var diagnostic: source.Diagnostic = .{};
        var observed = try source.lowerObserved(testing.allocator, module, .{
            .diagnostic = &diagnostic,
            .observer = .{ .context = &trace, .enter = Trace.enter },
        });
        defer observed.deinit();
        try testing.expectEqualSlices(
            source.CompileStage,
            &.{
                .source_check,
                .lowering,
                .target_check,
                .direct_optimization,
                .coalescing,
                .complete,
            },
            trace.stages[0..trace.count],
        );
        try testing.expectEqual(@as(?anyerror, null), diagnostic.code);
        try testing.expectEqual(
            try data.program_image.identity(testing.allocator, plain.program),
            try data.program_image.identity(testing.allocator, observed.program),
        );
        builder.functions.items[@intCast(module.entry)].body = null;
        trace.count = 0;
        try testing.expectError(
            error.UndefinedFunction,
            source.lowerObserved(
                testing.allocator,
                builder.module(module.entry, module.failure),
                .{
                    .diagnostic = &diagnostic,
                    .observer = .{ .context = &trace, .enter = Trace.enter },
                },
            ),
        );
        try testing.expectEqual(error.UndefinedFunction, diagnostic.code.?);
        try testing.expectEqual(source.CompileStage.source_check, diagnostic.phase);
        try testing.expectEqual(@as(?data.program.Id, module.entry), diagnostic.function);
    }
}

test "closed compiler rejects invalid unused source before catalogue pruning" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    const integer = try builder.scalar(u64);
    const entry = try builder.declare(&.{}, integer, &.{}, &.{});
    const unused = try builder.declare(&.{}, integer, &.{}, &.{});
    try builder.define(entry, try builder.pure(try builder.constant(u64, 42)));
    try builder.define(unused, try builder.pure(try builder.constant(bool, true)));
    try testing.expectError(
        error.TypeMismatch,
        lower(testing.allocator, builder.module(entry, try builder.scalar(void))),
    );
}

test "local product projection retains mutable reads and unselected faults" {
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var compiled = try lower(testing.allocator, try source.examples.productProjection(&builder));
    defer compiled.deinit();
    var reads: usize = 0;
    var writes: usize = 0;
    var products: usize = 0;
    var arithmetic: usize = 0;
    for (compiled.program.blocks) |block| {
        for (block.instructions) |instruction| switch (instruction.opcode) {
            .field => return error.TestUnexpectedResult,
            .cell_get => reads += 1,
            .cell_set => writes += 1,
            .product => products += 1,
            .integer_add => {
                arithmetic += 1;
                try testing.expectEqual(1, instruction.failures.len);
                try testing.expectEqual(p.Fault.arithmetic_overflow, instruction.failures[0].kind);
            },
            else => {},
        };
    }
    try testing.expectEqual(3, reads);
    try testing.expectEqual(1, writes);
    try testing.expectEqual(2, products);
    try testing.expectEqual(2, arithmetic);
}

test "projection forwarding cannot erase malformed source operations" {
    for (0..5) |mode| {
        var b = source.Builder.init(testing.allocator);
        defer b.deinit();
        const integer = try b.scalar(u64);
        const boolean = try b.scalar(bool);
        const unit = try b.scalar(void);
        const pair = try b.schema(.{ .product = &.{ integer, integer } });
        const aggregate = try b.primitive(
            if (mode == 4) boolean else pair,
            .product,
            &.{ try b.constant(u64, 11), try b.constant(u64, 22) },
            0,
        );
        const selected = try b.value(
            .{
                .schema = if (mode == 1) boolean else integer,
                .expression = .{
                    .primitive = .{
                        .opcode = .field,
                        .operands = if (mode == 2) &.{} else &.{aggregate},
                        .immediate = if (mode == 0) ~@as(p.Id, 0) else 0,
                        .failures = if (mode == 3) &.{.{
                            .kind = .arithmetic_overflow,
                            .value = try b.failureLiteral(try b.constant(void, {})),
                        }} else &.{},
                    },
                },
            },
        );
        const entry = try b.declare(&.{}, if (mode == 1) boolean else integer, &.{}, &.{});
        try b.define(entry, try b.pure(selected));
        if (lower(testing.allocator, b.module(entry, unit))) |result| {
            var accepted = result;
            accepted.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

fn repeatedCellReadModule(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const integer = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ integer, integer } });
    const region_id = b.region();
    const region = try b.schema(.{ .internal = .{ .region = region_id } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{
        .element = integer,
        .region = region_id,
    } } });
    const inside = try b.declare(&.{region}, pair, &.{}, &.{region_id});
    const target = try b.variable(cell);
    const first = try b.variable(integer);
    const ignored = try b.variable(unit);
    const second = try b.variable(integer);
    const read = try b.primitive(integer, .cell_get, &.{try b.reference(target)}, 0);
    const write = try b.primitive(
        unit,
        .cell_set,
        &.{ try b.reference(target), try b.constant(u64, 7) },
        0,
    );
    const answer = try b.pure(try b.primitive(
        pair,
        .product,
        &.{ try b.reference(first), try b.reference(second) },
        0,
    ));
    const body = try b.bind(
        first,
        try b.pure(read),
        try b.bind(ignored, try b.pure(write), try b.bind(second, try b.pure(read), answer)),
    );
    try b.define(
        inside,
        try b.bind(
            target,
            try b.pure(try b.primitive(
                cell,
                .cell_new,
                &.{ try b.reference(b.parameter(inside, 0)), try b.constant(u64, 1) },
                0,
            )),
            body,
        ),
    );
    const main = try b.declare(&.{}, pair, &.{}, &.{});
    const signature = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{region},
        .result = pair,
        .regions = &.{region_id},
    } } });
    try b.define(
        main,
        try b.term(.{ .with_region = .{
            .region = region_id,
            .body = try b.lambda(inside, signature),
        } }),
    );
    return b.module(main, unit);
}

test "copy-binding fusion preserves repeated mutable reads across a write" {
    var b = source.Builder.init(testing.allocator);
    defer b.deinit();
    const module = try repeatedCellReadModule(&b);
    var compiled = try lower(testing.allocator, module);
    defer compiled.deinit();
    var matched = false;
    for (compiled.program.blocks) |block| {
        var index: usize = 0;
        const expected = [_]p.Opcode{ .cell_get, .cell_set, .cell_get };
        for (block.instructions) |instruction| {
            if (instruction.opcode != .cell_get and instruction.opcode != .cell_set) continue;
            try testing.expect(index < expected.len);
            try testing.expectEqual(expected[index], instruction.opcode);
            index += 1;
        }
        if (index != 0) {
            try testing.expectEqual(expected.len, index);
            matched = true;
        }
    }
    try testing.expect(matched);
}

test "optional capture explanations preserve images and retain mapped presentation" {
    const Own = data.activation_ownership;
    const Observer = struct {
        count: usize = 0,
        mapped: bool = false,
        unavailable: bool = false,
        retained: ?Own.CaptureExplanation = null,
        fn capture(_: *anyopaque, _: *const Own.CaptureSite, _: p.Id) void {}
        fn closure(_: *anyopaque, _: p.Id, _: p.Id) void {}
        fn explain(
            context: *anyopaque,
            _: *const Own.CaptureSite,
            _: p.Id,
            value: ?Own.CaptureExplanation,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const present = value orelse {
                self.unavailable = true;
                return;
            };
            self.count += 1;
            for (present.reasons) |reason|
                self.mapped = self.mapped or
                    reason.location.source_variable != null;
            if (self.retained) |old| old.deinit(testing.allocator);
            self.retained = null;
            self.retained = present.copy(testing.allocator) catch {
                self.unavailable = true;
                return;
            };
        }
    };
    inline for (.{
        "deep",
        "generator",
        "recursive",
        "injection",
        "yieldingCleanup",
        "statefulService",
    }) |name| {
        var observer: Observer = .{};
        defer if (observer.retained) |retained| retained.deinit(testing.allocator);
        {
            var builder = source.Builder.init(testing.allocator);
            defer builder.deinit();
            const module = try @field(source.examples, name)(&builder);
            var plain = try source.lowerObserved(testing.allocator, module, .{});
            defer plain.deinit();
            var observed = try source.lowerObserved(
                testing.allocator,
                module,
                .{ .captures = .{
                    .context = &observer,
                    .capture = Observer.capture,
                    .closure = Observer.closure,
                    .explanation = Observer.explain,
                } },
            );
            defer observed.deinit();
            try testing.expectEqual(
                try data.program_image.identity(testing.allocator, plain.program),
                try data.program_image.identity(testing.allocator, observed.program),
            );
            if (observer.unavailable) std.debug.print("explanation unavailable for {s}\n", .{name});
            try testing.expect(!observer.unavailable);
        }
        if (observer.retained) |retained| {
            try testing.expect(observer.count != 0);
            for (retained.reasons) |reason| for (reason.inputs) |input| try testing.expect(
                input < retained.reasons.len,
            );
        }
        if (observer.count != 0) try testing.expect(observer.mapped);
        if (comptime std.mem.eql(
            u8,
            name,
            "statefulService",
        )) try testing.expect(observer.count != 0);
    }
}

test "service interaction observation checks actual construction and labeled replies" {
    const Report = data.closed_compilation.ServiceObservation.Report;
    const Observer = struct {
        calls: usize = 0,
        expected: @TypeOf(@as(Report, .{}).ordered),
        failed: bool = false,
        fn enter(_: *anyopaque, _: data.closed_compilation.Stage) void {}
        fn receive(context: *anyopaque, report_: ?Report) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const report = report_ orelse {
                self.failed = true;
                return;
            };
            if (report.ordered != self.expected or
                report.waits == null or
                report.waits.?.status != .scoped_acyclic)
            {
                std.debug.print("service report: {any}\n", .{report.ordered});
                self.failed = true;
                return;
            }
            var incomplete = report.waits.?;
            incomplete.edges = incomplete.edges[1..];
            self.failed = self.failed or report.waitCoverage(incomplete);
            var bad_ranks: [7]usize = @splat(0);
            incomplete = report.waits.?;
            incomplete.ranks = &bad_ranks;
            self.failed = self.failed or report.ranksValid(incomplete);
            self.failed = self.failed or !report.waitCoverage(
                report.waits.?,
            ) or !report.ranksValid(report.waits.?);
            self.failed = self.failed or
                report.external_completion != .unresolved or
                report.scheduler_fairness != .explicit_runtime_premise or
                report.end_to_end !=
                    .conditional_on_finite_batch_fairness_external_completion_and_resources;
            const event: Report.TraceEvent = if (self.expected == .established)
                .matching_reply
            else
                .mismatched_reply;
            const trace = [_]Report.TraceEvent{
                .command,
                .suspended,
                event,
                .command,
                .suspended,
                event,
                .command,
                .finalize,
            };
            self.failed = self.failed or !(report.contains(testing.allocator, &trace) catch false);
            self.failed = self.failed or (report.contains(
                testing.allocator,
                &.{ .command, event },
            ) catch true);
            self.failed = self.failed or !(report.contains(
                testing.allocator,
                &.{ .command, .suspended, .finalize },
            ) catch false);
        }
    };
    inline for (.{ false, true }) |swapped| {
        var builder = source.Builder.init(testing.allocator);
        defer builder.deinit();
        const module = try (if (swapped)
            source.examples.swappedServiceReplies
        else
            source.examples.statefulService)(
            &builder,
        );
        var observer: Observer = .{ .expected = if (swapped) .potential else .established };
        var plain = try source.lower(testing.allocator, module);
        defer plain.deinit();
        var observed = try source.lowerObserved(
            testing.allocator,
            module,
            .{ .compilation_observer = .{
                .context = &observer,
                .enter = Observer.enter,
                .service = .{
                    .contract = .{
                        .command = "example/service-command",
                        .reply = "example/service-reply",
                        .finalizer = "example/service-finalize",
                    },
                    .receive = Observer.receive,
                },
            } },
        );
        defer observed.deinit();
        try testing.expectEqual(@as(usize, 1), observer.calls);
        try testing.expect(!observer.failed);
        try testing.expectEqual(
            try data.program_image.identity(testing.allocator, plain.program),
            try data.program_image.identity(testing.allocator, observed.program),
        );
    }
}

test "changed service code cannot retain prior interaction or wait conclusions" {
    const Report = data.closed_compilation.ServiceObservation.Report;
    const Observer = struct {
        received: bool = false,
        unresolved: bool = false,
        fn enter(_: *anyopaque, _: data.closed_compilation.Stage) void {}
        fn receive(raw: *anyopaque, value: ?Report) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.received = true;
            if (value) |report|
                self.unresolved = report.ordered == .unresolved and
                    report.waits == null and
                    report.end_to_end == .no_claim;
        }
    };
    var builder = source.Builder.init(testing.allocator);
    defer builder.deinit();
    var original = try source.lower(
        testing.allocator,
        try source.examples.statefulService(&builder),
    );
    defer original.deinit();
    for ([_]bool{ false, true }) |overwrite| {
        const blocks = try testing.allocator.dupe(ir.Block, original.program.blocks);
        defer testing.allocator.free(blocks);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var changed = false;
        for (blocks) |*block| for (
            block.instructions,
            0..,
        ) |instruction, index| if (instruction.opcode == .integer_add) {
            const operations = try arena.allocator().dupe(ir.Instruction, block.instructions);
            if (overwrite) {
                // Keep the same checked operations and final state, but overwrite
                // the request id with the sum before constructing its reply.
                const request_id = operations[0].destination;
                operations[index].destination = request_id;
                operations[index + 1].operands = try arena.allocator().dupe(
                    p.Id,
                    &.{ operations[index + 1].operands[0], request_id },
                );
            } else operations[index].opcode = .integer_sub;
            block.instructions = operations;
            changed = true;
        };
        try testing.expect(changed);
        var candidate = original.program;
        candidate.blocks = blocks;
        var admitted = try data.activation_ownership.analyze(testing.allocator, candidate);
        admitted.deinit();
        var observer: Observer = .{};
        var compiled = try data.closed_compilation.run(
            testing.allocator,
            candidate,
            .{ .observer = .{
                .context = &observer,
                .enter = Observer.enter,
                .service = .{
                    .contract = .{
                        .command = "example/service-command",
                        .reply = "example/service-reply",
                        .finalizer = "example/service-finalize",
                    },
                    .receive = Observer.receive,
                },
            } },
        );
        defer compiled.deinit();
        try testing.expect(observer.received and observer.unresolved);
    }
}
