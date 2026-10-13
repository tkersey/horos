// Copyright (c) 2026 Boundary contributors. MIT license.
//! Pure type, scope, and custody admission of portable machine positions.
const std = @import("std");
const p = @import("program.zig");
const g = @import("graph.zig");
const a = @import("admission.zig");
const scalar = @import("scalar.zig");
const image = @import("program_image.zig");
const contracts = @import("contracts.zig");
const traits = @import("traits.zig");
const borrows = @import("borrow_flow.zig");
const state_effects = @import("state_effects.zig");
const provenance = @import("control_provenance.zig");
pub const Error = image.Error || @import("activation_ownership.zig").Error || error{ InvalidState, InvalidScope };

pub fn node(state: anytype, reference: g.NodeRef) Error!g.Node {
    if (reference.id >= state.nodes.len) return error.InvalidReference;
    return state.nodes[@intCast(reference.id)];
}
pub fn next(term: @import("activation.zig").Terminator) ?@import("activation.zig").Edge {
    return switch (term) {
        .call => |v| v.next,
        .perform => |v| v.next,
        .apply => |v| v.next,
        .handle => |v| v.next,
        .resume_value => |v| v.next,
        .resume_with => |v| v.next,
        .resume_computation => |v| v.next,
        .dispose => |v| v.next,
        .protect => |v| v.next,
        .with_region => |v| v.next,
        else => null,
    };
}
fn isFrame(record: g.Node) bool {
    return record == .control or record == .continuation or record == .attachment or record == .region_scope or record == .injection or record == .protection or record == .cleanup_return or record == .disposal_return or record == .unwind;
}
fn frameParent(record: g.Node) ?g.NodeRef {
    return switch (record) {
        .control => |v| v.parent,
        .continuation => |v| v.parent,
        .attachment => |v| v.return_to,
        .region_scope => |v| v.return_to,
        .injection => |v| v.continuation,
        .protection => |v| v.return_to,
        .cleanup_return => |v| v.parent,
        .disposal_return => |v| v.parent,
        .unwind => |v| v.cursor,
        else => null,
    };
}
fn treeParent(record: g.Node) ?g.NodeRef {
    if (record == .region) return record.region.outer;
    // Cutting custody at a delimiter preserves its borrowed lexical evidence.
    if (record == .attachment and record.attachment.phase == .suspended) return record.attachment.outer;
    return frameParent(record);
}

const stable_ir = @import("activation.zig");
const ps = @import("process_state.zig");
const StateView = struct {
    program_identity: [32]u8,
    status: ps.Status,
    roots: g.Roots,
    nodes: []const g.Node,
    blobs: []const g.Blob,
};

pub fn validateStable(allocator: std.mem.Allocator, program: stable_ir.Program, state: ps.State) Error!void {
    var flow = try @import("activation_ownership.zig").analyze(allocator, program);
    defer flow.deinit();
    if (!std.mem.eql(u8, &state.program_identity, &try @import("program_image.zig").identity(allocator, program))) return error.InvalidState;
    var view = flow.view();
    return validateStableRecords(allocator, program, state, &view, null);
}

/// Only the opaque immutable byte-admitted owner can supply reusable facts.
pub fn validateAdmitted(allocator: std.mem.Allocator, admitted: *const @import("program_image.zig").Admitted, state: ps.State) Error!void {
    if (!std.mem.eql(u8, &state.program_identity, &admitted.identity())) return error.InvalidState;
    var analysis = try admitted.analysis(allocator);
    defer analysis.deinit();
    return validateStableRecords(allocator, admitted.program(), state, &analysis.facts, admitted);
}

fn validateStableRecords(allocator: std.mem.Allocator, program: stable_ir.Program, state: ps.State, view: *@import("activation_flow.zig").View, admitted: ?*const @import("program_image.zig").Admitted) Error!void {
    try @import("state_image.zig").checkGraph(allocator, state);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const records = try scratch.allocator().alloc(g.Node, state.nodes.len);
    const frames = try scratch.allocator().alloc(?ps.Activation, state.nodes.len);
    for (records, frames, state.nodes) |*record, *frame, source| {
        record.* = source.record;
        frame.* = source.activation;
    }
    return validateInternal(allocator, program, .{
        .program_identity = state.program_identity,
        .status = state.status,
        .roots = state.roots,
        .nodes = records,
        .blobs = state.blobs,
    }, frames, view, admitted);
}

fn validateInternal(allocator: std.mem.Allocator, program: stable_ir.Program, state: StateView, activations: []const ?ps.Activation, flow: ?*@import("activation_flow.zig").View, admitted: ?*const @import("program_image.zig").Admitted) Error!void {
    const Context = ContextFor();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    var context: Context = .{
        .allocator = temporary,
        .program = program,
        .control = try provenance.derive(temporary, program, &.{}, false),
        .state = state,
        .activations = activations,
        .flow = flow,
        .facts = if (admitted) |owner| owner.schemaFacts() else try a.schemas(temporary, program.schemas),
        .uses = if (admitted) |owner| owner.traits() else try traits.derive(temporary, program.schemas),
        .custody = try temporary.alloc(usize, state.nodes.len),
        .owned = try temporary.alloc(usize, state.nodes.len),
        .environments = try temporary.alloc(usize, state.nodes.len),
        .region_owners = try temporary.alloc(usize, state.nodes.len),
        .loan_resources = try temporary.alloc(?g.NodeRef, state.nodes.len),
        .captured_delimiters = try temporary.alloc(?p.Id, state.nodes.len),
        .frame_children = try temporary.alloc(?g.NodeRef, state.nodes.len),
        .normal_return = try temporary.alloc(bool, state.nodes.len),
        .enter = try temporary.alloc(usize, state.nodes.len),
        .leave = try temporary.alloc(usize, state.nodes.len),
    };
    @memset(context.custody, 0);
    @memset(context.owned, 0);
    @memset(context.environments, 0);
    @memset(context.region_owners, 0);
    @memset(context.loan_resources, null);
    @memset(context.captured_delimiters, null);
    @memset(context.frame_children, null);
    if (state.roots.detached.len != 0) return error.InvalidState;
    switch (state.status) {
        .completed, .failed, .cancelled => {
            if (state.roots.current != null or state.roots.pending != null or state.roots.evidence != null or state.roots.exit == null) return error.InvalidState;
        },
        .active, .yielded => {
            if (state.roots.current == null or state.roots.pending != null) return error.InvalidState;
            const current = try node(state, state.roots.current.?);
            if (current != .control or !std.meta.eql(current.control.evidence, state.roots.evidence)) return error.InvalidState;
        },
        .parked => {
            if (state.roots.current != null or state.roots.pending == null) return error.InvalidState;
            const pending = try node(state, state.roots.pending.?);
            if (pending != .pending) return error.InvalidState;
            const saved = try node(state, pending.pending.continuation);
            if (saved != .continuation or !std.meta.eql(saved.continuation.evidence, state.roots.evidence)) return error.InvalidState;
        },
        .unwinding => {
            if (state.roots.current == null or state.roots.pending != null or state.roots.evidence != null or state.roots.exit == null) return error.InvalidState;
            if (try node(state, state.roots.current.?) != .unwind) return error.InvalidState;
        },
    }
    try context.custodian(state.roots.current, null);
    // Count custody before following captures, so shared forged control rejects in O(N).
    for (state.nodes, 0..) |record, id| {
        try context.custodian(frameParent(record), .{ .id = id });
        switch (record) {
            .attachment => |attachment| {
                // Every semantic traversal may follow this link, regardless of node order.
                const activation = try node(state, attachment.handler);
                if (activation != .handler or activation.handler.definition >= program.handlers.len)
                    return error.InvalidState;
            },
            .one_shot, .multi_template => |v| {
                try context.custodian(v.capture, .{ .id = id });
                if (try node(state, v.delimiter) != .attachment) return error.InvalidState;
                const captured = &context.captured_delimiters[@intCast(v.delimiter.id)];
                if (captured.* != null) return error.InvalidOwnership;
                captured.* = v.schema;
            },
            .pending => |v| try context.custodian(v.continuation, .{ .id = id }),
            .computation => |v| {
                if (v.environment.id >= state.nodes.len) return error.InvalidReference;
                context.environments[@intCast(v.environment.id)] += 1;
            },
            .region_scope => |scope| {
                if (try node(state, scope.region) != .region) return error.InvalidState;
                context.region_owners[@intCast(scope.region.id)] += 1;
            },
            .protection => |scope| {
                try context.ownObligation(scope.obligation);
                if (scope.loan) |loan| {
                    if (try node(state, loan) != .region) return error.InvalidState;
                    context.region_owners[@intCast(loan.id)] += 1;
                    const obligation = (try node(state, scope.obligation.node)).obligation;
                    const resource = obligation.resource orelse return error.InvalidState;
                    if (resource.body != .owned) return error.InvalidOwnership;
                    context.loan_resources[@intCast(loan.id)] = resource.body.owned.node;
                }
            },
            .cleanup_return => |cleanup| try context.ownObligation(cleanup.obligation),
            else => {},
        }
    }
    for (state.nodes, context.custody) |record, count| if (isFrame(record) and count != 1) return error.InvalidOwnership;
    for (state.nodes, context.region_owners) |record, count| if (record == .region and count != 1) return error.InvalidOwnership;
    try context.frameForest();
    const returning = switch (state.status) {
        .active, .yielded => state.roots.current,
        .parked => (try node(state, state.roots.pending.?)).pending.continuation,
        .unwinding, .completed, .failed, .cancelled => null,
    };
    if (returning) |ref| if (!context.normal_return[@intCast(ref.id)])
        return error.InvalidState;
    try context.exits();
    context.effect_check = try Context.EffectCheck.init(
        temporary,
        program,
        state,
        context.captured_delimiters,
        context.frame_children,
        context.enter,
        context.leave,
        if (admitted) |owner| owner.effectFacts() else null,
    );
    context.effect_check.?.activations = activations;
    context.effect_check.?.control = context.control;
    for (state.blobs) |blob| try a.value(temporary, program.schemas, context.facts, .{ .schema = blob.schema, .bytes = blob.bytes });
    var pending_count: usize = 0;
    for (state.nodes, 0..) |record, id| {
        try context.checkRecord(record, id);
        if (record == .pending) pending_count += 1;
    }
    // Frame custody prevents a dormant capture from sharing the live control
    // spine. Every suspended delimiter must belong to one such capture.
    for (state.nodes, context.captured_delimiters) |record, captured| {
        if (record == .attachment and record.attachment.phase == .suspended and captured == null)
            return error.InvalidState;
    }
    if (pending_count != @as(usize, if (state.roots.pending != null) 1 else 0)) return error.InvalidState;
    try context.valueScopes();
    for (state.nodes, context.owned, context.environments) |record, owned, environment_owners| switch (record) {
        .one_shot, .package, .resource => if (owned != 1) return error.InvalidOwnership,
        .obligation => if (owned != 1) return error.InvalidOwnership,
        .computation => |closure| {
            const constructor = program.constructors[@intCast(closure.constructor)];
            if (owned != @as(usize, if (context.uses.copy[@intCast(constructor.schema)]) 0 else 1)) return error.InvalidOwnership;
        },
        .aggregate => |aggregate| if (owned != @as(usize, if (context.uses.copy[@intCast(aggregate.schema)]) 0 else 1)) return error.InvalidOwnership,
        .environment => |environment| {
            for (environment.values) |value| if (!context.uses.copy[@intCast(value.schema)] and environment_owners != 1) return error.InvalidOwnership;
        },
        else => if (owned != 0) return error.InvalidOwnership,
    };
    try context.control.validateState(temporary, state.nodes, activations);
    try context.effect_check.?.futureCaptures(&context, Context.visitFutureCapture);
}

fn ContextFor() type {
    const Program = stable_ir.Program;
    const Block = std.meta.Elem(@FieldType(Program, "blocks"));
    return struct {
        const Context = @This();
        const EffectCheck = state_effects.CheckFor(Program, StateView);
        const BorrowFlow = borrows.StableFlow;
        allocator: std.mem.Allocator,
        program: Program,
        control: *const provenance.Analysis,
        state: StateView,
        activations: []const ?ps.Activation,
        flow: ?*@import("activation_flow.zig").View,
        facts: a.SchemaFacts,
        uses: traits.Facts,
        custody: []usize,
        owned: []usize,
        environments: []usize,
        region_owners: []usize,
        loan_resources: []?g.NodeRef,
        captured_delimiters: []?p.Id,
        frame_children: []?g.NodeRef,
        normal_return: []bool,
        effect_check: ?EffectCheck = null,
        enter: []usize,
        leave: []usize,

        fn ownObligation(self: *Context, owned: g.OwnedRef) Error!void {
            if (try node(self.state, owned.node) != .obligation) return error.InvalidState;
            self.owned[@intCast(owned.node.id)] += 1;
            if (self.owned[@intCast(owned.node.id)] > 1) return error.InvalidOwnership;
        }

        fn exits(self: Context) Error!void {
            const visited = try self.allocator.alloc(bool, self.state.nodes.len);
            @memset(visited, false);
            var cursor = self.state.roots.exit;
            while (cursor) |ref| {
                const record = try node(self.state, ref);
                if (record != .exit or visited[@intCast(ref.id)]) return error.InvalidState;
                visited[@intCast(ref.id)] = true;
                cursor = record.exit.outer;
            }
            var running: usize = 0;
            for (self.state.nodes, 0..) |record, id| switch (record) {
                .exit => if (!visited[id]) return error.InvalidState,
                .cleanup_return => |cleanup| {
                    if (cleanup.exit.id >= visited.len or !visited[@intCast(cleanup.exit.id)]) return error.InvalidState;
                    running += 1;
                },
                else => {},
            };
            if (self.state.roots.exit != null and self.state.status != .unwinding and @backingInt(self.state.status) < 4 and running == 0) return error.InvalidState;
        }

        fn custodian(self: *Context, reference: ?g.NodeRef, child: ?g.NodeRef) Error!void {
            if (reference) |ref| {
                if (!isFrame(try node(self.state, ref))) return error.InvalidState;
                self.custody[@intCast(ref.id)] += 1;
                if (self.custody[@intCast(ref.id)] > 1) return error.InvalidOwnership;
                self.frame_children[@intCast(ref.id)] = child;
            }
        }

        /// Euler intervals make scope checks constant-time, even on deep stacks.
        fn frameForest(self: *Context) Error!void {
            const children = try self.allocator.alloc(std.ArrayList(usize), self.state.nodes.len);
            for (children) |*list| list.* = .empty;
            for (self.state.nodes, 0..) |record, id| if (treeParent(record)) |parent| {
                _ = try node(self.state, parent);
                try children[@intCast(parent.id)].append(self.allocator, id);
            };
            const Task = struct { id: usize, leaving: bool };
            var pending: std.ArrayList(Task) = .empty;
            @memset(self.enter, std.math.maxInt(usize));
            @memset(self.leave, std.math.maxInt(usize));
            @memset(self.normal_return, false);
            for (self.state.nodes, 0..) |record, id| if ((isFrame(record) or record == .region) and treeParent(record) == null)
                try pending.append(self.allocator, .{ .id = id, .leaving = false });
            var clock: usize = 0;
            while (pending.pop()) |task| {
                if (task.leaving) {
                    self.leave[task.id] = clock;
                    clock += 1;
                    continue;
                }
                if (self.enter[task.id] != std.math.maxInt(usize)) return error.InvalidState;
                self.enter[task.id] = clock;
                clock += 1;
                const record = self.state.nodes[task.id];
                self.normal_return[task.id] = switch (record) {
                    // Completing cleanup resumes an existing, independently checked exit.
                    .cleanup_return => true,
                    // Protection creates a normal exit that must eventually return here.
                    .control,
                    .continuation,
                    .attachment,
                    .region_scope,
                    .injection,
                    .protection,
                    => if (frameParent(record)) |parent|
                        self.normal_return[@intCast(parent.id)]
                    else
                        true,
                    // A disposal marker continues an existing unwind; it has no answer.
                    else => false,
                };
                try pending.append(self.allocator, .{ .id = task.id, .leaving = true });
                for (children[task.id].items) |id| try pending.append(self.allocator, .{ .id = id, .leaving = false });
            }
            for (self.state.nodes, 0..) |record, id| if ((isFrame(record) or record == .region) and self.enter[id] == std.math.maxInt(usize)) return error.InvalidState;
        }

        fn containsScope(self: Context, parent: ?g.NodeRef, attachment: g.NodeRef) Error!void {
            const child = parent orelse return error.InvalidScope;
            if (attachment.id >= self.state.nodes.len or child.id >= self.state.nodes.len) return error.InvalidReference;
            if (!(self.enter[@intCast(attachment.id)] <= self.enter[@intCast(child.id)] and self.leave[@intCast(child.id)] <= self.leave[@intCast(attachment.id)])) return error.InvalidScope;
        }

        fn value(self: *Context, item: g.Value, expected: p.Id) Error!void {
            if (item.schema != expected) return error.TypeMismatch;
            const shape = try a.schemaAt(self.program.schemas, expected);
            switch (item.body) {
                .scalar => |bytes| {
                    const width = scalar.width(shape) orelse return error.InvalidValue;
                    if (!std.mem.allEqual(u8, bytes[width..], 0)) return error.InvalidValue;
                    try a.value(self.allocator, self.program.schemas, self.facts, .{ .schema = expected, .bytes = bytes[0..width] });
                },
                .blob => |ref| {
                    if (scalar.width(shape) != null or !self.facts.exportable[@intCast(expected)] or ref.id >= self.state.blobs.len) return error.InvalidValue;
                    if (self.state.blobs[@intCast(ref.id)].schema != expected) return error.TypeMismatch;
                },
                .reference, .owned => {
                    const ref = switch (item.body) {
                        .reference => |ref| ref,
                        .owned => |owned| owned.node,
                        else => unreachable,
                    };
                    const record_value = try node(self.state, ref);
                    if ((item.body == .reference) != self.uses.copy[@intCast(expected)]) return error.InvalidOwnership;
                    if (item.body == .owned) self.owned[@intCast(ref.id)] += 1;
                    if (shape != .internal) {
                        if (self.facts.exportable[@intCast(expected)] or record_value != .aggregate or record_value.aggregate.schema != expected) return error.InvalidValue;
                        return;
                    }
                    switch (shape.internal) {
                        .capability => |effect| {
                            if (record_value != .attachment) return error.TypeMismatch;
                            const activation = try node(self.state, record_value.attachment.handler);
                            if (activation != .handler or activation.handler.definition >= self.program.handlers.len) return error.InvalidState;
                            var found = false;
                            for (self.program.handlers[@intCast(activation.handler.definition)].clauses) |clause| if (clause.effect == effect) {
                                found = true;
                                break;
                            };
                            if (!found) return error.TypeMismatch;
                        },
                        .computation => {
                            if (record_value != .computation or record_value.computation.constructor >= self.program.constructors.len) return error.TypeMismatch;
                            if (self.program.constructors[@intCast(record_value.computation.constructor)].schema != expected) return error.TypeMismatch;
                        },
                        .resumption => |signature| {
                            if (signature.use == .multi) {
                                if (record_value != .multi_template or record_value.multi_template.schema != expected) return error.TypeMismatch;
                            } else if (record_value != .one_shot or record_value.one_shot.schema != expected) return error.TypeMismatch;
                        },
                        .region => |descriptor| {
                            if (record_value != .region or record_value.region.descriptor != descriptor) return error.TypeMismatch;
                        },
                        .cell => {
                            if (record_value != .cell or record_value.cell.schema != expected) return error.TypeMismatch;
                        },
                        .suspension_package => {
                            if (record_value != .package or record_value.package.schema != expected) return error.TypeMismatch;
                        },
                        .abstract_resource => {
                            if (record_value != .resource or record_value.resource.schema != expected) return error.TypeMismatch;
                        },
                        .borrowed => {
                            if (record_value != .borrow or record_value.borrow.schema != expected) return error.TypeMismatch;
                        },
                    }
                },
            }
        }

        fn values(self: *Context, items: []const g.Value, types: []const p.Id) Error!void {
            if (items.len != types.len) return error.TypeMismatch;
            for (items, types) |item, ty| try self.value(item, ty);
        }

        fn evidence(self: Context, reference: ?g.NodeRef) Error!void {
            if (reference) |ref| if (try node(self.state, ref) != .attachment) return error.InvalidScope;
        }

        fn expectedResult(self: Context, source: Block) Error!p.Id {
            return switch (source.terminator) {
                .call => |call| self.program.functions[@intCast(call.function)].result,
                .perform => |perform| self.program.effects[@intCast(perform.effect)].result,
                .apply => |apply| (try contracts.computation(self.program, try self.slotType(source, apply.computation))).result,
                .handle => |handle| self.program.handlers[@intCast(handle.handler)].answer,
                .resume_value => |resuming| (try contracts.resumption(self.program, try self.slotType(source, resuming.resumption))).answer,
                .resume_with => |resuming| self.program.handlers[@intCast(resuming.handler)].answer,
                .resume_computation => |resuming| (try contracts.resumption(self.program, try self.slotType(source, resuming.resumption))).answer,
                .with_region => |scope| (try contracts.computation(self.program, try self.slotType(source, scope.body))).result,
                .protect => |protection| (try contracts.computation(self.program, try self.slotType(source, protection.body))).result,
                .dispose => |disposal| (try contracts.resumption(self.program, try self.slotType(source, disposal.owned))).answer,
                else => error.InvalidState,
            };
        }

        fn checkActivation(self: *Context, id: usize, block_id: p.Id, saved: bool) Error!void {
            const frame = self.activations[id] orelse return error.InvalidState;
            const block = self.program.blocks[@intCast(block_id)];
            const function = self.program.functions[@intCast(block.function)];
            const flow = self.flow.?;
            if (frame.position > block.instructions.len or frame.scope != block.custody or
                (saved and frame.position != block.instructions.len)) return error.InvalidState;
            if (flow.positions[@intCast(block_id)].len == 0) return error.InvalidState;
            const position: usize = @intCast(frame.position);
            const available = flow.positions[@intCast(block_id)][position];
            var retained = flow.live[@intCast(block_id)][position];
            if (saved) {
                const edge = next(block.terminator) orelse return error.InvalidState;
                const after = flow.live[@intCast(edge.block)][0];
                retained = after;
                for (edge.assignments) |assignment| retained = try flow.pool.remove(retained, assignment.destination);
                for (edge.assignments) |assignment| if (assignment.source == .slot and flow.pool.contains(after, assignment.destination)) {
                    retained = try flow.pool.insert(retained, assignment.source.slot);
                };
            }
            const record = self.state.nodes[id];
            const parent = if (saved) record.continuation.parent else record.control.parent;
            const region_context = if (saved) record.continuation.region else record.control.region;
            for (frame.bindings) |binding| {
                if (binding.slot >= function.layout.slots.len or !flow.pool.contains(retained, binding.slot)) return error.InvalidState;
                if (!flow.pool.contains(available.available, binding.slot) and !flow.pool.contains(available.obligations, binding.slot)) return error.InvalidState;
                const schema = function.layout.slots[@intCast(binding.slot)];
                try self.value(binding.value, schema);
                const shape = self.program.schemas[@intCast(schema)];
                if (shape == .internal and shape.internal == .capability) try self.containsScope(parent, binding.value.body.reference);
                try self.valueRegion(binding.value, region_context);
            }
            var needed = flow.pool.iterator(try flow.pool.intersect(retained, available.available));
            while (needed.next()) |slot| if (@import("state_image.zig").find(frame.bindings, slot) == null) return error.InvalidState;
            var scope = frame.scope;
            for (frame.owners) |owner| {
                while (scope != owner.scope) scope = function.custody[@intCast(scope)].parent orelse return error.InvalidState;
            }
        }

        fn slotType(self: Context, block: Block, slot: p.Id) Error!p.Id {
            return contracts.programSlotSchema(self.program, block, slot);
        }

        fn checkParent(self: Context, reference: ?g.NodeRef, result_type: p.Id) Error!void {
            if (reference) |ref| switch (try node(self.state, ref)) {
                .continuation => |saved| {
                    if (saved.source_block >= self.program.blocks.len) return error.InvalidReference;
                    if (result_type != try self.expectedResult(self.program.blocks[@intCast(saved.source_block)])) return error.TypeMismatch;
                },
                .attachment => |attachment| {
                    const activation = (try node(self.state, attachment.handler)).handler;
                    if (result_type != self.program.handlers[@intCast(activation.definition)].input) return error.TypeMismatch;
                },
                .region_scope => |scope| {
                    if (scope.source_block >= self.program.blocks.len or result_type != try self.expectedResult(self.program.blocks[@intCast(scope.source_block)])) return error.TypeMismatch;
                },
                .injection => |injected| {
                    const saved = try node(self.state, injected.continuation);
                    if (saved != .continuation or saved.continuation.source_block >= self.program.blocks.len) return error.InvalidState;
                    if (result_type != try self.expectedResult(self.program.blocks[@intCast(saved.continuation.source_block)])) return error.TypeMismatch;
                },
                .protection => |protection| {
                    if (protection.source_block >= self.program.blocks.len or result_type != try self.expectedResult(self.program.blocks[@intCast(protection.source_block)])) return error.TypeMismatch;
                },
                .cleanup_return => |cleanup| {
                    const obligation = try node(self.state, cleanup.obligation.node);
                    if (obligation != .obligation or obligation.obligation.source_block >= self.program.blocks.len) return error.InvalidState;
                    const source = self.program.blocks[@intCast(obligation.obligation.source_block)];
                    if (source.terminator != .protect) return error.InvalidState;
                    const signature = try contracts.computation(self.program, try self.slotType(source, source.terminator.protect.cleanup));
                    if (result_type != signature.result) return error.TypeMismatch;
                },
                .disposal_return => |disposal| if (result_type != (try contracts.resumption(self.program, disposal.schema)).answer) return error.TypeMismatch,
                else => return error.InvalidState,
            } else if (result_type != self.program.roots.result) return error.TypeMismatch;
        }

        fn checkRecord(self: *Context, item: g.Node, id: usize) Error!void {
            switch (item) {
                .unwind => |unwind| {
                    if (self.state.status != .unwinding or self.state.roots.current.?.id != id) return error.InvalidState;
                    for (unwind.values) |value_item| {
                        if (value_item.body != .owned) return error.InvalidOwnership;
                        try self.value(value_item, value_item.schema);
                    }
                },
                .protection => |protection| {
                    if (protection.source_block >= self.program.blocks.len) return error.InvalidReference;
                    const source = self.program.blocks[@intCast(protection.source_block)];
                    if (source.terminator != .protect) return error.InvalidState;
                    const obligation = try node(self.state, protection.obligation.node);
                    if (obligation != .obligation or obligation.obligation.source_block != protection.source_block or obligation.obligation.status != .pending) return error.InvalidState;
                    const after = try node(self.state, protection.return_to orelse return error.InvalidState);
                    if (after != .continuation or after.continuation.source_block != protection.source_block or !std.meta.eql(after.continuation.evidence, protection.evidence) or !std.meta.eql(after.continuation.region, protection.region)) return error.InvalidState;
                    if (source.terminator.protect.loan_region) |descriptor| {
                        const loan = try node(self.state, protection.loan orelse return error.InvalidScope);
                        if (loan != .region or loan.region.descriptor != descriptor or !std.meta.eql(loan.region.outer, protection.region)) return error.InvalidScope;
                    } else if (protection.loan != null) return error.InvalidScope;
                },
                .cleanup_return => |cleanup| {
                    const obligation = try node(self.state, cleanup.obligation.node);
                    if (obligation != .obligation or obligation.obligation.status != .running or obligation.obligation.status.running.id != id) return error.InvalidState;
                    const after = try node(self.state, cleanup.parent orelse return error.InvalidState);
                    if (after != .continuation or after.continuation.source_block != obligation.obligation.source_block) return error.InvalidState;
                },
                .disposal_return => |disposal| {
                    const signature = try contracts.resumption(self.program, disposal.schema);
                    if (signature.use == .multi or self.state.roots.exit == null) return error.InvalidState;
                    for (disposal.values) |value_item| {
                        if (value_item.body != .owned) return error.InvalidOwnership;
                        try self.value(value_item, value_item.schema);
                    }
                },
                .obligation => |obligation| {
                    if (obligation.source_block >= self.program.blocks.len) return error.InvalidReference;
                    const source = self.program.blocks[@intCast(obligation.source_block)];
                    if (source.terminator != .protect) return error.InvalidState;
                    if (obligation.status == .pending) {
                        try self.value(obligation.cleanup orelse return error.InvalidState, try self.slotType(source, source.terminator.protect.cleanup));
                        if (source.terminator.protect.resource) |slot| {
                            try self.value(obligation.resource orelse return error.InvalidState, try self.slotType(source, slot));
                        } else if (obligation.resource != null) return error.InvalidOwnership;
                    } else {
                        if (obligation.cleanup != null or obligation.resource != null or obligation.status != .running) return error.InvalidState;
                        const cleanup = try node(self.state, obligation.status.running);
                        if (cleanup != .cleanup_return or cleanup.cleanup_return.obligation.node.id != id) return error.InvalidState;
                    }
                },
                .exit => |exit| {
                    if (@backingInt(self.state.status) >= 4) {
                        if (exit.stop != null or exit.outer != null or exit.discarded.len != 0) return error.InvalidState;
                        switch (self.state.status) {
                            .completed => {
                                if (exit.reason != .normal or exit.cleanup_failures.len != 0 or exit.cancellation != null) return error.InvalidState;
                                try self.value(exit.reason.normal, self.program.roots.result);
                            },
                            .failed => {
                                if (exit.reason != .failure) return error.InvalidState;
                                try self.value(exit.reason.failure, self.program.roots.failure);
                            },
                            .cancelled => if (exit.reason != .cancellation or exit.cancellation == null) return error.InvalidState,
                            else => unreachable,
                        }
                        for (exit.cleanup_failures) |failure| try self.value(failure, self.program.roots.failure);
                        if (exit.cancellation) |reason| if (reason == .text and !std.unicode.utf8ValidateSlice(reason.text)) return error.InvalidUtf8;
                        return;
                    }
                    if (exit.cancellation) |reason| if (reason == .text and !std.unicode.utf8ValidateSlice(reason.text)) return error.InvalidUtf8;
                    for (exit.cleanup_failures) |failure| try self.value(failure, self.program.roots.failure);
                    for (exit.discarded) |value_item| {
                        if (value_item.body != .owned) return error.InvalidOwnership;
                        try self.value(value_item, value_item.schema);
                    }
                    if (exit.outer != null and (exit.cancellation != null or exit.cleanup_failures.len != 0)) return error.InvalidState;
                    switch (exit.reason) {
                        .normal => |value_item| {
                            try self.value(value_item, value_item.schema);
                            const after = try node(self.state, exit.stop orelse return error.InvalidState);
                            if (after != .continuation or after.continuation.source_block >= self.program.blocks.len or self.program.blocks[@intCast(after.continuation.source_block)].terminator != .protect) return error.InvalidState;
                            if (!self.normal_return[@intCast(exit.stop.?.id)]) return error.InvalidState;
                            try self.checkParent(exit.stop, value_item.schema);
                        },
                        .abandoned => {
                            const after = try node(self.state, exit.stop orelse return error.InvalidState);
                            if (after != .continuation or after.continuation.source_block >= self.program.blocks.len or self.program.blocks[@intCast(after.continuation.source_block)].terminator != .dispose) return error.InvalidState;
                            if (!self.normal_return[@intCast(exit.stop.?.id)]) return error.InvalidState;
                        },
                        .failure => |failure| {
                            try self.value(failure, self.program.roots.failure);
                            if (exit.stop != null) return error.InvalidState;
                        },
                        .cancellation => if (exit.cancellation == null or exit.stop != null) return error.InvalidState,
                    }
                },
                .control => |control| {
                    if (control.block >= self.program.blocks.len) return error.InvalidReference;
                    const block = self.program.blocks[@intCast(control.block)];
                    try self.checkActivation(id, control.block, false);
                    try self.checkParent(control.parent, self.program.functions[@intCast(block.function)].result);
                    try self.effect_check.?.requireEffects(
                        control.parent,
                        self.program.functions[@intCast(block.function)].effects,
                    );
                    try self.evidence(control.evidence);
                    if (control.evidence) |evidence_ref| try self.containsScope(control.parent, evidence_ref);
                    try self.region(control.region);
                    try self.regionContext(control.region, control.parent);
                },
                .continuation => |saved| {
                    if (saved.source_block >= self.program.blocks.len) return error.InvalidReference;
                    const source = self.program.blocks[@intCast(saved.source_block)];
                    _ = next(source.terminator) orelse return error.InvalidState;
                    try self.checkActivation(id, saved.source_block, true);
                    try self.checkParent(saved.parent, self.program.functions[@intCast(source.function)].result);
                    try self.effect_check.?.requireEffects(
                        saved.parent,
                        self.program.functions[@intCast(source.function)].effects,
                    );
                    try self.evidence(saved.evidence);
                    if (saved.evidence) |evidence_ref| try self.containsScope(saved.parent, evidence_ref);
                    try self.region(saved.region);
                    try self.regionContext(saved.region, saved.parent);
                },
                .handler => |activation| {
                    if (activation.definition >= self.program.handlers.len) return error.InvalidReference;
                    try self.values(activation.state, self.program.handlers[@intCast(activation.definition)].state);
                    try self.evidence(activation.evidence);
                    try self.region(activation.region);
                    for (activation.state) |value_item| try self.valueRegion(value_item, activation.region);
                },
                .attachment => |attachment| {
                    const activation = try node(self.state, attachment.handler);
                    if (!std.meta.eql(attachment.outer, activation.handler.evidence)) return error.InvalidScope;
                    try self.evidence(attachment.outer);
                    if (attachment.phase == .active) try self.checkParent(attachment.return_to, self.program.handlers[@intCast(activation.handler.definition)].answer) else if (attachment.return_to != null) return error.InvalidState;
                    if (attachment.phase == .active) if (attachment.outer) |outer| try self.containsScope(attachment.return_to, outer);
                    if (!std.meta.eql(attachment.region, activation.handler.region)) return error.InvalidScope;
                    if (attachment.phase == .active) try self.regionContext(attachment.region, attachment.return_to);
                    try self.effect_check.?.attachment(.{ .id = id });
                },
                .environment => |environment| {
                    if (environment.tail != null) return error.InvalidState;
                    for (environment.values) |item_value| try self.value(item_value, item_value.schema);
                },
                .aggregate => |aggregate| {
                    const shape = try a.schemaAt(self.program.schemas, aggregate.schema);
                    if (self.facts.exportable[@intCast(aggregate.schema)]) return error.InvalidValue;
                    switch (shape) {
                        .product => |fields| {
                            if (aggregate.tag != 0) return error.InvalidValue;
                            try self.values(aggregate.fields, fields);
                        },
                        .sum => |variants| {
                            if (aggregate.tag >= variants.len) return error.InvalidValue;
                            try self.values(aggregate.fields, &.{variants[@intCast(aggregate.tag)]});
                        },
                        .seq, .vector => {
                            if (aggregate.tag != 0 or (shape == .vector and aggregate.fields.len > shape.vector.maximum)) return error.InvalidValue;
                            const element = if (shape == .seq) shape.seq else shape.vector.element;
                            for (aggregate.fields) |field| try self.value(field, element);
                        },
                        .array => |array| {
                            if (aggregate.tag != 0 or aggregate.fields.len != array.length) return error.InvalidValue;
                            for (aggregate.fields) |field| try self.value(field, array.element);
                        },
                        else => return error.InvalidValue,
                    }
                },
                .region => |scope| {
                    if (scope.descriptor >= self.program.scopes.region_count or scope.obligations.len != 0) return error.InvalidState;
                    try self.region(scope.outer);
                },
                .region_scope => |scope| {
                    const region_node = try node(self.state, scope.region);
                    if (region_node != .region or scope.source_block >= self.program.blocks.len) return error.InvalidState;
                    const source = self.program.blocks[@intCast(scope.source_block)];
                    if (source.terminator != .with_region or source.terminator.with_region.region != region_node.region.descriptor) return error.InvalidState;
                    try self.checkParent(scope.return_to, try self.expectedResult(source));
                    const after = try node(self.state, scope.return_to orelse return error.InvalidState);
                    if (after != .continuation or
                        after.continuation.source_block != scope.source_block or
                        !std.meta.eql(after.continuation.region, region_node.region.outer))
                        return error.InvalidScope;
                },
                .cell => |cell| {
                    const shape = try a.schemaAt(self.program.schemas, cell.schema);
                    if (shape != .internal or shape.internal != .cell) return error.TypeMismatch;
                    const scope = try node(self.state, cell.region);
                    if (scope != .region or scope.region.descriptor != shape.internal.cell.region) return error.InvalidScope;
                    const content = cell.value orelse return error.InvalidState;
                    try self.value(content, shape.internal.cell.element);
                    try self.valueRegion(content, cell.region);
                },
                .injection => |injected| {
                    const saved = try node(self.state, injected.continuation);
                    if (saved != .continuation or saved.continuation.source_block >= self.program.blocks.len) return error.InvalidState;
                    const source = self.program.blocks[@intCast(saved.continuation.source_block)];
                    if (source.terminator != .perform) return error.InvalidState;
                },
                .computation => |closure| {
                    if (closure.constructor >= self.program.constructors.len) return error.InvalidReference;
                    const constructor = self.program.constructors[@intCast(closure.constructor)];
                    const environment = try node(self.state, closure.environment);
                    if (environment != .environment) return error.InvalidState;
                    const fields = self.program.scopes.captures[@intCast(constructor.capture)].fields;
                    if (fields.len != environment.environment.values.len) return error.TypeMismatch;
                    for (fields, environment.environment.values) |schema, item_value| if (schema != item_value.schema) return error.TypeMismatch;
                },
                .one_shot => |token| {
                    if ((try contracts.resumption(self.program, token.schema)).use == .multi) return error.InvalidState;
                    try self.capture(token);
                },
                .package => |package| {
                    const shape = try a.schemaAt(self.program.schemas, package.schema);
                    if (shape != .internal or shape.internal != .suspension_package) return error.TypeMismatch;
                    try self.value(package.continuation, shape.internal.suspension_package);
                },
                .resource => |resource| {
                    const descriptor = try @import("resource_admission.zig").descriptor(self.program, resource.schema);
                    try self.value(resource.value, descriptor.representation);
                },
                .borrow => |borrow| {
                    const shape = try a.schemaAt(self.program.schemas, borrow.schema);
                    if (shape != .internal or shape.internal != .borrowed) return error.TypeMismatch;
                    const resource = try node(self.state, borrow.resource);
                    const region_node = try node(self.state, borrow.region);
                    if (resource != .resource or resource.resource.schema != shape.internal.borrowed.value or region_node != .region or region_node.region.descriptor != shape.internal.borrowed.region) return error.TypeMismatch;
                    if (!std.meta.eql(self.loan_resources[@intCast(borrow.region.id)], @as(?g.NodeRef, borrow.resource))) return error.InvalidScope;
                },
                .multi_template => |token| {
                    if ((try contracts.resumption(self.program, token.schema)).use != .multi) return error.InvalidState;
                    try self.capture(token);
                },
                .pending => |pending| {
                    if (pending.effect >= self.program.effects.len) return error.InvalidEffect;
                    const effect = self.program.effects[@intCast(pending.effect)];
                    if (!effect.external) return error.InvalidEffect;
                    try self.value(pending.payload, effect.payload);
                    const saved = try node(self.state, pending.continuation);
                    if (saved != .continuation or saved.continuation.source_block != pending.source_block or pending.source_block >= self.program.blocks.len) return error.InvalidState;
                    const source = self.program.blocks[@intCast(pending.source_block)].terminator;
                    if (source != .perform or source.perform.effect != pending.effect or source.perform.capability != null) return error.InvalidState;
                    try self.checkParent(pending.continuation, effect.result);
                },
                else => return error.InvalidState,
            }
        }

        fn region(self: Context, reference: ?g.NodeRef) Error!void {
            if (reference) |ref| if (try node(self.state, ref) != .region) return error.InvalidScope;
        }
        fn regionContext(self: Context, required: ?g.NodeRef, parent: ?g.NodeRef) Error!void {
            const selected = required orelse return;
            try self.containsScope(try self.availableRegion(parent), selected);
        }
        fn availableRegion(self: Context, parent: ?g.NodeRef) Error!?g.NodeRef {
            var cursor = parent;
            while (cursor) |ref| switch (try node(self.state, ref)) {
                .control => |control| return control.region,
                .continuation => |saved| return saved.region,
                .attachment => |attachment| return attachment.region,
                .region_scope => |scope| return scope.region,
                .protection => |protection| return protection.loan orelse protection.region,
                .injection => |injected| {
                    const saved = try node(self.state, injected.continuation);
                    if (saved != .continuation) return error.InvalidState;
                    return saved.continuation.region;
                },
                .cleanup_return => |cleanup| {
                    cursor = cleanup.parent;
                    continue;
                },
                .disposal_return => |disposal| {
                    cursor = disposal.parent;
                    continue;
                },
                .unwind => |unwind| {
                    cursor = unwind.cursor;
                    continue;
                },
                else => return error.InvalidState,
            };
            return null;
        }
        fn valueRegion(self: Context, item: g.Value, context: ?g.NodeRef) Error!void {
            const shape = self.program.schemas[@intCast(item.schema)];
            if (shape != .internal) return;
            const ref: ?g.NodeRef = switch (shape.internal) {
                .region => item.body.reference,
                .cell => (try node(self.state, item.body.reference)).cell.region,
                .borrowed => (try node(self.state, item.body.reference)).borrow.region,
                else => null,
            };
            if (ref) |required| try self.containsScope(context, required);
        }

        const Bound = struct {
            present: bool = false,
            forbidden: bool = false,
            first: usize = std.math.maxInt(usize),
            last: usize = 0,

            fn merge(self: *Bound, other: Bound) void {
                if (!other.present) return;
                self.present = true;
                self.forbidden = self.forbidden or other.forbidden;
                self.first = @min(self.first, other.first);
                self.last = @max(self.last, other.last);
            }
        };
        const UseScope = struct {
            frame: Bound = .{},
            region: Bound = .{},
            fn merge(self: *UseScope, other: UseScope) void {
                self.frame.merge(other.frame);
                self.region.merge(other.region);
            }
        };

        fn bound(self: Context, ref: ?g.NodeRef) Bound {
            if (ref) |present| return .{ .present = true, .first = self.enter[@intCast(present.id)], .last = self.leave[@intCast(present.id)] };
            return .{ .present = true, .forbidden = true };
        }
        fn within(self: Context, required: ?g.NodeRef, use: Bound) Error!void {
            if (!use.present) return;
            if (required) |ref| {
                if (use.forbidden or self.enter[@intCast(ref.id)] > use.first or self.leave[@intCast(ref.id)] < use.last) return error.InvalidScope;
            }
        }
        fn holder(record: g.Node) bool {
            return record == .computation or record == .environment or record == .aggregate or record == .package;
        }

        const BorrowContext = struct {
            frame: ?g.NodeRef = null,
            region: ?g.NodeRef = null,
            frame_present: bool = true,
            region_present: bool = true,

            fn selected(self: BorrowContext, component: ?borrows.Ambient) BorrowContext {
                return .{
                    .frame = if (component == .region) null else self.frame,
                    .region = if (component == .evidence) null else self.region,
                    .frame_present = component != .region and self.frame_present,
                    .region_present = component != .evidence and self.region_present,
                };
            }
        };
        const Projection = union(enum) { value: g.Value, borrow: BorrowContext };
        const ProjectionTask = union(enum) {
            value: struct { value: g.Value, path: usize },
            source: struct { frame: g.NodeRef, source: borrows.Source },
            delivered: struct { frame: g.NodeRef, path: usize },
        };

        fn framePosition(self: Context, frame: g.NodeRef) ?usize {
            return switch (self.state.nodes[@intCast(frame.id)]) {
                .control => @intCast(self.activations[@intCast(frame.id)].?.position),
                .continuation => 0,
                else => null,
            };
        }

        fn frameSource(self: Context, frame: g.NodeRef, source: borrows.Source) Error!?g.Value {
            const record = self.state.nodes[@intCast(frame.id)];
            var slot = source.parameter;
            if (record == .control and !source.stable_slot) {
                const block = self.program.blocks[@intCast(record.control.block)];
                const inputs = self.program.functions[@intCast(block.function)].inputs;
                if (slot >= inputs.len) return error.InvalidState;
                slot = inputs[@intCast(slot)];
            } else if (record == .continuation) {
                if (!source.stable_slot) return error.InvalidState;
                const edge = next(self.program.blocks[@intCast(record.continuation.source_block)].terminator).?;
                for (edge.assignments) |assignment| if (assignment.destination == slot) {
                    slot = switch (assignment.source) {
                        .slot => |source_slot| source_slot,
                        .returned => return null,
                    };
                    break;
                };
            }
            const binding = @import("state_image.zig").find(self.activations[@intCast(frame.id)].?.bindings, slot) orelse return error.InvalidState;
            return binding.value;
        }

        fn projectSource(
            self: Context,
            pending: *std.ArrayList(ProjectionTask),
            result: *std.ArrayList(Projection),
            frame: g.NodeRef,
            source: borrows.Source,
        ) Error!void {
            const record = try node(self.state, frame);
            if (source.ambient) |ambient| {
                const context: BorrowContext = switch (record) {
                    .control => |v| .{ .frame = v.evidence, .region = v.region },
                    .continuation => |v| .{ .frame = v.evidence, .region = v.region },
                    .attachment => |v| blk: {
                        const handler = (try node(self.state, v.handler)).handler;
                        break :blk .{ .frame = handler.evidence, .region = handler.region };
                    },
                    else => return error.InvalidState,
                };
                try result.append(self.allocator, .{ .borrow = context.selected(ambient) });
                return;
            }
            const parameter: usize = @intCast(source.parameter);
            const value_item: ?g.Value = switch (record) {
                .control, .continuation => try self.frameSource(frame, source),
                .attachment => |v| blk: {
                    const handler = (try node(self.state, v.handler)).handler;
                    break :blk if (parameter < handler.state.len) handler.state[parameter] else null;
                },
                else => return error.InvalidState,
            };
            if (value_item) |argument| {
                try pending.append(self.allocator, .{ .value = .{
                    .value = argument,
                    .path = source.path,
                } });
            } else {
                try pending.append(self.allocator, .{ .delivered = .{
                    .frame = frame,
                    .path = source.path,
                } });
            }
        }

        fn projected(self: Context, flow: *BorrowFlow, children: []const ?g.NodeRef, first: ProjectionTask) Error![]const Projection {
            var pending: std.ArrayList(ProjectionTask) = .empty;
            var result: std.ArrayList(Projection) = .empty;
            var delivered: std.AutoHashMapUnmanaged(struct { id: p.Id, path: usize }, void) = .empty;
            var seen_values: std.AutoHashMapUnmanaged(struct { id: p.Id, path: usize }, void) = .empty;
            try pending.append(self.allocator, first);
            while (pending.pop()) |task| switch (task) {
                .value => |selected| {
                    if (selected.path == 0) {
                        try result.append(self.allocator, .{ .value = selected.value });
                        continue;
                    }
                    const ref = switch (selected.value.body) {
                        .reference => |ref| ref,
                        .owned => |ref| ref.node,
                        else => continue,
                    };
                    if ((try seen_values.getOrPut(self.allocator, .{ .id = ref.id, .path = selected.path })).found_existing) continue;
                    const record = try node(self.state, ref);
                    const path = flow.paths.items[selected.path - 1];
                    switch (path.step) {
                        .field => |field| {
                            if (record != .aggregate) continue;
                            const shape = self.program.schemas[@intCast(selected.value.schema)];
                            if (shape == .sum) {
                                if (record.aggregate.tag != field) continue;
                                try pending.append(self.allocator, .{ .value = .{ .value = record.aggregate.fields[0], .path = path.tail } });
                            } else if (field < record.aggregate.fields.len) try pending.append(self.allocator, .{ .value = .{ .value = record.aggregate.fields[@intCast(field)], .path = path.tail } });
                        },
                        .element => if (record == .aggregate) {
                            for (record.aggregate.fields) |value_item| try pending.append(self.allocator, .{ .value = .{ .value = value_item, .path = path.tail } });
                        },
                        .environment => |environment| if (record == .computation and record.computation.constructor == environment.constructor) {
                            const fields = (try node(self.state, record.computation.environment)).environment.values;
                            try pending.append(self.allocator, .{ .value = .{ .value = fields[@intCast(environment.field)], .path = path.tail } });
                        },
                        .handler_state => |state| if (record == .attachment) {
                            const handler = (try node(self.state, record.attachment.handler)).handler;
                            if (handler.definition == state.handler) try pending.append(self.allocator, .{ .value = .{ .value = handler.state[@intCast(state.field)], .path = path.tail } });
                        },
                        .body_result => |schema| {
                            const delimiter = switch (record) {
                                .one_shot, .multi_template => |token| token.delimiter,
                                .attachment => ref,
                                else => continue,
                            };
                            const attachment = (try node(self.state, delimiter)).attachment;
                            const handler = (try node(self.state, attachment.handler)).handler;
                            if (self.program.handlers[@intCast(handler.definition)].input == schema) {
                                try pending.append(self.allocator, .{ .delivered = .{
                                    .frame = delimiter,
                                    .path = path.tail,
                                } });
                            }
                        },
                        .cell_content => if (record == .cell) {
                            try pending.append(self.allocator, .{ .value = .{ .value = record.cell.value.?, .path = path.tail } });
                        },
                        .package_token => if (record == .package) {
                            try pending.append(self.allocator, .{ .value = .{ .value = record.package.continuation, .path = path.tail } });
                        },
                        .use_site => |site| switch (record) {
                            .one_shot, .multi_template => |token| try pending.append(self.allocator, .{ .value = .{ .value = token.use_site_capabilities[@intCast(site.index)], .path = path.tail } }),
                            else => {},
                        },
                        .outer => |component| if (record == .attachment) {
                            const activation = (try node(self.state, record.attachment.handler)).handler;
                            const context: BorrowContext = .{ .frame = record.attachment.outer, .region = activation.region };
                            try result.append(self.allocator, .{ .borrow = context.selected(component) });
                        },
                        .resumed => |component| switch (record) {
                            .one_shot, .multi_template => |token| {
                                const saved = (try node(self.state, token.capture.?)).continuation;
                                const context: BorrowContext = .{ .frame = saved.evidence, .region = saved.region };
                                try result.append(self.allocator, .{ .borrow = context.selected(component) });
                            },
                            .attachment => |attachment| {
                                const context: BorrowContext = .{ .frame = ref, .region = attachment.region };
                                try result.append(self.allocator, .{ .borrow = context.selected(component) });
                            },
                            else => {},
                        },
                    }
                },
                .source => |selected| try self.projectSource(
                    &pending,
                    &result,
                    selected.frame,
                    selected.source,
                ),
                .delivered => |selected| {
                    if ((try delivered.getOrPut(self.allocator, .{ .id = selected.frame.id, .path = selected.path })).found_existing) continue;
                    const child = children[@intCast(selected.frame.id)] orelse return error.InvalidState;
                    const record = try node(self.state, child);
                    const start: ?p.Id = switch (record) {
                        .control => |v| v.block,
                        .continuation => |v| next(self.program.blocks[@intCast(v.source_block)].terminator).?.block,
                        .attachment => |v| blk: {
                            const handler = (try node(self.state, v.handler)).handler;
                            break :blk self.program.functions[@intCast(self.program.handlers[@intCast(handler.definition)].return_function)].entry;
                        },
                        .region_scope, .protection, .injection => blk: {
                            try pending.append(self.allocator, .{ .delivered = .{ .frame = child, .path = selected.path } });
                            break :blk null;
                        },
                        .cleanup_return => |v| blk: {
                            const exit = (try node(self.state, v.exit)).exit;
                            if (exit.reason == .normal) try pending.append(self.allocator, .{ .value = .{ .value = exit.reason.normal, .path = selected.path } });
                            break :blk null;
                        },
                        // Resumed operation inputs and cleanup/disposal results are
                        // exportable. A dormant token has no hidden native input.
                        .one_shot, .multi_template, .pending, .disposal_return, .unwind => null,
                        else => return error.InvalidState,
                    };
                    if (start) |block| {
                        const sources = if (self.framePosition(child)) |position|
                            try flow.returnedFrom(block, position, selected.path)
                        else
                            try flow.returnedAt(block, selected.path);
                        for (sources) |source| try pending.append(self.allocator, .{ .source = .{ .frame = child, .source = source } });
                    }
                },
            };
            return result.items;
        }

        fn useProjection(self: Context, contexts: []UseScope, projected_value: Projection, use: UseScope) Error!void {
            switch (projected_value) {
                .value => |value_item| try self.useValue(contexts, value_item, use),
                .borrow => |context| {
                    try self.within(context.frame, use.frame);
                    try self.within(context.region, use.region);
                },
            }
        }

        fn ownerScope(self: Context, projected_owner: Projection, kind: borrows.Bound, region_frames: []const ?g.NodeRef) Error!?UseScope {
            if (projected_owner == .borrow) {
                const context = projected_owner.borrow;
                return .{ .frame = if (context.frame_present) self.bound(context.frame) else .{}, .region = if (context.region_present) self.bound(context.region) else .{} };
            }
            const ref = switch (projected_owner.value.body) {
                .reference => |ref| ref,
                .owned => |ref| ref.node,
                else => return null,
            };
            const record = try node(self.state, ref);
            switch (kind) {
                .region => {
                    const region_ref = switch (record) {
                        .region => ref,
                        .cell => |v| v.region,
                        .borrow => |v| v.region,
                        else => return null,
                    };
                    return .{ .frame = self.bound(region_frames[@intCast(region_ref.id)]), .region = self.bound(region_ref) };
                },
                .clause, .capture => {
                    const delimiter = switch (record) {
                        .attachment => record.attachment,
                        .one_shot, .multi_template => |v| (try node(self.state, v.delimiter)).attachment,
                        .package => |v| return self.ownerScope(.{ .value = v.continuation }, kind, region_frames),
                        else => return null,
                    };
                    const activation = (try node(self.state, delimiter.handler)).handler;
                    return .{ .frame = self.bound(if (kind == .clause and delimiter.phase == .active) delimiter.return_to else delimiter.outer), .region = self.bound(activation.region) };
                },
            }
        }

        fn futureScopes(self: *Context, contexts: []UseScope, region_frames: []const ?g.NodeRef) Error!void {
            var flow = try BorrowFlow.initWithControl(self.allocator, self.program, self.facts.exportable, self.control);
            const children = try self.allocator.alloc(?g.NodeRef, self.state.nodes.len);
            @memset(children, null);
            for (self.state.nodes, 0..) |record, id| {
                if (frameParent(record)) |parent| children[@intCast(parent.id)] = .{ .id = id };
                switch (record) {
                    .one_shot, .multi_template => |v| if (v.capture) |captured| {
                        children[@intCast(captured.id)] = .{ .id = id };
                    },
                    .pending => |v| children[@intCast(v.continuation.id)] = .{ .id = id },
                    else => {},
                }
            }
            for (self.state.nodes, 0..) |record, id| {
                const frame: g.NodeRef = .{ .id = id };
                const start: ?p.Id = switch (record) {
                    .control => |v| v.block,
                    .continuation => |v| next(self.program.blocks[@intCast(v.source_block)].terminator).?.block,
                    .attachment => |v| blk: {
                        const handler = (try node(self.state, v.handler)).handler;
                        break :blk self.program.functions[@intCast(self.program.handlers[@intCast(handler.definition)].return_function)].entry;
                    },
                    else => null,
                };
                if (start) |block| {
                    const constraints = if (self.framePosition(frame)) |position| try flow.requiredFrom(block, position) else try flow.required(block);
                    for (constraints) |constraint| {
                        const owners = try self.projected(&flow, children, .{ .source = .{ .frame = frame, .source = constraint.owner } });
                        const values_to_use = try self.projected(&flow, children, .{ .source = .{ .frame = frame, .source = constraint.value } });
                        for (owners) |owner| if (try self.ownerScope(owner, constraint.bound, region_frames)) |use| for (values_to_use) |value_item| try self.useProjection(contexts, value_item, use);
                    }
                }
                const outside: ?UseScope = switch (record) {
                    .attachment => |v| blk: {
                        const handler = (try node(self.state, v.handler)).handler;
                        break :blk .{ .frame = self.bound(if (v.phase == .active) v.return_to else v.outer), .region = self.bound(handler.region) };
                    },
                    .region_scope => |v| .{ .frame = self.bound(v.return_to), .region = self.bound((try node(self.state, v.region)).region.outer) },
                    .protection => |v| if (v.loan != null) .{ .frame = self.bound(v.return_to), .region = self.bound(v.region) } else null,
                    else => null,
                };
                if (outside) |use| for (try self.projected(&flow, children, .{ .delivered = .{ .frame = frame, .path = 0 } })) |value_item| try self.useProjection(contexts, value_item, use);
            }
        }

        /// Propagate all use contexts through the immutable holder DAG once. Mutable
        /// cells and dormant captures introduce their own scope boundary, so legal
        /// continuation/cell cycles do not become recursive validation calls.
        fn valueScopes(self: *Context) Error!void {
            const length = self.state.nodes.len;
            const contexts = try self.allocator.alloc(UseScope, length);
            @memset(contexts, .{});
            const indegrees = try self.allocator.alloc(usize, length);
            @memset(indegrees, 0);
            const region_frames = try self.allocator.alloc(?g.NodeRef, length);
            @memset(region_frames, null);
            const obligation_frames = try self.allocator.alloc(?g.NodeRef, length);
            @memset(obligation_frames, null);
            for (self.state.nodes, 0..) |record, id| if (record == .region_scope) {
                region_frames[@intCast(record.region_scope.region.id)] = .{ .id = id };
            };
            for (self.state.nodes, 0..) |record, id| if (record == .protection) {
                obligation_frames[@intCast(record.protection.obligation.node.id)] = .{ .id = id };
                if (record.protection.loan) |loan| region_frames[@intCast(loan.id)] = .{ .id = id };
            };
            const active_frame = self.state.roots.current orelse if (self.state.roots.pending) |pending| (try node(self.state, pending)).pending.continuation else null;
            for (self.state.nodes, 0..) |record, id| switch (record) {
                .unwind => |unwind| for (unwind.values) |item| try self.useValue(contexts, item, .{ .frame = self.bound(unwind.cursor), .region = self.bound(try self.availableRegion(unwind.cursor)) }),
                .disposal_return => |disposal| for (disposal.values) |item| try self.useValue(contexts, item, .{ .frame = self.bound(disposal.parent), .region = self.bound(try self.availableRegion(disposal.parent)) }),
                .obligation => |obligation| if (obligation.cleanup) |cleanup| {
                    const frame = obligation_frames[id] orelse return error.InvalidState;
                    const protection = (try node(self.state, frame)).protection;
                    try self.useValue(contexts, cleanup, .{ .frame = self.bound(protection.return_to), .region = self.bound(protection.region) });
                    if (obligation.resource) |resource| try self.useValue(contexts, resource, .{ .frame = self.bound(protection.return_to), .region = self.bound(protection.region) });
                },
                .exit => |exit| {
                    const frame = exit.stop orelse active_frame;
                    const use: UseScope = .{ .frame = self.bound(frame), .region = self.bound(try self.availableRegion(frame)) };
                    if (exit.reason == .normal) try self.useValue(contexts, exit.reason.normal, use);
                    for (exit.discarded) |item| try self.useValue(contexts, item, use);
                },
                .computation => |closure| indegrees[@intCast(closure.environment.id)] += 1,
                .environment, .aggregate, .package => {
                    const fields = if (record == .environment) record.environment.values else if (record == .aggregate) record.aggregate.fields else (&record.package.continuation)[0..1];
                    for (fields) |item| if (self.holderRef(item)) |ref| {
                        indegrees[@intCast(ref.id)] += 1;
                    };
                },
                .control => |control| {
                    for (self.activations[id].?.bindings) |binding| try self.useValue(contexts, binding.value, .{ .frame = self.bound(control.parent), .region = self.bound(control.region) });
                },
                .continuation => |saved| {
                    for (self.activations[id].?.bindings) |binding| try self.useValue(contexts, binding.value, .{ .frame = self.bound(saved.parent), .region = self.bound(saved.region) });
                },
                .handler => |activation| for (activation.state) |item| try self.useValue(contexts, item, .{ .frame = self.bound(activation.evidence), .region = self.bound(activation.region) }),
                .cell => |cell| try self.useValue(contexts, cell.value.?, .{ .frame = self.bound(region_frames[@intCast(cell.region.id)]), .region = self.bound(cell.region) }),
                .one_shot, .multi_template => |token| {
                    const saved = (try node(self.state, token.capture.?)).continuation;
                    for (token.use_site_capabilities) |item| try self.useValue(contexts, item, .{ .frame = self.bound(saved.parent), .region = self.bound(saved.region) });
                },
                else => {},
            };
            try self.futureScopes(contexts, region_frames);
            var pending: std.ArrayList(usize) = .empty;
            var expected: usize = 0;
            for (self.state.nodes, indegrees, 0..) |record, incoming, id| if (holder(record)) {
                expected += 1;
                if (incoming == 0) try pending.append(self.allocator, id);
            };
            var visited: usize = 0;
            while (pending.pop()) |id| {
                visited += 1;
                const record = self.state.nodes[id];
                if (record == .computation) {
                    const target: usize = @intCast(record.computation.environment.id);
                    contexts[target].merge(contexts[id]);
                    indegrees[target] -= 1;
                    if (indegrees[target] == 0) try pending.append(self.allocator, target);
                } else {
                    const fields = if (record == .environment) record.environment.values else if (record == .aggregate) record.aggregate.fields else (&record.package.continuation)[0..1];
                    for (fields) |item| {
                        try self.useValue(contexts, item, contexts[id]);
                        if (self.holderRef(item)) |ref| {
                            const target: usize = @intCast(ref.id);
                            indegrees[target] -= 1;
                            if (indegrees[target] == 0) try pending.append(self.allocator, target);
                        }
                    }
                }
            }
            if (visited != expected) return error.InvalidState;
        }
        fn holderRef(self: Context, item: g.Value) ?g.NodeRef {
            const ref = switch (item.body) {
                .reference => |ref| ref,
                .owned => |owned| owned.node,
                else => return null,
            };
            return if (holder(self.state.nodes[@intCast(ref.id)])) ref else null;
        }
        fn useValue(self: Context, contexts: []UseScope, item: g.Value, use: UseScope) Error!void {
            if (self.holderRef(item)) |ref| {
                contexts[@intCast(ref.id)].merge(use);
                return;
            }
            const ref = switch (item.body) {
                .reference => |ref| ref,
                .owned => |owned| owned.node,
                else => return,
            };
            switch (try node(self.state, ref)) {
                .attachment => try self.within(ref, use.frame),
                .region => try self.within(ref, use.region),
                .cell => |cell| try self.within(cell.region, use.region),
                .borrow => |borrow| try self.within(borrow.region, use.region),
                .one_shot, .multi_template => |token| {
                    const delimiter = (try node(self.state, token.delimiter)).attachment;
                    const activation = (try node(self.state, delimiter.handler)).handler;
                    try self.within(delimiter.outer, use.frame);
                    try self.within(activation.region, use.region);
                },
                else => {},
            }
        }

        fn capture(self: *Context, token: anytype) Error!void {
            const signature = try contracts.resumption(self.program, token.schema);
            if (token.capture == null) return error.InvalidState;
            if (!self.normal_return[@intCast(token.capture.?.id)]) return error.InvalidState;
            const saved = try node(self.state, token.capture.?);
            const delimiter = try node(self.state, token.delimiter);
            if (saved != .continuation or delimiter != .attachment or delimiter.attachment.phase != .suspended) return error.InvalidState;
            if (saved.continuation.source_block >= self.program.blocks.len) return error.InvalidReference;
            const source = self.program.blocks[@intCast(saved.continuation.source_block)].terminator;
            if (source != .perform or source.perform.effect != signature.effect or source.perform.capability == null) return error.InvalidState;
            const activation = try node(self.state, delimiter.attachment.handler);
            var matching = false;
            for (self.program.handlers[@intCast(activation.handler.definition)].clauses) |clause| if (clause.effect == signature.effect and (clause.resumption == token.schema or try contracts.cloneCompatible(self.program, clause.resumption, token.schema))) {
                matching = true;
                break;
            };
            if (!matching or !std.meta.eql(token.evidence, saved.continuation.evidence)) return error.TypeMismatch;
            const effect = self.program.effects[@intCast(signature.effect)];
            if (token.use_site_capabilities.len != effect.use_site_effects.len) return error.InvalidEffect;
            for (token.use_site_capabilities, effect.use_site_effects) |value_item, id| {
                try self.value(value_item, value_item.schema);
                try contracts.capability(self.program, value_item.schema, id);
            }
            var cursor: ?g.NodeRef = token.capture;
            while (cursor) |ref| {
                if (ref.id == token.delimiter.id) return;
                const frame = try node(self.state, ref);
                try self.captureFrame(signature, @intCast(ref.id));
                cursor = frameParent(frame);
            }
            return error.InvalidScope;
        }

        fn visitFutureCapture(pointer: *anyopaque, frame_id: usize, schema: p.Id) Error!void {
            const self: *Context = @ptrCast(@alignCast(pointer));
            try self.captureFrame(try contracts.resumption(self.program, schema), frame_id);
        }
        fn captureFrame(self: *Context, signature: p.ResumptionType, frame_id: usize) Error!void {
            const frame = self.state.nodes[frame_id];
            switch (frame) {
                .continuation => {
                    for (self.activations[frame_id].?.bindings) |binding| try self.capturedValue(signature, binding.value);
                },
                .attachment => |attachment| {
                    const handler = (try node(self.state, attachment.handler)).handler;
                    for (handler.state) |item| try self.capturedValue(signature, item);
                },
                .disposal_return => |disposal| {
                    for (disposal.values) |item| try self.capturedValue(signature, item);
                },
                else => {},
            }
            if (frame == .region_scope) {
                const region_node = (try node(self.state, frame.region_scope.region)).region;
                if (std.mem.indexOfScalar(p.Id, signature.owned_regions, region_node.descriptor) == null) return error.InvalidOwnership;
            }
            if ((frame == .protection or frame == .cleanup_return) and (!signature.obligations or signature.use == .multi)) return error.InvalidOwnership;
            if (frame == .protection) if (frame.protection.loan) |loan| {
                const descriptor = (try node(self.state, loan)).region.descriptor;
                if (std.mem.indexOfScalar(p.Id, signature.owned_regions, descriptor) == null) return error.InvalidOwnership;
            };
        }

        fn capturedValue(_: Context, signature: p.ResumptionType, item: g.Value) Error!void {
            if (std.mem.indexOfScalar(p.Id, signature.capture_bound, item.schema) == null)
                return error.InvalidOwnership;
        }
    };
}
