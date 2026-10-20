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
pub fn cloneCompatible(image: anytype, from: p.Id, to: p.Id) a.Error!bool {
    const owned = try resumption(image, from);
    const template = try resumption(image, to);
    if ((owned.use != .linear and owned.use != .affine) or template.use != .multi) return false;
    inline for (
        @typeInfo(p.ResumptionType).@"struct".field_names,
        @typeInfo(p.ResumptionType).@"struct".field_types,
    ) |field_name, FieldType| {
        if (comptime std.mem.eql(u8, field_name, "use")) continue;
        const equal = if (FieldType == []const p.Id)
            std.mem.eql(p.Id, @field(owned, field_name), @field(template, field_name))
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
pub fn subset(small: []const p.Id, large: []const p.Id) a.Error!void {
    for (small) |id| if (std.mem.indexOfScalar(p.Id, large, id) == null) return error.InvalidEffect;
}
fn row(image: anytype, ids: []const p.Id) a.Error!void {
    for (ids, 0..) |id, index| {
        if (id >= image.effects.len) return error.InvalidEffect;
        if (index > 0 and ids[index - 1] >= id) return error.NonCanonical;
    }
}
/// Capability evidence is positional: its order also orders body parameters.
/// Catalog renumbering must preserve those positions, not sort them by new IDs.
fn evidence(image: anytype, ids: []const p.Id) a.Error!void {
    for (ids, 0..) |id, index| {
        if (id >= image.effects.len) return error.InvalidEffect;
        if (std.mem.indexOfScalar(p.Id, ids[0..index], id) != null) return error.InvalidEffect;
    }
}
fn covers(handler: anytype, effect: p.Id) bool {
    for (handler.clauses) |clause| if (clause.effect == effect) return true;
    return false;
}

fn continuationEffect(image: anytype, handler: anytype, effect: p.Id, escapes: bool) a.Error!void {
    for (handler.clauses) |clause| {
        const signature = try resumption(image, clause.resumption);
        if (handler.mode == .shallow or escapes) try subset(&.{effect}, signature.effects);
        if (handler.mode == .shallow and escapes) try subset(&.{effect}, signature.escaping);
    }
}

fn deepHandlerEffects(image: anytype, handler: anytype) a.Error!void {
    if (handler.mode != .deep) return;
    for (handler.clauses) |clause|
        try subset(handler.effects, (try resumption(image, clause.resumption)).effects);
}

pub fn programSlotSchema(program: anytype, block: anytype, slot: p.Id) a.Error!p.Id {
    const slots = program.functions[@intCast(block.function)].layout.slots;
    if (slot >= slots.len) return error.InvalidReference;
    return slots[@intCast(slot)];
}

/// Effects admitted while producing the result awaited by a saved call edge.
pub fn invocationEffect(
    image: anytype,
    block: anytype,
    facts: effect_scope.Facts,
    effect: p.Id,
) a.Error!bool {
    return switch (block.terminator) {
        .call => |v| containsEffect(image.functions[@intCast(v.function)].effects, effect),
        .apply => |v| containsEffect(
            (try computation(image, try programSlotSchema(image, block, v.computation))).effects,
            effect,
        ),
        .handle => |v| blk: {
            const handler = image.handlers[@intCast(v.handler)];
            const body = try computation(image, try programSlotSchema(image, block, v.body));
            break :blk containsEffect(handler.effects, effect) or
                (containsEffect(body.effects, effect) and
                    !effect_scope.discharged(image, facts, handler, body, effect));
        },
        inline .resume_value, .resume_computation => |v| containsEffect(
            (try resumption(image, try programSlotSchema(image, block, v.resumption))).effects,
            effect,
        ),
        .resume_with => |v| blk: {
            const signature = try resumption(
                image,
                try programSlotSchema(image, block, v.resumption),
            );
            const handler = image.handlers[@intCast(v.handler)];
            break :blk containsEffect(handler.effects, effect) or
                (containsEffect(signature.effects, effect) and
                    (!covers(handler, effect) or containsEffect(signature.escaping, effect)));
        },
        .perform => |v| containsEffect(image.effects[@intCast(v.effect)].use_site_effects, effect),
        .with_region => |v| containsEffect(
            (try computation(image, try programSlotSchema(image, block, v.body))).effects,
            effect,
        ),
        .protect => |v| containsEffect(
            (try computation(image, try programSlotSchema(image, block, v.body))).effects,
            effect,
        ) or containsEffect(
            (try computation(image, try programSlotSchema(image, block, v.cleanup))).effects,
            effect,
        ),
        .dispose => |v| containsEffect(
            (try resumption(image, try programSlotSchema(image, block, v.owned))).effects,
            effect,
        ),
        else => false,
    };
}

pub fn retainsResumption(clause: @import("activation.zig").Clause) bool {
    return clause.strategy == .general;
}

pub fn containsEffect(row_: []const p.Id, effect: p.Id) bool {
    return std.mem.indexOfScalar(p.Id, row_, effect) != null;
}

pub fn validate(allocator: std.mem.Allocator, image: anytype) a.Error!traits.Facts {
    return validateDiagnosed(allocator, image, null);
}

pub fn validateDiagnosed(
    allocator: std.mem.Allocator,
    image: anytype,
    diagnostic: ?*a.Diagnostic,
) a.Error!traits.Facts {
    const facts = try traits.derive(allocator, image.schemas);
    try @import("resource_admission.zig").validate(allocator, image);
    for (image.effects, 0..) |effect, index| {
        if (diagnostic) |d| d.* = .{ .phase = .effect, .effect = index };
        try evidence(image, effect.use_site_effects);
        for (effect.bodies) |schema| _ = try computation(image, schema);
    }
    for (image.functions, 0..) |function, index| {
        if (diagnostic) |d| d.* = .{ .phase = .function, .function = index };
        try row(image, function.effects);
    }
    for (image.schemas, 0..) |schema, index| {
        if (diagnostic) |d| d.* = .{ .phase = .schema, .schema = index };
        if (schema == .internal)
            switch (schema.internal) {
                .capability => |effect| if (effect >= image.effects.len) return error.InvalidEffect,
                .computation => |signature| {
                    try row(image, signature.effects);
                    try @import("region_admission.zig").catalog(image, signature.regions);
                    for (signature.capture_bound) |id| {
                        if (signature.use == .reusable and !facts.copy[
                            @intCast(id)
                        ]) return error.InvalidOwnership;
                        if (signature.use == .multi and !facts.clone[
                            @intCast(id)
                        ]) return error.InvalidOwnership;
                    }
                },
                .resumption => |signature| {
                    try row(image, signature.effects);
                    try evidence(image, signature.handled);
                    try row(image, signature.escaping);
                    try subset(signature.escaping, signature.effects);
                    if (signature.mode == .deep and
                        signature.escaping.len != 0)
                        return error.InvalidEffect;
                    try @import("region_admission.zig").catalog(image, signature.owned_regions);
                    if (signature.effect >= image.effects.len or
                        signature.use == .reusable)
                        return error.InvalidEffect;
                    const effect = image.effects[@intCast(signature.effect)];
                    if (effect.result != signature.input) return error.TypeMismatch;
                    if (signature.use == .multi) {
                        if (signature.obligations) return error.InvalidOwnership;
                        if (effect.control_use != .multi) return error.InvalidOwnership;
                        for (signature.capture_bound) |id| if (!facts.clone[
                            @intCast(id)
                        ]) return error.InvalidOwnership;
                    }
                },
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
    for (image.scopes.captures, 0..) |capture, index| {
        if (diagnostic) |d| d.* = .{ .phase = .capture, .capture = index };
        for (capture.fields, 0..) |schema, field| {
            if (diagnostic) |d| d.field = field;
            _ = try a.schemaAt(image.schemas, schema);
        }
        if (capture.owned_regions.len != 0 or
            capture.borrowed_regions.len != 0)
            return error.UnsupportedInstruction;
    }
    for (image.constructors) |constructor|
        try validateConstructor(image, constructor, diagnostic);
    for (image.handlers, 0..) |handler, index| {
        if (diagnostic) |d| d.* = .{
            .phase = .handler,
            .handler = index,
            .function = handler.return_function,
        };
        _ = try a.schemaAt(image.schemas, handler.input);
        _ = try a.schemaAt(image.schemas, handler.answer);
        try row(image, handler.effects);
        for (handler.state) |schema| {
            _ = try a.schemaAt(image.schemas, schema);
            if (!facts.copy[@intCast(schema)]) return error.InvalidOwnership;
        }
        if (handler.return_function >= image.functions.len) return error.InvalidReference;
        const returns = image.functions[@intCast(handler.return_function)];
        const returned_inputs = inputs.of(returns);
        if (returned_inputs.len == 0 or returned_inputs.len - 1 != handler.state.len or
            returns.result != handler.answer) return error.TypeMismatch;
        if (!returned_inputs.matches(0, handler.state) or
            returned_inputs.at(handler.state.len) != handler.input) return error.TypeMismatch;
        try subset(returns.effects, handler.effects);
        for (handler.clauses, 0..) |clause, clause_index| {
            if (diagnostic) |d| {
                d.function = clause.function;
                d.effect = clause.effect;
                d.schema = clause.resumption;
            }
            if (clause.effect >= image.effects.len or
                clause.function >= image.functions.len)
                return error.InvalidReference;
            for (handler.clauses[0..clause_index]) |previous|
                if (previous.effect == clause.effect)
                    return error.InvalidEffect;
            const effect = image.effects[@intCast(clause.effect)];
            const function = image.functions[@intCast(clause.function)];
            const parameters = inputs.of(function);
            const continuation = try resumption(image, clause.resumption);
            if (continuation.effect != clause.effect or
                continuation.mode != handler.mode or
                continuation.answer != (if (handler.mode == .deep)
                    handler.answer
                else
                    handler.input))
                return error.TypeMismatch;
            if (continuation.handled.len != handler.clauses.len) return error.InvalidEffect;
            for (
                continuation.handled,
                handler.clauses,
            ) |id, handled| if (id != handled.effect) return error.InvalidEffect;
            if (!retainsResumption(clause)) {
                if (handler.mode != .deep or
                    continuation.use != .linear or
                    effect.bodies.len != 0)
                    return error.InvalidProgram;
                if (function.result != effect.result or
                    parameters.len != handler.state.len + 1)
                    return error.TypeMismatch;
                if (!parameters.matches(
                    0,
                    handler.state,
                ) or parameters.at(handler.state.len) != effect.payload) return error.TypeMismatch;
                if (function.effects.len != 0) return error.InvalidEffect;
                if (function.entry >= image.blocks.len) return error.InvalidProgram;
                try @import("total_clause.zig").validate(allocator, image, clause.function, facts);
                continue;
            }
            if (function.result != handler.answer or
                parameters.len != handler.state.len + 2 + effect.bodies.len)
                return error.TypeMismatch;
            if (!parameters.matches(
                0,
                handler.state,
            ) or parameters.at(handler.state.len) != effect.payload or
                !parameters.matches(handler.state.len + 1, effect.bodies) or
                parameters.at(parameters.len - 1) != clause.resumption) return error.TypeMismatch;
            try subset(function.effects, handler.effects);
        }
    }
    return facts;
}

fn validateConstructor(
    image: anytype,
    constructor: p.Constructor,
    diagnostic: ?*a.Diagnostic,
) a.Error!void {
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
    if (!parameters.matches(0, capture.fields) or
        !parameters.matches(capture.fields.len, signature.parameters)) return error.TypeMismatch;
    try subset(function.effects, signature.effects);
    if (!std.mem.eql(p.Id, function.regions, signature.regions)) return error.TypeMismatch;
    for (capture.fields, 0..) |schema, field| {
        if (diagnostic) |d| d.field = field;
        if (std.mem.indexOfScalar(
            p.Id,
            signature.capture_bound,
            schema,
        ) == null) return error.InvalidOwnership;
    }
}

/// Null context checks intrinsic shape/type laws before provenance derivation.
/// Full activation admission always follows with a qualified contextual pass.
pub fn terminator(
    image: anytype,
    block: anytype,
    slots: []const p.Id,
    effect_facts: effect_scope.Facts,
    context: ?@import("control_provenance.zig").Context,
) a.Error!void {
    const function = image.functions[@intCast(block.function)];
    switch (block.terminator) {
        .protect => |protection| {
            const body = try computation(image, try a.slotType(slots, protection.body));
            const cleanup = try computation(image, try a.slotType(slots, protection.cleanup));
            const loaned: usize = @intFromBool(protection.resource != null);
            if (body.parameters.len < loaned or
                cleanup.parameters.len != 1 + loaned or
                try a.schemaAt(image.schemas, cleanup.result) != .unit)
                return error.TypeMismatch;
            try a.arguments(slots, protection.arguments, body.parameters[loaned..]);
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
                for (body.regions) |needed| if (needed != region) try subset(
                    &.{needed},
                    function.regions,
                );
                if (context) |control| try control.analysis.capturesRegion(
                    .{ .block = control.block, .role = .body },
                    body.effects,
                    region,
                );
            } else {
                if (protection.loan_region != null) return error.InvalidOwnership;
                try subset(body.regions, function.regions);
            }
            _ = try @import("cleanup_contract.zig").types(image, cleanup.parameters[0]);
            try subset(body.effects, function.effects);
            try subset(cleanup.effects, function.effects);
            try subset(cleanup.regions, function.regions);
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
            try a.edge(image, block.function, slots, protection.next, body.result);
        },
        .dispose => |disposal| {
            const signature = try resumption(image, try a.slotType(slots, disposal.owned));
            if (signature.use == .multi) return error.InvalidOwnership;
            try subset(signature.effects, function.effects);
            // Explicit disposal returns no value; continuation arguments are moves.
            try a.edge(image, block.function, slots, disposal.next, null);
        },
        .apply => |apply| {
            const signature = try computation(image, try a.slotType(slots, apply.computation));
            try a.arguments(slots, apply.arguments, signature.parameters);
            try subset(signature.effects, function.effects);
            try subset(signature.regions, function.regions);
            try a.edge(image, block.function, slots, apply.next, signature.result);
        },
        .handle => |handle| {
            if (handle.handler >= image.handlers.len) return error.InvalidReference;
            const handler = image.handlers[@intCast(handle.handler)];
            const body = try computation(image, try a.slotType(slots, handle.body));
            try subset(body.regions, function.regions);
            if (body.result != handler.input or
                body.parameters.len != handler.clauses.len + handle.arguments.len)
                return error.TypeMismatch;
            for (
                body.parameters[0..handler.clauses.len],
                handler.clauses,
            ) |schema, clause| try capability(image, schema, clause.effect);
            try a.arguments(slots, handle.arguments, body.parameters[handler.clauses.len..]);
            try a.arguments(slots, handle.state, handler.state);
            for (body.effects) |effect| {
                const escapes = !effect_scope.discharged(
                    image,
                    effect_facts,
                    handler,
                    body,
                    effect,
                );
                if (escapes) try subset(&.{effect}, function.effects);
                try continuationEffect(image, handler, effect, escapes);
            }
            try subset(handler.effects, function.effects);
            try deepHandlerEffects(image, handler);
            try a.edge(image, block.function, slots, handle.next, handler.answer);
        },
        .resume_value => |resuming| {
            const signature = try resumption(image, try a.slotType(slots, resuming.resumption));
            if (try a.slotType(
                slots,
                resuming.argument,
            ) != signature.input) return error.TypeMismatch;
            try subset(signature.effects, function.effects);
            try a.edge(image, block.function, slots, resuming.next, signature.answer);
        },
        .resume_with => |resuming| {
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
            ) |clause, id| if (clause.effect != id) return error.InvalidEffect;
            for (signature.effects) |effect| {
                const escapes = !covers(successor, effect) or
                    std.mem.indexOfScalar(p.Id, signature.escaping, effect) != null;
                if (escapes) try subset(&.{effect}, function.effects);
                try continuationEffect(image, successor, effect, escapes);
            }
            try subset(successor.effects, function.effects);
            try deepHandlerEffects(image, successor);
            try a.arguments(slots, resuming.state, successor.state);
            try a.edge(image, block.function, slots, resuming.next, successor.answer);
        },
        .resume_computation => |resuming| {
            const signature = try resumption(image, try a.slotType(slots, resuming.resumption));
            const thunk = try computation(image, try a.slotType(slots, resuming.computation));
            const effect = image.effects[@intCast(signature.effect)];
            if (thunk.result != signature.input or
                thunk.parameters.len != effect.use_site_effects.len)
                return error.TypeMismatch;
            for (
                thunk.parameters,
                effect.use_site_effects,
            ) |schema, id| try capability(image, schema, id);
            try subset(thunk.effects, effect.use_site_effects);
            try subset(signature.effects, function.effects);
            try a.edge(image, block.function, slots, resuming.next, signature.answer);
        },
        .with_region => |scope| {
            if (scope.region >= image.scopes.region_count) return error.InvalidReference;
            const body = try computation(image, try a.slotType(slots, scope.body));
            if (body.parameters.len != scope.arguments.len + 1) return error.TypeMismatch;
            const region = image.schemas[@intCast(body.parameters[0])];
            if (region != .internal or
                region.internal != .region or
                region.internal.region != scope.region)
                return error.TypeMismatch;
            for (body.regions) |id| if (id != scope.region) try subset(&.{id}, function.regions);
            try a.arguments(slots, scope.arguments, body.parameters[1..]);
            try subset(body.effects, function.effects);
            // The region frame is captured even when no live slot refers to it.
            // Effects handled inside the body have already left its escaping row.
            if (context) |control| try control.analysis.capturesRegion(
                .{ .block = control.block, .role = .body },
                body.effects,
                scope.region,
            );
            try a.edge(image, block.function, slots, scope.next, body.result);
        },
        else => return error.UnsupportedInstruction,
    }
}
