const std = @import("std");
const a = @import("../../authoring/runtime.zig");
const p = @import("horos_data").program;
const cache_key = @import("../../authoring/cache_key.zig");

pub const Pair = opaque {
    pub fn input(self: *const Pair) *const a.Schema {
        return pairData(self).input;
    }
    pub fn output(self: *const Pair) *const a.Schema {
        return pairData(self).output;
    }
    pub fn forward(self: *const Pair) *const a.Schema {
        return pairData(self).forward;
    }
    pub fn backward(self: *const Pair) *const a.Schema {
        return pairData(self).backward;
    }
    pub fn peerForward(self: *const Pair) *const a.Schema {
        return pairData(self).peer_forward;
    }
    pub fn peerBackward(self: *const Pair) *const a.Schema {
        return pairData(self).peer_backward;
    }
    pub fn answerForward(self: *const Pair) *const a.Schema {
        return pairData(self).answer_forward;
    }
    pub fn answerBackward(self: *const Pair) *const a.Schema {
        return pairData(self).answer_backward;
    }
    pub fn swap(self: *const Pair) *const Pair {
        return @ptrCast(pairData(self).reciprocal);
    }
};

const PairData = struct {
    input: *const a.Schema,
    output: *const a.Schema,
    forward: *const a.Schema,
    backward: *const a.Schema,
    peer_forward: *const a.Schema,
    peer_backward: *const a.Schema,
    answer_forward: *const a.Schema,
    answer_backward: *const a.Schema,
    reciprocal: *PairData,
};

fn pairData(value: *const Pair) *const PairData {
    return @ptrCast(@alignCast(value));
}

const PairKey = struct {
    input: *const a.Schema,
    output: *const a.Schema,
    captures: []const *const a.Schema,
};
const PairKeyOps = cache_key.KeyOps(PairKey, cache_key.DefaultPolicy);
const PairCache = struct {
    entries: std.ArrayList(struct { key: PairKey, value: *const Pair }) = .empty,
};

pub fn savePair(
    c: *a.Context,
    input: *const a.Schema,
    output: *const a.Schema,
    nodes: [6]*const a.Schema,
) a.Error!*const Pair {
    const forward = try a.interop.namedStorage(c, PairData, .{
        .input = input,
        .output = output,
        .forward = nodes[0],
        .backward = nodes[1],
        .peer_forward = nodes[2],
        .peer_backward = nodes[3],
        .answer_forward = nodes[4],
        .answer_backward = nodes[5],
        .reciprocal = undefined,
    });
    const backward = try a.interop.namedStorage(c, PairData, .{
        .input = output,
        .output = input,
        .forward = nodes[1],
        .backward = nodes[0],
        .peer_forward = nodes[3],
        .peer_backward = nodes[2],
        .answer_forward = nodes[5],
        .answer_backward = nodes[4],
        .reciprocal = forward,
    });
    forward.reciprocal = backward;
    return @ptrCast(forward);
}

pub fn pair(
    c: *a.Context,
    input: *const a.Schema,
    output: *const a.Schema,
    captures: []const *const a.Schema,
) a.Error!*const Pair {
    const count = std.math.add(usize, captures.len, 8) catch return error.Capacity;
    const references = std.math.mul(usize, 6, count) catch return error.Capacity;
    if (references > @import("horos_data").component.max_catalog_entries) return error.Capacity;
    _ = try a.interop.schemaId(c, input);
    _ = try a.interop.schemaId(c, output);
    const allocator = a.interop.builder(c).allocator();
    for (captures) |schema| _ = try a.interop.schemaId(c, schema);
    const cache = try a.interop.libraryStorage(c, PairCache);
    const key: PairKey = .{ .input = input, .output = output, .captures = captures };
    for (cache.entries.items) |entry| if (PairKeyOps.eql(key, entry.key)) return entry.value;
    var declarations: [6]*const a.SchemaDeclaration = undefined;
    var nodes: [6]*const a.Schema = undefined;
    for (&declarations, &nodes) |*declaration, *node| {
        declaration.* = try c.declareSchema(.callable);
        node.* = declaration.*.schema();
    }
    const bound = try allocator.alloc(*const a.Schema, count);
    @memcpy(bound[0..captures.len], captures);
    @memcpy(bound[captures.len..][0..6], &nodes);
    bound[count - 2] = input;
    bound[count - 1] = output;
    const results = [_]*const a.Schema{ nodes[4], nodes[5], nodes[0], nodes[1], output, input };
    for (declarations, results, 0..) |declaration, result, index| {
        const parameters: []const a.Field = switch (index) {
            0 => &.{.{ .name = "peer", .schema = nodes[3] }},
            1 => &.{.{ .name = "peer", .schema = nodes[2] }},
            else => &.{},
        };
        try c.defineCallable(declaration, parameters, result, &.{}, .{
            .use = .reusable,
            .captures = bound,
        });
    }
    const value = try savePair(c, input, output, nodes);
    try cache.entries.append(allocator, .{
        .key = try PairKeyOps.snapshot(allocator, key),
        .value = value,
    });
    return value;
}

pub fn pureDelay(c: *a.Context, schema: *const a.Schema) a.Error!void {
    const id = try a.interop.schemaId(c, schema);
    const shape = a.interop.builder(c).schemas.items[@intCast(id)];
    if (shape != .internal or shape.internal != .computation) return error.InvalidCategory;
    const callable = shape.internal.computation;
    if (callable.parameters.len != 0 or callable.effects.len != 0 or
        callable.regions.len != 0) return error.SchemaMismatch;
}

pub fn force(body: *a.Body, value: *const a.Value) a.Error!*const a.Value {
    const c = try body.context();
    try pureDelay(c, try body.schemaOf(value));
    return body.apply(value, &.{});
}

pub fn invoke(
    body: *a.Body,
    participant: *const a.Value,
    peer: *const a.Value,
) a.Error!*const a.Value {
    const c = try body.context();
    const interface = try body.schemaOf(participant);
    const answer = (try interface.checkedResult()) orelse return error.InvalidSchema;
    try pureDelay(c, answer);
    const function = try c.functionFor("hyper.invoke", answer);
    const nested = try body.closureBody(function);
    const result = try nested.apply(participant, &.{.{ .name = "peer", .value = peer }});
    try c.define(function, try nested.ret(try force(nested, result)));
    return body.lambda(function, answer);
}
