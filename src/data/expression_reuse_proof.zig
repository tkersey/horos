const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const equal = @import("record_equal.zig").equal;
const coalescing = @import("coalescing.zig");
const Error = coalescing.Error || error{ExpressionWorkLimit};
pub const Location = struct { block: usize, instruction: usize };
pub const Witness = struct { target: Location, source: Location };
pub const Definition = struct {
    location: Location,
    function: p.Id,
    instruction: ir.Instruction,
    schema: p.Id,
};
pub const Limits = struct {
    work: u64 = 1_000_000_000,
    witnesses: usize = 4096,
    depth: usize = 256,
    temporary_bytes: usize = 256 << 20,
};
pub const Budget = struct {
    limits: Limits = .{},
    strict: bool = false,
    capture_boundary: bool = false,
    bytes_remaining: usize = 0,
    remaining: u64,
    exhausted: bool = false,

    pub fn init(limits: Limits) Budget {
        return .{
            .limits = limits,
            .remaining = limits.work,
            .bytes_remaining = limits.temporary_bytes,
            .strict = true,
        };
    }
    pub fn workUsed(self: Budget) u64 {
        return self.limits.work - self.remaining;
    }
    pub fn charge(self: *Budget, amount: usize) bool {
        if (self.remaining < amount) {
            self.exhausted = true;
            return false;
        }
        self.remaining -= amount;
        return true;
    }
    pub fn tick(self: *Budget) bool {
        return self.charge(1);
    }
};
pub fn sameExpression(left: ir.Instruction, right: ir.Instruction) bool {
    var normalized = right;
    normalized.destination = left.destination;
    return equal(ir.Instruction, left, normalized);
}
pub fn relevant(definition: Definition, slot: p.Id) bool {
    return definition.instruction.destination == slot or std.mem.indexOfScalar(
        p.Id,
        definition.instruction.operands,
        slot,
    ) != null;
}
pub fn edgePreserves(definition: Definition, edge: ir.Edge, overwritten: []const p.Id) bool {
    for (overwritten) |slot| if (relevant(definition, slot)) return false;
    for (edge.assignments) |assignment| {
        if (!relevant(definition, assignment.destination)) continue;
        if (assignment.source != .slot or
            assignment.source.slot != assignment.destination)
            return false;
    }
    return true;
}
const Incoming = struct {
    edge: ir.Edge,
    overwritten: []const p.Id = &.{},
    capture_boundary: bool = false,
};
pub const Predecessor = struct { block: usize, transfer: Incoming };
pub fn indexPredecessors(
    allocator: std.mem.Allocator,
    program: ir.Program,
    budget: *Budget,
) Error![]std.ArrayList(Predecessor) {
    return indexLivePredecessors(allocator, program, null, budget);
}
pub fn indexLivePredecessors(
    allocator: std.mem.Allocator,
    program: ir.Program,
    live: ?[]const bool,
    budget: *Budget,
) Error![]std.ArrayList(Predecessor) {
    if (budget.strict and !budget.charge(program.blocks.len)) return error.ExpressionWorkLimit;
    const result = try allocator.alloc(std.ArrayList(Predecessor), program.blocks.len);
    for (result) |*items| items.* = .empty;
    for (program.blocks, 0..) |block, id| {
        if (live) |blocks| if (!blocks[id]) continue;
        var edge_index: usize = 0;
        while (successor(block.terminator, edge_index)) |transfer| : (edge_index += 1) {
            if (!budget.tick()) return error.ExpressionWorkLimit;
            const target: usize = @intCast(transfer.edge.block);
            if (live) |blocks| if (!blocks[target]) continue;
            const list = &result[target];
            if (budget.strict and list.items.len == list.capacity and
                !budget.charge(list.items.len)) return error.ExpressionWorkLimit;
            try list.append(
                allocator,
                .{ .block = id, .transfer = transfer },
            );
        }
    }
    return result;
}
pub fn transparentRegions(
    a: std.mem.Allocator,
    program: ir.Program,
    live: ?[]const bool,
    budget: *Budget,
) Error![]usize {
    if (budget.strict and !budget.charge(program.blocks.len)) return error.ExpressionWorkLimit;
    const parents = try a.alloc(usize, program.blocks.len);
    for (parents, 0..) |*parent, id| parent.* = id;
    for (program.blocks, 0..) |block, id| {
        if (live) |blocks| if (!blocks[id]) continue;
        var edge: usize = 0;
        while (successor(block.terminator, edge)) |transfer| : (edge += 1) {
            if (!budget.tick()) return error.ExpressionWorkLimit;
            if (transfer.capture_boundary) continue;
            const target: usize = @intCast(transfer.edge.block);
            if (live) |blocks| if (!blocks[target]) continue;
            const left = try representative(parents, id, budget);
            const right = try representative(parents, target, budget);
            parents[@max(left, right)] = @min(left, right);
        }
    }
    for (0..parents.len) |id| parents[id] = try representative(parents, id, budget);
    return parents;
}
fn representative(parents: []usize, start: usize, budget: *Budget) Error!usize {
    var root = start;
    while (parents[root] != root) {
        if (budget.strict and !budget.tick()) return error.ExpressionWorkLimit;
        root = parents[root];
    }
    var cursor = start;
    while (parents[cursor] != cursor) {
        const next = parents[cursor];
        parents[cursor] = root;
        cursor = next;
    }
    return root;
}
pub fn successor(term: ir.Terminator, index: usize) ?Incoming {
    return switch (term) {
        .return_value, .fail => null,
        .branch => |v| if (index == 0) .{ .edge = v.when_true } else if (index == 1) .{
            .edge = v.when_false,
        } else null,
        .switch_variant => |v| if (index < v.cases.len) .{ .edge = v.cases[index] } else null,
        .jump => |v| if (index == 0) .{ .edge = v } else null,
        .yield_value => |v| if (index == 0) .{ .edge = v, .capture_boundary = true } else null,
        .unpack_product => |v| if (index == 0) .{
            .edge = v.next,
            .overwritten = v.destinations,
        } else null,
        inline else => |v| if (index == 0) .{ .edge = v.next, .capture_boundary = true } else null,
    };
}
const Proof = struct {
    program: ir.Program,
    definition: Definition,
    cache: []State,
    visited: []usize = &.{},
    visit_count: usize = 0,
    budget: *Budget,
    predecessors: []const std.ArrayList(Predecessor),
    const State = enum { unseen, active, yes, no };
    const Frame = struct {
        block_id: usize,
        next: usize = 0,
        count: usize = 0,
        full: bool,
    };
    const Resolution = enum { pending, yes, no };
    fn depthLimit(self: *Proof) bool {
        _ = self.budget.tick();
        if (self.budget.strict) self.budget.exhausted = true;
        return false;
    }
    fn enter(self: *Proof, frame: Frame, before: usize) Resolution {
        if (!self.budget.tick()) return .no;
        if (frame.full) switch (self.cache[frame.block_id]) {
            .active, .no => return .no,
            .yes => return .yes,
            .unseen => {},
        };
        if (frame.full) {
            if (self.visited.len != 0) {
                self.visited[self.visit_count] = frame.block_id;
                self.visit_count += 1;
            }
            self.cache[frame.block_id] = .active;
        }
        var result: Resolution = .no;
        defer if (frame.full and result != .pending) {
            self.cache[frame.block_id] = if (result == .yes) .yes else .no;
        };
        const block = self.program.blocks[frame.block_id];
        var cursor = before;
        while (cursor != 0) {
            if (!self.budget.tick()) return .no;
            cursor -= 1;
            if (self.definition.location.block == frame.block_id and
                self.definition.location.instruction == cursor)
            {
                result = .yes;
                return result;
            }
            if (relevant(self.definition, block.instructions[cursor].destination)) return .no;
        }
        if (self.program.functions[@intCast(block.function)].entry == frame.block_id) return .no;
        result = .pending;
        return result;
    }
    fn resolve(self: *Proof, block_id: usize, before: usize, frames: []Frame) bool {
        if (frames.len == 0) return self.depthLimit();
        frames[0] = .{
            .block_id = block_id,
            .full = before == self.program.blocks[block_id].instructions.len,
        };
        switch (self.enter(frames[0], before)) {
            .yes => return true,
            .no => return false,
            .pending => {},
        }
        var count: usize = 1;
        defer for (frames[0..count]) |frame| {
            if (frame.full) self.cache[frame.block_id] = .no;
        };
        while (count != 0) {
            const frame = &frames[count - 1];
            const incoming = self.predecessors[frame.block_id].items;
            if (frame.next == incoming.len) {
                if (frame.count == 0) return false;
                if (frame.full) self.cache[frame.block_id] = .yes;
                count -= 1;
                continue;
            }
            if (!self.budget.tick()) return false;
            const indexed = incoming[frame.next];
            frame.next += 1;
            const predecessor = self.program.blocks[indexed.block];
            if (predecessor.function != self.program.blocks[frame.block_id].function) continue;
            frame.count += 1;
            if (indexed.transfer.capture_boundary) {
                self.budget.capture_boundary = true;
                return false;
            }
            if (self.budget.strict and
                (!self.budget.charge(indexed.transfer.edge.assignments.len) or
                    !self.budget.charge(indexed.transfer.overwritten.len))) return false;
            if (!edgePreserves(
                self.definition,
                indexed.transfer.edge,
                indexed.transfer.overwritten,
            )) return false;
            const child: Frame = .{ .block_id = indexed.block, .full = true };
            if (count == frames.len) return self.depthLimit();
            switch (self.enter(child, predecessor.instructions.len)) {
                .no => return false,
                .yes => continue,
                .pending => {
                    frames[count] = child;
                    count += 1;
                },
            }
        }
        return true;
    }
};
fn definitionAt(program: ir.Program, witness: Witness) ?Definition {
    if (witness.source.block >= program.blocks.len or
        witness.target.block >= program.blocks.len)
        return null;
    const source = program.blocks[witness.source.block];
    const target = program.blocks[witness.target.block];
    if (source.function != target.function or
        witness.source.instruction >= source.instructions.len or
        witness.target.instruction >= target.instructions.len)
        return null;
    const op = source.instructions[witness.source.instruction];
    if (!sameExpression(op, target.instructions[witness.target.instruction])) return null;
    return .{
        .location = witness.source,
        .function = source.function,
        .instruction = op,
        .schema = program.functions[
            @intCast(source.function)
        ].layout.slots[
            @intCast(op.destination)
        ],
    };
}

pub const Workspace = struct {
    cache: []Proof.State,
    visited: []usize,
    frames: []Proof.Frame,

    pub fn init(a: std.mem.Allocator, program: ir.Program, budget: *Budget) Error!Workspace {
        if (!budget.charge(program.blocks.len)) return error.ExpressionWorkLimit;
        const cache = try a.alloc(Proof.State, program.blocks.len);
        @memset(cache, .unseen);
        const frame_count = @min(budget.limits.depth, program.blocks.len +| 2);
        return .{
            .cache = cache,
            .visited = try a.alloc(usize, program.blocks.len),
            .frames = try a.alloc(Proof.Frame, frame_count),
        };
    }

    pub fn proves(
        self: Workspace,
        program: ir.Program,
        w: Witness,
        predecessors: []const std.ArrayList(Predecessor),
        budget: *Budget,
    ) bool {
        var proof: Proof = .{
            .program = program,
            .definition = definitionAt(program, w) orelse return false,
            .budget = budget,
            .predecessors = predecessors,
            .cache = self.cache,
            .visited = self.visited,
        };
        defer for (self.visited[0..proof.visit_count]) |id| {
            self.cache[id] = .unseen;
        };
        return proof.resolve(w.target.block, w.target.instruction, self.frames);
    }
};

pub fn proves(
    allocator: std.mem.Allocator,
    program: ir.Program,
    witness: Witness,
    predecessors: []const std.ArrayList(Predecessor),
    budget: *Budget,
) std.mem.Allocator.Error!bool {
    const definition = definitionAt(program, witness) orelse return false;
    const cache = try allocator.alloc(Proof.State, program.blocks.len);
    defer allocator.free(cache);
    @memset(cache, .unseen);
    var proof: Proof = .{
        .program = program,
        .definition = definition,
        .budget = budget,
        .predecessors = predecessors,
        .cache = cache,
    };
    var frames: [256]Proof.Frame = undefined;
    return proof.resolve(witness.target.block, witness.target.instruction, &frames);
}
