// Copyright (c) 2026 Boundary contributors. MIT license.
//! Effect interfaces of saved control frames. Capability origins are derived
//! from the logical graph; no instruction or application computation executes.
const std = @import("std");
const p = @import("program.zig");
const g = @import("graph.zig");
const a = @import("admission.zig");
const contracts = @import("contracts.zig");
const effect_scope = @import("effect_scope.zig");
pub const Error = a.Error || error{ InvalidState, InvalidScope };
pub fn CheckFor(comptime Program: type, comptime State: type) type {
    return struct {
        const Self = @This();
        const Origins = OriginAnalysis;
        allocator: std.mem.Allocator,
        program: Program,
        state: State,
        activations: []const ?@import("process_state.zig").Activation = &.{},
        captures: []const ?p.Id,
        children: []const ?g.NodeRef,
        enter: []const usize,
        leave: []const usize,
        facts: effect_scope.Facts,
        control: ?*const @import("control_provenance.zig").Analysis = null,
        origins: std.AutoHashMapUnmanaged(p.Id, Origins) = .empty,
        pub fn init(
            allocator: std.mem.Allocator,
            program: Program,
            state: State,
            captures: []const ?p.Id,
            children: []const ?g.NodeRef,
            enter: []const usize,
            leave: []const usize,
            prepared_facts: ?effect_scope.Facts,
        ) Error!Self {
            return .{
                .allocator = allocator,
                .program = program,
                .state = state,
                .captures = captures,
                .children = children,
                .enter = enter,
                .leave = leave,
                .facts = prepared_facts orelse try effect_scope.derive(allocator, program),
            };
        }
        const node = checkNode;
        const handler = checkHandler;
        const block = checkBlock;
        const scopeEffects = checkScopeEffects;
        pub const requireEffects = checkRequireEffects;
        const allows = checkAllows;
        pub const attachment = checkAttachment;
        /// A possible executable suspension must also select the concrete
        /// attachment before it can capture a saved frame. Merely retaining a
        /// capability is not an operation on it. Fresh future installations
        /// cannot capture frames outside their own delimiter.
        pub const futureCaptures = checkFutureCaptures;
        const inside = checkInside;
        const local = checkLocal;
    };
}

test "latent disposal follows owned containers but never invokes copied capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const copied: g.Value = .{ .schema = 0, .body = .{ .reference = .{ .id = 0 } } };
    const token: g.Value = .{ .schema = 0, .body = .{ .owned = .{ .node = .{ .id = 1 } } } };
    const closure: g.Value = .{ .schema = 0, .body = .{ .owned = .{ .node = .{ .id = 3 } } } };
    const nodes: []const g.Node = &.{
        .{ .attachment = .{ .handler = .{ .id = 0 }, .outer = null, .return_to = null } },
        .{ .one_shot = .{
            .schema = 0,
            .capture = null,
            .delimiter = .{ .id = 0 },
            .evidence = null,
        } },
        .{ .environment = .{ .values = &.{copied}, .tail = null } },
        .{ .computation = .{ .constructor = 0, .environment = .{ .id = 2 } } },
        .{ .aggregate = .{ .schema = 0, .tag = 0, .fields = &.{closure} } },
        .{ .aggregate = .{ .schema = 0, .tag = 0, .fields = &.{token} } },
        .{ .exit = .{ .reason = .{ .normal = closure } } },
        .{ .exit = .{ .reason = .{ .normal = copied }, .discarded = &.{token} } },
    };
    const State = struct { nodes: []const g.Node };
    const Check = CheckFor(@import("activation.zig").Program, State);
    var check: Check = .{
        .allocator = allocator,
        .program = .{
            .roots = .{ .entry = 0, .result = 0, .failure = 0 },
            .schemas = &.{},
            .constants = &.{},
            .effects = &.{},
            .functions = &.{},
            .blocks = &.{},
        },
        .state = .{ .nodes = nodes },
        .captures = &.{},
        .children = &.{},
        .enter = &.{},
        .leave = &.{},
        .facts = .{ .ambient = &.{}, .dependencies = &.{}, .width = 0 },
    };
    // Both retained closures and tokens expose this origin as values; only
    // tokens execute captured cleanup when disposal reaches them.
    const bits = try allocator.alloc(usize, nodes.len);
    @memset(bits, 1);
    var origins: Check.Origins = .{ .effect = 0, .indices = &.{}, .width = 1, .bits = bits };
    try origins.capabilities.append(allocator, .{ .id = 0 });
    const disposal = try origins.disposals(&check);
    for ([_]usize{ 0, 2, 3, 4, 6 }) |id|
        try std.testing.expectEqual(@as(usize, 0), disposal.row(id)[0]);
    for ([_]usize{ 1, 5, 7 }) |id| try std.testing.expectEqual(@as(usize, 1), disposal.row(id)[0]);
}

fn checkNode(self: anytype, ref: g.NodeRef) Error!g.Node {
    if (ref.id >= self.state.nodes.len) return error.InvalidReference;
    return self.state.nodes[@intCast(ref.id)];
}

fn checkHandler(
    self: anytype,
    ref: g.NodeRef,
) Error!@TypeOf(self.program.handlers[0]) {
    const activation = try self.node(ref);
    if (activation != .handler or
        activation.handler.definition >= self.program.handlers.len)
        return error.InvalidState;
    return self.program.handlers[@intCast(activation.handler.definition)];
}

fn checkBlock(self: anytype, id: p.Id) Error!@TypeOf(self.program.blocks[0]) {
    if (id >= self.program.blocks.len) return error.InvalidReference;
    return self.program.blocks[@intCast(id)];
}

fn checkScopeEffects(self: anytype, source: p.Id, cleanup: bool, effect: p.Id) Error!bool {
    const code = try self.block(source);
    const operand = switch (code.terminator) {
        .with_region => |v| v.body,
        .protect => |v| if (cleanup) v.cleanup else v.body,
        else => return error.InvalidState,
    };
    const signature = try contracts.computation(
        self.program,
        try contracts.programSlotSchema(self.program, code, operand),
    );
    return contracts.containsEffect(signature.effects, effect);
}

fn checkRequireEffects(self: anytype, parent: ?g.NodeRef, effects: []const p.Id) Error!void {
    for (effects) |effect| if (!try self.allows(parent, effect)) return error.InvalidEffect;
}

fn checkAllows(self: anytype, parent: ?g.NodeRef, effect: p.Id) Error!bool {
    var cursor = parent;
    while (cursor) |ref| switch (try self.node(ref)) {
        .continuation => |v| return contracts.invocationEffect(
            self.program,
            try self.block(v.source_block),
            self.facts,
            effect,
        ),
        .attachment => |v| {
            const handler_ = try self.handler(v.handler);
            if (v.phase == .suspended) {
                const schema = self.captures[
                    @intCast(ref.id)
                ] orelse return error.InvalidState;
                const signature = try contracts.resumption(self.program, schema);
                if (contracts.containsEffect(signature.effects, effect)) return true;
                if (signature.mode != .deep) return false;
            }
            for (handler_.clauses) |clause| if (clause.effect == effect) {
                if (try self.local(ref, effect)) return true;
                break;
            };
            if (v.phase == .suspended) return false;
            cursor = v.return_to;
        },
        .region_scope => |v| return self.scopeEffects(v.source_block, false, effect),
        .protection => |v| return self.scopeEffects(v.source_block, false, effect),
        .cleanup_return => |v| {
            const obligation = try self.node(v.obligation.node);
            if (obligation != .obligation) return error.InvalidState;
            return self.scopeEffects(obligation.obligation.source_block, true, effect);
        },
        .injection => |v| {
            const saved = try self.node(v.continuation);
            if (saved != .continuation) return error.InvalidState;
            const source = try self.block(saved.continuation.source_block);
            if (source.terminator != .perform) return error.InvalidState;
            return contracts.containsEffect(
                self.program.effects[
                    @intCast(source.terminator.perform.effect)
                ].use_site_effects,
                effect,
            );
        },
        .disposal_return => |v| return contracts.containsEffect(
            (try contracts.resumption(self.program, v.schema)).effects,
            effect,
        ),
        else => return error.InvalidState,
    };
    return contracts.containsEffect(
        self.program.functions[@intCast(self.program.roots.entry)].effects,
        effect,
    );
}

fn checkAttachment(self: anytype, ref: g.NodeRef) Error!void {
    const record = (try self.node(ref)).attachment;
    const definition = try self.handler(record.handler);
    if (record.phase == .active) return self.requireEffects(
        record.return_to,
        definition.effects,
    );
    const schema = self.captures[@intCast(ref.id)] orelse return error.InvalidState;
    const signature = try contracts.resumption(self.program, schema);
    if (signature.mode == .deep) try contracts.subset(
        definition.effects,
        signature.effects,
    );
}

fn checkFutureCaptures(self: anytype, context: *anyopaque, comptime visit: anytype) !void {
    for (self.state.nodes, 0..) |record, target_id| {
        if (record != .attachment) continue;
        const definition = try self.handler(record.attachment.handler);
        for (definition.clauses) |clause| {
            if (!contracts.retainsResumption(clause)) continue;
            if (!self.origins.contains(clause.effect)) {
                var origins = try OriginAnalysis.init(self, clause.effect);
                try origins.solve(self);
                try self.origins.put(self.allocator, clause.effect, origins);
            }
            const origins = self.origins.getPtr(clause.effect).?;
            const executed = try origins.executable(self);
            const bit = origins.indices[target_id];
            if (bit == OriginAnalysis.absent) continue;
            const scratch = try self.allocator.alloc(usize, origins.width);
            for (self.state.nodes, 0..) |frame, frame_id| {
                if (frame_id == target_id or !self.inside(
                    .{ .id = frame_id },
                    .{ .id = target_id },
                )) continue;
                switch (frame) {
                    .continuation,
                    .attachment,
                    .region_scope,
                    .protection,
                    .cleanup_return,
                    .disposal_return,
                    => {},
                    else => continue,
                }
                @memset(scratch, 0);
                _ = try executed.child(self, frame_id, scratch, null);
                if (OriginAnalysis.contains(scratch, bit))
                    try visit(context, frame_id, clause.resumption);
            }
        }
    }
}

fn checkInside(self: anytype, ref: g.NodeRef, scope: g.NodeRef) bool {
    return self.enter[@intCast(scope.id)] <= self.enter[@intCast(ref.id)] and
        self.leave[@intCast(ref.id)] <= self.leave[@intCast(scope.id)];
}

fn checkLocal(self: anytype, scope: g.NodeRef, effect: p.Id) Error!bool {
    if (self.facts.ambient[@intCast(effect)]) return false;
    if (!self.origins.contains(effect)) {
        var origins = try OriginAnalysis.init(self, effect);
        try origins.solve(self);
        try self.origins.put(self.allocator, effect, origins);
    }
    const origins = self.origins.getPtr(effect).?;
    const scratch = try self.allocator.alloc(usize, origins.width);
    defer self.allocator.free(scratch);
    @memset(scratch, 0);
    _ = try origins.child(self, @intCast(scope.id), scratch, null);
    for (origins.capabilities.items, 0..) |cap, bit| {
        if (OriginAnalysis.contains(scratch, bit) and !self.inside(cap, scope)) return false;
    }
    return true;
}

/// Each row is a set of capability origins exposed by a value or control
/// component. Union and subtraction of a fixed delimiter scope are monotone,
/// including continuation/cell cycles and recursively retained templates.
const OriginAnalysis = struct {
    effect: p.Id,
    indices: []usize,
    capabilities: std.ArrayList(g.NodeRef) = .empty,
    width: usize = 0,
    bits: []usize = &.{},
    execution: ?[]usize = null,
    const word_bits = @bitSizeOf(usize);
    const absent = std.math.maxInt(usize);

    fn init(check: anytype, effect: p.Id) Error!OriginAnalysis {
        var self: OriginAnalysis = .{
            .effect = effect,
            .indices = try check.allocator.alloc(usize, check.state.nodes.len),
        };
        @memset(self.indices, absent);
        for (check.state.nodes) |record| try self.collect(g.Node, check, record);
        for (check.activations) |activation| if (activation) |frame|
            for (frame.bindings) |binding| try self.collect(g.Value, check, binding.value);
        self.width = std.math.divCeil(usize, self.capabilities.items.len, word_bits) catch
            return error.InvalidLength;
        const length = std.math.mul(usize, check.state.nodes.len, self.width) catch
            return error.InvalidLength;
        self.bits = try check.allocator.alloc(usize, length);
        @memset(self.bits, 0);
        return self;
    }

    inline fn collect(
        self: *OriginAnalysis,
        comptime T: type,
        check: anytype,
        value: T,
    ) Error!void {
        if (T == g.Value) {
            const shape = try a.schemaAt(check.program.schemas, value.schema);
            if (shape != .internal or shape.internal != .capability or
                shape.internal.capability != self.effect) return;
            if (value.body != .reference) return error.InvalidValue;
            const ref = value.body.reference;
            if (try check.node(ref) != .attachment) return error.InvalidState;
            if (self.indices[@intCast(ref.id)] == absent) {
                self.indices[@intCast(ref.id)] = self.capabilities.items.len;
                try self.capabilities.append(check.allocator, ref);
            }
            return;
        }
        switch (@typeInfo(T)) {
            inline .pointer, .array => |info| {
                if (info.child != u8) for (value) |item| try self.collect(
                    info.child,
                    check,
                    item,
                );
            },
            .optional => |info| if (value) |item| try self.collect(info.child, check, item),
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType|
                try self.collect(FieldType, check, @field(value, field_name)),
            .@"union" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| {
                if (std.mem.eql(u8, @tagName(value), field_name)) {
                    try self.collect(FieldType, check, @field(value, field_name));
                    return;
                }
            },
            else => {},
        }
    }

    fn row(self: OriginAnalysis, id: usize) []usize {
        return self.bits[id * self.width ..][0..self.width];
    }

    fn contains(row_: []const usize, bit: usize) bool {
        return row_[bit / word_bits] & (@as(usize, 1) << @intCast(bit % word_bits)) != 0;
    }

    fn add(row_: []usize, bit: usize) bool {
        const mask = @as(usize, 1) << @intCast(bit % word_bits);
        const changed = row_[bit / word_bits] & mask == 0;
        row_[bit / word_bits] |= mask;
        return changed;
    }

    fn merge(
        self: OriginAnalysis,
        check: anytype,
        into: []usize,
        ref: g.NodeRef,
        mask: ?g.NodeRef,
    ) Error!bool {
        _ = try check.node(ref);
        const from = self.row(@intCast(ref.id));
        var changed = false;
        for (self.capabilities.items, 0..) |cap, bit| {
            if (!contains(from, bit)) continue;
            if (mask) |scope| if (check.inside(cap, scope)) continue;
            changed = add(into, bit) or changed;
        }
        return changed;
    }

    fn valueOrigins(
        self: OriginAnalysis,
        check: anytype,
        into: []usize,
        item: g.Value,
    ) Error!bool {
        const shape = try a.schemaAt(check.program.schemas, item.schema);
        if (shape == .internal and shape.internal == .capability) {
            if (shape.internal.capability != self.effect) return false;
            if (item.body != .reference) return error.InvalidValue;
            return add(into, self.indices[@intCast(item.body.reference.id)]);
        }
        return switch (item.body) {
            .reference => |ref| self.merge(check, into, ref, null),
            .owned => |ref| self.merge(check, into, ref.node, null),
            else => false,
        };
    }

    inline fn values(
        self: OriginAnalysis,
        comptime T: type,
        check: anytype,
        into: []usize,
        input: T,
    ) Error!bool {
        if (T == g.Value) return self.valueOrigins(check, into, input);
        var changed = false;
        switch (@typeInfo(T)) {
            inline .pointer, .array => |info| {
                if (info.child != u8) for (input) |item| {
                    changed = try self.values(info.child, check, into, item) or changed;
                };
            },
            .optional => |info| if (input) |item| {
                changed = try self.values(info.child, check, into, item) or changed;
            },
            .@"struct" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| {
                changed = try self.values(
                    FieldType,
                    check,
                    into,
                    @field(input, field_name),
                ) or changed;
            },
            .@"union" => |info| inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| {
                if (std.mem.eql(u8, @tagName(input), field_name))
                    return self.values(FieldType, check, into, @field(input, field_name));
            },
            else => {},
        }
        return changed;
    }

    fn child(
        self: OriginAnalysis,
        check: anytype,
        id: usize,
        into: []usize,
        mask: ?g.NodeRef,
    ) Error!bool {
        const ref = check.children[id] orelse return false;
        return switch (try check.node(ref)) {
            .one_shot, .multi_template => |capture| blk: {
                var changed = false;
                for (capture.use_site_capabilities) |item| {
                    const shape = try a.schemaAt(check.program.schemas, item.schema);
                    if (shape != .internal or shape.internal != .capability)
                        return error.TypeMismatch;
                    if (item.body != .reference) return error.InvalidValue;
                    _ = try check.node(item.body.reference);
                    if (mask) |scope| if (check.inside(
                        item.body.reference,
                        scope,
                    )) continue;
                    changed = try self.valueOrigins(check, into, item) or changed;
                }
                break :blk changed;
            },
            .pending => false, // Environmental resume values are first-order.
            else => self.merge(check, into, ref, mask),
        };
    }

    fn delimiter(self: OriginAnalysis, check: anytype, id: usize, into: []usize) Error!bool {
        const attached = check.state.nodes[id].attachment;
        const definition = try check.handler(attached.handler);
        const reinstated = attached.phase == .active or blk: {
            const schema = check.captures[id] orelse return error.InvalidState;
            break :blk (try contracts.resumption(check.program, schema)).mode == .deep;
        };
        var mask: ?g.NodeRef = null;
        if (reinstated)
            for (definition.clauses) |clause|
                if (clause.effect == self.effect) {
                    mask = .{ .id = id };
                    break;
                };
        var changed = try self.child(check, id, into, mask);
        if (reinstated) changed = try self.merge(
            check,
            into,
            attached.handler,
            null,
        ) or changed;
        return changed;
    }

    fn positionSources(
        self: OriginAnalysis,
        check: anytype,
        id: usize,
        into: []usize,
        sources: @import("control_provenance.zig").SuspensionSources,
        returns: OriginAnalysis,
    ) Error!bool {
        var changed = false;
        if (sources.conservative) changed = try self.merge(
            check,
            into,
            .{ .id = id },
            null,
        );
        if (sources.pending_return) {
            if (check.children[id]) |child_ref| {
                changed = try returns.merge(check, into, child_ref, null) or changed;
            } else {
                // A detached or externally supplied result has no saved
                // child whose current activation proves its provenance.
                changed = try self.merge(check, into, .{ .id = id }, null) or changed;
            }
        }
        for (sources.slots) |slot| {
            var found = false;
            for (check.activations[id].?.bindings) |binding| if (binding.slot == slot) {
                changed = try self.valueOrigins(check, into, binding.value) or changed;
                found = true;
                break;
            };
            if (!found) return error.InvalidState;
        }
        return changed;
    }

    /// Interpret return sources from current saved positions. Inputs to
    /// an earlier invocation may already have been dropped or overwritten;
    /// only the child's remaining computation can justify its result.
    fn returnOrigins(self: OriginAnalysis, check: anytype) Error!OriginAnalysis {
        var result = self;
        result.bits = try check.allocator.alloc(usize, self.bits.len);
        @memset(result.bits, 0);
        var changed = true;
        while (changed) {
            changed = false;
            for (check.state.nodes, 0..) |record, id| {
                const into = result.row(id);
                switch (record) {
                    .control, .continuation => {
                        const frame = check.activations[id] orelse
                            return error.InvalidState;
                        const block_id = if (record == .control)
                            record.control.block
                        else
                            record.continuation.source_block;
                        const sources = if (check.control) |control|
                            try control.returnSources(
                                block_id,
                                @intCast(frame.position),
                                record == .continuation,
                            )
                        else
                            @import("control_provenance.zig").SuspensionSources{
                                .conservative = true,
                            };
                        changed = try self.positionSources(
                            check,
                            id,
                            into,
                            sources,
                            result,
                        ) or changed;
                    },
                    .region_scope, .protection, .injection => {
                        if (check.children[id]) |child_ref|
                            changed = try result.merge(
                                check,
                                into,
                                child_ref,
                                null,
                            ) or changed;
                    },
                    .cleanup_return => |v| {
                        const exit = (try check.node(v.exit)).exit;
                        if (exit.reason == .normal)
                            changed = try self.valueOrigins(
                                check,
                                into,
                                exit.reason.normal,
                            ) or changed;
                    },
                    // Handler return clauses, captured invocations and
                    // opaque records retain the reachable-origin bound.
                    else => changed = try self.merge(
                        check,
                        into,
                        .{ .id = id },
                        null,
                    ) or changed,
                }
            }
        }
        return result;
    }

    fn suspension(
        self: OriginAnalysis,
        check: anytype,
        id: usize,
        into: []usize,
        returns: OriginAnalysis,
    ) Error!void {
        const record = check.state.nodes[id];
        const frame = check.activations[id] orelse return error.InvalidState;
        const block_id = if (record == .control)
            record.control.block
        else
            record.continuation.source_block;
        const sources = if (check.control) |control|
            try control.suspensionSources(
                block_id,
                @intCast(frame.position),
                record == .continuation,
                self.effect,
            )
        else
            @import("control_provenance.zig").SuspensionSources{ .conservative = true };
        _ = try self.positionSources(check, id, into, sources, returns);
    }

    fn owned(self: OriginAnalysis, check: anytype, into: []usize, value: g.Value) Error!bool {
        if (value.body != .owned) return false;
        return self.merge(check, into, value.body.owned.node, null);
    }

    fn cleanup(self: OriginAnalysis, check: anytype, into: []usize, ref: g.NodeRef) Error!void {
        const record = try check.node(ref);
        if (record != .obligation) return error.InvalidState;
        const obligation = record.obligation;
        const value = obligation.cleanup orelse return error.InvalidState;
        const closure = try check.node(switch (value.body) {
            .reference => |node_ref| node_ref,
            .owned => |owned_ref| owned_ref.node,
            else => return error.InvalidValue,
        });
        if (closure != .computation) return error.InvalidState;
        const environment = try check.node(closure.computation.environment);
        if (environment != .environment) return error.InvalidState;
        const sources = if (check.control) |control|
            try control.constructorSources(closure.computation.constructor, self.effect)
        else
            @import("control_provenance.zig").InvocationSources{ .conservative = true };
        if (sources.conservative) _ = try self.merge(check, into, ref, null);
        for (sources.inputs) |input| {
            if (input < environment.environment.values.len) {
                _ = try self.valueOrigins(
                    check,
                    into,
                    environment.environment.values[@intCast(input)],
                );
            } else if (input - environment.environment.values.len == 1 and
                obligation.resource != null)
            {
                _ = try self.valueOrigins(check, into, obligation.resource.?);
            } else {
                // Supplied arguments are exit context, then resource.
                // Preserve the conservative bound for unrepresented inputs.
                _ = try self.merge(check, into, ref, null);
            }
        }
    }

    /// Discarding a container traverses only its owned fields. It never
    /// invokes a retained computation or a copied capability. A one-shot
    /// token, however, activates its captured cleanup when discarded.
    fn disposals(self: OriginAnalysis, check: anytype) Error!OriginAnalysis {
        var result = self;
        result.bits = try check.allocator.alloc(usize, self.bits.len);
        @memset(result.bits, 0);
        for (check.state.nodes, 0..) |record, id| if (record == .one_shot) {
            // Reachable origins bound recipients only after the owning
            // program establishes a possible disposal effect. Otherwise
            // a merely retained capability invents a future capture.
            if (check.control) |control| if (!control.disposalEffect(
                record.one_shot.schema,
                self.effect,
            )) continue;
            _ = try self.merge(check, result.row(id), .{ .id = id }, null);
        };
        var changed = true;
        while (changed) {
            changed = false;
            for (check.state.nodes, 0..) |record, id| {
                const into = result.row(id);
                switch (record) {
                    .aggregate => |v| for (v.fields) |value| {
                        changed = try result.owned(check, into, value) or changed;
                    },
                    .computation => |v| {
                        const environment = try check.node(v.environment);
                        if (environment != .environment) return error.InvalidState;
                        for (environment.environment.values) |value|
                            changed = try result.owned(check, into, value) or changed;
                    },
                    .package => |v| changed = try result.owned(
                        check,
                        into,
                        v.continuation,
                    ) or changed,
                    .exit => |v| {
                        if (v.reason == .normal) changed = try result.owned(
                            check,
                            into,
                            v.reason.normal,
                        ) or changed;
                        for (v.discarded) |value| changed = try result.owned(
                            check,
                            into,
                            value,
                        ) or changed;
                        if (v.outer) |outer| changed = try result.merge(
                            check,
                            into,
                            outer,
                            null,
                        ) or changed;
                    },
                    else => {},
                }
            }
        }
        return result;
    }

    /// Value reachability is the conservative fallback; executable rows
    /// instead compose current code, saved return edges and delimiters.
    /// Both use the same finite set of concrete attachment identities.
    fn executable(self: *OriginAnalysis, check: anytype) Error!OriginAnalysis {
        if (self.execution) |bits| {
            var result = self.*;
            result.bits = bits;
            return result;
        }
        var result = self.*;
        result.bits = try check.allocator.alloc(usize, self.bits.len);
        @memset(result.bits, 0);
        const disposal = try self.disposals(check);
        const returns = try self.returnOrigins(check);
        for (check.state.nodes, 0..) |record, id| {
            const into = result.row(id);
            switch (record) {
                .control, .continuation => {
                    try self.suspension(check, id, into, returns);
                    for (check.activations[id].?.bindings) |binding|
                        _ = try disposal.owned(check, into, binding.value);
                },
                .handler => |handler_| if (contracts.containsEffect(
                    check.program.handlers[@intCast(handler_.definition)].effects,
                    self.effect,
                )) {
                    _ = try self.merge(check, into, .{ .id = id }, null);
                },
                .attachment, .region_scope, .injection, .pending => {},
                .protection => |scope| try self.cleanup(check, into, scope.obligation.node),
                .cleanup_return => |v| _ = try disposal.merge(check, into, v.exit, null),
                .disposal_return => |v| for (v.values) |value| {
                    _ = try disposal.owned(check, into, value);
                },
                .unwind => |v| {
                    for (v.values) |value| _ = try disposal.owned(check, into, value);
                    if (check.state.roots.exit) |exit| _ = try disposal.merge(
                        check,
                        into,
                        exit,
                        null,
                    );
                },
                else => _ = try self.merge(check, into, .{ .id = id }, null),
            }
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (check.state.nodes, 0..) |record, id| {
                const into = result.row(id);
                switch (record) {
                    .attachment => changed = try result.delimiter(
                        check,
                        id,
                        into,
                    ) or changed,
                    .one_shot, .multi_template => |capture| changed = try result.merge(
                        check,
                        into,
                        capture.delimiter,
                        null,
                    ) or changed,
                    else => changed = try result.child(check, id, into, null) or changed,
                }
            }
        }
        self.execution = result.bits;
        return result;
    }

    fn solve(self: *OriginAnalysis, check: anytype) Error!void {
        if (self.width == 0) return;
        var changed = true;
        while (changed) {
            changed = false;
            for (check.state.nodes, 0..) |record, id| {
                const into = self.row(id);
                switch (record) {
                    .attachment => {
                        changed = try self.delimiter(check, id, into) or changed;
                        continue;
                    },
                    .one_shot, .multi_template => |capture| {
                        changed = try self.merge(
                            check,
                            into,
                            capture.delimiter,
                            null,
                        ) or changed;
                        continue;
                    },
                    .computation => |v| changed = try self.merge(
                        check,
                        into,
                        v.environment,
                        null,
                    ) or changed,
                    .protection => |v| changed = try self.merge(
                        check,
                        into,
                        v.obligation.node,
                        null,
                    ) or changed,
                    .cleanup_return => |v| changed = try self.merge(
                        check,
                        into,
                        v.exit,
                        null,
                    ) or changed,
                    .borrow => |v| changed = try self.merge(
                        check,
                        into,
                        v.resource,
                        null,
                    ) or changed,
                    .exit => |v| if (v.outer) |outer| {
                        changed = try self.merge(check, into, outer, null) or changed;
                    },
                    else => {},
                }
                changed = try self.values(g.Node, check, into, record) or changed;
                if (check.activations.len != 0) if (check.activations[id]) |frame| {
                    for (frame.bindings) |binding| changed = try self.valueOrigins(
                        check,
                        into,
                        binding.value,
                    ) or changed;
                };
                changed = try self.child(check, id, into, null) or changed;
            }
        }
    }
};
