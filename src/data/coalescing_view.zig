// Copyright (c) 2026 Boundary contributors. MIT license.
//! Deterministic comparison views; their labels are never proof of equivalence.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const graph = @import("coalescing_graph.zig");
const names = @import("coalescing_locals.zig");
const wire = @import("wire.zig");
const record = @import("record.zig");
const roles = @import("reference_roles.zig");
pub const Error = names.Error;
pub const View = struct {
    node: graph.Node,
    /// Canonical block order -> original catalogue ID.
    blocks: []const p.Id,
    /// Original local ID -> canonical name (including unused locals).
    slots: []const p.Id,
    custody: []const p.Id,
};

/// Caller owns all storage through a scratch arena, including partial allocations.
/// fixed contains finalized schema/literal/capture classes and nominal identities.
pub fn function(
    a: std.mem.Allocator,
    program: ir.Program,
    id: p.Id,
    fixed: r.Maps,
    work: *graph.Work,
) Error!View {
    if (id >= program.functions.len) return error.InvalidReference;
    var body: Body = .{
        .sink = .{ .allocator = a, .program = program, .fixed = fixed, .work = work },
        .locals = try names.Names.init(a, program.functions[@intCast(id)], work),
        .blocks = .{ .allocator = a, .work = work, .program = program, .function = id },
    };
    try body.blocks.collect();
    try body.write();
    const bytes = try a.alloc(u8, body.sink.writer.position);
    body.sink.writer = .{ .output = bytes };
    body.sink.edges.clearRetainingCapacity();
    try body.write();
    return .{
        .node = .{ .kind = .function, .label = bytes, .edges = body.sink.edges.items },
        .blocks = body.blocks.order.items,
        .slots = body.locals.slots,
        .custody = body.locals.custody,
    };
}

pub fn descriptor(
    a: std.mem.Allocator,
    program: ir.Program,
    kind: r.Kind,
    id: p.Id,
    fixed: r.Maps,
    work: *graph.Work,
) Error!graph.Node {
    var sink: Sink = .{ .allocator = a, .program = program, .fixed = fixed, .work = work };
    try sink.descriptor(kind, id);
    const bytes = try a.alloc(u8, sink.writer.position);
    sink.writer = .{ .output = bytes };
    sink.edges.clearRetainingCapacity();
    try sink.descriptor(kind, id);
    return .{ .kind = kind, .label = bytes, .edges = sink.edges.items };
}

const Sink = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    fixed: r.Maps,
    work: *graph.Work,
    writer: wire.Writer = .{},
    edges: std.ArrayList(graph.Edge) = .empty,

    fn raw(self: *Sink, value: anytype) Error!void {
        const before = self.writer.position;
        try record.write(@TypeOf(value), value, &self.writer);
        try self.work.charge(self.writer.position - before);
    }
    fn natural(self: *Sink, value: p.Id) Error!void {
        try self.raw(value);
    }
    fn global(self: *Sink, kind: r.Kind, id: p.Id) Error!void {
        try self.raw(kind);
        const map = self.fixed[@backingInt(kind)];
        if (id >= map.len) return error.InvalidReference;
        const offset: usize = switch (kind) {
            .function => 0,
            .constructor => self.program.functions.len,
            .handler => std.math.add(
                usize,
                self.program.functions.len,
                self.program.constructors.len,
            ) catch return error.InvalidLength,
            else => {
                try self.natural(map[@intCast(id)]);
                return;
            },
        };
        const target = std.math.add(usize, offset, @intCast(id)) catch
            return error.InvalidLength;
        try self.natural(self.edges.items.len);
        try self.edges.append(self.allocator, .{ .role = self.edges.items.len, .target = target });
    }
    fn globals(self: *Sink, kind: r.Kind, values: []const p.Id) Error!void {
        try self.natural(values.len);
        for (values) |value| try self.global(kind, value);
    }
    fn descriptor(self: *Sink, kind: r.Kind, id: p.Id) Error!void {
        switch (kind) {
            .constructor => {
                if (id >= self.program.constructors.len) return error.InvalidReference;
                const value = self.program.constructors[@intCast(id)];
                try self.global(.function, value.function);
                try self.global(.capture, value.capture);
                try self.global(.schema, value.schema);
            },
            .handler => {
                if (id >= self.program.handlers.len) return error.InvalidReference;
                const value = self.program.handlers[@intCast(id)];
                try self.raw(value.mode);
                try self.global(.schema, value.input);
                try self.global(.schema, value.answer);
                try self.global(.function, value.return_function);
                try self.natural(value.clauses.len);
                for (value.clauses) |clause| {
                    try self.global(.effect, clause.effect);
                    try self.global(.function, clause.function);
                    try self.global(.schema, clause.resumption);
                    try self.raw(clause.strategy);
                }
                try self.globals(.schema, value.state);
                try self.globals(.effect, value.effects);
            },
            else => return error.InvalidProgram,
        }
    }
};

const Body = struct {
    sink: Sink,
    locals: names.Names,
    blocks: names.Blocks,

    fn write(self: *Body) Error!void {
        const code = self.locals.function;
        try self.slots(code.inputs);
        try self.sink.global(.schema, code.result);
        try self.sink.globals(.effect, code.effects);
        try self.sink.globals(.region, code.regions);
        try self.sink.natural(self.blocks.order.items.len);
        for (self.blocks.order.items) |old| {
            const block = self.blocks.program.blocks[@intCast(old)];
            try self.sink.natural(try self.locals.scope(block.custody));
            try self.sink.natural(block.instructions.len);
            for (block.instructions) |operation| try self.instruction(operation);
            try self.terminator(block.terminator);
        }
        try self.locals.complete(self.sink.fixed[@backingInt(r.Kind.schema)]);
        try self.sink.natural(self.locals.slot_order.items.len);
        for (self.locals.slot_order.items) |old|
            try self.sink.global(.schema, code.layout.slots[@intCast(old)]);
        try self.sink.natural(self.locals.scope_order.items.len);
        for (self.locals.scope_order.items) |old| {
            const parent = code.custody[@intCast(old)].parent;
            try self.sink.raw(parent != null);
            if (parent) |scope| try self.sink.natural(try self.locals.scope(scope));
        }
    }
    fn slot(self: *Body, old: p.Id) Error!void {
        try self.sink.natural(try self.locals.slot(old));
    }
    fn slots(self: *Body, values: []const p.Id) Error!void {
        try self.sink.natural(values.len);
        for (values) |value| try self.slot(value);
    }
    fn instruction(self: *Body, value: ir.Instruction) Error!void {
        try self.slot(value.destination);
        try self.sink.raw(value.opcode);
        try self.slots(value.operands);
        switch (value.opcode) {
            .constant => try self.sink.global(.constant, value.immediate),
            .computation => try self.sink.global(.constructor, value.immediate),
            else => try self.sink.natural(value.immediate),
        }
        try self.sink.natural(value.failures.len);
        for (value.failures) |failure| {
            try self.sink.raw(failure.kind);
            try self.sink.global(.constant, failure.value);
        }
    }
    pub const VisitError = names.Error;
    pub fn reference(
        self: *Body,
        comptime role: roles.Role,
        comptime cardinality: roles.Cardinality,
        value: anytype,
    ) Error!void {
        if (comptime cardinality == .optional) {
            try self.sink.raw(value != null);
            if (value) |item| try self.reference(role, .one, item);
        } else if (comptime cardinality == .list) {
            try self.sink.natural(value.len);
            for (value) |item| try self.reference(role, .one, item);
        } else switch (role) {
            .slot_read, .slot_write => try self.slot(value),
            .function => try self.sink.global(.function, value),
            .effect => try self.sink.global(.effect, value),
            .handler => try self.sink.global(.handler, value),
            .region => try self.sink.global(.region, value),
            .block => try self.sink.natural(
                self.blocks.names.get(value) orelse return error.InvalidReference,
            ),
            .edge => try roles.visitEdge(value, self),
            .assignment => try roles.visitAssignment(value, self),
            .source => {
                try self.sink.raw(std.meta.activeTag(value));
                try roles.visitSource(value, self);
            },
            .nonreference => {},
        }
    }
    fn terminator(self: *Body, value: ir.Terminator) Error!void {
        try self.sink.raw(std.meta.activeTag(value));
        try roles.visitTerminator(value, self);
    }
};
