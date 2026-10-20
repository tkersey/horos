// Copyright (c) 2026 Boundary contributors. MIT license.
//! Bounded typed XOR equality search. Proof replay never invokes the search.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const own = @import("activation_ownership.zig");
const image = @import("program_image.zig");
const equal = @import("record_equal.zig").equal;
const p01 = @import("coalescing.zig");
const counted = @import("loop_regions.zig");
pub const Error = p01.Error || error{ InvalidEqualityProof, EqualityWorkLimit };
pub const Options = struct {
    work_limit: u64 = 200_000,
    max_nodes: usize = 128,
    max_rounds: usize = 16,
    coalescing: p01.Options = .{},
};
pub const Kind = enum { input, literal, xor, product, field };
pub const Node = struct {
    kind: Kind,
    schema: p.Id,
    value: u64 = 0,
    left: usize = 0,
    right: usize = 0,
    fields: []const usize = &.{},
};
pub const Law = enum { congruence, commute, associate, cancel, zero, projection };
pub const Step = struct { law: Law, left: usize, right: usize, auxiliary: usize = 0 };
pub const Proof = struct { epoch: [32]u8, nodes: []const Node, steps: []const Step };
pub const Statistics = struct {
    nodes: usize = 0,
    classes: usize = 0,
    unions: usize = 0,
    rounds: usize = 0,
    search_work_units: u64 = 0,
    heuristic_tree_cost: ?u64 = null,
    materialized_instructions: usize = 0,
    saturated: bool = false,
    work_limit: bool = false,
    candidates: usize = 0,
    selected: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    proof: Proof,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    left: u64,
    fn take(self: *@This(), amount: usize) Error!void {
        if (amount > self.left) return error.EqualityWorkLimit;
        self.left -= amount;
    }
    fn tick(self: *@This()) Error!void {
        if (self.left == 0) return error.EqualityWorkLimit;
        self.left -= 1;
    }
    fn record(self: *@This(), comptime T: type, value: T) Error!void {
        var count: counted.Budget = .{ .remaining = self.left };
        defer self.left = count.remaining;
        count.record(T, value) catch |err| switch (err) {
            error.LoopWorkLimit => return error.EqualityWorkLimit,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
};
fn width(schema: p.Schema) ?usize {
    return switch (schema) {
        .u8 => 1,
        .u16 => 2,
        .u32 => 4,
        .u64 => 8,
        else => null,
    };
}
fn allowed(program: ir.Program, schema: p.Id, depth: usize, budget: *Budget) Error!bool {
    try budget.tick();
    if (depth >= 32) return false;
    const value = program.schemas[@intCast(schema)];
    if (width(value) != null) return true;
    if (value != .product) return false;
    for (value.product) |field| if (!try allowed(program, field, depth + 1, budget)) return false;
    return true;
}
fn arity(node: Node) usize {
    return switch (node.kind) {
        .xor => 2,
        .field => 1,
        .product => node.fields.len,
        else => 0,
    };
}
fn childAt(node: Node, index: usize) usize {
    return switch (node.kind) {
        .xor => if (index == 0) node.left else node.right,
        .field => node.left,
        .product => node.fields[index],
        else => unreachable,
    };
}
fn literal(program: ir.Program, id: p.Id) ?u64 {
    const value = program.constants[@intCast(id)];
    const size = width(program.schemas[@intCast(value.schema)]) orelse return null;
    if (value.bytes.len != size) return null;
    var result: u64 = 0;
    for (value.bytes, 0..) |byte, i| result |= @as(u64, byte) << @as(u6, @intCast(8 * i));
    return result;
}
fn find(parents: []usize, id: usize) usize {
    var root = id;
    while (parents[root] != root) root = parents[root];
    var at = id;
    while (parents[at] != at) {
        const next = parents[at];
        parents[at] = root;
        at = next;
    }
    return root;
}
fn equivalent(parents: []usize, left: usize, right: usize) bool {
    return find(parents, left) == find(parents, right);
}
fn same(parents: []usize, left: Node, right: Node) bool {
    if (left.schema != right.schema or left.kind != right.kind) return false;
    return switch (left.kind) {
        .input, .literal => left.value == right.value,
        .xor => equivalent(parents, left.left, right.left) and
            equivalent(parents, left.right, right.right),
        .field => left.value == right.value and equivalent(parents, left.left, right.left),
        .product => blk: {
            if (left.fields.len != right.fields.len) break :blk false;
            for (left.fields, right.fields) |l, r| if (!equivalent(parents, l, r)) break :blk false;
            break :blk true;
        },
    };
}
fn chargeComparison(budget: *Budget, left: Node, right: Node) Error!void {
    if (left.kind == .product and
        right.kind == .product and
        left.schema == right.schema and
        left.fields.len == right.fields.len)
        try budget.take(left.fields.len);
}
fn justified(nodes: []const Node, parents: []usize, step: Step) bool {
    if (step.left >= nodes.len or
        step.right >= nodes.len or
        step.auxiliary >= nodes.len)
        return false;
    const left = nodes[step.left];
    const right = nodes[step.right];
    if (left.schema != right.schema) return false;
    return switch (step.law) {
        .congruence => same(parents, left, right),
        .projection => blk: {
            const product = nodes[step.auxiliary];
            break :blk left.kind == .field and
                product.kind == .product and
                left.value < product.fields.len and
                equivalent(parents, left.left, step.auxiliary) and
                equivalent(parents, step.right, product.fields[@intCast(left.value)]);
        },
        .commute => left.kind == .xor and right.kind == .xor and equivalent(
            parents,
            left.left,
            right.right,
        ) and equivalent(parents, left.right, right.left),
        .cancel => left.kind == .xor and right.kind == .literal and right.value == 0 and equivalent(
            parents,
            left.left,
            left.right,
        ),
        .zero => blk: {
            const zero = nodes[step.auxiliary];
            break :blk left.kind == .xor and
                zero.kind == .literal and
                zero.value == 0 and
                zero.schema == left.schema and
                ((equivalent(parents, left.left, step.auxiliary) and
                    equivalent(parents, left.right, step.right)) or
                    (equivalent(parents, left.right, step.auxiliary) and
                        equivalent(parents, left.left, step.right)));
        },
        .associate => blk: {
            const inner = nodes[step.auxiliary];
            if (left.kind != .xor or
                right.kind != .xor or
                inner.kind != .xor or
                inner.schema != left.schema or
                !equivalent(parents, left.left, step.auxiliary))
                break :blk false;
            const tail = nodes[right.right];
            break :blk tail.kind == .xor and tail.schema == left.schema and equivalent(
                parents,
                right.left,
                inner.left,
            ) and
                equivalent(parents, tail.left, inner.right) and
                equivalent(parents, tail.right, left.right);
        },
    };
}
const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    parents: std.ArrayList(usize) = .empty,
    steps: std.ArrayList(Step) = .empty,
    budget: Budget,
    limit: usize,
    fn add(self: *@This(), node: Node) Error!usize {
        for (self.nodes.items, 0..) |old, id| {
            try self.budget.tick();
            try chargeComparison(&self.budget, old, node);
            if (same(self.parents.items, old, node)) return id;
        }
        if (self.nodes.items.len >= self.limit) return error.EqualityWorkLimit;
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.parents.ensureUnusedCapacity(self.allocator, 1);
        const id = self.nodes.items.len;
        self.nodes.appendAssumeCapacity(node);
        self.parents.appendAssumeCapacity(id);
        return id;
    }
    fn merge(self: *@This(), step: Step) Error!void {
        try self.budget.tick();
        if (equivalent(self.parents.items, step.left, step.right)) return;
        if (step.law == .congruence) try chargeComparison(
            &self.budget,
            self.nodes.items[step.left],
            self.nodes.items[step.right],
        );
        if (!justified(
            self.nodes.items,
            self.parents.items,
            step,
        )) return error.InvalidEqualityProof;
        try self.steps.append(self.allocator, step);
        const left = find(self.parents.items, step.left);
        const right = find(self.parents.items, step.right);
        self.parents.items[@max(left, right)] = @min(left, right);
    }
};
fn parse(graph: *Graph, program: ir.Program) Error!?usize {
    if (program.functions.len != 1 or program.blocks.len != 1) return null;
    const f = program.functions[0];
    const block = program.blocks[0];
    if (f.entry != 0 or
        f.effects.len != 0 or
        f.regions.len != 0 or
        f.custody.len != 1 or
        block.function != 0 or
        block.custody != 0 or
        block.terminator != .return_value)
        return null;
    for (f.layout.slots) |schema| if (!try allowed(program, schema, 0, &graph.budget)) return null;
    const slots = try graph.allocator.alloc(?usize, f.layout.slots.len);
    @memset(slots, null);
    for (f.inputs) |slot| {
        try graph.budget.tick();
        slots[@intCast(slot)] = try graph.add(.{
            .kind = .input,
            .schema = f.layout.slots[@intCast(slot)],
            .value = slot,
        });
    }
    for (block.instructions) |op| {
        try graph.budget.tick();
        if (op.failures.len != 0) return null;
        const schema = f.layout.slots[@intCast(op.destination)];
        const id = switch (op.opcode) {
            .move => if (op.operands.len == 1) slots[
                @intCast(op.operands[0])
            ] orelse return null else return null,
            .constant => try graph.add(.{
                .kind = .literal,
                .schema = schema,
                .value = literal(program, op.immediate) orelse return null,
            }),
            .integer_bit_xor => blk: {
                if (op.operands.len != 2) return null;
                break :blk try graph.add(.{
                    .kind = .xor,
                    .schema = schema,
                    .left = slots[@intCast(op.operands[0])] orelse return null,
                    .right = slots[@intCast(op.operands[1])] orelse return null,
                });
            },
            .product => blk: {
                const fields = try graph.allocator.alloc(usize, op.operands.len);
                for (
                    op.operands,
                    fields,
                ) |slot, *field| field.* = slots[@intCast(slot)] orelse return null;
                break :blk try graph.add(.{ .kind = .product, .schema = schema, .fields = fields });
            },
            .field => if (op.operands.len == 1) try graph.add(.{
                .kind = .field,
                .schema = schema,
                .value = op.immediate,
                .left = slots[@intCast(op.operands[0])] orelse return null,
            }) else return null,
            else => return null,
        };
        slots[@intCast(op.destination)] = id;
    }
    return slots[@intCast(block.terminator.return_value)];
}
fn saturate(graph: *Graph, stats: *Statistics, rounds: usize) Error!void {
    for (0..rounds) |_| {
        const old_nodes = graph.nodes.items.len;
        const old_steps = graph.steps.items.len;
        for (0..old_nodes) |id| {
            const node = graph.nodes.items[id];
            if (node.kind == .field) for (0..old_nodes) |via| {
                try graph.budget.tick();
                const product = graph.nodes.items[via];
                if (product.kind == .product and node.value < product.fields.len and equivalent(
                    graph.parents.items,
                    node.left,
                    via,
                )) try graph.merge(.{
                    .law = .projection,
                    .left = id,
                    .right = product.fields[@intCast(node.value)],
                    .auxiliary = via,
                });
            };
            if (node.kind != .xor) continue;
            const zero = try graph.add(.{ .kind = .literal, .schema = node.schema, .value = 0 });
            if (equivalent(graph.parents.items, node.left, node.right))
                try graph.merge(.{ .law = .cancel, .left = id, .right = zero });
            if (equivalent(graph.parents.items, node.left, zero)) try graph.merge(.{
                .law = .zero,
                .left = id,
                .right = node.right,
                .auxiliary = zero,
            });
            if (equivalent(graph.parents.items, node.right, zero)) try graph.merge(.{
                .law = .zero,
                .left = id,
                .right = node.left,
                .auxiliary = zero,
            });
            const swapped = try graph.add(.{
                .kind = .xor,
                .schema = node.schema,
                .left = node.right,
                .right = node.left,
            });
            try graph.merge(.{ .law = .commute, .left = id, .right = swapped });
            for (0..old_nodes) |via| {
                try graph.budget.tick();
                const inner = graph.nodes.items[via];
                if (inner.kind != .xor or !equivalent(
                    graph.parents.items,
                    node.left,
                    via,
                )) continue;
                const tail = try graph.add(.{
                    .kind = .xor,
                    .schema = node.schema,
                    .left = inner.right,
                    .right = node.right,
                });
                const outer = try graph.add(.{
                    .kind = .xor,
                    .schema = node.schema,
                    .left = inner.left,
                    .right = tail,
                });
                try graph.merge(.{
                    .law = .associate,
                    .left = id,
                    .right = outer,
                    .auxiliary = via,
                });
            }
        }
        for (0..graph.nodes.items.len) |i| for (0..i) |j| {
            try graph.budget.tick();
            try chargeComparison(&graph.budget, graph.nodes.items[i], graph.nodes.items[j]);
            if (same(
                graph.parents.items,
                graph.nodes.items[i],
                graph.nodes.items[j],
            )) try graph.merge(.{ .law = .congruence, .left = i, .right = j });
        };
        stats.rounds += 1;
        if (old_nodes == graph.nodes.items.len and old_steps == graph.steps.items.len) {
            stats.saturated = true;
            return;
        }
    }
    return error.EqualityWorkLimit;
}
fn materialize(
    graph: *Graph,
    original: ir.Program,
    root: usize,
    stats: *Statistics,
) Error!ir.Program {
    const a = graph.allocator;
    const n = graph.nodes.items.len;
    const costs = try a.alloc(?u64, n);
    @memset(costs, null);
    const choices = try a.alloc(?usize, n);
    @memset(choices, null);
    for (0..n) |_| {
        var changed = false;
        for (graph.nodes.items, 0..) |node, id| {
            try graph.budget.tick();
            const owner = find(graph.parents.items, id);
            const value: u64 = switch (node.kind) {
                .input => 0,
                .literal => 1,
                .xor, .product, .field => blk: {
                    var total: ?u64 = 1;
                    for (0..arity(node)) |index| {
                        const cost = costs[find(graph.parents.items, childAt(node, index))] orelse {
                            total = null;
                            break;
                        };
                        total = std.math.add(u64, total.?, cost) catch {
                            total = null;
                            break;
                        };
                    }
                    break :blk total orelse continue;
                },
            };
            if (costs[owner] == null or value < costs[owner].?) {
                costs[owner] = value;
                choices[owner] = id;
                changed = true;
            }
        }
        if (!changed) break;
    }
    const needed = try a.alloc(bool, n);
    @memset(needed, false);
    needed[find(graph.parents.items, root)] = true;
    for (0..n) |_| {
        var changed = false;
        for (needed, 0..) |wanted, id| if (wanted) {
            try graph.budget.tick();
            const node = graph.nodes.items[choices[id] orelse return error.EqualityWorkLimit];
            for (0..arity(node)) |index| {
                const owner = find(graph.parents.items, childAt(node, index));
                if (!needed[owner]) {
                    needed[owner] = true;
                    changed = true;
                }
            }
        };
        if (!changed) break;
    }
    var constants: std.ArrayList(p.Literal) = .empty;
    try constants.appendSlice(a, original.constants);
    var layout: std.ArrayList(p.Id) = .empty;
    try layout.appendSlice(a, original.functions[0].layout.slots);
    var instructions: std.ArrayList(ir.Instruction) = .empty;
    const output = try a.alloc(?p.Id, n);
    @memset(output, null);
    const used = try a.alloc(bool, layout.items.len);
    @memset(used, false);
    for (original.functions[0].inputs) |slot| used[@intCast(slot)] = true;
    for (0..n) |_| {
        var progress = false;
        for (needed, 0..) |wanted, owner| {
            if (!wanted or output[owner] != null) continue;
            try graph.budget.tick();
            const node = graph.nodes.items[choices[owner] orelse return error.EqualityWorkLimit];
            if (node.kind == .input) {
                output[owner] = node.value;
                progress = true;
                continue;
            }
            var ready = true;
            for (0..arity(node)) |index| if (output[
                find(graph.parents.items, childAt(node, index))
            ] == null) {
                ready = false;
                break;
            };
            if (!ready) continue;
            const operands = try a.alloc(p.Id, arity(node));
            for (
                operands,
                0..,
            ) |*operand, index| operand.* = output[
                find(graph.parents.items, childAt(node, index))
            ].?;
            var destination: ?p.Id = null;
            for (used, 0..) |occupied, slot| if (!occupied and layout.items[slot] == node.schema) {
                used[slot] = true;
                destination = @intCast(slot);
                break;
            };
            if (destination == null) {
                destination = @intCast(layout.items.len);
                try layout.append(a, node.schema);
            }
            var op: ir.Instruction = .{
                .destination = destination.?,
                .opcode = .integer_bit_xor,
                .operands = operands,
            };
            if (node.kind == .product) op.opcode = .product;
            if (node.kind == .field) {
                op.opcode = .field;
                op.immediate = node.value;
            }
            if (node.kind == .literal) {
                const size = width(original.schemas[@intCast(node.schema)]).?;
                const bytes = try a.alloc(u8, size);
                for (
                    bytes,
                    0..,
                ) |*byte, i| byte.* = @truncate(node.value >> @as(u6, @intCast(i * 8)));
                op.opcode = .constant;
                op.immediate = constants.items.len;
                try constants.append(a, .{ .schema = node.schema, .bytes = bytes });
            }
            try instructions.append(a, op);
            output[owner] = destination;
            progress = true;
        }
        if (!progress) break;
    }
    const result_slot = output[
        find(graph.parents.items, root)
    ] orelse return error.EqualityWorkLimit;
    stats.heuristic_tree_cost = costs[find(graph.parents.items, root)];
    stats.materialized_instructions = instructions.items.len;
    const functions = try a.dupe(ir.Function, original.functions);
    functions[0].layout.slots = try layout.toOwnedSlice(a);
    const blocks = try a.dupe(ir.Block, original.blocks);
    blocks[0].instructions = try instructions.toOwnedSlice(a);
    blocks[0].terminator = .{ .return_value = result_slot };
    var program = original;
    program.functions = functions;
    program.blocks = blocks;
    program.constants = try constants.toOwnedSlice(a);
    return program;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!?Candidate {
    var stats: Statistics = .{};
    defer if (statistics) |out| {
        out.* = stats;
    };
    var admitted = try own.analyze(allocator, original);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    var graph: Graph = .{
        .allocator = arena.allocator(),
        .budget = .{ .left = options.work_limit },
        .limit = @min(options.max_nodes, 1024),
    };
    defer {
        stats.nodes = graph.nodes.items.len;
        stats.search_work_units = options.work_limit - graph.budget.left;
        stats.unions = graph.steps.items.len;
        stats.classes = 0;
        for (0..graph.parents.items.len) |id| stats.classes += @intFromBool(find(
            graph.parents.items,
            id,
        ) == id);
    }
    try graph.budget.record(ir.Program, original);
    const root = (try parse(&graph, original)) orelse return null;
    try saturate(&graph, &stats, options.max_rounds);
    const program = try materialize(&graph, original, root, &stats);
    stats.candidates = 1;
    const proof: Proof = .{
        .epoch = try image.identity(allocator, original),
        .nodes = graph.nodes.items,
        .steps = graph.steps.items,
    };
    keep = true;
    return .{ .arena = arena, .program = program, .proof = proof };
}

pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    proof: Proof,
    options: Options,
) Error!void {
    var before = try own.analyze(allocator, original);
    defer before.deinit();
    var after = try own.analyze(allocator, candidate);
    defer after.deinit();
    if (!std.mem.eql(
        u8,
        &proof.epoch,
        &try image.identity(allocator, original),
    )) return error.InvalidEqualityProof;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var source: Graph = .{
        .allocator = a,
        .budget = .{ .left = options.work_limit },
        .limit = @min(options.max_nodes, 1024),
    };
    try source.budget.record(ir.Program, original);
    try source.budget.record(ir.Program, candidate);
    try source.budget.record(Proof, proof);
    const root = (try parse(&source, original)) orelse return error.InvalidEqualityProof;
    if (proof.nodes.len < source.nodes.items.len or proof.nodes.len > source.limit or !equal(
        []const Node,
        source.nodes.items,
        proof.nodes[0..source.nodes.items.len],
    )) return error.InvalidEqualityProof;
    for (proof.nodes, 0..) |node, id| {
        try source.budget.tick();
        if (node.schema >= original.schemas.len) return error.InvalidEqualityProof;
        if (!try allowed(
            original,
            node.schema,
            0,
            &source.budget,
        )) return error.InvalidEqualityProof;
        switch (node.kind) {
            .input => {
                if (node.fields.len != 0 or
                    node.left != 0 or
                    node.right != 0 or
                    std.mem.indexOfScalar(
                        p.Id,
                        original.functions[0].inputs,
                        node.value,
                    ) == null or
                    original.functions[0].layout.slots[
                        @intCast(node.value)
                    ] != node.schema)
                    return error.InvalidEqualityProof;
            },
            .literal => {
                const bytes = width(
                    original.schemas[
                        @intCast(node.schema)
                    ],
                ) orelse return error.InvalidEqualityProof;
                if (node.fields.len != 0 or
                    node.left != 0 or
                    node.right != 0 or
                    (bytes < 8 and
                        node.value >> @as(u6, @intCast(bytes * 8)) != 0))
                    return error.InvalidEqualityProof;
            },
            .xor => {
                if (width(original.schemas[
                    @intCast(node.schema)
                ]) == null or
                    node.fields.len != 0 or
                    node.value != 0 or
                    node.left >= id or
                    node.right >= id or
                    proof.nodes[node.left].schema != node.schema or
                    proof.nodes[node.right].schema != node.schema)
                    return error.InvalidEqualityProof;
            },
            .product => {
                const schema = original.schemas[@intCast(node.schema)];
                if (schema != .product or
                    node.value != 0 or
                    node.left != 0 or
                    node.right != 0 or
                    node.fields.len != schema.product.len)
                    return error.InvalidEqualityProof;
                for (
                    node.fields,
                    schema.product,
                ) |field, sid|
                    if (field >= id or
                        proof.nodes[field].schema != sid)
                        return error.InvalidEqualityProof;
            },
            .field => {
                if (node.fields.len != 0 or
                    node.right != 0 or
                    node.left >= id)
                    return error.InvalidEqualityProof;
                const schema = original.schemas[@intCast(proof.nodes[node.left].schema)];
                if (schema != .product or node.value >= schema.product.len or schema.product[
                    @intCast(node.value)
                ] != node.schema) return error.InvalidEqualityProof;
            },
        }
    }
    const parents = try a.alloc(usize, proof.nodes.len);
    for (parents, 0..) |*parent, id| parent.* = id;
    for (proof.steps) |step| {
        try source.budget.tick();
        if (step.left >= proof.nodes.len or
            step.right >= proof.nodes.len)
            return error.InvalidEqualityProof;
        if (step.law == .congruence) try chargeComparison(
            &source.budget,
            proof.nodes[step.left],
            proof.nodes[step.right],
        );
        if (!justified(proof.nodes, parents, step)) return error.InvalidEqualityProof;
        const left = find(parents, step.left);
        const right = find(parents, step.right);
        parents[@max(left, right)] = @min(left, right);
    }
    if (candidate.functions.len != 1 or
        candidate.blocks.len != 1 or
        candidate.constants.len < original.constants.len)
        return error.InvalidEqualityProof;
    var rest = candidate;
    rest.functions = original.functions;
    rest.blocks = original.blocks;
    rest.constants = original.constants;
    if (!equal(ir.Program, original, rest) or !equal(
        []const p.Literal,
        original.constants,
        candidate.constants[0..original.constants.len],
    )) return error.InvalidEqualityProof;
    const old = original.functions[0];
    const f = candidate.functions[0];
    if (f.layout.slots.len < old.layout.slots.len or !std.mem.eql(
        p.Id,
        old.layout.slots,
        f.layout.slots[0..old.layout.slots.len],
    )) return error.InvalidEqualityProof;
    var metadata = f;
    metadata.layout = old.layout;
    if (!equal(ir.Function, old, metadata)) return error.InvalidEqualityProof;
    for (f.layout.slots) |schema| if (!try allowed(
        candidate,
        schema,
        0,
        &source.budget,
    )) return error.InvalidEqualityProof;
    for (original.constants.len..candidate.constants.len) |id| if (literal(
        candidate,
        id,
    ) == null) return error.InvalidEqualityProof;
    const block = candidate.blocks[0];
    if (block.function != 0 or
        block.custody != 0 or
        block.terminator != .return_value)
        return error.InvalidEqualityProof;
    const slots = try a.alloc(?usize, f.layout.slots.len);
    @memset(slots, null);
    for (f.inputs) |slot| for (
        source.nodes.items,
        0..,
    ) |node, id| if (node.kind == .input and node.value == slot) {
        slots[@intCast(slot)] = id;
        break;
    };
    for (block.instructions) |op| {
        try source.budget.tick();
        if (op.failures.len != 0) return error.InvalidEqualityProof;
        if (op.opcode == .move) {
            if (op.operands.len != 1) return error.InvalidEqualityProof;
            slots[
                @intCast(op.destination)
            ] = slots[
                @intCast(op.operands[0])
            ] orelse return error.InvalidEqualityProof;
            continue;
        }
        var expected: Node = .{
            .kind = .literal,
            .schema = f.layout.slots[@intCast(op.destination)],
        };
        switch (op.opcode) {
            .constant => expected.value = literal(
                candidate,
                op.immediate,
            ) orelse return error.InvalidEqualityProof,
            .integer_bit_xor => {
                if (op.operands.len != 2) return error.InvalidEqualityProof;
                expected.kind = .xor;
                expected.left = slots[
                    @intCast(op.operands[0])
                ] orelse return error.InvalidEqualityProof;
                expected.right = slots[
                    @intCast(op.operands[1])
                ] orelse return error.InvalidEqualityProof;
            },
            .product => {
                const fields = try a.alloc(usize, op.operands.len);
                for (
                    op.operands,
                    fields,
                ) |slot, *field| field.* = slots[
                    @intCast(slot)
                ] orelse return error.InvalidEqualityProof;
                expected.kind = .product;
                expected.fields = fields;
            },
            .field => {
                if (op.operands.len != 1) return error.InvalidEqualityProof;
                expected.kind = .field;
                expected.value = op.immediate;
                expected.left = slots[
                    @intCast(op.operands[0])
                ] orelse return error.InvalidEqualityProof;
            },
            else => return error.InvalidEqualityProof,
        }
        var matched: ?usize = null;
        for (proof.nodes, 0..) |node, id| {
            try source.budget.tick();
            try chargeComparison(&source.budget, node, expected);
            if (same(parents, node, expected)) {
                matched = id;
                break;
            }
        }
        slots[@intCast(op.destination)] = matched orelse return error.InvalidEqualityProof;
    }
    const result = slots[
        @intCast(block.terminator.return_value)
    ] orelse return error.InvalidEqualityProof;
    if (!equivalent(parents, result, root)) return error.InvalidEqualityProof;
}
pub fn possible(program: ir.Program) bool {
    if (program.functions.len != 1 or program.blocks.len != 1) return false;
    for (program.blocks[0].instructions) |op|
        if (op.opcode == .integer_bit_xor or
            op.opcode == .field or
            op.opcode == .product or
            op.opcode == .move)
            return true;
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
    var candidate = (construct(allocator, original, &stats, options) catch |err| switch (err) {
        error.EqualityWorkLimit => {
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
        candidate.proof,
        options,
    ) catch |err| switch (err) {
        error.EqualityWorkLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    var selected = try p01.run(allocator, candidate.program, options.coalescing);
    var keep = false;
    defer if (!keep) selected.deinit();
    var baseline = try p01.run(
        allocator,
        original,
        .{ .work_limit = options.coalescing.work_limit },
    );
    defer baseline.deinit();
    if (try image.encodedLength(selected.program) > try image.encodedLength(baseline.program))
        return p01.run(allocator, original, options.coalescing);
    stats.selected = true;
    keep = true;
    return selected;
}
