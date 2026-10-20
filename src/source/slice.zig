const std = @import("std");
const source = @import("../source.zig");
const ast = @import("ast.zig");
const relocation = @import("relation_relocate.zig");
pub const Error = source.Error || error{ ImpureSlice, InvalidRelation };
pub const Request = struct {
    entry: source.Id,
    require_pure: bool = false,
};
pub const Output = struct {
    arena: std.heap.ArenaAllocator,
    original_entry: source.Id,
    selected_entry: source.Id,
    maps: relocation.Maps,
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
    var admitted = try source.lower(allocator, original);
    admitted.deinit();
    if (request.entry >= original.functions.len) return error.InvalidReference;
    var output: Output = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .original_entry = original.entry,
        .selected_entry = request.entry,
        .maps = undefined,
        .retained = undefined,
    };
    errdefer output.deinit();
    output.maps = try dependencyMaps(
        output.arena.allocator(),
        allocator,
        original,
        request.entry,
    );
    var selected = original;
    selected.entry = request.entry;
    output.retained = try relocation.relocate(output.arena.allocator(), selected, output.maps);
    var readmitted = try source.lower(allocator, output.retained);
    defer readmitted.deinit();
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
        try relocation.visitReferences(
            scratch.allocator(),
            original,
            reference.kind,
            reference.id,
            &references,
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
