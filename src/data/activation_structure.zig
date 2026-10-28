// Copyright (c) 2026 Boundary contributors. MIT license.
//! The structural layer of stable-activation admission. It checks every slot,
//! destination and control edge. Initialization, liveness, effects, ownership,
//! region flow and full instruction typing are separate required layers; success
//! here alone never grants executable status.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const a = @import("admission.zig");
pub const Error = a.Error || error{
    InvalidReference,
    TypeMismatch,
    DuplicateDestination,
    InvalidProgram,
};

pub fn validate(allocator: std.mem.Allocator, image: ir.Program) Error!void {
    return validateComponentWithWork(allocator, image, &.{}, null);
}

/// Imports are bodyless declarations, never executable entry points.
pub fn validateComponentWithWork(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    work: ?*u64,
) Error!void {
    return validateComponentDiagnosedWithWork(allocator, image, imports, null, work);
}

pub fn validateComponentDiagnosedWithWork(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
    diagnostic: ?*a.Diagnostic,
    work: ?*u64,
) Error!void {
    try a.spend(work, 1);
    var checker: Checker = .{
        .allocator = allocator,
        .image = image,
        .work = work,
        .diagnostic = diagnostic,
    };
    for (imports, 0..) |id, at| {
        try a.spend(work, 1);
        if (id >= image.functions.len or try @import("contracts.zig").containsEffectWithWork(
            imports[0..at],
            id,
            work,
        )) return error.InvalidReference;
    }
    defer checker.destinations.deinit(allocator);
    if (image.roots.profile != 1) return error.InvalidProgram;
    if (image.roots.entry >= image.functions.len) return error.InvalidReference;
    try checker.schema(image.roots.result);
    try checker.schema(image.roots.failure);
    if (image.functions[@intCast(image.roots.entry)].result != image.roots.result)
        return error.TypeMismatch;
    for (image.functions, 0..) |function, id| try checker.validateFunction(function, id, imports);
    for (image.blocks, 0..) |block, block_id| {
        try a.spend(work, 1);
        if (diagnostic) |d| d.* = .{
            .phase = .block,
            .function = block.function,
            .block = block_id,
            .terminator = std.meta.activeTag(block.terminator),
        };
        if (try @import("contracts.zig").containsEffectWithWork(
            imports,
            block.function,
            work,
        )) return error.InvalidProgram;
        try checker.block(block);
    }
}

const Checker = struct {
    allocator: std.mem.Allocator,
    image: ir.Program,
    work: ?*u64,
    diagnostic: ?*a.Diagnostic,
    destinations: std.AutoHashMapUnmanaged(p.Id, void) = .empty,

    fn validateFunction(
        self: *Checker,
        declaration: anytype,
        id: usize,
        imports: []const p.Id,
    ) Error!void {
        try a.spend(self.work, 1);
        const imported = try @import("contracts.zig").containsEffectWithWork(
            imports,
            id,
            self.work,
        );
        if (imported) {
            if (declaration.entry != @import("relocation.zig").missing or
                declaration.inputs.len != declaration.layout.slots.len)
                return error.InvalidProgram;
        } else {
            try self.target(id, declaration.entry);
            if (self.image.blocks[
                @intCast(declaration.entry)
            ].custody != 0) return error.InvalidProgram;
        }
        if (declaration.custody.len == 0 or
            declaration.custody[0].parent != null)
            return error.InvalidProgram;
        for (declaration.custody[1..], 1..) |scope, scope_id| {
            try a.spend(self.work, 1);
            const parent = scope.parent orelse return error.InvalidProgram;
            if (parent >= scope_id) return error.InvalidReference;
        }
        try self.schema(declaration.result);
        for (declaration.layout.slots) |shape_id| {
            try a.spend(self.work, 1);
            try self.schema(shape_id);
        }
        for (declaration.effects) |effect| {
            try a.spend(self.work, 1);
            if (effect >= self.image.effects.len)
                return error.InvalidReference;
        }
        for (declaration.regions) |region| {
            try a.spend(self.work, 1);
            if (region >= self.image.scopes.region_count)
                return error.InvalidReference;
        }
        try self.clearDestinations();
        for (declaration.inputs) |input| {
            try a.spend(self.work, 1);
            _ = try self.slot(id, input);
            try self.destination(input);
        }
    }

    fn schema(self: Checker, id: p.Id) Error!void {
        try a.spend(self.work, 1);
        if (id >= self.image.schemas.len) return error.InvalidReference;
    }

    fn slot(self: Checker, function: p.Id, id: p.Id) Error!p.Id {
        try a.spend(self.work, 1);
        if (function >= self.image.functions.len) return error.InvalidReference;
        const layout = self.image.functions[@intCast(function)].layout.slots;
        if (id >= layout.len) return error.InvalidReference;
        const result = layout[@intCast(id)];
        try self.schema(result);
        return result;
    }

    fn target(self: Checker, owner: p.Id, id: p.Id) Error!void {
        try a.spend(self.work, 1);
        if (id >= self.image.blocks.len) return error.InvalidReference;
        if (self.image.blocks[@intCast(id)].function != owner) return error.InvalidReference;
    }

    fn clearDestinations(self: *Checker) Error!void {
        try a.spend(self.work, self.destinations.capacity());
        self.destinations.clearRetainingCapacity();
    }

    fn destination(self: *Checker, id: p.Id) Error!void {
        try a.spend(self.work, 1);
        const result = try self.destinations.getOrPut(self.allocator, id);
        if (result.found_existing) return error.DuplicateDestination;
    }

    fn slots(self: Checker, function: p.Id, values: []const p.Id) Error!void {
        for (values) |value| {
            try a.spend(self.work, 1);
            _ = try self.slot(function, value);
        }
    }

    fn arguments(
        self: Checker,
        function: p.Id,
        supplied: []const p.Id,
        expected: []const p.Id,
    ) Error!void {
        if (supplied.len != expected.len) return error.TypeMismatch;
        for (supplied, expected) |value, shape| {
            try a.spend(self.work, 1);
            if (try self.slot(function, value) != shape) return error.TypeMismatch;
        }
    }

    fn edge(self: *Checker, owner: p.Id, next: ir.Edge, returned: ?p.Id) Error!void {
        try self.target(owner, next.block);
        try self.clearDestinations();
        for (next.assignments) |assignment| {
            try a.spend(self.work, 1);
            try self.destination(assignment.destination);
            const expected = try self.slot(owner, assignment.destination);
            const actual = switch (assignment.source) {
                .slot => |value| try self.slot(owner, value),
                .returned => returned orelse return error.TypeMismatch,
            };
            if (actual != expected) {
                if (assignment.source == .returned) if (self.diagnostic) |d| {
                    switch (d.terminator orelse return error.TypeMismatch) {
                        .resume_value, .resume_with, .resume_computation => d.continuation = .{
                            .dimension = .answer,
                            .expected = expected,
                            .actual = actual,
                        },
                        else => {},
                    }
                };
                return error.TypeMismatch;
            }
        }
    }

    fn computation(self: Checker, owner: p.Id, value: p.Id) Error!p.ComputationType {
        try a.spend(self.work, 1);
        const shape = self.image.schemas[@intCast(try self.slot(owner, value))];
        if (shape != .internal or shape.internal != .computation) return error.TypeMismatch;
        return shape.internal.computation;
    }

    fn resumption(self: Checker, owner: p.Id, value: p.Id) Error!p.ResumptionType {
        try a.spend(self.work, 1);
        const shape = self.image.schemas[@intCast(try self.slot(owner, value))];
        if (shape != .internal or shape.internal != .resumption) return error.TypeMismatch;
        return shape.internal.resumption;
    }

    fn block(self: *Checker, code: ir.Block) Error!void {
        if (code.function >= self.image.functions.len) return error.InvalidReference;
        const owner = code.function;
        if (code.custody >= self.image.functions[@intCast(owner)].custody.len)
            return error.InvalidReference;
        for (code.instructions) |instruction| {
            try a.spend(self.work, 1);
            _ = try self.slot(owner, instruction.destination);
            try self.slots(owner, instruction.operands);
            for (instruction.failures) |failure| {
                try a.spend(self.work, 1);
                if (failure.value >= self.image.constants.len) return error.InvalidReference;
            }
        }
        switch (code.terminator) {
            .return_value => |value| {
                const function = self.image.functions[@intCast(owner)];
                if (try self.slot(owner, value) != function.result) return error.TypeMismatch;
            },
            .fail => |value| {
                if (try self.slot(owner, value) != self.image.roots.failure)
                    return error.TypeMismatch;
            },
            .jump, .yield_value => |next| try self.edge(owner, next, null),
            .branch => |branch| {
                const shape = self.image.schemas[@intCast(try self.slot(owner, branch.condition))];
                if (shape != .boolean) return error.TypeMismatch;
                try self.edge(owner, branch.when_true, null);
                try self.edge(owner, branch.when_false, null);
            },
            .switch_variant => |selected| {
                const shape = self.image.schemas[@intCast(try self.slot(owner, selected.value))];
                if (shape != .sum or shape.sum.len != selected.cases.len)
                    return error.TypeMismatch;
                for (selected.cases, shape.sum) |next, result| {
                    try a.spend(self.work, 1);
                    try self.edge(owner, next, result);
                }
            },
            .unpack_product => |unpack| try self.checkUnpack(owner, unpack),
            .call => |call| try self.checkCall(owner, call),
            .perform => |perform| try self.checkPerform(owner, perform),
            .apply => |apply| {
                const signature = try self.computation(owner, apply.computation);
                try self.arguments(owner, apply.arguments, signature.parameters);
                try self.edge(owner, apply.next, signature.result);
            },
            .handle => |handle| try self.checkHandle(owner, handle),
            .resume_value, .resume_with, .resume_computation => try self.resumeControl(code),
            .dispose => |dispose| {
                _ = try self.slot(owner, dispose.owned);
                try self.edge(owner, dispose.next, null);
            },
            .protect, .with_region => try self.scopeControl(code),
        }
    }

    fn checkUnpack(self: *Checker, owner: p.Id, operation: anytype) Error!void {
        const shape = self.image.schemas[@intCast(try self.slot(owner, operation.value))];
        if (shape != .product or shape.product.len != operation.destinations.len)
            return error.TypeMismatch;
        try self.clearDestinations();
        for (operation.destinations, shape.product) |id, expected| {
            try a.spend(self.work, 1);
            try self.destination(id);
            if (try self.slot(owner, id) != expected) return error.TypeMismatch;
        }
        // Unpack establishes destinations before taking its ordinary next edge.
        try self.edge(owner, operation.next, null);
    }

    fn checkCall(self: *Checker, owner: p.Id, operation: anytype) Error!void {
        if (operation.function >= self.image.functions.len) return error.InvalidReference;
        const callee = self.image.functions[@intCast(operation.function)];
        if (operation.arguments.len != callee.inputs.len) return error.TypeMismatch;
        for (operation.arguments, callee.inputs) |value, input| {
            try a.spend(self.work, 1);
            if (try self.slot(owner, value) != try self.slot(operation.function, input))
                return error.TypeMismatch;
        }
        try self.edge(owner, operation.next, callee.result);
    }

    fn checkPerform(self: *Checker, owner: p.Id, operation: ir.Perform) Error!void {
        if (operation.effect >= self.image.effects.len) return error.InvalidReference;
        const effect = self.image.effects[@intCast(operation.effect)];
        if (try self.slot(owner, operation.payload) != effect.payload) return error.TypeMismatch;
        if (operation.capability) |value| _ = try self.slot(owner, value);
        try self.arguments(owner, operation.bodies, effect.bodies);
        try self.slots(owner, operation.use_site_capabilities);
        try self.edge(owner, operation.next, effect.result);
    }

    fn checkHandle(self: *Checker, owner: p.Id, operation: anytype) Error!void {
        if (operation.handler >= self.image.handlers.len) return error.InvalidReference;
        const handler = self.image.handlers[@intCast(operation.handler)];
        _ = try self.computation(owner, operation.body);
        try self.slots(owner, operation.arguments);
        try self.arguments(owner, operation.state, handler.state);
        try self.edge(owner, operation.next, handler.answer);
    }

    fn resumeControl(self: *Checker, code: ir.Block) Error!void {
        const owner = code.function;
        switch (code.terminator) {
            inline .resume_value, .resume_with => |operation| {
                const signature = try self.resumption(owner, operation.resumption);
                const argument = try self.slot(owner, operation.argument);
                if (argument != signature.input) {
                    if (self.diagnostic) |d| d.continuation = .{
                        .dimension = .input,
                        .expected = signature.input,
                        .actual = argument,
                    };
                    return error.TypeMismatch;
                }
                var answer = signature.answer;
                if (code.terminator == .resume_with) {
                    const successor = code.terminator.resume_with;
                    if (successor.handler >= self.image.handlers.len)
                        return error.InvalidReference;
                    const handler = self.image.handlers[@intCast(successor.handler)];
                    if (handler.input != signature.answer) {
                        if (self.diagnostic) |d| d.continuation = .{
                            .dimension = .answer,
                            .expected = handler.input,
                            .actual = signature.answer,
                        };
                        return error.TypeMismatch;
                    }
                    try self.arguments(owner, successor.state, handler.state);
                    answer = handler.answer;
                }
                try self.edge(owner, operation.next, answer);
            },
            .resume_computation => |operation| {
                const signature = try self.resumption(owner, operation.resumption);
                _ = try self.computation(owner, operation.computation);
                try self.edge(owner, operation.next, signature.answer);
            },
            else => return error.InvalidProgram,
        }
    }

    fn scopeControl(self: *Checker, code: ir.Block) Error!void {
        const owner = code.function;
        switch (code.terminator) {
            .protect => |operation| {
                const signature = try self.computation(owner, operation.body);
                _ = try self.computation(owner, operation.cleanup);
                try self.slots(owner, operation.arguments);
                if (operation.resource) |value| _ = try self.slot(owner, value);
                if (operation.loan_region) |region| if (region >= self.image.scopes.region_count)
                    return error.InvalidReference;
                try self.edge(owner, operation.next, signature.result);
            },
            .with_region => |operation| {
                if (operation.region >= self.image.scopes.region_count)
                    return error.InvalidReference;
                const signature = try self.computation(owner, operation.body);
                try self.slots(owner, operation.arguments);
                try self.edge(owner, operation.next, signature.result);
            },
            else => return error.InvalidProgram,
        }
    }
};

pub fn validateComponent(
    allocator: std.mem.Allocator,
    image: ir.Program,
    imports: []const p.Id,
) Error!void {
    return validateComponentWithWork(allocator, image, imports, null);
}
