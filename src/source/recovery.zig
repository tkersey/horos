// Copyright (c) 2026 Boundary contributors. MIT license.
//! Source-bound parameter recovery. Reconstruct the trusted frontend's actual
//! input and formal-parameter origins, then independently check the submitted
//! structural correspondence. No submitted lowering input acquires authority.
const std = @import("std");
const source = @import("../source.zig");
const data = @import("horos_data");
const lowering = @import("activation_lower.zig");
const Error = source.Error;

/// Returned bindings belong to `a`. Their source identity comes from lowering
/// `module`; their final locations come only from the checked correspondence.
pub fn parameters(
    a: std.mem.Allocator,
    module: source.ast.Module,
    program: data.activation.Program,
    evidence: lowering.RecoveryEvidence,
) Error![]const source.RecoveryBinding {
    var original = try lowering.lowerRecoveryInput(a, module);
    defer original.deinit();
    try data.coalescing.validateCorrespondence(
        a,
        original.program,
        program,
        evidence.correspondence,
    );
    var result: std.ArrayList(source.RecoveryBinding) = .empty;
    errdefer result.deinit(a);
    for (original.parameters) |binding|
        if (try binding.relocated(evidence.correspondence)) |final|
            try result.append(a, final);
    return result.toOwnedSlice(a);
}

pub fn validate(
    a: std.mem.Allocator,
    module: source.ast.Module,
    compiled: *const source.Compiled,
) Error!void {
    const evidence = compiled.recovery_evidence orelse return error.InvalidCorrespondence;
    const expected = try parameters(a, module, compiled.program, evidence);
    defer a.free(expected);
    if (!data.record.equal(
        []const source.RecoveryBinding,
        expected,
        compiled.parameters,
    )) return error.InvalidCorrespondence;
}
