// Copyright (c) 2026 Boundary contributors. MIT license.
//! Epoch-keyed specialization of proved private-call arguments.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const facts = @import("value_facts.zig");
const origin = @import("constant_origin.zig");
const contexts = @import("call_contexts.zig");
const privacy = @import("capture_reduction.zig");
const traits = @import("traits.zig");
const ownership = @import("activation_ownership.zig");
const access = @import("slot_access.zig").terminator;
const equal = @import("record_equal.zig").equal;
const image = @import("program_image.zig");
const p01 = @import("coalescing.zig");
const profiles = @import("optimization_profile.zig");
pub const Error = facts.Error || p01.Error || profiles.Error || error{
    InvalidCallPattern,
    CallPatternLimit,
};
pub const Options = struct {
    work_limit: u64 = facts.default_work_limit,
    max_variants: usize = 16,
    max_added_blocks: usize = 256,
    max_added_bytes: usize = 4096,
    profile: ?profiles.Record = null,
    coalescing: p01.Options = .{},
};
pub const Static = union(enum) { constructor: p.Id, variant: p.Id, boolean: bool, unsigned: u64 };
pub const Key = struct {
    epoch: [32]u8,
    function: p.Id,
    parameter: usize,
    schema: p.Id,
    value: Static,
};
pub const Variant = struct {
    key: Key,
    function: p.Id,
    first_block: usize,
    literal: ?p.Id = null,
    generalized_parameters: []const usize = &.{},
};
pub const Site = struct {
    block: usize,
    variant: usize,
    payload: ?p.Id = null,
    captures: []const p.Id = &.{},
};
pub const Statistics = struct {
    variants: usize = 0,
    rewritten_calls: usize = 0,
    direct_applications: usize = 0,
    variant_projections: usize = 0,
    variant_switches: usize = 0,
    constant_branches: usize = 0,
    constants_materialized: usize = 0,
    retained_calls: usize = 0,
    generic_fallback_calls: usize = 0,
    folded_calls: usize = 0,
    generalized_parameters: usize = 0,
    residual_boundaries: usize = 0,
    work_limit: bool = false,
};
pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    variants: []const Variant,
    sites: []const Site,
    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
const Budget = struct {
    remaining: u64,
    fn take(self: *Budget, amount: usize) Error!void {
        if (amount > self.remaining) return error.CallPatternLimit;
        self.remaining -= amount;
    }
    fn tick(self: *Budget) Error!void {
        if (self.remaining == 0) return error.CallPatternLimit;
        self.remaining -= 1;
    }
};

/// A private parameter may be implicitly retained by a continuation even when
/// every explicit use is specializable. Record that observation during original
/// admission; a proposed representation must satisfy each observed capture.
const ParameterCaptures = struct {
    const Capture = struct { function: p.Id, slot: p.Id, site: *const ownership.CaptureSite };
    allocator: std.mem.Allocator,
    program: ir.Program,
    budget: *Budget,
    captures: std.ArrayList(Capture) = .empty,
    failure: ?Error = null,
    query_cost: usize = 0,

    fn observe(
        context: *anyopaque,
        function: p.Id,
        site: *const ownership.CaptureSite,
        slot: p.Id,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.failure != null) return;
        const inputs = self.program.functions[@intCast(function)].inputs;
        self.budget.tick() catch |err| {
            self.failure = err;
            return;
        };
        self.budget.take(inputs.len) catch |err| {
            self.failure = err;
            return;
        };
        if (std.mem.indexOfScalar(p.Id, inputs, slot) == null) return;
        const saved = site.copy(self.allocator) catch |err| {
            self.failure = err;
            return;
        };
        self.captures.append(
            self.allocator,
            .{ .function = function, .slot = slot, .site = saved },
        ) catch |err| {
            saved.destroyCopy(self.allocator);
            self.failure = err;
        };
    }

    fn prepare(self: *@This()) Error!void {
        if (self.failure) |err| return err;
        if (self.captures.items.len == 0) return;
        // Charge a conservative complete handler/bound scan for each query.
        // The predicate itself remains owned by activation_ownership.
        self.query_cost = 2;
        for (self.program.handlers) |handler| {
            try self.budget.tick();
            self.query_cost = std.math.add(
                usize,
                self.query_cost,
                1,
            ) catch return error.CallPatternLimit;
            for (handler.clauses) |clause| {
                try self.budget.tick();
                const bound = self.program.schemas[
                    @intCast(clause.resumption)
                ].internal.resumption.capture_bound;
                self.query_cost = std.math.add(
                    usize,
                    self.query_cost,
                    1,
                ) catch return error.CallPatternLimit;
                self.query_cost = std.math.add(
                    usize,
                    self.query_cost,
                    bound.len,
                ) catch return error.CallPatternLimit;
            }
        }
    }

    fn allows(self: *@This(), key: Key, permissions: traits.Facts) Error!bool {
        const replacement = replacementSchemas(self.program, key);
        if (replacement.len == 0) return true;
        const input = self.program.functions[@intCast(key.function)].inputs[key.parameter];
        for (self.captures.items) |capture| {
            try self.budget.tick();
            if (capture.function != key.function or capture.slot != input) continue;
            for (replacement) |schema| {
                try self.budget.take(self.query_cost);
                if (!try capture.site.captureAllowed(permissions, schema)) return false;
            }
        }
        return true;
    }
};

fn replacementSchemas(program: ir.Program, key: Key) []const p.Id {
    return switch (key.value) {
        .constructor => captureFields(program, key),
        .variant => |tag| program.schemas[@intCast(key.schema)].sum[@intCast(tag)..][0..1],
        .boolean, .unsigned => &.{},
    };
}

fn closedLeaf(
    program: ir.Program,
    constructor_id: p.Id,
    permissions: traits.Facts,
    budget: *Budget,
) Error!bool {
    try budget.tick();
    if (constructor_id >= program.constructors.len or !privacy.privateWorker(
        program,
        @intCast(constructor_id),
    )) return false;
    const constructor = program.constructors[@intCast(constructor_id)];
    const capture = program.scopes.captures[@intCast(constructor.capture)];
    const callable = program.schemas[@intCast(constructor.schema)].internal.computation;
    const function = program.functions[@intCast(constructor.function)];
    if (capture.owned_regions.len != 0 or
        capture.borrowed_regions.len != 0 or
        capture.use != .reusable or
        callable.use != .reusable or
        function.regions.len != 0 or
        function.effects.len != 0)
        return false;
    for (capture.fields) |schema| {
        try budget.tick();
        if (!permissions.copy[
            @intCast(schema)
        ] or !permissions.drop[
            @intCast(schema)
        ]) return false;
    }
    for (program.blocks) |block| {
        try budget.tick();
        if (block.function == constructor.function) switch (block.terminator) {
            .return_value, .fail, .jump, .branch => {},
            else => return false,
        };
    }
    return true;
}
fn recursive(program: ir.Program, function_id: p.Id) bool {
    for (program.blocks) |block|
        if (block.function == function_id and
            block.terminator == .call and
            block.terminator.call.function == function_id)
            return true;
    return false;
}
fn changing(program: ir.Program, function_id: p.Id, parameter: usize, budget: *Budget) Error!bool {
    for (program.blocks) |block| {
        try budget.tick();
        if (block.function == function_id and
            block.terminator == .call and
            block.terminator.call.function == function_id and
            block.terminator.call.arguments[parameter] != program.functions[
                @intCast(function_id)
            ].inputs[parameter])
            return true;
    }
    return false;
}
fn parameterEligible(
    program: ir.Program,
    function_id: p.Id,
    parameter: usize,
    value: Static,
    permissions: traits.Facts,
    budget: *Budget,
) Error!bool {
    try budget.tick();
    if (function_id >= program.functions.len or contexts.unknownEntry(
        program,
        function_id,
    )) return false;
    const function = program.functions[@intCast(function_id)];
    const folds = recursive(program, function_id);
    if (parameter >= function.inputs.len or
        (function.effects.len != 0 and
            !folds) or
        function.regions.len != 0)
        return false;
    const slot = function.inputs[parameter];
    const schema = program.schemas[@intCast(function.layout.slots[@intCast(slot)])];
    switch (value) {
        .boolean => if (schema != .boolean) return false,
        .unsigned => |number| {
            const maximum: u64 = switch (schema) {
                .u8 => std.math.maxInt(u8),
                .u16 => std.math.maxInt(u16),
                .u32 => std.math.maxInt(u32),
                .u64 => std.math.maxInt(u64),
                else => return false,
            };
            if (number > maximum) return false;
        },
        .constructor => |id| {
            if (schema != .internal or
                schema.internal != .computation or
                schema.internal.computation.use != .reusable or
                !try closedLeaf(program, id, permissions, budget))
                return false;
        },
        .variant => |tag| {
            const sid = function.layout.slots[@intCast(slot)];
            if (schema != .sum or tag >= schema.sum.len or !permissions.copy[
                @intCast(sid)
            ] or !permissions.drop[
                @intCast(sid)
            ]) return false;
        },
    }
    return parameterUsesEligible(program, function_id, parameter, value, budget, folds, slot);
}

fn parameterUsesEligible(
    program: ir.Program,
    function_id: p.Id,
    parameter: usize,
    value: Static,
    budget: *Budget,
    folds: bool,
    slot: p.Id,
) Error!bool {
    var uses: usize = 0;
    for (program.blocks) |block| {
        try budget.tick();
        if (block.function != function_id) continue;
        for (block.instructions) |op| {
            try budget.tick();
            if (op.destination == slot) return false;
            if (std.mem.indexOfScalar(p.Id, op.operands, slot) != null) {
                if (value == .unsigned) {
                    uses += 1;
                    continue;
                }
                if (value != .variant or
                    op.opcode != .variant_payload or
                    op.operands.len != 1 or
                    op.immediate != value.variant)
                    return false;
                uses += 1;
            }
        }
        const count = parameterTerminatorUses(
            block.terminator,
            function_id,
            parameter,
            value,
            folds,
            slot,
        ) orelse return false;
        uses += count;
    }
    return uses != 0;
}

fn parameterTerminatorUses(
    terminator: ir.Terminator,
    function_id: p.Id,
    parameter: usize,
    value: Static,
    folds: bool,
    slot: p.Id,
) ?usize {
    var uses: usize = 0;
    const usage = access(terminator, slot);
    if (usage.writes != 0) return null;
    switch (terminator) {
        .apply => |apply| {
            if (folds and usage.reads == 0) return 0;
            if (value != .constructor or
                apply.computation != slot or
                usage.reads != 1)
                return null;
            uses += 1;
        },
        .switch_variant => |branch| {
            if (folds and usage.reads == 0) return 0;
            if (value != .variant or branch.value != slot or usage.reads != 1) return null;
            uses += 1;
        },
        .branch => |branch| {
            if (value == .boolean and branch.condition == slot) {
                if (usage.reads != 1) return null;
                uses += 1;
            } else if (value == .unsigned) {
                uses += usage.reads;
            } else if (usage.reads != 0) return null;
        },
        .return_value, .fail, .jump => if (value == .unsigned) {
            uses += usage.reads;
        } else if (usage.reads != 0) return null,
        .call => |call| {
            if (!folds) return null;
            if (call.function == function_id) {
                if (call.arguments[parameter] != slot or usage.reads != 1) return null;
            } else if (usage.reads != 0) return null;
        },
        .perform, .yield_value => if (!folds or usage.reads != 0) return null,
        else => return null,
    }
    return uses;
}
/// Admitted-program opportunity filter; eligibility is rechecked under budget.
pub fn possible(program: ir.Program) bool {
    for (program.blocks) |block| {
        if (block.terminator != .call) continue;
        const target = block.terminator.call.function;
        if (contexts.unknownEntry(program, target)) continue;
        const function = program.functions[@intCast(target)];
        const folds = recursive(program, target);
        if ((function.effects.len != 0 and !folds) or function.regions.len != 0) continue;
        // Every parameter specialization already rejects these control forms.
        // Establish this cheap necessary condition before whole-program facts.
        var supported_body = true;
        for (program.blocks) |body| {
            if (body.function != target) continue;
            switch (body.terminator) {
                .return_value, .fail, .jump, .branch, .apply, .switch_variant => {},
                .call, .perform, .yield_value => if (!folds) {
                    supported_body = false;
                    break;
                },
                else => {
                    supported_body = false;
                    break;
                },
            }
        }
        if (!supported_body) continue;
        for (function.inputs) |slot| {
            const schema = program.schemas[@intCast(function.layout.slots[@intCast(slot)])];
            if (schema == .u8 or
                schema == .u16 or
                schema == .u32 or
                schema == .u64 or
                schema == .boolean or
                schema == .sum or
                (schema == .internal and
                    schema.internal == .computation and
                    schema.internal.computation.use == .reusable))
                return true;
        }
    }
    return false;
}
fn without(a: std.mem.Allocator, values: []const p.Id, index: usize) Error![]const p.Id {
    const result = try a.alloc(p.Id, values.len - 1);
    @memcpy(result[0..index], values[0..index]);
    @memcpy(result[index..], values[index + 1 ..]);
    return result;
}
fn payloadAt(block: ir.Block, before: usize, slot: p.Id, tag: p.Id, budget: *Budget) Error!?p.Id {
    var cursor = before;
    var queried = slot;
    while (cursor != 0) {
        try budget.tick();
        cursor -= 1;
        const op = block.instructions[cursor];
        if (op.destination != queried) continue;
        if (op.opcode == .move) {
            queried = op.operands[0];
            continue;
        }
        if (op.opcode != .variant or op.immediate != tag) return null;
        const payload = op.operands[0];
        for (block.instructions[cursor..]) |later| {
            try budget.tick();
            if (later.destination == payload) return null;
        }
        return payload;
    }
    return null;
}
fn discoveredPayload(
    block: ir.Block,
    state: facts.Block,
    argument: p.Id,
    tag: p.Id,
    budget: *Budget,
) Error!?p.Id {
    var version = state.exit[@intCast(argument)];
    while (state.definitions[version].instruction) |index| {
        try budget.tick();
        const op = block.instructions[index];
        const definition = state.definitions[version];
        if (op.opcode == .move) {
            version = definition.operands[0];
            continue;
        }
        if (op.opcode != .variant or op.immediate != tag) return null;
        const payload = op.operands[0];
        return if (state.exit[@intCast(payload)] == definition.operands[0]) payload else null;
    }
    return null;
}
fn captureFields(program: ir.Program, key: Key) []const p.Id {
    if (key.value != .constructor) return &.{};
    return program.scopes.captures[
        @intCast(program.constructors[
            @intCast(key.value.constructor)
        ].capture)
    ].fields;
}
fn concat(a: std.mem.Allocator, left: []const p.Id, right: []const p.Id) Error![]const p.Id {
    if (right.len == 0) return left;
    return std.mem.concat(a, p.Id, &.{ left, right });
}
fn discoveredCaptures(
    block: ir.Block,
    state: facts.Block,
    argument: p.Id,
    constructor: p.Id,
    budget: *Budget,
) Error!?[]const p.Id {
    var version = state.exit[@intCast(argument)];
    while (state.definitions[version].instruction) |index| {
        try budget.tick();
        const op = block.instructions[index];
        const definition = state.definitions[version];
        if (op.opcode == .move) {
            version = definition.operands[0];
            continue;
        }
        if (op.opcode != .computation or op.immediate != constructor) return null;
        for (op.operands, definition.operands) |slot, captured| {
            try budget.tick();
            if (state.exit[@intCast(slot)] != captured) return null;
        }
        return op.operands;
    }
    return null;
}
fn capturesAt(
    block: ir.Block,
    before: usize,
    slot: p.Id,
    constructor: p.Id,
    budget: *Budget,
) Error!?[]const p.Id {
    var cursor = before;
    var queried = slot;
    while (cursor != 0) {
        try budget.tick();
        cursor -= 1;
        const op = block.instructions[cursor];
        if (op.destination != queried) continue;
        if (op.opcode == .move) {
            queried = op.operands[0];
            continue;
        }
        if (op.opcode != .computation or op.immediate != constructor) return null;
        for (op.operands) |captured| for (block.instructions[cursor..]) |later| {
            try budget.tick();
            if (later.destination == captured) return null;
        };
        return op.operands;
    }
    return null;
}
fn translated(program: ir.Program, variant: Variant, block_id: p.Id) p.Id {
    var index = variant.first_block;
    for (program.blocks, 0..) |block, old| if (block.function == variant.key.function) {
        if (old == block_id) return index;
        index += 1;
    };
    unreachable; // original admission establishes every intra-function target
}
fn translatedEdge(program: ir.Program, variant: Variant, edge: ir.Edge) ir.Edge {
    var result = edge;
    result.block = translated(program, variant, edge.block);
    return result;
}
fn matches(value: Static, certified: origin.Constant) bool {
    return switch (value) {
        .constructor => |id| certified == .constructor and certified.constructor == id,
        .variant => |tag| certified == .variant and certified.variant == tag,
        .boolean => |flag| certified == .boolean and certified.boolean == flag,
        .unsigned => |number| certified == .unsigned and certified.unsigned == number,
    };
}
fn literalValue(program: ir.Program, id: p.Id) ?u64 {
    if (id >= program.constants.len) return null;
    const literal = program.constants[@intCast(id)];
    return switch (program.schemas[@intCast(literal.schema)]) {
        .u8 => literal.bytes[0],
        .u16 => std.mem.readInt(u16, literal.bytes[0..2], .little),
        .u32 => std.mem.readInt(u32, literal.bytes[0..4], .little),
        .u64 => std.mem.readInt(u64, literal.bytes[0..8], .little),
        else => null,
    };
}
fn findLiteral(program: ir.Program, schema: p.Id, value: u64, budget: *Budget) Error!?p.Id {
    for (program.constants, 0..) |literal, id| {
        try budget.tick();
        if (literal.schema == schema and literalValue(program, id) == value) return id;
    }
    return null;
}
pub fn construct(
    allocator: std.mem.Allocator,
    original: ir.Program,
    options: Options,
) Error!?Candidate {
    // A supplied stale profile is rejected even when the later search budget
    // would otherwise return its ordinary no-op fallback.
    if (options.profile) |record| try profiles.validate(allocator, original, record);
    // The default covers shared P02 analysis as in branch/application
    // specialization. An explicit pass limit still caps every phase.
    var budget: Budget = .{ .remaining = options.work_limit };
    var captured: ParameterCaptures = .{
        .allocator = allocator,
        .program = original,
        .budget = &budget,
    };
    defer {
        for (captured.captures.items) |capture| capture.site.destroyCopy(allocator);
        captured.captures.deinit(allocator);
    }
    var discovered = facts.analyzeObservedWithLimit(
        allocator,
        original,
        options.work_limit,
        .{ .context = &captured, .capture = ParameterCaptures.observe },
    ) catch |err| {
        // The observer cannot throw through the admission callback. Preserve its
        // allocation failure even if the subsequent fact search exhausts work.
        if (captured.failure) |failure| if (failure == error.OutOfMemory) return error.OutOfMemory;
        return err;
    };
    defer discovered.deinit();
    try captured.prepare();
    var arena = std.heap.ArenaAllocator.init(allocator);
    var keep = false;
    defer if (!keep) arena.deinit();
    const a = arena.allocator();
    var construction: Construction = .{
        .a = a,
        .original = original,
        .options = options,
        .budget = &budget,
        .captured = &captured,
        .discovered = discovered,
        .permissions = try traits.derive(a, original.schemas),
        .proof = .{ .allocator = a, .program = original, .work_limit = options.work_limit },
    };
    defer construction.proof.deinit();
    try construction.discover();
    if (construction.sites.items.len == 0) return null;
    try construction.generalize();
    const program = try construction.materialize();
    const owned_variants = try construction.variants.toOwnedSlice(a);
    const owned_sites = try construction.sites.toOwnedSlice(a);
    keep = true;
    return .{
        .arena = arena,
        .program = program,
        .variants = owned_variants,
        .sites = owned_sites,
    };
}

const Construction = struct {
    a: std.mem.Allocator,
    original: ir.Program,
    options: Options,
    budget: *Budget,
    captured: *ParameterCaptures,
    discovered: facts.Facts,
    permissions: traits.Facts,
    proof: origin.Prover,
    variants: std.ArrayList(Variant) = .empty,
    sites: std.ArrayList(Site) = .empty,
    added_blocks: usize = 0,
    fn discover(self: *Construction) Error!void {
        const a = self.a;
        const original = self.original;
        const options = self.options;
        const budget = self.budget;
        const discovered = self.discovered;
        const order = if (options.profile) |record| blk: {
            const charge = std.math.mul(
                u64,
                original.blocks.len,
                original.blocks.len,
            ) catch return error.CallPatternLimit;
            if (charge > budget.remaining) return error.CallPatternLimit;
            budget.remaining -= charge;
            break :blk try profiles.orderedBlocks(a, original, record);
        } else null;
        for (0..original.blocks.len) |ordinal| {
            const bid = if (order) |ordered| ordered[ordinal] else ordinal;
            const block = original.blocks[bid];
            const block_facts = discovered.blocks[bid];
            try budget.tick();
            if (!block_facts.reachable or block.terminator != .call) continue;
            const call = block.terminator.call;
            for (call.arguments, 0..) |argument, parameter| {
                if (try self.discoverArgument(bid, parameter, argument)) break;
            }
        }
    }
    fn discoverArgument(
        self: *Construction,
        bid: usize,
        parameter: usize,
        argument: p.Id,
    ) Error!bool {
        const original = self.original;
        const budget = self.budget;
        const discovered = self.discovered;
        const permissions = self.permissions;
        const proof = &self.proof;
        const block = original.blocks[bid];
        const block_facts = discovered.blocks[bid];
        const call = block.terminator.call;
        try budget.tick();
        const value = block_facts.definitions[block_facts.exit[@intCast(argument)]].value;
        const known: Static = if (value.constructor) |id| .{
            .constructor = id,
        } else if (value.variants.singleton()) |tag| .{
            .variant = tag,
        } else if (value.boolean) |flag| .{
            .boolean = flag,
        } else if (value.unsigned) |number| .{ .unsigned = number } else return false;
        if (!try parameterEligible(
            original,
            call.function,
            parameter,
            known,
            permissions,
            budget,
        )) return false;
        const payload: ?p.Id = if (known == .variant) (try discoveredPayload(
            block,
            block_facts,
            argument,
            known.variant,
            budget,
        )) orelse return false else null;
        // Forward discovery can be stronger than the independent prover.
        // Missing proof leaves this call intact; it is not a compile error.
        const certified = (try proof.resolve(bid, block.instructions.len, argument)) orelse {
            if (proof.exhausted) return error.CallPatternLimit;
            return false;
        };
        if (!matches(known, certified)) return false;
        return self.admitArgument(bid, parameter, argument, known, payload);
    }
    fn admitArgument(
        self: *Construction,
        bid: usize,
        parameter: usize,
        argument: p.Id,
        known: Static,
        payload: ?p.Id,
    ) Error!bool {
        const a = self.a;
        const original = self.original;
        const budget = self.budget;
        const captured = self.captured;
        const discovered = self.discovered;
        const permissions = self.permissions;
        const sites = &self.sites;
        const block = original.blocks[bid];
        const block_facts = discovered.blocks[bid];
        const call = block.terminator.call;
        const callee = original.functions[@intCast(call.function)];
        const key: Key = .{
            .epoch = discovered.epoch,
            .function = call.function,
            .parameter = parameter,
            .schema = callee.layout.slots[@intCast(callee.inputs[parameter])],
            .value = known,
        };
        if (!try captured.allows(key, permissions)) return false;
        const fields = captureFields(original, key);
        const captures: []const p.Id = if (fields.len != 0) (try discoveredCaptures(
            block,
            block_facts,
            argument,
            known.constructor,
            budget,
        )) orelse return false else &.{};
        const literal: ?p.Id = if (known == .unsigned) (try findLiteral(
            original,
            key.schema,
            known.unsigned,
            budget,
        )) orelse return false else null;
        const selected = (try self.selectVariant(key, literal)) orelse return false;
        try sites.append(
            a,
            .{ .block = bid, .variant = selected, .payload = payload, .captures = captures },
        );
        return true;
    }
    fn selectVariant(self: *Construction, key: Key, literal: ?p.Id) Error!?usize {
        const a = self.a;
        const original = self.original;
        const options = self.options;
        const variants = &self.variants;
        var selected: ?usize = null;
        for (variants.items, 0..) |variant, index| if (std.meta.eql(variant.key, key)) {
            selected = index;
            break;
        };
        if (selected == null) {
            if (variants.items.len >= options.max_variants) {
                if (options.profile != null) return null;
                return error.CallPatternLimit;
            }
            var count: usize = 0;
            for (original.blocks) |body| if (body.function == key.function) {
                count += 1;
            };
            if (count > options.max_added_blocks -| self.added_blocks) {
                if (options.profile != null) return null;
                return error.CallPatternLimit;
            }
            selected = variants.items.len;
            try variants.append(
                a,
                .{
                    .key = key,
                    .function = original.functions.len + variants.items.len,
                    .first_block = original.blocks.len + self.added_blocks,
                    .literal = literal,
                },
            );
            self.added_blocks += count;
        }
        return selected.?;
    }
    fn generalize(self: *Construction) Error!void {
        const a = self.a;
        const original = self.original;
        const budget = self.budget;
        const proof = &self.proof;
        const variants = &self.variants;
        const sites = &self.sites;
        // Finite binding-time abstraction: only the invariant selected parameter
        // enters a key. Known arguments that change on recurrence are generalized
        // to the ordinary dynamic worker parameters, never successively unfolded.
        for (variants.items, 0..) |*variant, vid| {
            if (!recursive(original, variant.key.function)) continue;
            var generalized: std.ArrayList(usize) = .empty;
            for (original.functions[@intCast(variant.key.function)].inputs, 0..) |_, position| {
                if (position == variant.key.parameter or !try changing(
                    original,
                    variant.key.function,
                    position,
                    budget,
                )) continue;
                for (sites.items) |site| if (site.variant == vid) {
                    const source = original.blocks[site.block];
                    const known = try proof.resolve(
                        site.block,
                        source.instructions.len,
                        source.terminator.call.arguments[position],
                    );
                    if (proof.exhausted) return error.CallPatternLimit;
                    if (known != null) {
                        try generalized.append(a, position);
                        break;
                    }
                };
            }
            variant.generalized_parameters = try generalized.toOwnedSlice(a);
        }
    }
    fn materialize(self: *Construction) Error!ir.Program {
        const a = self.a;
        const original = self.original;
        const options = self.options;
        const variants = &self.variants;
        const functions = try a.alloc(ir.Function, original.functions.len + variants.items.len);
        @memcpy(functions[0..original.functions.len], original.functions);
        const blocks = try a.alloc(ir.Block, original.blocks.len + self.added_blocks);
        @memcpy(blocks[0..original.blocks.len], original.blocks);
        for (variants.items) |variant| try self.materializeWorker(variant, functions, blocks);
        try self.rewriteSites(blocks);
        var program = original;
        program.functions = functions;
        program.blocks = blocks;
        const before_bytes = try image.encodedLength(original);
        const after_bytes = try image.encodedLength(program);
        if (after_bytes > before_bytes and
            after_bytes - before_bytes > options.max_added_bytes)
            return error.CallPatternLimit;
        return program;
    }
    fn rewriteSites(self: *Construction, blocks: []ir.Block) Error!void {
        const a = self.a;
        const budget = self.budget;
        const variants = &self.variants;
        const sites = &self.sites;
        for (sites.items) |site| {
            try budget.tick();
            const variant = variants.items[site.variant];
            const call = &blocks[site.block].terminator.call;
            call.function = variant.function;
            if (variant.key.value != .variant) {
                call.arguments = try concat(
                    a,
                    try without(a, call.arguments, variant.key.parameter),
                    site.captures,
                );
            } else {
                const arguments = try a.dupe(p.Id, call.arguments);
                arguments[variant.key.parameter] = site.payload.?;
                call.arguments = arguments;
            }
        }
    }
    fn materializeWorker(
        self: *Construction,
        variant: Variant,
        functions: []ir.Function,
        blocks: []ir.Block,
    ) Error!void {
        const a = self.a;
        const original = self.original;
        const budget = self.budget;
        try budget.tick();
        const before = original.functions[@intCast(variant.key.function)];
        const fields = captureFields(original, variant.key);
        const capture_inputs = try a.alloc(p.Id, fields.len);
        for (
            capture_inputs,
            0..,
        ) |*slot, index|
            slot.* = if (index == 0)
                before.inputs[variant.key.parameter]
            else
                before.layout.slots.len + index - 1;
        var worker = before;
        worker.entry = translated(original, variant, before.entry);
        if (variant.key.value != .variant) {
            worker.inputs = try concat(
                a,
                try without(a, before.inputs, variant.key.parameter),
                capture_inputs,
            );
            if (fields.len != 0) {
                const layout = try a.dupe(p.Id, before.layout.slots);
                layout[@intCast(before.inputs[variant.key.parameter])] = fields[0];
                worker.layout.slots = try concat(a, layout, fields[1..]);
            }
        } else {
            const slots = try a.dupe(p.Id, before.layout.slots);
            slots[@intCast(before.inputs[variant.key.parameter])] = replacementSchemas(
                original,
                variant.key,
            )[0];
            worker.layout.slots = slots;
        }
        functions[@intCast(variant.function)] = worker;
        try self.materializeBlocks(variant, before, capture_inputs, blocks);
    }
    fn materializeBlocks(
        self: *Construction,
        variant: Variant,
        before: ir.Function,
        capture_inputs: []const p.Id,
        blocks: []ir.Block,
    ) Error!void {
        const original = self.original;
        const budget = self.budget;
        var next = variant.first_block;
        for (original.blocks, 0..) |block, bid| {
            if (block.function != variant.key.function) continue;
            try budget.tick();
            var copy = block;
            copy.function = variant.function;
            try self.materializeInstructions(variant, before, block, bid, &copy);
            try self.materializeTerminator(variant, before, capture_inputs, block, &copy);
            blocks[next] = copy;
            next += 1;
        }
    }
    fn materializeInstructions(
        self: *Construction,
        variant: Variant,
        before: ir.Function,
        block: ir.Block,
        bid: usize,
        copy: *ir.Block,
    ) Error!void {
        const a = self.a;
        if (variant.key.value == .unsigned and bid == before.entry) {
            const instructions = try a.alloc(ir.Instruction, block.instructions.len + 1);
            instructions[0] = .{
                .destination = before.inputs[variant.key.parameter],
                .opcode = .constant,
                .immediate = variant.literal.?,
            };
            @memcpy(instructions[1..], block.instructions);
            copy.instructions = instructions;
        }
        if (variant.key.value == .variant) {
            const instructions = try a.dupe(ir.Instruction, block.instructions);
            for (instructions) |*op|
                if (op.opcode == .variant_payload and
                    op.operands[0] == before.inputs[variant.key.parameter])
                {
                    op.* = .{
                        .destination = op.destination,
                        .opcode = .move,
                        .operands = op.operands,
                    };
                };
            copy.instructions = instructions;
        }
    }
    fn materializeApply(
        self: *Construction,
        variant: Variant,
        before: ir.Function,
        capture_inputs: []const p.Id,
        block: ir.Block,
        copy: *ir.Block,
    ) Error!void {
        const a = self.a;
        const original = self.original;
        const apply = block.terminator.apply;
        if (variant.key.value == .constructor and
            apply.computation == before.inputs[variant.key.parameter])
            copy.terminator = .{
                .call = .{
                    .function = original.constructors[
                        @intCast(variant.key.value.constructor)
                    ].function,
                    .arguments = try concat(a, capture_inputs, apply.arguments),
                    .next = translatedEdge(original, variant, apply.next),
                },
            }
        else
            copy.terminator.apply.next = translatedEdge(
                original,
                variant,
                apply.next,
            );
    }
    fn materializeSwitch(
        self: *Construction,
        variant: Variant,
        before: ir.Function,
        block: ir.Block,
        copy: *ir.Block,
    ) Error!void {
        const a = self.a;
        const original = self.original;
        const branch = block.terminator.switch_variant;
        if (variant.key.value == .variant and
            branch.value == before.inputs[variant.key.parameter])
        {
            var edge = translatedEdge(
                original,
                variant,
                branch.cases[@intCast(variant.key.value.variant)],
            );
            const assignments = try a.dupe(ir.Assignment, edge.assignments);
            for (assignments) |*assignment| if (assignment.source == .returned) {
                assignment.source = .{ .slot = before.inputs[variant.key.parameter] };
            };
            edge.assignments = assignments;
            copy.terminator = .{ .jump = edge };
        } else {
            const edges = try a.dupe(ir.Edge, branch.cases);
            for (edges) |*edge| edge.* = translatedEdge(original, variant, edge.*);
            copy.terminator.switch_variant.cases = edges;
        }
    }
    fn materializeCall(
        self: *Construction,
        variant: Variant,
        capture_inputs: []const p.Id,
        block: ir.Block,
        copy: *ir.Block,
    ) Error!void {
        const a = self.a;
        const original = self.original;
        const call = block.terminator.call;
        copy.terminator.call.next = translatedEdge(original, variant, call.next);
        if (call.function == variant.key.function) {
            copy.terminator.call.function = variant.function;
            if (variant.key.value != .variant)
                copy.terminator.call.arguments = try concat(
                    a,
                    try without(a, call.arguments, variant.key.parameter),
                    capture_inputs,
                );
        }
    }
    fn materializeBranch(
        self: *Construction,
        variant: Variant,
        before: ir.Function,
        block: ir.Block,
        copy: *ir.Block,
    ) Error!void {
        const original = self.original;
        const branch = block.terminator.branch;
        if (variant.key.value == .boolean and
            branch.condition == before.inputs[variant.key.parameter])
        {
            copy.terminator = .{ .jump = translatedEdge(
                original,
                variant,
                if (variant.key.value.boolean) branch.when_true else branch.when_false,
            ) };
        } else {
            copy.terminator.branch.when_true = translatedEdge(
                original,
                variant,
                branch.when_true,
            );
            copy.terminator.branch.when_false = translatedEdge(
                original,
                variant,
                branch.when_false,
            );
        }
    }
    fn materializeTerminator(
        self: *Construction,
        variant: Variant,
        before: ir.Function,
        capture_inputs: []const p.Id,
        block: ir.Block,
        copy: *ir.Block,
    ) Error!void {
        const original = self.original;
        switch (block.terminator) {
            .apply => try self.materializeApply(variant, before, capture_inputs, block, copy),
            .switch_variant => try self.materializeSwitch(variant, before, block, copy),
            .call => try self.materializeCall(variant, capture_inputs, block, copy),
            .perform => |perform| copy.terminator.perform.next = translatedEdge(
                original,
                variant,
                perform.next,
            ),
            .yield_value => |edge| copy.terminator.yield_value = translatedEdge(
                original,
                variant,
                edge,
            ),
            .jump => |edge| copy.terminator.jump = translatedEdge(original, variant, edge),
            .branch => try self.materializeBranch(variant, before, block, copy),
            .return_value, .fail => {},
            else => unreachable,
        }
    }
};

fn edgeCorresponds(original: ir.Program, variant: Variant, before: ir.Edge, after: ir.Edge) bool {
    if (!equal([]const ir.Assignment, before.assignments, after.assignments)) return false;
    // Count source-function blocks independently of the emitter's remapping.
    var ordinal: usize = 0;
    for (original.blocks, 0..) |block, id| {
        if (block.function != variant.key.function) continue;
        if (id == before.block) return after.block == variant.first_block + ordinal;
        ordinal += 1;
    }
    return false;
}
fn payloadEdgeCorresponds(
    original: ir.Program,
    variant: Variant,
    before: ir.Edge,
    after: ir.Edge,
    payload: p.Id,
) bool {
    if (before.assignments.len != after.assignments.len) return false;
    for (before.assignments, after.assignments) |old, new| {
        if (old.destination != new.destination) return false;
        if (old.source == .returned) {
            if (new.source != .slot or new.source.slot != payload) return false;
        } else if (!equal(ir.Source, old.source, new.source)) return false;
    }
    var relocated = after;
    relocated.assignments = before.assignments;
    return edgeCorresponds(original, variant, before, relocated);
}
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    variants: []const Variant,
    sites: []const Site,
    work_limit: u64,
) Error!void {
    var before = try ownership.analyze(allocator, original);
    defer before.deinit();
    var after = try ownership.analyze(allocator, candidate);
    defer after.deinit();
    if (variants.len == 0 or
        sites.len == 0 or
        candidate.functions.len != original.functions.len + variants.len or
        candidate.blocks.len < original.blocks.len)
        return error.InvalidCallPattern;
    var unchanged = candidate;
    unchanged.functions = original.functions;
    unchanged.blocks = original.blocks;
    if (!equal(ir.Program, original, unchanged)) return error.InvalidCallPattern;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const permissions = try traits.derive(scratch.allocator(), original.schemas);
    const epoch = try image.identity(allocator, original);
    var budget: Budget = .{ .remaining = work_limit };
    var proof: origin.Prover = .{
        .allocator = allocator,
        .program = original,
        .work_limit = work_limit,
    };
    defer proof.deinit();
    var validation: Validation = .{
        .original = original,
        .candidate = candidate,
        .variants = variants,
        .sites = sites,
        .permissions = permissions,
        .epoch = epoch,
        .budget = &budget,
        .proof = &proof,
    };
    try validation.check();
}

const Validation = struct {
    original: ir.Program,
    candidate: ir.Program,
    variants: []const Variant,
    sites: []const Site,
    permissions: traits.Facts,
    epoch: [32]u8,
    budget: *Budget,
    proof: *origin.Prover,
    fn check(self: *Validation) Error!void {
        const original = self.original;
        const candidate = self.candidate;
        const variants = self.variants;
        const sites = self.sites;
        for (sites) |site|
            if (site.variant >= variants.len or
                site.block >= original.blocks.len or
                original.blocks[site.block].terminator != .call or
                original.blocks[site.block].terminator.call.function !=
                    variants[site.variant].key.function)
                return error.InvalidCallPattern;
        for (
            original.functions,
            candidate.functions[0..original.functions.len],
        ) |old, new| if (!equal(ir.Function, old, new)) return error.InvalidCallPattern;
        var next_block = original.blocks.len;
        for (variants, 0..) |variant, vid| {
            next_block = try self.checkVariant(variant, vid, next_block);
        }
        if (next_block != candidate.blocks.len) return error.InvalidCallPattern;
        try self.checkOriginalBlocks();
    }
    fn checkGeneralized(
        self: *Validation,
        variant: Variant,
        vid: usize,
        function: ir.Function,
    ) Error!void {
        const original = self.original;
        const sites = self.sites;
        const budget = self.budget;
        const proof = self.proof;
        var generalized_index: usize = 0;
        if (recursive(original, variant.key.function))
            for (function.inputs, 0..) |_, position| {
                if (position == variant.key.parameter or !try changing(
                    original,
                    variant.key.function,
                    position,
                    budget,
                )) continue;
                var is_static = false;
                for (sites) |site|
                    if (site.variant == vid) {
                        const source = original.blocks[site.block];
                        if (position >= source.terminator.call.arguments.len)
                            return error.InvalidCallPattern;
                        const known = try proof.resolve(
                            site.block,
                            source.instructions.len,
                            source.terminator.call.arguments[position],
                        );
                        if (proof.exhausted) return error.CallPatternLimit;
                        if (known != null) {
                            is_static = true;
                            break;
                        }
                    };
                if (is_static) {
                    if (generalized_index >= variant.generalized_parameters.len or
                        variant.generalized_parameters[generalized_index] != position)
                        return error.InvalidCallPattern;
                    generalized_index += 1;
                }
            };
        if (generalized_index != variant.generalized_parameters.len)
            return error.InvalidCallPattern;
    }
    fn checkLiteral(
        self: *Validation,
        variant: Variant,
        function: ir.Function,
        slot: p.Id,
    ) Error!void {
        const original = self.original;
        if (variant.key.schema != function.layout.slots[
            @intCast(slot)
        ]) return error.InvalidCallPattern;
        if (variant.key.value == .unsigned) {
            const literal = variant.literal orelse return error.InvalidCallPattern;
            if (literal >= original.constants.len or original.constants[
                @intCast(literal)
            ].schema != variant.key.schema or literalValue(
                original,
                literal,
            ) != variant.key.value.unsigned) return error.InvalidCallPattern;
        } else if (variant.literal != null) return error.InvalidCallPattern;
    }
    fn checkCaptureLayout(
        self: *Validation,
        function: ir.Function,
        worker: ir.Function,
        fields: []const p.Id,
        slot: p.Id,
        index: usize,
    ) Error!void {
        _ = self;
        if (worker.layout.slots.len != function.layout.slots.len + fields.len - 1 or
            !std.mem.eql(
                p.Id,
                worker.layout.slots[function.layout.slots.len..],
                fields[1..],
            ))
            return error.InvalidCallPattern;
        for (
            function.layout.slots,
            worker.layout.slots[0..function.layout.slots.len],
            0..,
        ) |old_schema, new_schema, position| {
            if (new_schema != (if (position == slot)
                fields[0]
            else
                old_schema))
                return error.InvalidCallPattern;
        }
        for (
            fields,
            0..,
        ) |_, captured|
            if (worker.inputs[index + captured] != (if (captured == 0)
                slot
            else
                function.layout.slots.len + captured - 1))
                return error.InvalidCallPattern;
    }
    fn checkWorker(
        self: *Validation,
        variant: Variant,
        function: ir.Function,
        worker: ir.Function,
        fields: []const p.Id,
        slot: p.Id,
    ) Error!void {
        const original = self.original;
        var metadata = worker;
        metadata.entry = function.entry;
        metadata.inputs = function.inputs;
        if (variant.key.value == .variant or fields.len != 0) metadata.layout = function.layout;
        if (!equal(ir.Function, function, metadata)) return error.InvalidCallPattern;
        if (variant.key.value != .variant) {
            if (worker.inputs.len + 1 != function.inputs.len + fields.len)
                return error.InvalidCallPattern;
            var index: usize = 0;
            for (function.inputs, 0..) |input, position| {
                if (position == variant.key.parameter) continue;
                if (worker.inputs[index] != input) return error.InvalidCallPattern;
                index += 1;
            }
            if (fields.len != 0) try self.checkCaptureLayout(
                function,
                worker,
                fields,
                slot,
                index,
            );
        } else {
            if (!std.mem.eql(p.Id, worker.inputs, function.inputs) or
                worker.layout.slots.len != function.layout.slots.len)
                return error.InvalidCallPattern;
            for (function.layout.slots, worker.layout.slots, 0..) |old, new, position| {
                const expected = if (position == slot) original.schemas[
                    @intCast(variant.key.schema)
                ].sum[
                    @intCast(variant.key.value.variant)
                ] else old;
                if (new != expected) return error.InvalidCallPattern;
            }
        }
    }
    fn checkVariant(
        self: *Validation,
        variant: Variant,
        vid: usize,
        next_block: usize,
    ) Error!usize {
        const original = self.original;
        const candidate = self.candidate;
        const variants = self.variants;
        const sites = self.sites;
        const permissions = self.permissions;
        const epoch = self.epoch;
        const budget = self.budget;
        try budget.tick();
        if (!std.mem.eql(u8, &epoch, &variant.key.epoch) or
            variant.function != original.functions.len + vid or
            variant.first_block != next_block or
            !try parameterEligible(
                original,
                variant.key.function,
                variant.key.parameter,
                variant.key.value,
                permissions,
                budget,
            ))
            return error.InvalidCallPattern;
        for (variants[0..vid]) |previous| if (std.meta.eql(
            previous.key,
            variant.key,
        )) return error.InvalidCallPattern;
        const function = original.functions[@intCast(variant.key.function)];
        const slot = function.inputs[variant.key.parameter];
        try self.checkGeneralized(variant, vid, function);
        try self.checkLiteral(variant, function, slot);
        const fields = captureFields(original, variant.key);
        const worker = candidate.functions[@intCast(variant.function)];
        try self.checkWorker(variant, function, worker, fields, slot);
        var used = false;
        for (sites) |site| if (site.variant == vid) {
            used = true;
        };
        if (!used) return error.InvalidCallPattern;
        return self.checkBlocks(variant, function, worker, fields, slot, next_block);
    }
    fn checkInstructions(
        self: *Validation,
        variant: Variant,
        function: ir.Function,
        slot: p.Id,
        block: ir.Block,
        bid: usize,
        replacement: ir.Block,
    ) Error!void {
        _ = self;
        const prefix: usize = @intFromBool(
            variant.key.value == .unsigned and bid == function.entry,
        );
        if (replacement.function != variant.function or
            replacement.custody != block.custody or
            block.instructions.len + prefix != replacement.instructions.len)
            return error.InvalidCallPattern;
        if (prefix != 0) {
            const initialization: ir.Instruction = .{
                .destination = slot,
                .opcode = .constant,
                .immediate = variant.literal.?,
            };
            if (!equal(
                ir.Instruction,
                initialization,
                replacement.instructions[0],
            )) return error.InvalidCallPattern;
        }
        for (block.instructions, replacement.instructions[prefix..]) |old_op, new_op| {
            var expected = old_op;
            if (variant.key.value == .variant and
                old_op.opcode == .variant_payload and
                old_op.operands[0] == slot)
                expected = .{
                    .destination = old_op.destination,
                    .opcode = .move,
                    .operands = old_op.operands,
                };
            if (!equal(ir.Instruction, expected, new_op)) return error.InvalidCallPattern;
        }
    }
    fn checkApply(
        self: *Validation,
        variant: Variant,
        function: ir.Function,
        fields: []const p.Id,
        slot: p.Id,
        block: ir.Block,
        term: *ir.Terminator,
    ) Error!void {
        const original = self.original;
        const apply = block.terminator.apply;

        if (variant.key.value == .constructor and apply.computation == slot) {
            if (term.* != .call or
                term.call.function != original.constructors[
                    @intCast(variant.key.value.constructor)
                ].function or
                term.call.arguments.len != fields.len + apply.arguments.len or
                !std.mem.eql(
                    p.Id,
                    term.call.arguments[fields.len..],
                    apply.arguments,
                ) or
                !edgeCorresponds(original, variant, apply.next, term.call.next))
                return error.InvalidCallPattern;
            for (
                fields,
                0..,
            ) |_, captured|
                if (term.call.arguments[captured] != (if (captured == 0)
                    slot
                else
                    function.layout.slots.len + captured - 1))
                    return error.InvalidCallPattern;
            term.* = block.terminator;
        } else {
            if (term.* != .apply or !edgeCorresponds(
                original,
                variant,
                apply.next,
                term.apply.next,
            )) return error.InvalidCallPattern;
            term.apply.next = apply.next;
        }
    }
    fn checkSwitch(
        self: *Validation,
        variant: Variant,
        slot: p.Id,
        block: ir.Block,
        term: *ir.Terminator,
    ) Error!void {
        const original = self.original;
        const branch = block.terminator.switch_variant;

        if (variant.key.value == .variant and branch.value == slot) {
            if (term.* != .jump or !payloadEdgeCorresponds(
                original,
                variant,
                branch.cases[@intCast(variant.key.value.variant)],
                term.jump,
                slot,
            )) return error.InvalidCallPattern;
            term.* = block.terminator;
        } else {
            if (term.* != .switch_variant or
                term.switch_variant.cases.len != branch.cases.len)
                return error.InvalidCallPattern;
            for (
                branch.cases,
                term.switch_variant.cases,
            ) |old_edge, new_edge| if (!edgeCorresponds(
                original,
                variant,
                old_edge,
                new_edge,
            )) return error.InvalidCallPattern;
            term.switch_variant.cases = branch.cases;
        }
    }
    fn checkCall(
        self: *Validation,
        variant: Variant,
        function: ir.Function,
        fields: []const p.Id,
        slot: p.Id,
        block: ir.Block,
        term: *ir.Terminator,
    ) Error!void {
        const original = self.original;
        const call = block.terminator.call;

        if (term.* != .call or !edgeCorresponds(
            original,
            variant,
            call.next,
            term.call.next,
        )) return error.InvalidCallPattern;
        if (call.function == variant.key.function) {
            if (term.call.function != variant.function) return error.InvalidCallPattern;
            if (variant.key.value != .variant) {
                if (term.call.arguments.len + 1 != call.arguments.len + fields.len)
                    return error.InvalidCallPattern;
                var at: usize = 0;
                for (
                    call.arguments,
                    0..,
                ) |arg, position| if (position != variant.key.parameter) {
                    if (term.call.arguments[at] != arg) return error.InvalidCallPattern;
                    at += 1;
                };
                for (
                    fields,
                    0..,
                ) |_, captured|
                    if (term.call.arguments[at + captured] != (if (captured == 0)
                        slot
                    else
                        function.layout.slots.len + captured - 1))
                        return error.InvalidCallPattern;
            } else if (!std.mem.eql(
                p.Id,
                call.arguments,
                term.call.arguments,
            )) return error.InvalidCallPattern;
            term.call.function = call.function;
            term.call.arguments = call.arguments;
        }
        term.call.next = call.next;
    }
    fn checkBranch(
        self: *Validation,
        variant: Variant,
        slot: p.Id,
        block: ir.Block,
        term: *ir.Terminator,
    ) Error!void {
        const original = self.original;
        const branch = block.terminator.branch;

        if (variant.key.value == .boolean and branch.condition == slot) {
            const selected = if (variant.key.value.boolean)
                branch.when_true
            else
                branch.when_false;
            if (term.* != .jump or !edgeCorresponds(
                original,
                variant,
                selected,
                term.jump,
            )) return error.InvalidCallPattern;
            term.* = block.terminator;
        } else {
            if (term.* != .branch or !edgeCorresponds(
                original,
                variant,
                branch.when_true,
                term.branch.when_true,
            ) or !edgeCorresponds(
                original,
                variant,
                branch.when_false,
                term.branch.when_false,
            )) return error.InvalidCallPattern;
            term.branch.when_true = branch.when_true;
            term.branch.when_false = branch.when_false;
        }
    }
    fn checkTerminator(
        self: *Validation,
        variant: Variant,
        function: ir.Function,
        fields: []const p.Id,
        slot: p.Id,
        block: ir.Block,
        replacement: ir.Block,
    ) Error!void {
        const original = self.original;
        var term = replacement.terminator;
        switch (block.terminator) {
            .apply => try self.checkApply(variant, function, fields, slot, block, &term),
            .switch_variant => try self.checkSwitch(variant, slot, block, &term),
            .call => try self.checkCall(variant, function, fields, slot, block, &term),
            .perform => |perform| {
                if (term != .perform or !edgeCorresponds(
                    original,
                    variant,
                    perform.next,
                    term.perform.next,
                )) return error.InvalidCallPattern;
                term.perform.next = perform.next;
            },
            .yield_value => |edge| {
                if (term != .yield_value or !edgeCorresponds(
                    original,
                    variant,
                    edge,
                    term.yield_value,
                )) return error.InvalidCallPattern;
                term = block.terminator;
            },
            .jump => |edge| {
                if (term != .jump or !edgeCorresponds(
                    original,
                    variant,
                    edge,
                    term.jump,
                )) return error.InvalidCallPattern;
                term = block.terminator;
            },
            .branch => try self.checkBranch(variant, slot, block, &term),
            .return_value, .fail => {},
            else => return error.InvalidCallPattern,
        }
        if (!equal(ir.Terminator, block.terminator, term)) return error.InvalidCallPattern;
    }
    fn checkBlocks(
        self: *Validation,
        variant: Variant,
        function: ir.Function,
        worker: ir.Function,
        fields: []const p.Id,
        slot: p.Id,
        first_block: usize,
    ) Error!usize {
        const original = self.original;
        const candidate = self.candidate;
        const budget = self.budget;
        var next_block = first_block;
        for (original.blocks, 0..) |block, bid| {
            if (block.function != variant.key.function) continue;
            try budget.tick();
            if (next_block >= candidate.blocks.len) return error.InvalidCallPattern;
            const replacement = candidate.blocks[next_block];
            if (bid == function.entry and
                worker.entry != next_block)
                return error.InvalidCallPattern;
            next_block += 1;
            try self.checkInstructions(variant, function, slot, block, bid, replacement);
            try self.checkTerminator(variant, function, fields, slot, block, replacement);
        }
        return next_block;
    }
    fn checkStaticArguments(
        self: *Validation,
        item: Site,
        variant: Variant,
        known: origin.Constant,
        fields: []const p.Id,
        old: ir.Block,
        new: ir.Block,
    ) Error!void {
        const budget = self.budget;
        const call = old.terminator.call;
        if (!matches(variant.key.value, known) or
            item.payload != null or
            new.terminator.call.arguments.len + 1 != call.arguments.len + fields.len)
            return error.InvalidCallPattern;
        var index: usize = 0;
        for (call.arguments, 0..) |argument, position| {
            if (position == variant.key.parameter) continue;
            if (new.terminator.call.arguments[index] != argument)
                return error.InvalidCallPattern;
            index += 1;
        }
        if (fields.len != 0) {
            const captures = (try capturesAt(
                old,
                old.instructions.len,
                call.arguments[variant.key.parameter],
                variant.key.value.constructor,
                budget,
            )) orelse return error.InvalidCallPattern;
            if (!std.mem.eql(p.Id, captures, item.captures) or !std.mem.eql(
                p.Id,
                new.terminator.call.arguments[index..],
                captures,
            )) return error.InvalidCallPattern;
        }
    }
    fn checkVariantArguments(
        self: *Validation,
        item: Site,
        variant: Variant,
        known: origin.Constant,
        old: ir.Block,
        new: ir.Block,
    ) Error!void {
        const budget = self.budget;
        const call = old.terminator.call;
        if (known != .variant or
            known.variant != variant.key.value.variant or
            new.terminator.call.arguments.len != call.arguments.len)
            return error.InvalidCallPattern;
        const payload = (try payloadAt(
            old,
            old.instructions.len,
            call.arguments[variant.key.parameter],
            known.variant,
            budget,
        )) orelse return error.InvalidCallPattern;
        if (item.payload != payload) return error.InvalidCallPattern;
        for (
            call.arguments,
            new.terminator.call.arguments,
            0..,
        ) |argument, replacement, position| {
            if (replacement != (if (position == variant.key.parameter)
                payload
            else
                argument))
                return error.InvalidCallPattern;
        }
    }
    fn checkSite(
        self: *Validation,
        item: Site,
        old: ir.Block,
        new: ir.Block,
        bid: usize,
    ) Error!void {
        const original = self.original;
        const variants = self.variants;
        const proof = self.proof;
        if (item.variant >= variants.len or
            old.terminator != .call or
            new.terminator != .call)
            return error.InvalidCallPattern;
        const variant = variants[item.variant];
        const call = old.terminator.call;
        if (call.function != variant.key.function or
            new.terminator.call.function != variant.function)
            return error.InvalidCallPattern;
        const known = (try proof.resolve(
            bid,
            old.instructions.len,
            call.arguments[variant.key.parameter],
        )) orelse {
            if (proof.exhausted) return error.CallPatternLimit;
            return error.InvalidCallPattern;
        };
        const fields = captureFields(original, variant.key);
        if (item.captures.len != fields.len) return error.InvalidCallPattern;
        if (variant.key.value != .variant) {
            try self.checkStaticArguments(item, variant, known, fields, old, new);
        } else {
            try self.checkVariantArguments(item, variant, known, old, new);
        }
        var restored = new;
        restored.terminator.call.function = call.function;
        restored.terminator.call.arguments = call.arguments;
        if (!equal(ir.Block, old, restored)) return error.InvalidCallPattern;
    }
    fn checkOriginalBlocks(self: *Validation) Error!void {
        const original = self.original;
        const candidate = self.candidate;
        const sites = self.sites;
        const budget = self.budget;
        var seen: usize = 0;
        for (original.blocks, candidate.blocks[0..original.blocks.len], 0..) |old, new, bid| {
            try budget.tick();
            var site: ?Site = null;
            for (sites) |item| if (item.block == bid) {
                if (site != null) return error.InvalidCallPattern;
                site = item;
            };
            if (site) |item| {
                seen += 1;
                try self.checkSite(item, old, new, bid);
            } else if (!equal(ir.Block, old, new)) return error.InvalidCallPattern;
        }
        if (seen != sites.len) return error.InvalidCallPattern;
    }
};
pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: Options,
) Error!p01.Owned {
    var stats: Statistics = .{};
    for (original.blocks) |block| if (block.terminator == .call) {
        stats.retained_calls += 1;
    };
    defer if (statistics) |out| {
        out.* = stats;
    };
    var candidate = (construct(allocator, original, options) catch |err| switch (err) {
        error.CallPatternLimit, error.SemanticWorkLimit => {
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
        candidate.variants,
        candidate.sites,
        options.work_limit,
    ) catch |err| switch (err) {
        error.CallPatternLimit => {
            stats.work_limit = true;
            return p01.run(allocator, original, options.coalescing);
        },
        else => return err,
    };
    recordSpecializations(original, candidate, &stats);
    recordFallbackCalls(original, candidate, &stats);
    stats.retained_calls -= candidate.sites.len;
    return p01.run(allocator, candidate.program, options.coalescing);
}

fn recordSpecializations(
    original: ir.Program,
    candidate: Candidate,
    stats: *Statistics,
) void {
    stats.variants = candidate.variants.len;
    for (candidate.variants) |variant|
        stats.generalized_parameters += variant.generalized_parameters.len;
    for (candidate.variants) |variant| if (variant.key.value == .unsigned) {
        stats.constants_materialized += 1;
    };
    stats.rewritten_calls = candidate.sites.len;
    for (candidate.variants) |variant|
        for (original.blocks) |block|
            if (block.function == variant.key.function) {
                const selector = original.functions[
                    @intCast(variant.key.function)
                ].inputs[variant.key.parameter];
                if (block.terminator == .apply and
                    variant.key.value == .constructor and
                    block.terminator.apply.computation == selector)
                    stats.direct_applications += 1;
                if (block.terminator == .call) {
                    if (block.terminator.call.function == variant.key.function)
                        stats.folded_calls += 1
                    else
                        stats.residual_boundaries += 1;
                }
                if (block.terminator == .perform or
                    block.terminator == .yield_value or
                    (block.terminator == .apply and
                        (variant.key.value != .constructor or
                            block.terminator.apply.computation != selector)))
                    stats.residual_boundaries += 1;
                if (variant.key.value == .boolean and
                    block.terminator == .branch and
                    block.terminator.branch.condition == original.functions[
                        @intCast(variant.key.function)
                    ].inputs[variant.key.parameter])
                    stats.constant_branches += 1;
                if (variant.key.value == .variant) {
                    if (block.terminator == .switch_variant and
                        block.terminator.switch_variant.value == selector)
                        stats.variant_switches += 1;
                    const slot = original.functions[
                        @intCast(variant.key.function)
                    ].inputs[variant.key.parameter];
                    for (block.instructions) |op|
                        if (op.opcode == .variant_payload and
                            op.operands[0] == slot)
                        {
                            stats.variant_projections += 1;
                        };
                }
            };
}

fn recordFallbackCalls(
    original: ir.Program,
    candidate: Candidate,
    stats: *Statistics,
) void {
    for (original.blocks, 0..) |block, bid| {
        if (block.terminator != .call) continue;
        var specialized = false;
        for (candidate.sites) |site| if (site.block == bid) {
            specialized = true;
        };
        if (specialized) continue;
        for (candidate.variants) |variant|
            if (variant.key.function == block.terminator.call.function) {
                stats.generic_fallback_calls += 1;
                break;
            };
    }
}
