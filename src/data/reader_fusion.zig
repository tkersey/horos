// Copyright (c) 2026 Boundary contributors. MIT license.
//! P12's disjoint Reader law: immutable state, confined explicit capabilities,
//! total tail clauses and preserved inner-then-outer return composition.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const total = @import("total_clause.zig");
const access = @import("slot_access.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidReaderFusion, ReaderFusionLimit };
pub const Options = struct { work_limit: usize = 10_000_000, coalescing: p01.Options = .{} };
pub const Shape = struct {
    site: usize,
    outer_constructor: p.Id,
    inner_constructor: p.Id,
    outer_handler: p.Id,
    inner_handler: p.Id,
    outer_entry: p.Id,
    outer_return: p.Id,
    outer_capability: p.Id,
    inner_capability: p.Id,
    captured_outer_capability: p.Id,
    inner_state_at_caller: p.Id,
};
const Budget = struct {
    left: usize,
    fn take(self: *Budget, amount: usize) Error!void {
        if (amount > self.left) return error.ReaderFusionLimit;
        self.left -= amount;
    }
    fn record(self: *Budget, comptime T: type, value: T) Error!void {
        try self.take(1);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| try self.record(FieldType, @field(value, field_name)),
            .@"union" => switch (value) {
                inline else => |payload| try self.record(@TypeOf(payload), payload),
            },
            .optional => |info| if (value) |payload| {
                try self.record(info.child, payload);
            },
            .pointer => |info| for (value) |item| try self.record(info.child, item),
            else => {},
        }
    }
};
fn wire(schema: p.Id, permissions: traits.Facts, exportable: []const bool) bool {
    return permissions.copy[
        @intCast(schema)
    ] and permissions.drop[
        @intCast(schema)
    ] and exportable[
        @intCast(schema)
    ];
}
fn pureReturn(
    a: std.mem.Allocator,
    program: ir.Program,
    id: p.Id,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!bool {
    const function = program.functions[@intCast(id)];
    if (function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1)
        return false;
    for (function.layout.slots) |schema| {
        try budget.take(1);
        if (!wire(schema, permissions, exportable)) return false;
    }
    for (program.blocks) |block| {
        try budget.take(1);
        if (block.function != id) continue;
        if (block.custody != 0) return false;
        for (block.instructions) |op| {
            try budget.take(1 + op.operands.len);
            if (!total.instruction(op)) return false;
        }
    }
    total.validate(a, program, id, permissions) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    return true;
}
fn reader(
    a: std.mem.Allocator,
    program: ir.Program,
    id: p.Id,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!bool {
    const handler = program.handlers[@intCast(id)];
    if (handler.mode != .deep or
        handler.clauses.len != 1 or
        handler.state.len != 1 or
        handler.input != handler.answer or
        !wire(handler.state[0], permissions, exportable) or
        !wire(handler.input, permissions, exportable))
        return false;
    const clause = handler.clauses[0];
    if (program.schemas[
        @intCast(clause.resumption)
    ].internal.resumption.owned_regions.len != 0) return false;
    const effect = program.effects[@intCast(clause.effect)];
    if (clause.strategy != .tail or
        effect.bodies.len != 0 or
        effect.use_site_effects.len != 0 or
        effect.control_use != .linear or
        program.schemas[
            @intCast(effect.payload)
        ] != .unit or
        effect.result != handler.state[0])
        return false;
    const function = program.functions[@intCast(clause.function)];
    const entry = program.blocks[@intCast(function.entry)];
    if (function.inputs.len != 2 or
        function.effects.len != 0 or
        function.regions.len != 0 or
        function.custody.len != 1 or
        entry.custody != 0 or
        entry.instructions.len != 0 or
        entry.terminator != .return_value or
        entry.terminator.return_value != function.inputs[0])
        return false;
    for (program.blocks, 0..) |block, bid| {
        try budget.take(1);
        if (block.function == clause.function and bid != function.entry) return false;
    }
    return pureReturn(a, program, handler.return_function, permissions, exportable, budget);
}
fn returned(program: ir.Program, function: p.Id, edge: ir.Edge) bool {
    const block = program.blocks[@intCast(edge.block)];
    return block.function == function and
        block.custody == 0 and
        block.instructions.len == 0 and
        block.terminator == .return_value and
        edge.assignments.len == 1 and
        edge.assignments[0].source == .returned and
        edge.assignments[0].destination == block.terminator.return_value;
}
fn callerSlot(
    function: ir.Function,
    capture_count: usize,
    captures: []const p.Id,
    arguments: []const p.Id,
    slot: p.Id,
) ?p.Id {
    for (function.inputs, 0..) |input, index| if (input == slot) {
        if (index < capture_count) return captures[index];
        if (index == capture_count) return null;
        return arguments[index - capture_count - 1];
    };
    return null;
}
fn safeEdge(program: ir.Program, function: p.Id, edge: ir.Edge, exportable: []const bool) bool {
    const slots = program.functions[@intCast(function)].layout.slots;
    for (edge.assignments) |assignment| {
        if (!exportable[@intCast(slots[@intCast(assignment.destination)])]) return false;
        if (assignment.source == .slot and !exportable[
            @intCast(slots[
                @intCast(assignment.source.slot)
            ])
        ]) return false;
    }
    return true;
}
fn confinedBody(
    program: ir.Program,
    function_id: p.Id,
    outer_cap: p.Id,
    inner_cap: p.Id,
    outer_effect: p.Id,
    inner_effect: p.Id,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!bool {
    const function = program.functions[@intCast(function_id)];
    if (function.regions.len != 0 or function.custody.len != 1) return false;
    for (function.effects) |effect|
        if (effect != outer_effect and
            effect != inner_effect)
            return false;
    for (function.layout.slots, 0..) |schema, slot| {
        try budget.take(1);
        if (slot != outer_cap and slot != inner_cap and !wire(
            schema,
            permissions,
            exportable,
        )) return false;
    }
    for (program.blocks) |block| {
        try budget.take(1);
        if (block.function != function_id) continue;
        if (block.custody != 0) return false;
        for (block.instructions) |op| {
            try budget.take(1 + op.operands.len);
            if (!total.instruction(
                op,
            ) or op.destination == outer_cap or op.destination == inner_cap) return false;
            for (op.operands) |slot| if (slot == outer_cap or slot == inner_cap) return false;
        }
        switch (block.terminator) {
            .return_value, .fail => |slot| if (slot == outer_cap or slot == inner_cap) return false,
            .jump => |edge| if (!safeEdge(program, function_id, edge, exportable)) return false,
            .branch => |branch| {
                if (branch.condition == outer_cap or branch.condition == inner_cap or !safeEdge(
                    program,
                    function_id,
                    branch.when_true,
                    exportable,
                ) or !safeEdge(
                    program,
                    function_id,
                    branch.when_false,
                    exportable,
                )) return false;
            },
            .switch_variant => |branch| {
                if (branch.value == outer_cap or branch.value == inner_cap) return false;
                for (branch.cases) |edge| if (!safeEdge(
                    program,
                    function_id,
                    edge,
                    exportable,
                )) return false;
            },
            .perform => |op| {
                const expected = if (op.effect == outer_effect)
                    outer_cap
                else if (op.effect == inner_effect)
                    inner_cap
                else
                    return false;
                if (op.capability != expected or
                    op.bodies.len != 0 or
                    op.use_site_capabilities.len != 0 or
                    op.payload == outer_cap or
                    op.payload == inner_cap or
                    !safeEdge(program, function_id, op.next, exportable))
                    return false;
            },
            else => return false,
        }
    }
    return true;
}
/// All indices come from original admitted records; no library name is a law.
pub fn recognize(
    a: std.mem.Allocator,
    program: ir.Program,
    site: usize,
    permissions: traits.Facts,
    exportable: []const bool,
    limit: usize,
) Error!?Shape {
    var budget: Budget = .{ .left = limit };
    return recognizeBudgeted(a, program, site, permissions, exportable, &budget);
}
fn recognizeBudgeted(
    a: std.mem.Allocator,
    program: ir.Program,
    site: usize,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!?Shape {
    try budget.take(1);
    if (site >= program.blocks.len) return null;
    const block = program.blocks[site];
    if (block.terminator != .handle or
        block.custody != 0 or
        block.instructions.len == 0)
        return null;
    const caller = program.functions[@intCast(block.function)];
    if (caller.regions.len != 0 or caller.custody.len != 1) return null;
    const outer = block.terminator.handle;
    const construction = block.instructions[block.instructions.len - 1];
    if (construction.opcode != .computation or
        construction.destination != outer.body or
        !try reader(a, program, outer.handler, permissions, exportable, budget))
        return null;
    const outer_handler = program.handlers[@intCast(outer.handler)];
    if (outer_handler.effects.len != 0) return null;
    const outer_effect = outer_handler.clauses[0].effect;
    const ctor = program.constructors[@intCast(construction.immediate)];
    const capture = program.scopes.captures[@intCast(ctor.capture)];
    const signature = program.schemas[@intCast(ctor.schema)].internal.computation;
    if (signature.use != .reusable or
        capture.owned_regions.len != 0 or
        capture.borrowed_regions.len != 0)
        return null;
    for (capture.fields) |schema| if (!wire(schema, permissions, exportable)) return null;
    for (signature.parameters[1..]) |schema| if (!wire(
        schema,
        permissions,
        exportable,
    )) return null;
    for (signature.effects) |effect| if (effect != outer_effect) return null;
    var reads: usize = 0;
    var writes: usize = 0;
    for (program.blocks) |body| {
        try budget.take(1);
        if (body.function != block.function) continue;
        for (body.instructions) |op| {
            try budget.take(1 + op.operands.len);
            writes += @intFromBool(op.destination == outer.body);
            reads += std.mem.count(p.Id, op.operands, &.{outer.body});
        }
        const use = access.terminator(body.terminator, outer.body);
        reads += use.reads;
        writes += use.writes;
    }
    if (reads != 1 or writes != 1 or std.mem.indexOfScalar(
        p.Id,
        caller.inputs,
        outer.body,
    ) != null) return null;
    const function = program.functions[@intCast(ctor.function)];
    const entry = program.blocks[@intCast(function.entry)];
    if (function.regions.len != 0 or
        function.custody.len != 1 or
        entry.custody != 0 or
        entry.instructions.len != 1 or
        entry.instructions[0].opcode != .computation or
        entry.terminator != .handle)
        return null;
    const inner = entry.terminator.handle;
    const inner_construction = entry.instructions[0];
    if (inner_construction.destination != inner.body or !returned(
        program,
        ctor.function,
        inner.next,
    ) or !try reader(a, program, inner.handler, permissions, exportable, budget)) return null;
    if (std.mem.indexOfScalar(p.Id, function.inputs, inner.body) != null) return null;
    for (program.blocks, 0..) |body, id| {
        try budget.take(1);
        if (body.function == ctor.function and
            id != function.entry and
            id != inner.next.block)
            return null;
    }
    const inner_handler = program.handlers[@intCast(inner.handler)];
    const inner_effect = inner_handler.clauses[0].effect;
    if (inner_effect == outer_effect or inner_handler.answer != outer_handler.input) return null;
    for (inner_handler.effects) |effect| if (effect != outer_effect) return null;
    const outer_cap = function.inputs[capture.fields.len];
    const state = callerSlot(
        function,
        capture.fields.len,
        construction.operands,
        outer.arguments,
        inner.state[0],
    ) orelse return null;
    const inner_ctor = program.constructors[@intCast(inner_construction.immediate)];
    if (!@import("capture_reduction.zig").privateWorker(
        program,
        @intCast(inner_construction.immediate),
    )) return null;
    const inner_capture = program.scopes.captures[@intCast(inner_ctor.capture)];
    const inner_signature = program.schemas[@intCast(inner_ctor.schema)].internal.computation;
    if (inner_signature.use != .reusable or
        inner_capture.owned_regions.len != 0 or
        inner_capture.borrowed_regions.len != 0)
        return null;
    for (inner_signature.parameters[1..]) |schema| if (!wire(
        schema,
        permissions,
        exportable,
    )) return null;
    const inner_function = program.functions[@intCast(inner_ctor.function)];
    var captured_outer: ?p.Id = null;
    for (inner_capture.fields, inner_construction.operands, 0..) |schema, operand, index| {
        if (wire(schema, permissions, exportable)) continue;
        if (operand != outer_cap or captured_outer != null) return null;
        captured_outer = inner_function.inputs[index];
    }
    const captured = captured_outer orelse return null;
    const inner_cap = inner_function.inputs[inner_capture.fields.len];
    if (!try confinedBody(
        program,
        inner_ctor.function,
        captured,
        inner_cap,
        outer_effect,
        inner_effect,
        permissions,
        exportable,
        budget,
    )) return null;
    return .{
        .site = site,
        .outer_constructor = construction.immediate,
        .inner_constructor = inner_construction.immediate,
        .outer_handler = outer.handler,
        .inner_handler = inner.handler,
        .outer_entry = function.entry,
        .outer_return = inner.next.block,
        .outer_capability = outer_cap,
        .inner_capability = inner_cap,
        .captured_outer_capability = captured,
        .inner_state_at_caller = state,
    };
}

pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    shape: Shape,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn literalIdentity(program: ir.Program, handler: ir.Handler) bool {
    const function = program.functions[@intCast(handler.return_function)];
    const block = program.blocks[@intCast(function.entry)];
    return block.instructions.len == 0 and
        block.terminator == .return_value and
        block.terminator.return_value == function.inputs[1];
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var admitted = try own.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schema_facts = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    try budget.record(ir.Program, original);
    var chosen: ?Shape = null;
    for (original.blocks, 0..) |_, id| {
        try budget.take(1);
        if (try recognizeBudgeted(
            a,
            original,
            id,
            permissions,
            schema_facts.exportable,
            &budget,
        )) |shape| {
            chosen = shape;
            break;
        }
    }
    const shape = chosen orelse return null;
    const site = original.blocks[shape.site];
    const outer = site.terminator.handle;
    const oh = original.handlers[@intCast(shape.outer_handler)];
    const ih = original.handlers[@intCast(shape.inner_handler)];
    const oc = original.constructors[@intCast(shape.outer_constructor)];
    const ic = original.constructors[@intCast(shape.inner_constructor)];
    const of = original.functions[@intCast(oc.function)];
    const entry = original.blocks[@intCast(shape.outer_entry)];
    const inner = entry.terminator.handle;
    const os = original.schemas[@intCast(oc.schema)].internal.computation;
    const is = original.schemas[@intCast(ic.schema)].internal.computation;
    // Handled evidence follows clause/capability positions; escaping effect
    // rows are sets in canonical ID order, independent of handler nesting.
    const handled = try a.dupe(p.Id, &.{ oh.clauses[0].effect, ih.clauses[0].effect });
    const effects = try a.dupe(
        p.Id,
        &.{ @min(handled[0], handled[1]), @max(handled[0], handled[1]) },
    );
    const states = try a.dupe(p.Id, &.{ oh.state[0], ih.state[0] });
    const base_f = original.functions.len;
    const base_b = original.blocks.len;
    const base_s = original.schemas.len;
    const identity_returns = literalIdentity(original, oh) and literalIdentity(original, ih);
    const return_blocks: usize = if (identity_returns) 1 else 3;
    try budget.take(original.functions.len);
    try budget.take(original.blocks.len);
    try budget.take(original.schemas.len);
    const functions = try a.alloc(ir.Function, base_f + 4);
    @memcpy(functions[0..base_f], original.functions);
    const blocks = try a.alloc(ir.Block, base_b + 2 + return_blocks + 2);
    @memcpy(blocks[0..base_b], original.blocks);
    const schemas = try a.alloc(p.Schema, base_s + 3);
    @memcpy(schemas[0..base_s], original.schemas);
    var bound: std.ArrayList(p.Id) = .empty;
    for ([_]p.Id{
        oh.clauses[0].resumption,
        ih.clauses[0].resumption,
    }) |id| for (original.schemas[@intCast(id)].internal.resumption.capture_bound) |schema| {
        try budget.take(1);
        if (std.mem.indexOfScalar(p.Id, bound.items, schema) == null) try bound.append(a, schema);
    };
    for ([_]p.Id{ states[0], states[1], oh.input, os.parameters[0], is.parameters[0] }) |schema| {
        if (std.mem.indexOfScalar(p.Id, bound.items, schema) == null) try bound.append(a, schema);
    }
    const capture_bound = try bound.toOwnedSlice(a);
    for ([_]ir.Clause{ oh.clauses[0], ih.clauses[0] }, 0..) |clause, index| {
        var signature = original.schemas[@intCast(clause.resumption)].internal.resumption;
        signature.handled = handled;
        signature.effects = &.{};
        signature.escaping = &.{};
        signature.capture_bound = capture_bound;
        schemas[base_s + index] = .{ .internal = .{ .resumption = signature } };
    }
    const parameters = try a.alloc(p.Id, os.parameters.len + 1);
    parameters[0] = os.parameters[0];
    parameters[1] = is.parameters[0];
    @memcpy(parameters[2..], os.parameters[1..]);
    var body_type = os;
    body_type.parameters = parameters;
    body_type.effects = effects;
    schemas[base_s + 2] = .{ .internal = .{ .computation = body_type } };
    // The confined inner closure is gone. Its non-input temporary is now the
    // second installation capability; no extra activation slot is needed.
    const body_slots = try a.dupe(p.Id, of.layout.slots);
    body_slots[@intCast(inner.body)] = is.parameters[0];
    const capture_count = original.scopes.captures[@intCast(oc.capture)].fields.len;
    const inputs = try a.alloc(p.Id, of.inputs.len + 1);
    @memcpy(inputs[0 .. capture_count + 1], of.inputs[0 .. capture_count + 1]);
    inputs[capture_count + 1] = inner.body;
    @memcpy(inputs[capture_count + 2 ..], of.inputs[capture_count + 1 ..]);
    functions[base_f] = of;
    functions[base_f].entry = base_b;
    functions[base_f].inputs = inputs;
    functions[base_f].layout.slots = body_slots;
    functions[base_f].effects = effects;
    const captures_at_site = entry.instructions[0].operands;
    const body_arguments = try a.alloc(p.Id, captures_at_site.len + inner.arguments.len + 1);
    @memcpy(body_arguments[0..captures_at_site.len], captures_at_site);
    body_arguments[captures_at_site.len] = inner.body;
    @memcpy(body_arguments[captures_at_site.len + 1 ..], inner.arguments);
    var next = inner.next;
    next.block = base_b + 1;
    blocks[base_b] = entry;
    blocks[base_b].function = base_f;
    blocks[base_b].instructions = &.{};
    blocks[base_b].terminator = .{ .call = .{
        .function = ic.function,
        .arguments = body_arguments,
        .next = next,
    } };
    blocks[base_b + 1] = original.blocks[@intCast(shape.outer_return)];
    blocks[base_b + 1].function = base_f;
    const return_slots = try a.dupe(
        p.Id,
        if (identity_returns) &.{ states[0], states[1], oh.input } else &.{ states[0], states[1], oh.input, oh.input, oh.input },
    );
    functions[base_f + 1] = .{
        .entry = base_b + 2,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = return_slots },
        .result = oh.answer,
    };
    if (identity_returns) blocks[base_b + 2] = .{
        .function = base_f + 1,
        .instructions = &.{},
        .terminator = .{ .return_value = 2 },
    } else {
        blocks[base_b + 2] = .{
            .function = base_f + 1,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = ih.return_function,
                .arguments = &.{ 1, 2 },
                .next = .{
                    .block = base_b + 3,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        };
        blocks[base_b + 3] = .{
            .function = base_f + 1,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = oh.return_function,
                .arguments = &.{ 0, 3 },
                .next = .{
                    .block = base_b + 4,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        };
        blocks[base_b + 4] = .{
            .function = base_f + 1,
            .instructions = &.{},
            .terminator = .{ .return_value = 4 },
        };
    }
    const clauses = try a.alloc(ir.Clause, 2);
    for ([_]ir.Clause{ oh.clauses[0], ih.clauses[0] }, 0..) |clause, index| {
        const slots = try a.dupe(
            p.Id,
            &.{ states[0], states[1], original.effects[@intCast(clause.effect)].payload },
        );
        functions[base_f + 2 + index] = .{
            .entry = base_b + 2 + return_blocks + index,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = slots },
            .result = states[index],
        };
        blocks[base_b + 2 + return_blocks + index] = .{
            .function = base_f + 2 + index,
            .instructions = &.{},
            .terminator = .{ .return_value = index },
        };
        clauses[index] = clause;
        clauses[index].function = base_f + 2 + index;
        clauses[index].resumption = base_s + index;
    }
    const handlers = try a.alloc(ir.Handler, original.handlers.len + 1);
    @memcpy(handlers[0..original.handlers.len], original.handlers);
    handlers[original.handlers.len] = .{
        .mode = .deep,
        .input = oh.input,
        .answer = oh.answer,
        .return_function = base_f + 1,
        .clauses = clauses,
        .state = states,
    };
    const constructors = try a.alloc(p.Constructor, original.constructors.len + 1);
    @memcpy(constructors[0..original.constructors.len], original.constructors);
    constructors[original.constructors.len] = .{
        .function = base_f,
        .capture = oc.capture,
        .schema = base_s + 2,
    };
    const caller = &functions[@intCast(site.function)];
    const caller_slots = try a.dupe(p.Id, caller.layout.slots);
    caller_slots[@intCast(outer.body)] = base_s + 2;
    caller.layout.slots = caller_slots;
    const instructions = try a.dupe(ir.Instruction, site.instructions);
    instructions[instructions.len - 1].immediate = original.constructors.len;
    blocks[shape.site].instructions = instructions;
    blocks[shape.site].terminator.handle.handler = original.handlers.len;
    blocks[shape.site].terminator.handle.state = try a.dupe(
        p.Id,
        &.{ outer.state[0], shape.inner_state_at_caller },
    );
    var program = original;
    program.schemas = schemas;
    program.functions = functions;
    program.blocks = blocks;
    program.handlers = handlers;
    program.constructors = constructors;
    keep = true;
    return .{ .arena = arena, .program = program, .shape = shape };
}

const Checker = struct {
    budget: Budget,
    fn require(self: *@This(), comptime T: type, expected: T, actual: T) Error!void {
        try self.budget.record(T, expected);
        try self.budget.record(T, actual);
        if (!equal(T, expected, actual)) return error.InvalidReaderFusion;
    }
};
/// Reconstruct correspondence from original records. The constructor's Shape,
/// maps, and candidate-generation routine are not consumed as proof.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    site: usize,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const facts = try admission.schemas(a, original.schemas);
    var proof: Checker = .{ .budget = .{ .left = options.work_limit } };
    const shape = (try recognizeBudgeted(
        a,
        original,
        site,
        permissions,
        facts.exportable,
        &proof.budget,
    )) orelse return error.InvalidReaderFusion;
    const old_site = original.blocks[site];
    const outer = old_site.terminator.handle;
    const oh = original.handlers[@intCast(shape.outer_handler)];
    const ih = original.handlers[@intCast(shape.inner_handler)];
    const oc = original.constructors[@intCast(shape.outer_constructor)];
    const ic = original.constructors[@intCast(shape.inner_constructor)];
    const of = original.functions[@intCast(oc.function)];
    const old_entry = original.blocks[@intCast(shape.outer_entry)];
    const inner = old_entry.terminator.handle;
    const os = original.schemas[@intCast(oc.schema)].internal.computation;
    const is = original.schemas[@intCast(ic.schema)].internal.computation;
    const f = original.functions.len;
    const b = original.blocks.len;
    const s = original.schemas.len;
    const identity_returns = literalIdentity(original, oh) and literalIdentity(original, ih);
    const n: usize = if (identity_returns) 1 else 3;
    if (candidate.functions.len != f + 4 or
        candidate.blocks.len != b + 4 + n or
        candidate.schemas.len != s + 3 or
        candidate.handlers.len != original.handlers.len + 1 or
        candidate.constructors.len != original.constructors.len + 1)
        return error.InvalidReaderFusion;
    var rest = candidate;
    rest.functions = original.functions;
    rest.blocks = original.blocks;
    rest.schemas = original.schemas;
    rest.handlers = original.handlers;
    rest.constructors = original.constructors;
    try proof.require(ir.Program, original, rest);
    try proof.require([]const p.Schema, original.schemas, candidate.schemas[0..s]);
    try proof.require(
        []const ir.Handler,
        original.handlers,
        candidate.handlers[0..original.handlers.len],
    );
    try proof.require(
        []const p.Constructor,
        original.constructors,
        candidate.constructors[0..original.constructors.len],
    );
    for (original.functions, candidate.functions[0..f], 0..) |old, new, id| {
        if (id != old_site.function) {
            try proof.require(ir.Function, old, new);
            continue;
        }
        var metadata = new;
        metadata.layout = old.layout;
        try proof.require(ir.Function, old, metadata);
        if (new.layout.slots.len != old.layout.slots.len) return error.InvalidReaderFusion;
        for (
            old.layout.slots,
            new.layout.slots,
            0..,
        ) |old_schema, new_schema, slot|
            if (new_schema != (if (slot == outer.body)
                s + 2
            else
                old_schema))
                return error.InvalidReaderFusion;
    }
    for (original.blocks, candidate.blocks[0..b], 0..) |old, new, id| {
        if (id != site) {
            try proof.require(ir.Block, old, new);
            continue;
        }
        var metadata = new;
        metadata.instructions = old.instructions;
        metadata.terminator = old.terminator;
        try proof.require(ir.Block, old, metadata);
        if (new.instructions.len != old.instructions.len or
            new.terminator != .handle)
            return error.InvalidReaderFusion;
        for (old.instructions, new.instructions, 0..) |old_op, new_op, index| {
            var restored = new_op;
            if (index + 1 == old.instructions.len) {
                if (new_op.immediate != original.constructors.len) return error.InvalidReaderFusion;
                restored.immediate = old_op.immediate;
            }
            try proof.require(ir.Instruction, old_op, restored);
        }
        var restored = new.terminator.handle;
        if (restored.handler != original.handlers.len) return error.InvalidReaderFusion;
        try proof.require(
            []const p.Id,
            &.{ outer.state[0], shape.inner_state_at_caller },
            restored.state,
        );
        restored.handler = outer.handler;
        restored.state = outer.state;
        try proof.require(@TypeOf(outer), outer, restored);
    }
    const handled = [_]p.Id{ oh.clauses[0].effect, ih.clauses[0].effect };
    const states = [_]p.Id{ oh.state[0], ih.state[0] };
    var allowed_bound: std.ArrayList(p.Id) = .empty;
    for ([_]p.Id{
        oh.clauses[0].resumption,
        ih.clauses[0].resumption,
    }) |id| for (original.schemas[@intCast(id)].internal.resumption.capture_bound) |schema| {
        if (std.mem.indexOfScalar(
            p.Id,
            allowed_bound.items,
            schema,
        ) == null) try allowed_bound.append(a, schema);
    };
    for ([_]p.Id{ states[0], states[1], oh.input, os.parameters[0], is.parameters[0] }) |schema| {
        if (std.mem.indexOfScalar(
            p.Id,
            allowed_bound.items,
            schema,
        ) == null) try allowed_bound.append(a, schema);
    }
    for ([_]ir.Clause{ oh.clauses[0], ih.clauses[0] }, 0..) |clause, index| {
        const schema = candidate.schemas[s + index];
        if (schema != .internal or schema.internal != .resumption) return error.InvalidReaderFusion;
        var signature = schema.internal.resumption;
        const old = original.schemas[@intCast(clause.resumption)].internal.resumption;
        try proof.require([]const p.Id, &handled, signature.handled);
        try proof.require([]const p.Id, allowed_bound.items, signature.capture_bound);
        if (signature.effects.len != 0 or
            signature.escaping.len != 0)
            return error.InvalidReaderFusion;
        signature.handled = old.handled;
        signature.effects = old.effects;
        signature.escaping = old.escaping;
        signature.capture_bound = old.capture_bound;
        try proof.require(p.ResumptionType, old, signature);
    }
    const body_schema = candidate.schemas[s + 2];
    if (body_schema != .internal or
        body_schema.internal != .computation)
        return error.InvalidReaderFusion;
    var body_type = body_schema.internal.computation;
    if (body_type.parameters.len != os.parameters.len + 1 or
        body_type.parameters[0] != os.parameters[0] or
        body_type.parameters[1] != is.parameters[0])
        return error.InvalidReaderFusion;
    try proof.require([]const p.Id, os.parameters[1..], body_type.parameters[2..]);
    // Candidate admission has independently established canonical row order.
    // Check the original effect set without using the constructor's ordering.
    try proof.require(usize, 2, body_type.effects.len);
    for (handled) |effect| try proof.require(
        bool,
        true,
        std.mem.indexOfScalar(p.Id, body_type.effects, effect) != null,
    );
    body_type.parameters = os.parameters;
    body_type.effects = os.effects;
    try proof.require(p.ComputationType, os, body_type);
    const body = candidate.functions[f];
    var body_metadata = body;
    body_metadata.entry = of.entry;
    body_metadata.inputs = of.inputs;
    body_metadata.layout = of.layout;
    body_metadata.effects = of.effects;
    try proof.require(ir.Function, of, body_metadata);
    const captures = original.scopes.captures[@intCast(oc.capture)].fields.len;
    if (body.entry != b or
        body.inputs.len != of.inputs.len + 1 or
        body.inputs[captures + 1] != inner.body or
        body.layout.slots.len != of.layout.slots.len)
        return error.InvalidReaderFusion;
    try proof.require([]const p.Id, of.inputs[0 .. captures + 1], body.inputs[0 .. captures + 1]);
    try proof.require([]const p.Id, of.inputs[captures + 1 ..], body.inputs[captures + 2 ..]);
    for (of.layout.slots, body.layout.slots, 0..) |old_schema, new_schema, slot| {
        try proof.require(
            p.Id,
            if (slot == inner.body) is.parameters[0] else old_schema,
            new_schema,
        );
    }
    try proof.require(
        []const p.Id,
        candidate.schemas[s + 2].internal.computation.effects,
        body.effects,
    );
    const new_entry = candidate.blocks[b];
    var entry_metadata = new_entry;
    entry_metadata.function = old_entry.function;
    entry_metadata.instructions = old_entry.instructions;
    entry_metadata.terminator = old_entry.terminator;
    try proof.require(ir.Block, old_entry, entry_metadata);
    if (new_entry.function != f or
        new_entry.instructions.len != 0 or
        new_entry.terminator != .call)
        return error.InvalidReaderFusion;
    const call = new_entry.terminator.call;
    const original_captures = old_entry.instructions[0].operands;
    if (call.function != ic.function or
        call.arguments.len != original_captures.len + inner.arguments.len + 1 or
        call.arguments[original_captures.len] != inner.body or
        call.next.block != b + 1)
        return error.InvalidReaderFusion;
    try proof.require([]const p.Id, original_captures, call.arguments[0..original_captures.len]);
    try proof.require([]const p.Id, inner.arguments, call.arguments[original_captures.len + 1 ..]);
    try proof.require([]const ir.Assignment, inner.next.assignments, call.next.assignments);
    var returned_block = candidate.blocks[b + 1];
    if (returned_block.function != f) return error.InvalidReaderFusion;
    returned_block.function = oc.function;
    try proof.require(ir.Block, original.blocks[@intCast(shape.outer_return)], returned_block);
    const return_slots: []const p.Id = if (identity_returns) &.{
        states[0],
        states[1],
        oh.input,
    } else &.{ states[0], states[1], oh.input, oh.input, oh.input };
    try proof.require(
        ir.Function,
        .{
            .entry = b + 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = return_slots },
            .result = oh.answer,
        },
        candidate.functions[f + 1],
    );
    if (identity_returns) try proof.require(
        ir.Block,
        .{ .function = f + 1, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        candidate.blocks[b + 2],
    ) else {
        try proof.require(
            ir.Block,
            .{
                .function = f + 1,
                .instructions = &.{},
                .terminator = .{ .call = .{
                    .function = ih.return_function,
                    .arguments = &.{ 1, 2 },
                    .next = .{
                        .block = b + 3,
                        .assignments = &.{.{ .destination = 3, .source = .returned }},
                    },
                } },
            },
            candidate.blocks[b + 2],
        );
        try proof.require(
            ir.Block,
            .{
                .function = f + 1,
                .instructions = &.{},
                .terminator = .{ .call = .{
                    .function = oh.return_function,
                    .arguments = &.{ 0, 3 },
                    .next = .{
                        .block = b + 4,
                        .assignments = &.{.{ .destination = 4, .source = .returned }},
                    },
                } },
            },
            candidate.blocks[b + 3],
        );
        try proof.require(
            ir.Block,
            .{ .function = f + 1, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
            candidate.blocks[b + 4],
        );
    }
    var expected_clauses: [2]ir.Clause = undefined;
    for ([_]ir.Clause{ oh.clauses[0], ih.clauses[0] }, 0..) |clause, index| {
        try proof.require(
            ir.Function,
            .{
                .entry = b + 2 + n + index,
                .inputs = &.{ 0, 1, 2 },
                .layout = .{ .slots = &.{
                    states[0],
                    states[1],
                    original.effects[@intCast(clause.effect)].payload,
                } },
                .result = states[index],
            },
            candidate.functions[f + 2 + index],
        );
        try proof.require(
            ir.Block,
            .{
                .function = f + 2 + index,
                .instructions = &.{},
                .terminator = .{ .return_value = index },
            },
            candidate.blocks[b + 2 + n + index],
        );
        expected_clauses[index] = clause;
        expected_clauses[index].function = f + 2 + index;
        expected_clauses[index].resumption = s + index;
    }
    try proof.require(
        ir.Handler,
        .{
            .mode = .deep,
            .input = oh.input,
            .answer = oh.answer,
            .return_function = f + 1,
            .clauses = &expected_clauses,
            .state = &states,
        },
        candidate.handlers[original.handlers.len],
    );
    try proof.require(
        p.Constructor,
        .{ .function = f, .capture = oc.capture, .schema = s + 2 },
        candidate.constructors[original.constructors.len],
    );
}

pub const Statistics = struct { pairs_fused: usize = 0, work_limit: bool = false };
pub fn possible(program: ir.Program) bool {
    var count: usize = 0;
    for (program.handlers) |handler|
        if (handler.mode == .deep and
            handler.clauses.len == 1 and
            handler.state.len == 1 and
            handler.clauses[0].strategy == .tail)
        {
            count += 1;
        };
    return count >= 2;
}
pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!p01.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var candidate = (construct(allocator, original, options) catch |err| switch (err) {
        error.ReaderFusionLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validate(
        allocator,
        original,
        candidate.program,
        candidate.shape.site,
        options,
    ) catch |err| switch (err) {
        error.ReaderFusionLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.pairs_fused = 1;
    return result;
}
