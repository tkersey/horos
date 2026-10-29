// Copyright (c) 2026 Boundary contributors. MIT license.
//! Type, effect and nominal resource contracts over stable activation records.
//! Includes position-sensitive borrow/context provenance. Capture/ownership flow
//! and portable State admission have their own checks.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const a = @import("admission.zig");
const contracts = @import("contracts.zig");
const structure = @import("activation_structure.zig");
const effect_scope = @import("effect_scope.zig");
const provenance = @import("control_provenance.zig");
pub const Error = a.Error || structure.Error;

pub fn validate(allocator: std.mem.Allocator, image: ir.Program) Error!void {
    return validateDiagnosed(allocator, image, null);
}

pub fn validateDiagnosed(
    allocator: std.mem.Allocator,
    image: ir.Program,
    diagnostic: ?*a.Diagnostic,
) Error!void {
    return validateInternal(allocator, image, &.{}, false, &.{}, diagnostic);
}

pub fn validateComponent(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    borrows: []const @import("borrow_contract.zig").Summary,
) Error!void {
    return validateInternal(allocator, image, imports, true, borrows, null);
}
fn validateInternal(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    component: bool,
    borrows: []const @import("borrow_contract.zig").Summary,
    diagnostic: ?*a.Diagnostic,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try validateWithFacts(arena.allocator(), image, imports, component, borrows, diagnostic);
}

pub const ContextualFacts = struct {
    uses: @import("traits.zig").Facts,
    effects: effect_scope.Facts,
    control: *const provenance.Analysis,
};

/// Admission-internal entrypoint. The invocation arena owns the returned facts;
/// all consumers share this one derivation against the immutable input image.
pub fn validateWithFacts(
    scratch: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    component: bool,
    borrows: []const @import("borrow_contract.zig").Summary,
    diagnostic: ?*a.Diagnostic,
) Error!ContextualFacts {
    return validateWithObservedFacts(
        scratch,
        image,
        imports,
        component,
        borrows,
        diagnostic,
        false,
    );
}

pub fn validateWithObservedFacts(
    scratch: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    component: bool,
    borrows: []const @import("borrow_contract.zig").Summary,
    diagnostic: ?*a.Diagnostic,
    explanations: bool,
) Error!ContextualFacts {
    return validateWithObservedFactsAndWork(
        scratch,
        image,
        imports,
        component,
        borrows,
        diagnostic,
        explanations,
        null,
    );
}

pub fn validateWithObservedFactsAndWork(
    scratch: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    component: bool,
    borrows: []const @import("borrow_contract.zig").Summary,
    diagnostic: ?*a.Diagnostic,
    explanations: bool,
    work: ?*u64,
) Error!ContextualFacts {
    try a.spend(work, 1);
    try structure.validateComponentDiagnosedWithWork(scratch, image, imports, diagnostic, work);
    const exportable = try catalogs(scratch, image, component, work);
    const uses = try contracts.validateDiagnosedWithWork(scratch, image, diagnostic, work);
    const effects = try effect_scope.deriveComponentWithWork(scratch, image, imports, work);
    try validateBlockTypes(image, uses, effects, diagnostic, work);
    try @import("region_admission.zig").validateDiagnosedWithWork(
        scratch,
        image,
        diagnostic,
        work,
    );
    const control = try provenance.deriveObservedWithWork(
        scratch,
        image,
        imports,
        component,
        explanations,
        work,
    );
    for (image.blocks, 0..) |block, block_id| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{
            .phase = .block,
            .function = block.function,
            .block = block_id,
        };
        try terminator(
            image,
            block,
            image.functions[@intCast(block.function)].layout.slots,
            effects,
            .{ .analysis = control, .block = block_id },
            work,
        );
    }
    try validateBorrows(
        scratch,
        image,
        imports,
        component,
        borrows,
        diagnostic,
        exportable,
        control,
        work,
    );
    return .{ .uses = uses, .effects = effects, .control = control };
}

fn validateBorrows(
    scratch: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    component: bool,
    borrows: []const @import("borrow_contract.zig").Summary,
    diagnostic: ?*a.Diagnostic,
    exportable: []const bool,
    control: *const provenance.Analysis,
    work: ?*u64,
) Error!void {
    if (component) {
        var solver = try @import("borrow_flow.zig").contractedWithControlAndWork(
            scratch,
            image,
            imports,
            exportable,
            borrows,
            control,
            work,
        );
        for (borrows) |summary| {
            try a.spend(work, 1);
            if (image.functions[
                @intCast(summary.function)
            ].entry == @import("relocation.zig").missing)
                continue;
            try @import("borrow_contract.zig").check(&solver, summary);
        }
    } else try @import("borrow_flow.zig").validateWithControlAndWork(
        scratch,
        image,
        exportable,
        diagnostic,
        control,
        work,
    );
}

fn validateBlockTypes(
    image: ir.Program,
    uses: @import("traits.zig").Facts,
    effects: effect_scope.Facts,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) Error!void {
    for (image.blocks, 0..) |block, block_id| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{
            .phase = .block,
            .function = block.function,
            .block = block_id,
        };
        const layout = image.functions[@intCast(block.function)].layout.slots;
        for (block.instructions) |instruction| {
            try a.spend(work, 1);
            // A single-operation typing view, not a predecessor Program or block.
            // Its result schema is always derived from the owning layout.
            const operation = .{
                .opcode = instruction.opcode,
                .result_type = layout[@intCast(instruction.destination)],
                .operands = instruction.operands,
                .immediate = instruction.immediate,
                .failures = instruction.failures,
            };
            try a.validateInstructionWithWork(image, block.function, operation, layout, uses, work);
            try instructionUses(image, operation, layout, uses, work);
        }
        try terminator(image, block, layout, effects, null, work);
    }
}

/// Exportability remains valid for the immutable image throughout this call.
fn catalogs(
    allocator: std.mem.Allocator,
    image: ir.Program,
    component: bool,
    work: ?*u64,
) Error![]const bool {
    const facts = try a.schemasWithWork(allocator, image.schemas, work);
    if ((!component and !facts.exportable[@intCast(image.roots.result)]) or
        !facts.exportable[@intCast(image.roots.failure)]) return error.InvalidSchema;
    const entry = image.functions[@intCast(image.roots.entry)];
    const parameters = @import("function_inputs.zig").of(entry);
    for (0..parameters.len) |index| {
        try a.spend(work, 1);
        if (!component and !facts.exportable[
            @intCast(parameters.at(index))
        ]) return error.InvalidSchema;
    }
    for (image.constants) |literal| {
        try a.spend(work, 1);
        try a.valueWithWork(allocator, image.schemas, facts, literal, work);
    }
    for (image.effects) |effect| {
        try a.spend(work, 1);
        try a.spend(work, effect.identity.len);
        if (effect.identity.len == 0 or !std.unicode.utf8ValidateSlice(effect.identity))
            return error.InvalidEffect;
        _ = try a.schemaAt(image.schemas, effect.payload);
        _ = try a.schemaAt(image.schemas, effect.result);
        if (!facts.exportable[@intCast(effect.result)]) return error.InvalidEffect;
        if (effect.external and (!facts.exportable[@intCast(effect.payload)] or
            effect.bodies.len != 0)) return error.InvalidEffect;
        for (effect.use_site_effects) |id| {
            try a.spend(work, 1);
            if (id >= image.effects.len)
                return error.InvalidEffect;
        }
    }
    return facts.exportable;
}

fn instructionUses(
    image: ir.Program,
    operation: anytype,
    slots: []const p.Id,
    uses: @import("traits.zig").Facts,
    work: ?*u64,
) Error!void {
    switch (operation.opcode) {
        .sequence_get => {
            const source = image.schemas[@intCast(slots[@intCast(operation.operands[0])])];
            const element = try @import("aggregate_admission.zig").element(source);
            if (!uses.copy[@intCast(element)]) return error.InvalidOwnership;
        },
        .select => if (!uses.drop[@intCast(operation.result_type)]) return error.InvalidOwnership,
        .sequence_set, .sequence_take => {
            const shape = image.schemas[@intCast(operation.result_type)];
            const element = try @import("aggregate_admission.zig").element(shape);
            if (!uses.drop[@intCast(element)]) return error.InvalidOwnership;
        },
        .field => {
            const shape = image.schemas[@intCast(slots[@intCast(operation.operands[0])])];
            for (shape.product, 0..) |field, index| {
                try a.spend(work, 1);
                if (index != operation.immediate and !uses.drop[@intCast(field)])
                    return error.InvalidOwnership;
            }
        },
        else => {},
    }
}

fn terminator(
    image: ir.Program,
    block: ir.Block,
    slots: []const p.Id,
    effects: effect_scope.Facts,
    control: ?provenance.Context,
    work: ?*u64,
) Error!void {
    const function = image.functions[@intCast(block.function)];
    switch (block.terminator) {
        .call => |call| {
            const callee = image.functions[@intCast(call.function)];
            try a.spend(work, call.arguments.len);
            try @import("function_inputs.zig").of(callee).arguments(slots, call.arguments);
            try contracts.subsetWithWork(callee.effects, function.effects, work);
        },
        .perform => |perform| {
            const effect = image.effects[@intCast(perform.effect)];
            if (perform.capability) |slot| {
                try contracts.capability(image, try a.slotType(slots, slot), perform.effect);
            } else if (!effect.external) return error.InvalidEffect;
            try a.argumentsWithWork(slots, perform.bodies, effect.bodies, work);
            if (perform.use_site_capabilities.len != effect.use_site_effects.len)
                return error.InvalidEffect;
            for (perform.use_site_capabilities, effect.use_site_effects) |slot, id| {
                try a.spend(work, 1);
                try contracts.capability(image, try a.slotType(slots, slot), id);
            }
            try contracts.subsetWithWork(&.{perform.effect}, function.effects, work);
            try contracts.subsetWithWork(effect.use_site_effects, function.effects, work);
        },
        .apply,
        .handle,
        .resume_value,
        .resume_with,
        .resume_computation,
        .with_region,
        .protect,
        .dispose,
        => try contracts.terminatorWithWork(image, block, slots, effects, control, work),

        else => {}, // Shape admission checks ordinary values and control edges.
    }
}
