const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const ast = @import("ast.zig");
const check = @import("check.zig");
const Error = source.Error || error{ InvalidRelation, UnsupportedRelation };

pub const Binding = struct { function: u64, schema: u64, captures: []const u64 };
pub const Transport = struct {
    functions: ?[]const ?u64 = null,
    schemas: ?[]const ?u64 = null,
    variables: ?[]const ?u64 = null,
    constructors: ?[]const ?u64 = null,
    values: ?[]const ?u64 = null,

    pub fn id(map: ?[]const ?u64, old: u64) Error!u64 {
        const entries = map orelse return old;
        if (old >= entries.len) return error.InvalidRelation;
        return entries[@intCast(old)] orelse error.InvalidRelation;
    }
};

const Capture = struct {
    allocator: std.mem.Allocator,
    work: *u64,
    bindings: []const Binding = &.{},

    fn receive(
        pointer: *anyopaque,
        program: data.activation.Program,
        facts: check.Facts,
    ) source.Error!void {
        const self: *Capture = @ptrCast(@alignCast(pointer));
        try data.admission.spend(self.work, program.constructors.len);
        const result = try self.allocator.alloc(Binding, program.constructors.len);
        for (result, program.constructors) |*out, constructor| {
            const captures = facts.functions[@intCast(constructor.function)].items;
            try data.admission.spend(self.work, captures.len);
            out.* = .{
                .function = constructor.function,
                .schema = constructor.schema,
                .captures = try self.allocator.dupe(u64, captures),
            };
        }
        self.bindings = result;
    }
};

pub fn admit(
    allocator: std.mem.Allocator,
    storage: std.mem.Allocator,
    module: ast.Module,
    work: *u64,
) Error![]const Binding {
    var capture: Capture = .{ .allocator = storage, .work = work };
    try source.admitObservedWithWork(allocator, module, work, .{
        .context = &capture,
        .receive = Capture.receive,
    });
    return capture.bindings;
}

pub fn validate(
    module: ast.Module,
    before: []const Binding,
    after: []const Binding,
    transport: Transport,
    work: ?*u64,
) Error!void {
    if (transport.constructors) |map| {
        if (map.len != before.len) return error.InvalidRelation;
        for (map, 0..) |new, old| {
            try data.admission.spend(work, 1);
            if (new) |index| try matching(before[old], after, index, transport, work);
        }
    }
    for (module.values, 0..) |value, index| {
        try data.admission.spend(work, 1);
        if (transport.values) |map| {
            if (index >= map.len) return error.InvalidRelation;
            if (map[index] == null) continue;
        }
        const old = raw(value) orelse continue;
        if (old >= before.len) return error.InvalidRelation;
        const new = try Transport.id(transport.constructors, old);
        try matching(before[@intCast(old)], after, new, transport, work);
    }
}

fn matching(
    before: Binding,
    after: []const Binding,
    index: u64,
    transport: Transport,
    work: ?*u64,
) Error!void {
    try data.admission.spend(work, 1);
    if (index >= after.len) return error.InvalidRelation;
    const target = after[@intCast(index)];
    if (target.function != try Transport.id(transport.functions, before.function) or
        target.schema != try Transport.id(transport.schemas, before.schema) or
        target.captures.len != before.captures.len) return error.InvalidRelation;
    try data.admission.spend(work, before.captures.len);
    for (before.captures, target.captures) |old, new| {
        if (try Transport.id(transport.variables, old) != new)
            return error.UnsupportedRelation;
    }
}

pub fn raw(value: ast.Value) ?u64 {
    if (value.expression != .primitive) return null;
    const primitive = value.expression.primitive;
    return if (primitive.opcode == .computation) primitive.immediate else null;
}
