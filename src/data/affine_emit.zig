// Copyright (c) 2026 Boundary contributors. MIT license.
//! Untrusted affine candidate construction; never a production acceptance gate.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const census = @import("affine_capture.zig");
const extract = @import("affine_extract.zig");
const space = @import("affine_space.zig");
pub const Error = census.Error || error{UnrepresentableAffineObservation};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    constructor: ?usize,
    basis: []const space.Row,
    input_bias: []const u64,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Builder = struct {
    a: std.mem.Allocator,
    schema: p.Id,
    width: usize,
    slots: *std.ArrayList(p.Id),
    literals: *std.ArrayList(p.Literal),
    operations: std.ArrayList(ir.Instruction) = .empty,
    budget: *space.Budget,
    input_bias: []const u64,
    fn append(
        self: *Builder,
        opcode: p.Opcode,
        operands: []const p.Id,
        immediate: p.Id,
    ) Error!p.Id {
        try self.budget.charge();
        const destination = self.slots.items.len;
        try self.slots.append(self.a, self.schema);
        try self.operations.append(
            self.a,
            .{
                .destination = destination,
                .opcode = opcode,
                .operands = try self.a.dupe(p.Id, operands),
                .immediate = immediate,
            },
        );
        return destination;
    }
    fn constant(self: *Builder, value: u64) Error!p.Id {
        const bytes = try self.a.alloc(u8, self.width);
        for (bytes, 0..) |*byte, i| byte.* = @truncate(value >> @intCast(8 * i));
        const id = self.literals.items.len;
        try self.literals.append(self.a, .{ .schema = self.schema, .bytes = bytes });
        return self.append(.constant, &.{}, id);
    }
    const Accumulator = struct { value: ?p.Id = null, scratch: ?p.Id = null };
    fn combine(self: *Builder, accumulator: *Accumulator, value: p.Id) Error!void {
        const previous = accumulator.value orelse {
            accumulator.value = value;
            return;
        };
        if (accumulator.scratch) |slot| {
            // This scratch belongs only to this expression. Other basis rows
            // and edge outputs retain distinct slots until their parallel use.
            try self.budget.charge();
            try self.operations.append(
                self.a,
                .{
                    .destination = slot,
                    .opcode = .integer_bit_xor,
                    .operands = try self.a.dupe(p.Id, &.{ previous, value }),
                },
            );
            accumulator.value = slot;
        } else {
            const slot = try self.append(.integer_bit_xor, &.{ previous, value }, 0);
            accumulator.scratch = slot;
            accumulator.value = slot;
        }
    }
    fn expression(
        self: *Builder,
        value: extract.Expression,
        basis: *const space.Space,
        summary: []const p.Id,
        inputs: []const p.Id,
    ) Error!p.Id {
        const coefficients = (try basis.coefficients(
            value.state,
            self.budget,
        )) orelse return error.UnrepresentableAffineObservation;
        var result: Accumulator = .{};
        for (summary, 0..) |slot, i| if (coefficients & space.coordinate(i) != 0) {
            try self.combine(&result, slot);
        };
        for (inputs, 0..) |slot, i| if (value.input & space.coordinate(i) != 0) {
            try self.combine(&result, slot);
        };
        var offset = value.constant;
        for (self.input_bias, 0..) |bias, i| if (value.input & space.coordinate(i) != 0) {
            offset ^= bias;
        };
        if (offset != 0) try self.combine(&result, try self.constant(offset));
        return result.value orelse try self.constant(0);
    }
    fn biased(self: *Builder, slot: p.Id, bias: u64) Error!p.Id {
        return if (bias == 0) slot else self.append(
            .integer_bit_xor,
            &.{ slot, try self.constant(bias) },
            0,
        );
    }
    fn original(self: *Builder, row: space.Row, operands: []const p.Id) Error!p.Id {
        var result: Accumulator = .{};
        for (operands, 0..) |slot, i| if (row & space.coordinate(i) != 0) {
            try self.combine(&result, slot);
        };
        return result.value orelse try self.constant(0);
    }
};
fn remap(
    builder: *Builder,
    slot: p.Id,
    values: []const ?extract.Expression,
    basis: *const space.Space,
    summary: []const p.Id,
    inputs: []const p.Id,
) Error!p.Id {
    return if (values[@intCast(slot)]) |value| builder.expression(
        value,
        basis,
        summary,
        inputs,
    ) else slot;
}

fn rewriteEdge(
    builder: *Builder,
    edge: ir.Edge,
    worker: ir.Function,
    values: []const ?extract.Expression,
    basis: *const space.Space,
    basis_rows: []const space.Row,
    dimension: usize,
    summary: []const p.Id,
) Error!ir.Edge {
    if (edge.assignments.len == 0) return edge;
    const state = (try @import("affine_edges.zig").state(
        builder.a,
        worker.inputs[0..dimension],
        values,
        edge,
        builder.budget,
    )) orelse return error.UnrepresentableAffineObservation;
    var assignments: std.ArrayList(ir.Assignment) = .empty;
    for (basis_rows, summary) |row, destination| {
        var expression: extract.Expression = .{};
        for (state, 0..) |value, i| if (row & space.coordinate(i) != 0) {
            expression = expression.xor(value);
        };
        const slot = try builder.expression(expression, basis, summary, worker.inputs[dimension..]);
        if (slot != destination) try assignments.append(
            builder.a,
            .{ .destination = destination, .source = .{ .slot = slot } },
        );
    }
    for (edge.assignments) |assignment| {
        if (std.mem.indexOfScalar(
            p.Id,
            worker.inputs[0..dimension],
            assignment.destination,
        ) != null) continue;
        var replacement = assignment;
        if (assignment.source == .slot) replacement.source.slot = try remap(
            builder,
            assignment.source.slot,
            values,
            basis,
            summary,
            worker.inputs[dimension..],
        );
        try assignments.append(builder.a, replacement);
    }
    return .{ .block = edge.block, .assignments = try assignments.toOwnedSlice(builder.a) };
}

fn appliesConstructor(program: ir.Program, function: p.Id, slot: p.Id, constructor: usize) bool {
    for (program.blocks) |block| {
        if (block.function != function) continue;
        for (block.instructions) |op|
            if (op.destination == slot and
                op.opcode == .computation and
                op.immediate == constructor)
                return true;
    }
    return false;
}

pub const Basis = enum { observations, canonical };
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    constructor_id: usize,
    work_limit: u64,
) Error!?Candidate {
    return constructBasis(allocator, original, constructor_id, work_limit, .observations);
}
pub fn constructBasis(
    allocator: std.mem.Allocator,
    original: ir.Program,
    constructor_id: usize,
    work_limit: u64,
    choice: Basis,
) Error!?Candidate {
    return constructTarget(allocator, original, .{ .capture = constructor_id }, work_limit, choice);
}
pub fn constructTarget(
    allocator: std.mem.Allocator,
    original: ir.Program,
    target: census.Target,
    work_limit: u64,
    choice: Basis,
) Error!?Candidate {
    var plan = (try census.analyzeTarget(
        allocator,
        original,
        target,
        work_limit,
    )) orelse return null;
    const constructor_id = plan.constructor;
    defer plan.deinit();
    if (plan.basis.len == plan.dimension) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var budget: space.Budget = .{ .remaining = work_limit };
    var basis = try space.Space.init(plan.dimension);
    for (plan.basis) |row| _ = try basis.insert(row, &budget);
    if (choice == .canonical) {
        basis = try basis.canonical(&budget);
        var buffer: [space.max_dimension]space.Row = undefined;
        plan.basis = try plan.arena.allocator().dupe(space.Row, basis.rows(&buffer));
    }
    const functions = try a.dupe(ir.Function, original.functions);
    const blocks = try a.dupe(ir.Block, original.blocks);
    const constructors = try a.dupe(p.Constructor, original.constructors);
    const captures = try a.alloc(
        p.Capture,
        original.scopes.captures.len + @intFromBool(constructor_id != null),
    );
    @memcpy(captures[0..original.scopes.captures.len], original.scopes.captures);
    if (constructor_id) |id| {
        const ctor = &constructors[id];
        var capture = original.scopes.captures[@intCast(ctor.capture)];
        const fields = try a.alloc(p.Id, plan.basis.len);
        @memset(fields, plan.schema);
        capture.fields = fields;
        captures[original.scopes.captures.len] = capture;
        ctor.capture = original.scopes.captures.len;
    }
    const worker = original.functions[@intCast(plan.worker)];
    const input_slots = try a.alloc(p.Id, worker.inputs.len - plan.dimension + plan.basis.len);
    @memcpy(input_slots[0..plan.basis.len], worker.inputs[0..plan.basis.len]);
    @memcpy(input_slots[plan.basis.len..], worker.inputs[plan.dimension..]);
    functions[@intCast(plan.worker)].inputs = input_slots;
    const layouts = try a.alloc(std.ArrayList(p.Id), functions.len);
    for (layouts, original.functions) |*layout, function| {
        layout.* = .empty;
        try layout.appendSlice(a, function.layout.slots);
    }
    var literals: std.ArrayList(p.Literal) = .empty;
    try literals.appendSlice(a, original.constants);
    for (original.blocks, blocks) |block, *out| {
        var builder: Builder = .{
            .a = a,
            .schema = plan.schema,
            .width = extract.unsignedWidth(original.schemas[@intCast(plan.schema)]).?,
            .slots = &layouts[@intCast(block.function)],
            .literals = &literals,
            .budget = &budget,
            .input_bias = plan.input_bias,
        };
        if (block.function != plan.worker) {
            for (block.instructions) |op| {
                var replacement = op;
                if (constructor_id != null and
                    op.opcode == .computation and
                    op.immediate == constructor_id.?)
                {
                    const operands = try a.alloc(p.Id, plan.basis.len);
                    for (
                        plan.basis,
                        operands,
                    ) |row, *operand| operand.* = try builder.original(row, op.operands);
                    replacement.operands = operands;
                }
                try builder.operations.append(a, replacement);
            }
            if (block.terminator == .call and block.terminator.call.function == plan.worker) {
                const call = block.terminator.call;
                const arguments = try a.alloc(p.Id, input_slots.len);
                for (
                    plan.basis,
                    arguments[0..plan.basis.len],
                ) |row, *argument| argument.* = try builder.original(
                    row,
                    call.arguments[0..plan.dimension],
                );
                for (
                    call.arguments[plan.dimension..],
                    arguments[plan.basis.len..],
                    plan.input_bias,
                ) |slot, *argument, bias| argument.* = try builder.biased(slot, bias);
                out.terminator.call.arguments = arguments;
            }
            if (constructor_id != null and block.terminator == .apply and appliesConstructor(
                original,
                block.function,
                block.terminator.apply.computation,
                constructor_id.?,
            )) {
                const arguments = try a.dupe(p.Id, block.terminator.apply.arguments);
                for (
                    arguments,
                    plan.input_bias,
                ) |*argument, bias| argument.* = try builder.biased(argument.*, bias);
                out.terminator.apply.arguments = arguments;
            }
        } else {
            const values = try a.alloc(?extract.Expression, worker.layout.slots.len);
            @memset(values, null);
            for (worker.inputs, 0..) |slot, index| {
                if (index < plan.dimension) values[
                    @intCast(slot)
                ] = .{ .state = space.coordinate(index) } else if (worker.layout.slots[
                    @intCast(slot)
                ] == plan.schema) values[
                    @intCast(slot)
                ] = .{ .input = space.coordinate(index - plan.dimension) };
            }
            const summary = input_slots[0..plan.basis.len];
            const dynamic = worker.inputs[plan.dimension..];
            for (block.instructions) |op| {
                const value = try extract.instruction(
                    original,
                    worker,
                    op,
                    values,
                    plan.schema,
                    &budget,
                );
                if (value == null) {
                    var replacement = op;
                    const operands = try a.dupe(p.Id, op.operands);
                    for (operands) |*operand| operand.* = try remap(
                        &builder,
                        operand.*,
                        values,
                        &basis,
                        summary,
                        dynamic,
                    );
                    replacement.operands = operands;
                    try builder.operations.append(a, replacement);
                }
                values[@intCast(op.destination)] = value;
            }
            switch (block.terminator) {
                .return_value => |slot| out.terminator.return_value = try remap(
                    &builder,
                    slot,
                    values,
                    &basis,
                    summary,
                    dynamic,
                ),
                .branch => |branch| {
                    out.terminator.branch.condition = try remap(
                        &builder,
                        branch.condition,
                        values,
                        &basis,
                        summary,
                        dynamic,
                    );
                    out.terminator.branch.when_true = try rewriteEdge(
                        &builder,
                        branch.when_true,
                        worker,
                        values,
                        &basis,
                        plan.basis,
                        plan.dimension,
                        summary,
                    );
                    out.terminator.branch.when_false = try rewriteEdge(
                        &builder,
                        branch.when_false,
                        worker,
                        values,
                        &basis,
                        plan.basis,
                        plan.dimension,
                        summary,
                    );
                },
                .call => |call| {
                    out.terminator.call.next = try rewriteEdge(
                        &builder,
                        call.next,
                        worker,
                        values,
                        &basis,
                        plan.basis,
                        plan.dimension,
                        summary,
                    );
                    if (call.function == plan.worker) {
                        const arguments = try a.alloc(p.Id, input_slots.len);
                        for (plan.basis, arguments[0..plan.basis.len]) |row, *argument| {
                            var value: extract.Expression = .{};
                            for (
                                call.arguments[0..plan.dimension],
                                0..,
                            ) |slot, i| if (row & space.coordinate(i) != 0) {
                                value = value.xor(values[@intCast(slot)].?);
                            };
                            argument.* = try builder.expression(value, &basis, summary, dynamic);
                        }
                        for (
                            call.arguments[plan.dimension..],
                            arguments[plan.basis.len..],
                            plan.input_bias,
                        ) |slot, *argument, bias| {
                            if (values[@intCast(slot)]) |value| {
                                var encoded = value;
                                encoded.constant ^= bias;
                                argument.* = try builder.expression(
                                    encoded,
                                    &basis,
                                    summary,
                                    dynamic,
                                );
                            } else argument.* = try builder.biased(slot, bias);
                        }
                        out.terminator.call.arguments = arguments;
                    } else {
                        const arguments = try a.dupe(p.Id, call.arguments);
                        for (arguments) |*argument| argument.* = try remap(
                            &builder,
                            argument.*,
                            values,
                            &basis,
                            summary,
                            dynamic,
                        );
                        out.terminator.call.arguments = arguments;
                    }
                },
                .jump => |edge| out.terminator.jump = try rewriteEdge(
                    &builder,
                    edge,
                    worker,
                    values,
                    &basis,
                    plan.basis,
                    plan.dimension,
                    summary,
                ),
                else => unreachable,
            }
        }
        out.instructions = try builder.operations.toOwnedSlice(a);
    }
    for (functions, layouts) |*function, layout| function.layout.slots = layout.items;
    var program = original;
    program.functions = functions;
    program.blocks = blocks;
    program.constructors = constructors;
    program.scopes.captures = captures;
    program.constants = try literals.toOwnedSlice(a);
    const owned_basis = try a.dupe(space.Row, plan.basis);
    const owned_bias = try a.dupe(u64, plan.input_bias);
    // Complete allocations before copying the arena's owning list head.
    return .{
        .arena = arena,
        .program = program,
        .constructor = constructor_id,
        .basis = owned_basis,
        .input_bias = owned_bias,
    };
}
