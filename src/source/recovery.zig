// Copyright (c) 2026 Boundary contributors. MIT license.
//! Parameter recovery checker. The existing frontend owns source lowering;
//! actual pre/post optimization records certify relocation and quotienting.
//! Lexical diagnostic bindings never acquire parameter-recovery authority.
const std = @import("std");
const source = @import("../source.zig");
const data = @import("horos_data");
const p = data.program;
const r = data.relocation;
const Error = source.Error;
fn require(ok: bool) Error!void {
    if (!ok) return error.InvalidCorrespondence;
}

pub fn validate(a: std.mem.Allocator, module: source.ast.Module, compiled: *const source.Compiled) Error!void {
    const evidence = compiled.recovery_evidence orelse return error.InvalidCorrespondence;
    const before = evidence.input;
    const map = evidence.correspondence;
    try data.coalescing.validateCorrespondence(a, before, compiled.program, map);
    try require(module.functions.len == before.functions.len);
    try require(module.entry == before.roots.entry and module.failure == before.roots.failure);
    try require(data.record.equal([]const p.Schema, module.schemas, before.schemas));
    var cursor: usize = 0;
    for (module.functions, before.functions, 0..) |original, lowered, index| {
        const target = map.maps[@backingInt(r.Kind.function)][index];
        if (target == r.missing) continue;
        const final = compiled.program.functions[@intCast(target)];
        try require(original.parameters.len == lowered.inputs.len and original.parameters.len == final.inputs.len);
        try require(original.result == lowered.result);
        try require(std.mem.eql(p.Id, original.effects, lowered.effects));
        try require(std.mem.eql(p.Id, original.regions, lowered.regions));
        for (original.parameters, lowered.inputs, final.inputs) |variable, input, output| {
            try require(variable < module.variables.len and input < lowered.layout.slots.len);
            const schema = module.variables[@intCast(variable)];
            try require(schema == lowered.layout.slots[@intCast(input)]);
            try require(map.locals[index].slots[@intCast(input)] == output);
            try require(cursor < compiled.parameters.len);
            const expected: source.RecoveryBinding = .{
                .source_function = index,
                .variable = variable,
                .source_schema = schema,
                .function = target,
                .slot = output,
                .schema = final.layout.slots[@intCast(output)],
            };
            try require(data.record.equal(source.RecoveryBinding, expected, compiled.parameters[cursor]));
            cursor += 1;
        }
    }
    try require(cursor == compiled.parameters.len);
}
