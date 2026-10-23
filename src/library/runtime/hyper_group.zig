const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const hyper = @import("hyper.zig");
const cache_key = @import("../../authoring/cache_key.zig");
const catalog_limit = @import("horos_data").component.max_catalog_entries;

pub const Group = opaque {
    pub fn get(self: *const Group, from: usize, to: usize) *const hyper.Pair {
        const data = groupData(self);
        std.debug.assert(from < data.endpoints.len);
        std.debug.assert(to < data.endpoints.len);
        return data.pairs[from * data.endpoints.len + to];
    }
    pub fn index(self: *const Group, name: []const u8) a.Error!usize {
        for (groupData(self).endpoints, 0..) |endpoint, i| {
            if (std.mem.eql(u8, endpoint.name, name)) return i;
        }
        return error.UnknownName;
    }
    pub fn lookup(self: *const Group, from: []const u8, to: []const u8) a.Error!*const hyper.Pair {
        return self.get(try self.index(from), try self.index(to));
    }
};

const GroupData = struct {
    owner: *a.Context,
    endpoints: []const a.Field,
    pairs: []const *const hyper.Pair,
    compositions: std.ArrayList(struct { rotation: [3]usize, maker: *const a.Function }) = .empty,
};

fn groupData(value: *const Group) *GroupData {
    return @ptrCast(@alignCast(@constCast(value)));
}

const GroupKey = struct {
    endpoints: []const a.Field,
    captures: []const *const a.Schema,
};
const GroupKeyOps = cache_key.KeyOps(GroupKey, cache_key.DefaultPolicy);
const GroupCache = struct {
    entries: std.ArrayList(struct { key: GroupKey, value: *const Group }) = .empty,
};

const Layout = struct {
    count: usize,
    nodes: usize,
    bound_length: usize,

    fn init(endpoints: usize, captures: usize) a.Error!Layout {
        if (endpoints == 0) return error.InvalidSchema;
        const count = std.math.mul(usize, endpoints, endpoints) catch return error.Capacity;
        const doubled = std.math.mul(usize, count, 2) catch return error.Capacity;
        const nodes = std.math.add(usize, doubled, endpoints) catch return error.Capacity;
        if (nodes > catalog_limit) return error.Capacity;
        const with_endpoints = std.math.add(usize, nodes, endpoints) catch return error.Capacity;
        const bound = std.math.add(usize, with_endpoints, captures) catch return error.Capacity;
        const references = std.math.mul(usize, nodes, bound) catch return error.Capacity;
        if (references > catalog_limit) return error.Capacity;
        return .{ .count = count, .nodes = nodes, .bound_length = bound };
    }
};

pub fn group(
    c: *a.Context,
    endpoints: []const a.Field,
    captures: []const *const a.Schema,
) a.Error!*const Group {
    const layout = try Layout.init(endpoints.len, captures.len);
    for (endpoints) |endpoint| _ = try a.interop.schemaId(c, endpoint.schema);
    for (captures) |schema| _ = try a.interop.schemaId(c, schema);
    const cache = try a.interop.libraryStorage(c, GroupCache);
    const key: GroupKey = .{ .endpoints = endpoints, .captures = captures };
    for (cache.entries.items) |entry| if (GroupKeyOps.eql(key, entry.key)) return entry.value;
    const names = try a.interop.namedFields(c, endpoints);
    const allocator = a.interop.builder(c).allocator();
    const declarations = try allocator.alloc(*const a.SchemaDeclaration, layout.nodes);
    const nodes = try allocator.alloc(*const a.Schema, layout.nodes);
    for (declarations, nodes) |*declaration, *node| {
        declaration.* = try c.declareSchema(.callable);
        node.* = declaration.*.schema();
    }
    const bound = try allocator.alloc(*const a.Schema, layout.bound_length);
    @memcpy(bound[0..nodes.len], nodes);
    for (endpoints, bound[nodes.len..][0..endpoints.len]) |endpoint, *schema| {
        schema.* = endpoint.schema;
    }
    @memcpy(bound[nodes.len + endpoints.len ..], captures);
    try defineGraph(c, endpoints, declarations, nodes, bound, layout.count);
    const pairs = try savePairs(c, endpoints, nodes, layout.count);
    const value: *const Group = @ptrCast(try a.interop.namedStorage(c, GroupData, .{
        .owner = c,
        .endpoints = names,
        .pairs = pairs,
    }));
    try cache.entries.append(allocator, .{
        .key = try GroupKeyOps.snapshot(allocator, key),
        .value = value,
    });
    return value;
}

fn defineGraph(
    c: *a.Context,
    endpoints: []const a.Field,
    declarations: []const *const a.SchemaDeclaration,
    nodes: []const *const a.Schema,
    bound: []const *const a.Schema,
    count: usize,
) a.Error!void {
    for (endpoints, 0..) |_, from| for (endpoints, 0..) |_, to| {
        const index = from * endpoints.len + to;
        const reverse = to * endpoints.len + from;
        try c.defineCallable(
            declarations[index],
            &.{.{ .name = "peer", .schema = nodes[count + reverse] }},
            nodes[2 * count + to],
            &.{},
            .{ .use = .reusable, .captures = bound },
        );
        try c.defineCallable(declarations[count + index], &.{}, nodes[index], &.{}, .{
            .use = .reusable,
            .captures = bound,
        });
    };
    for (endpoints, 0..) |endpoint, i| {
        try c.defineCallable(declarations[2 * count + i], &.{}, endpoint.schema, &.{}, .{
            .use = .reusable,
            .captures = bound,
        });
    }
}

fn savePairs(
    c: *a.Context,
    endpoints: []const a.Field,
    nodes: []const *const a.Schema,
    count: usize,
) a.Error![]const *const hyper.Pair {
    const pairs = try a.interop.builder(c).allocator().alloc(*const hyper.Pair, count);
    for (endpoints, 0..) |input, from| for (endpoints[from..], from..) |output, to| {
        const index = from * endpoints.len + to;
        const reverse = to * endpoints.len + from;
        const pair = try hyper.savePair(c, input.schema, output.schema, .{
            nodes[index],
            nodes[reverse],
            nodes[count + index],
            nodes[count + reverse],
            nodes[2 * count + to],
            nodes[2 * count + from],
        });
        pairs[index] = pair;
        if (index != reverse) pairs[reverse] = pair.swap();
    };
    return pairs;
}

pub fn compose(
    body: *a.Body,
    interfaces: *const Group,
    rotation: [3]usize,
    left: *const a.Value,
    right: *const a.Value,
) a.Error!*const a.Value {
    const c = try body.context();
    const data = groupData(interfaces);
    if (data.owner != c) return error.ForeignHandle;
    for (rotation) |index| if (index >= data.endpoints.len) return error.InvalidReference;
    const ab = interfaces.get(rotation[0], rotation[1]);
    const bc = interfaces.get(rotation[1], rotation[2]);
    const checked_left = try a.interop.refineValue(body, left, bc.forward(), false);
    const checked_right = try a.interop.refineValue(body, right, ab.forward(), false);
    const maker = try composition(c, interfaces, rotation);
    return body.call(maker, &.{
        .{ .name = "left", .value = checked_left },
        .{ .name = "right", .value = checked_right },
    });
}

fn composition(
    c: *a.Context,
    interfaces: *const Group,
    rotation: [3]usize,
) a.Error!*const a.Function {
    const data = groupData(interfaces);
    for (data.compositions.items) |entry| {
        if (std.mem.eql(usize, &entry.rotation, &rotation)) return entry.maker;
    }
    const rotations = [_][3]usize{
        rotation,
        .{ rotation[2], rotation[0], rotation[1] },
        .{ rotation[1], rotation[2], rotation[0] },
    };
    var makers: [3]*const a.Function = undefined;
    for (rotations, &makers) |item, *maker| {
        maker.* = try c.function("hyper.compose", &.{
            .{ .name = "left", .schema = interfaces.get(item[1], item[2]).forward() },
            .{ .name = "right", .schema = interfaces.get(item[0], item[1]).forward() },
        }, interfaces.get(item[0], item[2]).forward(), &.{});
    }
    for (rotations, makers, 0..) |item, maker, i| {
        try composeBody(c, interfaces, item, maker, makers[(i + 1) % makers.len]);
    }
    try data.compositions.append(a.interop.builder(c).allocator(), .{
        .rotation = rotation,
        .maker = makers[0],
    });
    return makers[0];
}

fn composeBody(
    c: *a.Context,
    interfaces: *const Group,
    rotation: [3]usize,
    maker: *const a.Function,
    rotated: *const a.Function,
) a.Error!void {
    const bc = interfaces.get(rotation[1], rotation[2]);
    const ac = interfaces.get(rotation[0], rotation[2]);
    const body = try c.body(maker);
    const left = try body.parameter("left");
    const right = try body.parameter("right");
    const outer = try c.functionFor("hyper.compose.participant", ac.forward());
    const outer_body = try body.closureBody(outer);
    const peer = try outer_body.parameter("peer");
    const inner = try c.functionFor("hyper.compose.peer", bc.peerBackward());
    const inner_body = try outer_body.closureBody(inner);
    const combined = try inner_body.call(rotated, &.{
        .{ .name = "left", .value = right },
        .{ .name = "right", .value = try hyper.force(inner_body, peer) },
    });
    try c.define(inner, try inner_body.ret(combined));
    const invoked = try hyper.invoke(
        outer_body,
        left,
        try outer_body.lambda(inner, bc.peerBackward()),
    );
    try c.define(outer, try outer_body.ret(invoked));
    try c.define(maker, try body.ret(try body.lambda(outer, ac.forward())));
}
