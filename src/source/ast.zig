// Copyright (c) 2026 Boundary contributors. MIT license.
//! Higher-order source syntax. Functions may close over lexical variables;
//! terms compose with bind, independently of any target block or frame layout.
const std = @import("std");
const data = @import("horos_data");
const p = data.program;
pub const Id = p.Id;
pub const Hint = struct { value: Id, kind: data.binding_time.Kind };
pub const Hints = struct {
    module: [32]u8,
    table: []const Hint,

    pub fn bind(module: Module, table: []const Hint) data.record.Error!?Hints {
        if (table.len == 0) return null;
        return .{ .module = try identity(module, null), .table = table };
    }

    pub fn recordedAgainst(self: Hints, module: Module) data.record.Error!bool {
        const actual = try identity(module, null);
        return std.mem.eql(u8, &self.module, &actual);
    }
};

pub fn identity(module: Module, work: ?*u64) data.record.Error![32]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var writer: data.wire.Writer = .{ .hasher = &digest, .remaining = work };
    try writer.put("horos.source-relation/1\x00");
    try data.record.write(Module, module, &writer);
    return digest.finalResult();
}
pub const Value = struct {
    schema: Id,
    expression: union(enum) {
        variable: Id,
        literal: Id,
        primitive: struct {
            opcode: p.Opcode,
            operands: []const Id,
            immediate: Id = 0,
            failures: []const p.InstructionFailure = &.{},
        },
        lambda: Id,
    },
};
pub const Operation = struct {
    effect: Id,
    capability: ?Id = null,
    payload: Id,
    bodies: []const Id = &.{},
    use_site_capabilities: []const Id = &.{},
};
pub const Term = union(enum) {
    value: Id,
    bind: struct { variable: Id, value: Id, next: Id },
    conditional: struct { condition: Id, when_true: Id, when_false: Id },
    call: struct { function: Id, arguments: []const Id },
    apply: struct { computation: Id, arguments: []const Id },
    perform: Operation,
    handle: struct {
        handler: Id,
        body: Id,
        arguments: []const Id = &.{},
        state: []const Id = &.{},
    },
    resume_value: struct { resumption: Id, argument: Id },
    resume_with: struct { resumption: Id, argument: Id, handler: Id, state: []const Id = &.{} },
    resume_computation: struct { resumption: Id, computation: Id },
    protect: struct {
        body: Id,
        cleanup: Id,
        arguments: []const Id = &.{},
        resource: ?Id = null,
        loan_region: ?Id = null,
    },
    with_region: struct { region: Id, body: Id, arguments: []const Id = &.{} },
    dispose: Id,
    fail: Id,
    yield_then: Id,
    match_sum: struct { value: Id, cases: []const struct { variable: Id, body: Id } },
    unpack_product: struct { value: Id, variables: []const Id, body: Id },
};
pub const Function = struct {
    parameters: []const Id,
    result: Id,
    effects: []const Id = &.{},
    regions: []const Id = &.{},
    body: ?Id = null,
};
pub const Module = struct {
    entry: Id,
    failure: Id,
    schemas: []const p.Schema,
    constants: []const p.Literal,
    effects: []const p.Effect,
    handlers: []const p.Handler,
    region_count: Id,
    resources: []const p.Resource = &.{},
    variables: []const Id,
    values: []const Value,
    terms: []const Term,
    functions: []const Function,
};
