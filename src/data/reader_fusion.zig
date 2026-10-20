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
        @setEvalBranchQuota(10000);
        return self.recordFields(T, value);
    }

    inline fn recordFields(self: *Budget, comptime T: type, value: T) Error!void {
        try self.take(1);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| try self.recordFields(FieldType, @field(value, field_name)),
            .@"union" => switch (value) {
                inline else => |payload| try self.recordFields(@TypeOf(payload), payload),
            },
            .optional => |info| if (value) |payload| {
                try self.recordFields(info.child, payload);
            },
            .pointer => |info| for (value) |item| try self.recordFields(info.child, item),
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
        if (!confinedTerminator(
            program,
            function_id,
            block.terminator,
            outer_cap,
            inner_cap,
            outer_effect,
            inner_effect,
            exportable,
        )) return false;
    }
    return true;
}
fn confinedTerminator(
    program: ir.Program,
    function_id: p.Id,
    terminator: ir.Terminator,
    outer_cap: p.Id,
    inner_cap: p.Id,
    outer_effect: p.Id,
    inner_effect: p.Id,
    exportable: []const bool,
) bool {
    switch (terminator) {
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
    return recognizeOuterUses(.{
        .a = a,
        .block = block,
        .budget = budget,
        .caller = caller,
        .capture = capture,
        .construction = construction,
        .ctor = ctor,
        .exportable = exportable,
        .outer = outer,
        .outer_effect = outer_effect,
        .outer_handler = outer_handler,
        .permissions = permissions,
        .program = program,
        .site = site,
    });
}
fn recognizeOuterUses(ctx: anytype) Error!?Shape {
    var reads: usize = 0;
    var writes: usize = 0;
    for (ctx.program.blocks) |body| {
        try ctx.budget.take(1);
        if (body.function != ctx.block.function) continue;
        for (body.instructions) |op| {
            try ctx.budget.take(1 + op.operands.len);
            writes += @intFromBool(op.destination == ctx.outer.body);
            reads += std.mem.count(p.Id, op.operands, &.{ctx.outer.body});
        }
        const use = access.terminator(body.terminator, ctx.outer.body);
        reads += use.reads;
        writes += use.writes;
    }
    if (reads != 1 or writes != 1 or std.mem.indexOfScalar(
        p.Id,
        ctx.caller.inputs,
        ctx.outer.body,
    ) != null) return null;
    return recognizeInnerInstallation(ctx);
}

fn recognizeInnerInstallation(ctx: anytype) Error!?Shape {
    const function = ctx.program.functions[@intCast(ctx.ctor.function)];
    const entry = ctx.program.blocks[@intCast(function.entry)];
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
        ctx.program,
        ctx.ctor.function,
        inner.next,
    ) or
        !try reader(
            ctx.a,
            ctx.program,
            inner.handler,
            ctx.permissions,
            ctx.exportable,
            ctx.budget,
        ))
        return null;
    if (std.mem.indexOfScalar(p.Id, function.inputs, inner.body) != null) return null;
    for (ctx.program.blocks, 0..) |body, id| {
        try ctx.budget.take(1);
        if (body.function == ctx.ctor.function and
            id != function.entry and
            id != inner.next.block)
            return null;
    }
    const inner_handler = ctx.program.handlers[@intCast(inner.handler)];
    const inner_effect = inner_handler.clauses[0].effect;
    if (inner_effect ==
        ctx.outer_effect or
        inner_handler.answer !=
            ctx.outer_handler.input)
        return null;
    for (inner_handler.effects) |effect| if (effect != ctx.outer_effect) return null;
    const outer_cap = function.inputs[ctx.capture.fields.len];
    const state = callerSlot(
        function,
        ctx.capture.fields.len,
        ctx.construction.operands,
        ctx.outer.arguments,
        inner.state[0],
    ) orelse return null;
    return recognizeInnerCapture(.{
        .function = function,
        .inner = inner,
        .inner_construction = inner_construction,
        .inner_effect = inner_effect,
        .outer_cap = outer_cap,
        .state = state,
        .budget = ctx.budget,
        .construction = ctx.construction,
        .exportable = ctx.exportable,
        .outer = ctx.outer,
        .outer_effect = ctx.outer_effect,
        .permissions = ctx.permissions,
        .program = ctx.program,
        .site = ctx.site,
    });
}
fn recognizeInnerCapture(ctx: anytype) Error!?Shape {
    const inner_ctor = ctx.program.constructors[@intCast(ctx.inner_construction.immediate)];
    if (!@import("capture_reduction.zig").privateWorker(
        ctx.program,
        @intCast(ctx.inner_construction.immediate),
    )) return null;
    const inner_capture = ctx.program.scopes.captures[@intCast(inner_ctor.capture)];
    const inner_signature = ctx.program.schemas[@intCast(inner_ctor.schema)].internal.computation;
    if (inner_signature.use != .reusable or
        inner_capture.owned_regions.len != 0 or
        inner_capture.borrowed_regions.len != 0)
        return null;
    for (inner_signature.parameters[1..]) |schema| if (!wire(
        schema,
        ctx.permissions,
        ctx.exportable,
    )) return null;
    const inner_function = ctx.program.functions[@intCast(inner_ctor.function)];
    var captured_outer: ?p.Id = null;
    for (inner_capture.fields, ctx.inner_construction.operands, 0..) |schema, operand, index| {
        if (wire(schema, ctx.permissions, ctx.exportable)) continue;
        if (operand != ctx.outer_cap or captured_outer != null) return null;
        captured_outer = inner_function.inputs[index];
    }
    const captured = captured_outer orelse return null;
    const inner_cap = inner_function.inputs[inner_capture.fields.len];
    if (!try confinedBody(
        ctx.program,
        inner_ctor.function,
        captured,
        inner_cap,
        ctx.outer_effect,
        ctx.inner_effect,
        ctx.permissions,
        ctx.exportable,
        ctx.budget,
    )) return null;
    return .{
        .site = ctx.site,
        .outer_constructor = ctx.construction.immediate,
        .inner_constructor = ctx.inner_construction.immediate,
        .outer_handler = ctx.outer.handler,
        .inner_handler = ctx.inner.handler,
        .outer_entry = ctx.function.entry,
        .outer_return = ctx.inner.next.block,
        .outer_capability = ctx.outer_cap,
        .inner_capability = inner_cap,
        .captured_outer_capability = captured,
        .inner_state_at_caller = ctx.state,
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
    const program = try constructProgram(a, original, shape, &budget);
    keep = true;
    return .{ .arena = arena, .program = program, .shape = shape };
}
fn constructProgram(
    a: std.mem.Allocator,
    original: ir.Program,
    shape: Shape,
    budget: *Budget,
) Error!ir.Program {
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
    return constructSchemas(.{
        .a = a,
        .base_b = base_b,
        .base_f = base_f,
        .base_s = base_s,
        .blocks = blocks,
        .budget = budget,
        .effects = effects,
        .entry = entry,
        .functions = functions,
        .handled = handled,
        .ic = ic,
        .identity_returns = identity_returns,
        .ih = ih,
        .inner = inner,
        .is = is,
        .oc = oc,
        .of = of,
        .oh = oh,
        .original = original,
        .os = os,
        .outer = outer,
        .return_blocks = return_blocks,
        .schemas = schemas,
        .shape = shape,
        .site = site,
        .states = states,
    });
}
fn constructSchemas(ctx: anytype) Error!ir.Program {
    var bound: std.ArrayList(p.Id) = .empty;
    for ([_]p.Id{
        ctx.oh.clauses[0].resumption,
        ctx.ih.clauses[0].resumption,
    }) |id| for (ctx.original.schemas[@intCast(id)].internal.resumption.capture_bound) |schema| {
        try ctx.budget.take(1);
        if (std.mem.indexOfScalar(
            p.Id,
            bound.items,
            schema,
        ) ==
            null)
            try bound.append(
                ctx.a,
                schema,
            );
    };
    for ([_]p.Id{
        ctx.states[0],
        ctx.states[1],
        ctx.oh.input,
        ctx.os.parameters[0],
        ctx.is.parameters[0],
    }) |schema| {
        if (std.mem.indexOfScalar(
            p.Id,
            bound.items,
            schema,
        ) ==
            null)
            try bound.append(
                ctx.a,
                schema,
            );
    }
    const capture_bound = try bound.toOwnedSlice(ctx.a);
    for ([_]ir.Clause{ ctx.oh.clauses[0], ctx.ih.clauses[0] }, 0..) |clause, index| {
        var signature = ctx.original.schemas[@intCast(clause.resumption)].internal.resumption;
        signature.handled = ctx.handled;
        signature.effects = &.{};
        signature.escaping = &.{};
        signature.capture_bound = capture_bound;
        ctx.schemas[ctx.base_s + index] = .{ .internal = .{ .resumption = signature } };
    }
    const parameters = try ctx.a.alloc(p.Id, ctx.os.parameters.len + 1);
    parameters[0] = ctx.os.parameters[0];
    parameters[1] = ctx.is.parameters[0];
    @memcpy(parameters[2..], ctx.os.parameters[1..]);
    var body_type = ctx.os;
    body_type.parameters = parameters;
    body_type.effects = ctx.effects;
    ctx.schemas[ctx.base_s + 2] = .{ .internal = .{ .computation = body_type } };
    return constructBody(ctx);
}
fn constructBody(ctx: anytype) Error!ir.Program {
    // The confined inner closure is gone. Its non-input temporary is now the
    // second installation capability; no extra activation slot is needed.
    const body_slots = try ctx.a.dupe(p.Id, ctx.of.layout.slots);
    body_slots[@intCast(ctx.inner.body)] = ctx.is.parameters[0];
    const capture_count = ctx.original.scopes.captures[@intCast(ctx.oc.capture)].fields.len;
    const inputs = try ctx.a.alloc(p.Id, ctx.of.inputs.len + 1);
    @memcpy(inputs[0 .. capture_count + 1], ctx.of.inputs[0 .. capture_count + 1]);
    inputs[capture_count + 1] = ctx.inner.body;
    @memcpy(inputs[capture_count + 2 ..], ctx.of.inputs[capture_count + 1 ..]);
    ctx.functions[ctx.base_f] = ctx.of;
    ctx.functions[ctx.base_f].entry = ctx.base_b;
    ctx.functions[ctx.base_f].inputs = inputs;
    ctx.functions[ctx.base_f].layout.slots = body_slots;
    ctx.functions[ctx.base_f].effects = ctx.effects;
    const captures_at_site = ctx.entry.instructions[0].operands;
    const body_arguments = try ctx.a.alloc(
        p.Id,
        captures_at_site.len +
            ctx.inner.arguments.len +
            1,
    );
    @memcpy(body_arguments[0..captures_at_site.len], captures_at_site);
    body_arguments[captures_at_site.len] = ctx.inner.body;
    @memcpy(body_arguments[captures_at_site.len + 1 ..], ctx.inner.arguments);
    var next = ctx.inner.next;
    next.block = ctx.base_b + 1;
    ctx.blocks[ctx.base_b] = ctx.entry;
    ctx.blocks[ctx.base_b].function = ctx.base_f;
    ctx.blocks[ctx.base_b].instructions = &.{};
    ctx.blocks[ctx.base_b].terminator = .{ .call = .{
        .function = ctx.ic.function,
        .arguments = body_arguments,
        .next = next,
    } };
    ctx.blocks[ctx.base_b + 1] = ctx.original.blocks[@intCast(ctx.shape.outer_return)];
    ctx.blocks[ctx.base_b + 1].function = ctx.base_f;
    return constructReturns(ctx);
}
fn constructReturns(ctx: anytype) Error!ir.Program {
    const return_slots = try ctx.a.dupe(
        p.Id,
        if (ctx.identity_returns)
            &.{ ctx.states[0], ctx.states[1], ctx.oh.input }
        else
            &.{ ctx.states[0], ctx.states[1], ctx.oh.input, ctx.oh.input, ctx.oh.input },
    );
    ctx.functions[ctx.base_f + 1] = .{
        .entry = ctx.base_b + 2,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = return_slots },
        .result = ctx.oh.answer,
    };
    if (ctx.identity_returns) ctx.blocks[ctx.base_b + 2] = .{
        .function = ctx.base_f + 1,
        .instructions = &.{},
        .terminator = .{ .return_value = 2 },
    } else {
        ctx.blocks[ctx.base_b + 2] = .{
            .function = ctx.base_f + 1,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = ctx.ih.return_function,
                .arguments = &.{ 1, 2 },
                .next = .{
                    .block = ctx.base_b + 3,
                    .assignments = &.{.{ .destination = 3, .source = .returned }},
                },
            } },
        };
        ctx.blocks[ctx.base_b + 3] = .{
            .function = ctx.base_f + 1,
            .instructions = &.{},
            .terminator = .{ .call = .{
                .function = ctx.oh.return_function,
                .arguments = &.{ 0, 3 },
                .next = .{
                    .block = ctx.base_b + 4,
                    .assignments = &.{.{ .destination = 4, .source = .returned }},
                },
            } },
        };
        ctx.blocks[ctx.base_b + 4] = .{
            .function = ctx.base_f + 1,
            .instructions = &.{},
            .terminator = .{ .return_value = 4 },
        };
    }
    return constructHandler(ctx);
}
fn constructHandler(ctx: anytype) Error!ir.Program {
    const clauses = try ctx.a.alloc(ir.Clause, 2);
    for ([_]ir.Clause{ ctx.oh.clauses[0], ctx.ih.clauses[0] }, 0..) |clause, index| {
        const slots = try ctx.a.dupe(
            p.Id,
            &.{
                ctx.states[0],
                ctx.states[1],
                ctx.original.effects[
                    @intCast(
                        clause.effect,
                    )
                ].payload,
            },
        );
        ctx.functions[ctx.base_f + 2 + index] = .{
            .entry = ctx.base_b + 2 + ctx.return_blocks + index,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = slots },
            .result = ctx.states[index],
        };
        ctx.blocks[ctx.base_b + 2 + ctx.return_blocks + index] = .{
            .function = ctx.base_f + 2 + index,
            .instructions = &.{},
            .terminator = .{ .return_value = index },
        };
        clauses[index] = clause;
        clauses[index].function = ctx.base_f + 2 + index;
        clauses[index].resumption = ctx.base_s + index;
    }
    const handlers = try ctx.a.alloc(ir.Handler, ctx.original.handlers.len + 1);
    @memcpy(handlers[0..ctx.original.handlers.len], ctx.original.handlers);
    handlers[ctx.original.handlers.len] = .{
        .mode = .deep,
        .input = ctx.oh.input,
        .answer = ctx.oh.answer,
        .return_function = ctx.base_f + 1,
        .clauses = clauses,
        .state = ctx.states,
    };
    const constructors = try ctx.a.alloc(p.Constructor, ctx.original.constructors.len + 1);
    @memcpy(constructors[0..ctx.original.constructors.len], ctx.original.constructors);
    constructors[ctx.original.constructors.len] = .{
        .function = ctx.base_f,
        .capture = ctx.oc.capture,
        .schema = ctx.base_s + 2,
    };
    const caller = &ctx.functions[@intCast(ctx.site.function)];
    const caller_slots = try ctx.a.dupe(p.Id, caller.layout.slots);
    caller_slots[@intCast(ctx.outer.body)] = ctx.base_s + 2;
    caller.layout.slots = caller_slots;
    const instructions = try ctx.a.dupe(ir.Instruction, ctx.site.instructions);
    instructions[instructions.len - 1].immediate = ctx.original.constructors.len;
    ctx.blocks[ctx.shape.site].instructions = instructions;
    ctx.blocks[ctx.shape.site].terminator.handle.handler = ctx.original.handlers.len;
    ctx.blocks[ctx.shape.site].terminator.handle.state = try ctx.a.dupe(
        p.Id,
        &.{ ctx.outer.state[0], ctx.shape.inner_state_at_caller },
    );
    var program = ctx.original;
    program.schemas = ctx.schemas;
    program.functions = ctx.functions;
    program.blocks = ctx.blocks;
    program.handlers = handlers;
    program.constructors = constructors;
    return program;
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
    return validateRecords(.{
        .a = a,
        .candidate = candidate,
        .original = original,
        .proof = &proof,
        .shape = shape,
        .site = site,
    });
}
fn validateRecords(ctx: anytype) Error!void {
    const old_site = ctx.original.blocks[ctx.site];
    const outer = old_site.terminator.handle;
    const oh = ctx.original.handlers[@intCast(ctx.shape.outer_handler)];
    const ih = ctx.original.handlers[@intCast(ctx.shape.inner_handler)];
    const oc = ctx.original.constructors[@intCast(ctx.shape.outer_constructor)];
    const ic = ctx.original.constructors[@intCast(ctx.shape.inner_constructor)];
    const of = ctx.original.functions[@intCast(oc.function)];
    const old_entry = ctx.original.blocks[@intCast(ctx.shape.outer_entry)];
    const inner = old_entry.terminator.handle;
    const os = ctx.original.schemas[@intCast(oc.schema)].internal.computation;
    const is = ctx.original.schemas[@intCast(ic.schema)].internal.computation;
    const f = ctx.original.functions.len;
    const b = ctx.original.blocks.len;
    const s = ctx.original.schemas.len;
    const identity_returns = literalIdentity(
        ctx.original,
        oh,
    ) and
        literalIdentity(
            ctx.original,
            ih,
        );
    const n: usize = if (identity_returns) 1 else 3;
    if (ctx.candidate.functions.len != f + 4 or
        ctx.candidate.blocks.len != b + 4 + n or
        ctx.candidate.schemas.len != s + 3 or
        ctx.candidate.handlers.len != ctx.original.handlers.len + 1 or
        ctx.candidate.constructors.len != ctx.original.constructors.len + 1)
        return error.InvalidReaderFusion;
    try validateUnchangedRecords(ctx);
    return validateOriginalFunctions(.{
        .b = b,
        .f = f,
        .ic = ic,
        .identity_returns = identity_returns,
        .ih = ih,
        .inner = inner,
        .is = is,
        .n = n,
        .oc = oc,
        .of = of,
        .oh = oh,
        .old_entry = old_entry,
        .old_site = old_site,
        .os = os,
        .outer = outer,
        .s = s,
        .a = ctx.a,
        .candidate = ctx.candidate,
        .original = ctx.original,
        .proof = ctx.proof,
        .shape = ctx.shape,
        .site = ctx.site,
    });
}
fn validateUnchangedRecords(ctx: anytype) Error!void {
    var rest = ctx.candidate;
    rest.functions = ctx.original.functions;
    rest.blocks = ctx.original.blocks;
    rest.schemas = ctx.original.schemas;
    rest.handlers = ctx.original.handlers;
    rest.constructors = ctx.original.constructors;
    try ctx.proof.*.require(ir.Program, ctx.original, rest);
    try ctx.proof.*.require(
        []const p.Schema,
        ctx.original.schemas,
        ctx.candidate.schemas[0..ctx.original.schemas.len],
    );
    try ctx.proof.*.require(
        []const ir.Handler,
        ctx.original.handlers,
        ctx.candidate.handlers[0..ctx.original.handlers.len],
    );
    try ctx.proof.*.require(
        []const p.Constructor,
        ctx.original.constructors,
        ctx.candidate.constructors[0..ctx.original.constructors.len],
    );
}
fn validateOriginalFunctions(ctx: anytype) Error!void {
    for (ctx.original.functions, ctx.candidate.functions[0..ctx.f], 0..) |old, new, id| {
        if (id != ctx.old_site.function) {
            try ctx.proof.*.require(ir.Function, old, new);
            continue;
        }
        var metadata = new;
        metadata.layout = old.layout;
        try ctx.proof.*.require(ir.Function, old, metadata);
        if (new.layout.slots.len != old.layout.slots.len) return error.InvalidReaderFusion;
        for (
            old.layout.slots,
            new.layout.slots,
            0..,
        ) |old_schema, new_schema, slot|
            if (new_schema != (if (slot == ctx.outer.body)
                ctx.s + 2
            else
                old_schema))
                return error.InvalidReaderFusion;
    }
    return validateOriginalBlocks(ctx);
}
fn validateOriginalBlocks(ctx: anytype) Error!void {
    for (ctx.original.blocks, ctx.candidate.blocks[0..ctx.b], 0..) |old, new, id| {
        if (id != ctx.site) {
            try ctx.proof.*.require(ir.Block, old, new);
            continue;
        }
        var metadata = new;
        metadata.instructions = old.instructions;
        metadata.terminator = old.terminator;
        try ctx.proof.*.require(ir.Block, old, metadata);
        if (new.instructions.len != old.instructions.len or
            new.terminator != .handle)
            return error.InvalidReaderFusion;
        for (old.instructions, new.instructions, 0..) |old_op, new_op, index| {
            var restored = new_op;
            if (index + 1 == old.instructions.len) {
                if (new_op.immediate !=
                    ctx.original.constructors.len)
                    return error.InvalidReaderFusion;
                restored.immediate = old_op.immediate;
            }
            try ctx.proof.*.require(ir.Instruction, old_op, restored);
        }
        var restored = new.terminator.handle;
        if (restored.handler != ctx.original.handlers.len) return error.InvalidReaderFusion;
        try ctx.proof.*.require(
            []const p.Id,
            &.{ ctx.outer.state[0], ctx.shape.inner_state_at_caller },
            restored.state,
        );
        restored.handler = ctx.outer.handler;
        restored.state = ctx.outer.state;
        try ctx.proof.*.require(@TypeOf(ctx.outer), ctx.outer, restored);
    }
    return validateResumptions(ctx);
}
fn validateResumptions(ctx: anytype) Error!void {
    const handled = [_]p.Id{ ctx.oh.clauses[0].effect, ctx.ih.clauses[0].effect };
    const states = [_]p.Id{ ctx.oh.state[0], ctx.ih.state[0] };
    var allowed_bound: std.ArrayList(p.Id) = .empty;
    for ([_]p.Id{
        ctx.oh.clauses[0].resumption,
        ctx.ih.clauses[0].resumption,
    }) |id| for (ctx.original.schemas[@intCast(id)].internal.resumption.capture_bound) |schema| {
        if (std.mem.indexOfScalar(
            p.Id,
            allowed_bound.items,
            schema,
        ) == null) try allowed_bound.append(ctx.a, schema);
    };
    for ([_]p.Id{
        states[0],
        states[1],
        ctx.oh.input,
        ctx.os.parameters[0],
        ctx.is.parameters[0],
    }) |schema| {
        if (std.mem.indexOfScalar(
            p.Id,
            allowed_bound.items,
            schema,
        ) == null) try allowed_bound.append(ctx.a, schema);
    }
    for ([_]ir.Clause{ ctx.oh.clauses[0], ctx.ih.clauses[0] }, 0..) |clause, index| {
        const schema = ctx.candidate.schemas[ctx.s + index];
        if (schema != .internal or schema.internal != .resumption) return error.InvalidReaderFusion;
        var signature = schema.internal.resumption;
        const old = ctx.original.schemas[@intCast(clause.resumption)].internal.resumption;
        try ctx.proof.*.require([]const p.Id, &handled, signature.handled);
        try ctx.proof.*.require([]const p.Id, allowed_bound.items, signature.capture_bound);
        if (signature.effects.len != 0 or
            signature.escaping.len != 0)
            return error.InvalidReaderFusion;
        signature.handled = old.handled;
        signature.effects = old.effects;
        signature.escaping = old.escaping;
        signature.capture_bound = old.capture_bound;
        try ctx.proof.*.require(p.ResumptionType, old, signature);
    }
    return validateBodySchema(.{
        .handled = handled,
        .states = states,
        .b = ctx.b,
        .candidate = ctx.candidate,
        .f = ctx.f,
        .ic = ctx.ic,
        .identity_returns = ctx.identity_returns,
        .ih = ctx.ih,
        .inner = ctx.inner,
        .is = ctx.is,
        .n = ctx.n,
        .oc = ctx.oc,
        .of = ctx.of,
        .oh = ctx.oh,
        .old_entry = ctx.old_entry,
        .original = ctx.original,
        .os = ctx.os,

        .proof = ctx.proof,
        .s = ctx.s,
        .shape = ctx.shape,
    });
}
fn validateBodySchema(ctx: anytype) Error!void {
    const body_schema = ctx.candidate.schemas[ctx.s + 2];
    if (body_schema != .internal or
        body_schema.internal != .computation)
        return error.InvalidReaderFusion;
    var body_type = body_schema.internal.computation;
    if (body_type.parameters.len != ctx.os.parameters.len + 1 or
        body_type.parameters[0] != ctx.os.parameters[0] or
        body_type.parameters[1] != ctx.is.parameters[0])
        return error.InvalidReaderFusion;
    try ctx.proof.*.require([]const p.Id, ctx.os.parameters[1..], body_type.parameters[2..]);
    // Candidate admission has independently established canonical row order.
    // Check the original effect set without using the constructor's ordering.
    try ctx.proof.*.require(usize, 2, body_type.effects.len);
    for (ctx.handled) |effect| try ctx.proof.*.require(
        bool,
        true,
        std.mem.indexOfScalar(p.Id, body_type.effects, effect) != null,
    );
    body_type.parameters = ctx.os.parameters;
    body_type.effects = ctx.os.effects;
    try ctx.proof.*.require(p.ComputationType, ctx.os, body_type);
    return validateBodyFunction(ctx);
}
fn validateBodyFunction(ctx: anytype) Error!void {
    const body = ctx.candidate.functions[ctx.f];
    var body_metadata = body;
    body_metadata.entry = ctx.of.entry;
    body_metadata.inputs = ctx.of.inputs;
    body_metadata.layout = ctx.of.layout;
    body_metadata.effects = ctx.of.effects;
    try ctx.proof.*.require(ir.Function, ctx.of, body_metadata);
    const captures = ctx.original.scopes.captures[@intCast(ctx.oc.capture)].fields.len;
    if (body.entry != ctx.b or
        body.inputs.len != ctx.of.inputs.len + 1 or
        body.inputs[captures + 1] != ctx.inner.body or
        body.layout.slots.len != ctx.of.layout.slots.len)
        return error.InvalidReaderFusion;
    try ctx.proof.*.require(
        []const p.Id,
        ctx.of.inputs[0 .. captures +
            1],
        body.inputs[0 .. captures +
            1],
    );
    try ctx.proof.*.require(
        []const p.Id,
        ctx.of.inputs[captures +
            1 ..],
        body.inputs[captures +
            2 ..],
    );
    for (ctx.of.layout.slots, body.layout.slots, 0..) |old_schema, new_schema, slot| {
        try ctx.proof.*.require(
            p.Id,
            if (slot == ctx.inner.body) ctx.is.parameters[0] else old_schema,
            new_schema,
        );
    }
    try ctx.proof.*.require(
        []const p.Id,
        ctx.candidate.schemas[ctx.s + 2].internal.computation.effects,
        body.effects,
    );
    return validateBodyBlocks(ctx);
}
fn validateBodyBlocks(ctx: anytype) Error!void {
    const new_entry = ctx.candidate.blocks[ctx.b];
    var entry_metadata = new_entry;
    entry_metadata.function = ctx.old_entry.function;
    entry_metadata.instructions = ctx.old_entry.instructions;
    entry_metadata.terminator = ctx.old_entry.terminator;
    try ctx.proof.*.require(ir.Block, ctx.old_entry, entry_metadata);
    if (new_entry.function != ctx.f or
        new_entry.instructions.len != 0 or
        new_entry.terminator != .call)
        return error.InvalidReaderFusion;
    const call = new_entry.terminator.call;
    const original_captures = ctx.old_entry.instructions[0].operands;
    if (call.function != ctx.ic.function or
        call.arguments.len != original_captures.len + ctx.inner.arguments.len + 1 or
        call.arguments[original_captures.len] != ctx.inner.body or
        call.next.block != ctx.b + 1)
        return error.InvalidReaderFusion;
    try ctx.proof.*.require(
        []const p.Id,
        original_captures,
        call.arguments[0..original_captures.len],
    );
    try ctx.proof.*.require(
        []const p.Id,
        ctx.inner.arguments,
        call.arguments[original_captures.len +
            1 ..],
    );
    try ctx.proof.*.require(
        []const ir.Assignment,
        ctx.inner.next.assignments,
        call.next.assignments,
    );
    var returned_block = ctx.candidate.blocks[ctx.b + 1];
    if (returned_block.function != ctx.f) return error.InvalidReaderFusion;
    returned_block.function = ctx.oc.function;
    try ctx.proof.*.require(
        ir.Block,
        ctx.original.blocks[
            @intCast(
                ctx.shape.outer_return,
            )
        ],
        returned_block,
    );
    return validateReturns(ctx);
}
fn validateReturns(ctx: anytype) Error!void {
    const return_slots: []const p.Id = if (ctx.identity_returns) &.{
        ctx.states[0],
        ctx.states[1],
        ctx.oh.input,
    } else &.{ ctx.states[0], ctx.states[1], ctx.oh.input, ctx.oh.input, ctx.oh.input };
    try ctx.proof.*.require(
        ir.Function,
        .{
            .entry = ctx.b + 2,
            .inputs = &.{ 0, 1, 2 },
            .layout = .{ .slots = return_slots },
            .result = ctx.oh.answer,
        },
        ctx.candidate.functions[ctx.f + 1],
    );
    return validateReturnBlocks(ctx);
}
fn validateReturnBlocks(ctx: anytype) Error!void {
    if (ctx.identity_returns) try ctx.proof.*.require(
        ir.Block,
        .{ .function = ctx.f + 1, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        ctx.candidate.blocks[ctx.b + 2],
    ) else {
        try ctx.proof.*.require(
            ir.Block,
            .{
                .function = ctx.f + 1,
                .instructions = &.{},
                .terminator = .{ .call = .{
                    .function = ctx.ih.return_function,
                    .arguments = &.{ 1, 2 },
                    .next = .{
                        .block = ctx.b + 3,
                        .assignments = &.{.{ .destination = 3, .source = .returned }},
                    },
                } },
            },
            ctx.candidate.blocks[ctx.b + 2],
        );
        try ctx.proof.*.require(
            ir.Block,
            .{
                .function = ctx.f + 1,
                .instructions = &.{},
                .terminator = .{ .call = .{
                    .function = ctx.oh.return_function,
                    .arguments = &.{ 0, 3 },
                    .next = .{
                        .block = ctx.b + 4,
                        .assignments = &.{.{ .destination = 4, .source = .returned }},
                    },
                } },
            },
            ctx.candidate.blocks[ctx.b + 3],
        );
        try ctx.proof.*.require(
            ir.Block,
            .{ .function = ctx.f + 1, .instructions = &.{}, .terminator = .{ .return_value = 4 } },
            ctx.candidate.blocks[ctx.b + 4],
        );
    }
    return validateClauses(ctx);
}

fn validateClauses(ctx: anytype) Error!void {
    var expected_clauses: [2]ir.Clause = undefined;
    for ([_]ir.Clause{ ctx.oh.clauses[0], ctx.ih.clauses[0] }, 0..) |clause, index| {
        try ctx.proof.*.require(
            ir.Function,
            .{
                .entry = ctx.b + 2 + ctx.n + index,
                .inputs = &.{ 0, 1, 2 },
                .layout = .{ .slots = &.{
                    ctx.states[0],
                    ctx.states[1],
                    ctx.original.effects[@intCast(clause.effect)].payload,
                } },
                .result = ctx.states[index],
            },
            ctx.candidate.functions[ctx.f + 2 + index],
        );
        try ctx.proof.*.require(
            ir.Block,
            .{
                .function = ctx.f + 2 + index,
                .instructions = &.{},
                .terminator = .{ .return_value = index },
            },
            ctx.candidate.blocks[ctx.b + 2 + ctx.n + index],
        );
        expected_clauses[index] = clause;
        expected_clauses[index].function = ctx.f + 2 + index;
        expected_clauses[index].resumption = ctx.s + index;
    }
    try ctx.proof.*.require(
        ir.Handler,
        .{
            .mode = .deep,
            .input = ctx.oh.input,
            .answer = ctx.oh.answer,
            .return_function = ctx.f + 1,
            .clauses = &expected_clauses,
            .state = &ctx.states,
        },
        ctx.candidate.handlers[ctx.original.handlers.len],
    );
    try ctx.proof.*.require(
        p.Constructor,
        .{ .function = ctx.f, .capture = ctx.oc.capture, .schema = ctx.s + 2 },
        ctx.candidate.constructors[ctx.original.constructors.len],
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
