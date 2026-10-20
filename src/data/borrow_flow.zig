// Copyright (c) 2026 Boundary contributors. MIT license.
//! Derived borrow dependencies and outlives requirements over the finite code
//! graph. Scoped calls bind their generative inputs and implicit context here;
//! State admission interprets the same projections against actual graph owners.
//! No instruction or user computation runs during this fixed-point analysis.
const std = @import("std");
const p = @import("program.zig");
const a = @import("admission.zig");
const contracts = @import("contracts.zig");
const activation = @import("activation.zig");
const inputs = @import("function_inputs.zig");
const provenance = @import("control_provenance.zig");

pub const Step = union(enum) {
    field: p.Id,
    element,
    environment: struct { constructor: p.Id, field: p.Id },
    handler_state: struct { handler: p.Id, field: p.Id },
    use_site: struct { index: p.Id, schema: p.Id },
    cell_content,
    package_token,
    outer: ?Ambient,
    resumed: ?Ambient,
    body_result: p.Id,
};
const Path = struct { step: Step, tail: usize };
pub const Ambient = enum { evidence, region };
pub const Source = struct {
    stable_slot: bool = false,
    parameter: p.Id = 0,
    path: usize = 0,
    ambient: ?Ambient = null,
};
const Trace = struct {
    block: p.Id,
    slot: p.Id = 0,
    path: usize = 0,
    ambient: ?Ambient = null,
    body_result: bool = false,
    // Null means before the terminator; otherwise read before this instruction.
    position: ?usize = null,
};
const Query = struct {
    start: p.Id,
    position: ?usize = null,
    path: usize,
    target: ?Trace = null,
    writes: ?p.Id = null,
    sources: std.ArrayList(Source) = .empty,
};
pub const Bound = enum { region, clause, capture };
pub const Constraint = struct { value: Source, owner: Source, bound: Bound };
const Requirements = struct {
    start: p.Id,
    position: ?usize = null,
    constraints: std.ArrayList(Constraint) = .empty,
};
const Mapped = struct {
    fresh: ?Ambient = null,
    items: [2]Trace = undefined,
    len: usize = 0,
    fn one(trace: Trace) Mapped {
        return .{ .items = .{ trace, undefined }, .len = 1 };
    }
    fn ambient(block: p.Id, component: ?Ambient) Mapped {
        if (component) |selected| return one(.{ .block = block, .ambient = selected });
        return .{
            .items = .{
                .{ .block = block, .ambient = .evidence },
                .{ .block = block, .ambient = .region },
            },
            .len = 2,
        };
    }
};

/// Function summaries use input ordinals; position queries explicitly use stable slots.
pub const StableFlow = FlowFor(false);
pub const ComponentFlow = FlowFor(true);

fn FlowFor(comptime open: bool) type {
    const Program = activation.Program;
    const Edge = activation.Edge;
    const Perform = activation.Perform;
    const Incoming = struct { block: p.Id, edge: ?Edge = null, variant: ?usize = null };
    const Binding = struct {
        block: p.Id,
        function: p.Id,
        arguments: []const p.Id,
        constructor: ?p.Id = null,
        computation_slot: ?p.Id = null,
        supplied: usize = 0,
        fresh: ?Ambient = null,
        handler: ?p.Id = null,
        state: []const p.Id = &.{},
        operation: ?Perform = null,
        resumed: ?p.Id = null,
    };

    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        program: Program,
        control: *const provenance.Analysis,
        exportable: []const bool,
        incoming: []std.ArrayList(Incoming),
        outgoing: []std.ArrayList(p.Id),
        paths: std.ArrayList(Path) = .empty,
        queries: std.ArrayList(Query) = .empty,
        requirements: std.ArrayList(Requirements) = .empty,
        changed: bool = false,
        diagnostic: ?*a.Diagnostic = null,
        import_summaries: if (open) []const @import(
            "borrow_contract.zig",
        ).Summary else void = if (open) &.{} else {},

        pub fn entry(self: Self, function: p.Id) p.Id {
            const start = self.program.functions[@intCast(function)].entry;
            if (open and start == @import("relocation.zig").missing and
                self.import_summaries.len != 0) return self.program.blocks.len + function;
            return start;
        }

        fn imported(self: Self, start: p.Id) ?@import("borrow_contract.zig").Summary {
            if (!open) return null;
            if (start < self.program.blocks.len) return null;
            const function = start - self.program.blocks.len;
            for (self.import_summaries) |summary| if (summary.function == function) return summary;
            return null;
        }

        pub fn contractSource(
            self: *Self,
            function: p.Id,
            source: @import("borrow_contract.zig").Projection,
        ) a.Error!Source {
            if (source.source == .ambient) {
                if (source.path.len != 0) return error.InvalidReference;
                return .{ .ambient = source.source.ambient };
            }
            const parameters = inputs.of(self.program.functions[@intCast(function)]);
            if (source.source.input >= parameters.len) return error.InvalidReference;
            var schema = parameters.at(@intCast(source.source.input));
            for (source.path) |step| {
                switch (step) {
                    .environment => |v| if (v.constructor >= self.program.constructors.len)
                        return error.InvalidReference,
                    .handler_state => |v| if (v.handler >= self.program.handlers.len)
                        return error.InvalidReference,
                    .use_site => |v| if (v.schema >= self.program.schemas.len)
                        return error.InvalidReference,
                    .body_result => |v| if (v >= self.program.schemas.len)
                        return error.InvalidReference,
                    else => {},
                }
                schema = self.selectedSchema(schema, step) orelse return error.InvalidReference;
            }
            var path: usize = 0;
            var i = source.path.len;
            while (i != 0) {
                i -= 1;
                path = try self.prepend(source.path[i], path);
            }
            return .{ .parameter = source.source.input, .path = path };
        }

        fn rejected(self: Self, binding: Binding) a.Error {
            if (self.diagnostic) |diagnostic| diagnostic.* = .{
                .phase = .block,
                .function = self.program.blocks[@intCast(binding.block)].function,
                .block = binding.block,
                .callee = binding.function,
                .handler = binding.handler,
            };
            return error.InvalidOwnership;
        }

        pub fn init(
            allocator: std.mem.Allocator,
            program: Program,
            exportable: []const bool,
        ) a.Error!Self {
            return initWithControl(
                allocator,
                program,
                exportable,
                try provenance.derive(allocator, program, &.{}, open),
            );
        }

        pub fn initWithControl(
            allocator: std.mem.Allocator,
            program: Program,
            exportable: []const bool,
            control: *const provenance.Analysis,
        ) a.Error!Self {
            var self: Self = .{
                .allocator = allocator,
                .program = program,
                .control = control,
                .exportable = exportable,
                .incoming = try allocator.alloc(std.ArrayList(Incoming), program.blocks.len),
                .outgoing = try allocator.alloc(std.ArrayList(p.Id), program.blocks.len),
            };
            @memset(self.incoming, .empty);
            @memset(self.outgoing, .empty);
            for (program.blocks, 0..) |block, id| switch (block.terminator) {
                .jump, .yield_value => |edge| try self.link(id, edge, null),
                .branch => |branch| {
                    try self.link(id, branch.when_true, null);
                    try self.link(id, branch.when_false, null);
                },
                .switch_variant => |selected| for (
                    selected.cases,
                    0..,
                ) |edge, variant| try self.link(id, edge, variant),
                .unpack_product => |unpack| {
                    const target = unpack.next.block;
                    try self.outgoing[id].append(allocator, target);
                    try self.incoming[@intCast(target)].append(allocator, .{
                        .block = id,
                        .edge = unpack.next,
                    });
                },
                .call => |v| try self.link(id, v.next, null),
                .perform => |v| try self.link(id, v.next, null),
                .apply => |v| try self.link(id, v.next, null),
                .handle => |v| try self.link(id, v.next, null),
                .resume_value => |v| try self.link(id, v.next, null),
                .resume_with => |v| try self.link(id, v.next, null),
                .resume_computation => |v| try self.link(id, v.next, null),
                .dispose => |v| try self.link(id, v.next, null),
                .protect => |v| try self.link(id, v.next, null),
                .with_region => |v| try self.link(id, v.next, null),
                .return_value, .fail => {},
            };
            return self;
        }

        fn link(self: *Self, from: p.Id, edge: Edge, variant: ?usize) a.Error!void {
            try self.incoming[@intCast(edge.block)].append(
                self.allocator,
                .{ .block = from, .edge = edge, .variant = variant },
            );
            try self.outgoing[@intCast(from)].append(self.allocator, edge.block);
        }

        fn prepend(self: *Self, step: Step, tail: usize) a.Error!usize {
            if (step == .outer and tail != 0 and std.meta.eql(
                self.paths.items[tail - 1].step,
                step,
            )) return tail;
            for (
                self.paths.items,
                0..,
            ) |path, index| if (path.tail == tail and std.meta.eql(
                path.step,
                step,
            )) return index + 1;
            try self.paths.append(self.allocator, .{ .step = step, .tail = tail });
            return self.paths.items.len;
        }

        fn slotType(self: Self, block: p.Id, slot: p.Id) p.Id {
            const code = self.program.blocks[@intCast(block)];
            return self.program.functions[@intCast(code.function)].layout.slots[@intCast(slot)];
        }

        fn selectedSchema(self: Self, schema: p.Id, step: Step) ?p.Id {
            const shape = self.program.schemas[@intCast(schema)];
            return switch (step) {
                .field => |field| switch (shape) {
                    .product, .sum => |fields| if (field < fields.len) fields[
                        @intCast(field)
                    ] else null,
                    else => null,
                },
                .element => switch (shape) {
                    .seq => |element| element,
                    .vector => |vector| vector.element,
                    .array => |array| array.element,
                    else => null,
                },
                .environment => |environment| blk: {
                    const constructor = self.program.constructors[
                        @intCast(environment.constructor)
                    ];
                    if (constructor.schema != schema) break :blk null;
                    const fields = self.program.scopes.captures[
                        @intCast(constructor.capture)
                    ].fields;
                    break :blk if (environment.field < fields.len) fields[
                        @intCast(environment.field)
                    ] else null;
                },
                .handler_state => |state| blk: {
                    if (shape != .internal or shape.internal != .capability) break :blk null;
                    const handler = self.program.handlers[@intCast(state.handler)];
                    break :blk if (state.field < handler.state.len) handler.state[
                        @intCast(state.field)
                    ] else null;
                },
                .cell_content => if (shape == .internal and
                    shape.internal == .cell)
                    shape.internal.cell.element
                else
                    null,
                .package_token => if (shape == .internal and
                    shape.internal == .suspension_package)
                    shape.internal.suspension_package
                else
                    null,
                .use_site => |site| blk: {
                    if (shape != .internal or shape.internal != .resumption) break :blk null;
                    const effects = self.program.effects[
                        @intCast(shape.internal.resumption.effect)
                    ].use_site_effects;
                    const selected = self.program.schemas[@intCast(site.schema)];
                    break :blk if (site.index < effects.len and
                        selected == .internal and
                        selected.internal == .capability and
                        selected.internal.capability == effects[
                            @intCast(site.index)
                        ])
                        site.schema
                    else
                        null;
                },
                .outer => if (shape == .internal and
                    shape.internal == .capability)
                    schema
                else
                    null,
                .resumed => if (shape == .internal and
                    (shape.internal == .capability or
                        shape.internal == .resumption))
                    schema
                else
                    null,
                .body_result => |result| if (shape == .internal) switch (shape.internal) {
                    .capability => result,
                    .resumption => |signature| if (signature.mode == .shallow and
                        signature.answer == result) result else null,
                    else => null,
                } else null,
            };
        }

        // A repeated recursive schema means an arbitrary subtree at that position.
        // Widening to the whole subtree terminates recursive selector growth without
        // dropping any dependency. Products before the cycle remain field-sensitive.
        fn normalizePath(self: *Self, schema: p.Id, path: usize) a.Error!usize {
            var steps: std.ArrayList(Step) = .empty;
            defer steps.deinit(self.allocator);
            var seen: std.ArrayList(p.Id) = .empty;
            defer seen.deinit(self.allocator);
            var current = schema;
            var cursor = path;
            while (cursor != 0) {
                const item = self.paths.items[cursor - 1];
                if (item.step != .outer) {
                    if (std.mem.indexOfScalar(p.Id, seen.items, current) != null) break;
                    try seen.append(self.allocator, current);
                }
                current = self.selectedSchema(current, item.step) orelse return path;
                try steps.append(self.allocator, item.step);
                cursor = item.tail;
            }
            if (cursor == 0) return path;
            var result: usize = 0;
            var index = steps.items.len;
            while (index != 0) {
                index -= 1;
                result = try self.prepend(steps.items[index], result);
            }
            return result;
        }

        fn checkStart(self: *Self, start: p.Id, position: ?usize) a.Error!void {
            if (self.imported(start) != null) {
                if (position != null) return error.InvalidReference;
                return;
            }
            if (start >= self.program.blocks.len) return error.InvalidReference;
            if (position != null) {
                if (position.? > self.program.blocks[
                    @intCast(start)
                ].instructions.len) return error.InvalidReference;
            } else {
                const owner = self.program.blocks[@intCast(start)].function;
                if (self.program.functions[@intCast(owner)].entry != start)
                    return error.InvalidProgram;
            }
        }

        fn query(self: *Self, start: p.Id, path: usize) a.Error!usize {
            return self.queryFrom(start, path, null);
        }

        fn queryFrom(self: *Self, start: p.Id, path: usize, position: ?usize) a.Error!usize {
            try self.checkStart(start, position);
            const owner = if (self.imported(
                start,
            )) |summary| summary.function else self.program.blocks[
                @intCast(start)
            ].function;
            const function = self.program.functions[@intCast(owner)];
            const selected = try self.normalizePath(function.result, path);
            for (
                self.queries.items,
                0..,
            ) |item, index|
                if (item.start == start and
                    item.position == position and
                    item.path == selected and
                    item.target == null and
                    item.writes == null)
                    return index;
            try self.queries.append(
                self.allocator,
                .{ .start = start, .position = position, .path = selected },
            );
            self.changed = true;
            return self.queries.items.len - 1;
        }

        pub fn returned(self: *Self, start: p.Id) a.Error![]const Source {
            return self.returnedAt(start, 0);
        }

        pub fn returnedAt(self: *Self, start: p.Id, path: usize) a.Error![]const Source {
            const index = try self.query(start, path);
            try self.settle();
            return self.queries.items[index].sources.items;
        }

        fn origin(self: *Self, start: p.Id, target: Trace, position: ?usize) a.Error!usize {
            for (
                self.queries.items,
                0..,
            ) |item, index|
                if (item.start == start and
                    item.position == position and
                    item.target != null and
                    std.meta.eql(item.target.?, target))
                    return index;
            try self.queries.append(
                self.allocator,
                .{ .start = start, .position = position, .path = 0, .target = target },
            );
            self.changed = true;
            return self.queries.items.len - 1;
        }

        fn writeQuery(self: *Self, start: p.Id, schema: p.Id, path: usize) a.Error!usize {
            return self.writeQueryFrom(start, schema, path, null);
        }

        pub fn written(self: *Self, start: p.Id, schema: p.Id) a.Error![]const Source {
            const index = try self.writeQuery(start, schema, 0);
            try self.settle();
            return self.queries.items[index].sources.items;
        }

        fn writeQueryFrom(
            self: *Self,
            start: p.Id,
            schema: p.Id,
            path: usize,
            position: ?usize,
        ) a.Error!usize {
            try self.checkStart(start, position);
            for (
                self.queries.items,
                0..,
            ) |item, index|
                if (item.start == start and
                    item.position == position and
                    item.writes == schema and
                    item.path == path)
                    return index;
            try self.queries.append(
                self.allocator,
                .{ .start = start, .position = position, .path = path, .writes = schema },
            );
            self.changed = true;
            return self.queries.items.len - 1;
        }

        fn settle(self: *Self) a.Error!void {
            // Every new query or fact marks the analysis dirty. A failed pass must
            // remain dirty so a retry cannot publish a partially settled result.
            errdefer self.changed = true;
            while (self.changed) {
                self.changed = false;
                var current: usize = 0;
                while (current < self.queries.items.len) : (current += 1) try self.solve(current);
                current = 0;
                while (current < self.requirements.items.len) : (current += 1)
                    try self.solveRequirements(current);
            }
        }

        fn addSource(self: *Self, query_index: usize, source: Source) a.Error!void {
            for (self.queries.items[query_index].sources.items) |existing| if (std.meta.eql(
                existing,
                source,
            )) return;
            try self.queries.items[query_index].sources.append(self.allocator, source);
            self.changed = true;
        }

        fn requirementsQuery(self: *Self, start: p.Id) a.Error!usize {
            return self.requirementsQueryFrom(start, null);
        }

        fn requirementsQueryFrom(self: *Self, start: p.Id, position: ?usize) a.Error!usize {
            try self.checkStart(start, position);
            for (
                self.requirements.items,
                0..,
            ) |item, index| if (item.start == start and item.position == position) return index;
            try self.requirements.append(self.allocator, .{ .start = start, .position = position });
            self.changed = true;
            return self.requirements.items.len - 1;
        }

        pub fn required(self: *Self, start: p.Id) a.Error![]const Constraint {
            const index = try self.requirementsQuery(start);
            try self.settle();
            return self.requirements.items[index].constraints.items;
        }

        pub fn requiredFrom(self: *Self, start: p.Id, position: usize) a.Error![]const Constraint {
            const index = try self.requirementsQueryFrom(start, position);
            try self.settle();
            return self.requirements.items[index].constraints.items;
        }
        pub fn returnedFrom(
            self: *Self,
            start: p.Id,
            position: usize,
            path: usize,
        ) a.Error![]const Source {
            const index = try self.queryFrom(start, path, position);
            try self.settle();
            return self.queries.items[index].sources.items;
        }

        fn reenters(self: Self, start: p.Id, live: []const bool) bool {
            for (self.incoming[
                @intCast(start)
            ].items) |incoming| if (live[
                @intCast(incoming.block)
            ]) return true;
            return false;
        }
        fn futureInstruction(
            self: Self,
            start: p.Id,
            position: ?usize,
            block: p.Id,
            ordinal: usize,
            live: []const bool,
        ) bool {
            return position == null or block != start or ordinal >= position.? or self.reenters(
                start,
                live,
            );
        }

        fn addConstraint(
            self: *Self,
            index: usize,
            value: Source,
            owner: Source,
            bound: Bound,
        ) a.Error!void {
            const constraint: Constraint = .{ .value = value, .owner = owner, .bound = bound };
            for (self.requirements.items[index].constraints.items) |item| if (std.meta.eql(
                item,
                constraint,
            )) return;
            try self.requirements.items[index].constraints.append(self.allocator, constraint);
            self.changed = true;
        }

        fn relation(
            self: *Self,
            index: usize,
            block: p.Id,
            value: p.Id,
            owner: p.Id,
            bound: Bound,
        ) a.Error!void {
            return self.relationAt(index, block, value, owner, bound, null);
        }
        fn relationAt(
            self: *Self,
            index: usize,
            block: p.Id,
            value: p.Id,
            owner: p.Id,
            bound: Bound,
            position: ?usize,
        ) a.Error!void {
            if (self.exportable[@intCast(self.slotType(block, value))]) return;
            const start = self.requirements.items[index].start;
            const values = try self.origin(
                start,
                .{ .block = block, .slot = value, .path = 0, .position = position },
                self.requirements.items[index].position,
            );
            const owners = try self.origin(
                start,
                .{ .block = block, .slot = owner, .path = 0, .position = position },
                self.requirements.items[index].position,
            );
            for (self.queries.items[values].sources.items) |source|
                for (self.queries.items[owners].sources.items) |destination|
                    try self.addConstraint(index, source, destination, bound);
        }

        fn mapInput(self: *Self, binding: Binding, source: Source) a.Error!Mapped {
            if (source.ambient) |ambient| {
                if (binding.resumed) |token| return Mapped.one(.{
                    .block = binding.block,
                    .slot = token,
                    .path = try self.prepend(.{ .resumed = ambient }, 0),
                });
                if (binding.operation) |op| return Mapped.one(.{
                    .block = binding.block,
                    .slot = op.capability.?,
                    .path = try self.prepend(.{ .outer = ambient }, 0),
                });
                if (binding.fresh == ambient) return .{ .fresh = ambient };
                return Mapped.one(.{ .block = binding.block, .ambient = ambient });
            }
            if (binding.operation) |op| {
                const handler = self.program.handlers[@intCast(binding.handler.?)];
                if (source.parameter < handler.state.len) return Mapped.one(.{
                    .block = binding.block,
                    .slot = op.capability.?,
                    .path = try self.prepend(
                        .{ .handler_state = .{
                            .handler = binding.handler.?,
                            .field = source.parameter,
                        } },
                        source.path,
                    ),
                });
                const argument = source.parameter - handler.state.len;
                if (argument == 0) return Mapped.one(.{
                    .block = binding.block,
                    .slot = op.payload,
                    .path = source.path,
                });
                if (argument <= op.bodies.len) return Mapped.one(.{
                    .block = binding.block,
                    .slot = op.bodies[@intCast(argument - 1)],
                    .path = source.path,
                });
                if (source.path != 0 and self.paths.items[source.path - 1].step == .body_result)
                    return Mapped.one(.{
                        .block = binding.block,
                        .slot = op.capability.?,
                        .path = source.path,
                    });
                if (source.path != 0 and self.paths.items[source.path - 1].step == .use_site) {
                    const path = self.paths.items[source.path - 1];
                    return Mapped.one(.{
                        .block = binding.block,
                        .slot = op.use_site_capabilities[@intCast(path.step.use_site.index)],
                        .path = path.tail,
                    });
                }
                if (source.path != 0 and
                    self.paths.items[source.path - 1].step == .resumed)
                    return Mapped.one(
                        .{ .block = binding.block, .slot = op.capability.?, .path = source.path },
                    );
                return Mapped.one(.{
                    .block = binding.block,
                    .slot = op.capability.?,
                    .path = try self.prepend(.{ .outer = null }, 0),
                });
            }
            const captures = if (binding.constructor) |id| self.program.scopes.captures[
                @intCast(self.program.constructors[
                    @intCast(id)
                ].capture)
            ].fields.len else 0;
            if (source.parameter < captures) return Mapped.one(.{
                .block = binding.block,
                .slot = binding.computation_slot.?,
                .path = try self.prepend(
                    .{ .environment = .{
                        .constructor = binding.constructor.?,
                        .field = source.parameter,
                    } },
                    source.path,
                ),
            });
            if (binding.resumed) |token| return Mapped.one(
                .{
                    .block = binding.block,
                    .slot = token,
                    .path = try self.prepend(
                        .{
                            .use_site = .{
                                .index = source.parameter - captures,
                                .schema = inputs.of(
                                    self.program.functions[
                                        @intCast(binding.function)
                                    ],
                                ).at(
                                    @intCast(source.parameter),
                                ),
                            },
                        },
                        source.path,
                    ),
                },
            );
            if (source.parameter < captures + binding.supplied) {
                if (source.path != 0) {
                    const path = self.paths.items[source.path - 1];
                    if (path.step == .outer) return Mapped.ambient(binding.block, path.step.outer);
                    if (path.step == .resumed and binding.fresh == .evidence) {
                        if (path.step.resumed == .region) return Mapped.ambient(
                            binding.block,
                            .region,
                        );
                        if (path.step.resumed == null) {
                            var context = Mapped.ambient(binding.block, .region);
                            context.fresh = .evidence;
                            return context;
                        }
                    }
                    if (path.step == .handler_state) {
                        if (binding.handler != path.step.handler_state.handler) return .{};
                        return Mapped.one(.{
                            .block = binding.block,
                            .slot = binding.state[@intCast(path.step.handler_state.field)],
                            .path = path.tail,
                        });
                    }
                    if (path.step == .body_result and binding.fresh == .evidence) {
                        const handler = self.program.handlers[@intCast(binding.handler.?)];
                        if (handler.input != path.step.body_result) return .{};
                        return Mapped.one(.{
                            .block = binding.block,
                            .path = path.tail,
                            .body_result = true,
                        });
                    }
                }
                return .{ .fresh = binding.fresh orelse return self.rejected(binding) };
            }
            return Mapped.one(.{
                .block = binding.block,
                .slot = binding.arguments[@intCast(source.parameter - captures - binding.supplied)],
                .path = source.path,
            });
        }

        fn transferRequirements(self: *Self, index: usize, binding: Binding) a.Error!void {
            const called = try self.requirementsQuery(self.entry(binding.function));
            const pairs = try self.allocator.dupe(
                Constraint,
                self.requirements.items[called].constraints.items,
            );
            defer self.allocator.free(pairs);
            const start = self.requirements.items[index].start;
            for (pairs) |pair| {
                const values = try self.mapInput(binding, pair.value);
                const owners = try self.mapOwner(binding, pair.owner, pair.bound);
                if (values.fresh) |component| {
                    // Capabilities need evidence ancestry; region references need
                    // region ancestry. A constraint on the other component cannot
                    // make a fresh value escape its owner.
                    for (owners.items[0..owners.len]) |owner| {
                        if (self.selectedComponent(
                            owner,
                        )) |selected| if (selected != component) continue;
                        return self.rejected(binding);
                    }
                }
                for (values.items[0..values.len]) |value_trace|
                    for (owners.items[0..owners.len]) |owner_trace| {
                        const v = try self.origin(
                            start,
                            value_trace,
                            self.requirements.items[index].position,
                        );
                        const o = try self.origin(
                            start,
                            owner_trace,
                            self.requirements.items[index].position,
                        );
                        for (self.queries.items[v].sources.items) |value|
                            for (self.queries.items[o].sources.items) |owner|
                                try self.addConstraint(index, value, owner, pair.bound);
                    };
            }
        }

        fn mapOwner(self: *Self, binding: Binding, source: Source, bound: Bound) a.Error!Mapped {
            const mapped = try self.mapInput(binding, source);
            // A clause executes outside the capability's delimiter. Explicit
            // ambient/resumed projections already denote a context; a newly bound
            // capability value still needs this owner projection before comparison.
            if (bound == .clause and
                mapped.fresh == .evidence and
                source.ambient == null and
                source.path == 0)
                return Mapped.ambient(binding.block, null);
            return mapped;
        }

        fn selectedComponent(self: Self, trace: Trace) ?Ambient {
            if (trace.ambient) |selected| return selected;
            var cursor = trace.path;
            while (cursor != 0) {
                const path = self.paths.items[cursor - 1];
                switch (path.step) {
                    .outer, .resumed => |selected| return selected,
                    else => cursor = path.tail,
                }
            }
            return null;
        }

        fn bodyBinding(
            self: Self,
            block: p.Id,
            computation_slot: p.Id,
            arguments: []const p.Id,
            supplied: usize,
            id: p.Id,
        ) Binding {
            const term = self.program.blocks[@intCast(block)].terminator;
            return .{
                .block = block,
                .function = self.program.constructors[
                    @intCast(id)
                ].function,
                .arguments = arguments,
                .constructor = id,
                .computation_slot = computation_slot,
                .supplied = supplied,
                .resumed = if (term == .resume_computation)
                    term.resume_computation.resumption
                else
                    null,
                .fresh = switch (term) {
                    .handle => .evidence,
                    .with_region => .region,
                    .protect => |v| if (v.body == computation_slot and
                        v.loan_region != null)
                        .region
                    else
                        null,
                    else => null,
                },
                .handler = if (term == .handle) term.handle.handler else null,
                .state = if (term == .handle) term.handle.state else &.{},
            };
        }

        fn bodyRequirements(
            self: *Self,
            index: usize,
            block: p.Id,
            computation_slot: p.Id,
            arguments: []const p.Id,
            supplied: usize,
        ) a.Error!void {
            const schema = self.slotType(block, computation_slot);
            for (
                self.program.constructors,
                0..,
            ) |constructor, id| if (constructor.schema == schema) try self.transferRequirements(
                index,
                self.bodyBinding(block, computation_slot, arguments, supplied, id),
            );
        }

        fn returnInput(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            source: Source,
        ) a.Error!void {
            const term = self.program.blocks[@intCast(block)].terminator;
            const state = switch (term) {
                inline .handle, .resume_with => |v| v.state,
                else => return error.InvalidProgram,
            };
            if (source.ambient) |ambient| {
                return self.pushTrace(pending, .{ .block = block, .ambient = ambient });
            }
            if (source.parameter < state.len) {
                return self.push(pending, block, state[@intCast(source.parameter)], source.path);
            }
            switch (term) {
                .handle => |v| try self.body(
                    pending,
                    block,
                    v.body,
                    v.arguments,
                    self.program.handlers[@intCast(v.handler)].clauses.len,
                    source.path,
                ),
                .resume_with => |v| {
                    // Operation inputs are exportable. Project the captured body's
                    // result, retaining its selectors rather than its whole context.
                    const schema = self.program.handlers[@intCast(v.handler)].input;
                    const path = try self.prepend(.{ .body_result = schema }, source.path);
                    try self.push(pending, block, v.resumption, path);
                },
                else => return error.InvalidProgram,
            }
        }

        fn returnInputs(
            self: *Self,
            start: p.Id,
            block: p.Id,
            source: Source,
            position: ?usize,
        ) a.Error!std.ArrayList(Source) {
            var pending: std.ArrayList(Trace) = .empty;
            defer pending.deinit(self.allocator);
            try self.returnInput(&pending, block, source);
            var result: std.ArrayList(Source) = .empty;
            for (pending.items) |trace| {
                const query_id = try self.origin(start, trace, position);
                try result.appendSlice(self.allocator, self.queries.items[query_id].sources.items);
            }
            return result;
        }

        fn returnRequirements(self: *Self, index: usize, block: p.Id) a.Error!void {
            const handler_id = switch (self.program.blocks[@intCast(block)].terminator) {
                inline .handle, .resume_with => |v| v.handler,
                else => return error.InvalidProgram,
            };
            const handler = self.program.handlers[@intCast(handler_id)];
            const query_id = try self.requirementsQuery(self.entry(handler.return_function));
            const constraints = try self.allocator.dupe(
                Constraint,
                self.requirements.items[query_id].constraints.items,
            );
            defer self.allocator.free(constraints);
            for (constraints) |constraint| {
                var values = try self.returnInputs(
                    self.requirements.items[index].start,
                    block,
                    constraint.value,
                    self.requirements.items[index].position,
                );
                defer values.deinit(self.allocator);
                var owners = try self.returnInputs(
                    self.requirements.items[index].start,
                    block,
                    constraint.owner,
                    self.requirements.items[index].position,
                );
                defer owners.deinit(self.allocator);
                for (values.items) |value| for (owners.items) |owner| try self.addConstraint(
                    index,
                    value,
                    owner,
                    constraint.bound,
                );
            }
        }

        fn solveRequirements(self: *Self, index: usize) a.Error!void {
            if (self.imported(self.requirements.items[index].start)) |summary| {
                for (summary.requirements) |pair| try self.addConstraint(
                    index,
                    try self.contractSource(summary.function, pair.value),
                    try self.contractSource(summary.function, pair.owner),
                    pair.bound,
                );
                return;
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const reach = try self.reachable(
                self.requirements.items[index].start,
                arena.allocator(),
            );
            const live = reach.membership;
            for (reach.blocks) |id| {
                const block = self.program.blocks[@intCast(id)];
                for (
                    block.instructions,
                    0..,
                ) |op, position| if (self.futureInstruction(
                    self.requirements.items[index].start,
                    self.requirements.items[index].position,
                    id,
                    position,
                    live,
                )) switch (op.opcode) {
                    .cell_new, .cell_set => try self.relationAt(
                        index,
                        id,
                        op.operands[1],
                        op.operands[0],
                        .region,
                        position,
                    ),
                    else => {},
                };
                switch (block.terminator) {
                    .call => |v| try self.transferRequirements(
                        index,
                        .{ .block = id, .function = v.function, .arguments = v.arguments },
                    ),
                    .apply => |v| try self.bodyRequirements(
                        index,
                        id,
                        v.computation,
                        v.arguments,
                        0,
                    ),
                    .with_region => |v| try self.bodyRequirements(
                        index,
                        id,
                        v.body,
                        v.arguments,
                        1,
                    ),
                    .protect => |v| {
                        try self.bodyRequirements(
                            index,
                            id,
                            v.body,
                            v.arguments,
                            @intFromBool(v.resource != null),
                        );
                        // Exit information and the owned resource are exportable;
                        // cleanup's retained environment still has ordinary bounds.
                        try self.bodyRequirements(
                            index,
                            id,
                            v.cleanup,
                            &.{},
                            if (v.resource == null) 1 else 2,
                        );
                    },
                    .handle => |v| {
                        try self.bodyRequirements(
                            index,
                            id,
                            v.body,
                            v.arguments,
                            self.program.handlers[@intCast(v.handler)].clauses.len,
                        );
                        try self.returnRequirements(index, id);
                    },
                    .perform => |v| if (v.capability) |capability| {
                        var captures = false;
                        const targets = self.control.targets(
                            .{ .block = id, .role = .operation },
                            v.effect,
                        );
                        for (targets) |target| captures = captures or target.retains;
                        if (captures) {
                            try self.relation(index, id, v.payload, capability, .clause);
                            for (v.bodies) |slot| try self.relation(
                                index,
                                id,
                                slot,
                                capability,
                                .clause,
                            );
                        }
                        for (targets) |target| try self.transferRequirements(
                            index,
                            .{
                                .block = id,
                                .function = target.function,
                                .arguments = &.{},
                                .handler = target.handler,
                                .operation = v,
                            },
                        );
                    },
                    .resume_value => |v| try self.relation(
                        index,
                        id,
                        v.argument,
                        v.resumption,
                        .capture,
                    ),
                    .resume_with => |v| {
                        try self.relation(index, id, v.argument, v.resumption, .capture);
                        for (v.state) |slot| try self.relation(
                            index,
                            id,
                            slot,
                            v.resumption,
                            .capture,
                        );
                        try self.returnRequirements(index, id);
                    },
                    .resume_computation => |v| {
                        try self.relation(index, id, v.computation, v.resumption, .capture);
                        try self.bodyRequirements(index, id, v.computation, &.{}, 0);
                    },
                    else => {},
                }
            }
        }

        fn push(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            slot: p.Id,
            path: usize,
        ) a.Error!void {
            return self.pushAt(pending, block, slot, path, null);
        }
        fn pushAt(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            slot: p.Id,
            path: usize,
            position: ?usize,
        ) a.Error!void {
            const schema = self.slotType(block, slot);
            const selected = try self.normalizePath(schema, path);
            var current = schema;
            var cursor = selected;
            while (cursor != 0) {
                const item = self.paths.items[cursor - 1];
                current = self.selectedSchema(current, item.step) orelse return;
                cursor = item.tail;
            }
            if (self.exportable[@intCast(current)]) return;
            try pending.append(
                self.allocator,
                .{ .block = block, .slot = slot, .path = selected, .position = position },
            );
        }

        fn pushTrace(self: *Self, pending: *std.ArrayList(Trace), trace: Trace) a.Error!void {
            if (trace.ambient != null or trace.body_result)
                return pending.append(self.allocator, trace);
            try self.pushAt(pending, trace.block, trace.slot, trace.path, trace.position);
        }

        fn transferSources(
            self: *Self,
            pending: *std.ArrayList(Trace),
            binding: Binding,
            index: usize,
        ) a.Error!void {
            const sources = try self.allocator.dupe(
                Source,
                self.queries.items[index].sources.items,
            );
            defer self.allocator.free(sources);
            for (sources) |source| {
                const mapped = try self.mapInput(binding, source);
                if (mapped.fresh != null) return self.rejected(binding);
                for (mapped.items[0..mapped.len]) |trace| try self.pushTrace(pending, trace);
            }
        }

        const Reachable = struct { membership: []const bool, blocks: []const p.Id };

        fn reachable(self: Self, start: p.Id, allocator: std.mem.Allocator) a.Error!Reachable {
            const visited = try allocator.alloc(bool, self.program.blocks.len);
            @memset(visited, false);
            visited[@intCast(start)] = true;
            var pending: std.ArrayList(p.Id) = .empty;
            defer pending.deinit(allocator);
            try pending.append(allocator, start);
            var next: usize = 0;
            while (next < pending.items.len) : (next += 1) {
                const from = pending.items[next];
                for (self.outgoing[@intCast(from)].items) |target| {
                    if (visited[@intCast(target)]) continue;
                    visited[@intCast(target)] = true;
                    try pending.append(allocator, target);
                }
            }
            const blocks = try pending.toOwnedSlice(allocator);
            std.mem.sort(p.Id, blocks, {}, std.sort.asc(p.Id));
            return .{ .membership = visited, .blocks = blocks };
        }

        fn solve(self: *Self, query_index: usize) a.Error!void {
            const query_start = self.queries.items[query_index].start;
            const query_path = self.queries.items[query_index].path;
            const query_target = self.queries.items[query_index].target;
            const query_writes = self.queries.items[query_index].writes;
            if (self.imported(query_start)) |summary| {
                if (query_target != null) return error.InvalidReference;
                // A whole-result bound also bounds every result projection.
                if (query_writes) |schema| {
                    for (summary.writes) |write| if (write.schema == schema) {
                        for (write.sources) |source| try self.addSource(
                            query_index,
                            try self.contractSource(summary.function, source),
                        );
                    };
                } else for (summary.returned) |source| try self.addSource(
                    query_index,
                    try self.contractSource(summary.function, source),
                );
                return;
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const reach = try self.reachable(query_start, allocator);
            const live = reach.membership;
            var pending: std.ArrayList(Trace) = .empty;
            defer pending.deinit(self.allocator);
            var visited: std.AutoHashMapUnmanaged(Trace, void) = .empty;
            if (query_target) |target| {
                if (live[@intCast(target.block)]) try self.pushTrace(&pending, target);
            } else if (query_writes) |schema| {
                for (reach.blocks) |id| {
                    const block = self.program.blocks[@intCast(id)];
                    for (block.instructions, 0..) |op, position|
                        if (self.futureInstruction(
                            query_start,
                            self.queries.items[query_index].position,
                            id,
                            position,
                            live,
                        ) and op.opcode == .cell_set and self.slotType(
                            id,
                            op.operands[0],
                        ) == schema)
                            try self.pushAt(&pending, id, op.operands[1], query_path, position);
                    try self.calledWrites(&pending, id, schema, query_path);
                }
            } else for (reach.blocks) |id| {
                const block = self.program.blocks[@intCast(id)];
                if (block.terminator == .return_value) try self.push(
                    &pending,
                    id,
                    block.terminator.return_value,
                    query_path,
                );
            }
            while (pending.pop()) |trace| {
                if ((try visited.getOrPut(allocator, trace)).found_existing) continue;
                if (trace.body_result) {
                    const term = self.program.blocks[@intCast(trace.block)].terminator;
                    if (term != .handle) return error.InvalidProgram;
                    const v = term.handle;
                    try self.body(
                        &pending,
                        trace.block,
                        v.body,
                        v.arguments,
                        self.program.handlers[@intCast(v.handler)].clauses.len,
                        trace.path,
                    );
                    continue;
                }
                if (trace.ambient) |ambient| {
                    try self.addSource(query_index, .{ .ambient = ambient });
                    continue;
                }
                try self.stableTrace(&pending, trace, query_index, query_start, live, allocator);
            }
        }

        fn stableTrace(
            self: *Self,
            pending: *std.ArrayList(Trace),
            trace: Trace,
            query_index: usize,
            query_start: p.Id,
            live: []const bool,
            allocator: std.mem.Allocator,
        ) a.Error!void {
            const code = self.program.blocks[@intCast(trace.block)];
            var position = trace.position orelse code.instructions.len;
            const cut = self.queries.items[query_index].position;
            while (position != 0) {
                if (trace.block == query_start and cut != null and position == cut.?) {
                    try self.addSource(
                        query_index,
                        .{ .stable_slot = true, .parameter = trace.slot, .path = trace.path },
                    );
                    if (!self.reenters(query_start, live)) return;
                }
                position -= 1;
                const op = code.instructions[position];
                if (op.destination != trace.slot) continue;
                var definition = trace;
                definition.position = position;
                try self.instruction(pending, definition, op);
                if (op.opcode == .cell_get) {
                    const writes = try self.writeQueryFrom(
                        query_start,
                        self.slotType(trace.block, op.operands[0]),
                        trace.path,
                        self.queries.items[query_index].position,
                    );
                    const sources = try allocator.dupe(
                        Source,
                        self.queries.items[writes].sources.items,
                    );
                    for (sources) |source| try self.addSource(query_index, source);
                }
                return;
            }
            if (trace.block == query_start and cut != null and cut.? == 0) {
                try self.addSource(
                    query_index,
                    .{ .stable_slot = true, .parameter = trace.slot, .path = trace.path },
                );
                if (!self.reenters(query_start, live)) return;
            }
            if (trace.block == query_start and cut == null) {
                const function = self.program.functions[@intCast(code.function)];
                if (std.mem.indexOfScalar(p.Id, function.inputs, trace.slot)) |parameter|
                    try self.addSource(
                        query_index,
                        .{ .parameter = parameter, .path = trace.path },
                    );
            }
            for (self.incoming[@intCast(trace.block)].items) |incoming| {
                if (!live[@intCast(incoming.block)]) continue;
                const edge = incoming.edge.?;
                var changed = false;
                for (edge.assignments) |assignment| {
                    if (assignment.destination != trace.slot) continue;
                    changed = true;
                    switch (assignment.source) {
                        .slot => |slot| try self.stableIncoming(
                            pending,
                            incoming.block,
                            slot,
                            trace.path,
                        ),
                        .returned => if (incoming.variant) |variant| {
                            const selected = self.program.blocks[
                                @intCast(incoming.block)
                            ].terminator.switch_variant;
                            try self.push(
                                pending,
                                incoming.block,
                                selected.value,
                                try self.prepend(.{ .field = variant }, trace.path),
                            );
                        } else try self.output(pending, incoming.block, trace.path),
                    }
                    break;
                }
                if (!changed) try self.stableIncoming(
                    pending,
                    incoming.block,
                    trace.slot,
                    trace.path,
                );
            }
        }

        fn stableIncoming(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            slot: p.Id,
            path: usize,
        ) a.Error!void {
            const term = self.program.blocks[@intCast(block)].terminator;
            if (term == .unpack_product) {
                if (std.mem.indexOfScalar(p.Id, term.unpack_product.destinations, slot)) |field| {
                    try self.push(
                        pending,
                        block,
                        term.unpack_product.value,
                        try self.prepend(.{ .field = field }, path),
                    );
                    return;
                }
            }
            try self.push(pending, block, slot, path);
        }

        fn childPath(self: Self, path: usize, step: Step) ?usize {
            if (path == 0) return 0;
            const selected = self.paths.items[path - 1];
            return if (std.meta.eql(selected.step, step)) selected.tail else null;
        }

        fn sequenceInstruction(
            self: *Self,
            pending: *std.ArrayList(Trace),
            trace: Trace,
            op: anytype,
        ) a.Error!void {
            const sequence = op.operands[0];
            switch (op.opcode) {
                .sequence_concat, .sequence_take => {
                    try self.pushAt(pending, trace.block, sequence, trace.path, trace.position);
                    if (op.opcode == .sequence_concat)
                        try self.pushAt(
                            pending,
                            trace.block,
                            op.operands[1],
                            trace.path,
                            trace.position,
                        );
                },
                .sequence_append, .sequence_set => {
                    const element = self.childPath(trace.path, .element) orelse return;
                    try self.pushAt(pending, trace.block, sequence, trace.path, trace.position);
                    const added = op.operands[if (op.opcode == .sequence_append) 1 else 2];
                    try self.pushAt(pending, trace.block, added, element, trace.position);
                },
                .sequence_pop => {
                    const present = self.childPath(trace.path, .{ .field = 1 }) orelse return;
                    if (self.childPath(present, .{ .field = 0 })) |element|
                        try self.pushAt(
                            pending,
                            trace.block,
                            sequence,
                            try self.prepend(.element, element),
                            trace.position,
                        );
                    if (self.childPath(present, .{ .field = 1 })) |rest| {
                        if (self.childPath(rest, .element)) |element|
                            try self.pushAt(
                                pending,
                                trace.block,
                                sequence,
                                try self.prepend(.element, element),
                                trace.position,
                            );
                    }
                },
                .sequence_pop_last => {
                    if (self.childPath(trace.path, .{ .field = 0 })) |rest|
                        try self.pushAt(pending, trace.block, sequence, rest, trace.position);
                    if (self.childPath(trace.path, .{ .field = 1 })) |optional| {
                        if (self.childPath(optional, .{ .field = 1 })) |element|
                            try self.pushAt(
                                pending,
                                trace.block,
                                sequence,
                                try self.prepend(.element, element),
                                trace.position,
                            );
                    }
                },
                else => return error.InvalidProgram,
            }
        }

        fn instruction(
            self: *Self,
            pending: *std.ArrayList(Trace),
            trace: Trace,
            op: anytype,
        ) a.Error!void {
            const path = if (trace.path == 0) null else self.paths.items[trace.path - 1];
            switch (op.opcode) {
                .move => try self.pushAt(
                    pending,
                    trace.block,
                    op.operands[0],
                    trace.path,
                    trace.position,
                ),
                .select => for (op.operands[1..]) |slot|
                    try self.pushAt(pending, trace.block, slot, trace.path, trace.position),
                .product => {
                    if (path) |selected| {
                        if (selected.step == .field and
                            selected.step.field < op.operands.len)
                            try self.pushAt(
                                pending,
                                trace.block,
                                op.operands[@intCast(selected.step.field)],
                                selected.tail,
                                trace.position,
                            );
                    } else for (op.operands) |slot| try self.pushAt(
                        pending,
                        trace.block,
                        slot,
                        0,
                        trace.position,
                    );
                },
                .field, .variant_payload => try self.pushAt(
                    pending,
                    trace.block,
                    op.operands[0],
                    try self.prepend(.{ .field = op.immediate }, trace.path),
                    trace.position,
                ),
                .variant => {
                    if (path) |selected| {
                        if (selected.step == .field and
                            selected.step.field == op.immediate)
                            try self.pushAt(
                                pending,
                                trace.block,
                                op.operands[0],
                                selected.tail,
                                trace.position,
                            );
                    } else for (op.operands) |slot| try self.pushAt(
                        pending,
                        trace.block,
                        slot,
                        0,
                        trace.position,
                    );
                },
                .computation => {
                    if (path) |selected| {
                        if (selected.step == .environment and
                            selected.step.environment.constructor == op.immediate)
                            try self.pushAt(
                                pending,
                                trace.block,
                                op.operands[@intCast(selected.step.environment.field)],
                                selected.tail,
                                trace.position,
                            );
                    } else for (op.operands) |slot| try self.pushAt(
                        pending,
                        trace.block,
                        slot,
                        0,
                        trace.position,
                    );
                },
                .cell_new => if (path) |selected| {
                    if (selected.step == .cell_content) try self.pushAt(
                        pending,
                        trace.block,
                        op.operands[1],
                        selected.tail,
                        trace.position,
                    );
                } else try self.pushAt(pending, trace.block, op.operands[0], 0, trace.position),
                .cell_get => try self.pushAt(
                    pending,
                    trace.block,
                    op.operands[0],
                    try self.prepend(.cell_content, trace.path),
                    trace.position,
                ),
                .sequence => for (op.operands) |slot| try self.pushAt(
                    pending,
                    trace.block,
                    slot,
                    if (path) |selected| selected.tail else 0,
                    trace.position,
                ),
                .sequence_get => if (path) |selected| {
                    // Lookup returns Optional<Element>; only Some carries a borrow.
                    if (selected.step == .field and selected.step.field == 1) try self.pushAt(
                        pending,
                        trace.block,
                        op.operands[0],
                        try self.prepend(.element, selected.tail),
                        trace.position,
                    );
                } else try self.pushAt(
                    pending,
                    trace.block,
                    op.operands[0],
                    try self.prepend(.element, 0),
                    trace.position,
                ),
                .clone_resumption => try self.pushAt(
                    pending,
                    trace.block,
                    op.operands[0],
                    trace.path,
                    trace.position,
                ),
                .unpack => try self.pushAt(
                    pending,
                    trace.block,
                    op.operands[0],
                    try self.prepend(.package_token, trace.path),
                    trace.position,
                ),
                .package => if (path) |selected| {
                    if (selected.step == .package_token) try self.pushAt(
                        pending,
                        trace.block,
                        op.operands[0],
                        selected.tail,
                        trace.position,
                    );
                } else try self.pushAt(pending, trace.block, op.operands[0], 0, trace.position),
                .sequence_append,
                .sequence_concat,
                .sequence_pop,
                .sequence_set,
                .sequence_take,
                .sequence_pop_last,
                => try self.sequenceInstruction(pending, trace, op),
                .constant,
                .integer_add,
                .integer_sub,
                .integer_mul,
                .integer_div,
                .integer_rem,
                .integer_bit_not,
                .integer_bit_and,
                .integer_bit_or,
                .integer_bit_xor,
                .integer_convert,
                .enum_tag,
                .equal,
                .less,
                .boolean_not,
                .variant_tag,
                .sequence_length,
                .cell_set,
                .resource_pack,
                .resource_unpack,
                .blob_length,
                .blob_concat,
                .blob_slice,
                .blob_compare,
                .blob_byte,
                .text_scalar,
                .text_integer,
                .blob_from_byte,
                // Scalar results and owned resources with exportable representations
                // have no borrows.
                => {},
            }
        }

        fn call(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            function: p.Id,
            arguments: []const p.Id,
            path: usize,
        ) a.Error!void {
            const index = try self.query(self.entry(function), path);
            try self.transferSources(
                pending,
                .{ .block = block, .function = function, .arguments = arguments },
                index,
            );
        }

        fn body(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            computation_slot: p.Id,
            arguments: []const p.Id,
            supplied: usize,
            path: usize,
        ) a.Error!void {
            const schema = self.slotType(block, computation_slot);
            for (self.program.constructors, 0..) |constructor, id| {
                if (constructor.schema != schema) continue;
                const index = try self.query(self.entry(constructor.function), path);
                try self.transferSources(
                    pending,
                    self.bodyBinding(block, computation_slot, arguments, supplied, id),
                    index,
                );
            }
        }

        fn callWrites(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            function: p.Id,
            arguments: []const p.Id,
            schema: p.Id,
            path: usize,
        ) a.Error!void {
            const index = try self.writeQuery(self.entry(function), schema, path);
            try self.transferSources(
                pending,
                .{ .block = block, .function = function, .arguments = arguments },
                index,
            );
        }

        fn bodyWrites(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            computation_slot: p.Id,
            arguments: []const p.Id,
            supplied: usize,
            schema: p.Id,
            path: usize,
        ) a.Error!void {
            const computation_schema = self.slotType(block, computation_slot);
            for (self.program.constructors, 0..) |constructor, id| {
                if (constructor.schema != computation_schema) continue;
                const index = try self.writeQuery(self.entry(constructor.function), schema, path);
                try self.transferSources(
                    pending,
                    self.bodyBinding(block, computation_slot, arguments, supplied, id),
                    index,
                );
            }
        }

        fn calledWrites(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            schema: p.Id,
            path: usize,
        ) a.Error!void {
            switch (self.program.blocks[@intCast(block)].terminator) {
                .call => |v| try self.callWrites(
                    pending,
                    block,
                    v.function,
                    v.arguments,
                    schema,
                    path,
                ),
                .apply => |v| try self.bodyWrites(
                    pending,
                    block,
                    v.computation,
                    v.arguments,
                    0,
                    schema,
                    path,
                ),
                .with_region => |v| try self.bodyWrites(
                    pending,
                    block,
                    v.body,
                    v.arguments,
                    1,
                    schema,
                    path,
                ),
                .protect => |v| {
                    try self.bodyWrites(
                        pending,
                        block,
                        v.body,
                        v.arguments,
                        @intFromBool(v.resource != null),
                        schema,
                        path,
                    );
                    try self.bodyWrites(
                        pending,
                        block,
                        v.cleanup,
                        &.{},
                        if (v.resource == null) 1 else 2,
                        schema,
                        path,
                    );
                },
                .handle => |v| {
                    const handler = self.program.handlers[@intCast(v.handler)];
                    try self.bodyWrites(
                        pending,
                        block,
                        v.body,
                        v.arguments,
                        handler.clauses.len,
                        schema,
                        path,
                    );
                    const index = try self.writeQuery(
                        self.entry(handler.return_function),
                        schema,
                        path,
                    );
                    const sources = try self.allocator.dupe(
                        Source,
                        self.queries.items[index].sources.items,
                    );
                    defer self.allocator.free(sources);
                    for (sources) |source| try self.returnInput(pending, block, source);
                },
                .perform => |v| if (v.capability != null) {
                    for (self.control.targets(
                        .{ .block = block, .role = .operation },
                        v.effect,
                    )) |target| {
                        const index = try self.writeQuery(
                            self.entry(target.function),
                            schema,
                            path,
                        );
                        try self.transferSources(
                            pending,
                            .{
                                .block = block,
                                .function = target.function,
                                .arguments = &.{},
                                .handler = target.handler,
                                .operation = v,
                            },
                            index,
                        );
                    }
                },
                .resume_value => |v| {
                    try self.push(pending, block, v.resumption, 0);
                    try self.push(pending, block, v.argument, 0);
                },
                .resume_with => |v| {
                    try self.push(pending, block, v.resumption, 0);
                    try self.push(pending, block, v.argument, 0);
                    for (v.state) |slot| try self.push(pending, block, slot, 0);
                },
                .resume_computation => |v| {
                    try self.push(pending, block, v.resumption, 0);
                    try self.push(pending, block, v.computation, 0);
                },
                else => {},
            }
        }

        pub fn isOuter(self: Self, path: usize) bool {
            var cursor = path;
            while (cursor != 0) {
                const item = self.paths.items[cursor - 1];
                if (item.step == .outer) return true;
                cursor = item.tail;
            }
            return false;
        }

        fn output(
            self: *Self,
            pending: *std.ArrayList(Trace),
            block: p.Id,
            path: usize,
        ) a.Error!void {
            switch (self.program.blocks[@intCast(block)].terminator) {
                .call => |v| try self.call(pending, block, v.function, v.arguments, path),
                .apply => |v| try self.body(pending, block, v.computation, v.arguments, 0, path),
                .with_region => |v| try self.body(pending, block, v.body, v.arguments, 1, path),
                .protect => |v| try self.body(
                    pending,
                    block,
                    v.body,
                    v.arguments,
                    @intFromBool(v.resource != null),
                    path,
                ),
                .handle => |v| {
                    const handler = self.program.handlers[@intCast(v.handler)];
                    const returns = try self.query(self.entry(handler.return_function), path);
                    const sources = try self.allocator.dupe(
                        Source,
                        self.queries.items[returns].sources.items,
                    );
                    defer self.allocator.free(sources);
                    for (sources) |source| try self.returnInput(pending, block, source);
                    // A clause can return state or a borrow arriving from the body's
                    // older inputs. Fresh body capabilities are checked separately.
                    for (handler.clauses) |clause| {
                        if (!@import("contracts.zig").retainsResumption(clause)) continue;
                        const index = try self.query(self.entry(clause.function), path);
                        for (self.queries.items[index].sources.items) |source| {
                            if (source.ambient) |ambient| {
                                try self.pushTrace(
                                    pending,
                                    .{ .block = block, .ambient = ambient },
                                );
                            } else if (source.parameter < v.state.len) {
                                try self.push(
                                    pending,
                                    block,
                                    v.state[@intCast(source.parameter)],
                                    source.path,
                                );
                            } else {
                                try self.push(pending, block, v.body, 0);
                                for (v.arguments) |slot| try self.push(pending, block, slot, 0);
                                if (source.parameter == inputs.of(
                                    self.program.functions[
                                        @intCast(clause.function)
                                    ],
                                ).len - 1) {
                                    try self.pushTrace(
                                        pending,
                                        .{ .block = block, .ambient = .evidence },
                                    );
                                    try self.pushTrace(
                                        pending,
                                        .{ .block = block, .ambient = .region },
                                    );
                                }
                            }
                        }
                    }
                },
                .resume_value => |v| {
                    try self.push(pending, block, v.resumption, 0);
                    try self.push(pending, block, v.argument, 0);
                },
                .resume_with => |v| {
                    try self.push(pending, block, v.resumption, 0);
                    try self.push(pending, block, v.argument, 0);
                    for (v.state) |slot| try self.push(pending, block, slot, 0);
                },
                .resume_computation => |v| {
                    try self.push(pending, block, v.resumption, 0);
                    try self.push(pending, block, v.computation, 0);
                },
                .perform => |v| {
                    // Keep all incoming borrows for internal result schemas. External
                    // results are exportable and are removed by push's schema check.
                    if (v.capability) |slot| try self.push(
                        pending,
                        block,
                        slot,
                        try self.prepend(.{ .outer = null }, 0),
                    );
                    try self.push(pending, block, v.payload, 0);
                    for (v.bodies) |slot| try self.push(pending, block, slot, 0);
                    for (v.use_site_capabilities) |slot| try self.push(pending, block, slot, 0);
                },
                else => {},
            }
        }
    };
}

pub fn validate(
    allocator: std.mem.Allocator,
    program: activation.Program,
    exportable: []const bool,
    diagnostic: ?*a.Diagnostic,
) a.Error!void {
    return validateWithControl(
        allocator,
        program,
        exportable,
        diagnostic,
        try provenance.derive(allocator, program, &.{}, false),
    );
}

pub fn validateWithControl(
    allocator: std.mem.Allocator,
    program: activation.Program,
    exportable: []const bool,
    diagnostic: ?*a.Diagnostic,
    control: *const provenance.Analysis,
) a.Error!void {
    var flow = try FlowFor(false).initWithControl(allocator, program, exportable, control);
    flow.diagnostic = diagnostic;
    for (program.functions) |function| _ = try flow.requirementsQuery(function.entry);
    try flow.settle();
    try validateScopes(&flow);
}

/// Component admission uses declared import assumptions without dropping any
/// dependent query. The closed linker subsequently checks those assumptions.
pub fn contracted(
    allocator: std.mem.Allocator,
    program: activation.Program,
    imports: []const p.Id,
    exportable: []const bool,
    summaries: []const @import("borrow_contract.zig").Summary,
) a.Error!ComponentFlow {
    return contractedWithControl(
        allocator,
        program,
        imports,
        exportable,
        summaries,
        try provenance.derive(allocator, program, imports, true),
    );
}

pub fn contractedWithControl(
    allocator: std.mem.Allocator,
    program: activation.Program,
    imports: []const p.Id,
    exportable: []const bool,
    summaries: []const @import("borrow_contract.zig").Summary,
    control: *const provenance.Analysis,
) a.Error!ComponentFlow {
    var flow = try ComponentFlow.initWithControl(allocator, program, exportable, control);
    flow.import_summaries = summaries;
    var previous: ?p.Id = null;
    for (summaries) |summary| {
        if (previous) |prior| if (summary.function <= prior) return error.NonCanonical;
        previous = summary.function;
        try @import("borrow_contract.zig").validate(&flow, summary);
    }
    for (imports) |function| {
        for (summaries) |summary| {
            if (summary.function == function) break;
        } else return error.InvalidOwnership;
    }
    for (program.functions, 0..) |_, id| {
        if (std.mem.indexOfScalar(p.Id, imports, id) != null) continue;
        _ = try flow.requirementsQuery(flow.entry(id));
    }
    try flow.settle();
    try validateScopes(&flow);
    return flow;
}

fn validateScopes(flow: anytype) a.Error!void {
    const program = flow.program;
    for (program.blocks, 0..) |block, block_id| {
        const body_slot, const arguments, const supplied = switch (block.terminator) {
            .handle => |v| .{
                v.body,
                v.arguments,
                program.handlers[@intCast(v.handler)].clauses.len,
            },
            .with_region => |v| .{ v.body, v.arguments, @as(usize, 1) },
            .protect => |v| .{ v.body, v.arguments, @as(usize, @intFromBool(v.resource != null)) },
            else => continue,
        };
        const body_schema = flow.slotType(block_id, body_slot);
        for (program.constructors, 0..) |constructor, id| {
            if (constructor.schema != body_schema) continue;
            const start = flow.entry(constructor.function);
            const returned = try flow.returned(start);
            const binding = flow.bodyBinding(block_id, body_slot, arguments, supplied, id);
            for (returned) |source| {
                if ((try flow.mapInput(binding, source)).fresh != null) {
                    return flow.rejected(binding);
                }
            }
        }
    }
}

fn sparseReachabilityAttempt(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const program: activation.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.unit},
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
        }},
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{},
                .terminator = .{ .branch = .{
                    .condition = 0,
                    .when_true = .{ .block = 4 },
                    .when_false = .{ .block = 2 },
                } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 4 } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 1 } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 0 } } },
        },
    };
    var flow = try StableFlow.initWithControl(memory, program, &.{true}, undefined);
    for (
        [_]p.Id{ 0, 1, 2, 3, 4 },
        [_][]const p.Id{ &.{ 0, 2, 4 }, &.{1}, &.{ 0, 2, 4 }, &.{ 1, 3 }, &.{ 0, 2, 4 } },
    ) |start, expected| {
        const reach = try flow.reachable(start, memory);
        try std.testing.expectEqualSlices(p.Id, expected, reach.blocks);
        for (
            reach.membership,
            0..,
        ) |member, id| try std.testing.expectEqual(
            std.mem.indexOfScalar(p.Id, expected, id) != null,
            member,
        );
    }
}

test "borrow reachability lists exact members in block order with cycles and allocation failures" {
    try @import("allocation_testing.zig").check(
        std.testing.allocator,
        sparseReachabilityAttempt,
        .{},
    );
}
