const std = @import("std");
const data = @import("horos_data");
const source = @import("../source.zig");
const relation = @import("relation.zig");
const Error = relation.Error;

pub const Rule = union(enum) {
    relocation: relation.Relocation.Maps,
    identity,
    scalar: relation.Scalar,
    inline_call: u64,
    product_layout: []const relation.Layout,
    specialization: []const u8,
};
pub const Step = struct { successor: source.ast.Module, rule: Rule };

pub fn decode(
    a: std.mem.Allocator,
    record: Step,
    remaining: *usize,
) Error!relation.Step {
    const rule: relation.Rule = switch (record.rule) {
        .specialization => |bytes| blk: {
            var reader: data.wire.Reader = .{ .input = bytes };
            const proof = try data.record.readBounded(
                relation.Specialization,
                &reader,
                a,
                remaining,
            );
            try reader.finish();
            break :blk .{ .specialization = proof };
        },
        inline else => |payload, tag| @unionInit(
            relation.Rule,
            @tagName(tag),
            try source.own(@TypeOf(payload), a, payload),
        ),
    };
    return .{ .successor = try source.own(source.ast.Module, a, record.successor), .rule = rule };
}
pub fn encode(a: std.mem.Allocator, step: relation.Step) Error!Step {
    const rule: Rule = switch (step.rule) {
        .specialization => |proof| blk: {
            var measure: data.wire.Writer = .{};
            try data.record.writeAlloc(relation.Specialization, a, proof, &measure);
            const bytes = try a.alloc(u8, measure.position);
            var writer: data.wire.Writer = .{ .output = bytes };
            try data.record.writeAlloc(relation.Specialization, a, proof, &writer);
            break :blk .{ .specialization = bytes };
        },
        inline else => |payload, tag| @unionInit(
            Rule,
            @tagName(tag),
            try source.own(@TypeOf(payload), a, payload),
        ),
    };
    return .{ .successor = try source.own(source.ast.Module, a, step.successor), .rule = rule };
}
