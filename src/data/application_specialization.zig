// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked replacement of a locally constructed computation by its direct call.
//! This is an external-semantics transformation, not a same-microstep quotient.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const facts = @import("value_facts.zig");
const ownership = @import("activation_ownership.zig");
const admission = @import("admission.zig");
const coalescing = @import("coalescing.zig");
const equal = @import("record_equal.zig").equal;
const origin_proof = @import("constant_origin.zig");
pub const Error = facts.Error || coalescing.Error || error{InvalidSpecialization};
pub const Statistics = struct {
    direct_applications: usize = 0,
    eliminated_constructions: usize = 0,
    retained_constructions: usize = 0,
    unavailable_captures: usize = 0,
    retained_applications: usize = 0,
    proof_work_limit: bool = false,
};
pub const Witness = struct { block: usize, construction: ?usize = null };

/// Original admission, versioned discovery, independent correspondence,
/// fresh admission, and final mandatory P01. No runtime image is modified.
pub fn run(
    allocator: std.mem.Allocator,
    original: ir.Program,
    statistics: ?*Statistics,
    options: coalescing.Options,
) Error!coalescing.Owned {
    var observed: Statistics = .{};
    defer if (statistics) |out| {
        out.* = observed;
    };
    var known = try facts.analyze(allocator, original);
    defer known.deinit();
    try known.requireEpoch(allocator, original);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schemas = try admission.schemas(a, original.schemas);
    const blocks = try a.dupe(ir.Block, original.blocks);
    var witnesses: std.ArrayList(Witness) = .empty;
    var proof: origin_proof.Prover = .{ .allocator = a, .program = original };
    defer proof.deinit();
    var specializer: Specializer = .{
        .allocator = a,
        .original = original,
        .exportable = schemas.exportable,
        .observed = &observed,
        .witnesses = &witnesses,
        .proof = &proof,
    };
    for (original.blocks, known.blocks, blocks, 0..) |block, state, *out, index|
        try specializer.specialize(block, state, index, out);
    var candidate = original;
    candidate.blocks = blocks;
    try validate(allocator, original, candidate, witnesses.items);
    var checked = try ownership.analyze(allocator, candidate);
    checked.deinit();
    observed.proof_work_limit = proof.exhausted;
    observed.direct_applications = witnesses.items.len;
    observed.eliminated_constructions = witnesses.items.len - observed.retained_constructions;
    return coalescing.run(allocator, candidate, options);
}

const Specializer = struct {
    allocator: std.mem.Allocator,
    original: ir.Program,
    exportable: []const bool,
    observed: *Statistics,
    witnesses: *std.ArrayList(Witness),
    proof: *origin_proof.Prover,

    fn specialize(
        self: *Specializer,
        block: ir.Block,
        state: facts.Block,
        index: usize,
        out: *ir.Block,
    ) Error!void {
        if (!state.reachable or block.terminator != .apply) return;
        const apply = block.terminator.apply;
        const value = state.definitions[state.exit[@intCast(apply.computation)]].value;
        const origin = value.construction orelse {
            try self.specializeClosed(block, index, value, out);
            return;
        };
        if (value.constructor == null or !eligible(self.original, index, origin, self.exportable)) {
            self.observed.retained_applications += 1;
            return;
        }
        const construction = block.instructions[origin];
        const definition = state.definitions[state.results[origin]];
        var available = true;
        for (construction.operands, definition.operands) |slot, version| {
            if (state.exit[@intCast(slot)] != version) available = false;
        }
        if (!available) {
            self.observed.unavailable_captures += 1;
            return;
        }
        const constructor = self.original.constructors[@intCast(construction.immediate)];
        const arguments = try self.allocator.alloc(
            p.Id,
            construction.operands.len + apply.arguments.len,
        );
        @memcpy(arguments[0..construction.operands.len], construction.operands);
        @memcpy(arguments[construction.operands.len..], apply.arguments);
        const instructions = try self.allocator.alloc(ir.Instruction, block.instructions.len - 1);
        @memcpy(instructions[0..origin], block.instructions[0..origin]);
        @memcpy(instructions[origin..], block.instructions[origin + 1 ..]);
        out.instructions = instructions;
        out.terminator = .{ .call = .{
            .function = constructor.function,
            .arguments = arguments,
            .next = apply.next,
        } };
        try self.witnesses.append(self.allocator, .{ .block = index, .construction = origin });
    }

    fn specializeClosed(
        self: *Specializer,
        block: ir.Block,
        index: usize,
        value: facts.Value,
        out: *ir.Block,
    ) Error!void {
        const apply = block.terminator.apply;
        const constructor = value.constructor orelse {
            self.observed.retained_applications += 1;
            return;
        };
        const verified = try self.proof.resolve(
            index,
            block.instructions.len,
            apply.computation,
        );
        if (!closedReusable(self.original, constructor) or
            verified == null or
            verified.? != .constructor or
            verified.?.constructor != constructor)
        {
            self.observed.retained_applications += 1;
            return;
        }
        out.terminator = .{ .call = .{
            .function = self.original.constructors[@intCast(constructor)].function,
            .arguments = apply.arguments,
            .next = apply.next,
        } };
        try self.witnesses.append(self.allocator, .{ .block = index });
        self.observed.retained_constructions += 1;
    }
};

fn closedReusable(program: ir.Program, id: p.Id) bool {
    const constructor = program.constructors[@intCast(id)];
    const capture = program.scopes.captures[@intCast(constructor.capture)];
    const callable = program.schemas[@intCast(constructor.schema)].internal.computation;
    return capture.fields.len == 0 and
        capture.owned_regions.len == 0 and
        capture.borrowed_regions.len == 0 and
        callable.use == .reusable and
        program.functions[
            @intCast(constructor.function)
        ].regions.len == 0;
}

fn eligible(program: ir.Program, block_id: usize, index: usize, exportable: []const bool) bool {
    const block = program.blocks[block_id];
    if (index >= block.instructions.len or block.terminator != .apply) return false;
    const instruction = block.instructions[index];
    if (instruction.opcode != .computation or
        instruction.destination != block.terminator.apply.computation)
        return false;
    const constructor = program.constructors[@intCast(instruction.immediate)];
    const capture = program.scopes.captures[@intCast(constructor.capture)];
    const function = program.functions[@intCast(constructor.function)];
    if (capture.owned_regions.len != 0 or
        capture.borrowed_regions.len != 0 or
        function.regions.len != 0)
        return false;
    for (capture.fields) |schema| if (!exportable[@intCast(schema)]) return false;
    // One definition and one consumption prevent both escaping aliases and
    // accidentally retaining a prior value when the construction is removed.
    var reads: usize = 0;
    var writes: usize = std.mem.count(
        p.Id,
        program.functions[@intCast(block.function)].inputs,
        &.{instruction.destination},
    );
    for (program.blocks) |other| {
        if (other.function != block.function) continue;
        for (other.instructions) |operation| {
            reads += std.mem.count(p.Id, operation.operands, &.{instruction.destination});
            if (operation.destination == instruction.destination) writes += 1;
        }
        const uses = access(other.terminator, instruction.destination);
        reads += uses.reads;
        writes += uses.writes;
    }
    return reads == 1 and writes == 1;
}

/// The checker does not consume finder facts. It checks the actual construction,
/// every intervening write, ordered ABI operands, and all unchanged records.
pub fn validate(
    allocator: std.mem.Allocator,
    original: ir.Program,
    candidate: ir.Program,
    witnesses: []const Witness,
) Error!void {
    var original_check = try ownership.analyze(allocator, original);
    defer original_check.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schemas = try admission.schemas(arena.allocator(), original.schemas);
    var unchanged = candidate;
    unchanged.blocks = original.blocks;
    if (!equal(
        ir.Program,
        original,
        unchanged,
    ) or candidate.blocks.len != original.blocks.len) return error.InvalidSpecialization;
    var proof: origin_proof.Prover = .{ .allocator = allocator, .program = original };
    defer proof.deinit();
    for (original.blocks, candidate.blocks, 0..) |before, after, index| {
        var witness: ?Witness = null;
        for (witnesses) |item| if (item.block == index) {
            if (witness != null) return error.InvalidSpecialization;
            witness = item;
        };
        if (witness) |item| {
            if (item.construction == null) {
                try validateClosed(original, before, after, index, &proof);
                continue;
            }
            try validateConstruction(original, before, after, index, item, schemas.exportable);
        } else if (!equal(ir.Block, before, after)) return error.InvalidSpecialization;
    }
    for (witnesses) |item|
        if (item.block >= original.blocks.len)
            return error.InvalidSpecialization;
}
const access = @import("slot_access.zig").terminator;

test "scope bodies and cleanup computations are real closure uses" {
    try std.testing.expectEqual(
        @as(usize, 1),
        access(
            .{ .handle = .{
                .handler = 0,
                .body = 5,
                .arguments = &.{},
                .state = &.{},
                .next = .{ .block = 0 },
            } },
            5,
        ).reads,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        access(
            .{ .protect = .{
                .body = 5,
                .cleanup = 5,
                .arguments = &.{},
                .next = .{ .block = 0 },
            } },
            5,
        ).reads,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        access(
            .{ .with_region = .{
                .region = 0,
                .body = 5,
                .arguments = &.{},
                .next = .{ .block = 0 },
            } },
            5,
        ).reads,
    );
}

fn validateClosed(
    original: ir.Program,
    before: ir.Block,
    after: ir.Block,
    index: usize,
    proof: *origin_proof.Prover,
) Error!void {
    if (before.terminator != .apply or
        after.terminator != .call)
        return error.InvalidSpecialization;
    const apply = before.terminator.apply;
    const proven = (try proof.resolve(
        index,
        before.instructions.len,
        apply.computation,
    )) orelse return error.InvalidSpecialization;
    if (proven != .constructor or !closedReusable(
        original,
        proven.constructor,
    )) return error.InvalidSpecialization;
    var expected = before;
    expected.terminator = .{ .call = .{
        .function = original.constructors[@intCast(proven.constructor)].function,
        .arguments = apply.arguments,
        .next = apply.next,
    } };
    if (!equal(ir.Block, expected, after)) return error.InvalidSpecialization;
}

fn validateConstruction(
    original: ir.Program,
    before: ir.Block,
    after: ir.Block,
    index: usize,
    item: Witness,
    exportable: []const bool,
) Error!void {
    const position = item.construction.?;
    if (!eligible(
        original,
        index,
        position,
        exportable,
    )) return error.InvalidSpecialization;
    const construction = before.instructions[position];
    const apply = before.terminator.apply;
    for (before.instructions[position + 1 ..]) |operation| {
        for (construction.operands) |capture|
            if (operation.destination == capture)
                return error.InvalidSpecialization;
    }
    if (after.function != before.function or
        after.custody != before.custody or
        after.terminator != .call)
        return error.InvalidSpecialization;
    const call = after.terminator.call;
    const constructor = original.constructors[@intCast(construction.immediate)];
    if (call.function != constructor.function or !equal(
        ir.Edge,
        call.next,
        apply.next,
    )) return error.InvalidSpecialization;
    if (call.arguments.len != construction.operands.len + apply.arguments.len)
        return error.InvalidSpecialization;
    if (!std.mem.eql(
        p.Id,
        call.arguments[0..construction.operands.len],
        construction.operands,
    ) or
        !std.mem.eql(
            p.Id,
            call.arguments[construction.operands.len..],
            apply.arguments,
        )) return error.InvalidSpecialization;
    if (after.instructions.len + 1 != before.instructions.len)
        return error.InvalidSpecialization;
    for (before.instructions, 0..) |instruction, old| {
        if (old == position) continue;
        const at = old - @intFromBool(old > position);
        if (!equal(
            ir.Instruction,
            instruction,
            after.instructions[at],
        )) return error.InvalidSpecialization;
    }
}
