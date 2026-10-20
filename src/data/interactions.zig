// Copyright (c) 2026 Boundary contributors. MIT license.
//! Optional finite monitors over the existing stable-slot IR. This is a may
//! language, not an interpreter, a value-equivalence proof, or a termination test.
const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const provenance = @import("control_provenance.zig");
pub const Error = provenance.Error || error{InvalidMonitor};
pub const Mask = u64;
pub fn bit(index: usize) Mask {
    return @as(Mask, 1) << @intCast(index);
}
pub const Choice = enum { program, environment, approximation };
/// Concrete phases follow stable_session transitions, not instruction attempts.
/// `instruction` is successful value completion; its declared failure is a
/// separate outcome. Cancellation uses the current control block: local perform
/// enters its clause atomically, and yield installs its successor before parking.
/// Only an external pending request keeps the originating perform as its site.
/// See docs/paper-analyses.md for the projection and physical-error boundary.
pub const Phase = enum {
    instruction,
    operation,
    reply,
    branch,
    yield,
    resumed,
    returned,
    failure,
    cancellation,
    cleanup,
};
pub const Site = struct {
    block: p.Id,
    phase: Phase,
    position: usize = 0,
    alternative: usize = 0,
    choice: Choice = .program,
    selection: ?*const provenance.Selection = null,
};
/// Projection and context functions are the consumer's explicit interpretation.
/// They borrow an immutable binding for the entire Session lifetime. Bit zero
/// is an ordinary alphabet symbol; a zero projection mask means a silent step.
pub const Monitor = struct {
    binding: *const anyopaque,
    states: usize,
    alphabet: usize,
    contexts: usize = 1,
    entry: usize = 0,
    bad: Mask,
    transitions: []const u8, // state-major total deterministic transition table
    project: *const fn (*const anyopaque, ir.Program, Site, usize) Mask,
    parameters: ?*const fn (*const anyopaque, ir.Program, p.Id, p.Id, usize) Mask = null,
};
pub const Status = enum { established, potential, demonstrated, unresolved, unrequested };
pub const Summary = struct {
    normal: Mask = 0,
    failure: Mask = 0,
    cancellation: Mask = 0,
    prefixes: Mask = 0,
    widened: bool = false,
    may_nonreturn: bool = false,
    fn join(self: *Summary, other: Summary) bool {
        const old = self.*;
        self.normal |= other.normal;
        self.failure |= other.failure;
        self.cancellation |= other.cancellation;
        self.prefixes |= other.prefixes;
        self.widened = self.widened or other.widened;
        self.may_nonreturn = self.may_nonreturn or other.may_nonreturn;
        return !std.meta.eql(old, self.*);
    }
    pub fn status(self: Summary, monitor: Monitor) Status {
        return if (self.prefixes & monitor.bad != 0) .potential else .established;
    }
};
pub const Statistics = struct {
    iterations: usize = 0,
    relations: usize = 0,
    control_states: usize = 0,
    opaque_sites: usize = 0,
};
pub const Result = struct {
    summaries: []const Summary,
    statistics: Statistics,
    monitor: Monitor,
    functions: usize,
    pub fn get(self: Result, function: p.Id, context: usize, state: usize) Summary {
        return self.summaries[
            (@as(
                usize,
                @intCast(function),
            ) * self.monitor.contexts + context) * self.monitor.states + state
        ];
    }
};
/// Query cache belongs to the borrowed provenance subject. A complete binding
/// consists of callback identity, immutable binding address, and every monitor
/// field, including transition storage. It never crosses revision/owner lifetimes.
pub const Session = struct {
    allocator: std.mem.Allocator,
    owner: *const provenance.Analysis,
    imports: []const p.Id = &.{},
    cached: std.ArrayList(Result) = .empty,
    pub fn deinit(self: *Session) void {
        for (self.cached.items) |result| self.allocator.free(result.summaries);
        self.cached.deinit(self.allocator);
    }
    pub fn analyze(self: *Session, monitor: Monitor) Error!Result {
        if (monitor.states == 0 or
            monitor.states > 64 or
            monitor.alphabet == 0 or
            monitor.alphabet > 64 or
            monitor.contexts == 0 or
            monitor.contexts > 64 or
            monitor.entry >= monitor.states or
            monitor.transitions.len != monitor.states * monitor.alphabet)
            return error.InvalidMonitor;
        for (monitor.transitions) |next| if (next >= monitor.states) return error.InvalidMonitor;
        for (self.cached.items) |result| if (same(monitor, result.monitor)) return result;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const image = self.owner.program();
        const count = std.math.mul(
            usize,
            image.functions.len,
            2 * monitor.contexts * monitor.states,
        ) catch return error.Capacity;
        const summaries = try self.allocator.alloc(Summary, count);
        errdefer self.allocator.free(summaries);
        @memset(summaries, .{});
        var engine: Engine = .{
            .allocator = arena.allocator(),
            .session = self,
            .image = image,
            .monitor = monitor,
            .summaries = summaries,
            .entries = try arena.allocator().alloc(Mask, image.blocks.len),
            .opaque_blocks = try arena.allocator().alloc(bool, image.blocks.len),
        };
        engine.selections = try arena.allocator().alloc(
            ?*const provenance.Selection,
            image.blocks.len,
        );
        engine.alphabets = try arena.allocator().alloc(?Mask, image.blocks.len);
        engine.disposals = try arena.allocator().alloc(?bool, image.functions.len);
        engine.administratives = try arena.allocator().alloc(?bool, image.handlers.len);
        @memset(engine.selections, null);
        @memset(engine.alphabets, null);
        @memset(engine.disposals, null);
        @memset(engine.administratives, null);
        for (image.blocks, 0..) |block, id| if (block.terminator == .perform) {
            engine.selections[id] = try self.owner.select(
                .{ .block = id, .role = .operation },
                block.terminator.perform.effect,
            );
        };
        @memset(engine.opaque_blocks, false);
        var changed = true;
        while (changed) {
            changed = false;
            engine.stats.iterations += 1;
            inline for (.{ false, true }) |cleanup| {
                engine.cleanup = cleanup;
                for (
                    image.functions,
                    0..,
                ) |_, function|
                    for (0..monitor.contexts) |context|
                        for (0..monitor.states) |state| {
                            const result = try engine.function(function, context, state);
                            changed = summaries[
                                engine.index(function, context, state)
                            ].join(result) or changed;
                        };
            }
        }
        for (summaries) |summary| engine.stats.relations += @popCount(
            summary.normal,
        ) + @popCount(summary.failure) + @popCount(summary.cancellation);
        for (engine.opaque_blocks) |widened| engine.stats.opaque_sites += @intFromBool(widened);
        const result: Result = .{
            .summaries = summaries,
            .statistics = engine.stats,
            .monitor = monitor,
            .functions = image.functions.len,
        };
        try self.cached.append(self.allocator, result);
        return result;
    }
};
fn same(a: Monitor, b: Monitor) bool {
    return a.binding == b.binding and
        a.states == b.states and
        a.alphabet == b.alphabet and
        a.contexts == b.contexts and
        a.entry == b.entry and
        a.bad == b.bad and
        a.transitions.ptr == b.transitions.ptr and
        a.project == b.project and
        a.parameters == b.parameters;
}
const Engine = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    image: ir.Program,
    monitor: Monitor,
    summaries: []Summary,
    entries: []Mask,
    opaque_blocks: []bool,
    pending: std.ArrayList(p.Id) = .empty,
    stats: Statistics = .{},
    selections: []?*const provenance.Selection = &.{},
    alphabets: []?Mask = &.{},
    disposals: []?bool = &.{},
    administratives: []?bool = &.{},
    // Runtime cancellation records an exit but preserves work already executing
    // under unwind. This is execution context, independent of consumer bindings.
    cleanup: bool = false,
    fn operationSelection(self: Engine, block: p.Id) *const provenance.Selection {
        return self.selections[@intCast(block)].?;
    }
    fn index(self: Engine, function_id: usize, context: usize, state: usize) usize {
        return ((@as(
            usize,
            @intFromBool(self.cleanup),
        ) * self.image.functions.len + function_id) * self.monitor.contexts + context) * self.monitor.states + state;
    }
    fn event(self: Engine, site: Site, context: usize, states: Mask) Error!Mask {
        const projected = self.monitor.project(self.monitor.binding, self.image, site, context);
        if (self.monitor.alphabet < 64 and projected >> @intCast(
            self.monitor.alphabet,
        ) != 0) return error.InvalidMonitor;
        return self.symbols(states, projected);
    }
    fn symbols(self: Engine, states: Mask, alphabet: Mask) Mask {
        if (alphabet == 0) return states;
        var result: Mask = 0;
        for (0..self.monitor.states) |state| if (states & bit(state) != 0) {
            for (0..self.monitor.alphabet) |symbol| if (alphabet & bit(symbol) != 0) {
                result |= bit(self.monitor.transitions[state * self.monitor.alphabet + symbol]);
            };
        };
        return result;
    }
    fn closure(self: Engine, states: Mask, alphabet: Mask) Mask {
        var result = states;
        while (true) {
            const next = result | self.symbols(result, alphabet);
            if (next == result) return result;
            result = next;
        }
    }
    fn widened(self: *Engine, block: p.Id, states: Mask) Summary {
        if (block < self.opaque_blocks.len) self.opaque_blocks[@intCast(block)] = true;
        const all = self.closure(states, std.math.maxInt(Mask));
        return .{
            .normal = all,
            .failure = all,
            .cancellation = all,
            .prefixes = all,
            .widened = true,
            .may_nonreturn = true,
        };
    }
    fn push(self: *Engine, edge: ir.Edge, states: Mask) Error!void {
        const entry = &self.entries[@intCast(edge.block)];
        if (states & ~entry.* == 0) return;
        entry.* |= states;
        try self.pending.append(self.allocator, edge.block);
    }
    fn calleeContexts(self: Engine, block: p.Id, callee: p.Id, context: usize) Error!Mask {
        const contexts = if (self.monitor.parameters) |parameters| parameters(
            self.monitor.binding,
            self.image,
            block,
            callee,
            context,
        ) else bit(context);
        if (contexts == 0 or (self.monitor.contexts < 64 and contexts >> @intCast(
            self.monitor.contexts,
        ) != 0)) return error.InvalidMonitor;
        return contexts;
    }
    fn call(self: *Engine, block: p.Id, callee: p.Id, context: usize, states: Mask) Error!Summary {
        if (std.mem.indexOfScalar(
            p.Id,
            self.session.imports,
            callee,
        ) != null) return self.widened(block, states);
        const contexts = try self.calleeContexts(block, callee, context);
        var result: Summary = .{ .may_nonreturn = true };
        for (0..self.monitor.contexts) |callee_context| if (contexts & bit(callee_context) != 0) {
            for (0..self.monitor.states) |state| if (states & bit(state) != 0) {
                _ = result.join(self.summaries[
                    self.index(@intCast(callee), callee_context, state)
                ]);
            };
        };
        return result;
    }
    fn invoke(self: *Engine, block: p.Id, slot: p.Id, context: usize, states: Mask) Error!Summary {
        const constructors = try self.session.owner.constructorsAt(block, slot);
        var result: Summary = .{};
        if (constructors.conservative) _ = result.join(self.widened(block, states));
        for (constructors.ids) |constructor| _ = result.join(try self.call(
            block,
            self.image.constructors[@intCast(constructor)].function,
            context,
            states,
        ));
        return result;
    }
    fn cleanupInvoke(
        self: *Engine,
        block: p.Id,
        slot: p.Id,
        context: usize,
        states: Mask,
    ) Error!Summary {
        const previous = self.cleanup;
        self.cleanup = true;
        defer self.cleanup = previous;
        return self.invoke(block, slot, context, states);
    }
    fn cancellation(
        self: *Engine,
        out: *Summary,
        block: p.Id,
        context: usize,
        incoming: Mask,
    ) Error!Mask {
        var states = incoming;
        while (true) {
            const cancelled = try self.abrupt(block, context, states, .cancellation);
            _ = out.join(cancelled);
            if (!self.cleanup) return states;
            // Repeated cancellation can be observed while cleanup keeps running.
            // Close those observations before continuing the same instruction.
            const continued = states | cancelled.cancellation;
            if (continued == states) return states;
            states = continued;
        }
    }
    fn propagate(self: *Engine, out: *Summary, result: Summary, edge: ir.Edge) Error!void {
        var exceptional = result;
        exceptional.normal = 0;
        _ = out.join(exceptional);
        try self.push(edge, result.normal);
    }
    fn disposable(self: *Engine, function_id: p.Id) Error!bool {
        const cached = &self.disposals[@intCast(function_id)];
        if (cached.*) |known| return known;
        var result = false;
        for (self.image.functions[@intCast(function_id)].layout.slots) |schema| {
            if (try self.session.owner.mayRunDisposal(schema)) {
                result = true;
                break;
            }
        }
        cached.* = result;
        return result;
    }
    fn abrupt(
        self: *Engine,
        block: p.Id,
        context: usize,
        states: Mask,
        phase: Phase,
    ) Error!Summary {
        var result: Summary = .{ .normal = states, .prefixes = states };
        if (try self.disposable(self.image.blocks[@intCast(block)].function)) result = self.widened(
            block,
            states,
        );
        const exits = try self.event(
            .{ .block = block, .phase = phase, .choice = .environment },
            context,
            result.normal,
        );
        // Cleanup prefixes and post-event exits are different observations:
        // a terminal event can leave a bad state reached during cleanup.
        result.prefixes |= exits;
        result.normal = 0;
        result.failure = if (phase == .failure) exits else 0;
        result.cancellation = if (phase == .cancellation) exits else 0;
        return result;
    }
    /// Checked administrative deep clauses resume exactly once on every path.
    /// Their surrounding steps must be projection-silent and cannot suspend,
    /// fail, clone, inject, dispose, or invoke arbitrary work. Unknown handlers
    /// are represented by the full monitor closure, never a wildcard event.
    fn administrative(self: *Engine, handler_id: p.Id) Error!bool {
        const cached = &self.administratives[@intCast(handler_id)];
        if (cached.*) |known| return known;
        const result = try self.deriveAdministrative(handler_id);
        cached.* = result;
        return result;
    }
    fn deriveAdministrative(self: *Engine, handler_id: p.Id) Error!bool {
        const handler = self.image.handlers[@intCast(handler_id)];
        if (handler.mode != .deep or handler.state.len != 0) return false;
        if (!try self.silent(handler.return_function, false)) return false;
        for (handler.clauses) |clause| {
            const signature = try @import("contracts.zig").resumption(
                self.image,
                clause.resumption,
            );
            if (signature.use == .multi or !try self.silent(clause.function, true)) return false;
        }
        return true;
    }
    fn silent(self: *Engine, function_id: p.Id, resumes: bool) Error!bool {
        if (try self.disposable(function_id)) return false;
        var resume_count: usize = 0;
        const function_ = self.image.functions[@intCast(function_id)];
        if (resumes and function_.inputs.len != 2) return false;
        const token: ?p.Id = if (resumes) function_.inputs[1] else null;
        // Deliberately narrow: a straight-line chain, with exactly one resume.
        var block_id = self.image.functions[@intCast(function_id)].entry;
        var left = self.image.blocks.len + 1;
        while (left != 0) : (left -= 1) {
            const block = self.image.blocks[@intCast(block_id)];
            // A numeric runtime quantum may stop at any erased control point.
            for (0..self.monitor.contexts) |context| if (self.monitor.project(
                self.monitor.binding,
                self.image,
                .{ .block = block_id, .phase = .cancellation, .choice = .environment },
                context,
            ) != 0) return false;
            for (block.instructions, 0..) |instruction, position| {
                if (!@import("total_clause.zig").instruction(instruction)) return false;
                if (token) |slot| if (instruction.destination == slot or std.mem.indexOfScalar(
                    p.Id,
                    instruction.operands,
                    slot,
                ) != null) return false;
                for (0..self.monitor.contexts) |context| if (self.monitor.project(
                    self.monitor.binding,
                    self.image,
                    .{ .block = block_id, .phase = .instruction, .position = position },
                    context,
                ) != 0) return false;
            }
            switch (block.terminator) {
                .jump => |edge| {
                    if (token) |slot|
                        for (edge.assignments) |assignment| {
                            if (assignment.destination == slot or
                                (assignment.source == .slot and
                                    assignment.source.slot == slot))
                                return false;
                        };
                    block_id = edge.block;
                },
                .resume_value => |value| {
                    if (token == null or value.resumption != token.?) return false;
                    for (value.next.assignments) |assignment| {
                        if (assignment.destination == token.? or
                            (assignment.source == .slot and
                                assignment.source.slot == token.?))
                            return false;
                    }
                    resume_count += 1;
                    block_id = value.next.block;
                },
                .return_value => {
                    for (0..self.monitor.contexts) |context| if (self.monitor.project(
                        self.monitor.binding,
                        self.image,
                        .{ .block = block_id, .phase = .returned },
                        context,
                    ) != 0) return false;
                    return resume_count == @intFromBool(resumes);
                },
                else => return false,
            }
        }
        return false;
    }
    /// A static continuation slice bounds an unsupported local clause's
    /// alphabet. It includes every compatible captured suffix, callee, clause,
    /// return continuation and owned cleanup. Unknown applications/imports lose
    /// the bound. Multi-shot repeats this suffix language, never its producer
    /// prefix merely because the template is resumed more than once.
    fn remainingAlphabet(self: *Engine, origin: p.Id) Error!Mask {
        if (self.alphabets[@intCast(origin)]) |known| return known;
        var slice = Slice{
            .engine = self,
            .seen = try self.allocator.alloc(bool, self.image.blocks.len),
        };
        @memset(slice.seen, false);
        const operation = self.image.blocks[@intCast(origin)].terminator.perform;
        // A local dispatch has no cancellable origin state after its operation
        // event: cancellation then belongs to the entered clause. External
        // requests (no bodies, known empty targets) use the precise transfer.
        try slice.add(operation.next.block);
        try slice.handlers(origin, operation.effect);
        try slice.addEvent(.{
            .block = origin,
            .phase = .reply,
            .choice = .environment,
            .selection = self.operationSelection(origin),
        });
        while (slice.pending.pop()) |id| try slice.block(id);
        const result = if (slice.unbounded) std.math.maxInt(Mask) else slice.alphabet;
        self.alphabets[@intCast(origin)] = result;
        return result;
    }
    fn resumeAlphabet(self: *Engine, block_id: p.Id, slot: p.Id) Error!Mask {
        if (self.alphabets[@intCast(block_id)]) |known| return known;
        var slice = Slice{
            .engine = self,
            .seen = try self.allocator.alloc(bool, self.image.blocks.len),
        };
        @memset(slice.seen, false);
        try slice.resumed(block_id, slot);
        const term = self.image.blocks[@intCast(block_id)].terminator;
        if (term == .resume_computation) try slice.invoke_(
            block_id,
            term.resume_computation.computation,
        );
        if (term == .resume_with) {
            const handler = self.image.handlers[@intCast(term.resume_with.handler)];
            try slice.function_(handler.return_function);
            for (handler.clauses) |clause| try slice.function_(clause.function);
        }
        while (slice.pending.pop()) |id| try slice.block(id);
        const result = if (slice.unbounded) std.math.maxInt(Mask) else slice.alphabet;
        self.alphabets[@intCast(block_id)] = result;
        return result;
    }
    fn resumeSummary(
        self: *Engine,
        block_id: p.Id,
        slot: p.Id,
        context: usize,
        incoming: Mask,
    ) Error!Summary {
        const allowed = try self.resumeAlphabet(block_id, slot);
        const states = try self.event(.{ .block = block_id, .phase = .resumed }, context, incoming);
        var result = self.widened(block_id, 0);
        const all = self.closure(states, allowed);
        result.normal = all;
        result.failure = all;
        result.cancellation = all;
        result.prefixes = all;
        return result;
    }
    const Slice = struct {
        engine: *Engine,
        seen: []bool,
        pending: std.ArrayList(p.Id) = .empty,
        alphabet: Mask = 0,
        unbounded: bool = false,
        fn add(self: *Slice, block_id: p.Id) Error!void {
            if (block_id >= self.seen.len) {
                self.unbounded = true;
                return;
            }
            if (self.seen[@intCast(block_id)]) return;
            self.seen[@intCast(block_id)] = true;
            try self.pending.append(self.engine.allocator, block_id);
        }
        fn function_(self: *Slice, id: p.Id) Error!void {
            if (std.mem.indexOfScalar(p.Id, self.engine.session.imports, id) != null) {
                self.unbounded = true;
                return;
            }
            try self.add(self.engine.image.functions[@intCast(id)].entry);
        }
        fn invoke_(self: *Slice, block_id: p.Id, slot: p.Id) Error!void {
            const constructors = try self.engine.session.owner.constructorsAt(block_id, slot);
            if (constructors.conservative) self.unbounded = true;
            for (constructors.ids) |constructor| try self.function_(
                self.engine.image.constructors[
                    @intCast(constructor)
                ].function,
            );
        }
        fn handlers(self: *Slice, block_id: p.Id, _: p.Id) Error!void {
            const selection = self.engine.operationSelection(block_id);
            if (selection.knowledge().conservative) self.unbounded = true;
            for (selection.targets()) |target| {
                try self.function_(target.function);
                try self.function_(
                    self.engine.image.handlers[
                        @intCast(target.handler)
                    ].return_function,
                );
            }
        }
        fn addEvent(self: *Slice, site: Site) Error!void {
            for (0..self.engine.monitor.contexts) |context|
                self.alphabet |= self.engine.monitor.project(
                    self.engine.monitor.binding,
                    self.engine.image,
                    site,
                    context,
                );
        }
        fn resumed(self: *Slice, id: p.Id, slot: p.Id) Error!void {
            const image = self.engine.image;
            const block_ = image.blocks[@intCast(id)];
            const schema = image.functions[@intCast(block_.function)].layout.slots[@intCast(slot)];
            const signature = try @import("contracts.zig").resumption(image, schema);
            // All operation sites with this nominal family are safe may-sources.
            // A template's suffix starts after the original operation entry.
            var found = false;
            for (
                image.blocks,
                0..,
            ) |candidate, candidate_id|
                if (candidate.terminator == .perform and
                    candidate.terminator.perform.effect == signature.effect)
                {
                    found = true;
                    try self.add(candidate.terminator.perform.next.block);
                    try self.handlers(candidate_id, signature.effect);
                    try self.addEvent(.{
                        .block = candidate_id,
                        .phase = .reply,
                        .choice = .environment,
                        .selection = self.engine.operationSelection(candidate_id),
                    });
                };
            if (!found or self.engine.session.imports.len != 0) self.unbounded = true;
            try self.addEvent(.{ .block = id, .phase = .resumed });
        }
        fn callers(self: *Slice, function_id: p.Id) Error!void {
            // Return to every compatible static caller is a widening bound,
            // not a claim that these cross-call paths are feasible witnesses.
            for (self.engine.image.blocks, 0..) |candidate, id|
                switch (candidate.terminator) {
                    .call => |v| if (v.function == function_id) {
                        try self.add(v.next.block);
                    },
                    .apply => |v| try self.add(v.next.block),
                    .handle => |v| {
                        try self.function_(
                            self.engine.image.handlers[
                                @intCast(v.handler)
                            ].return_function,
                        );
                        try self.add(v.next.block);
                    },
                    .with_region => |v| try self.add(v.next.block),
                    .protect => |v| {
                        try self.invoke_(id, v.cleanup);
                        try self.add(v.next.block);
                    },
                    .dispose => |v| try self.add(v.next.block),
                    inline .resume_value, .resume_computation => |v| {
                        try self.resumed(id, v.resumption);
                        try self.add(v.next.block);
                    },
                    .resume_with => |v| {
                        try self.resumed(id, v.resumption);
                        const handler = self.engine.image.handlers[@intCast(v.handler)];
                        try self.function_(handler.return_function);
                        for (handler.clauses) |clause| try self.function_(clause.function);
                        try self.add(v.next.block);
                    },
                    .return_value,
                    .fail,
                    .jump,
                    .unpack_product,
                    .branch,
                    .switch_variant,
                    .perform,
                    .yield_value,
                    => {},
                };
        }
        fn block(self: *Slice, id: p.Id) Error!void {
            const value = self.engine.image.blocks[@intCast(id)];
            // Cancellation/failure can unwind an ambient frame even if this
            // suffix never returns. Include its return/unwind actions as a may
            // bound, without replaying the caller's producer instructions/body.
            try self.callers(value.function);
            if (try self.engine.disposable(value.function)) self.unbounded = true;
            for (
                value.instructions,
                0..,
            ) |_, position| try self.addEvent(.{
                .block = id,
                .phase = .instruction,
                .position = position,
            });
            try self.addEvent(.{ .block = id, .phase = .failure, .choice = .environment });
            try self.addEvent(.{ .block = id, .phase = .cancellation, .choice = .environment });
            switch (value.terminator) {
                .return_value => {
                    try self.addEvent(.{ .block = id, .phase = .returned });
                },
                .fail => {},
                .jump => |v| try self.add(v.block),
                .unpack_product => |v| try self.add(v.next.block),
                .branch => |v| {
                    try self.addEvent(.{ .block = id, .phase = .branch, .alternative = 0 });
                    try self.addEvent(.{ .block = id, .phase = .branch, .alternative = 1 });
                    try self.add(v.when_true.block);
                    try self.add(v.when_false.block);
                },
                .switch_variant => |v| for (v.cases, 0..) |edge, alternative| {
                    try self.addEvent(.{
                        .block = id,
                        .phase = .branch,
                        .alternative = alternative,
                    });
                    try self.add(edge.block);
                },
                .call => |v| {
                    try self.function_(v.function);
                    try self.add(v.next.block);
                },
                .apply => |v| {
                    try self.invoke_(id, v.computation);
                    try self.add(v.next.block);
                },
                .with_region => |v| {
                    try self.invoke_(id, v.body);
                    try self.add(v.next.block);
                },
                .handle => |v| {
                    try self.invoke_(id, v.body);
                    const handler = self.engine.image.handlers[@intCast(v.handler)];
                    try self.function_(handler.return_function);
                    for (handler.clauses) |clause| try self.function_(clause.function);
                    try self.add(v.next.block);
                },
                .perform => |v| {
                    const selected = self.engine.operationSelection(id);
                    try self.addEvent(
                        .{
                            .block = id,
                            .phase = .operation,
                            .selection = selected,
                            .choice = if (selected.knowledge().conservative)
                                .approximation
                            else
                                .program,
                        },
                    );
                    try self.addEvent(.{
                        .block = id,
                        .phase = .reply,
                        .selection = selected,
                        .choice = .environment,
                    });
                    try self.handlers(id, v.effect);
                    for (v.bodies) |slot| try self.invoke_(id, slot);
                    try self.add(v.next.block);
                },
                .yield_value => |v| {
                    try self.addEvent(.{ .block = id, .phase = .yield, .choice = .environment });
                    try self.add(v.block);
                },
                .resume_value => |v| {
                    try self.resumed(id, v.resumption);
                    try self.add(v.next.block);
                },
                .resume_with => |v| {
                    try self.resumed(id, v.resumption);
                    const handler = self.engine.image.handlers[@intCast(v.handler)];
                    try self.function_(handler.return_function);
                    for (handler.clauses) |clause| try self.function_(clause.function);
                    try self.add(v.next.block);
                },
                .resume_computation => |v| {
                    try self.resumed(id, v.resumption);
                    try self.invoke_(id, v.computation);
                    try self.add(v.next.block);
                },
                .protect => |v| {
                    try self.invoke_(id, v.body);
                    try self.invoke_(id, v.cleanup);
                    try self.add(v.next.block);
                },
                .dispose => |v| {
                    if (try self.engine.disposable(value.function)) self.unbounded = true;
                    try self.addEvent(.{ .block = id, .phase = .cleanup });
                    try self.add(v.next.block);
                },
            }
        }
    };
    fn function(self: *Engine, function_id: usize, context: usize, state: usize) Error!Summary {
        @memset(self.entries, 0);
        self.pending.clearRetainingCapacity();
        var out: Summary = .{ .prefixes = bit(state) };
        if (std.mem.indexOfScalar(
            p.Id,
            self.session.imports,
            function_id,
        ) != null) return self.widened(self.image.functions[function_id].entry, bit(state));
        try self.push(.{ .block = self.image.functions[function_id].entry }, bit(state));
        while (self.pending.pop()) |block_id| {
            self.stats.control_states += 1;
            const block = self.image.blocks[@intCast(block_id)];
            var states = self.entries[@intCast(block_id)];
            // Every edge arrival is itself a prefix, even when the next event
            // leaves a nonabsorbing bad state.
            out.prefixes |= states;
            // Cancellation at any control prefix; latent cleanup may run first.
            states = try self.cancellation(&out, block_id, context, states);
            const latent_disposal = try self.disposable(block.function);
            out.widened = out.widened or latent_disposal;
            out.may_nonreturn = out.may_nonreturn or latent_disposal;
            if (latent_disposal) states = self.widened(block_id, states).normal;
            out.prefixes |= states;
            for (block.instructions, 0..) |instruction, position| {
                if (instruction.failures.len != 0) {
                    _ = out.join(try self.abrupt(block_id, context, states, .failure));
                }
                states = try self.event(
                    .{ .block = block_id, .phase = .instruction, .position = position },
                    context,
                    states,
                );
                out.prefixes |= states;
                states = try self.cancellation(&out, block_id, context, states);
            }
            switch (block.terminator) {
                .return_value => {
                    const returned = try self.event(
                        .{ .block = block_id, .phase = .returned },
                        context,
                        states,
                    );
                    out.normal |= returned;
                    out.prefixes |= returned;
                },
                .fail => {
                    _ = out.join(try self.abrupt(block_id, context, states, .failure));
                },
                .jump => |edge| {
                    out.may_nonreturn = true;
                    try self.push(edge, states);
                },
                .unpack_product => |v| {
                    out.may_nonreturn = out.may_nonreturn or v.next.block <= block_id;
                    try self.push(v.next, states);
                },
                .branch => |v| {
                    out.may_nonreturn = out.may_nonreturn or
                        v.when_true.block <= block_id or
                        v.when_false.block <= block_id;
                    try self.push(
                        v.when_true,
                        try self.event(
                            .{ .block = block_id, .phase = .branch, .alternative = 0 },
                            context,
                            states,
                        ),
                    );
                    try self.push(
                        v.when_false,
                        try self.event(
                            .{ .block = block_id, .phase = .branch, .alternative = 1 },
                            context,
                            states,
                        ),
                    );
                },
                .switch_variant => |v| for (v.cases, 0..) |edge, alternative| {
                    out.may_nonreturn = out.may_nonreturn or edge.block <= block_id;
                    try self.push(
                        edge,
                        try self.event(
                            .{ .block = block_id, .phase = .branch, .alternative = alternative },
                            context,
                            states,
                        ),
                    );
                },
                .call => |v| try self.propagate(
                    &out,
                    try self.call(block_id, v.function, context, states),
                    v.next,
                ),
                .apply => |v| try self.propagate(
                    &out,
                    try self.invoke(block_id, v.computation, context, states),
                    v.next,
                ),
                .with_region => |v| try self.propagate(
                    &out,
                    try self.invoke(block_id, v.body, context, states),
                    v.next,
                ),
                .handle => |v| {
                    const body = try self.invoke(block_id, v.body, context, states);
                    // General clauses may abort to the delimiter. Ordinary
                    // returns also enter the return function, whose silent steps
                    // can still add cancellation exits.
                    try self.propagate(&out, body, v.next);
                    try self.propagate(
                        &out,
                        try self.call(
                            block_id,
                            self.image.handlers[@intCast(v.handler)].return_function,
                            context,
                            body.normal,
                        ),
                        v.next,
                    );
                },
                .perform => |v| {
                    const selection = self.operationSelection(block_id);
                    states = try self.event(
                        .{
                            .block = block_id,
                            .phase = .operation,
                            .selection = selection,
                            .choice = if (selection.knowledge().conservative)
                                .approximation
                            else
                                .program,
                        },
                        context,
                        states,
                    );
                    out.prefixes |= states;
                    var precise = !selection.knowledge().conservative and v.bodies.len == 0;
                    for (selection.targets()) |target|
                        precise = precise and
                            try self.administrative(target.handler);
                    if (precise) {
                        states = try self.cancellation(&out, block_id, context, states);
                        _ = out.join(try self.abrupt(block_id, context, states, .failure));
                        out.may_nonreturn = true;
                        if (selection.targets().len != 0) {
                            // Every erased clause prefix is projection-silent,
                            // including cancellation, but remains cancellable.
                            out.cancellation |= states;
                            var resumed_states: Mask = 0;
                            for (selection.targets()) |target| {
                                var cursor = self.image.functions[@intCast(target.function)].entry;
                                while (self.image.blocks[
                                    @intCast(cursor)
                                ].terminator != .resume_value) cursor = self.image.blocks[
                                    @intCast(cursor)
                                ].terminator.jump.block;
                                const contexts = try self.calleeContexts(
                                    block_id,
                                    target.function,
                                    context,
                                );
                                for (0..self.monitor.contexts) |clause_context| if (contexts & bit(
                                    clause_context,
                                ) != 0) {
                                    resumed_states |= try self.event(
                                        .{ .block = cursor, .phase = .resumed },
                                        clause_context,
                                        states,
                                    );
                                };
                            }
                            states = resumed_states;
                            out.prefixes |= states;
                        }
                        states = try self.event(
                            .{
                                .block = block_id,
                                .phase = .reply,
                                .selection = selection,
                                .choice = .environment,
                            },
                            context,
                            states,
                        );
                        out.prefixes |= states;
                        try self.push(v.next, states);
                    } else {
                        const allowed = try self.remainingAlphabet(block_id);
                        var hidden = self.widened(block_id, 0);
                        const all = self.closure(states, allowed);
                        hidden.normal = all;
                        hidden.failure = all;
                        hidden.cancellation = all;
                        hidden.prefixes = all;
                        // Aborting clauses can bypass the captured suffix.
                        _ = out.join(hidden);
                        try self.propagate(&out, hidden, v.next);
                    }
                },
                .yield_value => |edge| {
                    states = try self.event(
                        .{ .block = block_id, .phase = .yield, .choice = .environment },
                        context,
                        states,
                    );
                    out.prefixes |= states;
                    out.may_nonreturn = true;
                    try self.push(edge, states);
                },
                .protect => |v| {
                    const body = try self.invoke(block_id, v.body, context, states);
                    out.prefixes |= body.prefixes;
                    out.widened = out.widened or body.widened;
                    out.may_nonreturn = out.may_nonreturn or body.may_nonreturn;
                    const normal = try self.cleanupInvoke(
                        block_id,
                        v.cleanup,
                        context,
                        body.normal,
                    );
                    try self.propagate(&out, normal, v.next);
                    const failed = try self.cleanupInvoke(
                        block_id,
                        v.cleanup,
                        context,
                        body.failure,
                    );
                    // Cancellation is metadata when the primary exit failed.
                    out.failure |= failed.normal | failed.failure | failed.cancellation;
                    out.prefixes |= failed.prefixes;
                    const cancel = try self.cleanupInvoke(
                        block_id,
                        v.cleanup,
                        context,
                        body.cancellation,
                    );
                    out.cancellation |= cancel.normal | cancel.failure | cancel.cancellation;
                    out.prefixes |= cancel.prefixes;
                    out.widened = out.widened or failed.widened or cancel.widened;
                    out.may_nonreturn = out.may_nonreturn or
                        failed.may_nonreturn or
                        cancel.may_nonreturn;
                },
                // Retained continuation and injected computation protocols need
                // a checked library reduction. Unrecognized uses include every
                // finite projected sequence and all possible exit kinds.
                .resume_value => |v| try self.propagate(
                    &out,
                    try self.resumeSummary(block_id, v.resumption, context, states),
                    v.next,
                ),
                .resume_with => |v| try self.propagate(
                    &out,
                    try self.resumeSummary(block_id, v.resumption, context, states),
                    v.next,
                ),
                .resume_computation => |v| try self.propagate(
                    &out,
                    try self.resumeSummary(block_id, v.resumption, context, states),
                    v.next,
                ),
                .dispose => |v| try self.propagate(&out, self.widened(block_id, states), v.next),
            }
        }
        // A cancellation recorded during cleanup can become the eventual
        // primary exit after its remaining normal/failing work. Retaining the
        // ordinary exits as well is an explicit overapproximation.
        if (self.cleanup) out.cancellation |= out.normal | out.failure;
        return out;
    }
};

/// Finite phase transfers supplied only by an implementation checker in this
/// private module family. A graph is an abstraction, never admission evidence.
pub const PhaseEdge = struct { from: usize, to: usize, site: Site };
pub const PhaseGraph = struct {
    subject: ir.Program,
    nodes: usize,
    entry: usize,
    edges: []const PhaseEdge,
    normal: usize,
    failure: usize,
    cancellation: usize,
    pub fn analyze(self: PhaseGraph, allocator: std.mem.Allocator, monitor: Monitor) Error!Summary {
        const states = try allocator.alloc(Mask, self.nodes);
        defer allocator.free(states);
        @memset(states, 0);
        states[self.entry] = bit(monitor.entry);
        var result: Summary = .{ .may_nonreturn = true };
        var changed = true;
        while (changed) {
            changed = false;
            for (self.edges) |edge| {
                if (edge.from >= self.nodes or edge.to >= self.nodes) return error.InvalidMonitor;
                const alphabet = monitor.project(monitor.binding, self.subject, edge.site, 0);
                var next: Mask = 0;
                if (alphabet == 0) {
                    next = states[edge.from];
                } else {
                    for (0..monitor.states) |state| {
                        if (states[edge.from] & bit(state) == 0) continue;
                        for (0..monitor.alphabet) |symbol| if (alphabet & bit(symbol) != 0) {
                            next |= bit(monitor.transitions[state * monitor.alphabet + symbol]);
                        };
                    }
                }
                if (next & ~states[edge.to] != 0) {
                    states[edge.to] |= next;
                    changed = true;
                }
            }
        }
        for (states) |set| result.prefixes |= set;
        result.normal = states[self.normal];
        result.failure = states[self.failure];
        result.cancellation = states[self.cancellation];
        return result;
    }
    /// Independent NFA membership for concrete projected finite traces. Silent
    /// transfers close before/after each symbol; a missing edge is observable.
    pub fn contains(
        self: PhaseGraph,
        allocator: std.mem.Allocator,
        monitor: Monitor,
        trace: []const u8,
    ) Error!bool {
        var current = try allocator.alloc(bool, self.nodes);
        defer allocator.free(current);
        var next = try allocator.alloc(bool, self.nodes);
        defer allocator.free(next);
        @memset(current, false);
        current[self.entry] = true;
        self.silentClosure(monitor, current);
        for (trace) |symbol| {
            if (symbol >= monitor.alphabet) return error.InvalidMonitor;
            @memset(next, false);
            for (self.edges) |edge| if (current[edge.from] and monitor.project(
                monitor.binding,
                self.subject,
                edge.site,
                0,
            ) & bit(symbol) != 0) {
                next[edge.to] = true;
            };
            self.silentClosure(monitor, next);
            const swap = current;
            current = next;
            next = swap;
        }
        for (current) |present| if (present) return true;
        return false;
    }
    fn silentClosure(self: PhaseGraph, monitor: Monitor, states: []bool) void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.edges) |edge| if (states[edge.from] and !states[edge.to] and monitor.project(
                monitor.binding,
                self.subject,
                edge.site,
                0,
            ) == 0) {
                states[edge.to] = true;
                changed = true;
            };
        }
    }
};
