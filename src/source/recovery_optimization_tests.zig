const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const optimization = source.recovery_optimization;
const ir = data.activation;
const a = std.testing.allocator;

fn diamond(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const f = try b.declare(&.{ boolean, pair, word, word }, word, &.{}, &.{});
    const condition = try b.reference(b.parameter(f, 0));
    const aggregate = try b.reference(b.parameter(f, 1));
    const left = try b.reference(b.parameter(f, 2));
    const right = try b.reference(b.parameter(f, 3));
    const first = try b.variable(word);
    const first_value = try b.reference(first);
    const selected = try b.variable(word);
    const when_true = try b.primitive(word, .integer_bit_and, &.{ first_value, left }, 0);
    const when_false = try b.primitive(word, .integer_bit_or, &.{ first_value, right }, 0);
    const branch = try b.term(.{ .conditional = .{
        .condition = condition,
        .when_true = try b.pure(when_true),
        .when_false = try b.pure(when_false),
    } });
    const later = try b.primitive(word, .field, &.{aggregate}, 1);
    const merged = try b.reference(selected);
    const result = try b.primitive(word, .integer_bit_xor, &.{ merged, later }, 0);
    const first_projection = try b.primitive(word, .field, &.{aggregate}, 1);
    try b.define(f, try b.bind(
        first,
        try b.pure(first_projection),
        try b.bind(selected, branch, try b.pure(result)),
    ));
    return b.module(f, unit);
}

fn options() optimization.Options {
    return .{
        .rule = .scalar_field_reuse_v1,
        .limits = .{},
        .formals = &.{.{ .function = 0, .ordinal = 0 }},
    };
}

const Value = union(enum) { word: u64, pair: [2]u64 };
const Observation = struct { value: u64 = 0, fields: usize = 0, moves: usize = 0 };

fn instructionValue(
    slots: []const Value,
    instruction: ir.Instruction,
    observation: *Observation,
) !Value {
    const operands = instruction.operands;
    const left = slots[operands[0]];
    switch (instruction.opcode) {
        .move => {
            observation.moves += 1;
            return left;
        },
        .field => {
            observation.fields += 1;
            return .{ .word = left.pair[instruction.immediate] };
        },
        .integer_bit_and => return .{ .word = left.word & slots[operands[1]].word },
        .integer_bit_or => return .{ .word = left.word | slots[operands[1]].word },
        .integer_bit_xor => return .{ .word = left.word ^ slots[operands[1]].word },
        else => return error.UnexpectedFixtureInstruction,
    }
}

const pair_input: [2]u64 = .{ 0x1155, 0xabc5 };
const left_input: u64 = 0xcf;
const right_input: u64 = 0x7810;

fn observe(program: ir.Program, condition: bool) !Observation {
    const function = program.functions[program.roots.entry];
    const slots = try a.alloc(Value, function.layout.slots.len);
    defer a.free(slots);
    const inputs = [_]Value{
        .{ .word = @intFromBool(condition) }, .{ .pair = pair_input },
        .{ .word = left_input },              .{ .word = right_input },
    };
    for (function.inputs, inputs) |slot, input| slots[slot] = input;
    var block_id = function.entry;
    var observation: Observation = .{};
    for (0..program.blocks.len) |_| {
        const block = program.blocks[block_id];
        for (block.instructions) |op| slots[op.destination] =
            try instructionValue(slots, op, &observation);
        const edge = switch (block.terminator) {
            .branch => |br| if (slots[br.condition].word == 1) br.when_true else br.when_false,
            .jump => |edge| edge,
            .return_value => |id| {
                observation.value = slots[id].word;
                return observation;
            },
            else => return error.UnexpectedFixtureControl,
        };
        try std.testing.expect(edge.assignments.len <= 1);
        for (edge.assignments) |assignment| slots[assignment.destination] =
            slots[assignment.source.slot];
        block_id = edge.block;
    }
    return error.FixtureDidNotReturn;
}

fn expectBindings(
    module: source.Module,
    program: ir.Program,
    bindings: []const source.RecoveryBinding,
) !void {
    const formals = module.functions[module.entry].parameters;
    const f = program.functions[program.roots.entry];
    try std.testing.expectEqual(formals.len, bindings.len);
    for (formals, f.inputs, bindings) |formal, slot, binding| {
        try std.testing.expectEqual(module.entry, binding.source_function);
        try std.testing.expectEqual(formal, binding.variable);
        try std.testing.expectEqual(module.variables[formal], binding.source_schema);
        try std.testing.expectEqual(program.roots.entry, binding.function);
        try std.testing.expectEqual(slot, binding.slot);
        try std.testing.expectEqual(f.layout.slots[slot], binding.schema);
    }
}

test "recovery field reuse preserves both diamond paths" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var structural = try source.lowerObserved(a, module, .{ .recovery = true });
    defer structural.deinit();
    var optimized = try source.lowerRecoveryOptimized(a, module, options());
    defer optimized.deinit();
    try std.testing.expectEqual(1, optimized.evidence.witnesses.len);
    const witness = optimized.evidence.witnesses[0];
    try std.testing.expect(witness.source.block != witness.target.block);
    const blocks = optimized.evidence.correspondence.maps[@backingInt(data.relocation.Kind.block)];
    const producer = optimized.program.blocks[blocks[witness.source.block]];
    const join = optimized.program.blocks[blocks[witness.target.block]];
    const projection = producer.instructions[witness.source.instruction];
    const replacement = join.instructions[witness.target.instruction];
    try std.testing.expectEqual(.field, projection.opcode);
    try std.testing.expectEqual(1, projection.immediate);
    try std.testing.expectEqual(.move, replacement.opcode);
    try std.testing.expectEqualSlices(u64, &.{projection.destination}, replacement.operands);
    const checked = try optimization.parameters(
        a,
        module,
        optimized.program,
        optimized.evidence,
        options(),
    );
    defer a.free(checked);
    try expectBindings(module, optimized.program, checked);
    try std.testing.expectEqualDeep(checked, optimized.parameters);
    try expectBindings(module, structural.program, structural.parameters);
    for ([_]bool{ false, true }) |condition| {
        const baseline = try observe(structural.program, condition);
        const candidate = try observe(optimized.program, condition);
        const expected = if (condition) pair_input[1] & left_input else pair_input[1] | right_input;
        try std.testing.expectEqual(expected ^ pair_input[1], baseline.value);
        try std.testing.expectEqual(baseline.value, candidate.value);
        try std.testing.expectEqual(2, baseline.fields);
        try std.testing.expectEqual(1, candidate.fields);
        try std.testing.expectEqual(baseline.moves + 1, candidate.moves);
    }
}

fn checkEvidence(
    module: source.Module,
    program: ir.Program,
    evidence: optimization.Evidence,
    policy: optimization.Options,
) !void {
    const bindings = try optimization.parameters(a, module, program, evidence, policy);
    defer a.free(bindings);
}

fn formalBinding(
    bindings: []const source.RecoveryBinding,
    function: source.Id,
) !source.RecoveryBinding {
    for (bindings) |binding| if (binding.source_function == function) return binding;
    return error.MissingFormal;
}

test "recovery field reuse retains protected coalesced aliases through an applied rewrite" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const repeated = (try diamond(&b)).entry;
    const fixture = try @import("recovery_tests.zig").coalescedBindingModule(&b, repeated);
    const module = fixture.module;
    var policy = options();
    policy.formals = &.{.{ .function = fixture.first, .ordinal = 0 }};
    var ordinary = try source.lowerObserved(a, module, .{ .recovery = true });
    defer ordinary.deinit();
    const first = try formalBinding(ordinary.parameters, fixture.first);
    const second = try formalBinding(ordinary.parameters, fixture.second);
    try std.testing.expectEqual(first.function, second.function);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.variable != second.variable);
    var optimized = try source.lowerRecoveryOptimized(a, module, policy);
    defer optimized.deinit();
    try std.testing.expectEqual(.applied, optimized.outcome);
    try std.testing.expectEqual(1, optimized.evidence.witnesses.len);
    const w = optimized.evidence.witnesses[0];
    const maps = optimized.evidence.correspondence.maps;
    const functions = maps[@backingInt(data.relocation.Kind.function)];
    const blocks = maps[@backingInt(data.relocation.Kind.block)];
    const target = optimized.program.blocks[blocks[w.target.block]];
    try std.testing.expectEqual(functions[repeated], target.function);
    try std.testing.expectEqual(.move, target.instructions[w.target.instruction].opcode);
    const verified = try optimization.parameters(
        a,
        module,
        optimized.program,
        optimized.evidence,
        policy,
    );
    defer a.free(verified);
    try std.testing.expectEqualDeep(optimized.parameters, verified);
    const lhs = try formalBinding(verified, fixture.first);
    const rhs = try formalBinding(verified, fixture.second);
    try std.testing.expectEqual(first.variable, lhs.variable);
    try std.testing.expectEqual(second.variable, rhs.variable);
    try std.testing.expectEqual(lhs.function, rhs.function);
    try std.testing.expectEqual(lhs.slot, rhs.slot);
}

test "exhausted candidate P01 cannot split ordinary protected frame aliases" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const repeated = (try diamond(&b)).entry;
    const fixture = try @import("recovery_tests.zig").coalescedBindingModule(&b, repeated);
    const module = fixture.module;
    var policy = options();
    policy.formals = &.{.{ .function = fixture.first, .ordinal = 0 }};
    policy.limits.p01_work = 0;
    var ordinary = try source.lowerObserved(a, module, .{ .recovery = true });
    defer ordinary.deinit();
    var retained = try source.lowerRecoveryOptimized(a, module, policy);
    defer retained.deinit();
    try std.testing.expectEqual(.budget, retained.outcome);
    try expectStructuralFallback(module, policy, &ordinary, &retained);
    var unmerged = try source.lowerObserved(a, module, .{
        .recovery = true,
        .coalescing = .{ .work_limit = 0 },
    });
    defer unmerged.deinit();
    const lhs = try formalBinding(unmerged.parameters, fixture.first);
    const rhs = try formalBinding(unmerged.parameters, fixture.second);
    try std.testing.expect(lhs.function != rhs.function);
    var forged = retained.evidence;
    forged.correspondence = unmerged.recovery_evidence.?.correspondence;
    try std.testing.expectError(
        error.InvalidCorrespondence,
        checkEvidence(module, unmerged.program, forged, policy),
    );
}

test "no eligible field retains ordinary protected aliases" {
    var b = source.Builder.init(a);
    defer b.deinit();
    _ = try diamond(&b);
    const fixture = try @import("recovery_tests.zig").coalescedBindingModule(&b, null);
    var policy = options();
    policy.formals = &.{.{ .function = fixture.first, .ordinal = 0 }};
    var ordinary = try source.lowerObserved(a, fixture.module, .{ .recovery = true });
    defer ordinary.deinit();
    var retained = try source.lowerRecoveryOptimized(a, fixture.module, policy);
    defer retained.deinit();
    try std.testing.expectEqual(.no_sites, retained.outcome);
    try expectStructuralFallback(fixture.module, policy, &ordinary, &retained);
}

fn twoReachableDiamonds(b: *source.Builder, first: u64, second: u64) !source.Module {
    const word = try b.scalar(u64);
    const pair = try b.schema(.{ .product = &.{ word, word } });
    const entry = try b.declare(&.{ try b.scalar(bool), pair, word, word }, word, &.{}, &.{});
    var arguments: [4]u64 = undefined;
    for (&arguments, 0..) |*argument, i| argument.* = try b.reference(b.parameter(entry, i));
    const left = try b.variable(word);
    const right = try b.variable(word);
    const lhs = try b.term(.{ .call = .{ .function = first, .arguments = &arguments } });
    const rhs = try b.term(.{ .call = .{ .function = second, .arguments = &arguments } });
    const result = try b.primitive(
        word,
        .integer_bit_xor,
        &.{ try b.reference(left), try b.reference(right) },
        0,
    );
    try b.define(entry, try b.bind(left, lhs, try b.bind(right, rhs, try b.pure(result))));
    return b.module(entry, try b.scalar(void));
}

fn projectionWitness(program: ir.Program, function: u64) !data.scalar_field_reuse.Witness {
    const Location = data.scalar_field_reuse.Location;
    var early: ?Location = null;
    var late: ?Location = null;
    const entry = program.functions[function].entry;
    for (program.blocks, 0..) |block, block_id| {
        if (block.function != function) continue;
        for (block.instructions, 0..) |op, i| {
            if (op.opcode != .field) continue;
            const at: Location = .{ .block = block_id, .instruction = i };
            if (block_id == entry) early = at else late = at;
        }
    }
    return .{
        .source = early orelse return error.MissingProjection,
        .target = late orelse return error.MissingProjection,
    };
}

const CanonicalMap = struct {
    arena: std.mem.Allocator,
    work: *u64,
    map: ?data.coalescing.Correspondence = null,

    fn receive(
        ptr: *anyopaque,
        trace: *const data.coalescing.OriginsTrace,
    ) data.coalescing.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.map = try data.coalescing.Correspondence.copyCanonical(self.arena, trace, self.work);
    }
};

test "candidate P01 selection and independent checking share a single work allowance" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var policy = options();
    var input = try @import("activation_lower.zig").lowerRecoveryInput(a, module);
    defer input.deinit();
    var ordinary = try source.lowerObserved(a, module, .{ .recovery = true });
    defer ordinary.deinit();
    const w = try projectionWitness(input.program, module.entry);
    const rule = data.scalar_field_reuse;
    var budget = rule.Budget.init(.{});
    const s = try rule.reconstructBorrowedProposal(b.allocator(), input.program, &.{w}, &budget);
    const full = policy.limits.p01_work;
    var work = full;
    var capture: CanonicalMap = .{ .arena = b.allocator(), .work = &work };
    var selected = try data.coalescing.runWithWork(a, s, .{
        .correspondence = .{ .context = &capture, .receive = CanonicalMap.receive },
    }, &work);
    defer selected.deinit();
    const selection_work = full - work;
    var flow = try data.coalescing.correspondenceFlow(a, s, selected.program, capture.map.?, &work);
    defer flow.deinit();
    const total = full - work;
    try std.testing.expect(selection_work > 0 and selection_work < total);
    policy.limits.p01_work = total;
    var exact = try source.lowerRecoveryOptimized(a, module, policy);
    defer exact.deinit();
    try std.testing.expectEqual(.applied, exact.outcome);
    try std.testing.expectEqualDeep(selected.program, exact.program);
    try std.testing.expectEqualDeep(capture.map.?, exact.evidence.correspondence);
    policy.limits.p01_work = total - selection_work;
    try checkEvidence(module, exact.program, exact.evidence, policy);
    policy.limits.p01_work = total - 1;
    var retained = try source.lowerRecoveryOptimized(a, module, policy);
    defer retained.deinit();
    try std.testing.expectEqual(.budget, retained.outcome);
    try expectStructuralFallback(module, policy, &ordinary, &retained);
}

test "only surviving field replacements consume the witness allowance" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const dead = (try diamond(&b)).entry;
    const live = (try diamond(&b)).entry;
    const both = try twoReachableDiamonds(&b, dead, live);
    var module = both;
    module.entry = live;
    var policy = options();
    policy.limits.rule.witnesses = 1;
    policy.formals = &.{};
    var original = try @import("activation_lower.zig").lowerRecoveryInput(a, module);
    defer original.deinit();
    const wasted = try projectionWitness(original.program, dead);
    const demanded = try projectionWitness(original.program, live);
    var result = try source.lowerRecoveryOptimized(a, module, policy);
    defer result.deinit();
    try std.testing.expectEqual(.applied, result.outcome);
    try std.testing.expectEqual(1, result.evidence.witnesses.len);
    try std.testing.expectEqualDeep(demanded, result.evidence.witnesses[0]);
    const maps = result.evidence.correspondence.maps[@backingInt(data.relocation.Kind.block)];
    try std.testing.expectEqual(data.relocation.missing, maps[wasted.target.block]);
    const emitted = result.program.blocks[maps[demanded.target.block]];
    try std.testing.expectEqual(.move, emitted.instructions[demanded.target.instruction].opcode);
    try checkEvidence(module, result.program, result.evidence, policy);
    var extra = result.evidence;
    extra.witnesses = &.{ wasted, demanded };
    policy.limits.rule.witnesses = 2;
    try std.testing.expectError(
        error.InvalidCorrespondence,
        checkEvidence(module, result.program, extra, policy),
    );
    policy.limits.rule.witnesses = 1;
    var retained = try source.lowerRecoveryOptimized(a, both, policy);
    defer retained.deinit();
    try std.testing.expectEqual(.budget, retained.outcome);
    try std.testing.expectEqual(2, retained.statistics.budget);
    var ordinary = try source.lowerObserved(a, both, .{ .recovery = true });
    defer ordinary.deinit();
    try expectStructuralFallback(both, policy, &ordinary, &retained);
}

test "independent recovery validation enforces the actual encoded growth of a split function" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const first = (try diamond(&b)).entry;
    const second = (try diamond(&b)).entry;
    const module = try twoReachableDiamonds(&b, first, second);
    var original = try @import("activation_lower.zig").lowerRecoveryInput(a, module);
    defer original.deinit();
    const w = try projectionWitness(original.program, first);
    var policy = options();
    policy.formals = &.{};
    const rule = data.scalar_field_reuse;
    var budget = rule.Budget.init(.{});
    const modified = try rule.reconstructBorrowedProposal(
        b.allocator(),
        original.program,
        &.{w},
        &budget,
    );
    var work = policy.limits.p01_work;
    var capture: CanonicalMap = .{ .arena = b.allocator(), .work = &work };
    var final = try data.coalescing.runWithWork(a, modified, .{
        .correspondence = .{ .context = &capture, .receive = CanonicalMap.receive },
    }, &work);
    defer final.deinit();
    const evidence: optimization.Evidence = .{
        .rule = .scalar_field_reuse_v1,
        .witnesses = &.{w},
        .correspondence = capture.map.?,
    };
    var ordinary = try source.lowerObserved(a, module, .{ .recovery = true });
    defer ordinary.deinit();
    const before = try data.program_image.encodedLength(ordinary.program);
    const after = try data.program_image.encodedLength(final.program);
    try std.testing.expect(after > before);
    policy.limits.image_growth_bytes = after - before;
    try checkEvidence(module, final.program, evidence, policy);
    policy.limits.image_growth_bytes -= 1;
    try std.testing.expectError(
        error.ImageSizeLimit,
        checkEvidence(module, final.program, evidence, policy),
    );
}

test "recovery field reuse preserves required phase liveness" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var policy = options();
    var original = try source.lowerObserved(a, module, .{ .recovery = true });
    defer original.deinit();
    var accepted = try source.lowerRecoveryOptimized(a, module, policy);
    defer accepted.deinit();
    try std.testing.expectEqual(.applied, accepted.outcome);
    policy.formals = &.{.{ .function = module.entry, .ordinal = 1 }};
    try std.testing.expectError(
        error.RecoveryLiveness,
        checkEvidence(module, accepted.program, accepted.evidence, policy),
    );
    var retained = try source.lowerRecoveryOptimized(a, module, policy);
    defer retained.deinit();
    try std.testing.expectEqual(.recovery_liveness, retained.outcome);
    try std.testing.expectEqual(1, retained.statistics.recovery_liveness);
    try std.testing.expectEqual(0, retained.evidence.witnesses.len);
    try std.testing.expectEqualDeep(original.program, retained.program);
    try checkEvidence(module, retained.program, retained.evidence, policy);
}

test "a proven singleton liveness rejection survives a budget too small for a second check" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var policy = options();
    policy.formals = &.{.{ .function = module.entry, .ordinal = 1 }};
    var original = try @import("activation_lower.zig").lowerRecoveryInput(a, module);
    defer original.deinit();
    var ordinary = try source.lowerObserved(a, module, .{ .recovery = true });
    defer ordinary.deinit();
    const block_kind = @backingInt(data.relocation.Kind.block);
    const blocks = ordinary.recovery_evidence.?.correspondence.maps[block_kind];
    const rule = data.scalar_field_reuse;
    var budget = rule.Budget.init(.{});
    var statistics: rule.Statistics = .{};
    const found = try rule.discoverReachable(
        b.allocator(),
        original.program,
        blocks,
        &budget,
        &statistics,
    );
    try std.testing.expectEqual(1, found.len);
    const s = try rule.reconstructBorrowedProposal(b.allocator(), original.program, found, &budget);
    const before_check = budget.remaining;
    try rule.validate(a, original.program, s, found, &budget);
    const data_check_work = before_check - budget.remaining;
    try std.testing.expect(data_check_work > 0);
    policy.limits.rule.work = budget.workUsed() + data_check_work - 1;
    var retained = try source.lowerRecoveryOptimized(a, module, policy);
    defer retained.deinit();
    try std.testing.expectEqual(.recovery_liveness, retained.outcome);
    try std.testing.expectEqual(1, retained.statistics.recovery_liveness);
    try std.testing.expectEqual(0, retained.statistics.budget);
    try expectStructuralFallback(module, policy, &ordinary, &retained);
}

test "recovery evidence rejects same typed origin permutation" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var result = try source.lowerRecoveryOptimized(a, module, options());
    defer result.deinit();
    const w = result.evidence.witnesses[0];
    var evidence = result.evidence;
    evidence.witnesses = &.{.{ .source = w.target, .target = w.source }};
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        checkEvidence(module, result.program, evidence, options()),
    );
    const arena = b.allocator();
    const functions = try arena.dupe(source.ast.Function, module.functions);
    const parameters = try arena.dupe(u64, functions[module.entry].parameters);
    std.mem.swap(u64, &parameters[2], &parameters[3]);
    functions[module.entry].parameters = parameters;
    var permuted = module;
    permuted.functions = functions;
    try std.testing.expectError(
        error.InvalidCorrespondence,
        checkEvidence(permuted, result.program, result.evidence, options()),
    );
    const values = try arena.dupe(source.ast.Value, module.values);
    for (values) |*v| {
        if (v.expression != .primitive or v.expression.primitive.opcode != .field) continue;
        v.expression.primitive.immediate = 0;
        break;
    } else return error.MissingProjection;
    permuted = module;
    permuted.values = values;
    try std.testing.expectError(
        error.InvalidExpressionReuse,
        checkEvidence(permuted, result.program, result.evidence, options()),
    );
    evidence = result.evidence;
    const map = evidence.correspondence;
    const locals = try arena.dupe(@TypeOf(map.locals[0]), map.locals);
    const slots = try arena.dupe(u64, locals[module.entry].slots);
    var owned = try @import("activation_lower.zig").lowerRecoveryInput(a, module);
    defer owned.deinit();
    const inputs = owned.program.functions[module.entry].inputs;
    std.mem.swap(u64, &slots[inputs[2]], &slots[inputs[3]]);
    locals[module.entry].slots = slots;
    evidence.correspondence.locals = locals;
    try std.testing.expectError(
        error.InvalidCorrespondence,
        checkEvidence(module, result.program, evidence, options()),
    );
}

fn evidenceBytes(evidence: optimization.Evidence, output: []u8) ![]u8 {
    var writer: data.wire.Writer = .{ .output = output };
    try data.record.write(optimization.Evidence, evidence, &writer);
    return output[0..writer.position];
}

fn regionDiamond(b: *source.Builder) !source.Module {
    const field_function = (try diamond(b)).entry;
    const cell = @import("cell_order_example.zig");
    const first = (try cell.build(b)).entry;
    const second = (try cell.build(b)).entry;
    b.region_count = 1 << 40;
    const third = (try cell.build(b)).entry;
    const field = b.functions.items[field_function];
    var parameters: [4]u64 = undefined;
    for (&parameters, field.parameters) |*schema, id| schema.* = b.variables.items[id];
    const entry = try b.declare(&parameters, field.result, &.{}, &.{});
    var arguments: [4]u64 = undefined;
    for (&arguments, 0..) |*arg, i| arg.* = try b.reference(b.parameter(entry, i));
    var body = try b.term(.{ .call = .{ .function = field_function, .arguments = &arguments } });
    for ([_]u64{ first, second, third }) |callee| {
        const call = try b.term(.{ .call = .{ .function = callee, .arguments = &.{} } });
        body = try b.bind(try b.variable(b.functions.items[callee].result), call, body);
    }
    try b.define(entry, body);
    return b.module(entry, try b.scalar(void));
}

test "selected and fallback recovery evidence transport sparse regions in original ID order" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try regionDiamond(&b);
    var policy = options();
    for ([_]optimization.Outcome{ .applied, .budget }) |outcome| {
        if (outcome == .budget) policy.limits.rule.work = 0;
        var result = try source.lowerRecoveryOptimized(a, module, policy);
        defer result.deinit();
        try std.testing.expectEqual(outcome, result.outcome);
        const regions = result.evidence.correspondence.regions;
        try std.testing.expectEqual(3, regions.len);
        for (regions, [_]u64{ 0, 1, 1 << 40 }) |pair, original| {
            try std.testing.expectEqual(original, pair.original);
        }
        var storage: [8192]u8 = undefined;
        const bytes = try evidenceBytes(result.evidence, &storage);
        var decoded = try optimization.decode(a, bytes, policy.limits);
        defer decoded.deinit();
        const bindings = try optimization.parameters(
            a,
            module,
            result.program,
            decoded.evidence,
            policy,
        );
        defer a.free(bindings);
        try std.testing.expectEqualDeep(result.parameters, bindings);
    }
}

test "unknown recovery evidence rules precede payload and policy checks" {
    const defaults = options().limits;
    var tiny = defaults;
    tiny.evidence_bytes = 1;
    tiny.structural_evidence_bytes = 1;
    for ([_]optimization.Limits{ defaults, tiny }) |limits| {
        for ([_][]const u8{ &.{2}, &.{ 2, 0 }, &.{ 2, 0x80 } }) |unknown| {
            try std.testing.expectError(
                error.UnsupportedVersion,
                optimization.decode(a, unknown, limits),
            );
        }
    }
    try std.testing.expectError(error.Truncated, optimization.decode(a, &.{1}, defaults));
}

test "independent recovery validation distinguishes its scratch limit from allocator failure" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var policy = options();
    var selected = try source.lowerRecoveryOptimized(a, module, policy);
    defer selected.deinit();
    try std.testing.expectEqual(.applied, selected.outcome);
    for ([_]usize{ 0, 256, 512, 1024 }) |bytes| {
        policy.limits.rule.temporary_bytes = bytes;
        try std.testing.expectError(
            error.ScalarFieldLimit,
            checkEvidence(module, selected.program, selected.evidence, policy),
        );
    }
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        optimization.parameters(
            failing.allocator(),
            module,
            selected.program,
            selected.evidence,
            options(),
        ),
    );
}

fn expectStructuralFallback(
    module: source.Module,
    policy: optimization.Options,
    ordinary: *const source.Compiled,
    retained: *const optimization.Result,
) !void {
    try std.testing.expectEqual(.structural_fallback, retained.evidence.rule);
    try std.testing.expectEqual(0, retained.evidence.witnesses.len);
    try std.testing.expectEqualDeep(ordinary.program, retained.program);
    try std.testing.expectEqualDeep(ordinary.parameters, retained.parameters);
    try std.testing.expectEqualDeep(
        ordinary.recovery_evidence.?.correspondence,
        retained.evidence.correspondence,
    );
    var bytes: [2048]u8 = undefined;
    const encoded = try evidenceBytes(retained.evidence, &bytes);
    var decoded = try optimization.decode(a, encoded, policy.limits);
    defer decoded.deinit();
    const bindings = try optimization.parameters(
        a,
        module,
        retained.program,
        decoded.evidence,
        policy,
    );
    defer a.free(bindings);
    try std.testing.expectEqualDeep(ordinary.parameters, bindings);
}

test "encoded recovery evidence round trips at its exact wire limit" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var policy = options();
    var discovered = try source.lowerRecoveryOptimized(a, module, policy);
    defer discovered.deinit();
    try std.testing.expectEqual(.applied, discovered.outcome);
    var storage: [2048]u8 = undefined;
    policy.limits.evidence_bytes = (try evidenceBytes(discovered.evidence, &storage)).len;
    var fitting = try source.lowerRecoveryOptimized(a, module, policy);
    defer fitting.deinit();
    try std.testing.expectEqual(.applied, fitting.outcome);
    const bytes = try evidenceBytes(fitting.evidence, &storage);
    try std.testing.expectEqual(policy.limits.evidence_bytes, bytes.len);
    var checked = try optimization.decode(a, bytes, policy.limits);
    defer checked.deinit();
    try checkEvidence(module, fitting.program, checked.evidence, policy);
    policy.limits.evidence_bytes -= 1;
    var retained = try source.lowerRecoveryOptimized(a, module, policy);
    defer retained.deinit();
    try std.testing.expectEqual(.budget, retained.outcome);
    var ordinary = try source.lowerObserved(a, module, .{ .recovery = true });
    defer ordinary.deinit();
    try expectStructuralFallback(module, policy, &ordinary, &retained);
}

test "both recovery entry points bound the formal policy before inspecting its entries" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var policy = options();
    var selected = try source.lowerRecoveryOptimized(a, module, policy);
    defer selected.deinit();
    policy.formals = &.{
        .{ .function = module.entry, .ordinal = 0 },
        .{ .function = module.entry, .ordinal = 1 },
        .{ .function = module.functions.len, .ordinal = 0 },
    };
    for ([_]u64{ policy.formals.len - 1, policy.formals.len }) |work| {
        policy.limits.source_work = work;
        const reason = if (work < policy.formals.len)
            error.RelationLimit
        else
            error.InvalidCorrespondence;
        try std.testing.expectError(reason, source.lowerRecoveryOptimized(a, module, policy));
        try std.testing.expectError(
            reason,
            checkEvidence(module, selected.program, selected.evidence, policy),
        );
    }
}

test "the evidence rule determines admissible witness counts and fallback ceilings" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var policy = options();
    var selected = try source.lowerRecoveryOptimized(a, module, policy);
    defer selected.deinit();
    var wrong = selected.evidence;
    wrong.rule = .structural_fallback;
    var bytes: [2048]u8 = undefined;
    try std.testing.expectError(
        error.InvalidCorrespondence,
        optimization.decode(a, try evidenceBytes(wrong, &bytes), policy.limits),
    );
    try std.testing.expectError(
        error.InvalidCorrespondence,
        checkEvidence(module, selected.program, wrong, policy),
    );
    policy.limits.rule.work = 0;
    var retained = try source.lowerRecoveryOptimized(a, module, policy);
    defer retained.deinit();
    wrong = retained.evidence;
    wrong.rule = .scalar_field_reuse_v1;
    try std.testing.expectError(
        error.InvalidCorrespondence,
        optimization.decode(a, try evidenceBytes(wrong, &bytes), options().limits),
    );
    try std.testing.expectError(
        error.InvalidCorrespondence,
        checkEvidence(module, retained.program, wrong, options()),
    );
    const encoded = try evidenceBytes(retained.evidence, &bytes);
    policy.limits.structural_evidence_bytes = encoded.len - 1;
    try std.testing.expectError(
        error.ScalarFieldLimit,
        optimization.decode(a, encoded, policy.limits),
    );
    try std.testing.expectError(
        error.RelationLimit,
        source.lowerRecoveryOptimized(a, module, policy),
    );
    try std.testing.expectError(
        error.RelationLimit,
        checkEvidence(module, retained.program, retained.evidence, policy),
    );
}

fn decodeWithFailures(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var decoded = try optimization.decode(allocator, bytes, options().limits);
    defer decoded.deinit();
}

fn validateWithFailures(
    allocator: std.mem.Allocator,
    module: source.Module,
    candidate: *const optimization.Result,
) !void {
    const bindings = try optimization.parameters(
        allocator,
        module,
        candidate.program,
        candidate.evidence,
        options(),
    );
    defer allocator.free(bindings);
    try std.testing.expectEqualDeep(candidate.parameters, bindings);
}

test "recovery evidence is deterministic and releases partial decoding allocations" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var first = try source.lowerRecoveryOptimized(a, module, options());
    defer first.deinit();
    var second = try source.lowerRecoveryOptimized(a, module, options());
    defer second.deinit();
    var left: [2048]u8 = undefined;
    var right: [2048]u8 = undefined;
    const bytes = try evidenceBytes(first.evidence, &left);
    try std.testing.expectEqualSlices(u8, bytes, try evidenceBytes(second.evidence, &right));
    try std.testing.expectEqualDeep(first.program, second.program);
    try std.testing.expectEqualDeep(first.statistics, second.statistics);
    const allocations = @import("../allocation_testing.zig");
    try allocations.check(a, decodeWithFailures, .{bytes});
    try allocations.check(std.heap.smp_allocator, validateWithFailures, .{ module, &first });
}

test "recovery lowering policies retain their original meaning" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var baseline = try source.lowerObserved(a, module, .{ .recovery = true });
    defer baseline.deinit();
    try source.recovery.validate(a, module, &baseline);
    try std.testing.expectError(
        error.InvalidCorrespondence,
        source.lowerObserved(a, module, .{ .recovery = true, .contract = .semantic }),
    );
    var selected = try source.lowerRecoveryOptimized(a, module, options());
    defer selected.deinit();
    try std.testing.expectEqual(.applied, selected.outcome);
    try std.testing.expectError(
        error.InvalidCorrespondence,
        source.recovery.parameters(a, module, selected.program, baseline.recovery_evidence.?),
    );
    try std.testing.expectError(
        error.InvalidCorrespondence,
        checkEvidence(module, baseline.program, selected.evidence, options()),
    );
    var unknown = options();
    unknown.rule = .structural_fallback;
    try std.testing.expectError(
        error.UnsupportedVersion,
        source.lowerRecoveryOptimized(a, module, unknown),
    );
    unknown.rule = @fromBackingInt(@intCast(2));
    try std.testing.expectError(
        error.UnsupportedVersion,
        source.lowerRecoveryOptimized(a, module, unknown),
    );
    var forged = selected.evidence;
    forged.rule = unknown.rule;
    try std.testing.expectError(
        error.UnsupportedVersion,
        checkEvidence(module, selected.program, forged, options()),
    );
    var bytes: [2048]u8 = undefined;
    const encoded = try evidenceBytes(selected.evidence, &bytes);
    var decoded = try optimization.decode(a, encoded, options().limits);
    defer decoded.deinit();
    try checkEvidence(module, selected.program, decoded.evidence, options());
    try std.testing.expectEqualDeep(selected.evidence, decoded.evidence);
    const bad = try b.allocator().dupe(u8, encoded);
    bad[0] = 2;
    const limits = options().limits;
    try std.testing.expectError(error.UnsupportedVersion, optimization.decode(a, bad, limits));
    const truncated = encoded[0 .. encoded.len - 1];
    try std.testing.expectError(error.Truncated, optimization.decode(a, truncated, limits));
    bytes[encoded.len] = 0;
    const trailing = bytes[0 .. encoded.len + 1];
    try std.testing.expectError(error.NonCanonical, optimization.decode(a, trailing, limits));
    var limited = options().limits;
    limited.evidence_bytes = encoded.len - 1;
    try std.testing.expectError(error.ScalarFieldLimit, optimization.decode(a, encoded, limited));
    limited = options().limits;
    limited.rule.witnesses = 0;
    try std.testing.expectError(error.ScalarFieldLimit, optimization.decode(a, encoded, limited));
}

fn compileWithFailures(allocator: std.mem.Allocator, module: source.Module) !void {
    var compiled = try source.lowerRecoveryOptimized(allocator, module, options());
    defer compiled.deinit();
    try std.testing.expectEqual(.applied, compiled.outcome);
}

test "recovery optimization rolls back every bounded failure" {
    var b = source.Builder.init(a);
    defer b.deinit();
    const module = try diamond(&b);
    var baseline = try source.lowerObserved(a, module, .{ .recovery = true });
    defer baseline.deinit();
    var unaffordable = options();
    unaffordable.limits.source_work = 0;
    try std.testing.expectError(
        error.RelationLimit,
        source.lowerRecoveryOptimized(a, module, unaffordable),
    );
    unaffordable = options();
    unaffordable.limits.lowering_bytes = 0;
    try std.testing.expectError(
        error.OutOfMemory,
        source.lowerRecoveryOptimized(a, module, unaffordable),
    );
    const limits = [_]optimization.Limits{
        .{ .rule = .{ .work = 0 } },            .{ .rule = .{ .work = 100 } },
        .{ .rule = .{ .depth = 0 } },           .{ .rule = .{ .depth = 1 } },
        .{ .rule = .{ .temporary_bytes = 0 } }, .{ .rule = .{ .temporary_bytes = 512 } },
        .{ .rule = .{ .witnesses = 0 } },       .{ .evidence_bytes = 0 },
        .{ .evidence_bytes = 1 },
    };
    for (limits) |limit| {
        var policy = options();
        policy.limits = limit;
        var retained = try source.lowerRecoveryOptimized(a, module, policy);
        defer retained.deinit();
        try std.testing.expectEqual(.budget, retained.outcome);
        if (limit.rule.work == 0) try std.testing.expectEqual(0, retained.statistics.budget);
        if (limit.evidence_bytes == 1) try std.testing.expectEqual(1, retained.statistics.budget);
        try expectStructuralFallback(module, policy, &baseline, &retained);
    }
    const allocations = @import("../allocation_testing.zig");
    try allocations.check(std.heap.smp_allocator, compileWithFailures, .{module});
}
