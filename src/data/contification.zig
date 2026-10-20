// Copyright (c) 2026 Boundary contributors. MIT license.
//! Closed private tail-call components become shared caller-local join bodies.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const ownership = @import("activation_ownership.zig");
const contexts = @import("call_contexts.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
const image = @import("program_image.zig");
pub const Error = p01.Error || error{ InvalidContification, ContificationLimit };
pub const Options = struct {
    work_limit: usize = 1_000_000,
    max_helpers: usize = 16,
    max_blocks: usize = 256,
    max_slots: usize = 512,
    max_added_bytes: usize = 4096,
    coalescing: p01.Options = .{},
};
pub const Witness = struct {
    helpers: []const p.Id,
    caller: p.Id,
    first_slot: usize,
    first_block: usize,
};
pub const Statistics = struct {
    helpers: usize = 0,
    calls_removed: usize = 0,
    body_blocks: usize = 0,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    witness: Witness,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: usize,
    fn tick(self: *Budget) Error!void {
        try self.take(1);
    }
    fn take(self: *Budget, amount: usize) Error!void {
        if (self.left < amount) return error.ContificationLimit;
        self.left -= amount;
    }
};
const Context = struct {
    caller: p.Id,
    continuation: ir.Edge,
    calls: usize,
    blocks: usize,
    slots: usize,
};
fn member(helpers: []const p.Id, id: p.Id) bool {
    return std.mem.indexOfScalar(p.Id, helpers, id) != null;
}
// Iterative Kosaraju discovery; only this transformation consumes the graph.
fn components(a: std.mem.Allocator, program: ir.Program, budget: *Budget) Error![][]const p.Id {
    const n = program.functions.len;
    const outgoing = try a.alloc(std.ArrayList(p.Id), n);
    const incoming = try a.alloc(std.ArrayList(p.Id), n);
    for (outgoing, incoming) |*out, *inc| {
        out.* = .empty;
        inc.* = .empty;
    }
    for (program.blocks) |block| {
        try budget.tick();
        if (block.terminator == .call) {
            const target = block.terminator.call.function;
            try outgoing[@intCast(block.function)].append(a, target);
            try incoming[@intCast(target)].append(a, block.function);
        }
    }
    const seen = try a.alloc(bool, n);
    @memset(seen, false);
    const Frame = struct { id: p.Id, next: usize = 0 };
    var stack: std.ArrayList(Frame) = .empty;
    var order: std.ArrayList(p.Id) = .empty;
    for (0..n) |start| {
        if (seen[start]) continue;
        seen[start] = true;
        try stack.append(a, .{ .id = start });
        while (stack.items.len != 0) {
            try budget.tick();
            const top = stack.items.len - 1;
            const id = stack.items[top].id;
            if (stack.items[top].next < outgoing[@intCast(id)].items.len) {
                const next = outgoing[@intCast(id)].items[stack.items[top].next];
                stack.items[top].next += 1;
                if (!seen[@intCast(next)]) {
                    seen[@intCast(next)] = true;
                    try stack.append(a, .{ .id = next });
                }
            } else {
                _ = stack.pop();
                try order.append(a, id);
            }
        }
    }
    @memset(seen, false);
    const result = try a.alloc([]const p.Id, n);
    var pending: std.ArrayList(p.Id) = .empty;
    while (order.pop()) |start| {
        if (seen[@intCast(start)]) continue;
        var group: std.ArrayList(p.Id) = .empty;
        seen[@intCast(start)] = true;
        try pending.append(a, start);
        while (pending.pop()) |id| {
            try budget.tick();
            try group.append(a, id);
            for (incoming[@intCast(id)].items) |next| {
                try budget.tick();
                if (!seen[@intCast(next)]) {
                    seen[@intCast(next)] = true;
                    try pending.append(a, next);
                }
            }
        }
        const ids = try group.toOwnedSlice(a);
        std.mem.sort(p.Id, ids, {}, std.sort.asc(p.Id));
        for (ids) |id| result[@intCast(id)] = ids;
    }
    return result;
}
fn sharedLayout(program: ir.Program, helpers: []const p.Id) bool {
    if (helpers.len < 2) return false;
    const slots = program.functions[@intCast(helpers[0])].layout.slots;
    for (helpers[1..]) |id| if (!std.mem.eql(
        p.Id,
        slots,
        program.functions[@intCast(id)].layout.slots,
    )) return false;
    return true;
}
fn slotBase(program: ir.Program, witness: Witness, helper: p.Id) Error!usize {
    if (sharedLayout(program, witness.helpers) and member(witness.helpers, helper)) return witness.first_slot;
    var base = witness.first_slot;
    for (witness.helpers) |id| {
        if (id == helper) return base;
        base += program.functions[@intCast(id)].layout.slots.len;
    }
    return error.InvalidContification;
}
fn quietFunction(
    program: ir.Program,
    id: p.Id,
    helpers: []const p.Id,
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
        try budget.tick();
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return false;
    }
    for (program.blocks) |block| {
        try budget.tick();
        if (block.function != id) continue;
        if (block.custody != 0) return false;
        for (block.instructions) |op| {
            try budget.tick();
            try budget.take(op.operands.len);
            if (op.failures.len != 0) return false;
            switch (op.opcode) {
                .constant,
                .move,
                .product,
                .field,
                .variant,
                .equal,
                .less,
                .boolean_not,
                .integer_bit_not,
                .integer_bit_and,
                .integer_bit_or,
                .integer_bit_xor,
                => {},
                else => return false,
            }
        }
        switch (block.terminator) {
            .return_value, .fail, .jump, .branch => {},
            .call => |call| {
                if (!member(helpers, call.function)) return false;
                if (member(helpers, id)) {
                    const source = terminalReturn(program, call.next) orelse return false;
                    if (source != .returned) return false;
                }
            },
            else => return false,
        }
    }
    return true;
}
fn classify(
    program: ir.Program,
    helpers: []const p.Id,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *Budget,
) Error!?Context {
    if (helpers.len == 0) return null;
    for (helpers, 0..) |helper, index| {
        try budget.tick();
        if (helper >= program.functions.len or
            (index != 0 and
                helpers[index - 1] >= helper) or
            contexts.unknownEntry(program, helper))
            return null;
    }
    var context: ?Context = null;
    for (program.blocks) |block| {
        try budget.tick();
        if (block.terminator != .call or !member(
            helpers,
            block.terminator.call.function,
        ) or member(helpers, block.function)) continue;
        if (context) |*known| {
            if (known.caller != block.function or !equal(
                ir.Edge,
                known.continuation,
                block.terminator.call.next,
            )) return null;
            known.calls += 1;
        } else context = .{
            .caller = block.function,
            .continuation = block.terminator.call.next,
            .calls = 1,
            .blocks = 0,
            .slots = 0,
        };
    }
    var result = context orelse return null;
    for (helpers) |helper| {
        if (!try quietFunction(
            program,
            helper,
            helpers,
            permissions,
            exportable,
            budget,
        )) return null;
        result.slots = std.math.add(
            usize,
            result.slots,
            program.functions[@intCast(helper)].layout.slots.len,
        ) catch return error.Capacity;
    }
    // Tail identity continuations and exportable values make prior helper
    // activations unobservable. Equal layouts may hand off one slot bank via
    // parallel argument assignment; caller slots remain disjoint.
    if (sharedLayout(
        program,
        helpers,
    )) result.slots = program.functions[@intCast(helpers[0])].layout.slots.len;
    if (!try quietFunction(
        program,
        result.caller,
        helpers,
        permissions,
        exportable,
        budget,
    )) return null;
    for (program.blocks) |block| {
        try budget.tick();
        if (member(helpers, block.function)) result.blocks += 1;
    }
    return result;
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| if (block.terminator == .call and !contexts.unknownEntry(
        program,
        block.terminator.call.function,
    )) return true;
    return false;
}
fn targetBlock(program: ir.Program, witness: Witness, old: p.Id) Error!p.Id {
    var next = witness.first_block;
    for (program.blocks, 0..) |block, id| if (member(witness.helpers, block.function)) {
        if (id == old) return next;
        next += 1;
    };
    return error.InvalidContification;
}
fn localEdge(
    a: std.mem.Allocator,
    program: ir.Program,
    witness: Witness,
    old: ir.Edge,
    base: usize,
) Error!ir.Edge {
    const assignments = try a.dupe(ir.Assignment, old.assignments);
    for (assignments) |*assignment| {
        assignment.destination += base;
        switch (assignment.source) {
            .slot => |slot| assignment.source = .{ .slot = slot + base },
            .returned => return error.InvalidContification,
        }
    }
    return .{ .block = try targetBlock(program, witness, old.block), .assignments = assignments };
}
fn callEdge(
    a: std.mem.Allocator,
    program: ir.Program,
    witness: Witness,
    call: @FieldType(ir.Terminator, "call"),
    source_base: usize,
) Error!ir.Edge {
    const target = program.functions[@intCast(call.function)];
    const base = try slotBase(program, witness, call.function);
    var assignments: std.ArrayList(ir.Assignment) = .empty;
    for (target.inputs, call.arguments) |input, argument| {
        if (base + input == source_base + argument) continue;
        try assignments.append(
            a,
            .{ .destination = base + input, .source = .{ .slot = source_base + argument } },
        );
    }
    return .{
        .block = try targetBlock(program, witness, target.entry),
        .assignments = try assignments.toOwnedSlice(a),
    };
}
fn terminalReturn(program: ir.Program, edge: ir.Edge) ?ir.Source {
    const continuation = program.blocks[@intCast(edge.block)];
    if (continuation.instructions.len != 0 or continuation.terminator != .return_value) return null;
    const result = continuation.terminator.return_value;
    for (edge.assignments) |assignment|
        if (assignment.destination == result)
            return assignment.source;
    return .{ .slot = result };
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var admitted = try ownership.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    var selected: ?Witness = null;
    var context: Context = undefined;
    const groups = try components(a, original, &budget);
    for (groups, 0..) |helpers, id| {
        if (helpers[0] != id) continue;
        const found = (try classify(
            original,
            helpers,
            permissions,
            schemas.exportable,
            &budget,
        )) orelse continue;
        if (helpers.len > options.max_helpers or
            found.blocks > options.max_blocks or
            found.slots > options.max_slots)
            return error.ContificationLimit;
        selected = .{
            .helpers = helpers,
            .caller = found.caller,
            .first_slot = original.functions[@intCast(found.caller)].layout.slots.len,
            .first_block = original.blocks.len,
        };
        context = found;
        break;
    }
    const witness = selected orelse return null;
    const functions = try a.dupe(ir.Function, original.functions);
    const slots = try a.alloc(p.Id, witness.first_slot + context.slots);
    @memcpy(slots[0..witness.first_slot], functions[@intCast(witness.caller)].layout.slots);
    for (witness.helpers) |id| {
        const base = try slotBase(original, witness, id);
        const local = original.functions[@intCast(id)].layout.slots;
        @memcpy(slots[base..][0..local.len], local);
    }
    functions[@intCast(witness.caller)].layout.slots = slots;
    const blocks = try a.alloc(ir.Block, original.blocks.len + context.blocks);
    @memcpy(blocks[0..original.blocks.len], original.blocks);
    var next = witness.first_block;
    for (original.blocks, 0..) |block, bid| {
        try budget.tick();
        if (block.terminator == .call and member(
            witness.helpers,
            block.terminator.call.function,
        ) and !member(witness.helpers, block.function)) {
            blocks[bid].terminator = .{ .jump = try callEdge(
                a,
                original,
                witness,
                block.terminator.call,
                0,
            ) };
        }
        if (!member(witness.helpers, block.function)) continue;
        const base = try slotBase(original, witness, block.function);
        var copied = block;
        copied.function = witness.caller;
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        for (instructions) |*op| {
            try budget.tick();
            op.destination += base;
            const operands = try a.dupe(p.Id, op.operands);
            for (operands) |*slot| slot.* += base;
            op.operands = operands;
        }
        copied.instructions = instructions;
        switch (block.terminator) {
            .call => |call| copied.terminator = .{ .jump = try callEdge(
                a,
                original,
                witness,
                call,
                base,
            ) },
            .return_value => |value| {
                if (terminalReturn(original, context.continuation)) |source| {
                    copied.terminator = .{ .return_value = switch (source) {
                        .returned => value + base,
                        .slot => |slot| slot,
                    } };
                } else {
                    const assignments = try a.dupe(ir.Assignment, context.continuation.assignments);
                    for (assignments) |*assignment| if (assignment.source == .returned) {
                        assignment.source = .{ .slot = value + base };
                    };
                    copied.terminator = .{ .jump = .{
                        .block = context.continuation.block,
                        .assignments = assignments,
                    } };
                }
            },
            .fail => |value| copied.terminator = .{ .fail = value + base },
            .jump => |edge| copied.terminator = .{ .jump = try localEdge(
                a,
                original,
                witness,
                edge,
                base,
            ) },
            .branch => |branch| copied.terminator = .{ .branch = .{
                .condition = branch.condition + base,
                .when_true = try localEdge(a, original, witness, branch.when_true, base),
                .when_false = try localEdge(a, original, witness, branch.when_false, base),
            } },
            else => return error.InvalidContification,
        }
        blocks[next] = copied;
        next += 1;
    }
    var program = original;
    program.functions = functions;
    program.blocks = blocks;
    const before = try image.encodedLength(original);
    const after = try image.encodedLength(program);
    if (after > before and
        after - before > options.max_added_bytes)
        return error.ContificationLimit;
    keep = true;
    return .{ .arena = arena, .program = program, .witness = witness };
}
fn edgeCorresponds(
    program: ir.Program,
    witness: Witness,
    old: ir.Edge,
    new: ir.Edge,
    base: usize,
) bool {
    var ordinal: usize = 0;
    var destination: ?usize = null;
    for (program.blocks, 0..) |block, id| if (member(witness.helpers, block.function)) {
        if (id == old.block) destination = witness.first_block + ordinal;
        ordinal += 1;
    };
    if (destination == null or
        new.block != destination.? or
        old.assignments.len != new.assignments.len)
        return false;
    for (old.assignments, new.assignments) |before, after| {
        if (before.source != .slot or
            after.source != .slot or
            after.destination != before.destination + base or
            after.source.slot != before.source.slot + base)
            return false;
    }
    return true;
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
    options: Options,
) Error!void {
    var before = try ownership.analyze(allocator, original);
    defer before.deinit();
    var after = try ownership.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    var budget: Budget = .{ .left = options.work_limit };
    // Certification needs a closed tail-call group, independently of how SCCs
    // were discovered. Every actual incoming/outgoing use is reconstructed.
    const context = (try classify(
        original,
        witness.helpers,
        permissions,
        schemas.exportable,
        &budget,
    )) orelse return error.InvalidContification;
    if (context.caller != witness.caller or
        candidate.functions.len != original.functions.len or
        witness.first_block != original.blocks.len or
        candidate.blocks.len != original.blocks.len + context.blocks)
        return error.InvalidContification;
    const caller = original.functions[@intCast(witness.caller)];
    if (witness.first_slot != caller.layout.slots.len) return error.InvalidContification;
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    if (!equal(ir.Program, original, unchanged)) return error.InvalidContification;
    const bases = try a.alloc(usize, original.functions.len);
    @memset(bases, std.math.maxInt(usize));
    const slots = candidate.functions[@intCast(witness.caller)].layout.slots;
    if (slots.len != witness.first_slot + context.slots or !std.mem.eql(
        p.Id,
        caller.layout.slots,
        slots[0..witness.first_slot],
    )) return error.InvalidContification;
    var next_slot = witness.first_slot;
    const shared_slots = sharedLayout(original, witness.helpers);
    for (witness.helpers) |id| {
        const local = original.functions[@intCast(id)].layout.slots;
        bases[@intCast(id)] = next_slot;
        if (!std.mem.eql(
            p.Id,
            local,
            slots[next_slot..][0..local.len],
        )) return error.InvalidContification;
        if (!shared_slots) next_slot += local.len;
    }
    for (original.functions, candidate.functions, 0..) |old, new, id| {
        var restored = new;
        if (id == witness.caller) restored.layout = old.layout;
        if (!equal(ir.Function, old, restored)) return error.InvalidContification;
    }
    const targets = try a.alloc(p.Id, original.blocks.len);
    @memset(targets, std.math.maxInt(p.Id));
    var next_block = witness.first_block;
    for (original.blocks, 0..) |block, id| if (member(witness.helpers, block.function)) {
        targets[id] = next_block;
        next_block += 1;
    };
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
        try budget.tick();
        if (old.terminator == .call and member(
            witness.helpers,
            old.terminator.call.function,
        ) and !member(witness.helpers, old.function)) {
            var restored = new;
            restored.terminator = old.terminator;
            if (!equal(ir.Block, old, restored)) return error.InvalidContification;
            try checkCall(original, old.terminator.call, new.terminator, 0, bases, targets);
        } else if (!equal(ir.Block, old, new)) return error.InvalidContification;
        if (!member(witness.helpers, old.function)) continue;
        const base = bases[@intCast(old.function)];
        const copied = candidate.blocks[@intCast(targets[bid])];
        if (copied.function != witness.caller or
            copied.custody != old.custody or
            copied.instructions.len != old.instructions.len)
            return error.InvalidContification;
        for (old.instructions, copied.instructions) |op, replacement| {
            try budget.tick();
            if (replacement.destination != op.destination + base or
                replacement.operands.len != op.operands.len)
                return error.InvalidContification;
            for (
                op.operands,
                replacement.operands,
            ) |operand, mapped| if (mapped != operand + base) return error.InvalidContification;
            var restored = replacement;
            restored.destination = op.destination;
            restored.operands = op.operands;
            if (!equal(ir.Instruction, op, restored)) return error.InvalidContification;
        }
        switch (old.terminator) {
            .call => |call| try checkCall(original, call, copied.terminator, base, bases, targets),
            .return_value => |value| {
                if (copied.terminator == .return_value) {
                    const continuation = original.blocks[@intCast(context.continuation.block)];
                    if (continuation.instructions.len != 0 or
                        continuation.terminator != .return_value)
                        return error.InvalidContification;
                    const result = continuation.terminator.return_value;
                    var expected = result;
                    for (context.continuation.assignments) |transfer|
                        if (transfer.destination == result) {
                            expected = switch (transfer.source) {
                                .returned => value + base,
                                .slot => |slot| slot,
                            };
                        };
                    if (copied.terminator.return_value != expected)
                        return error.InvalidContification;
                } else {
                    if (copied.terminator != .jump or
                        copied.terminator.jump.block != context.continuation.block or
                        copied.terminator.jump.assignments.len != context.continuation.assignments.len)
                        return error.InvalidContification;
                    for (
                        context.continuation.assignments,
                        copied.terminator.jump.assignments,
                    ) |transfer, replacement| {
                        var expected = transfer;
                        if (expected.source == .returned) expected.source = .{
                            .slot = value + base,
                        };
                        if (!equal(
                            ir.Assignment,
                            expected,
                            replacement,
                        )) return error.InvalidContification;
                    }
                }
            },
            .fail => |value| if (copied.terminator != .fail or
                copied.terminator.fail != value + base)
                return error.InvalidContification,
            .jump => |edge| if (copied.terminator != .jump or !edgeCorresponds(
                original,
                witness,
                edge,
                copied.terminator.jump,
                base,
            )) return error.InvalidContification,
            .branch => |branch| if (copied.terminator != .branch or
                copied.terminator.branch.condition != branch.condition + base or
                !edgeCorresponds(
                    original,
                    witness,
                    branch.when_true,
                    copied.terminator.branch.when_true,
                    base,
                ) or
                !edgeCorresponds(
                    original,
                    witness,
                    branch.when_false,
                    copied.terminator.branch.when_false,
                    base,
                ))
                return error.InvalidContification,
            else => return error.InvalidContification,
        }
    }
}
fn checkCall(
    program: ir.Program,
    call: @FieldType(ir.Terminator, "call"),
    term: ir.Terminator,
    source_base: usize,
    bases: []const usize,
    targets: []const p.Id,
) Error!void {
    const target = program.functions[@intCast(call.function)];
    if (term != .jump or term.jump.block != targets[
        @intCast(target.entry)
    ]) return error.InvalidContification;
    var next: usize = 0;
    for (target.inputs, call.arguments) |input, argument| {
        const destination = bases[@intCast(call.function)] + input;
        const source = source_base + argument;
        if (destination == source) continue;
        if (next >= term.jump.assignments.len) return error.InvalidContification;
        const transfer = term.jump.assignments[next];
        if (transfer.destination != destination or
            transfer.source != .slot or
            transfer.source.slot != source)
            return error.InvalidContification;
        next += 1;
    }
    if (next != term.jump.assignments.len) return error.InvalidContification;
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
        error.ContificationLimit => {
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
        candidate.witness,
        options,
    ) catch |err| switch (err) {
        error.ContificationLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    stats.helpers = candidate.witness.helpers.len;
    stats.body_blocks = candidate.program.blocks.len - original.blocks.len;
    for (original.blocks) |block| if (block.terminator == .call and member(
        candidate.witness.helpers,
        block.terminator.call.function,
    )) {
        stats.calls_removed += 1;
    };
    return p01.run(allocator, candidate.program, options.coalescing);
}
