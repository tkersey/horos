// Copyright (c) 2026 Boundary contributors. MIT license.
//! Proposed private interface, not evidence of eligibility or acceptance.
const ir = @import("activation.zig");
const p = @import("program.zig");

pub const Target = union(enum) {
    capture: usize,
    parameters: struct { worker: p.Id, count: usize },

    pub fn constructor(self: Target) ?usize {
        return switch (self) {
            .capture => |id| id,
            .parameters => null,
        };
    }

    /// Call only after original admission and target range checks.
    pub fn worker(self: Target, program: ir.Program) p.Id {
        return switch (self) {
            .capture => |id| program.constructors[id].function,
            .parameters => |target| target.worker,
        };
    }

    pub fn dimension(self: Target, program: ir.Program) usize {
        return switch (self) {
            .capture => |id| program.scopes.captures[
                @intCast(program.constructors[id].capture)
            ].fields.len,
            .parameters => |target| target.count,
        };
    }
};
