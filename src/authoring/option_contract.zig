//! Closed field vocabularies for heterogeneous canonical option records.
//! Only the record's type is inspected; option values may remain runtime data.
const std = @import("std");

pub fn check(comptime operation: []const u8, comptime Options: type, comptime allowed: []const []const u8) void {
    const fields = switch (@typeInfo(Options)) {
        .@"struct" => |fields| fields,
        else => @compileError("Horos " ++ operation ++ ": expected a named option record"),
    };
    // Zig classifies .{} as an empty tuple. Preserve that canonical spelling.
    if (fields.is_tuple and fields.field_names.len != 0)
        @compileError("Horos " ++ operation ++ ": expected a named option record");
    for (fields.field_names) |name| {
        for (allowed) |accepted| {
            if (std.mem.eql(u8, name, accepted)) break;
        } else @compileError("Horos " ++ operation ++ ": unknown option " ++ name);
    }
}

pub const callable = &.{ "use", "captures", "regions" };
pub const handler = &.{ "mode", "use", "resumption_slots", "obligations", "residual", "return_effects", "clause_effects", "escaping", "captures", "body_use", "body_captures", "body_parameters", "owned_regions", "borrowed_regions", "state" };
pub const choice = &.{ "captures", "residual", "owned_regions", "borrowed_regions" };
