// Copyright (c) 2026 Boundary contributors. MIT license.
//! P13 private unfold law: (value, known_successor(state)) -> (value, state).
//! Only the original apply site calls the successor. Stopping cannot force it.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const admission = @import("admission.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || error{ InvalidUnfoldFusion, UnfoldFusionLimit };
pub const Options = struct { work_limit: usize = 10_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct {
    protocols_fused: usize = 0,
    construction_sites_removed: usize = 0,
    applications_direct: usize = 0,
    work_limit: bool = false,
};
const Budget = struct {
    left: usize,
    fn record(self: *@This(), comptime T: type, value: T) Error!void {
        if (self.left == 0) return error.UnfoldFusionLimit;
        self.left -= 1;
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| try self.record(FieldType, @field(value, field_name)),
            .@"union" => switch (value) {
                inline else => |v| try self.record(@TypeOf(v), v),
            },
            .optional => |info| if (value) |v| {
                try self.record(info.child, v);
            },
            .pointer => |info| for (value) |v| try self.record(info.child, v),
            else => {},
        }
    }
};
const Shape = struct {
    closure: p.Id,
    step: p.Id,
    state: p.Id,
    successor: p.Id,
    constructions: usize,
    applications: usize,
};
fn affected(shape: Shape, schema: p.Id) bool {
    return schema == shape.closure or schema == shape.step;
}
// A closed, effect-free singleton protocol is the initial domain. Other closure
// implementations, public/nominal boundaries, owning state and unknown uses stay.
fn recognize(a: std.mem.Allocator, program: ir.Program, budget: *Budget) Error!?Shape {
    try budget.record(ir.Program, program);
    if (program.constructors.len != 1 or
        program.scopes.captures.len != 1 or
        program.scopes.region_count != 0 or
        program.scopes.resources.len != 0 or
        program.handlers.len != 0 or
        program.effects.len != 0)
        return null;
    const constructor = program.constructors[0];
    const capture = program.scopes.captures[@intCast(constructor.capture)];
    if (capture.fields.len != 1 or
        capture.use != .reusable or
        capture.owned_regions.len != 0 or
        capture.borrowed_regions.len != 0)
        return null;
    const signature = program.schemas[@intCast(constructor.schema)].internal.computation;
    if (signature.parameters.len != 0 or
        signature.use != .reusable or
        signature.effects.len != 0 or
        signature.regions.len != 0)
        return null;
    const product = program.schemas[@intCast(signature.result)];
    if (product != .product or
        product.product.len != 2 or
        product.product[1] != constructor.schema)
        return null;
    const schemas = try admission.schemas(a, program.schemas);
    const permissions = try traits.derive(a, program.schemas);
    const state = capture.fields[0];
    if (!schemas.exportable[
        @intCast(state)
    ] or !permissions.copy[
        @intCast(state)
    ] or !permissions.drop[
        @intCast(state)
    ] or !schemas.exportable[
        @intCast(product.product[0])
    ]) return null;
    var shape: Shape = .{
        .closure = constructor.schema,
        .step = signature.result,
        .state = state,
        .successor = constructor.function,
        .constructions = 0,
        .applications = 0,
    };
    if (affected(shape, program.roots.result) or
        affected(shape, program.roots.failure))
        return null;
    for (
        program.schemas,
        0..,
    ) |_, id| if (!affected(shape, id) and !schemas.exportable[id]) return null;
    for (program.constants) |literal| if (affected(shape, literal.schema)) return null;
    const root = program.functions[@intCast(program.roots.entry)];
    for (root.inputs) |slot| if (affected(shape, root.layout.slots[@intCast(slot)])) return null;
    for (program.functions) |function| {
        if (function.effects.len != 0 or
            function.regions.len != 0 or
            function.custody.len != 1 or
            function.result == shape.closure)
            return null;
        for (function.inputs) |slot| if (function.layout.slots[
            @intCast(slot)
        ] == shape.closure) return null;
    }
    var products: usize = 0;
    for (program.blocks) |block| {
        try budget.record(ir.Block, block);
        if (block.custody != 0) return null;
        const slots = program.functions[@intCast(block.function)].layout.slots;
        for (block.instructions) |op| {
            const result = slots[@intCast(op.destination)];
            var touches = affected(shape, result);
            for (op.operands) |operand| touches = touches or affected(
                shape,
                slots[@intCast(operand)],
            );
            if (!touches) continue;
            switch (op.opcode) {
                .computation => {
                    if (result != shape.closure or
                        op.immediate != 0 or
                        op.operands.len != 1 or
                        slots[
                            @intCast(op.operands[0])
                        ] != shape.state)
                        return null;
                    shape.constructions += 1;
                },
                .product => {
                    if (result != shape.step or op.operands.len != 2 or slots[
                        @intCast(op.operands[1])
                    ] != shape.closure) return null;
                    products += 1;
                },
                .field => if (op.operands.len != 1 or slots[
                    @intCast(op.operands[0])
                ] != shape.step) return null,
                .move => if (op.operands.len != 1 or slots[
                    @intCast(op.operands[0])
                ] != result) return null,
                else => return null,
            }
        }
        switch (block.terminator) {
            .apply => |call| {
                if (slots[
                    @intCast(call.computation)
                ] != shape.closure or call.arguments.len != 0) return null;
                shape.applications += 1;
            },
            .call, .jump, .branch, .switch_variant, .unpack_product, .return_value, .fail => {},
            else => return null,
        }
    }
    if (shape.constructions == 0 or shape.applications == 0 or products == 0) return null;
    return shape;
}
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
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
    var budget: Budget = .{ .left = options.work_limit };
    const shape = (try recognize(a, original, &budget)) orelse return null;
    const schemas = try a.dupe(p.Schema, original.schemas);
    schemas[@intCast(shape.step)].product = try a.dupe(
        p.Id,
        &.{ original.schemas[@intCast(shape.step)].product[0], shape.state },
    );
    const functions = try a.dupe(ir.Function, original.functions);
    for (functions) |*function| {
        const slots = try a.dupe(p.Id, function.layout.slots);
        for (slots) |*schema| if (schema.* == shape.closure) {
            schema.* = shape.state;
        };
        function.layout.slots = slots;
    }
    const blocks = try a.dupe(ir.Block, original.blocks);
    for (blocks) |*block| {
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        for (instructions) |*op| if (op.opcode == .computation) {
            op.opcode = .move;
            op.immediate = 0;
        };
        block.instructions = instructions;
        if (block.terminator == .apply) {
            const call = block.terminator.apply;
            block.terminator = .{ .call = .{
                .function = shape.successor,
                .arguments = try a.dupe(p.Id, &.{call.computation}),
                .next = call.next,
            } };
        }
    }
    var program = original;
    program.schemas = schemas;
    program.functions = functions;
    program.blocks = blocks;
    keep = true;
    return .{ .arena = arena, .program = program };
}
/// Validate the representation relation from original records and actual output;
/// the constructor's maps and emitted instruction stream are not evidence.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget: Budget = .{ .left = options.work_limit };
    const shape = (try recognize(
        arena.allocator(),
        original,
        &budget,
    )) orelse return error.InvalidUnfoldFusion;
    try budget.record(ir.Program, candidate);
    if (original.schemas.len != candidate.schemas.len or
        original.functions.len != candidate.functions.len or
        original.blocks.len != candidate.blocks.len)
        return error.InvalidUnfoldFusion;
    var rest = candidate;
    rest.schemas = original.schemas;
    rest.functions = original.functions;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidUnfoldFusion;
    for (original.schemas, candidate.schemas, 0..) |old, new, id| {
        if (id == shape.step) {
            if (new != .product or !std.mem.eql(
                p.Id,
                new.product,
                &.{ old.product[0], shape.state },
            )) return error.InvalidUnfoldFusion;
        } else if (!equal(p.Schema, old, new)) return error.InvalidUnfoldFusion;
    }
    for (original.functions, candidate.functions) |old, new| {
        var metadata = new;
        metadata.layout = old.layout;
        if (!equal(
            ir.Function,
            old,
            metadata,
        ) or old.layout.slots.len != new.layout.slots.len) return error.InvalidUnfoldFusion;
        for (
            old.layout.slots,
            new.layout.slots,
        ) |before_schema, after_schema|
            if (after_schema != (if (before_schema == shape.closure)
                shape.state
            else
                before_schema))
                return error.InvalidUnfoldFusion;
    }
    for (original.blocks, candidate.blocks) |old, new| {
        if (old.function != new.function or
            old.custody != new.custody or
            old.instructions.len != new.instructions.len)
            return error.InvalidUnfoldFusion;
        for (old.instructions, new.instructions) |before_op, after_op| {
            var restored = after_op;
            if (before_op.opcode == .computation) {
                if (after_op.opcode != .move or
                    after_op.immediate != 0)
                    return error.InvalidUnfoldFusion;
                restored.opcode = .computation;
                restored.immediate = before_op.immediate;
            }
            if (!equal(ir.Instruction, before_op, restored)) return error.InvalidUnfoldFusion;
        }
        if (old.terminator == .apply) {
            if (new.terminator != .call) return error.InvalidUnfoldFusion;
            const before_call = old.terminator.apply;
            const after_call = new.terminator.call;
            if (after_call.function != shape.successor or !std.mem.eql(
                p.Id,
                after_call.arguments,
                &.{before_call.computation},
            ) or !equal(
                ir.Edge,
                before_call.next,
                after_call.next,
            )) return error.InvalidUnfoldFusion;
        } else if (!equal(
            ir.Terminator,
            old.terminator,
            new.terminator,
        )) return error.InvalidUnfoldFusion;
    }
}
pub fn possible(program: ir.Program) bool {
    if (program.constructors.len != 1 or
        program.handlers.len != 0 or
        program.effects.len != 0 or
        program.scopes.resources.len != 0)
        return false;
    const id = program.constructors[0].schema;
    if (id >= program.schemas.len) return false;
    const schema = program.schemas[@intCast(id)];
    if (schema != .internal or schema.internal != .computation) return false;
    const result = schema.internal.computation.result;
    if (result >= program.schemas.len) return false;
    const step = program.schemas[@intCast(result)];
    return step == .product and step.product.len == 2 and step.product[1] == id;
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
        error.UnfoldFusionLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    }) orelse return p01.run(allocator, original, options.coalescing);
    defer candidate.deinit();
    validate(allocator, original, candidate.program, options) catch |err| switch (err) {
        error.UnfoldFusionLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.protocols_fused = 1;
    for (original.blocks) |block| {
        for (block.instructions) |op| {
            stats.construction_sites_removed += @intFromBool(op.opcode == .computation);
        }
        stats.applications_direct += @intFromBool(block.terminator == .apply);
    }
    return result;
}
