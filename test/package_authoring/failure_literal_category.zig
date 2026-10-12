const std = @import("std");
const horos = @import("horos");
pub fn main(init: std.process.Init) !void {
    var raw = horos.source.Builder.init(init.gpa);
    defer raw.deinit();
    const c = try horos.authoring.Context.init(&raw);
    const integer = try c.schema(u64);
    const entry = try c.function("bad failure category", .{}, integer, &.{});
    const body = try c.body(entry);
    const one = try body.constant(u64, 1);
    const two = try body.constant(u64, 2);
    const ordinary = try body.constant(void, {});
    _ = try body.checkedAdd(one, two, ordinary);
}
