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

pub fn validate(allocator: std.mem.Allocator, image: anytype) a.Error!void {
    const facts = try a.schemas(allocator, image.schemas);
    for (image.scopes.resources) |resource| {
        _ = try a.schemaAt(image.schemas, resource.representation);
        if (!facts.exportable[@intCast(resource.representation)]) return error.InvalidSchema;
        for ([_][]const p.Id{ resource.introducers, resource.eliminators }) |authorities| for (
            authorities,
            0..,
        ) |function, index| {
            if (function >= image.functions.len) return error.InvalidReference;
            if (index != 0 and authorities[index - 1] >= function) return error.NonCanonical;
        };
    }
}

pub fn instruction(image: anytype, function: p.Id, op: anytype, slots: []const p.Id) a.Error!void {
    const resource = try instructionShape(image, op, slots);
    const authorities = if (op.opcode == .resource_pack)
        resource.introducers
    else
        resource.eliminators;
    if (std.mem.indexOfScalar(p.Id, authorities, function) == null) return error.InvalidOwnership;
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
