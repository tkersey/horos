// Copyright (c) 2026 Boundary contributors. MIT license.
//! Representation authority and loans introduced only by an owning protection.
const std = @import("std");
const p = @import("program.zig");
const a = @import("admission.zig");

pub fn descriptor(image: anytype, schema: p.Id) a.Error!p.Resource {
    const shape = try a.schemaAt(image.schemas, schema);
    if (shape != .internal or
        shape.internal != .abstract_resource or
        shape.internal.abstract_resource >= image.scopes.resources.len)
        return error.TypeMismatch;
    return image.scopes.resources[@intCast(shape.internal.abstract_resource)];
}

pub fn validateWithWork(allocator: std.mem.Allocator, image: anytype, work: ?*u64) a.Error!void {
    try a.spend(work, 1);
    const facts = try a.schemasWithWork(allocator, image.schemas, work);
    for (image.scopes.resources) |resource| {
        try a.spend(work, 1);
        _ = try a.schemaAt(image.schemas, resource.representation);
        if (!facts.exportable[@intCast(resource.representation)]) return error.InvalidSchema;
        for ([_][]const p.Id{ resource.introducers, resource.eliminators }) |authorities| {
            try a.spend(work, 1);
            for (
                authorities,
                0..,
            ) |function, index| {
                try a.spend(work, 1);
                if (function >= image.functions.len) return error.InvalidReference;
                if (index != 0 and authorities[index - 1] >= function) return error.NonCanonical;
            }
        }
    }
}

pub fn instructionWithWork(
    image: anytype,
    function: p.Id,
    op: anytype,
    slots: []const p.Id,
    work: ?*u64,
) a.Error!void {
    try a.spend(work, 1);
    const resource = try instructionShape(image, op, slots);
    const authorities = if (op.opcode == .resource_pack)
        resource.introducers
    else
        resource.eliminators;
    if (!(try @import("contracts.zig").containsEffectWithWork(
        authorities,
        function,
        work,
    ))) return error.InvalidOwnership;
}

pub fn instructionShape(image: anytype, op: anytype, slots: []const p.Id) a.Error!p.Resource {
    if (op.operands.len != 1 or op.immediate != 0) return error.InvalidProgram;
    const input = slots[@intCast(op.operands[0])];
    const shape = image.schemas[@intCast(input)];
    const resource = try descriptor(
        image,
        if (op.opcode == .resource_pack)
            op.result_type
        else if (shape == .internal and
            shape.internal == .borrowed)
            shape.internal.borrowed.value
        else
            input,
    );
    const representation = if (op.opcode == .resource_pack) input else op.result_type;
    if (representation != resource.representation) return error.TypeMismatch;
    return resource;
}

pub fn validate(allocator: std.mem.Allocator, image: anytype) a.Error!void {
    return validateWithWork(allocator, image, null);
}

pub fn instruction(image: anytype, function: p.Id, op: anytype, slots: []const p.Id) a.Error!void {
    return instructionWithWork(image, function, op, slots, null);
}
