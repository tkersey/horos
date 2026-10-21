const std = @import("std");
const ast = @import("ast.zig");
const relation = @import("relation.zig");
const relocation = @import("relation_relocate.zig");
const Error = relation.Error;
const ProofKind = enum { term, value };
const ProofReference = struct { kind: ProofKind, id: usize };
const Coverage = struct {
    ctx: *relation.Context,
    successor: ast.Module,
    proof: relation.Specialization,
    covered: [std.meta.tags(relocation.Kind).len][]bool,
    terms: []bool,
    values: []bool,
    source_pending: std.ArrayList(relocation.Reference) = .empty,
    proof_pending: std.ArrayList(ProofReference) = .empty,

    fn source(self: *Coverage, reference: relocation.Reference) Error!void {
        try self.ctx.spend(1);
        if (reference.kind == .region) {
            try relation.Context.require(reference.id < self.successor.region_count);
            return;
        }
        const covered = self.covered[@backingInt(reference.kind)];
        try relation.Context.require(reference.id < covered.len);
        if (covered[@intCast(reference.id)]) return;
        covered[@intCast(reference.id)] = true;
        try self.source_pending.append(self.ctx.a, reference);
    }

    fn derivation(self: *Coverage, kind: ProofKind, id: usize) Error!void {
        try self.ctx.spend(1);
        const covered = if (kind == .term) self.terms else self.values;
        try relation.Context.require(id < covered.len);
        if (covered[id]) return;
        covered[id] = true;
        try self.proof_pending.append(self.ctx.a, .{ .kind = kind, .id = id });
    }

    fn proofs(self: *Coverage) Error!void {
        for (self.proof.functions) |function| {
            try self.source(.{ .kind = .function, .id = function.after });
            try self.derivation(.term, function.body orelse return error.InvalidRelation);
        }
        while (self.proof_pending.pop()) |reference| switch (reference.kind) {
            .term => {
                const proof = self.proof.terms[reference.id];
                try self.source(.{ .kind = .term, .id = proof.after });
                for (proof.children) |child| try self.derivation(.term, child);
                for (proof.values) |value| try self.derivation(.value, value);
            },
            .value => {
                const proof = self.proof.values[reference.id];
                try self.source(.{ .kind = .value, .id = proof.after });
                for (proof.children) |child| try self.derivation(.value, child);
            },
        };
    }

    fn sources(self: *Coverage) Error!void {
        var references: std.ArrayList(relocation.Reference) = .empty;
        defer references.deinit(self.ctx.a);
        while (self.source_pending.pop()) |reference| {
            references.clearRetainingCapacity();
            try relocation.visitReferencesWithWork(
                self.ctx.a,
                self.successor,
                self.ctx.successor_constructors,
                reference.kind,
                reference.id,
                &references,
                self.ctx.left,
            );
            for (references.items) |child| try self.source(child);
        }
    }

    fn complete(self: *Coverage) Error!void {
        for (self.terms) |checked| try relation.Context.require(checked);
        for (self.values) |checked| try relation.Context.require(checked);
        for (self.covered) |catalog| {
            try self.ctx.spend(catalog.len);
            for (catalog) |covered| try relation.Context.require(covered);
        }
    }
};

fn flags(ctx: *relation.Context, length: usize, unchanged: usize) Error![]bool {
    try relation.Context.require(unchanged <= length);
    try ctx.spend(length);
    const result = try ctx.a.alloc(bool, length);
    @memset(result[0..unchanged], true);
    @memset(result[unchanged..], false);
    return result;
}

pub fn coverage(
    ctx: *relation.Context,
    successor: ast.Module,
    proof: relation.Specialization,
) Error!void {
    var state: Coverage = .{
        .ctx = ctx,
        .successor = successor,
        .proof = proof,
        .covered = undefined,
        .terms = try flags(ctx, proof.terms.len, 0),
        .values = try flags(ctx, proof.values.len, 0),
    };
    inline for (comptime std.meta.tags(relocation.Kind)) |kind| {
        const name = comptime @tagName(kind) ++ "s";
        state.covered[@backingInt(kind)] = if (comptime kind == .region) &.{} else try flags(
            ctx,
            @field(successor, name).len,
            @field(ctx.before, name).len,
        );
    }
    try state.proofs();
    try state.sources();
    try state.complete();
}
