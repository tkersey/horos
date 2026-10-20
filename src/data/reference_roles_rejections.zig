const std = @import("std");
const roles = @import("reference_roles.zig");
const mode = @import("rejection_mode").value;
fn extend(comptime T: type) type {
    const fields = @typeInfo(T).@"struct";
    const names = fields.field_names ++ &[_][]const u8{"unclassified"};
    const types = fields.field_types ++ &[_]type{u64};
    return @Struct(
        .auto,
        null,
        names,
        types,
        &(@as([names.len]std.lang.Type.Struct.FieldAttributes, @splat(.{}))),
    );
}
fn changedType(comptime T: type, comptime index: usize) type {
    const fields = @typeInfo(T).@"struct";
    var types: [fields.field_types.len]type = fields.field_types[0..fields.field_types.len].*;
    types[index] = u32;
    return @Struct(
        .auto,
        null,
        fields.field_names,
        &types,
        &(@as([types.len]std.lang.Type.Struct.FieldAttributes, @splat(.{}))),
    );
}
const ir = @import("activation.zig");
comptime {
    if (std.mem.eql(u8, mode, "field")) roles.validateTerminatorPayload(.perform, extend(ir.Perform));
    if (std.mem.eql(u8, mode, "type")) roles.validateTerminatorPayload(.perform, changedType(ir.Perform, 1));
    if (std.mem.eql(u8, mode, "edge")) roles.validateEdge(extend(ir.Edge));
    if (std.mem.eql(u8, mode, "assignment")) roles.validateAssignment(changedType(ir.Assignment, 0));
    if (std.mem.eql(u8, mode, "source")) roles.validateSource(union(enum) {
        slot: u64,
        returned,
        unclassified,
    });
}
