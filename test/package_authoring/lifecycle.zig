const std = @import("std");
const horos = @import("horos");
pub fn main(init: std.process.Init) !void {
    var raw = horos.source.Builder.init(init.gpa);
    defer raw.deinit();
    const c = try horos.authoring.Context.init(&raw);
    const unit = try c.schema(void);
    const entry = try c.function("closed", .{}, unit, &.{});
    const body = try c.body(entry);
    try c.define(entry, try body.ret(try body.constant(void, {})));
    body.scope.active = true;
}
