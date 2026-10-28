// Copyright (c) 2026 Boundary contributors. MIT license.
//! Closed higher-order interfaces and their first-order constructor evidence.
const std = @import("std");
const p = @import("program.zig");
const a = @import("admission.zig");
const traits = @import("traits.zig");
const effect_scope = @import("effect_scope.zig");
const inputs = @import("function_inputs.zig");

pub fn computation(image: anytype, schema: p.Id) a.Error!p.ComputationType {
    const shape = try a.schemaAt(image.schemas, schema);
    if (shape != .internal or shape.internal != .computation) return error.TypeMismatch;
    return shape.internal.computation;
}
pub fn resumption(image: anytype, schema: p.Id) a.Error!p.ResumptionType {
    const shape = try a.schemaAt(image.schemas, schema);
    if (shape != .internal or shape.internal != .resumption) return error.TypeMismatch;
    return shape.internal.resumption;
}

/// Conversion changes only use permission. Target schema admission separately
/// proves every captured type CloneSafe and excludes exit obligations.
pub fn cloneCompatibleWithWork(image: anytype, from: p.Id, to: p.Id, work: ?*u64) a.Error!bool {
    try a.spend(work, 1);
    const owned = try resumption(image, from);
    const template = try resumption(image, to);
    if ((owned.use != .linear and owned.use != .affine) or template.use != .multi) return false;
    inline for (
        @typeInfo(p.ResumptionType).@"struct".field_names,
        @typeInfo(p.ResumptionType).@"struct".field_types,
    ) |field_name, FieldType| {
        if (comptime std.mem.eql(u8, field_name, "use")) continue;
        const equal = if (FieldType == []const p.Id)
            try equalIds(@field(owned, field_name), @field(template, field_name), work)
        else
            @field(owned, field_name) == @field(template, field_name);
        if (!equal) return false;
    }
    return true;
}
pub fn capability(image: anytype, schema: p.Id, effect: p.Id) a.Error!void {
    const shape = try a.schemaAt(image.schemas, schema);
    if (shape != .internal or
        shape.internal != .capability or
        shape.internal.capability != effect)
        return error.TypeMismatch;
}
pub fn subsetWithWork(small: []const p.Id, large: []const p.Id, work: ?*u64) a.Error!void {
    try a.spend(work, 1);
    for (small) |id| {
        try a.spend(work, 1);
        if (!(try containsEffectWithWork(large, id, work))) return error.InvalidEffect;
    }
}
fn row(image: anytype, ids: []const p.Id, work: ?*u64) a.Error!void {
    try a.spend(work, 1);
    for (ids, 0..) |id, index| {
        try a.spend(work, 1);
        if (id >= image.effects.len) return error.InvalidEffect;
        if (index > 0 and ids[index - 1] >= id) return error.NonCanonical;
    }
}
/// Capability evidence is positional: its order also orders body parameters.
/// Catalog renumbering must preserve those positions, not sort them by new IDs.
fn evidence(image: anytype, ids: []const p.Id, work: ?*u64) a.Error!void {
    try a.spend(work, 1);
    for (ids, 0..) |id, index| {
        try a.spend(work, 1);
        if (id >= image.effects.len) return error.InvalidEffect;
        if (try containsEffectWithWork(ids[0..index], id, work)) return error.InvalidEffect;
    }
}
fn covers(handler: anytype, effect: p.Id, work: ?*u64) a.Error!bool {
    try a.spend(work, 1);
    for (handler.clauses) |clause| {
        try a.spend(work, 1);
        if (clause.effect == effect) return true;
    }
    return false;
}

fn continuationEffect(
    image: anytype,
    handler: anytype,
    effect: p.Id,
    escapes: bool,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    for (handler.clauses) |clause| {
        try a.spend(work, 1);
        const signature = try resumption(image, clause.resumption);
        if (handler.mode == .shallow or escapes) try subsetWithWork(
            &.{effect},
            signature.effects,
            work,
        );
        if (handler.mode == .shallow and escapes) try subsetWithWork(
            &.{effect},
            signature.escaping,
            work,
        );
    }
}

fn deepHandlerEffects(image: anytype, handler: anytype, work: ?*u64) a.Error!void {
    try a.spend(work, 1);
    if (handler.mode != .deep) return;
    for (handler.clauses) |clause| {
        try a.spend(work, 1);
        try subsetWithWork(
            handler.effects,
            (try resumption(image, clause.resumption)).effects,
            work,
        );
    }
}

pub fn programSlotSchema(program: anytype, block: anytype, slot: p.Id) a.Error!p.Id {
    const slots = program.functions[@intCast(block.function)].layout.slots;
    if (slot >= slots.len) return error.InvalidReference;
    return slots[@intCast(slot)];
}

/// Effects admitted while producing the result awaited by a saved call edge.
pub fn invocationEffectWithWork(
    image: anytype,
    block: anytype,
    facts: effect_scope.Facts,
    effect: p.Id,
    work: ?*u64,
) a.Error!bool {
    try a.spend(work, 1);
    return switch (block.terminator) {
        .call => |v| try containsEffectWithWork(
            image.functions[@intCast(v.function)].effects,
            effect,
            work,
        ),
        .apply => |v| try containsEffectWithWork(
            (try computation(image, try programSlotSchema(image, block, v.computation))).effects,
            effect,
            work,
        ),
        .handle => |v| blk: {
            const handler = image.handlers[@intCast(v.handler)];
            const body = try computation(image, try programSlotSchema(image, block, v.body));
            break :blk try containsEffectWithWork(handler.effects, effect, work) or
                (try containsEffectWithWork(body.effects, effect, work) and
                    !(try effect_scope.dischargedWithWork(
                        image,
                        facts,
                        handler,
                        body,
                        effect,
                        work,
                    )));
        },
        inline .resume_value, .resume_computation => |v| try containsEffectWithWork(
            (try resumption(image, try programSlotSchema(image, block, v.resumption))).effects,
            effect,
            work,
        ),
        .resume_with => |v| try successorInvocationEffect(image, block, v, effect, work),
        .perform => |v| try containsEffectWithWork(
            image.effects[@intCast(v.effect)].use_site_effects,
            effect,
            work,
        ),
        .with_region => |v| try containsEffectWithWork(
            (try computation(image, try programSlotSchema(image, block, v.body))).effects,
            effect,
            work,
        ),
        .protect => |v| try containsEffectWithWork(
            (try computation(image, try programSlotSchema(image, block, v.body))).effects,
            effect,
            work,
        ) or try containsEffectWithWork(
            (try computation(image, try programSlotSchema(image, block, v.cleanup))).effects,
            effect,
            work,
        ),
        .dispose => |v| try containsEffectWithWork(
            (try resumption(image, try programSlotSchema(image, block, v.owned))).effects,
            effect,
            work,
        ),
        else => false,
    };
}

fn successorInvocationEffect(
    image: anytype,
    block: anytype,
    v: anytype,
    effect: p.Id,
    work: ?*u64,
) a.Error!bool {
    const signature = try resumption(
        image,
        try programSlotSchema(image, block, v.resumption),
    );
    const handler = image.handlers[@intCast(v.handler)];
    return try containsEffectWithWork(handler.effects, effect, work) or
        (try containsEffectWithWork(signature.effects, effect, work) and
            (!(try covers(
                handler,
                effect,
                work,
            )) or try containsEffectWithWork(signature.escaping, effect, work)));
}

pub fn retainsResumption(clause: @import("activation.zig").Clause) bool {
    return clause.strategy == .general;
}

pub fn containsEffectWithWork(row_: []const p.Id, effect: p.Id, work: ?*u64) a.Error!bool {
    try a.spend(work, 1);
    for (row_) |id| {
        try a.spend(work, 1);
        if (id == effect) return true;
    }
    return false;
}

pub fn validate(allocator: std.mem.Allocator, image: anytype) a.Error!traits.Facts {
    return validateDiagnosedWithWork(allocator, image, null, null);
}

pub fn validateDiagnosedWithWork(
    allocator: std.mem.Allocator,
    image: anytype,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) a.Error!traits.Facts {
    try a.spend(work, 1);
    const facts = try traits.deriveWithWork(allocator, image.schemas, work);
    try @import("resource_admission.zig").validateWithWork(allocator, image, work);
    for (image.effects, 0..) |effect, index| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{ .phase = .effect, .effect = index };
        try evidence(image, effect.use_site_effects, work);
        for (effect.bodies) |schema| {
            try a.spend(work, 1);
            _ = try computation(image, schema);
        }
    }
    for (image.functions, 0..) |function, index| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{ .phase = .function, .function = index };
        try row(image, function.effects, work);
    }
    for (image.schemas, 0..) |schema, index| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{ .phase = .schema, .schema = index };
        try validateSchema(image, schema, facts, diagnostic, work);
    }
    for (image.scopes.captures, 0..) |capture, index| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{ .phase = .capture, .capture = index };
        for (capture.fields, 0..) |schema, field| {
            try a.spend(work, 1);
            if (diagnostic) |d| d.field = field;
            _ = try a.schemaAt(image.schemas, schema);
        }
        if (capture.owned_regions.len != 0 or
            capture.borrowed_regions.len != 0)
            return error.UnsupportedInstruction;
    }
    for (image.constructors) |constructor| {
        try a.spend(work, 1);
        try validateConstructor(image, constructor, diagnostic, work);
    }
    for (image.handlers, 0..) |handler, index| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{
            .phase = .handler,
            .handler = index,
            .function = handler.return_function,
        };
        try validateHandler(allocator, image, handler, facts, diagnostic, work);
    }
    return facts;
}

fn validateSchema(
    image: anytype,
    schema: p.Schema,
    facts: traits.Facts,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    if (schema == .internal)
        switch (schema.internal) {
            .capability => |effect| if (effect >= image.effects.len) return error.InvalidEffect,
            .computation => |signature| {
                try row(image, signature.effects, work);
                try @import("region_admission.zig").catalogWithWork(image, signature.regions, work);
                for (signature.capture_bound) |id| {
                    try a.spend(work, 1);
                    if (signature.use == .reusable and !facts.copy[
                        @intCast(id)
                    ]) return error.InvalidOwnership;
                    if (signature.use == .multi and !facts.clone[
                        @intCast(id)
                    ]) return error.InvalidOwnership;
                }
            },
            .resumption => |signature| try validateResumption(
                image,
                signature,
                facts,
                diagnostic,
                work,
            ),
            .region => |id| if (id >= image.scopes.region_count) return error.InvalidReference,
            .cell => |cell| {
                if (cell.region >= image.scopes.region_count) return error.InvalidReference;
                if (!facts.copy[@intCast(cell.element)]) return error.UnsupportedInstruction;
            },
            .suspension_package => {}, // Schema admission checks its owned token type.
            .abstract_resource => {
                // The descriptor index is checked independently of representation use.
                if (schema.internal.abstract_resource >= image.scopes.resources.len)
                    return error.InvalidReference;
            },
            .borrowed => |borrow| {
                if (borrow.region >= image.scopes.region_count) return error.InvalidReference;
                _ = try @import("resource_admission.zig").descriptor(image, borrow.value);
            },
        };
}

fn continuationFailure(
    diagnostic: ?*a.Diagnostic,
    detail: a.ContinuationDiagnostic,
    failure: a.Error,
) a.Error {
    if (diagnostic) |d| d.continuation = detail;
    return failure;
}

fn validateResumption(
    image: anytype,
    signature: p.ResumptionType,
    facts: traits.Facts,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) a.Error!void {
    try row(image, signature.effects, work);
    try evidence(image, signature.handled, work);
    try row(image, signature.escaping, work);
    try subsetWithWork(signature.escaping, signature.effects, work);
    if (signature.mode == .deep and signature.escaping.len != 0)
        return continuationFailure(diagnostic, .{ .dimension = .effects }, error.InvalidEffect);
    try @import("region_admission.zig").catalogWithWork(image, signature.owned_regions, work);
    if (signature.effect >= image.effects.len) return error.InvalidEffect;
    if (signature.use == .reusable)
        return continuationFailure(diagnostic, .{ .dimension = .use }, error.InvalidEffect);
    const effect = image.effects[@intCast(signature.effect)];
    if (effect.result != signature.input) return continuationFailure(diagnostic, .{
        .dimension = .input,
        .expected = effect.result,
        .actual = signature.input,
    }, error.TypeMismatch);
    if (signature.use == .multi) {
        if (signature.obligations)
            return continuationFailure(diagnostic, .{ .dimension = .cleanup }, error.InvalidOwnership);
        if (effect.control_use != .multi)
            return continuationFailure(diagnostic, .{ .dimension = .use }, error.InvalidOwnership);
        for (signature.capture_bound) |id| {
            try a.spend(work, 1);
            if (!facts.clone[@intCast(id)]) return continuationFailure(diagnostic, .{
                .dimension = .capture,
                .actual = id,
            }, error.InvalidOwnership);
        }
    }
}

fn validateHandlerClause(
    allocator: std.mem.Allocator,
    image: anytype,
    handler: anytype,
    clause: anytype,
    clause_index: usize,
    facts: traits.Facts,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    if (diagnostic) |d| {
        d.function = clause.function;
        d.effect = clause.effect;
        d.schema = clause.resumption;
    }
    if (clause.effect >= image.effects.len or
        clause.function >= image.functions.len)
        return error.InvalidReference;
    for (handler.clauses[0..clause_index]) |previous| {
        try a.spend(work, 1);
        if (previous.effect == clause.effect)
            return error.InvalidEffect;
    }
    const continuation = try resumption(image, clause.resumption);
    if (continuation.effect != clause.effect) return error.TypeMismatch;
    if (continuation.mode != handler.mode)
        return continuationFailure(diagnostic, .{ .dimension = .mode }, error.TypeMismatch);
    const answer = if (handler.mode == .deep) handler.answer else handler.input;
    if (continuation.answer != answer) return continuationFailure(diagnostic, .{
        .dimension = .answer,
        .expected = answer,
        .actual = continuation.answer,
    }, error.TypeMismatch);
    if (continuation.handled.len != handler.clauses.len) return error.InvalidEffect;
    for (
        continuation.handled,
        handler.clauses,
    ) |id, handled| {
        try a.spend(work, 1);
        if (id != handled.effect) return error.InvalidEffect;
    }
    try validateClauseInputs(allocator, image, handler, clause, facts, work);
}

fn validateClauseInputs(
    allocator: std.mem.Allocator,
    image: anytype,
    handler: anytype,
    clause: anytype,
    facts: traits.Facts,
    work: ?*u64,
) a.Error!void {
    const effect = image.effects[@intCast(clause.effect)];
    const function = image.functions[@intCast(clause.function)];
    const parameters = inputs.of(function);
    const continuation = try resumption(image, clause.resumption);
    if (!retainsResumption(clause)) {
        if (handler.mode != .deep or
            continuation.use != .linear or
            effect.bodies.len != 0)
            return error.InvalidProgram;
        if (function.result != effect.result or
            parameters.len != handler.state.len + 1)
            return error.TypeMismatch;
        if (!(try matches(
            parameters,
            0,
            handler.state,
            work,
        )) or parameters.at(handler.state.len) != effect.payload) return error.TypeMismatch;
        if (function.effects.len != 0) return error.InvalidEffect;
        if (function.entry >= image.blocks.len) return error.InvalidProgram;
        try @import("total_clause.zig").validateWithWork(
            allocator,
            image,
            clause.function,
            facts,
            work,
        );
        return;
    }
    if (function.result != handler.answer or
        parameters.len != handler.state.len + 2 + effect.bodies.len)
        return error.TypeMismatch;
    if (!(try matches(
        parameters,
        0,
        handler.state,
        work,
    )) or parameters.at(handler.state.len) != effect.payload or
        !(try matches(parameters, handler.state.len + 1, effect.bodies, work)) or
        parameters.at(parameters.len - 1) != clause.resumption) return error.TypeMismatch;
    try subsetWithWork(function.effects, handler.effects, work);
}

fn validateHandler(
    allocator: std.mem.Allocator,
    image: anytype,
    handler: anytype,
    facts: traits.Facts,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    _ = try a.schemaAt(image.schemas, handler.input);
    _ = try a.schemaAt(image.schemas, handler.answer);
    try row(image, handler.effects, work);
    for (handler.state) |schema| {
        try a.spend(work, 1);
        _ = try a.schemaAt(image.schemas, schema);
        if (!facts.copy[@intCast(schema)]) return error.InvalidOwnership;
    }
    if (handler.return_function >= image.functions.len) return error.InvalidReference;
    const returns = image.functions[@intCast(handler.return_function)];
    const returned_inputs = inputs.of(returns);
    if (returned_inputs.len == 0 or returned_inputs.len - 1 != handler.state.len or
        returns.result != handler.answer) return error.TypeMismatch;
    if (!(try matches(returned_inputs, 0, handler.state, work)) or
        returned_inputs.at(handler.state.len) != handler.input) return error.TypeMismatch;
    try subsetWithWork(returns.effects, handler.effects, work);
    for (handler.clauses, 0..) |clause, clause_index| {
        try a.spend(work, 1);
        try validateHandlerClause(
            allocator,
            image,
            handler,
            clause,
            clause_index,
            facts,
            diagnostic,
            work,
        );
    }
}

fn validateConstructor(
    image: anytype,
    constructor: p.Constructor,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    if (diagnostic) |d| d.* = .{
        .phase = .constructor,
        .function = constructor.function,
        .capture = constructor.capture,
        .schema = constructor.schema,
    };
    if (constructor.function >= image.functions.len or
        constructor.capture >= image.scopes.captures.len)
        return error.InvalidReference;
    const signature = try computation(image, constructor.schema);
    const function = image.functions[@intCast(constructor.function)];
    const capture = image.scopes.captures[@intCast(constructor.capture)];
    const parameters = inputs.of(function);
    if (parameters.len < capture.fields.len or
        parameters.len - capture.fields.len != signature.parameters.len or
        function.result != signature.result or capture.use != signature.use)
        return error.TypeMismatch;
    if (!(try matches(parameters, 0, capture.fields, work)) or
        !(try matches(
            parameters,
            capture.fields.len,
            signature.parameters,
            work,
        ))) return error.TypeMismatch;
    try subsetWithWork(function.effects, signature.effects, work);
    if (!(try equalIds(function.regions, signature.regions, work))) return error.TypeMismatch;
    for (capture.fields, 0..) |schema, field| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.field = field;
        if (!(try containsEffectWithWork(
            signature.capture_bound,
            schema,
            work,
        ))) return error.InvalidOwnership;
    }
}

/// Null context checks intrinsic shape/type laws before provenance derivation.
/// Full activation admission always follows with a qualified contextual pass.
pub fn terminatorWithWork(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    effect_facts: effect_scope.Facts,
    context: ?@import("control_provenance.zig").Context,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const function = image.functions[@intCast(block.function)];
    switch (block.terminator) {
        .protect => try validateProtection(image, block, slots, context, work),
        .dispose => |disposal| {
            const signature = try resumption(image, try a.slotType(slots, disposal.owned));
            if (signature.use == .multi) return error.InvalidOwnership;
            try subsetWithWork(signature.effects, function.effects, work);
            // Explicit disposal returns no value; continuation arguments are moves.
            try a.edgeWithWork(image, block.function, slots, disposal.next, null, work);
        },
        .apply => |apply| {
            const signature = try computation(image, try a.slotType(slots, apply.computation));
            try a.argumentsWithWork(slots, apply.arguments, signature.parameters, work);
            try subsetWithWork(signature.effects, function.effects, work);
            try subsetWithWork(signature.regions, function.regions, work);
            try a.edgeWithWork(image, block.function, slots, apply.next, signature.result, work);
        },
        .handle => try validateHandle(image, block, slots, effect_facts, work),
        .resume_value => |resuming| {
            const signature = try resumption(image, try a.slotType(slots, resuming.resumption));
            if (try a.slotType(
                slots,
                resuming.argument,
            ) != signature.input) return error.TypeMismatch;
            try subsetWithWork(signature.effects, function.effects, work);
            try a.edgeWithWork(image, block.function, slots, resuming.next, signature.answer, work);
        },
        .resume_with => try validateSuccessor(image, block, slots, work),
        .resume_computation => try validateResumedComputation(image, block, slots, work),
        .with_region => try validateRegion(image, block, slots, context, work),
        else => return error.UnsupportedInstruction,
    }
}

fn validateProtection(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    context: ?@import("control_provenance.zig").Context,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const function = image.functions[@intCast(block.function)];
    const protection = block.terminator.protect;
    const body = try computation(image, try a.slotType(slots, protection.body));
    const cleanup = try computation(image, try a.slotType(slots, protection.cleanup));
    const loaned: usize = @intFromBool(protection.resource != null);
    if (body.parameters.len < loaned or
        cleanup.parameters.len != 1 + loaned or
        try a.schemaAt(image.schemas, cleanup.result) != .unit)
        return error.TypeMismatch;
    try a.argumentsWithWork(slots, protection.arguments, body.parameters[loaned..], work);
    if (protection.resource) |slot| {
        const resource = try a.slotType(slots, slot);
        _ = try @import("resource_admission.zig").descriptor(image, resource);
        const region = protection.loan_region orelse return error.InvalidOwnership;
        if (region >= image.scopes.region_count or
            cleanup.parameters[1] != resource)
            return error.TypeMismatch;
        const borrowed = image.schemas[@intCast(body.parameters[0])];
        if (borrowed != .internal or
            borrowed.internal != .borrowed or
            borrowed.internal.borrowed.value != resource or
            borrowed.internal.borrowed.region != region)
            return error.TypeMismatch;
        for (body.regions) |needed| {
            try a.spend(work, 1);
            if (needed != region) try subsetWithWork(
                &.{needed},
                function.regions,
                work,
            );
        }
        if (context) |control| try control.analysis.capturesRegion(
            .{ .block = control.block, .role = .body },
            body.effects,
            region,
        );
    } else {
        if (protection.loan_region != null) return error.InvalidOwnership;
        try subsetWithWork(body.regions, function.regions, work);
    }
    _ = try @import("cleanup_contract.zig").types(image, cleanup.parameters[0]);
    try subsetWithWork(body.effects, function.effects, work);
    try subsetWithWork(cleanup.effects, function.effects, work);
    try subsetWithWork(cleanup.regions, function.regions, work);
    // These rows describe only effects escaping the computation. A handler
    // installed wholly inside the body can still use multi-shot control.
    if (context) |control| {
        try control.analysis.capturesCleanup(
            .{ .block = control.block, .role = .body },
            body.effects,
        );
        try control.analysis.capturesCleanup(
            .{ .block = control.block, .role = .cleanup },
            cleanup.effects,
        );
    }
    try a.edgeWithWork(image, block.function, slots, protection.next, body.result, work);
}

fn validateHandle(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    effect_facts: effect_scope.Facts,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const function = image.functions[@intCast(block.function)];
    const handle = block.terminator.handle;
    if (handle.handler >= image.handlers.len) return error.InvalidReference;
    const handler = image.handlers[@intCast(handle.handler)];
    const body = try computation(image, try a.slotType(slots, handle.body));
    try subsetWithWork(body.regions, function.regions, work);
    if (body.result != handler.input or
        body.parameters.len != handler.clauses.len + handle.arguments.len)
        return error.TypeMismatch;
    for (
        body.parameters[0..handler.clauses.len],
        handler.clauses,
    ) |schema, clause| {
        try a.spend(work, 1);
        try capability(image, schema, clause.effect);
    }
    try a.argumentsWithWork(slots, handle.arguments, body.parameters[handler.clauses.len..], work);
    try a.argumentsWithWork(slots, handle.state, handler.state, work);
    for (body.effects) |effect| {
        try a.spend(work, 1);
        const escapes = !(try effect_scope.dischargedWithWork(
            image,
            effect_facts,
            handler,
            body,
            effect,
            work,
        ));
        if (escapes) try subsetWithWork(&.{effect}, function.effects, work);
        try continuationEffect(image, handler, effect, escapes, work);
    }
    try subsetWithWork(handler.effects, function.effects, work);
    try deepHandlerEffects(image, handler, work);
    try a.edgeWithWork(image, block.function, slots, handle.next, handler.answer, work);
}

fn validateSuccessor(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const function = image.functions[@intCast(block.function)];
    const resuming = block.terminator.resume_with;
    const signature = try resumption(image, try a.slotType(slots, resuming.resumption));
    if (signature.mode != .shallow or
        try a.slotType(slots, resuming.argument) != signature.input or
        resuming.handler >= image.handlers.len)
        return error.TypeMismatch;
    const successor = image.handlers[@intCast(resuming.handler)];
    if (successor.input != signature.answer or
        successor.clauses.len != signature.handled.len)
        return error.TypeMismatch;
    for (
        successor.clauses,
        signature.handled,
    ) |clause, id| {
        try a.spend(work, 1);
        if (clause.effect != id) return error.InvalidEffect;
    }
    for (signature.effects) |effect| {
        try a.spend(work, 1);
        const escapes = !(try covers(successor, effect, work)) or
            try containsEffectWithWork(signature.escaping, effect, work);
        if (escapes) try subsetWithWork(&.{effect}, function.effects, work);
        try continuationEffect(image, successor, effect, escapes, work);
    }
    try subsetWithWork(successor.effects, function.effects, work);
    try deepHandlerEffects(image, successor, work);
    try a.argumentsWithWork(slots, resuming.state, successor.state, work);
    try a.edgeWithWork(image, block.function, slots, resuming.next, successor.answer, work);
}

fn validateResumedComputation(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const function = image.functions[@intCast(block.function)];
    const resuming = block.terminator.resume_computation;
    const signature = try resumption(image, try a.slotType(slots, resuming.resumption));
    const thunk = try computation(image, try a.slotType(slots, resuming.computation));
    const effect = image.effects[@intCast(signature.effect)];
    if (thunk.result != signature.input or
        thunk.parameters.len != effect.use_site_effects.len)
        return error.TypeMismatch;
    for (
        thunk.parameters,
        effect.use_site_effects,
    ) |schema, id| {
        try a.spend(work, 1);
        try capability(image, schema, id);
    }
    try subsetWithWork(thunk.effects, effect.use_site_effects, work);
    try subsetWithWork(signature.effects, function.effects, work);
    try a.edgeWithWork(image, block.function, slots, resuming.next, signature.answer, work);
}

fn validateRegion(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    context: ?@import("control_provenance.zig").Context,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const function = image.functions[@intCast(block.function)];
    const scope = block.terminator.with_region;
    if (scope.region >= image.scopes.region_count) return error.InvalidReference;
    const body = try computation(image, try a.slotType(slots, scope.body));
    if (body.parameters.len != scope.arguments.len + 1) return error.TypeMismatch;
    const region = image.schemas[@intCast(body.parameters[0])];
    if (region != .internal or
        region.internal != .region or
        region.internal.region != scope.region)
        return error.TypeMismatch;
    for (body.regions) |id| {
        try a.spend(work, 1);
        if (id != scope.region) try subsetWithWork(&.{id}, function.regions, work);
    }
    try a.argumentsWithWork(slots, scope.arguments, body.parameters[1..], work);
    try subsetWithWork(body.effects, function.effects, work);
    // The region frame is captured even when no live slot refers to it.
    // Effects handled inside the body have already left its escaping row.
    if (context) |control| try control.analysis.capturesRegion(
        .{ .block = control.block, .role = .body },
        body.effects,
        scope.region,
    );
    try a.edgeWithWork(image, block.function, slots, scope.next, body.result, work);
}

pub fn cloneCompatible(image: anytype, from: p.Id, to: p.Id) a.Error!bool {
    return cloneCompatibleWithWork(image, from, to, null);
}

pub fn subset(small: []const p.Id, large: []const p.Id) a.Error!void {
    return subsetWithWork(small, large, null);
}

pub fn invocationEffect(
    image: anytype,
    block: anytype,
    facts: effect_scope.Facts,
    effect: p.Id,
) a.Error!bool {
    return invocationEffectWithWork(image, block, facts, effect, null);
}

pub fn validateDiagnosed(
    allocator: std.mem.Allocator,
    image: anytype,
    diagnostic: ?*a.Diagnostic,
) a.Error!traits.Facts {
    return validateDiagnosedWithWork(allocator, image, diagnostic, null);
}

pub fn terminator(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    effect_facts: effect_scope.Facts,
    context: ?@import("control_provenance.zig").Context,
) a.Error!void {
    return terminatorWithWork(image, block, slots, effect_facts, context, null);
}

pub fn containsEffect(row_: []const p.Id, effect: p.Id) bool {
    return std.mem.indexOfScalar(p.Id, row_, effect) != null;
}

fn equalIds(left: []const p.Id, right: []const p.Id, work: ?*u64) a.Error!bool {
    if (left.len != right.len) return false;
    for (left, right) |x, y| {
        try a.spend(work, 1);
        if (x != y) return false;
    }
    return true;
}
fn matches(parameters: anytype, start: usize, expected: []const p.Id, work: ?*u64) a.Error!bool {
    if (start > parameters.len or expected.len > parameters.len - start) return false;
    for (expected, 0..) |shape, index| {
        try a.spend(work, 1);
        if (parameters.at(start + index) != shape) return false;
    }
    return true;
}
