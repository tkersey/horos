// Copyright (c) 2026 Boundary contributors. MIT license.
//! Typed stable-record relocation. Slot numbers, ordinals and custody IDs stay local.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const roles = @import("reference_roles.zig");
const spend = @import("admission.zig").spend;
pub const Kind = enum(u8) {
    schema,
    constant,
    effect,
    function,
    block,
    handler,
    capture,
    region,
    resource,
    constructor,
};
pub const Reference = struct { kind: Kind, id: p.Id };
pub const kind_count = @typeInfo(Kind).@"enum".field_names.len;
pub const missing = std.math.maxInt(p.Id);
pub const Error = @import("admission.zig").Error;
pub const Maps = [kind_count][]const p.Id;

/// Caller owns each returned slice. No partial allocation escapes on failure.
pub fn identityMaps(a: std.mem.Allocator, counts: [kind_count]usize) Error!Maps {
    return identityMapsWithWork(a, counts, null);
}

pub fn identityMapsWithWork(
    a: std.mem.Allocator,
    counts: [kind_count]usize,
    work: ?*u64,
) Error!Maps {
    var result: Maps = undefined;
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |map| a.free(map);
    for (&result, counts) |*map, count| {
        try spend(work, count);
        const values = try a.alloc(p.Id, count);
        for (values, 0..) |*value, index| value.* = index;
        map.* = values;
        initialized += 1;
    }
    return result;
}

pub fn sortIdsWithWork(ids: []p.Id, work: ?*u64) Error!void {
    if (work) |left| {
        const levels: u64 = @bitSizeOf(usize) - @clz(ids.len);
        const visits = std.math.mul(u64, ids.len, 2 * levels + 3) catch return error.RelationLimit;
        try spend(left, visits);
        std.sort.heap(p.Id, ids, {}, std.sort.asc(p.Id));
    } else std.mem.sort(p.Id, ids, {}, std.sort.asc(p.Id));
}

const RegionNames = struct {
    allocator: std.mem.Allocator,
    declared: p.Id,
    work: ?*u64,
    ids: std.AutoHashMapUnmanaged(p.Id, p.Id) = .empty,

    fn id(self: *RegionNames, old: p.Id) Error!p.Id {
        if (old >= self.declared) return error.InvalidReference;
        if (self.work) |left| {
            const occupied: u64 = self.ids.count();
            try spend(left, occupied + 1);
            if (self.ids.available == 0) {
                try spend(left, @as(u64, self.ids.capacity()) * 3 + 8);
                try spend(left, occupied * (occupied + 1));
            }
        }
        const entry = try self.ids.getOrPut(self.allocator, old);
        if (!entry.found_existing) entry.value_ptr.* = self.ids.count() - 1;
        return entry.value_ptr.*;
    }
};

pub fn sizes(program: ir.Program) Error![kind_count]usize {
    const regions = std.math.cast(usize, program.scopes.region_count) orelse return error.Capacity;
    return .{
        program.schemas.len,
        program.constants.len,
        program.effects.len,
        program.functions.len,
        program.blocks.len,
        program.handlers.len,
        program.scopes.captures.len,
        regions,
        program.scopes.resources.len,
        program.constructors.len,
    };
}
pub const Mapper = struct {
    allocator: std.mem.Allocator,
    maps: Maps,
    region_names: ?*RegionNames = null,
    references: ?*std.ArrayList(Reference) = null,
    work: ?*u64 = null,
    collect_only: bool = false,

    pub fn id(self: Mapper, kind: Kind, value: p.Id) Error!p.Id {
        try spend(self.work, 1);
        if (self.references) |found| {
            if (found.items.len == found.capacity) try spend(self.work, found.items.len);
            try found.append(self.allocator, .{ .kind = kind, .id = value });
        }
        if (kind == .region) if (self.region_names) |names| return names.id(value);
        if (self.collect_only) return value;
        const map = self.maps[@backingInt(kind)];
        if (value >= map.len or map[@intCast(value)] == missing) return error.InvalidReference;
        return map[@intCast(value)];
    }
    fn ids(self: Mapper, kind: Kind, values: []const p.Id, set: bool) Error![]const p.Id {
        if (self.collect_only) {
            for (values) |value| _ = try self.id(kind, value);
            return values;
        }
        try spend(self.work, values.len);
        const result = try self.allocator.alloc(p.Id, values.len);
        for (result, values) |*target, value| target.* = try self.id(kind, value);
        if (!set) return result;
        try sortIdsWithWork(result, self.work);
        var count: usize = 0;
        for (result) |value| if (count == 0 or result[count - 1] != value) {
            result[count] = value;
            count += 1;
        };
        return result[0..count];
    }
    fn local(self: Mapper, comptime T: type, values: []const T) Error![]const T {
        if (self.collect_only) return values;
        try spend(self.work, values.len);
        return self.allocator.dupe(T, values);
    }
    pub fn schema(self: Mapper, value: p.Schema) Error!p.Schema {
        return switch (value) {
            .product => |v| .{ .product = try self.ids(.schema, v, false) },
            .sum => |v| .{ .sum = try self.ids(.schema, v, false) },
            .seq => |v| .{ .seq = try self.id(.schema, v) },
            .vector => |v| .{ .vector = .{
                .element = try self.id(.schema, v.element),
                .maximum = v.maximum,
            } },
            .array => |v| .{ .array = .{
                .element = try self.id(.schema, v.element),
                .length = v.length,
            } },
            .enumeration => |v| .{ .enumeration = try self.local(u32, v) },
            .internal => |v| .{ .internal = switch (v) {
                .computation => |c| .{ .computation = .{
                    .parameters = try self.ids(.schema, c.parameters, false),
                    .result = try self.id(.schema, c.result),
                    .effects = try self.ids(.effect, c.effects, true),
                    .capture_bound = try self.ids(.schema, c.capture_bound, true),
                    .use = c.use,
                    .regions = try self.ids(.region, c.regions, true),
                } },
                .resumption => |c| .{ .resumption = .{
                    .effect = try self.id(.effect, c.effect),
                    .input = try self.id(.schema, c.input),
                    .answer = try self.id(.schema, c.answer),
                    .effects = try self.ids(.effect, c.effects, true),
                    .capture_bound = try self.ids(.schema, c.capture_bound, true),
                    .handled = try self.ids(.effect, c.handled, false),
                    .escaping = try self.ids(.effect, c.escaping, true),
                    .mode = c.mode,
                    .use = c.use,
                    .owned_regions = try self.ids(.region, c.owned_regions, true),
                    .obligations = c.obligations,
                } },
                .capability => |v_| .{ .capability = try self.id(.effect, v_) },
                .cell => |v_| .{ .cell = .{
                    .element = try self.id(.schema, v_.element),
                    .region = try self.id(.region, v_.region),
                } },
                .region => |v_| .{ .region = try self.id(.region, v_) },
                .suspension_package => |v_| .{ .suspension_package = try self.id(.schema, v_) },
                .abstract_resource => |v_| .{ .abstract_resource = try self.id(.resource, v_) },
                .borrowed => |v_| .{ .borrowed = .{
                    .value = try self.id(.schema, v_.value),
                    .region = try self.id(.region, v_.region),
                } },
            } },
            else => value,
        };
    }
    pub fn literal(self: Mapper, value: p.Literal) Error!p.Literal {
        return .{
            .schema = try self.id(.schema, value.schema),
            .bytes = try self.local(u8, value.bytes),
        };
    }
    pub fn effect(self: Mapper, value: p.Effect) Error!p.Effect {
        return .{
            .identity = try self.local(u8, value.identity),
            .payload = try self.id(.schema, value.payload),
            .result = try self.id(.schema, value.result),
            .use_site_effects = try self.ids(.effect, value.use_site_effects, false),
            .bodies = try self.ids(.schema, value.bodies, false),
            .control_use = value.control_use,
            .external = value.external,
        };
    }
    pub fn function(self: Mapper, value: ir.Function) Error!ir.Function {
        return .{
            .entry = if (value.entry == missing) missing else try self.id(.block, value.entry),
            .inputs = try self.local(p.Id, value.inputs),
            .layout = .{ .slots = try self.ids(.schema, value.layout.slots, false) },
            .custody = try self.local(ir.CustodyScope, value.custody),
            .result = try self.id(.schema, value.result),
            .effects = try self.ids(.effect, value.effects, true),
            .regions = try self.ids(.region, value.regions, true),
        };
    }
    fn records(
        self: Mapper,
        comptime T: type,
        values: []const T,
        comptime map: fn (Mapper, T) Error!T,
    ) Error![]const T {
        try spend(self.work, values.len);
        if (self.collect_only) {
            for (values) |value| _ = try map(self, value);
            return values;
        }
        const result = try self.allocator.alloc(T, values.len);
        for (values, result) |value, *target| target.* = try map(self, value);
        return result;
    }
    fn failure(self: Mapper, value: p.InstructionFailure) Error!p.InstructionFailure {
        return .{ .kind = value.kind, .value = try self.id(.constant, value.value) };
    }
    fn instruction(self: Mapper, value: ir.Instruction) Error!ir.Instruction {
        const failures = try self.records(p.InstructionFailure, value.failures, failure);
        return .{
            .destination = value.destination,
            .opcode = value.opcode,
            .operands = try self.local(p.Id, value.operands),
            .failures = failures,
            .immediate = switch (@import("opcode_contract.zig").describe(
                value.opcode,
            ).immediate_role) {
                .constant => try self.id(.constant, value.immediate),
                .constructor => try self.id(.constructor, value.immediate),
                .numeric => value.immediate,
            },
        };
    }
    pub fn block(self: Mapper, value: ir.Block) Error!ir.Block {
        const instructions = try self.records(ir.Instruction, value.instructions, instruction);
        return .{
            .function = try self.id(.function, value.function),
            .custody = value.custody,
            .instructions = instructions,
            .terminator = try self.terminator(value.terminator),
        };
    }
    fn terminator(self: Mapper, value: ir.Terminator) Error!ir.Terminator {
        var control: ControlMapper = .{ .mapper = self };
        return roles.mapTerminator(value, &control);
    }
    fn clause(self: Mapper, value: ir.Clause) Error!ir.Clause {
        return .{
            .effect = try self.id(.effect, value.effect),
            .function = try self.id(.function, value.function),
            .resumption = try self.id(.schema, value.resumption),
            .strategy = value.strategy,
        };
    }
    pub fn handler(self: Mapper, value: ir.Handler) Error!ir.Handler {
        const clauses = try self.records(ir.Clause, value.clauses, clause);
        return .{
            .mode = value.mode,
            .input = try self.id(.schema, value.input),
            .answer = try self.id(.schema, value.answer),
            .return_function = try self.id(.function, value.return_function),
            .clauses = clauses,
            .state = try self.ids(.schema, value.state, false),
            .effects = try self.ids(.effect, value.effects, true),
        };
    }
    pub fn capture(self: Mapper, value: p.Capture) Error!p.Capture {
        return .{
            .fields = try self.ids(.schema, value.fields, false),
            .owned_regions = try self.ids(.region, value.owned_regions, true),
            .borrowed_regions = try self.ids(.region, value.borrowed_regions, true),
            .use = value.use,
        };
    }
    pub fn resource(self: Mapper, value: p.Resource) Error!p.Resource {
        return .{
            .representation = try self.id(.schema, value.representation),
            .introducers = try self.ids(.function, value.introducers, true),
            .eliminators = try self.ids(.function, value.eliminators, true),
        };
    }
    pub fn constructor(self: Mapper, value: p.Constructor) Error!p.Constructor {
        return .{
            .function = try self.id(.function, value.function),
            .capture = try self.id(.capture, value.capture),
            .schema = try self.id(.schema, value.schema),
        };
    }
};

const ControlMapper = struct {
    pub const VisitError = Error;
    mapper: Mapper,
    pub inline fn reference(
        self: *ControlMapper,
        comptime role: roles.Role,
        comptime cardinality: roles.Cardinality,
        value: anytype,
    ) Error!@TypeOf(value) {
        if (comptime cardinality == .optional) return if (value) |present| try self.reference(
            role,
            .one,
            present,
        ) else null;
        if (comptime cardinality == .list) {
            if (self.mapper.collect_only) {
                if (role == .slot_read or role == .slot_write or role == .nonreference)
                    return value;
                try spend(self.mapper.work, value.len);
                for (value) |item| _ = try self.reference(role, .one, item);
                return value;
            }
            try spend(self.mapper.work, value.len);
            const Child = @typeInfo(@TypeOf(value)).pointer.child;
            const result = try self.mapper.allocator.alloc(Child, value.len);
            for (value, result) |item, *out| out.* = try self.reference(role, .one, item);
            return result;
        }
        return switch (role) {
            .slot_read, .slot_write, .nonreference => value,
            .function => try self.mapper.id(.function, value),
            .effect => try self.mapper.id(.effect, value),
            .handler => try self.mapper.id(.handler, value),
            .region => try self.mapper.id(.region, value),
            .block => try self.mapper.id(.block, value),
            .edge => try roles.mapEdge(value, self),
            .assignment => try roles.mapAssignment(value, self),
            .source => try roles.mapSource(value, self),
        };
    }
};

/// Program fields own output storage. Origins and correspondence borrow scratch;
/// they grant no admission and must not escape the compiler/linker call.
pub const Projection = struct {
    program: ir.Program,
    function_origins: []const p.Id,
    maps: ?Maps = null,
    regions: std.AutoHashMapUnmanaged(p.Id, p.Id) = .empty,

    pub fn mapped(self: Projection, kind: Kind, old: p.Id) Error!p.Id {
        return self.mappedWithWork(kind, old, null);
    }

    pub fn mappedWithWork(self: Projection, kind: Kind, old: p.Id, work: ?*u64) Error!p.Id {
        try spend(work, 1);
        if (kind == .region) {
            try spend(work, self.regions.count());
            return self.regions.get(old) orelse error.InvalidReference;
        }
        const maps = self.maps orelse return error.InvalidReference;
        const map = maps[@backingInt(kind)];
        if (old >= map.len or map[@intCast(old)] == missing) return error.InvalidReference;
        return map[@intCast(old)];
    }
};

/// Project an already checked closed Program onto its typed reference closure.
/// All catalog declarations retain their relative order and nominal distinction.
/// Components must retain their interfaces; their unlinked objects do not use this.
pub fn ownReachable(
    output: std.mem.Allocator,
    scratch: std.mem.Allocator,
    input: ir.Program,
) Error!Projection {
    return ownReachableWithWork(output, scratch, input, null);
}

pub fn reachableBlocks(
    scratch: std.mem.Allocator,
    input: ir.Program,
    work: *u64,
) Error![]bool {
    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();
    var selection = try Selection.init(arena.allocator(), input, work);
    try selection.scan(input);
    const live = selection.seen[@backingInt(Kind.block)];
    try spend(work, live.len);
    return scratch.dupe(bool, live);
}

pub fn ownReachableWithWork(
    output: std.mem.Allocator,
    scratch: std.mem.Allocator,
    input: ir.Program,
    work: ?*u64,
) Error!Projection {
    var selection = try Selection.init(scratch, input, work);
    try selection.scan(input);
    var orders: [kind_count][]p.Id = undefined;
    var maps: Maps = undefined;
    for (&maps, selection.seen, &orders) |*map, seen, *order| {
        try spend(work, seen.len);
        try spend(work, seen.len);
        const ids = try scratch.alloc(p.Id, seen.len);
        map.* = ids;
        var count: usize = 0;
        for (seen) |live| count += @intFromBool(live);
        order.* = try scratch.alloc(p.Id, count);
        count = 0;
        for (ids, seen, 0..) |*id, live, old| {
            id.* = if (live) count else missing;
            if (live) {
                order.*[count] = old;
                count += 1;
            }
        }
    }
    const mapper: Mapper = .{
        .allocator = output,
        .maps = maps,
        .region_names = &selection.regions,
        .work = work,
    };
    const result = try copySelected(mapper, input, orders, selection.regions.ids.count());
    return .{
        .program = result,
        .function_origins = orders[@backingInt(Kind.function)],
        .maps = maps,
        .regions = selection.regions.ids,
    };
}

/// Materialize selected whole records using the same typed field rewriter as
/// reachability. Representatives/final maps require independent validation.
pub fn ownQuotient(
    output: std.mem.Allocator,
    scratch: std.mem.Allocator,
    input: ir.Program,
    representatives: Maps,
    final: Maps,
) Error!ir.Program {
    return ownQuotientWithWork(output, scratch, input, representatives, final, null);
}

pub fn ownQuotientWithWork(
    output: std.mem.Allocator,
    scratch: std.mem.Allocator,
    input: ir.Program,
    representatives: Maps,
    final: Maps,
    work: ?*u64,
) Error!ir.Program {
    var orders: [kind_count][]p.Id = undefined;
    for (representatives, &orders, try sizes(input)) |map, *order, size| {
        if (map.len != size) return error.InvalidReference;
        try spend(work, size);
        try spend(work, size);
        var count: usize = 0;
        for (map, 0..) |representative, id| {
            if (representative >= size or map[@intCast(representative)] != representative)
                return error.InvalidReference;
            count += @intFromBool(representative == id);
        }
        order.* = try scratch.alloc(p.Id, count);
        count = 0;
        for (map, 0..) |representative, id| if (representative == id) {
            order.*[count] = id;
            count += 1;
        };
    }
    const mapper: Mapper = .{ .allocator = output, .maps = final, .work = work };
    return copySelected(mapper, input, orders, orders[@backingInt(Kind.region)].len);
}

fn copySelected(
    mapper: Mapper,
    input: ir.Program,
    orders: [kind_count][]p.Id,
    regions: p.Id,
) Error!ir.Program {
    const output = mapper.allocator;
    for (orders) |order| try spend(mapper.work, order.len);
    var result = input;
    result.roots = .{
        .entry = try mapper.id(.function, input.roots.entry),
        .result = try mapper.id(.schema, input.roots.result),
        .failure = try mapper.id(.schema, input.roots.failure),
    };
    inline for (.{
        .{ Kind.schema, "schemas", Mapper.schema },
        .{ Kind.constant, "constants", Mapper.literal },
        .{ Kind.effect, "effects", Mapper.effect },
        .{ Kind.function, "functions", Mapper.function },
        .{ Kind.block, "blocks", Mapper.block },
        .{ Kind.handler, "handlers", Mapper.handler },
        .{ Kind.constructor, "constructors", Mapper.constructor },
    }) |item| {
        const T = std.meta.Elem(@TypeOf(@field(input, item[1])));
        const order = orders[@backingInt(item[0])];
        const values = try output.alloc(T, order.len);
        for (
            values,
            order,
        ) |*target, old| target.* = try item[2](mapper, @field(input, item[1])[@intCast(old)]);
        @field(result, item[1]) = values;
    }
    const captures = try output.alloc(p.Capture, orders[@backingInt(Kind.capture)].len);
    for (captures, orders[@backingInt(Kind.capture)]) |*target, old|
        target.* = try mapper.capture(input.scopes.captures[@intCast(old)]);
    const resources = try output.alloc(p.Resource, orders[@backingInt(Kind.resource)].len);
    for (resources, orders[@backingInt(Kind.resource)]) |*target, old|
        target.* = try mapper.resource(input.scopes.resources[@intCast(old)]);
    result.scopes = .{ .captures = captures, .resources = resources, .region_count = regions };
    return result;
}

const Selection = struct {
    allocator: std.mem.Allocator,
    work: ?*u64,
    seen: [kind_count][]bool,
    regions: RegionNames,

    fn init(allocator: std.mem.Allocator, input: ir.Program, work: ?*u64) Error!Selection {
        var result: Selection = .{
            .allocator = allocator,
            .work = work,
            .seen = undefined,
            .regions = .{
                .allocator = allocator,
                .declared = input.scopes.region_count,
                .work = work,
            },
        };
        // Region names are sparse nominal IDs, not a dense allocation bound.
        const counts = [_]usize{
            input.schemas.len,
            input.constants.len,
            input.effects.len,
            input.functions.len,
            input.blocks.len,
            input.handlers.len,
            input.scopes.captures.len,
            0,
            input.scopes.resources.len,
            input.constructors.len,
        };
        for (&result.seen, counts) |*seen, count| {
            try spend(work, count);
            seen.* = try allocator.alloc(bool, count);
            @memset(seen.*, false);
        }
        return result;
    }

    fn scan(self: *Selection, input: ir.Program) Error!void {
        try spend(self.work, 3);
        var pending: std.ArrayList(Reference) = .empty;
        try pending.appendSlice(
            self.allocator,
            &.{
                .{ .kind = .function, .id = input.roots.entry },
                .{ .kind = .schema, .id = input.roots.result },
                .{ .kind = .schema, .id = input.roots.failure },
            },
        );
        while (pending.pop()) |reference| {
            if (reference.kind == .region) {
                _ = try self.regions.id(reference.id);
                continue;
            }
            const kind = @backingInt(reference.kind);
            if (reference.id >= self.seen[kind].len) return error.InvalidReference;
            const id: usize = @intCast(reference.id);
            if (self.seen[kind][id]) continue;
            self.seen[kind][id] = true;
            const mapper: Mapper = .{
                .allocator = self.allocator,
                .maps = @splat(&.{}),
                .region_names = &self.regions,
                .references = &pending,
                .work = self.work,
                .collect_only = true,
            };
            switch (reference.kind) {
                .schema => _ = try mapper.schema(input.schemas[id]),
                .constant => _ = try mapper.literal(input.constants[id]),
                .effect => _ = try mapper.effect(input.effects[id]),
                .function => _ = try mapper.function(input.functions[id]),
                .block => _ = try mapper.block(input.blocks[id]),
                .handler => _ = try mapper.handler(input.handlers[id]),
                .capture => _ = try mapper.capture(input.scopes.captures[id]),
                .resource => _ = try mapper.resource(input.scopes.resources[id]),
                .constructor => _ = try mapper.constructor(input.constructors[id]),
                .region => unreachable,
            }
        }
    }
};
