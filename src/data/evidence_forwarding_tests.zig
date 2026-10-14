const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const forwarding = @import("evidence_forwarding.zig");
const a = std.testing.allocator;
const base: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                                                                                                 .unit,                                                                                                                                                       .boolean,
        .{ .internal = .{ .computation = .{ .parameters = &.{5}, .result = 0, .effects = &.{0}, .capture_bound = &.{0} } } }, .{ .internal = .{ .resumption = .{ .effect = 0, .input = 0, .answer = 0, .handled = &.{0}, .capture_bound = &.{ 0, 5 }, .mode = .deep, .use = .linear } } }, .{ .internal = .{ .capability = 0 } },
    },
    .constants = &.{},
    .effects = &.{.{ .identity = "test.tail.admin", .payload = 0, .result = 0, .external = false }},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 3, 0 } }, .result = 0 },
        .{ .entry = 2, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 5, 0, 0 } }, .result = 0, .effects = &.{0} },
        .{ .entry = 4, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 5, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 4, 0, 0 } }, .result = 0 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{.{ .destination = 1, .opcode = .computation, .operands = &.{0}, .immediate = 0 }}, .terminator = .{ .handle = .{ .handler = 0, .body = 1, .arguments = &.{}, .state = &.{}, .next = .{ .block = 1, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .capability = 1, .payload = 0, .next = .{ .block = 3, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } },
        .{ .function = 1, .instructions = &.{.{ .destination = 3, .opcode = .integer_bit_not, .operands = &.{2} }}, .terminator = .{ .return_value = 3 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .resume_value = .{ .resumption = 1, .argument = 0, .next = .{ .block = 6, .assignments = &.{ .{ .destination = 2, .source = .returned }, .{ .destination = 3, .source = .{ .slot = 0 } } } } } } },
        .{ .function = 3, .instructions = &.{.{ .destination = 0, .opcode = .move, .operands = &.{2} }}, .terminator = .{ .jump = .{ .block = 7, .assignments = &.{ .{ .destination = 2, .source = .{ .slot = 0 } }, .{ .destination = 0, .source = .{ .slot = 3 } } } } } },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
    .handlers = &.{.{ .mode = .deep, .input = 0, .answer = 0, .return_function = 2, .clauses = &.{.{ .effect = 0, .function = 3, .resumption = 4 }} }},
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 3 }},
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
};

pub fn fixture(allocator: std.mem.Allocator) !ir.Program {
    var result = base;
    const functions = try allocator.alloc(ir.Function, 5);
    @memcpy(functions[0..4], base.functions);
    functions[4] = .{ .entry = 8, .inputs = &.{ 0, 1, 2 }, .layout = .{ .slots = &.{ 5, 5, 0, 0, 0 } }, .result = 0, .effects = &.{0} };
    const blocks = try allocator.alloc(ir.Block, 11);
    @memcpy(blocks[0..8], base.blocks);
    blocks[2].terminator = .{ .call = .{ .function = 4, .arguments = &.{ 1, 1, 0 }, .next = base.blocks[2].terminator.perform.next } };
    blocks[8] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .capability = 0, .payload = 2, .next = .{ .block = 9, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } };
    blocks[9] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .capability = 1, .payload = 3, .next = .{ .block = 10, .assignments = &.{.{ .destination = 4, .source = .returned }} } } } };
    blocks[10] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 4 } };
    result.functions = functions;
    result.blocks = blocks;
    return result;
}
test "actual duplicate capability arguments remove forwarding, not operations" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const original = try fixture(arena.allocator());
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    admitted.deinit();
    const AllocationProbe = struct {
        fn execute(allocator: std.mem.Allocator, program: ir.Program) !void {
            var result = try forwarding.run(allocator, program, null, .{});
            defer result.deinit();
        }
    };
    try @import("allocation_testing.zig").check(a, AllocationProbe.execute, .{original});
    var candidate = (try forwarding.construct(a, original, .{})).?;
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 1), candidate.pairs.len);
    try forwarding.validate(a, original, candidate.program, candidate.pairs, 10_000_000);
    const interactions = try forwarding.observeInteractions(a, original, candidate.program, candidate.pairs, 10_000_000);
    try std.testing.expectEqual(.established, interactions.status);
    try std.testing.expect(interactions.monitors != 0);
    try std.testing.expectEqual(@as(?p.Id, 0), candidate.program.blocks[9].terminator.perform.capability);
    var stats: forwarding.Statistics = .{};
    var result = try forwarding.run(a, original, &stats, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.parameters_coalesced);
    try std.testing.expectEqual(@as(usize, 1), stats.call_arguments_removed);
    var performs: usize = 0;
    for (result.program.blocks) |block| if (block.terminator == .perform) {
        performs += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), performs);
    // Leaving the second capability unchanged is type-correct, but not the
    // claimed substitution. The independent record checker must reject it.
    try std.testing.expectError(error.InvalidEvidenceForwarding, forwarding.validate(a, original, original, candidate.pairs, 10_000_000));
    var limited = try forwarding.run(a, original, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expectEqual(@as(usize, 0), stats.parameters_coalesced);
    var invalid = original;
    invalid.roots.entry = 999;
    try std.testing.expectError(error.InvalidReference, forwarding.run(a, invalid, null, .{ .work_limit = 0 }));
}
test "writes and distinct argument slots cannot certify equal installations" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var original = try fixture(arena.allocator());
    const blocks = try arena.allocator().dupe(ir.Block, original.blocks);
    blocks[8].instructions = &.{.{ .destination = 0, .opcode = .move, .operands = &.{1} }};
    original.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    admitted.deinit();
    var rejected = try forwarding.construct(a, original, .{});
    defer if (rejected) |*value| value.deinit();
    try std.testing.expect(rejected == null);
    blocks[8].instructions = &.{};
    const functions = try arena.allocator().dupe(ir.Function, original.functions);
    functions[1].layout.slots = &.{ 0, 5, 0, 0, 5 };
    blocks[2].instructions = &.{.{ .destination = 4, .opcode = .move, .operands = &.{1} }};
    blocks[2].terminator.call.arguments = &.{ 1, 4, 0 };
    original.functions = functions;
    admitted = try @import("activation_ownership.zig").analyze(a, original);
    admitted.deinit();
    var unknown = try forwarding.construct(a, original, .{});
    defer if (unknown) |*value| value.deinit();
    try std.testing.expect(unknown == null);
}

fn nestedFixture(allocator: std.mem.Allocator) !ir.Program {
    var program = try fixture(allocator);
    const schemas = try allocator.alloc(p.Schema, 7);
    @memcpy(schemas[0..6], program.schemas);
    schemas[4].internal.resumption.effects = &.{0};
    schemas[6] = .{ .internal = .{ .computation = .{ .parameters = &.{5}, .result = 0, .effects = &.{0}, .capture_bound = &.{ 0, 5 } } } };
    const functions = try allocator.alloc(ir.Function, 6);
    @memcpy(functions[0..5], program.functions);
    functions[0].layout.slots = &.{ 0, 3, 0, 0 };
    functions[0].effects = &.{0};
    functions[1].layout.slots = &.{ 0, 5, 0, 0, 6, 0 };
    functions[2].inputs = &.{ 0, 1 };
    functions[2].layout.slots = &.{ 0, 0 };
    functions[3].inputs = &.{ 4, 0, 1 };
    functions[3].layout.slots = &.{ 0, 4, 0, 0, 0 };
    functions[3].effects = &.{0};
    functions[5] = .{ .entry = 11, .inputs = &.{ 0, 1, 2 }, .layout = .{ .slots = &.{ 5, 0, 5, 0 } }, .result = 0, .effects = &.{0} };
    const blocks = try allocator.alloc(ir.Block, 13);
    @memcpy(blocks[0..11], program.blocks);
    blocks[0].instructions = &.{ .{ .destination = 3, .opcode = .constant, .immediate = 0 }, base.blocks[0].instructions[0] };
    blocks[0].terminator.handle.state = &.{3};
    blocks[2].instructions = &.{ .{ .destination = 5, .opcode = .constant, .immediate = 1 }, .{ .destination = 4, .opcode = .computation, .immediate = 1, .operands = &.{ 1, 0 } } };
    blocks[2].terminator = .{ .handle = .{ .handler = 0, .body = 4, .arguments = &.{}, .state = &.{5}, .next = base.blocks[2].terminator.perform.next } };
    blocks[4].terminator = .{ .return_value = 1 };
    blocks[5].terminator.resume_value.argument = 4;
    blocks[11] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .call = .{ .function = 4, .arguments = &.{ 0, 2, 1 }, .next = .{ .block = 12, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } };
    blocks[12] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 3 } };
    const handlers = try allocator.dupe(ir.Handler, program.handlers);
    handlers[0].state = &.{0};
    handlers[0].effects = &.{0};
    program.schemas = schemas;
    program.functions = functions;
    program.blocks = blocks;
    program.handlers = handlers;
    program.constants = &.{ .{ .schema = 0, .bytes = &.{ 10, 0, 0, 0, 0, 0, 0, 0 } }, .{ .schema = 0, .bytes = &.{ 20, 0, 0, 0, 0, 0, 0, 0 } } };
    program.effects = &.{.{ .identity = "test.tail.admin", .payload = 0, .result = 0 }};
    program.constructors = try allocator.dupe(p.Constructor, &.{ program.constructors[0], .{ .function = 5, .capture = 1, .schema = 6 } });
    program.scopes.captures = try allocator.dupe(p.Capture, &.{ program.scopes.captures[0], .{ .fields = &.{ 5, 0 }, .use = .reusable } });
    return program;
}

test "two installations of one handler descriptor do not establish equal evidence" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const program = try nestedFixture(arena.allocator());
    var admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    var candidate = try forwarding.construct(a, program, .{});
    defer if (candidate) |*value| value.deinit();
    try std.testing.expect(candidate == null);
    try std.testing.expectEqual(program.blocks[0].terminator.handle.handler, program.blocks[2].terminator.handle.handler);
    try std.testing.expect(program.blocks[11].terminator.call.arguments[0] != program.blocks[11].terminator.call.arguments[1]);
    const control = try @import("control_provenance.zig").derive(arena.allocator(), program, &.{}, false);
    // The captured outer token survives discharge of the fresh inner formal,
    // even though both installations use exactly the same handler descriptor.
    const escaping = control.targets(.{ .block = 2, .role = .body }, 0);
    try std.testing.expectEqual(@as(usize, 1), escaping.len);
    try std.testing.expectEqual(@as(p.Id, 0), escaping[0].handler);
}

test "qualified targets preserve explicit outer forwarding and runtime capability unions" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var program = try nestedFixture(allocator);
    program.handlers = try allocator.dupe(ir.Handler, &.{ program.handlers[0], program.handlers[0] });
    const blocks = try allocator.dupe(ir.Block, program.blocks);
    blocks[2].terminator.handle.handler = 1;
    program.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    const provenance = @import("control_provenance.zig");
    const control = try provenance.derive(allocator, program, &.{}, false);
    const outer = control.targets(.{ .block = 8, .role = .operation }, 0);
    const inner = control.targets(.{ .block = 9, .role = .operation }, 0);
    const escaped = control.targets(.{ .block = 2, .role = .body }, 0);
    try std.testing.expectEqual(@as(usize, 1), outer.len);
    try std.testing.expectEqual(@as(p.Id, 0), outer[0].handler);
    try std.testing.expectEqual(@as(usize, 1), inner.len);
    try std.testing.expectEqual(@as(p.Id, 1), inner[0].handler);
    try std.testing.expectEqual(@as(usize, 1), escaped.len);
    try std.testing.expectEqual(@as(p.Id, 0), escaped[0].handler);
    const conservative = try provenance.derive(allocator, program, &.{}, true);
    const open_site = try conservative.select(.{ .block = 8, .role = .operation }, 0);
    try std.testing.expect(open_site.knowledge().conservative);
    try std.testing.expectEqual(@as(usize, 2), open_site.targets().len);
    try std.testing.expect(!(try control.select(.{ .block = 8, .role = .operation }, 0)).knowledge().conservative);

    const functions = try allocator.dupe(ir.Function, program.functions);
    functions[4].layout.slots = &.{ 5, 5, 0, 0, 0, 2, 5 };
    program.functions = functions;
    blocks[8].instructions = &.{
        .{ .destination = 3, .opcode = .constant, .immediate = 0 },
        .{ .destination = 5, .opcode = .less, .operands = &.{ 2, 3 } },
        .{ .destination = 6, .opcode = .select, .operands = &.{ 5, 0, 1 } },
    };
    blocks[8].terminator.perform.capability = 6;
    admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    // Recompute after mutation; the old program-bound facts are never reused.
    const joined_control = try provenance.deriveObserved(allocator, program, &.{}, false, true);
    const joined_selection = try joined_control.select(.{ .block = 8, .role = .operation }, 0);
    const joined = joined_selection.targets();
    const joined_explanation = try joined_control.explain(joined_selection);
    try std.testing.expect(explanationHas(joined_explanation, .branch_join));
    try std.testing.expectEqual(@as(usize, 2), joined_explanation.targets.len);
    try std.testing.expectEqual(@as(usize, 2), joined.len);
    try std.testing.expectEqual(@as(p.Id, 0), joined[0].handler);
    try std.testing.expectEqual(@as(p.Id, 1), joined[1].handler);
    const handlers = try allocator.dupe(ir.Handler, &.{ program.handlers[0], program.handlers[1], program.handlers[0] });
    handlers[2].return_function = program.functions.len;
    program.handlers = handlers;
    try std.testing.expectError(error.InvalidReference, @import("activation_ownership.zig").analyze(a, program));
}

test "conservative provenance preserves valid admission and rejects an unsafe retained capture" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var program = base;
    const blocks = try allocator.dupe(ir.Block, program.blocks);
    // The original argument, not the operation's reply, remains live across
    // this perform. Its u64 schema must be allowed by the selected resumption.
    blocks[3].instructions = &.{};
    blocks[3].terminator = .{ .return_value = 0 };
    program.blocks = blocks;
    const ownership = @import("activation_ownership.zig");
    var precise = try ownership.analyze(a, program);
    precise.deinit();
    var conservative = try ownership.analyzeComponent(a, program, &.{}, &.{});
    conservative.deinit();
    const control = try @import("control_provenance.zig").derive(allocator, program, &.{}, true);
    try std.testing.expect((try control.select(.{ .block = 2, .role = .operation }, 0)).knowledge().conservative);
    const schemas = try allocator.dupe(p.Schema, program.schemas);
    schemas[4].internal.resumption.capture_bound = &.{5};
    program.schemas = schemas;
    try std.testing.expectError(error.InvalidOwnership, ownership.analyze(a, program));
    try std.testing.expectError(error.InvalidOwnership, ownership.analyzeComponent(a, program, &.{}, &.{}));
}

test "successor bindings retain original views without poisoning unrelated deep handlers" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var program = base;
    const schemas = try allocator.alloc(p.Schema, base.schemas.len + 2);
    @memcpy(schemas[0..base.schemas.len], base.schemas);
    schemas[6] = .{ .internal = .{ .resumption = .{ .effect = 0, .input = 0, .answer = 0, .effects = &.{0}, .handled = &.{0}, .capture_bound = &.{ 0, 5 }, .mode = .shallow, .use = .linear } } };
    schemas[7] = schemas[6];
    schemas[7].internal.resumption.capture_bound = &.{};
    program.schemas = schemas;
    const functions = try allocator.alloc(ir.Function, 6);
    @memcpy(functions[0..4], base.functions);
    functions[4] = .{ .entry = 8, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 6, 0 } }, .result = 0 };
    functions[5] = .{ .entry = 10, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 6, 0 } }, .result = 0 };
    program.functions = functions;
    const blocks = try allocator.alloc(ir.Block, 12);
    @memcpy(blocks[0..8], base.blocks);
    blocks[8] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .resume_with = .{ .resumption = 1, .argument = 0, .handler = 2, .state = &.{}, .next = .{ .block = 9, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } };
    blocks[9] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 2 } };
    blocks[10] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .resume_with = .{ .resumption = 1, .argument = 0, .handler = 1, .state = &.{}, .next = .{ .block = 11, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } };
    blocks[11] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 2 } };
    blocks[3] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
    program.blocks = blocks;
    const handlers = try allocator.dupe(ir.Handler, &.{
        base.handlers[0],
        .{ .mode = .shallow, .input = 0, .answer = 0, .return_function = 2, .clauses = &.{.{ .effect = 0, .function = 4, .resumption = 6 }} },
        .{ .mode = .shallow, .input = 0, .answer = 0, .return_function = 2, .clauses = &.{.{ .effect = 0, .function = 5, .resumption = 6 }} },
    });
    program.handlers = handlers;
    var admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    const provenance = @import("control_provenance.zig");
    const original = try provenance.derive(allocator, program, &.{}, false);
    const isolated = try original.select(.{ .block = 2, .role = .operation }, 0);
    try std.testing.expect(!isolated.knowledge().conservative);
    try std.testing.expectEqual(@as(usize, 1), isolated.targets().len);
    try std.testing.expectEqual(@as(p.Id, 0), isolated.targets()[0].handler);
    // Installing the shallow handler instead joins both possible bindings; the
    // original view is retained even through a cycle of successor declarations.
    blocks[0].terminator.handle.handler = 1;
    admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    const rebound = try provenance.deriveObserved(allocator, program, &.{}, false, true);
    const views = try rebound.select(.{ .block = 2, .role = .operation }, 0);
    try std.testing.expect(!views.knowledge().conservative);
    try std.testing.expectEqual(@as(usize, 2), views.targets().len);
    try std.testing.expectEqual(@as(p.Id, 1), views.targets()[0].handler);
    try std.testing.expectEqual(@as(p.Id, 2), views.targets()[1].handler);
    const explanation = try rebound.explain(views);
    try std.testing.expect(explanationHas(explanation, .successor_binding));
    try std.testing.expect(explanation.reasons.len < 200);
    for (explanation.reasons) |reason| if (reason.rule == .successor_binding) try std.testing.expect(reason.approximation);
    // A successor with a narrower capture contract remains a possible recipient.
    // Neither the original broad handler nor the unused deep one can authorize it.
    handlers[2].clauses = &.{.{ .effect = 0, .function = 5, .resumption = 7 }};
    functions[5].layout.slots = &.{ 0, 7, 0 };
    try std.testing.expectError(error.InvalidOwnership, @import("activation_ownership.zig").analyze(a, program));
    blocks[0].terminator.handle.handler = 0;
    admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
}

fn explanationHas(explanation: @import("control_provenance.zig").Explanation, rule: @import("control_provenance.zig").Explanation.Rule) bool {
    for (explanation.reasons) |reason| if (reason.rule == rule) return true;
    return false;
}

test "explanations retain final outer argument and capture facts with owned presentation" {
    const provenance = @import("control_provenance.zig");
    var retained: provenance.Explanation = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const allocator = arena.allocator();
        var program = try nestedFixture(allocator);
        program.handlers = try allocator.dupe(ir.Handler, &.{ program.handlers[0], program.handlers[0] });
        const blocks = try allocator.dupe(ir.Block, program.blocks);
        blocks[2].terminator.handle.handler = 1;
        program.blocks = blocks;
        const control = try provenance.deriveObserved(allocator, program, &.{}, false, true);
        const selected = try control.select(.{ .block = 8, .role = .operation }, 0);
        const explanation = try control.explain(selected);
        try std.testing.expect(explanationHas(explanation, .fresh_installation));
        try std.testing.expect(explanationHas(explanation, .direct_argument));
        try std.testing.expect(explanationHas(explanation, .closure_capture));
        try std.testing.expectEqual(@as(usize, 1), explanation.targets.len);
        try std.testing.expectEqual(@as(p.Id, 0), explanation.targets[0].handler);
        try std.testing.expect(!explanation.knowledge.conservative);
        try std.testing.expect(explanation.reasons.len < 200);
        for (explanation.reasons) |reason| for (reason.inputs) |input| try std.testing.expect(input < explanation.reasons.len);
        retained = try explanation.copy(a);
        const CopyProbe = struct {
            fn run(allocator_: std.mem.Allocator, value: provenance.Explanation) !void {
                const owned = try value.copy(allocator_);
                owned.deinit(allocator_);
            }
        };
        try std.testing.checkAllAllocationFailures(a, CopyProbe.run, .{explanation});
        const open = try provenance.deriveObserved(allocator, program, &.{}, true, true);
        const conservative = try open.explain(try open.select(.{ .block = 8, .role = .operation }, 0));
        try std.testing.expect(conservative.knowledge.conservative);
        try std.testing.expect(explanationHas(conservative, .unknown_input));
        try std.testing.expect(explanationHas(conservative, .conservative_expansion));
    }
    defer retained.deinit(a);
    try std.testing.expectEqual(@as(p.Id, 8), retained.boundary.block);
    try std.testing.expect(explanationHas(retained, .fresh_installation));
    for (retained.reasons) |reason| for (reason.inputs) |input| try std.testing.expect(input < retained.reasons.len);
}

test "capture explanation observer preserves rejection and owns copied failure presentation" {
    const own = @import("activation_ownership.zig");
    const Observer = struct {
        retained: ?own.CaptureExplanation = null,
        failed_copy: bool = false,
        fn capture(_: *anyopaque, _: p.Id, _: *const own.CaptureSite, _: p.Id) void {}
        fn explain(context: *anyopaque, _: p.Id, _: *const own.CaptureSite, _: p.Id, value: ?own.CaptureExplanation) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.retained) |old| old.deinit(a);
            self.retained = if (value) |present| present.copy(a) catch result: {
                self.failed_copy = true;
                break :result null;
            } else null;
        }
    };
    var observer: Observer = .{};
    defer if (observer.retained) |value| value.deinit(a);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var program = base;
    const blocks = try arena.allocator().dupe(ir.Block, base.blocks);
    blocks[3].instructions = &.{};
    blocks[3].terminator = .{ .return_value = 0 };
    program.blocks = blocks;
    var admitted = try own.analyzeObserved(a, program, null, .{ .context = &observer, .capture = Observer.capture, .explanation = Observer.explain });
    admitted.deinit();
    try std.testing.expect(observer.retained != null and !observer.failed_copy);
    const schemas = try arena.allocator().dupe(p.Schema, base.schemas);
    schemas[4].internal.resumption.capture_bound = &.{5};
    program.schemas = schemas;
    try std.testing.expectError(error.InvalidOwnership, own.analyzeObserved(a, program, null, .{ .context = &observer, .capture = Observer.capture, .explanation = Observer.explain }));
    try std.testing.expect(observer.retained != null and !observer.failed_copy);
    try std.testing.expect(explanationHas(observer.retained.?, .fresh_installation));
    try std.testing.expect(!observer.retained.?.capture_constraint.?.satisfied);
}

test "explanation observers traverse large admitted blocks without native recursion" {
    const own = @import("activation_ownership.zig");
    const Observer = struct {
        observed: usize = 0,
        unavailable: bool = false,
        invalid: bool = false,
        fn capture(_: *anyopaque, _: p.Id, _: *const own.CaptureSite, _: p.Id) void {}
        fn explain(context: *anyopaque, _: p.Id, _: *const own.CaptureSite, _: p.Id, value: ?own.CaptureExplanation) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const explanation = value orelse {
                self.unavailable = true;
                return;
            };
            self.observed += 1;
            self.invalid = self.invalid or explanation.root >= explanation.reasons.len;
            for (explanation.reasons) |reason| for (reason.inputs) |input| {
                self.invalid = self.invalid or input >= explanation.reasons.len;
            };
        }
    };
    // Both a long unchanged capability and a long chain of actual capability
    // definitions must retain their finite explanation and ordinary admission.
    inline for (.{ false, true }) |definitions| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const allocator = arena.allocator();
        var program = try fixture(allocator);
        const blocks = try allocator.dupe(ir.Block, program.blocks);
        const instructions = try allocator.alloc(ir.Instruction, if (definitions) 4096 else 10_000);
        @memset(instructions, if (definitions)
            .{ .destination = 0, .opcode = .move, .operands = &.{0} }
        else
            .{ .destination = 2, .opcode = .integer_bit_not, .operands = &.{2} });
        blocks[8].instructions = instructions;
        program.blocks = blocks;
        var ordinary = try own.analyze(a, program);
        ordinary.deinit();
        var observer: Observer = .{};
        var observed = try own.analyzeObserved(a, program, null, .{ .context = &observer, .capture = Observer.capture, .explanation = Observer.explain });
        observed.deinit();
        try std.testing.expect(observer.observed != 0);
        try std.testing.expect(!observer.unavailable and !observer.invalid);
    }
}

test "explanations name unwitnessed inputs and close recursive summaries with backreferences" {
    const provenance = @import("control_provenance.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var program = try fixture(allocator);
    const blocks = try allocator.alloc(ir.Block, 12);
    @memcpy(blocks[0..11], program.blocks);
    blocks[10].terminator = .{ .call = .{ .function = 4, .arguments = &.{ 0, 1, 4 }, .next = .{ .block = 11, .assignments = &.{.{ .destination = 4, .source = .returned }} } } };
    blocks[11] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 4 } };
    program.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    const control = try provenance.deriveObserved(allocator, program, &.{}, false, true);
    const explanation = try control.explain(try control.select(.{ .block = 2, .role = .callee }, 0));
    try std.testing.expect(explanationHas(explanation, .summary_dependency));
    try std.testing.expect(!explanation.knowledge.conservative);
    try std.testing.expect(explanation.reasons.len < 200);
    var backreference = false;
    for (explanation.reasons, 0..) |reason, index| for (reason.inputs) |input| {
        backreference = backreference or input <= index;
    };
    try std.testing.expect(backreference);
    // Remove the only binding of the helper; intrinsic unused declarations
    // still receive unknown inputs instead of an empty-target proof.
    blocks[2] = base.blocks[2];
    admitted = try @import("activation_ownership.zig").analyze(a, program);
    admitted.deinit();
    const unbound = try provenance.deriveObserved(allocator, program, &.{}, false, true);
    const unknown = try unbound.explain(try unbound.select(.{ .block = 8, .role = .operation }, 0));
    try std.testing.expect(unknown.knowledge.conservative);
    try std.testing.expect(explanationHas(unknown, .unknown_input));
    try std.testing.expect(explanationHas(unknown, .conservative_expansion));
}

test "multi shot repeats captured suffix without replaying producer prefix" {
    const interactions = @import("interactions.zig");
    var image = base;
    var schemas = base.schemas[0..6].*;
    schemas[3].internal.computation.effects = &.{ 0, 1, 2 };
    schemas[4].internal.resumption.use = .multi;
    schemas[4].internal.resumption.effects = &.{ 1, 2 };
    image.schemas = &schemas;
    image.effects = &.{
        .{ .identity = "multi", .payload = 0, .result = 0, .external = false, .control_use = .multi },
        .{ .identity = "producer", .payload = 0, .result = 0 },
        .{ .identity = "suffix", .payload = 0, .result = 0 },
    };
    var functions = base.functions[0..4].*;
    functions[0].effects = &.{ 1, 2 };
    functions[1].effects = &.{ 0, 1, 2 };
    functions[3].effects = &.{ 1, 2 };
    image.functions = &functions;
    var handlers = base.handlers[0..1].*;
    handlers[0].effects = &.{ 1, 2 };
    image.handlers = &handlers;
    var blocks: [10]ir.Block = undefined;
    @memcpy(blocks[0..8], base.blocks);
    blocks[2].terminator = .{ .perform = .{ .effect = 1, .payload = 0, .next = .{ .block = 8, .assignments = &.{.{ .destination = 2, .source = .returned }} } } };
    blocks[8] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .capability = 1, .payload = 2, .next = .{ .block = 9, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } };
    blocks[9] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 2, .payload = 2, .next = .{ .block = 3, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } };
    blocks[6].instructions = &.{};
    blocks[6].terminator = .{ .resume_value = .{ .resumption = 1, .argument = 0, .next = .{ .block = 7, .assignments = &.{.{ .destination = 2, .source = .returned }} } } };
    image.blocks = &blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, image);
    admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owner = try @import("control_provenance.zig").derive(arena.allocator(), image, &.{}, false);
    var session: interactions.Session = .{ .allocator = a, .owner = owner };
    defer session.deinit();
    const Projection = struct {
        fn project(_: *const anyopaque, program: ir.Program, site: interactions.Site, _: usize) interactions.Mask {
            if (site.phase != .operation) return 0;
            return switch (program.blocks[@intCast(site.block)].terminator.perform.effect) {
                1 => 1,
                2 => 2,
                else => 0,
            };
        }
    };
    const binding: u8 = 0;
    const monitor: interactions.Monitor = .{ .binding = &binding, .states = 3, .alphabet = 2, .bad = interactions.bit(2), .transitions = &.{ 1, 0, 2, 1, 2, 2 }, .project = Projection.project };
    const result = try session.analyze(monitor);
    const root = result.get(image.roots.entry, 0, 0);
    try std.testing.expect(root.widened);
    try std.testing.expectEqual(.established, root.status(monitor));
    try std.testing.expect(root.normal & interactions.bit(1) != 0);
    // Two suffix occurrences remain represented without counting a new producer.
    try std.testing.expectEqual(@as(u8, 1), monitor.transitions[monitor.transitions[1 * 2 + 1] * 2 + 1]);
}

test "cell provenance explains conservative expansion at the read" {
    const provenance = @import("control_provenance.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var image = base;
    const schemas = try allocator.alloc(p.Schema, base.schemas.len + 1);
    @memcpy(schemas[0..base.schemas.len], base.schemas);
    schemas[base.schemas.len] = .{ .internal = .{ .cell = .{ .element = 5, .region = 0 } } };
    image.schemas = schemas;
    image.scopes.region_count = 1;
    const functions = try allocator.alloc(ir.Function, 5);
    @memcpy(functions[0..4], base.functions);
    functions[4] = .{ .entry = 8, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 6, 0, 5, 0 } }, .result = 0, .effects = &.{0}, .regions = &.{0} };
    image.functions = functions;
    const blocks = try allocator.alloc(ir.Block, 10);
    @memcpy(blocks[0..8], base.blocks);
    blocks[8] = .{ .function = 4, .instructions = &.{.{ .destination = 2, .opcode = .cell_get, .operands = &.{0} }}, .terminator = .{ .perform = .{ .effect = 0, .capability = 2, .payload = 1, .next = .{ .block = 9, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } };
    blocks[9] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 3 } };
    image.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, image);
    admitted.deinit();
    const owner = try provenance.deriveObserved(allocator, image, &.{}, false, true);
    const explanation = try owner.explain(try owner.select(.{ .block = 8, .role = .operation }, 0));
    try std.testing.expect(explanation.knowledge.conservative);
    try std.testing.expect(explanation.targets.len != 0);
    try std.testing.expect(explanationHas(explanation, .opaque_cell));
    try std.testing.expect(explanationHas(explanation, .conservative_expansion));
}

test "implicit disposal outside a direct helper row has finite explanation" {
    const provenance = @import("control_provenance.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var image = base;
    const schemas = try allocator.dupe(p.Schema, base.schemas);
    schemas[4].internal.resumption.effects = &.{1};
    image.schemas = schemas;
    image.constants = &.{.{ .schema = 1, .bytes = &.{} }};
    image.effects = &.{ base.effects[0], .{ .identity = "cleanup", .payload = 0, .result = 0 } };
    const handlers = try allocator.dupe(ir.Handler, base.handlers);
    handlers[0].effects = &.{1};
    image.handlers = handlers;
    const functions = try allocator.alloc(ir.Function, 6);
    @memcpy(functions[0..4], base.functions);
    functions[0].effects = &.{1};
    functions[3].effects = &.{1};
    functions[4] = .{ .entry = 8, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 4, 0, 0 } }, .result = 0 };
    functions[5] = .{ .entry = 10, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 4, 0, 1 } }, .result = 0 };
    image.functions = functions;
    const blocks = try allocator.alloc(ir.Block, 11);
    @memcpy(blocks[0..8], base.blocks);
    blocks[8] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .call = .{ .function = 5, .arguments = &.{ 0, 1 }, .next = .{ .block = 9, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } };
    blocks[9] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 2 } };
    blocks[10] = .{ .function = 5, .instructions = &.{.{ .destination = 2, .opcode = .constant, .immediate = 0 }}, .terminator = .{ .fail = 2 } };
    image.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, image);
    admitted.deinit();
    const owner = try provenance.deriveObserved(allocator, image, &.{}, false, true);
    const explanation = try owner.explain(try owner.select(.{ .block = 8, .role = .callee }, 1));
    try std.testing.expect(image.functions[5].effects.len == 0);
    try std.testing.expect(explanation.knowledge.environmental or explanation.knowledge.conservative);
    try std.testing.expect(explanationHas(explanation, .owned_cleanup));
    try std.testing.expect(explanation.reasons.len < 200);
}
