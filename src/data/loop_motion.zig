// Copyright (c) 2026 Boundary contributors. MIT license.
//! P18: guarded entry hoisting of stable total scalar definitions.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const flow = @import("activation_flow.zig");
const traits = @import("traits.zig");
const admission = @import("admission.zig");
const loops = @import("loop_regions.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
pub const Error = p01.Error || loops.Error || error{InvalidLoopMotion};
pub const Options = struct { work_limit: u64 = 2_000_000, coalescing: p01.Options = .{} };
pub const Statistics = struct {
    hoisted: usize = 0,
    guarded_entries: usize = 0,
    reused_preheaders: usize = 0,
    work_limit: bool = false,
};
pub const Placement = enum { guarded, preheader, append };
pub const Witness = struct {
    header: usize,
    body: usize,
    instructions: []const usize,
    placement: Placement = .guarded,
    predecessor: ?usize = null,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    witness: Witness,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
fn scalar(schema: p.Schema) bool {
    return switch (schema) {
        .boolean, .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 => true,
        else => false,
    };
}
fn scalarOperation(program: ir.Program, function: usize, op: ir.Instruction) bool {
    if (op.failures.len != 0) return false;
    const slots = program.functions[function].layout.slots;
    if (!scalar(program.schemas[@intCast(slots[@intCast(op.destination)])])) return false;
    for (op.operands) |slot| if (!scalar(
        program.schemas[
            @intCast(slots[
                @intCast(slot)
            ])
        ],
    )) return false;
    return switch (op.opcode) {
        .constant,
        .integer_bit_not,
        .integer_bit_and,
        .integer_bit_or,
        .integer_bit_xor,
        .boolean_not,
        .equal,
        .less,
        .select,
        => true,
        else => false,
    };
}
fn eligible(program: ir.Program, function: usize, op: ir.Instruction) bool {
    if (!scalarOperation(program, function, op)) return false;
    for (op.operands) |slot| if (slot == op.destination) return false;
    return true;
}
/// Heuristic repeated work: scalar operations weighted by natural-loop nesting.
/// Direct branch-condition producers are excluded so guarded entry copies do
/// not masquerade as repeated body work. This is not a latency measurement.
pub const RepeatedWork = struct { scalars: u64 = 0, branch_tests: u64 = 0 };
pub fn repeatedScalarWork(
    allocator: std.mem.Allocator,
    program: ir.Program,
) std.mem.Allocator.Error!?u64 {
    const result = (try repeatedWorkEstimate(allocator, program)) orelse return null;
    return result.scalars;
}
pub fn repeatedWorkEstimate(
    allocator: std.mem.Allocator,
    program: ir.Program,
) std.mem.Allocator.Error!?RepeatedWork {
    return repeatedWork(allocator, program) catch |err| switch (err) {
        error.LoopWorkLimit => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}
fn repeatedWork(allocator: std.mem.Allocator, program: ir.Program) loops.Error!RepeatedWork {
    if (!possible(program)) return .{};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var budget: loops.Budget = .{ .remaining = 1_000_000 };
    try budget.record(ir.Program, program);
    var total: RepeatedWork = .{};
    for (program.functions, 0..) |_, fid| {
        const graph = (try loops.Graph.init(a, program, fid, &budget)) orelse continue;
        if (!try graph.cyclic(&budget)) continue;
        const dom = try graph.dominators(&budget);
        const dominated = try a.alloc(bool, graph.blocks.len);
        for (graph.blocks, 0..) |_, h| {
            try budget.take(1);
            if (!graph.reachable[h]) continue;
            for (dominated, 0..) |*value, node| value.* = dom[node * graph.blocks.len + h];
            const members = (try graph.region(h, dominated, &budget)) orelse continue;
            for (graph.blocks, members) |bid, inside|
                if (inside) {
                    const block = program.blocks[bid];
                    var local_condition = false;
                    for (block.instructions) |op| {
                        try budget.take(1);
                        if (block.terminator == .branch and
                            block.terminator.branch.condition == op.destination)
                        {
                            local_condition = true;
                            continue;
                        }
                        if (scalarOperation(program, fid, op)) total.scalars +|= 1;
                    }
                    // Prefer a removed dispatch block, not merely replacing a
                    // condition read with a same-cost jump after a live prefix.
                    if (block.terminator == .branch and
                        !local_condition and
                        block.instructions.len == 0)
                    {
                        const branch = block.terminator.branch;
                        if ((branch.when_true.assignments.len == 0 and
                            branch.when_true.block != bid) or
                            (branch.when_false.assignments.len == 0 and
                                branch.when_false.block != bid))
                            total.branch_tests +|= 1;
                    }
                };
        }
    }
    return total;
}
fn functionAllowed(
    program: ir.Program,
    id: usize,
    permissions: traits.Facts,
    exportable: []const bool,
    budget: *loops.Budget,
) Error!bool {
    const f = program.functions[id];
    if (f.effects.len != 0 or f.regions.len != 0 or f.custody.len != 1) return false;
    for (f.layout.slots) |schema| {
        try budget.take(1);
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ] or !exportable[
            @intCast(schema)
        ]) return false;
    }
    for (program.blocks) |block| if (block.function == id) {
        try budget.take(1);
        if (block.custody != 0 or !loops.supported(block.terminator)) return false;
    };
    return true;
}
fn written(edge: ir.Edge, slot: p.Id) bool {
    for (edge.assignments) |assignment|
        if (assignment.destination == slot and
            (assignment.source != .slot or
                assignment.source.slot != slot))
            return true;
    return false;
}
fn stableDefinition(
    program: ir.Program,
    graph: loops.Graph,
    members: []const bool,
    header: usize,
    body: usize,
    index: usize,
    selected: []const usize,
    facts: *const flow.Facts,
    budget: *loops.Budget,
) Error!bool {
    const op = program.blocks[body].instructions[index];
    if (!eligible(program, graph.function, op)) return false;
    for (program.blocks[body].instructions[0..index]) |before| {
        try budget.take(1);
        if (std.mem.indexOfScalar(p.Id, before.operands, op.destination) != null) return false;
    }
    for (members, graph.blocks) |inside, bid| if (inside) {
        for (program.blocks[bid].instructions, 0..) |other, at| {
            try budget.take(1);
            if (other.destination == op.destination and (bid != body or at != index)) return false;
        }
        var ordinal: usize = 0;
        while (loops.edge(program.blocks[bid].terminator, ordinal)) |e| : (ordinal += 1) {
            try budget.take(1);
            if (written(e, op.destination)) return false;
        }
    };
    for (op.operands) |operand| {
        var from_selected = false;
        for (selected) |at| if (program.blocks[body].instructions[at].destination == operand) {
            from_selected = true;
            break;
        };
        if (from_selected) continue;
        if (!facts.pool.contains(
            facts.positions[header][program.blocks[header].instructions.len].available,
            operand,
        )) return false;
        for (members, graph.blocks) |inside, bid| if (inside) {
            for (program.blocks[bid].instructions) |other| {
                try budget.take(1);
                if (other.destination == operand) return false;
            }
            var ordinal: usize = 0;
            while (loops.edge(program.blocks[bid].terminator, ordinal)) |e| : (ordinal += 1) {
                try budget.take(1);
                if (written(e, operand)) return false;
            }
        };
    }
    return true;
}
fn bodyFor(program: ir.Program, graph: loops.Graph, members: []const bool, header: usize) ?usize {
    const block = program.blocks[header];
    if (block.terminator != .branch) return null;
    const branch = block.terminator.branch;
    const yes: usize = @intCast(branch.when_true.block);
    const no: usize = @intCast(branch.when_false.block);
    const yi = members[graph.local[yes]];
    const ni = members[graph.local[no]];
    if (yi == ni) return null;
    const body = if (yi) yes else no;
    return if (body == header) null else body;
}
fn redirect(a: std.mem.Allocator, term: ir.Terminator, old: usize, new: usize) !ir.Terminator {
    var result = term;
    switch (result) {
        .jump => |*e| if (e.block == old) {
            e.block = new;
        },
        .branch => |*b| {
            if (b.when_true.block == old) b.when_true.block = new;
            if (b.when_false.block == old) b.when_false.block = new;
        },
        .switch_variant => |*s| {
            const cases = try a.dupe(ir.Edge, s.cases);
            for (cases) |*e| if (e.block == old) {
                e.block = new;
            };
            s.cases = cases;
        },
        else => {},
    }
    return result;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    var facts = try own.analyze(allocator, original);
    defer facts.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    try budget.record(ir.Program, original);
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    for (original.functions, 0..) |_, fid| {
        if (!try functionAllowed(original, fid, permissions, schemas.exportable, &budget)) continue;
        const graph = (try loops.Graph.init(a, original, fid, &budget)) orelse continue;
        if (!try graph.cyclic(&budget)) continue;
        const dom = try graph.dominators(&budget);
        const n = graph.blocks.len;
        for (graph.blocks, 0..) |header, h| {
            try budget.take(1);
            if (!graph.reachable[h] or original.blocks[header].terminator != .branch) continue;
            const dominated = try a.alloc(bool, n);
            for (dominated, 0..) |*v, node| v.* = dom[node * n + h];
            const members = (try graph.region(h, dominated, &budget)) orelse continue;
            const body = bodyFor(original, graph, members, header) orelse continue;
            var selected: std.ArrayList(usize) = .empty;
            for (original.blocks[body].instructions, 0..) |_, index| {
                try budget.take(1);
                if (try stableDefinition(
                    original,
                    graph,
                    members,
                    header,
                    body,
                    index,
                    selected.items,
                    &facts,
                    &budget,
                )) try selected.append(a, index);
            }
            if (selected.items.len == 0) continue;
            var needs_guard = false;
            for (selected.items) |index| if (facts.pool.contains(
                facts.live[header][0],
                original.blocks[body].instructions[index].destination,
            )) {
                needs_guard = true;
            };
            var placement: Placement = if (needs_guard) .guarded else .preheader;
            var predecessor: ?usize = null;
            if (!needs_guard and original.functions[fid].entry != header) {
                var incoming: usize = 0;
                for (graph.blocks, 0..) |bid, node| if (!members[node]) {
                    var ordinal: usize = 0;
                    while (loops.edge(
                        original.blocks[bid].terminator,
                        ordinal,
                    )) |e| : (ordinal += 1) {
                        try budget.take(1);
                        if (e.block == header) {
                            incoming += 1;
                            predecessor = bid;
                        }
                    }
                };
                if (incoming == 1) {
                    const term = original.blocks[predecessor.?].terminator;
                    if (term == .jump and term.jump.assignments.len == 0) placement = .append;
                }
            }
            if (placement != .append) predecessor = null;
            const added: usize = switch (placement) {
                .guarded => 2,
                .preheader => 1,
                .append => 0,
            };
            const functions = try a.dupe(ir.Function, original.functions);
            const blocks = try a.alloc(
                ir.Block,
                std.math.add(usize, original.blocks.len, added) catch return error.Capacity,
            );
            @memcpy(blocks[0..original.blocks.len], original.blocks);
            const entry = original.blocks.len;
            const moved = try a.alloc(ir.Instruction, selected.items.len);
            for (
                selected.items,
                moved,
            ) |index, *op| op.* = original.blocks[body].instructions[index];
            if (placement == .append) {
                const before = original.blocks[predecessor.?].instructions;
                const operations = try a.alloc(ir.Instruction, before.len + moved.len);
                @memcpy(operations[0..before.len], before);
                @memcpy(operations[before.len..], moved);
                blocks[predecessor.?].instructions = operations;
            } else {
                for (graph.blocks, 0..) |bid, node| if (!members[node]) {
                    blocks[bid].terminator = try redirect(
                        a,
                        original.blocks[bid].terminator,
                        header,
                        entry,
                    );
                };
                if (functions[fid].entry == header) functions[fid].entry = entry;
                if (placement == .guarded) {
                    blocks[entry] = original.blocks[header];
                    blocks[entry].terminator = try redirect(
                        a,
                        blocks[entry].terminator,
                        body,
                        entry + 1,
                    );
                    blocks[entry + 1] = .{
                        .function = fid,
                        .custody = original.blocks[body].custody,
                        .instructions = moved,
                        .terminator = .{ .jump = .{ .block = body } },
                    };
                } else blocks[entry] = .{
                    .function = fid,
                    .custody = original.blocks[header].custody,
                    .instructions = moved,
                    .terminator = .{ .jump = .{ .block = header } },
                };
            }
            const retained = try a.alloc(
                ir.Instruction,
                original.blocks[body].instructions.len - moved.len,
            );
            var at: usize = 0;
            for (
                original.blocks[body].instructions,
                0..,
            ) |op, index| if (std.mem.indexOfScalar(usize, selected.items, index) == null) {
                retained[at] = op;
                at += 1;
            };
            blocks[body].instructions = retained;
            var program = original;
            program.functions = functions;
            program.blocks = blocks;
            const selected_indices = try selected.toOwnedSlice(a);
            keep = true;
            return .{
                .arena = arena,
                .program = program,
                .witness = .{
                    .header = header,
                    .body = body,
                    .instructions = selected_indices,
                    .placement = placement,
                    .predecessor = predecessor,
                },
            };
        }
    }
    return null;
}
fn sameRedirect(old: ir.Terminator, new: ir.Terminator, from: usize, to: usize) bool {
    if (std.meta.activeTag(old) != std.meta.activeTag(new)) return false;
    switch (old) {
        .branch => |v| if (v.condition != new.branch.condition) {
            return false;
        },
        .switch_variant => |v| if (v.value != new.switch_variant.value or
            v.cases.len != new.switch_variant.cases.len)
        {
            return false;
        },
        .return_value, .fail => return equal(ir.Terminator, old, new),
        .jump => {},
        else => return false,
    }
    var ordinal: usize = 0;
    while (loops.edge(old, ordinal)) |before| : (ordinal += 1) {
        const after = loops.edge(new, ordinal) orelse return false;
        if (after.block != (if (before.block == from) to else before.block) or !equal(
            []const ir.Assignment,
            before.assignments,
            after.assignments,
        )) return false;
    }
    return true;
}
/// Independent acceptance uses a reachability cut (not the discovery dominator
/// matrix), then forward fixed-version propagation over the requested batch.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witness: Witness,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var budget: loops.Budget = .{ .remaining = options.work_limit };
    try budget.record(ir.Program, original);
    try budget.record(ir.Program, candidate);
    if (witness.header >= original.blocks.len or
        witness.body >= original.blocks.len or
        witness.instructions.len == 0 or
        candidate.blocks.len != original.blocks.len + @as(
            usize,
            switch (witness.placement) {
                .guarded => 2,
                .preheader => 1,
                .append => 0,
            },
        ) or
        candidate.functions.len != original.functions.len)
        return error.InvalidLoopMotion;
    const fid: usize = @intCast(original.blocks[witness.header].function);
    const permissions = try traits.derive(a, original.schemas);
    const schemas = try admission.schemas(a, original.schemas);
    if (!try functionAllowed(
        original,
        fid,
        permissions,
        schemas.exportable,
        &budget,
    )) return error.InvalidLoopMotion;
    const graph = (try loops.Graph.init(
        a,
        original,
        fid,
        &budget,
    )) orelse return error.InvalidLoopMotion;
    const h = graph.local[witness.header];
    const outside = try graph.reachAvoid(h, &budget);
    const dominated = try a.alloc(bool, graph.blocks.len);
    for (dominated, 0..) |*v, node| v.* = graph.reachable[node] and !outside[node];
    const members = (try graph.region(h, dominated, &budget)) orelse return error.InvalidLoopMotion;
    if (bodyFor(
        original,
        graph,
        members,
        witness.header,
    ) != witness.body) return error.InvalidLoopMotion;
    if (witness.placement == .append) {
        const pred = witness.predecessor orelse return error.InvalidLoopMotion;
        if (pred >= original.blocks.len or
            original.blocks[pred].function != fid or
            members[graph.local[pred]] or
            original.functions[fid].entry == witness.header)
            return error.InvalidLoopMotion;
        const term = original.blocks[pred].terminator;
        if (term != .jump or
            term.jump.block != witness.header or
            term.jump.assignments.len != 0)
            return error.InvalidLoopMotion;
        var incoming: usize = 0;
        for (graph.predecessors[h].items) |node| if (!members[node]) {
            try budget.take(1);
            if (graph.blocks[node] != pred) return error.InvalidLoopMotion;
            incoming += 1;
        };
        if (incoming != 1) return error.InvalidLoopMotion;
    } else if (witness.predecessor != null) return error.InvalidLoopMotion;
    const function = original.functions[fid];
    const fixed = try a.alloc(bool, function.layout.slots.len);
    const definitions = try a.alloc(usize, fixed.len);
    @memset(definitions, 0);
    const edge_writes = try a.alloc(bool, fixed.len);
    @memset(edge_writes, false);
    if (before.positions[witness.header].len == 0) return error.InvalidLoopMotion;
    for (
        fixed,
        0..,
    ) |*v, slot|
        v.* = before.pool.contains(
            before.positions[witness.header][original.blocks[witness.header].instructions.len].available,
            slot,
        );
    for (members, graph.blocks) |inside, bid| if (inside) {
        for (original.blocks[bid].instructions) |op| {
            try budget.take(1);
            fixed[@intCast(op.destination)] = false;
            definitions[@intCast(op.destination)] += 1;
        }
        var ordinal: usize = 0;
        while (loops.edge(
            original.blocks[bid].terminator,
            ordinal,
        )) |e| : (ordinal += 1) for (e.assignments) |assignment| {
            try budget.take(1);
            if (assignment.source != .slot or assignment.source.slot != assignment.destination) {
                fixed[@intCast(assignment.destination)] = false;
                edge_writes[@intCast(assignment.destination)] = true;
            }
        };
    };
    const body = original.blocks[witness.body];
    for (witness.instructions, 0..) |index, position| {
        try budget.take(1);
        if (index >= body.instructions.len or
            (position != 0 and
                witness.instructions[position - 1] >= index))
            return error.InvalidLoopMotion;
        const op = body.instructions[index];
        if (witness.placement != .guarded and before.pool.contains(
            before.live[witness.header][0],
            op.destination,
        )) return error.InvalidLoopMotion;
        if (!eligible(original, fid, op) or definitions[
            @intCast(op.destination)
        ] != 1 or edge_writes[
            @intCast(op.destination)
        ]) return error.InvalidLoopMotion;
        for (op.operands) |operand| if (!fixed[@intCast(operand)]) return error.InvalidLoopMotion;
        for (body.instructions[0..index]) |earlier| {
            try budget.take(1);
            if (std.mem.indexOfScalar(
                p.Id,
                earlier.operands,
                op.destination,
            ) != null) return error.InvalidLoopMotion;
        }
        fixed[@intCast(op.destination)] = true;
    }
    var rest = candidate;
    rest.functions = original.functions;
    rest.blocks = original.blocks;
    if (!equal(ir.Program, original, rest)) return error.InvalidLoopMotion;
    const entry = original.blocks.len;
    const hoist = entry + 1;
    for (original.functions, candidate.functions, 0..) |old, new, id| {
        var metadata = new;
        if (id == fid and old.entry == witness.header and witness.placement != .append) {
            if (new.entry != entry) return error.InvalidLoopMotion;
            metadata.entry = old.entry;
        }
        if (!equal(ir.Function, old, metadata)) return error.InvalidLoopMotion;
    }
    for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
        try budget.take(1);
        if (old.function != new.function or
            old.custody != new.custody)
            return error.InvalidLoopMotion;
        if (bid == witness.body) {
            if (new.instructions.len != old.instructions.len - witness.instructions.len)
                return error.InvalidLoopMotion;
            var at: usize = 0;
            for (
                old.instructions,
                0..,
            ) |op, index| if (std.mem.indexOfScalar(
                usize,
                witness.instructions,
                index,
            ) == null) {
                if (!equal(
                    ir.Instruction,
                    op,
                    new.instructions[at],
                )) return error.InvalidLoopMotion;
                at += 1;
            };
        } else if (witness.placement == .append and bid == witness.predecessor.?) {
            if (new.instructions.len != old.instructions.len + witness.instructions.len or !equal(
                []const ir.Instruction,
                old.instructions,
                new.instructions[0..old.instructions.len],
            )) return error.InvalidLoopMotion;
            for (
                witness.instructions,
                0..,
            ) |index, i| if (!equal(
                ir.Instruction,
                body.instructions[index],
                new.instructions[old.instructions.len + i],
            )) return error.InvalidLoopMotion;
        } else if (!equal(
            []const ir.Instruction,
            old.instructions,
            new.instructions,
        )) return error.InvalidLoopMotion;
        if (witness.placement != .append and old.function == fid and !members[graph.local[bid]]) {
            if (!sameRedirect(
                old.terminator,
                new.terminator,
                witness.header,
                entry,
            )) return error.InvalidLoopMotion;
        } else if (!equal(
            ir.Terminator,
            old.terminator,
            new.terminator,
        )) return error.InvalidLoopMotion;
    }
    if (witness.placement != .append) {
        const preheader = candidate.blocks[entry];
        const moved = candidate.blocks[if (witness.placement == .guarded) hoist else entry];
        const old_header = original.blocks[witness.header];
        if (witness.placement == .guarded and
            (preheader.function != fid or
                preheader.custody != old_header.custody or
                !equal(
                    []const ir.Instruction,
                    preheader.instructions,
                    old_header.instructions,
                ) or
                !sameRedirect(old_header.terminator, preheader.terminator, witness.body, hoist)))
            return error.InvalidLoopMotion;
        const destination = if (witness.placement == .guarded) witness.body else witness.header;
        if (moved.function != fid or
            moved.custody != body.custody or
            moved.instructions.len != witness.instructions.len or
            !equal(ir.Terminator, .{ .jump = .{ .block = destination } }, moved.terminator))
            return error.InvalidLoopMotion;
        for (
            moved.instructions,
            witness.instructions,
        ) |op, index| if (!equal(
            ir.Instruction,
            op,
            body.instructions[index],
        )) return error.InvalidLoopMotion;
    }
}
pub fn possible(program: ir.Program) bool {
    for (program.blocks, 0..) |block, id| {
        var ordinal: usize = 0;
        while (loops.edge(
            block.terminator,
            ordinal,
        )) |e| : (ordinal += 1) if (e.block <= id) return true;
    }
    return false;
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
        error.LoopWorkLimit => {
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
        error.LoopWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    const result = try p01.run(allocator, candidate.program, options.coalescing);
    stats.hoisted = candidate.witness.instructions.len;
    stats.guarded_entries = @intFromBool(candidate.witness.placement == .guarded);
    stats.reused_preheaders = @intFromBool(candidate.witness.placement == .append);
    return result;
}
