const std = @import("std");
const b = @import("horos");
pub fn main(init: std.process.Init) !void {
    var raw = b.source.Builder.init(init.gpa);
    defer raw.deinit();
    const c = try b.authoring.Context.init(&raw);
    const unit = try c.schema(void);
    const operation = try c.external("operation", unit, unit);
    _ = try c.function("wrong category", .{}, operation, &.{});
}
