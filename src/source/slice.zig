const std = @import("std");
const source = @import("../source.zig");
const ast = @import("ast.zig");
const relocation = @import("relation_relocate.zig");
const bindings = @import("constructor_bindings.zig");
pub const Error = source.Error || error{ ImpureSlice, InvalidRelation, UnsupportedRelation };
pub const Request = struct {
    entry: source.Id,
    require_pure: bool = false,
};
pub const Output = struct {
    arena: std.heap.ArenaAllocator,
    original_entry: source.Id,
    selected_entry: source.Id,
    maps: relocation.Maps,
    generated_functions: usize = 0,
    emitted_constants: []const ?u64 = &.{},
    retained: ast.Module,

    pub fn deinit(self: *Output) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn module(self: *const Output) ast.Module {
        return self.retained;
    }
};

pub fn extract(
    allocator: std.mem.Allocator,
    original: ast.Module,
    request: Request,
) Error!Output {
    var output: Output = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .original_entry = original.entry,
        .selected_entry = request.entry,
        .maps = undefined,
        .retained = undefined,
    };
    errdefer output.deinit();
    const a = output.arena.allocator();
    var work: u64 = std.math.maxInt(u64);
    const catalog = try bindings.admitCatalog(allocator, a, original, &work);
    const constructors = catalog.constructors;
    var emitted = original;
    emitted.constants = catalog.constants;
    if (request.entry >= original.functions.len) return error.InvalidReference;
    output.maps = try dependencyMaps(
        a,
        allocator,
        emitted,
        request.entry,
        constructors,
    );
    const generated = try constructorHelpers(a, original, &output.maps, constructors);
    output.generated_functions = generated.functions.len;
    var selected = emitted;
    selected.entry = request.entry;
    output.retained = try relocation.relocateCatalogWithWork(
        a,
        selected,
        selected.constants,
        output.maps,
        generated,
        null,
    );
    output.emitted_constants = output.maps.constants;
    output.maps.constants = output.maps.constants[0..original.constants.len];
    const retained = try bindings.admit(allocator, a, output.retained, &work);
    try bindings.validate(
        original,
        constructors,
        retained,
        relocation.transport(output.maps),
        null,
    );
    if (request.require_pure) {
        const entry = output.retained.functions[@intCast(output.retained.entry)];
        if (entry.effects.len != 0) return error.ImpureSlice;
        for (output.retained.effects) |effect| if (effect.external) return error.ImpureSlice;
    }
    return output;
}

const catalogs = .{
    "schemas",   "constants", "effects", "handlers",  "resources",
    "variables", "values",    "terms",   "functions",
};
const kinds: [catalogs.len]relocation.Kind = .{
    .schema,   .constant, .effect, .handler,  .resource,
    .variable, .value,    .term,   .function,
};

const Closure = struct {
    allocator: std.mem.Allocator,
    maps: relocation.Maps,
    pending: std.ArrayList(relocation.Reference) = .empty,
    regions: std.AutoHashMapUnmanaged(source.Id, void) = .empty,

    fn include(self: *Closure, reference: relocation.Reference) Error!void {
        if (reference.kind == .region) {
            const found = try self.regions.getOrPut(self.allocator, reference.id);
            if (found.found_existing) return;
        } else {
            inline for (catalogs, kinds) |name, kind| {
                if (reference.kind == kind) {
                    const map = @field(self.maps, name);
                    if (reference.id >= map.len) return error.InvalidReference;
                    if (map[@intCast(reference.id)] != null) return;
                    @constCast(map)[@intCast(reference.id)] = 0;
                }
            }
        }
        try self.pending.append(self.allocator, reference);
    }
};

fn dependencyMaps(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    original: ast.Module,
    entry: source.Id,
    constructors: []const bindings.Binding,
) Error!relocation.Maps {
    var closure: Closure = .{ .allocator = allocator, .maps = .{} };
    inline for (catalogs) |name| {
        const map = try allocator.alloc(?source.Id, @field(original, name).len);
        @memset(map, null);
        @field(closure.maps, name) = map;
    }
    try closure.include(.{ .kind = .function, .id = entry });
    try closure.include(.{ .kind = .schema, .id = original.failure });
    var cursor: usize = 0;
    while (cursor < closure.pending.items.len) : (cursor += 1) {
        var scratch = std.heap.ArenaAllocator.init(scratch_allocator);
        defer scratch.deinit();
        var references: std.ArrayList(relocation.Reference) = .empty;
        const reference = closure.pending.items[cursor];
        try relocation.visitReferencesWithWork(
            scratch.allocator(),
            original,
            constructors,
            reference.kind,
            reference.id,
            &references,
            null,
        );
        for (references.items) |child| try closure.include(child);
    }
    inline for (catalogs) |name| {
        var next: source.Id = 0;
        for (@constCast(@field(closure.maps, name))) |*target| {
            if (target.* == null) continue;
            target.* = next;
            next += 1;
        }
    }
    try finalizeRegions(&closure, original.region_count);
    return closure.maps;
}

fn constructorHelpers(
    a: std.mem.Allocator,
    original: ast.Module,
    maps: *relocation.Maps,
    constructors: []const bindings.Binding,
) Error!relocation.Generated {
    const constructor_map = try a.alloc(?u64, constructors.len);
    @memset(constructor_map, null);
    for (original.values, maps.values) |value, retained| {
        if (retained == null) continue;
        if (bindings.raw(value)) |constructor| constructor_map[@intCast(constructor)] = 0;
    }
    var count: usize = 0;
    for (constructor_map) |*entry| if (entry.* != null) {
        entry.* = count;
        count += 1;
    };
    maps.constructors = constructor_map;
    for (@constCast(maps.functions)) |*entry| if (entry.*) |id| {
        entry.* = std.math.add(u64, id, count) catch return error.Capacity;
    };
    const functions = try a.alloc(ast.Function, count);
    const values = try a.alloc(ast.Value, count);
    const terms = try a.alloc(ast.Term, count);
    const value_start = relocation.mappedCount(maps.values);
    const term_start = relocation.mappedCount(maps.terms);
    _ = std.math.add(usize, value_start, count) catch return error.Capacity;
    _ = std.math.add(usize, term_start, count) catch return error.Capacity;
    for (constructors, constructor_map) |constructor, selected| {
        const index: usize = @intCast(selected orelse continue);
        const parameters = try a.alloc(u64, constructor.captures.len);
        for (parameters, constructor.captures) |*parameter, variable|
            parameter.* = try bindings.Transport.id(maps.variables, variable);
        const schema = try bindings.Transport.id(maps.schemas, constructor.schema);
        functions[index] = .{
            .parameters = parameters,
            .result = schema,
            .regions = original.functions[@intCast(constructor.function)].regions,
            .body = term_start + index,
        };
        values[index] = .{ .schema = schema, .expression = .{
            .lambda = try bindings.Transport.id(maps.functions, constructor.function),
        } };
        terms[index] = .{ .value = value_start + index };
    }
    return .{ .functions = functions, .values = values, .terms = terms };
}

fn finalizeRegions(closure: *Closure, count: source.Id) Error!void {
    const regions = try closure.allocator.alloc(relocation.Region, closure.regions.count());
    var iterator = closure.regions.keyIterator();
    var index: usize = 0;
    while (iterator.next()) |id| : (index += 1) {
        if (id.* >= count) return error.InvalidReference;
        regions[index] = .{ .old = id.*, .new = id.* };
    }
    std.mem.sort(relocation.Region, regions, {}, struct {
        fn less(_: void, left: relocation.Region, right: relocation.Region) bool {
            return left.old < right.old;
        }
    }.less);
    closure.maps.regions = regions;
    closure.maps.region_count = count;
}
