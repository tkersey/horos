// Copyright (c) 2026 Boundary contributors. MIT license.
//! Source-independent composition of checked first-order objects.
const std = @import("std");
const p = @import("program.zig");
const ir = @import("activation.zig");
const component = @import("component.zig");
const relocate = @import("relocation.zig");
const equal = @import("record.zig").equal;
const Kind = relocate.Kind;
const Id = p.Id;
pub const Instance = struct { key: []const u8, object: []const u8 };
pub const Endpoint = struct { instance: []const u8, symbol: []const u8 };
pub const Binding = struct { required: Endpoint, supplied: Endpoint };
pub const Error = @import("closed_compilation.zig").Error || component.Error || error{
    DuplicateInstance,
    MissingInstance,
    MissingSymbol,
    DuplicateBinding,
    UnresolvedImport,
    IncompatibleInterface,
    IncompatibleFailure,
};
pub const Linked = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    flow: @import("activation_flow.zig").Facts,
    pub fn deinit(self: *Linked) void {
        self.flow.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn encode(
        self: *const Linked,
        allocator: std.mem.Allocator,
        output: []u8,
    ) Error![]const u8 {
        return @import("program_image.zig").encode(allocator, self.program, output);
    }
};
const Unit = struct {
    key: []const u8,
    object: component.Object,
    offsets: [relocate.kind_count]usize,
    maps: relocate.Maps,
};

fn less(_: void, a: Instance, b: Instance) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}
fn unitAt(units: []const Unit, key: []const u8) Error!usize {
    for (units, 0..) |unit, i| if (std.mem.eql(u8, unit.key, key)) return i;
    return error.MissingInstance;
}
fn symbolAt(symbols: []const component.Symbol, name: []const u8) Error!relocate.Reference {
    for (symbols) |symbol| if (std.mem.eql(u8, symbol.name, name)) return symbol.reference;
    return error.MissingSymbol;
}
fn resolve(aliases: []const Id, imported: []const bool, start: usize) Error!usize {
    var cursor = start;
    var remaining = aliases.len;
    while (imported[cursor]) {
        if (remaining == 0 or aliases[cursor] == relocate.missing) return error.UnresolvedImport;
        remaining -= 1;
        cursor = @intCast(aliases[cursor]);
    }
    return cursor;
}

pub fn link(
    allocator: std.mem.Allocator,
    input: []const Instance,
    bindings: []const Binding,
    entry: Endpoint,
) Error!Linked {
    return linkWithOptions(allocator, input, bindings, entry, .{});
}

pub fn linkWithOptions(
    allocator: std.mem.Allocator,
    input: []const Instance,
    bindings: []const Binding,
    entry: Endpoint,
    options: @import("coalescing.zig").Options,
) Error!Linked {
    return linkWithCompilation(allocator, input, bindings, entry, .{ .coalescing = options });
}

pub fn linkWithCompilation(
    allocator: std.mem.Allocator,
    input: []const Instance,
    bindings: []const Binding,
    entry: Endpoint,
    options: @import("closed_compilation.zig").Options,
) Error!Linked {
    options.resetObservations();
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    const a = temporary.allocator();
    const sorted = try a.dupe(Instance, input);
    std.mem.sort(Instance, sorted, {}, less);
    const decoded = try a.alloc(component.Decoded, sorted.len);
    var initialized: usize = 0;
    defer for (decoded[0..initialized]) |*owner| owner.deinit();
    const units = try a.alloc(Unit, sorted.len);
    var totals = @as([relocate.kind_count]usize, @splat(0));
    try decodeUnits(allocator, sorted, units, decoded, &initialized, &totals);
    const imports = try resolveImports(a, units, bindings, totals);
    return finishLink(allocator, a, units, entry, imports, options);
}

const Imports = struct {
    imported: [relocate.kind_count][]bool,
    counts: [relocate.kind_count]usize,
};
fn resolveImports(
    a: std.mem.Allocator,
    units: []Unit,
    bindings: []const Binding,
    totals: [relocate.kind_count]usize,
) Error!Imports {
    var aliases: [relocate.kind_count][]Id = undefined;
    var imported: [relocate.kind_count][]bool = undefined;
    var maps: [relocate.kind_count][]Id = undefined;
    var counts = @as([relocate.kind_count]usize, @splat(0));
    for (&aliases, &imported, &maps, totals) |*alias, *is_import, *map, count| {
        alias.* = try a.alloc(Id, count);
        @memset(alias.*, relocate.missing);
        is_import.* = try a.alloc(bool, count);
        @memset(is_import.*, false);
        map.* = try a.alloc(Id, count);
        @memset(map.*, relocate.missing);
    }
    for (units) |unit| for (unit.object.imports) |symbol| {
        imported[@backingInt(symbol.reference.kind)][
            unit.offsets[@backingInt(symbol.reference.kind)] + @as(
                usize,
                @intCast(symbol.reference.id),
            )
        ] = true;
    };
    for (bindings) |binding| {
        const from = units[try unitAt(units, binding.required.instance)];
        const to = units[try unitAt(units, binding.supplied.instance)];
        const required = try symbolAt(from.object.imports, binding.required.symbol);
        const supplied = try symbolAt(to.object.exports, binding.supplied.symbol);
        if (required.kind != supplied.kind) return error.IncompatibleInterface;
        const kind = @backingInt(required.kind);
        const slot = from.offsets[kind] + @as(usize, @intCast(required.id));
        if (aliases[kind][slot] != relocate.missing) return error.DuplicateBinding;
        aliases[kind][slot] = to.offsets[kind] + supplied.id;
    }
    for (&maps, &counts, imported) |*map, *count, is_import| {
        for (is_import, 0..) |external, id| if (!external) {
            map.*[id] = count.*;
            count.* += 1;
        };
    }
    for (maps, aliases, imported) |map, alias, is_import| for (map, 0..) |*target, id| {
        if (is_import[id]) target.* = map[try resolve(alias, is_import, id)];
    };
    for (units) |*unit| for (
        &unit.maps,
        maps,
        unit.offsets,
        try relocate.sizes(unit.object.program),
    ) |*map, global, offset, count| {
        map.* = global[offset..][0..count];
    };
    return .{ .imported = imported, .counts = counts };
}
fn finishLink(
    allocator: std.mem.Allocator,
    a: std.mem.Allocator,
    units: []Unit,
    entry: Endpoint,
    imports: Imports,
    options: @import("closed_compilation.zig").Options,
) Error!Linked {
    const selected_unit = units[try unitAt(units, entry.instance)];
    const selected = try symbolAt(selected_unit.object.exports, entry.symbol);
    if (selected.kind != .function) return error.IncompatibleInterface;
    const selected_mapper: relocate.Mapper = .{ .allocator = a, .maps = selected_unit.maps };
    const root = try selected_mapper.id(.function, selected.id);
    var provisional = try assemble(a, units, imports.imported, imports.counts);
    provisional.roots = .{
        .entry = root,
        .result = provisional.functions[@intCast(root)].result,
        .failure = try selected_mapper.id(.schema, selected_unit.object.program.roots.failure),
    };
    const schema_map = try @import("schema_partition.zig").compute(a, provisional);
    var final_maps = try relocate.identityMaps(a, try relocate.sizes(provisional));
    final_maps[@backingInt(Kind.schema)] = schema_map;
    const result = try rewrite(a, provisional, final_maps);
    for (units) |*unit| {
        const mapped = try a.alloc(Id, unit.maps[@backingInt(Kind.schema)].len);
        for (
            mapped,
            unit.maps[@backingInt(Kind.schema)],
        ) |*target, id| target.* = schema_map[@intCast(id)];
        unit.maps[@backingInt(Kind.schema)] = mapped;
        const mapper: relocate.Mapper = .{ .allocator = a, .maps = unit.maps };
        if (try mapper.id(
            .schema,
            unit.object.program.roots.failure,
        ) != result.roots.failure) return error.IncompatibleFailure;
        for (unit.object.imports) |symbol| try compatible(
            mapper,
            unit.object.program,
            result,
            symbol.reference,
        );
    }
    var checked = try @import("activation_ownership.zig").analyze(allocator, result);
    defer checked.deinit();
    try checkBorrows(a, units, result);
    const optimized = try @import("closed_compilation.zig").run(allocator, result, options);
    return .{ .arena = optimized.arena, .program = optimized.program, .flow = optimized.flow };
}

fn decodeUnits(
    allocator: std.mem.Allocator,
    sorted: []const Instance,
    units: []Unit,
    decoded: []component.Decoded,
    initialized: *usize,
    totals: *[relocate.kind_count]usize,
) Error!void {
    for (sorted, units, decoded, 0..) |instance, *unit, *owner, i| {
        if (instance.key.len == 0 or !std.unicode.utf8ValidateSlice(
            instance.key,
        )) return error.InvalidSymbol;
        if (i != 0 and std.mem.eql(
            u8,
            sorted[i - 1].key,
            instance.key,
        )) return error.DuplicateInstance;
        owner.* = try component.decode(allocator, instance.object);
        initialized.* += 1;
        unit.* = .{
            .key = instance.key,
            .object = owner.object,
            .offsets = totals.*,
            .maps = undefined,
        };
        for (
            totals,
            try relocate.sizes(owner.object.program),
        ) |*total, count| total.* = std.math.add(
            usize,
            total.*,
            count,
        ) catch return error.InvalidLength;
        var entries: usize = 0;
        for (totals.*) |count| {
            entries = std.math.add(usize, entries, count) catch return error.Capacity;
            if (entries > component.max_catalog_entries) return error.Capacity;
        }
    }
}

fn checkBorrows(a: std.mem.Allocator, units: []const Unit, result: ir.Program) Error!void {
    const schemas = try @import("admission.zig").schemas(a, result.schemas);
    var borrow_flow = try @import("borrow_flow.zig").StableFlow.init(a, result, schemas.exportable);
    for (units) |unit| {
        const mapper: relocate.Mapper = .{ .allocator = a, .maps = unit.maps };
        for (unit.object.borrows) |summary| {
            const expected = try @import("borrow_contract.zig").relocated(mapper, summary);
            try @import("borrow_contract.zig").check(&borrow_flow, expected);
        }
        for (unit.object.imports) |symbol| switch (symbol.reference.kind) {
            .constructor => {
                const expected = unit.object.program.constructors[@intCast(symbol.reference.id)];
                const actual = result.constructors[
                    @intCast(try mapper.id(.constructor, symbol.reference.id))
                ];
                try callableBorrow(
                    &borrow_flow,
                    mapper,
                    unit.object,
                    expected.function,
                    actual.function,
                );
            },
            .handler => {
                const expected = unit.object.program.handlers[@intCast(symbol.reference.id)];
                const actual = result.handlers[
                    @intCast(try mapper.id(.handler, symbol.reference.id))
                ];
                try callableBorrow(
                    &borrow_flow,
                    mapper,
                    unit.object,
                    expected.return_function,
                    actual.return_function,
                );
                for (expected.clauses, actual.clauses) |left, right|
                    try callableBorrow(
                        &borrow_flow,
                        mapper,
                        unit.object,
                        left.function,
                        right.function,
                    );
            },
            else => {},
        };
    }
}

fn callableBorrow(
    flow: *@import("borrow_flow.zig").StableFlow,
    mapper: relocate.Mapper,
    object: component.Object,
    declared: Id,
    actual: Id,
) Error!void {
    for (object.borrows) |summary| {
        if (summary.function != declared) continue;
        var expected = try @import("borrow_contract.zig").relocated(mapper, summary);
        expected.function = actual;
        return @import("borrow_contract.zig").check(flow, expected);
    }
    return error.InvalidOwnership;
}

fn catalog(
    comptime T: type,
    comptime kind: Kind,
    allocator: std.mem.Allocator,
    units: []const Unit,
    imported: []const bool,
    count: usize,
    comptime method: anytype,
) Error![]const T {
    const result = try allocator.alloc(T, count);
    for (units) |unit| {
        const mapper: relocate.Mapper = .{ .allocator = allocator, .maps = unit.maps };
        const values = slice(kind, unit.object.program);
        for (values, 0..) |value, local| {
            if (imported[unit.offsets[@backingInt(kind)] + local]) continue;
            result[@intCast(try mapper.id(kind, local))] = try method(mapper, value);
        }
    }
    return result;
}
fn slice(comptime kind: Kind, program: ir.Program) switch (kind) {
    .schema => []const p.Schema,
    .constant => []const p.Literal,
    .effect => []const p.Effect,
    .function => []const ir.Function,
    .block => []const ir.Block,
    .handler => []const ir.Handler,
    .capture => []const p.Capture,
    .resource => []const p.Resource,
    .constructor => []const p.Constructor,
    .region => void,
} {
    return switch (kind) {
        .schema => program.schemas,
        .constant => program.constants,
        .effect => program.effects,
        .function => program.functions,
        .block => program.blocks,
        .handler => program.handlers,
        .capture => program.scopes.captures,
        .resource => program.scopes.resources,
        .constructor => program.constructors,
        .region => {},
    };
}
fn assemble(
    a: std.mem.Allocator,
    units: []const Unit,
    imported: [relocate.kind_count][]bool,
    counts: [relocate.kind_count]usize,
) Error!ir.Program {
    return .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = try assembleSchemas(a, units, imported, counts),
        .constants = try catalog(
            p.Literal,
            .constant,
            a,
            units,
            imported[1],
            counts[1],
            relocate.Mapper.literal,
        ),
        .effects = try catalog(
            p.Effect,
            .effect,
            a,
            units,
            imported[2],
            counts[2],
            relocate.Mapper.effect,
        ),
        .functions = try catalog(
            ir.Function,
            .function,
            a,
            units,
            imported[3],
            counts[3],
            relocate.Mapper.function,
        ),
        .blocks = try catalog(
            ir.Block,
            .block,
            a,
            units,
            imported[4],
            counts[4],
            relocate.Mapper.block,
        ),
        .handlers = try catalog(
            ir.Handler,
            .handler,
            a,
            units,
            imported[5],
            counts[5],
            relocate.Mapper.handler,
        ),
        .scopes = try assembleScopes(a, units, imported, counts),
        .constructors = try catalog(
            p.Constructor,
            .constructor,
            a,
            units,
            imported[9],
            counts[9],
            relocate.Mapper.constructor,
        ),
    };
}
fn assembleSchemas(
    a: std.mem.Allocator,
    units: []const Unit,
    imported: [relocate.kind_count][]bool,
    counts: [relocate.kind_count]usize,
) Error![]const p.Schema {
    return try catalog(
        p.Schema,
        .schema,
        a,
        units,
        imported[0],
        counts[0],
        relocate.Mapper.schema,
    );
}
fn assembleScopes(
    a: std.mem.Allocator,
    units: []const Unit,
    imported: [relocate.kind_count][]bool,
    counts: [relocate.kind_count]usize,
) Error!p.ScopeCatalog {
    return .{
        .captures = try catalog(
            p.Capture,
            .capture,
            a,
            units,
            imported[6],
            counts[6],
            relocate.Mapper.capture,
        ),
        .region_count = counts[7],
        .resources = try catalog(
            p.Resource,
            .resource,
            a,
            units,
            imported[8],
            counts[8],
            relocate.Mapper.resource,
        ),
    };
}
fn rewrite(a: std.mem.Allocator, program: ir.Program, maps: relocate.Maps) Error!ir.Program {
    const mapper: relocate.Mapper = .{ .allocator = a, .maps = maps };
    const schema_count = 1 + (std.mem.max(Id, maps[0]));
    const schemas = try a.alloc(p.Schema, @intCast(schema_count));
    const seen = try a.alloc(bool, schemas.len);
    @memset(seen, false);
    for (program.schemas, maps[0]) |value, mapped| if (!seen[@intCast(mapped)]) {
        schemas[@intCast(mapped)] = try mapper.schema(value);
        seen[@intCast(mapped)] = true;
    };
    var result = program;
    result.roots = .{
        .entry = program.roots.entry,
        .result = try mapper.id(.schema, program.roots.result),
        .failure = try mapper.id(.schema, program.roots.failure),
    };
    result.schemas = schemas;
    inline for (.{
        .{ "constants", relocate.Mapper.literal },
        .{ "effects", relocate.Mapper.effect },
        .{ "functions", relocate.Mapper.function },
        .{ "blocks", relocate.Mapper.block },
        .{ "handlers", relocate.Mapper.handler },
        .{ "constructors", relocate.Mapper.constructor },
    }) |item| {
        const T = std.meta.Elem(@TypeOf(@field(program, item[0])));
        const values = try a.alloc(T, @field(program, item[0]).len);
        for (
            values,
            @field(program, item[0]),
        ) |*target, source| target.* = try item[1](mapper, source);
        @field(result, item[0]) = values;
    }
    const captures = try a.alloc(p.Capture, program.scopes.captures.len);
    for (captures, program.scopes.captures) |*target, source| target.* = try mapper.capture(source);
    const resources = try a.alloc(p.Resource, program.scopes.resources.len);
    for (
        resources,
        program.scopes.resources,
    ) |*target, source| target.* = try mapper.resource(source);
    result.scopes = .{
        .captures = captures,
        .resources = resources,
        .region_count = program.scopes.region_count,
    };
    return result;
}
fn sameFunction(a: ir.Function, b: ir.Function) bool {
    if (a.inputs.len != b.inputs.len or a.result != b.result or !std.mem.eql(
        Id,
        a.effects,
        b.effects,
    ) or !std.mem.eql(Id, a.regions, b.regions)) return false;
    for (
        a.inputs,
        b.inputs,
    ) |left, right| if (a.layout.slots[
        @intCast(left)
    ] != b.layout.slots[
        @intCast(right)
    ]) return false;
    return true;
}
fn compatible(
    mapper: relocate.Mapper,
    local: ir.Program,
    linked: ir.Program,
    reference: relocate.Reference,
) Error!void {
    const id: usize = @intCast(reference.id);
    const target: usize = @intCast(try mapper.id(reference.kind, reference.id));
    const matches = switch (reference.kind) {
        .function => sameFunction(
            try mapper.function(local.functions[id]),
            linked.functions[target],
        ),
        .schema => equal(p.Schema, try mapper.schema(local.schemas[id]), linked.schemas[target]),
        .effect => blk: {
            var expected = try mapper.effect(local.effects[id]);
            expected.identity = linked.effects[target].identity; // Names are not nominal identity.
            break :blk equal(p.Effect, expected, linked.effects[target]);
        },
        .resource => try mapper.id(
            .schema,
            local.scopes.resources[id].representation,
        ) == linked.scopes.resources[target].representation,
        .region => true,
        .constructor => blk: {
            const expected = try mapper.constructor(local.constructors[id]);
            const actual = linked.constructors[target];
            break :blk expected.schema == actual.schema and equal(
                p.Capture,
                linked.scopes.captures[@intCast(expected.capture)],
                linked.scopes.captures[@intCast(actual.capture)],
            ) and
                sameFunction(
                    linked.functions[@intCast(expected.function)],
                    linked.functions[@intCast(actual.function)],
                );
        },
        .handler => blk: {
            var expected = try mapper.handler(local.handlers[id]);
            const actual = linked.handlers[target];
            if (expected.clauses.len != actual.clauses.len) break :blk false;
            if (!sameFunction(
                linked.functions[@intCast(expected.return_function)],
                linked.functions[@intCast(actual.return_function)],
            )) break :blk false;
            expected.return_function = actual.return_function;
            const clauses = try mapper.allocator.dupe(ir.Clause, expected.clauses);
            for (clauses, actual.clauses) |*clause, supplied| {
                if (!sameFunction(
                    linked.functions[@intCast(clause.function)],
                    linked.functions[@intCast(supplied.function)],
                )) break :blk false;
                clause.function = supplied.function;
            }
            expected.clauses = clauses;
            break :blk equal(ir.Handler, expected, actual);
        },
        else => return error.InvalidImport,
    };
    if (!matches) return error.IncompatibleInterface;
}
