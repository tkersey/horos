// Copyright (c) 2026 Boundary contributors. MIT license.
//! Checked finite reduction of the authored counter/owned-exchange construction.
//! A contract selects actual nominal declarations. Names alone establish nothing:
//! every reachable function, constructor, transfer, operand and reply relation
//! below is checked against the admitted stable-slot records. Other shapes are
//! unresolved and remain ordinarily admissible.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const provenance = @import("control_provenance.zig");
const interaction = @import("interactions.zig");
const Error = interaction.Error || error{UnrecognizedService};
pub const Contract = struct { command: []const u8, reply: []const u8, finalizer: []const u8 };
pub const Roles = struct {
    entry: p.Id,
    driver: p.Id,
    worker: p.Id,
    producer: p.Id,
    handler: p.Id,
    region: p.Id,
    cell_schema: p.Id,
    command: p.Id,
    reply: p.Id,
    finalizer: p.Id,
    offer: p.Id,
    request_site: p.Id,
    reply_site: p.Id,
    finalizer_site: p.Id,
    resume_site: p.Id,
    suspension_site: p.Id,
    close_site: p.Id,
    initial_offer_site: p.Id,
    local_reply_site: p.Id,
    reply_matches: bool,
};
const Checked = struct { owner: *const provenance.Analysis, roles: Roles };
const Checker = struct {
    allocator: std.mem.Allocator,
    owner: *const provenance.Analysis,
    image: ir.Program,
    blocks: []bool,
    functions: []bool,
    fn require(ok: bool) Error!void {
        if (!ok) return error.UnrecognizedService;
    }
    fn function(self: *Checker, id: p.Id, inputs: usize) Error!ir.Function {
        try require(id < self.image.functions.len and !self.functions[@intCast(id)]);
        self.functions[@intCast(id)] = true;
        const result = self.image.functions[@intCast(id)];
        try require(result.inputs.len == inputs);
        return result;
    }
    fn block(self: *Checker, id: p.Id, function_id: p.Id) Error!Cursor {
        try require(id < self.image.blocks.len and !self.blocks[@intCast(id)]);
        const value = self.image.blocks[@intCast(id)];
        try require(value.function == function_id);
        self.blocks[@intCast(id)] = true;
        return .{ .checker = self, .id = id, .value = value };
    }
    fn effect(self: Checker, identity: []const u8) Error!p.Id {
        var found: ?p.Id = null;
        for (
            self.image.effects,
            0..,
        ) |effect_, id| if (std.mem.eql(u8, effect_.identity, identity)) {
            try require(found == null);
            found = id;
        };
        return found orelse error.UnrecognizedService;
    }
    fn constructor(self: Checker, instruction: ir.Instruction, captures: []const p.Id) Error!p.Id {
        try require(instruction.opcode == .computation and std.mem.eql(
            p.Id,
            instruction.operands,
            captures,
        ) and instruction.failures.len == 0);
        return self.image.constructors[@intCast(instruction.immediate)].function;
    }
    fn returned(self: *Checker, function_id: p.Id, edge: ir.Edge) Error!void {
        const slot = try resultSlot(edge);
        var block_ = try self.block(edge.block, function_id);
        try block_.ret(slot);
    }
    fn resultSlot(edge: ir.Edge) Error!p.Id {
        try require(edge.assignments.len == 1 and edge.assignments[0].source == .returned);
        return edge.assignments[0].destination;
    }
    fn moved(edge: ir.Edge, from: p.Id) Error!p.Id {
        try require(
            edge.assignments.len == 1 and
                edge.assignments[0].source == .slot and
                edge.assignments[0].source.slot == from,
        );
        return edge.assignments[0].destination;
    }
    fn constant(self: Checker, instruction: ir.Instruction, value: u64) Error!void {
        try require(
            instruction.opcode == .constant and
                instruction.operands.len == 0 and
                instruction.failures.len == 0,
        );
        const literal = self.image.constants[@intCast(instruction.immediate)];
        try require(
            self.image.schemas[
                @intCast(literal.schema)
            ] == .u64 and literal.bytes.len == 8 and std.mem.readInt(
                u64,
                literal.bytes[0..8],
                .little,
            ) == value,
        );
    }
    fn unit(self: Checker, instruction: ir.Instruction) Error!void {
        try require(
            instruction.opcode == .constant and
                instruction.operands.len == 0 and
                instruction.failures.len == 0,
        );
        const literal = self.image.constants[@intCast(instruction.immediate)];
        try require(
            self.image.schemas[
                @intCast(literal.schema)
            ] == .unit and literal.bytes.len == 0,
        );
    }
    fn exchange(self: *Checker, handler_id: p.Id) Error!p.Id {
        const handler = self.image.handlers[@intCast(handler_id)];
        try require(handler.mode == .deep and handler.clauses.len == 1 and handler.state.len == 0);
        const clause = handler.clauses[0];
        const signature = try @import("contracts.zig").resumption(self.image, clause.resumption);
        try require(
            signature.use == .linear and
                signature.mode == .deep and
                signature.obligations and
                signature.owned_regions.len == 1 and
                signature.handled.len == 1 and
                signature.handled[0] == clause.effect,
        );
        const returns = try self.function(handler.return_function, 1);
        var returned_ = try self.block(returns.entry, handler.return_function);
        const answer = try returned_.op(.variant, &.{returns.inputs[0]}, 0);
        try returned_.ret(answer);
        const function_ = try self.function(clause.function, 2);
        var first = try self.block(function_.entry, clause.function);
        const package = try first.op(.package, &.{function_.inputs[1]}, 0);
        const package_edge = try first.term(.jump);
        const package_slot = try moved(package_edge.jump, package);
        var second = try self.block(package_edge.jump.block, clause.function);
        const product = try second.op(.product, &.{ function_.inputs[0], package_slot }, 0);
        const product_edge = try second.term(.jump);
        const product_slot = try moved(product_edge.jump, product);
        var third = try self.block(product_edge.jump.block, clause.function);
        const yielded = try third.op(.variant, &.{product_slot}, 1);
        try third.ret(yielded);
        return clause.effect;
    }
    /// The reduction below names values by slots. Require fresh definitions
    /// within each activation so a later same-typed write cannot silently change
    /// a retained request, state owner or previous-counter value. A phi may have
    /// several incoming edges, all defining that slot at the same target block.
    fn freshDefinitions(self: *Checker) Error!void {
        const Definitions = struct {
            owners: []?p.Id,
            fn fresh(self_: @This(), slot: p.Id) Error!void {
                try require(self_.owners[@intCast(slot)] == null);
                self_.owners[@intCast(slot)] = std.math.maxInt(p.Id);
            }
            fn edge(self_: @This(), value: ir.Edge) Error!void {
                for (value.assignments) |assignment| {
                    const owner = &self_.owners[@intCast(assignment.destination)];
                    try require(owner.* == null or owner.*.? == value.block);
                    owner.* = value.block;
                }
            }
        };
        for (self.image.functions, 0..) |function_, id| {
            const owners = try self.allocator.alloc(?p.Id, function_.layout.slots.len);
            defer self.allocator.free(owners);
            @memset(owners, null);
            const definitions: Definitions = .{ .owners = owners };
            for (function_.inputs) |input| try definitions.fresh(input);
            for (self.image.blocks) |block_| if (block_.function == id) {
                for (block_.instructions) |instruction| try definitions.fresh(
                    instruction.destination,
                );
                switch (block_.terminator) {
                    .return_value, .fail => {},
                    .jump, .yield_value => |edge| try definitions.edge(edge),
                    .branch => |branch| {
                        try definitions.edge(branch.when_true);
                        try definitions.edge(branch.when_false);
                    },
                    .switch_variant => |value| for (value.cases) |edge| try definitions.edge(edge),
                    .unpack_product => |value| {
                        for (value.destinations) |slot| try definitions.fresh(slot);
                        try definitions.edge(value.next);
                    },
                    inline else => |value| try definitions.edge(value.next),
                }
            };
        }
    }
    fn check(self: *Checker, contract: Contract) Error!Checked {
        const command = try self.effect(contract.command);
        const reply = try self.effect(contract.reply);
        const finalizer = try self.effect(contract.finalizer);
        try require(command != reply and reply != finalizer and command != finalizer);
        const entry_id = self.image.roots.entry;
        const entry = try self.function(entry_id, 0);
        var start = try self.block(entry.entry, entry_id);
        const producer_instruction = try start.next();
        const producer_id = try self.constructor(producer_instruction, &.{});
        const handle = (try start.term(.handle)).handle;
        try require(
            handle.body == producer_instruction.destination and
                handle.arguments.len == 0 and
                handle.state.len == 0,
        );
        const offer = try self.exchange(handle.handler);
        try require(!self.image.effects[@intCast(offer)].external);
        const initial = try resultSlot(handle.next);
        var call_driver = try self.block(handle.next.block, entry_id);
        const call = (try call_driver.term(.call)).call;
        try require(std.mem.eql(p.Id, call.arguments, &.{initial}));
        try self.returned(entry_id, call.next);

        const producer = try self.function(producer_id, 1);
        var region_entry = try self.block(producer.entry, producer_id);
        const region_instruction = try region_entry.next();
        const region_function_id = try self.constructor(region_instruction, &.{producer.inputs[0]});
        const region = (try region_entry.term(.with_region)).with_region;
        try require(region.body == region_instruction.destination and region.arguments.len == 0);
        try self.returned(producer_id, region.next);
        const region_function = try self.function(region_function_id, 2);
        var state = try self.block(region_function.entry, region_function_id);
        const zero = try state.next();
        try self.constant(zero, 0);
        const cell = try state.op(.cell_new, &.{ region_function.inputs[1], zero.destination }, 0);
        const body_instruction = try state.next();
        const body_id = try self.constructor(
            body_instruction,
            &.{ region_function.inputs[0], cell },
        );
        const cleanup_instruction = try state.next();
        const cleanup_id = try self.constructor(cleanup_instruction, &.{cell});
        const protect = (try state.term(.protect)).protect;
        try require(
            protect.body == body_instruction.destination and
                protect.cleanup == cleanup_instruction.destination and
                protect.arguments.len == 0 and
                protect.resource == null and
                protect.loan_region == null,
        );
        try self.returned(region_function_id, protect.next);
        const cleanup = try self.function(cleanup_id, 2);
        var cleanup_entry = try self.block(cleanup.entry, cleanup_id);
        const final_value = try cleanup_entry.op(.cell_get, &.{cleanup.inputs[0]}, 0);
        const final_operation = try cleanup_entry.perform(finalizer, null, final_value);
        try self.returned(cleanup_id, final_operation.next);

        const body = try self.function(body_id, 2);
        var initial_offer = try self.block(body.entry, body_id);
        const empty_ready = try initial_offer.next();
        try self.unit(empty_ready);
        const ready = try initial_offer.op(.variant, &.{empty_ready.destination}, 0);
        const offered = try initial_offer.perform(offer, body.inputs[0], ready);
        const first_command = try resultSlot(offered.next);
        var begin_work = try self.block(offered.next.block, body_id);
        const worker_call = (try begin_work.term(.call)).call;
        try require(std.mem.eql(
            p.Id,
            worker_call.arguments,
            &.{ first_command, body.inputs[1], body.inputs[0] },
        ));
        try self.returned(body_id, worker_call.next);
        const worker = try self.function(worker_call.function, 3);
        var dispatch = try self.block(worker.entry, worker_call.function);
        const choice = (try dispatch.term(.switch_variant)).switch_variant;
        try require(choice.value == worker.inputs[0] and choice.cases.len == 2);
        const request = try resultSlot(choice.cases[0]);
        _ = try resultSlot(choice.cases[1]);
        var work = try self.block(choice.cases[0].block, worker_call.function);
        const id = try work.op(.field, &.{request}, 0);
        const delta = try work.op(.field, &.{request}, 1);
        const before = try work.op(.cell_get, &.{worker.inputs[1]}, 0);
        const addition = try work.next();
        try require(addition.opcode == .integer_add and std.mem.eql(
            p.Id,
            addition.operands,
            &.{ before, delta },
        ) and addition.failures.len == 1 and addition.failures[0].kind == .arithmetic_overflow);
        const failure_literal = self.image.constants[@intCast(addition.failures[0].value)];
        try require(
            self.image.schemas[
                @intCast(failure_literal.schema)
            ] == .unit and failure_literal.bytes.len == 0,
        );
        _ = try work.op(.cell_set, &.{ worker.inputs[1], addition.destination }, 0);
        const suspension = (try work.term(.yield_value)).yield_value;
        try require(suspension.assignments.len == 0);
        var respond = try self.block(suspension.block, worker_call.function);
        var reply_id = id;
        var matches = true;
        if (respond.value.instructions.len > 2) {
            const three = try respond.next();
            try self.constant(three, 3);
            reply_id = try respond.op(.integer_bit_xor, &.{ id, three.destination }, 0);
            matches = false;
        }
        const response = try respond.op(.product, &.{ reply_id, before }, 0);
        const output = try respond.op(.variant, &.{response}, 1);
        const local_reply = try respond.perform(offer, worker.inputs[2], output);
        const next_command = try resultSlot(local_reply.next);
        var again = try self.block(local_reply.next.block, worker_call.function);
        const recurse = (try again.term(.call)).call;
        try require(recurse.function == worker_call.function and std.mem.eql(
            p.Id,
            recurse.arguments,
            &.{ next_command, worker.inputs[1], worker.inputs[2] },
        ));
        try self.returned(worker_call.function, recurse.next);
        var close = try self.block(choice.cases[1].block, worker_call.function);
        const final_counter = try close.op(.cell_get, &.{worker.inputs[1]}, 0);
        try close.ret(final_counter);

        const driver = try self.function(call.function, 1);
        var drive = try self.block(driver.entry, call.function);
        const answer = (try drive.term(.switch_variant)).switch_variant;
        try require(answer.value == driver.inputs[0] and answer.cases.len == 2);
        var finished = try self.block(answer.cases[0].block, call.function);
        try finished.ret(try resultSlot(answer.cases[0]));
        const yielded = try resultSlot(answer.cases[1]);
        var receive_answer = try self.block(answer.cases[1].block, call.function);
        const parts = (try receive_answer.term(.unpack_product)).unpack_product;
        try require(
            parts.value == yielded and
                parts.destinations.len == 2 and
                parts.next.assignments.len == 0,
        );
        var dispatch_message = try self.block(parts.next.block, call.function);
        const message = (try dispatch_message.term(.switch_variant)).switch_variant;
        try require(message.value == parts.destinations[0] and message.cases.len == 2);
        _ = try resultSlot(message.cases[0]);
        const reply_value = try resultSlot(message.cases[1]);
        var ready_branch = try self.block(message.cases[0].block, call.function);
        const empty = try ready_branch.next();
        try self.unit(empty);
        const next_request = (try ready_branch.term(.jump)).jump;
        _ = try moved(next_request, empty.destination);
        var reply_branch = try self.block(message.cases[1].block, call.function);
        const sent = try reply_branch.perform(reply, null, reply_value);
        try require(sent.next.block == next_request.block);
        _ = try resultSlot(sent.next);
        var request_next = try self.block(next_request.block, call.function);
        const command_payload = try request_next.next();
        try self.unit(command_payload);
        const received = try request_next.perform(command, null, command_payload.destination);
        const command_value = try resultSlot(received.next);
        var resume_ = try self.block(received.next.block, call.function);
        const token = try resume_.op(.unpack, &.{parts.destinations[1]}, 0);
        const resumed = (try resume_.term(.resume_value)).resume_value;
        try require(resumed.resumption == token and resumed.argument == command_value);
        const successor = try resultSlot(resumed.next);
        var next_driver = try self.block(resumed.next.block, call.function);
        const continued = (try next_driver.term(.call)).call;
        try require(continued.function == call.function and std.mem.eql(
            p.Id,
            continued.arguments,
            &.{successor},
        ));
        try self.returned(call.function, continued.next);
        // Every executable record in this admitted image participates in the
        // checked construction. Extra behavior cannot hide behind a label.
        for (self.blocks) |visited| try require(visited);
        for (self.functions) |visited| try require(visited);
        try self.freshDefinitions();
        for ([_]p.Id{ initial_offer.id, respond.id }) |site| {
            const selected = try self.owner.select(.{ .block = site, .role = .operation }, offer);
            try require(
                !selected.knowledge().conservative and
                    selected.targets().len == 1 and
                    selected.targets()[0].handler == handle.handler,
            );
        }
        return .{ .owner = self.owner, .roles = .{
            .entry = entry_id,
            .driver = call.function,
            .worker = worker_call.function,
            .producer = producer_id,
            .handler = handle.handler,
            .region = region.region,
            .cell_schema = region_function.layout.slots[@intCast(cell)],
            .command = command,
            .reply = reply,
            .finalizer = finalizer,
            .offer = offer,
            .request_site = request_next.id,
            .reply_site = reply_branch.id,
            .finalizer_site = cleanup_entry.id,
            .resume_site = resume_.id,
            .suspension_site = work.id,
            .close_site = close.id,
            .initial_offer_site = initial_offer.id,
            .local_reply_site = respond.id,
            .reply_matches = matches,
        } };
    }
};
const Cursor = struct {
    checker: *Checker,
    id: p.Id,
    value: ir.Block,
    position: usize = 0,
    fn next(self: *Cursor) Error!ir.Instruction {
        try Checker.require(self.position < self.value.instructions.len);
        const result = self.value.instructions[self.position];
        self.position += 1;
        return result;
    }
    fn op(self: *Cursor, opcode: p.Opcode, operands: []const p.Id, immediate: p.Id) Error!p.Id {
        const instruction = try self.next();
        try Checker.require(
            instruction.opcode == opcode and instruction.immediate == immediate and std.mem.eql(
                p.Id,
                instruction.operands,
                operands,
            ) and instruction.failures.len == 0,
        );
        return instruction.destination;
    }
    fn term(self: *Cursor, tag: p.TerminatorTag) Error!ir.Terminator {
        try Checker.require(
            self.position == self.value.instructions.len and std.meta.activeTag(
                self.value.terminator,
            ) == tag,
        );
        return self.value.terminator;
    }
    fn ret(self: *Cursor, value: p.Id) Error!void {
        try Checker.require((try self.term(.return_value)).return_value == value);
    }
    fn perform(self: *Cursor, effect: p.Id, capability: ?p.Id, payload: p.Id) Error!ir.Perform {
        const result = (try self.term(.perform)).perform;
        try Checker.require(
            result.effect == effect and
                result.capability == capability and
                result.payload == payload and
                result.bodies.len == 0 and
                result.use_site_capabilities.len == 0,
        );
        return result;
    }
};
fn derive(
    allocator: std.mem.Allocator,
    owner: *const provenance.Analysis,
    contract: Contract,
) Error!Checked {
    const image = owner.program();
    const blocks = try allocator.alloc(bool, image.blocks.len);
    defer allocator.free(blocks);
    @memset(blocks, false);
    const functions = try allocator.alloc(bool, image.functions.len);
    defer allocator.free(functions);
    @memset(functions, false);
    var checker: Checker = .{
        .allocator = allocator,
        .owner = owner,
        .image = image,
        .blocks = blocks,
        .functions = functions,
    };
    return checker.check(contract);
}

pub const Event = enum(u8) {
    ready,
    command,
    serve,
    suspended,
    offered_reply,
    matching_reply,
    mismatched_reply,
    reply_accepted,
    close,
    cleanup,
    finalize,
    finalizer_accepted,
};
const Binding = struct {
    roles: Roles,
    external_only: bool = false,
    fn project(
        raw: *const anyopaque,
        _: ir.Program,
        site: interaction.Site,
        _: usize,
    ) interaction.Mask {
        const self: *const Binding = @ptrCast(@alignCast(raw));
        const r = self.roles;
        const event: ?Event = if (site.phase == .cleanup)
            .cleanup
        else if (site.block == r.initial_offer_site and
            site.phase == .operation)
            .ready
        else if (site.block == r.request_site and
            site.phase == .operation)
            .command
        else if (site.block == r.resume_site and
            site.phase == .branch)
            (if (site.alternative == 0)
                .serve
            else
                .close)
        else if (site.block == r.suspension_site and
            site.phase == .yield)
            .suspended
        else if (site.block == r.local_reply_site and
            site.phase == .operation)
            .offered_reply
        else if (site.block == r.reply_site and
            site.phase == .operation)
            (if (r.reply_matches)
                .matching_reply
            else
                .mismatched_reply)
        else if (site.block == r.reply_site and
            site.phase == .reply)
            .reply_accepted
        else if (site.block == r.finalizer_site and
            site.phase == .operation)
            .finalize
        else if (site.block == r.finalizer_site and
            site.phase == .reply)
            .finalizer_accepted
        else
            null;
        const value = event orelse return 0;
        if (self.external_only) switch (value) {
            .command, .suspended, .matching_reply, .mismatched_reply, .finalize => {},
            else => return 0,
        };
        return interaction.bit(@backingInt(value));
    }
    fn monitor(self: *const Binding) interaction.Monitor {
        return .{
            .binding = self,
            .states = 10,
            .alphabet = 12,
            .bad = interaction.bit(9),
            .transitions = &transitions,
            .project = project,
        };
    }
};
const transitions = table: {
    @setEvalBranchQuota(10000);
    var result: [10 * 12]u8 = @splat(9);
    for (0..10) |state| {
        result[state * 12 + @backingInt(Event.cleanup)] = if (state == 9) 9 else 6;
        result[state * 12 + @backingInt(Event.finalizer_accepted)] = if (state == 8) 8 else 9;
    }
    result[0 * 12 + @backingInt(Event.ready)] = 1;
    result[1 * 12 + @backingInt(Event.command)] = 2;
    result[2 * 12 + @backingInt(Event.serve)] = 3;
    result[2 * 12 + @backingInt(Event.close)] = 6;
    result[3 * 12 + @backingInt(Event.suspended)] = 4;
    result[4 * 12 + @backingInt(Event.offered_reply)] = 5;
    result[5 * 12 + @backingInt(Event.matching_reply)] = 7;
    result[7 * 12 + @backingInt(Event.reply_accepted)] = 1;
    result[6 * 12 + @backingInt(Event.finalize)] = 8;
    break :table result;
};
fn graph(allocator: std.mem.Allocator, checked: Checked) Error!interaction.PhaseGraph {
    const r = checked.roles;
    var edges: std.ArrayList(interaction.PhaseEdge) = .empty;
    const Builder = struct {
        fn add(
            a: std.mem.Allocator,
            list: *std.ArrayList(interaction.PhaseEdge),
            from: usize,
            to: usize,
            site: interaction.Site,
        ) Error!void {
            try list.append(a, .{ .from = from, .to = to, .site = site });
        }
    };
    // Producer startup happens once. Only the captured suffix returns to node 1.
    try Builder.add(
        allocator,
        &edges,
        0,
        1,
        .{ .block = r.initial_offer_site, .phase = .operation },
    );
    try Builder.add(allocator, &edges, 1, 2, .{ .block = r.request_site, .phase = .operation });
    try Builder.add(
        allocator,
        &edges,
        2,
        3,
        .{ .block = r.resume_site, .phase = .branch, .alternative = 0, .choice = .environment },
    );
    try Builder.add(
        allocator,
        &edges,
        2,
        7,
        .{ .block = r.resume_site, .phase = .branch, .alternative = 1, .choice = .environment },
    );
    try Builder.add(
        allocator,
        &edges,
        3,
        4,
        .{ .block = r.suspension_site, .phase = .yield, .choice = .environment },
    );
    try Builder.add(allocator, &edges, 4, 5, .{ .block = r.local_reply_site, .phase = .operation });
    try Builder.add(allocator, &edges, 5, 6, .{ .block = r.reply_site, .phase = .operation });
    try Builder.add(
        allocator,
        &edges,
        6,
        1,
        .{ .block = r.reply_site, .phase = .reply, .choice = .environment },
    );
    // Three distinct cleanup exits. An exceptional exit while a future is held
    // disposes that owned future, which reaches the registered protected cleanup.
    for (0..3) |exit| {
        const cleanup_node = 7 + exit * 3;
        const waiting = cleanup_node + 1;
        const terminal = cleanup_node + 2;
        try Builder.add(
            allocator,
            &edges,
            cleanup_node,
            waiting,
            .{ .block = r.finalizer_site, .phase = .operation },
        );
        try Builder.add(
            allocator,
            &edges,
            waiting,
            terminal,
            .{ .block = r.finalizer_site, .phase = .reply, .choice = .environment },
        );
        // A finalizer may itself fail/cancel; it is never run a second time.
        try Builder.add(
            allocator,
            &edges,
            waiting,
            12,
            .{ .block = r.finalizer_site, .phase = .failure, .choice = .environment },
        );
        try Builder.add(
            allocator,
            &edges,
            waiting,
            15,
            .{ .block = r.finalizer_site, .phase = .cancellation, .choice = .environment },
        );
    }
    for (0..8) |node| {
        try Builder.add(
            allocator,
            &edges,
            node,
            10,
            .{
                .block = r.finalizer_site,
                .phase = .cleanup,
                .alternative = 1,
                .choice = .environment,
            },
        );
        try Builder.add(
            allocator,
            &edges,
            node,
            13,
            .{
                .block = r.finalizer_site,
                .phase = .cleanup,
                .alternative = 2,
                .choice = .environment,
            },
        );
    }
    // Allocation/failure/cancellation before protection establishes no cleanup.
    try Builder.add(
        allocator,
        &edges,
        0,
        12,
        .{ .block = r.initial_offer_site, .phase = .failure, .choice = .environment },
    );
    try Builder.add(
        allocator,
        &edges,
        0,
        15,
        .{ .block = r.initial_offer_site, .phase = .cancellation, .choice = .environment },
    );
    return .{
        .subject = checked.owner.program(),
        .nodes = 16,
        .entry = 0,
        .edges = try edges.toOwnedSlice(allocator),
        .normal = 9,
        .failure = 12,
        .cancellation = 15,
    };
}

pub const Participant = enum(u8) {
    driver,
    current_turn_and_state_owner,
    completion,
    command_source,
    reply_acknowledgement,
    finalizer_acknowledgement,
    scheduler,
};
pub const WaitEdge = struct { dependent: Participant, required: Participant, site: p.Id };
pub const Waits = struct {
    edges: []const WaitEdge,
    ranks: []const usize,
    owner_region: p.Id,
    owner_cell_schema: p.Id,
    status: enum { scoped_acyclic, cycle_candidate, incomplete, unexamined },
};
/// Small independent checker: no inference of completeness or fairness.
pub fn checkRanks(edges: []const WaitEdge, ranks: []const usize) bool {
    if (ranks.len != @typeInfo(Participant).@"enum".field_names.len) return false;
    for (edges) |edge| {
        const from = @backingInt(edge.dependent);
        const to = @backingInt(edge.required);
        if (from >= ranks.len or to >= ranks.len or ranks[from] <= ranks[to]) return false;
    }
    return true;
}
fn waitEdges(r: Roles) [6]WaitEdge {
    return .{
        .{ .dependent = .driver, .required = .current_turn_and_state_owner, .site = r.resume_site },
        .{ .dependent = .driver, .required = .command_source, .site = r.request_site },
        .{ .dependent = .driver, .required = .reply_acknowledgement, .site = r.reply_site },
        .{
            .dependent = .current_turn_and_state_owner,
            .required = .scheduler,
            .site = r.suspension_site,
        },
        .{
            .dependent = .completion,
            .required = .current_turn_and_state_owner,
            .site = r.close_site,
        },
        .{
            .dependent = .completion,
            .required = .finalizer_acknowledgement,
            .site = r.finalizer_site,
        },
    };
}
fn covered(checked: Checked, waits: Waits) bool {
    const expected = waitEdges(checked.roles);
    return waits.owner_region == checked.roles.region and
        waits.owner_cell_schema == checked.roles.cell_schema and
        @import("record_equal.zig").equal([]const WaitEdge, &expected, waits.edges);
}
pub const Ranked = struct { ranks: []const usize, status: enum { acyclic, cycle_candidate } };
pub fn rank(allocator: std.mem.Allocator, edges: []const WaitEdge) Error!Ranked {
    const ranks = try allocator.alloc(usize, @typeInfo(Participant).@"enum".field_names.len);
    errdefer allocator.free(ranks);
    @memset(ranks, 0);
    var acyclic = false;
    for (0..ranks.len) |_| {
        var changed = false;
        for (edges) |edge| {
            const from = @backingInt(edge.dependent);
            const to = @backingInt(edge.required);
            if (from >= ranks.len or to >= ranks.len) return error.InvalidReference;
            if (ranks[from] <= ranks[to]) {
                ranks[from] = ranks[to] + 1;
                changed = true;
            }
        }
        if (!changed) {
            acyclic = true;
            break;
        }
    }
    return .{
        .ranks = ranks,
        .status = if (acyclic and checkRanks(edges, ranks)) .acyclic else .cycle_candidate,
    };
}
fn waitsFor(allocator: std.mem.Allocator, checked: Checked) Error!Waits {
    const expected = waitEdges(checked.roles);
    const edges = try allocator.dupe(WaitEdge, &expected);
    const ranked = try rank(allocator, edges);
    var result: Waits = .{
        .edges = edges,
        .ranks = ranked.ranks,
        .owner_region = checked.roles.region,
        .owner_cell_schema = checked.roles.cell_schema,
        .status = if (ranked.status == .acyclic) .scoped_acyclic else .cycle_candidate,
    };
    if (!covered(checked, result)) result.status = .incomplete;
    return result;
}
pub const Report = struct {
    pub const ExternalEdge = struct { from: usize, to: usize, event: ?Event };
    pub fn externalEdges(self: Report, allocator: std.mem.Allocator) Error![]ExternalEdge {
        const phases = self.phases orelse return error.UnrecognizedService;
        const binding: Binding = .{ .roles = self.roles.?, .external_only = true };
        const result = try allocator.alloc(ExternalEdge, phases.edges.len);
        for (phases.edges, result) |edge, *out| {
            const symbols = Binding.project(&binding, phases.subject, edge.site, 0);
            out.* = .{
                .from = edge.from,
                .to = edge.to,
                .event = if (symbols == 0) null else @fromBackingInt(@intCast(@ctz(symbols))),
            };
        }
        return result;
    }
    pub fn waitCoverage(self: Report, candidate: Waits) bool {
        const phases = self.phases orelse return false;
        _ = phases;
        const roles = self.roles orelse return false;
        // The report is non-authoritative; this only checks completeness against
        // its original checked derivation, independently of proposed ranks.
        const expected = waitEdges(roles);
        return candidate.owner_region == roles.region and
            candidate.owner_cell_schema == roles.cell_schema and
            @import("record_equal.zig").equal([]const WaitEdge, &expected, candidate.edges);
    }
    pub fn ranksValid(_: Report, candidate: Waits) bool {
        return checkRanks(candidate.edges, candidate.ranks);
    }

    pub const TraceEvent = Event;
    pub fn contains(self: Report, allocator: std.mem.Allocator, trace: []const Event) Error!bool {
        return containsTrace(allocator, self, trace);
    }
    admission: enum { admitted } = .admitted,
    ordered: interaction.Status = .unresolved,
    waits: ?Waits = null,
    local_termination: enum { established_per_turn, unresolved } = .unresolved,
    finite_spawning: enum { one_private_cell_and_one_owned_successor, unresolved } = .unresolved,
    scheduler_fairness: enum { explicit_runtime_premise } = .explicit_runtime_premise,
    external_completion: enum { unresolved } = .unresolved,
    end_to_end: enum {
        conditional_on_finite_batch_fairness_external_completion_and_resources,
        no_claim,
    } = .no_claim,
    roles: ?Roles = null,
    phases: ?interaction.PhaseGraph = null,
    summary: ?interaction.Summary = null,
};
/// Borrows the admitted subject and caller allocator. All derived facts share
/// one provenance owner. No result is transported across changed code/bindings.
pub fn observe(
    allocator: std.mem.Allocator,
    owner: *const provenance.Analysis,
    contract: Contract,
) Error!Report {
    const checked = derive(allocator, owner, contract) catch |err| switch (err) {
        error.UnrecognizedService => return .{},
        else => return err,
    };
    const phases = try graph(allocator, checked);
    const binding: Binding = .{ .roles = checked.roles };
    const summary = try phases.analyze(allocator, binding.monitor());
    return .{
        .ordered = summary.status(binding.monitor()),
        .waits = try waitsFor(allocator, checked),
        .local_termination = .established_per_turn,
        .finite_spawning = .one_private_cell_and_one_owned_successor,
        .end_to_end = .conditional_on_finite_batch_fairness_external_completion_and_resources,
        .roles = checked.roles,
        .phases = phases,
        .summary = summary,
    };
}
pub fn containsTrace(
    allocator: std.mem.Allocator,
    report: Report,
    trace: []const Event,
) Error!bool {
    const binding: Binding = .{ .roles = report.roles orelse return false, .external_only = true };
    const bytes = try allocator.alloc(u8, trace.len);
    defer allocator.free(bytes);
    for (trace, bytes) |event, *byte| byte.* = @backingInt(event);
    return (report.phases orelse return false).contains(allocator, binding.monitor(), bytes);
}

test "rank checker cannot turn branch-union circular waits into a deadlock proof" {
    // A may-union can contain opposite edges from disjoint alternatives. These
    // are checker inputs, not an asserted complete service derivation. Coverage
    // is checked separately against actual roles in the source witness tests.
    const alternatives = [_]WaitEdge{
        .{ .dependent = .driver, .required = .completion, .site = 1 },
        .{ .dependent = .completion, .required = .driver, .site = 2 },
    };
    try std.testing.expect(!checkRanks(&alternatives, &.{ 2, 0, 1, 0, 0, 0, 0 }));
    try std.testing.expect(!checkRanks(&alternatives, &.{ 1, 0, 2, 0, 0, 0, 0 }));
    try std.testing.expect(checkRanks(alternatives[0..1], &.{ 2, 0, 1, 0, 0, 0, 0 }));
    try std.testing.expect(checkRanks(alternatives[1..2], &.{ 1, 0, 2, 0, 0, 0, 0 }));
}
