// Copyright (c) 2026 Boundary contributors. MIT license.
//! Select total tail resumptions without changing general callable functions.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const total = @import("total_clause.zig");
const traits = @import("traits.zig");
const equal = @import("record_equal.zig").equal;
const Error = std.mem.Allocator.Error || error{TailClauseWorkLimit};
pub const ValidationError = @import("coalescing.zig").Error || Error || error{InvalidTailClause};
const p01 = @import("coalescing.zig");
pub const Options = struct { work_limit: u64 = 10_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct { clauses_selected: usize = 0, work_limit: bool = false };
const Budget = struct { remaining: u64 };
fn take(budget: ?*Budget, amount: usize) Error!void {
    const b = budget orelse return;
    if (amount > b.remaining) return error.TailClauseWorkLimit;
    b.remaining -= amount;
}
fn charge(comptime T: type, value: T, budget: ?*Budget) Error!void {
    @setEvalBranchQuota(10000);
    return chargeFields(T, value, budget);
}

inline fn chargeFields(comptime T: type, value: T, budget: ?*Budget) Error!void {
    if (budget == null) return;
    try take(budget, 1);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (
            info.field_names,
            info.field_types,
        ) |field_name, FieldType| try chargeFields(FieldType, @field(value, field_name), budget),
        .@"union" => switch (value) {
            inline else => |payload| try chargeFields(@TypeOf(payload), payload, budget),
        },
        .optional => |info| if (value) |payload| {
            try chargeFields(info.child, payload, budget);
        },
        .pointer => |info| for (value) |item| try chargeFields(info.child, item, budget),
        else => {},
    }
}
pub fn possible(program: ir.Program) bool {
    for (program.handlers) |handler| for (handler.clauses) |clause| if (eligible(
        program,
        handler,
        clause,
    )) return true;
    return false;
}
pub fn run(
    a: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) ValidationError!p01.Owned {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const uses = try traits.derive(scratch, original.schemas);
    var budget: Budget = .{ .remaining = options.work_limit };
    const candidate = transform(scratch, original, uses, true, &budget) catch |err| switch (err) {
        error.TailClauseWorkLimit => {
            stats.work_limit = true;
            return p01.run(a, original, options.coalescing);
        },
        else => return err,
    };
    if (equal(ir.Program, original, candidate)) return p01.run(a, original, options.coalescing);
    budget.remaining = options.work_limit;
    validateBudgeted(a, original, candidate, &budget) catch |err| switch (err) {
        error.TailClauseWorkLimit => {
            stats.work_limit = true;
            return p01.run(a, original, options.coalescing);
        },
        else => return err,
    };
    for (
        original.handlers,
        candidate.handlers,
    ) |old, new| for (
        old.clauses,
        new.clauses,
    ) |old_clause, new_clause| {
        stats.clauses_selected += @intFromBool(
            old_clause.strategy == .general and new_clause.strategy == .tail,
        );
    };
    return p01.run(a, candidate, options.coalescing);
}

/// Check the actual appended code and changed clause bindings. Construction's
/// memo, block numbering and forward alias facts are not certificates.
pub fn validate(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
) ValidationError!void {
    return validateBudgeted(a, original, candidate, null);
}
const Origin = struct { handler: usize, clause: usize };
fn validateBudgeted(
    a: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    budget: ?*Budget,
) ValidationError!void {
    var before = try @import("activation_ownership.zig").analyze(a, original);
    defer before.deinit();
    var after = try @import("activation_ownership.zig").analyze(a, candidate);
    defer after.deinit();
    try charge(ir.Program, original, budget);
    try charge(ir.Program, candidate, budget);
    if (candidate.functions.len < original.functions.len or
        candidate.blocks.len < original.blocks.len or
        candidate.handlers.len != original.handlers.len)
        return error.InvalidTailClause;
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    unchanged.handlers = original.handlers;
    if (!equal(ir.Program, original, unchanged) or
        !equal(
            []const ir.Function,
            original.functions,
            candidate.functions[0..original.functions.len],
        ) or
        !equal(
            []const ir.Block,
            original.blocks,
            candidate.blocks[0..original.blocks.len],
        )) return error.InvalidTailClause;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const uses = try traits.derive(scratch, original.schemas);
    const origins = try scratch.alloc(?Origin, candidate.functions.len - original.functions.len);
    @memset(origins, null);
    try validateOrigins(original, candidate, origins);
    const seen = try scratch.alloc(bool, candidate.blocks.len - original.blocks.len);
    @memset(seen, false);
    for (origins, 0..) |possible_origin, index| {
        try validateSpecialization(
            scratch,
            original,
            candidate,
            possible_origin,
            index,
            uses,
            seen,
            budget,
        );
    }
    for (seen) |covered| if (!covered) return error.InvalidTailClause;
}

fn validateOrigins(
    original: ir.Program,
    candidate: ir.Program,
    origins: []?Origin,
) ValidationError!void {
    for (original.handlers, candidate.handlers, 0..) |old, new, handler_id| {
        var metadata = new;
        metadata.clauses = old.clauses;
        if (!equal(
            ir.Handler,
            old,
            metadata,
        ) or old.clauses.len != new.clauses.len) return error.InvalidTailClause;
        for (old.clauses, new.clauses, 0..) |old_clause, new_clause, clause_id| {
            if (equal(ir.Clause, old_clause, new_clause)) continue;
            var clause_metadata = new_clause;
            clause_metadata.function = old_clause.function;
            clause_metadata.strategy = old_clause.strategy;
            if (!equal(ir.Clause, old_clause, clause_metadata) or new_clause.strategy != .tail or
                !eligible(
                    original,
                    old,
                    old_clause,
                ) or new_clause.function < original.functions.len or
                new_clause.function >= candidate.functions.len) return error.InvalidTailClause;
            const index: usize = @intCast(new_clause.function - original.functions.len);
            if (origins[index]) |prior| {
                if (!equal(
                    ir.Clause,
                    original.handlers[prior.handler].clauses[prior.clause],
                    old_clause,
                )) return error.InvalidTailClause;
            } else origins[index] = .{ .handler = handler_id, .clause = clause_id };
        }
    }
}

fn validateSpecialization(
    scratch: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    possible_origin: ?Origin,
    index: usize,
    uses: traits.Facts,
    seen: []bool,
    budget: ?*Budget,
) ValidationError!void {
    const origin = possible_origin orelse return error.InvalidTailClause;
    const clause = original.handlers[origin.handler].clauses[origin.clause];
    const old = original.functions[@intCast(clause.function)];
    const id = original.functions.len + index;
    const new = candidate.functions[id];
    const token = old.inputs[old.inputs.len - 1];
    var metadata = new;
    metadata.entry = old.entry;
    metadata.inputs = old.inputs;
    metadata.layout = old.layout;
    metadata.result = old.result;
    metadata.effects = old.effects;
    if (!equal(
        ir.Function,
        old,
        metadata,
    ) or new.result != original.effects[@intCast(clause.effect)].result or
        new.effects.len != 0 or !equal(
        []const p.Id,
        new.inputs,
        old.inputs[0 .. old.inputs.len - 1],
    ) or
        new.layout.slots.len != old.layout.slots.len) return error.InvalidTailClause;
    for (old.layout.slots, new.layout.slots, 0..) |old_schema, new_schema, slot| {
        if (new_schema != (if (slot == token) original.effects[
            @intCast(clause.effect)
        ].payload else old_schema)) return error.InvalidTailClause;
        if (slot != token and !uses.copy[@intCast(old_schema)]) return error.InvalidTailClause;
    }
    var walk: Correspondence = .{
        .allocator = scratch,
        .original = original,
        .candidate = candidate,
        .seen = seen,
        .old_function = clause.function,
        .new_function = id,
        .token = token,
        .budget = budget,
    };
    try walk.push(old.entry, new.entry);
    var cursor: usize = 0;
    while (cursor < walk.pending.items.len) : (cursor += 1) try walk.block(
        walk.pending.items[cursor],
    );
}

const Pair = struct { original: p.Id, candidate: p.Id };
const Correspondence = struct {
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    mapping: std.AutoHashMapUnmanaged(p.Id, p.Id) = .empty,
    seen: []bool,
    old_function: p.Id,
    new_function: p.Id,
    token: p.Id,
    budget: ?*Budget,
    pending: std.ArrayList(Pair) = .empty,

    fn push(self: *Correspondence, old: p.Id, new: p.Id) ValidationError!void {
        if (old >= self.original.blocks.len or
            new < self.original.blocks.len or
            new >= self.candidate.blocks.len)
            return error.InvalidTailClause;
        if (self.mapping.get(old)) |prior| {
            if (prior != new) return error.InvalidTailClause;
            return;
        }
        const index: usize = @intCast(new - self.original.blocks.len);
        if (self.seen[index]) return error.InvalidTailClause;
        self.seen[index] = true;
        try self.mapping.put(self.allocator, old, new);
        try self.pending.append(self.allocator, .{ .original = old, .candidate = new });
    }
    fn checkEdge(self: *Correspondence, old: ir.Edge, new: ir.Edge) ValidationError!void {
        if (!equal(
            []const ir.Assignment,
            old.assignments,
            new.assignments,
        )) return error.InvalidTailClause;
        for (old.assignments) |assignment|
            if (assignment.destination == self.token or
                assignment.source != .slot or
                assignment.source.slot == self.token)
                return error.InvalidTailClause;
        try self.push(old.block, new.block);
    }
    fn block(self: *Correspondence, pair: Pair) ValidationError!void {
        const old = self.original.blocks[@intCast(pair.original)];
        try charge(ir.Block, old, self.budget);
        const new = self.candidate.blocks[@intCast(pair.candidate)];
        var metadata = new;
        metadata.function = old.function;
        metadata.terminator = old.terminator;
        if (old.function != self.old_function or new.function != self.new_function or !equal(
            ir.Block,
            old,
            metadata,
        )) return error.InvalidTailClause;
        for (old.instructions) |op| {
            if (!total.instruction(
                op,
            ) or op.destination == self.token) return error.InvalidTailClause;
            for (op.operands) |slot| if (slot == self.token) return error.InvalidTailClause;
        }
        try self.checkTerminator(old, new);
    }
    fn checkTerminator(self: *Correspondence, old: ir.Block, new: ir.Block) ValidationError!void {
        switch (old.terminator) {
            .jump => |edge| {
                if (new.terminator != .jump) return error.InvalidTailClause;
                try self.checkEdge(edge, new.terminator.jump);
            },
            .branch => |branch| {
                if (new.terminator != .branch or
                    branch.condition == self.token or
                    new.terminator.branch.condition != branch.condition)
                    return error.InvalidTailClause;
                try self.checkEdge(branch.when_true, new.terminator.branch.when_true);
                try self.checkEdge(branch.when_false, new.terminator.branch.when_false);
            },
            .switch_variant => |branch| {
                if (new.terminator != .switch_variant or
                    branch.value == self.token or
                    new.terminator.switch_variant.value != branch.value or
                    new.terminator.switch_variant.cases.len != branch.cases.len)
                    return error.InvalidTailClause;
                for (
                    branch.cases,
                    new.terminator.switch_variant.cases,
                ) |old_edge, new_edge| try self.checkEdge(old_edge, new_edge);
            },
            .unpack_product => |unpack| {
                if (new.terminator != .unpack_product or
                    unpack.value == self.token or
                    new.terminator.unpack_product.value != unpack.value or
                    !equal(
                        []const p.Id,
                        unpack.destinations,
                        new.terminator.unpack_product.destinations,
                    ))
                    return error.InvalidTailClause;
                for (unpack.destinations) |slot|
                    if (slot == self.token)
                        return error.InvalidTailClause;
                try self.checkEdge(unpack.next, new.terminator.unpack_product.next);
            },
            .resume_value => |resumption| try self.checkResumption(old, new, resumption),
            else => return error.InvalidTailClause,
        }
    }
    fn checkResumption(
        self: *Correspondence,
        old: ir.Block,
        new: ir.Block,
        resumption: @FieldType(ir.Terminator, "resume_value"),
    ) ValidationError!void {
        if (resumption.resumption != self.token or
            resumption.argument == self.token or
            new.terminator != .return_value or
            new.terminator.return_value != resumption.argument or
            !try certifyAdministrativeResult(
                self.allocator,
                self.original,
                old.function,
                old.custody,
                resumption.next,
                self.budget,
            ))
            return error.InvalidTailClause;
    }
};

pub fn optimize(
    a: std.mem.Allocator,
    input: ir.Program,
    uses: traits.Facts,
) std.mem.Allocator.Error!ir.Program {
    return transform(a, input, uses, false, null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TailClauseWorkLimit => unreachable, // No budget on the existing source path.
    };
}

// Both callers share construction. The semantic caller must independently
// validate the returned raw candidate before acquiring a checked owner.
fn transform(
    a: std.mem.Allocator,
    input: ir.Program,
    uses: traits.Facts,
    administrative: bool,
    budget: ?*Budget,
) Error!ir.Program {
    try charge(ir.Program, input, budget);
    var functions: std.ArrayList(ir.Function) = .empty;
    var blocks: std.ArrayList(ir.Block) = .empty;
    try functions.appendSlice(a, input.functions);
    try blocks.appendSlice(a, input.blocks);
    const handlers = try a.dupe(ir.Handler, input.handlers);
    var memo: std.AutoHashMapUnmanaged(p.Id, ?p.Id) = .empty;
    for (handlers) |*handler| {
        const clauses = try a.dupe(ir.Clause, handler.clauses);
        handler.clauses = clauses;
        for (clauses) |*clause| {
            if (!eligible(input, handler.*, clause.*)) continue;
            const lookup = try memo.getOrPut(a, clause.function);
            if (!lookup.found_existing) lookup.value_ptr.* = try specialize(
                a,
                input,
                clause.*,
                uses,
                &functions,
                &blocks,
                administrative,
                budget,
            );
            if (lookup.value_ptr.*) |id| {
                clause.function = id;
                clause.strategy = .tail;
            }
        }
    }
    var result = input;
    result.functions = functions.items;
    result.blocks = blocks.items;
    result.handlers = handlers;
    return result;
}

fn eligible(image: ir.Program, handler: ir.Handler, clause: ir.Clause) bool {
    if (handler.mode != .deep or clause.strategy != .general or
        clause.effect >= image.effects.len or clause.function >= image.functions.len or
        clause.resumption >= image.schemas.len) return false;
    const schema = image.schemas[@intCast(clause.resumption)];
    if (schema != .internal or schema.internal != .resumption or
        schema.internal.resumption.use != .linear) return false;
    const function = image.functions[@intCast(clause.function)];
    if (function.entry >= image.blocks.len or
        function.inputs.len != handler.state.len + 2 or
        function.result != handler.answer or
        image.effects[@intCast(clause.effect)].bodies.len != 0) return false;
    for (function.effects) |effect| if (std.mem.indexOfScalar(
        p.Id,
        handler.effects,
        effect,
    ) == null)
        return false;
    for (handler.state, function.inputs[0..handler.state.len]) |schema_id, slot|
        if (function.layout.slots[@intCast(slot)] != schema_id) return false;
    if (function.layout.slots[@intCast(function.inputs[handler.state.len])] !=
        image.effects[@intCast(clause.effect)].payload) return false;
    return function.layout.slots[@intCast(function.inputs[function.inputs.len - 1])] ==
        clause.resumption;
}

fn specialize(
    a: std.mem.Allocator,
    image: ir.Program,
    clause: ir.Clause,
    uses: traits.Facts,
    functions: *std.ArrayList(ir.Function),
    blocks: *std.ArrayList(ir.Block),
    administrative: bool,
    budget: ?*Budget,
) Error!?p.Id {
    const original = image.functions[@intCast(clause.function)];
    try charge(ir.Function, original, budget);
    const token = original.inputs[original.inputs.len - 1];
    for (original.layout.slots, 0..) |schema, slot| {
        if (slot != token and !uses.copy[@intCast(schema)]) return null;
    }
    var ids: std.ArrayList(p.Id) = .empty;
    var mapping: std.AutoHashMapUnmanaged(p.Id, p.Id) = .empty;
    try add(a, &ids, &mapping, original.entry, blocks.items.len);
    var cursor: usize = 0;
    while (cursor < ids.items.len) : (cursor += 1) {
        const block = image.blocks[@intCast(ids.items[cursor])];
        try charge(ir.Block, block, budget);
        for (block.instructions) |operation| {
            if (!total.instruction(operation) or operation.destination == token) return null;
            for (operation.operands) |slot| if (slot == token) return null;
        }
        if (!try discover(
            a,
            image,
            block,
            token,
            &ids,
            &mapping,
            blocks.items.len,
            administrative,
            budget,
        )) return null;
    }
    const function_id = functions.items.len;
    const block_start = blocks.items.len;
    for (ids.items) |id| {
        var block = image.blocks[@intCast(id)];
        try charge(ir.Block, block, budget);
        block.function = function_id;
        block.terminator = try remap(a, block.terminator, &mapping);
        try blocks.append(a, block);
    }
    const slots = try a.dupe(p.Id, original.layout.slots);
    slots[@intCast(token)] = image.effects[@intCast(clause.effect)].payload;
    var function = original;
    function.inputs = original.inputs[0 .. original.inputs.len - 1];
    function.entry = mapping.get(original.entry).?;
    function.layout.slots = slots;
    function.result = image.effects[@intCast(clause.effect)].result;
    // The original row includes effects performed by the resumed body. The
    // selected CFG contains only total local operations and ordinary returns.
    function.effects = &.{};
    try functions.append(a, function);
    var candidate = image;
    candidate.functions = functions.items;
    candidate.blocks = blocks.items;
    total.validate(a, candidate, function_id, uses) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        functions.items.len = function_id;
        blocks.items.len = block_start;
        return null;
    };
    return function_id;
}

fn add(
    a: std.mem.Allocator,
    ids: *std.ArrayList(p.Id),
    mapping: *std.AutoHashMapUnmanaged(p.Id, p.Id),
    id: p.Id,
    base: usize,
) Error!void {
    const entry = try mapping.getOrPut(a, id);
    if (entry.found_existing) return;
    entry.value_ptr.* = base + ids.items.len;
    try ids.append(a, id);
}

fn follow(
    a: std.mem.Allocator,
    ids: *std.ArrayList(p.Id),
    mapping: *std.AutoHashMapUnmanaged(p.Id, p.Id),
    edge: ir.Edge,
    token: p.Id,
    base: usize,
) Error!bool {
    for (edge.assignments) |assignment| {
        if (assignment.destination == token or assignment.source != .slot or
            assignment.source.slot == token) return false;
    }
    try add(a, ids, mapping, edge.block, base);
    return true;
}

fn discover(
    a: std.mem.Allocator,
    image: ir.Program,
    block: ir.Block,
    token: p.Id,
    ids: *std.ArrayList(p.Id),
    mapping: *std.AutoHashMapUnmanaged(p.Id, p.Id),
    base: usize,
    administrative: bool,
    budget: ?*Budget,
) Error!bool {
    return switch (block.terminator) {
        .jump => |v| follow(a, ids, mapping, v, token, base),
        .branch => |v| v.condition != token and
            try follow(a, ids, mapping, v.when_true, token, base) and
            try follow(a, ids, mapping, v.when_false, token, base),
        .switch_variant => |v| blk: {
            if (v.value == token) break :blk false;
            for (v.cases) |edge| if (!try follow(a, ids, mapping, edge, token, base))
                break :blk false;
            break :blk true;
        },
        .unpack_product => |v| blk: {
            if (v.value == token) break :blk false;
            for (v.destinations) |slot| if (slot == token) break :blk false;
            break :blk try follow(a, ids, mapping, v.next, token, base);
        },
        .resume_value => |v| v.resumption == token and v.argument != token and
            (if (administrative) try administrativeResult(
                a,
                image,
                block.function,
                block.custody,
                v.next,
                budget,
            ) else returnsResult(image, block.function, v.next)),
        else => false,
    };
}

fn returnsResult(image: ir.Program, function: p.Id, edge: ir.Edge) bool {
    const target = image.blocks[@intCast(edge.block)];
    if (target.function != function or target.instructions.len != 0 or
        target.terminator != .return_value or edge.assignments.len != 1) return false;
    return edge.assignments[0].source == .returned and
        edge.assignments[0].destination == target.terminator.return_value;
}

// Discovery follows the identity of the resumed answer forward. Slot numbers
// are storage locations: moves overwrite their previous facts and each edge
// reads one simultaneous predecessor view.
fn administrativeResult(
    a: std.mem.Allocator,
    image: ir.Program,
    function: p.Id,
    custody: p.Id,
    first: ir.Edge,
    budget: ?*Budget,
) Error!bool {
    const count = image.functions[@intCast(function)].layout.slots.len;
    try take(budget, count);
    try take(budget, count);
    try take(budget, image.blocks.len);
    try charge(ir.Edge, first, budget);
    const aliases = try a.alloc(bool, count);
    defer a.free(aliases);
    const previous = try a.alloc(bool, count);
    defer a.free(previous);
    const seen = try a.alloc(bool, image.blocks.len);
    defer a.free(seen);
    @memset(aliases, false);
    @memset(seen, false);
    for (first.assignments) |assignment|
        aliases[@intCast(assignment.destination)] = assignment.source == .returned;
    var id = first.block;
    while (!seen[@intCast(id)]) {
        seen[@intCast(id)] = true;
        const block = image.blocks[@intCast(id)];
        try charge(ir.Block, block, budget);
        if (block.function != function or block.custody != custody) return false;
        for (block.instructions) |op| {
            if (op.opcode != .move or op.failures.len != 0 or op.operands.len != 1) return false;
            aliases[@intCast(op.destination)] = aliases[@intCast(op.operands[0])];
        }
        switch (block.terminator) {
            .return_value => |slot| return aliases[@intCast(slot)],
            .jump => |edge| {
                @memcpy(previous, aliases);
                for (edge.assignments) |assignment| {
                    if (assignment.source != .slot) return false;
                    aliases[
                        @intCast(assignment.destination)
                    ] = previous[
                        @intCast(assignment.source.slot)
                    ];
                }
                id = edge.block;
            },
            else => return false,
        }
    }
    return false;
}

// Certification uses a different direction: trace the final return backward
// through actual writes and parallel transfers until it reaches `.returned`
// on the original resumption edge. No discovery alias table is consumed.
fn certifyAdministrativeResult(
    a: std.mem.Allocator,
    image: ir.Program,
    function: p.Id,
    custody: p.Id,
    first: ir.Edge,
    budget: ?*Budget,
) Error!bool {
    try take(budget, image.blocks.len);
    const seen = try a.alloc(bool, image.blocks.len);
    defer a.free(seen);
    @memset(seen, false);
    var chain: std.ArrayList(p.Id) = .empty;
    defer chain.deinit(a);
    var id = first.block;
    var wanted: p.Id = undefined;
    while (!seen[@intCast(id)]) {
        seen[@intCast(id)] = true;
        const block = image.blocks[@intCast(id)];
        if (block.function != function or block.custody != custody) return false;
        for (block.instructions) |op|
            if (op.opcode != .move or op.failures.len != 0 or op.operands.len != 1) return false;
        try chain.append(a, id);
        switch (block.terminator) {
            .return_value => |slot| {
                wanted = slot;
                break;
            },
            .jump => |edge| {
                for (edge.assignments) |assignment| if (assignment.source != .slot) return false;
                id = edge.block;
            },
            else => return false,
        }
    } else return false;
    var cursor = chain.items.len;
    while (cursor != 0) {
        cursor -= 1;
        const block = image.blocks[@intCast(chain.items[cursor])];
        try charge(ir.Block, block, budget);
        var op_index = block.instructions.len;
        while (op_index != 0) {
            op_index -= 1;
            const op = block.instructions[op_index];
            if (op.destination == wanted) wanted = op.operands[0];
        }
        const incoming = if (cursor == 0) first else image.blocks[
            @intCast(chain.items[cursor - 1])
        ].terminator.jump;
        for (incoming.assignments) |assignment| if (assignment.destination == wanted) {
            switch (assignment.source) {
                .returned => return cursor == 0,
                .slot => |slot| wanted = slot,
            }
            break;
        };
    }
    return false;
}

const ParallelReturnsFixture = struct {
    const incoming: ir.Edge = .{ .block = 1, .assignments = &.{
        .{ .destination = 2, .source = .returned },
        .{ .destination = 3, .source = .{ .slot = 1 } },
    } };
    const blocks = [_]ir.Block{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .call = .{ .function = 1, .arguments = &.{0}, .next = incoming } },
        },
        .{ .function = 0, .instructions = &.{.{
            .destination = 0,
            .opcode = .move,
            .operands = &.{2},
        }}, .terminator = .{ .jump = .{ .block = 2, .assignments = &.{
            .{ .destination = 2, .source = .{ .slot = 0 } },
            .{ .destination = 0, .source = .{ .slot = 3 } },
        } } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{
            .function = 1,
            .instructions = &.{.{
                .destination = 1,
                .opcode = .integer_bit_not,
                .operands = &.{0},
            }},
            .terminator = .{ .return_value = 1 },
        },
    };
};

test "administrative-return proofs preserve parallel writes and reject changed answers" {
    const a = std.testing.allocator;
    const incoming = ParallelReturnsFixture.incoming;
    var blocks = ParallelReturnsFixture.blocks;
    const image: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{
            .{
                .entry = 0,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 0, 0, 0, 0 } },
                .result = 0,
            },
            .{ .entry = 3, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 0 } }, .result = 0 },
        },
        .blocks = &blocks,
    };
    var checked = try @import("activation_ownership.zig").analyze(a, image);
    checked.deinit();
    try validate(a, image, image);
    try std.testing.expect(!returnsResult(image, 0, incoming));
    try std.testing.expect(try administrativeResult(a, image, 0, 0, incoming, null));
    try std.testing.expect(try certifyAdministrativeResult(a, image, 0, 0, incoming, null));
    blocks[2].terminator = .{ .return_value = 0 };
    checked = try @import("activation_ownership.zig").analyze(a, image);
    checked.deinit();
    try std.testing.expect(!try administrativeResult(a, image, 0, 0, incoming, null));
    try std.testing.expect(!try certifyAdministrativeResult(a, image, 0, 0, incoming, null));
    blocks[2].terminator = .{ .return_value = 2 };
    blocks[1].instructions = &.{.{
        .destination = 0,
        .opcode = .integer_bit_not,
        .operands = &.{2},
    }};
    checked = try @import("activation_ownership.zig").analyze(a, image);
    checked.deinit();
    try std.testing.expect(!try administrativeResult(a, image, 0, 0, incoming, null));
    try std.testing.expect(!try certifyAdministrativeResult(a, image, 0, 0, incoming, null));
    blocks[1].instructions = &.{.{ .destination = 0, .opcode = .move, .operands = &.{2} }};
    blocks[2].terminator = .{ .jump = .{ .block = 1 } };
    checked = try @import("activation_ownership.zig").analyze(a, image);
    checked.deinit();
    try std.testing.expect(!try administrativeResult(a, image, 0, 0, incoming, null));
    try std.testing.expect(!try certifyAdministrativeResult(a, image, 0, 0, incoming, null));
}

fn remapEdge(value: ir.Edge, mapping: *const std.AutoHashMapUnmanaged(p.Id, p.Id)) ir.Edge {
    var result = value;
    result.block = mapping.get(value.block).?;
    return result;
}

fn remap(
    a: std.mem.Allocator,
    value: ir.Terminator,
    mapping: *const std.AutoHashMapUnmanaged(p.Id, p.Id),
) Error!ir.Terminator {
    return switch (value) {
        .jump => |v| .{ .jump = remapEdge(v, mapping) },
        .branch => |v| .{ .branch = .{
            .condition = v.condition,
            .when_true = remapEdge(v.when_true, mapping),
            .when_false = remapEdge(v.when_false, mapping),
        } },
        .resume_value => |v| .{ .return_value = v.argument },
        .switch_variant => |v| blk: {
            const cases = try a.alloc(ir.Edge, v.cases.len);
            for (cases, v.cases) |*target, original| target.* = remapEdge(original, mapping);
            break :blk .{ .switch_variant = .{ .value = v.value, .cases = cases } };
        },
        .unpack_product => |v| .{ .unpack_product = .{
            .value = v.value,
            .destinations = v.destinations,
            .next = remapEdge(v.next, mapping),
        } },
        // discover rejects every other terminator before any copying starts.
        else => unreachable,
    };
}

const AdministrativeJoinFixture = struct {
    const original: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{
            .u64,                                  .unit, .boolean,
            .{ .internal = .{ .computation = .{
                .parameters = &.{5},
                .result = 0,
                .effects = &.{0},
                .capture_bound = &.{0},
            } } },
            .{ .internal = .{ .resumption = .{
                .effect = 0,
                .input = 0,
                .answer = 0,
                .handled = &.{0},
                .capture_bound = &.{ 0, 5 },
                .mode = .deep,
                .use = .linear,
            } } },
            .{ .internal = .{ .capability = 0 } },
        },
        .constants = &.{},
        .effects = &.{.{
            .identity = "test.tail.admin",
            .payload = 0,
            .result = 0,
            .external = false,
        }},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 3, 0 } }, .result = 0 },
            .{
                .entry = 2,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 0, 5, 0, 0 } },
                .result = 0,
                .effects = &.{0},
            },
            .{ .entry = 4, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
            .{
                .entry = 5,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 0, 4, 0, 0 } },
                .result = 0,
            },
        },
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{.{
                    .destination = 1,
                    .opcode = .computation,
                    .operands = &.{0},
                    .immediate = 0,
                }},
                .terminator = .{ .handle = .{
                    .handler = 0,
                    .body = 1,
                    .arguments = &.{},
                    .state = &.{},
                    .next = .{
                        .block = 1,
                        .assignments = &.{.{ .destination = 2, .source = .returned }},
                    },
                } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
            .{
                .function = 1,
                .instructions = &.{},
                .terminator = .{ .perform = .{
                    .effect = 0,
                    .capability = 1,
                    .payload = 0,
                    .next = .{
                        .block = 3,
                        .assignments = &.{.{ .destination = 2, .source = .returned }},
                    },
                } },
            },
            .{
                .function = 1,
                .instructions = &.{.{
                    .destination = 3,
                    .opcode = .integer_bit_not,
                    .operands = &.{2},
                }},
                .terminator = .{ .return_value = 3 },
            },
            .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{
                .function = 3,
                .instructions = &.{},
                .terminator = .{ .resume_value = .{
                    .resumption = 1,
                    .argument = 0,
                    .next = .{
                        .block = 6,
                        .assignments = &.{
                            .{ .destination = 2, .source = .returned },
                            .{ .destination = 3, .source = .{ .slot = 0 } },
                        },
                    },
                } },
            },
            .{
                .function = 3,
                .instructions = &.{.{ .destination = 0, .opcode = .move, .operands = &.{2} }},
                .terminator = .{ .jump = .{
                    .block = 7,
                    .assignments = &.{
                        .{ .destination = 2, .source = .{ .slot = 0 } },
                        .{ .destination = 0, .source = .{ .slot = 3 } },
                    },
                } },
            },
            .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        },
        .handlers = &.{.{
            .mode = .deep,
            .input = 0,
            .answer = 0,
            .return_function = 2,
            .clauses = &.{.{ .effect = 0, .function = 3, .resumption = 4 }},
        }},
        .constructors = &.{.{ .function = 1, .capture = 0, .schema = 3 }},
        .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
    };
};

test "a general resumption with an administrative join becomes a checked tail clause" {
    const a = std.testing.allocator;
    const original = AdministrativeJoinFixture.original;
    var admitted = try @import("activation_ownership.zig").analyze(a, original);
    admitted.deinit();
    const AllocationProbe = struct {
        fn execute(allocator: std.mem.Allocator, program: ir.Program) !void {
            var result = try run(allocator, program, null, .{});
            defer result.deinit();
        }
    };
    try @import("allocation_testing.zig").check(a, AllocationProbe.execute, .{original});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const uses = try traits.derive(scratch, original.schemas);
    var stats: Statistics = .{};
    var owned = try run(a, original, &stats, .{});
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.clauses_selected);
    try std.testing.expect(!stats.work_limit);
    try std.testing.expect(owned.program.handlers[0].clauses[0].strategy == .tail);
    var limited = try run(a, original, &stats, .{ .work_limit = 0 });
    defer limited.deinit();
    try std.testing.expect(stats.work_limit);
    try std.testing.expect(limited.program.handlers[0].clauses[0].strategy == .general);
    var invalid = original;
    invalid.roots.entry = 999;
    try std.testing.expectError(
        error.InvalidReference,
        run(a, invalid, null, .{ .work_limit = 0 }),
    );
    const structural = try optimize(scratch, original, uses);
    try std.testing.expectEqual(
        ir.Clause{ .effect = 0, .function = 3, .resumption = 4 },
        structural.handlers[0].clauses[0],
    );
    const candidate = try transform(scratch, original, uses, true, null);
    try std.testing.expect(candidate.handlers[0].clauses[0].strategy == .tail);
    try std.testing.expectEqual(original.functions.len + 1, candidate.functions.len);
    try validate(a, original, candidate);
    var measured: Budget = .{ .remaining = std.math.maxInt(u64) };
    _ = try transform(scratch, original, uses, true, &measured);
    const construction_work = std.math.maxInt(u64) - measured.remaining;
    try std.testing.expect(construction_work > 1);
    var late_limit = try run(a, original, &stats, .{ .work_limit = construction_work - 1 });
    defer late_limit.deinit();
    try std.testing.expect(stats.work_limit);
    const image_codec = @import("program_image.zig");
    try std.testing.expectEqual(
        try image_codec.identity(a, limited.program),
        try image_codec.identity(a, late_limit.program),
    );
    try checkChangedAnswer(a, scratch, original);
    try checkShallowClause(a, scratch, original);
    try checkEffectfulClause(a, scratch, original);
    try checkMutatedClause(a, scratch, original, candidate);
}

fn checkChangedAnswer(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
) !void {
    var stats: Statistics = .{};
    var changed_answer = original;
    const changed_blocks = try scratch.dupe(ir.Block, original.blocks);
    changed_blocks[7].terminator = .{ .return_value = 0 };
    changed_answer.blocks = changed_blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, changed_answer);
    admitted.deinit();
    var retained = try run(a, changed_answer, &stats, .{});
    defer retained.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.clauses_selected);
    try std.testing.expect(!stats.work_limit);
    try std.testing.expect(retained.program.handlers[0].clauses[0].strategy == .general);
}

fn checkShallowClause(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
) !void {
    var stats: Statistics = .{};
    var shallow = original;
    const shallow_schemas = try scratch.dupe(p.Schema, original.schemas);
    shallow_schemas[4].internal.resumption.mode = .shallow;
    shallow_schemas[4].internal.resumption.effects = &.{0};
    shallow_schemas[4].internal.resumption.capture_bound = &.{0};
    const shallow_handlers = try scratch.dupe(ir.Handler, original.handlers);
    shallow_handlers[0].mode = .shallow;
    const shallow_blocks = try scratch.dupe(ir.Block, original.blocks);
    shallow_blocks[5].terminator = .{ .resume_with = .{
        .resumption = 1,
        .argument = 0,
        .handler = 0,
        .next = original.blocks[5].terminator.resume_value.next,
    } };
    shallow.schemas = shallow_schemas;
    shallow.handlers = shallow_handlers;
    shallow.blocks = shallow_blocks;
    var admitted = @import("activation_ownership.zig").analyze(a, shallow) catch |err| {
        std.debug.print("shallow admission: {any}\n", .{err});
        return err;
    };
    admitted.deinit();
    var shallow_result = try run(a, shallow, &stats, .{});
    defer shallow_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.clauses_selected);
    try std.testing.expect(shallow_result.program.handlers[0].clauses[0].strategy == .general);
}

fn checkEffectfulClause(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
) !void {
    var stats: Statistics = .{};
    var effectful = original;
    const functions = try scratch.dupe(ir.Function, original.functions);
    functions[0].effects = &.{1};
    functions[3].effects = &.{1};
    const effect_schemas = try scratch.dupe(p.Schema, original.schemas);
    effect_schemas[4].internal.resumption.effects = &.{1};
    const effect_handlers = try scratch.dupe(ir.Handler, original.handlers);
    effect_handlers[0].effects = &.{1};
    const effect_blocks = try scratch.alloc(ir.Block, original.blocks.len + 1);
    @memcpy(effect_blocks[0..original.blocks.len], original.blocks);
    effect_blocks[8] = original.blocks[5];
    effect_blocks[5].terminator = .{ .perform = .{
        .effect = 1,
        .payload = 0,
        .next = .{ .block = 8 },
    } };
    effectful.functions = functions;
    effectful.schemas = effect_schemas;
    effectful.handlers = effect_handlers;
    effectful.blocks = effect_blocks;
    effectful.effects = &.{
        original.effects[0],
        .{ .identity = "test.before-resumption", .payload = 0, .result = 0 },
    };
    var admitted = @import("activation_ownership.zig").analyze(a, effectful) catch |err| {
        std.debug.print("effectful admission: {any}\n", .{err});
        return err;
    };
    admitted.deinit();
    var effect_result = try run(a, effectful, &stats, .{});
    defer effect_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.clauses_selected);
    try std.testing.expect(effect_result.program.handlers[0].clauses[0].strategy == .general);
}

fn checkMutatedClause(
    a: std.mem.Allocator,
    scratch: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
) !void {
    const selected = candidate.functions[@intCast(candidate.handlers[0].clauses[0].function)];
    try std.testing.expectEqual(@as(usize, 1), selected.inputs.len);
    try std.testing.expect(candidate.blocks[@intCast(selected.entry)].terminator == .return_value);
    var mutant = candidate;
    const blocks = try scratch.dupe(ir.Block, candidate.blocks);
    blocks[@intCast(selected.entry)].instructions = &.{.{
        .destination = 2,
        .opcode = .integer_bit_not,
        .operands = &.{0},
    }};
    blocks[@intCast(selected.entry)].terminator = .{ .return_value = 2 };
    mutant.blocks = blocks;
    var admitted = try @import("activation_ownership.zig").analyze(a, mutant);
    admitted.deinit();
    try std.testing.expectError(error.InvalidTailClause, validate(a, original, mutant));
}
