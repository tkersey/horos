const std = @import("std");
const data = @import("horos_data");
const p = data.program;
const ast = @import("ast.zig");
const bindings = @import("constructor_bindings.zig");
pub const Error = @import("../source.zig").Error || error{ InvalidRelation, UnsupportedRelation };
pub const Kind = enum {
    schema,
    constant,
    effect,
    handler,
    resource,
    region,
    variable,
    value,
    term,
    function,
};
pub const Reference = struct { kind: Kind, id: u64 };
pub const Region = struct { old: u64, new: u64 };
pub const Maps = struct {
    schemas: []const ?u64 = &.{},
    constants: []const ?u64 = &.{},
    effects: []const ?u64 = &.{},
    handlers: []const ?u64 = &.{},
    resources: []const ?u64 = &.{},
    variables: []const ?u64 = &.{},
    values: []const ?u64 = &.{},
    terms: []const ?u64 = &.{},
    functions: []const ?u64 = &.{},
    regions: []const Region = &.{},
    region_count: u64 = 0,
    constructors: []const ?u64 = &.{},
};
pub const Generated = struct {
    functions: []const ast.Function = &.{},
    values: []const ast.Value = &.{},
    terms: []const ast.Term = &.{},
};

pub fn transport(maps: Maps) bindings.Transport {
    return .{
        .functions = maps.functions,
        .schemas = maps.schemas,
        .variables = maps.variables,
        .values = maps.values,
        .constructors = if (maps.constructors.len == 0) null else maps.constructors,
    };
}
const catalogs = .{
    "schemas",
    "constants",
    "effects",
    "handlers",
    "resources",
    "variables",
    "values",
    "terms",
    "functions",
};

pub fn validateMaps(
    a: std.mem.Allocator,
    module: ast.Module,
    maps: Maps,
    bijection: bool,
) Error!void {
    return validateMapsWithWork(a, module, maps, bijection, 0, null);
}

pub fn validateMapsWithWork(
    a: std.mem.Allocator,
    module: ast.Module,
    maps: Maps,
    bijection: bool,
    functions_prefix: usize,
    work: ?*u64,
) Error!void {
    inline for (catalogs) |name| {
        const map = @field(maps, name);
        if (map.len != @field(module, name).len) return error.InvalidRelation;
        try data.admission.spend(work, map.len);
        const count = mappedCount(map);
        const prefix = if (comptime std.mem.eql(u8, name, "functions")) functions_prefix else 0;
        if (bijection and count != map.len) return error.InvalidRelation;
        try data.admission.spend(work, count);
        const seen = try a.alloc(bool, count);
        defer a.free(seen);
        @memset(seen, false);
        for (map) |maybe| if (maybe) |id_| {
            try data.admission.spend(work, 1);
            if (id_ < prefix or id_ - prefix >= count or seen[@intCast(id_ - prefix)])
                return error.InvalidRelation;
            seen[@intCast(id_ - prefix)] = true;
        };
    }
    if (bijection and maps.region_count != module.region_count) return error.InvalidRelation;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(a);
    for (maps.regions, 0..) |region, i| {
        try data.admission.spend(work, 1);
        if (region.old >= module.region_count or region.new >= maps.region_count)
            return error.InvalidRelation;
        if (i != 0 and maps.regions[i - 1].old >= region.old) return error.InvalidRelation;
        if ((bijection or maps.region_count == module.region_count) and
            region.old != region.new and try findRegion(maps, region.new, work) == null)
            return error.InvalidRelation;
        const item = try seen.getOrPut(a, region.new);
        if (item.found_existing) return error.InvalidRelation;
    }
}
pub fn mappedCount(map: []const ?u64) usize {
    var count: usize = 0;
    for (map) |id_| count += @intFromBool(id_ != null);
    return count;
}
fn findRegion(maps: Maps, old: u64, work: ?*u64) Error!?u64 {
    var low: usize = 0;
    var high = maps.regions.len;
    while (low < high) {
        try data.admission.spend(work, 1);
        const mid = low + (high - low) / 2;
        const region = maps.regions[mid];
        if (region.old == old) return region.new;
        if (region.old < old) low = mid + 1 else high = mid;
    }
    return null;
}

pub fn relocate(a: std.mem.Allocator, module: ast.Module, maps: Maps) Error!ast.Module {
    return relocateWithWork(a, module, maps, .{}, null);
}

pub fn relocateWithWork(
    a: std.mem.Allocator,
    module: ast.Module,
    maps: Maps,
    generated: Generated,
    work: ?*u64,
) Error!ast.Module {
    try validateMapsWithWork(a, module, maps, false, generated.functions.len, work);
    const mapper: Mapper = .{
        .a = a,
        .maps = maps,
        .region_original_count = module.region_count,
        .work = work,
    };
    var result = module;
    result.entry = try mapper.id(.function, module.entry);
    result.failure = try mapper.id(.schema, module.failure);
    result.region_count = maps.region_count;
    inline for (catalogs) |name| {
        const values = @field(module, name);
        const map = @field(maps, name);
        const T = std.meta.Elem(@TypeOf(values));
        try data.admission.spend(work, map.len);
        const added: []const T = if (comptime @hasField(Generated, name))
            @field(generated, name)
        else
            &.{};
        const count = std.math.add(usize, mappedCount(map), added.len) catch
            return error.Capacity;
        try data.admission.spend(work, count);
        const output = try a.alloc(T, count);
        for (map, values) |maybe, value_| if (maybe) |new| {
            output[@intCast(new)] = try @field(Mapper, name)(mapper, value_);
        };
        const start = if (comptime std.mem.eql(u8, name, "functions")) 0 else count - added.len;
        for (added, output[start..][0..added.len]) |item, *out|
            out.* = try @import("../source.zig").own(T, a, item);
        @field(result, name) = output;
    }
    return result;
}

pub fn visitReferences(
    a: std.mem.Allocator,
    module: ast.Module,
    kind: Kind,
    index: u64,
    sink: *std.ArrayList(Reference),
) Error!void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var work: u64 = std.math.maxInt(u64);
    const constructors = if (kind == .value and index < module.values.len and
        bindings.raw(module.values[@intCast(index)]) != null)
        try bindings.admit(a, arena.allocator(), module, &work)
    else
        &.{};
    return visitReferencesWithWork(a, module, constructors, kind, index, sink, null);
}

pub fn visitReferencesWithWork(
    a: std.mem.Allocator,
    module: ast.Module,
    constructors: []const bindings.Binding,
    kind: Kind,
    index: u64,
    sink: *std.ArrayList(Reference),
    work: ?*u64,
) Error!void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mapper: Mapper = .{
        .a = arena.allocator(),
        .constructors = constructors,
        .work = work,
        .references = .{ .allocator = a, .sink = sink },
    };
    try data.admission.spend(work, 1);
    switch (kind) {
        .region => try sink.append(a, .{ .kind = .region, .id = index }),
        inline else => |tag| {
            const name = @tagName(tag) ++ "s";
            const values_ = @field(module, name);
            if (index >= values_.len) return error.InvalidRelation;
            _ = try @field(Mapper, name)(mapper, values_[@intCast(index)]);
        },
    }
}

const Mapper = struct {
    a: std.mem.Allocator,
    maps: Maps = .{},
    region_original_count: u64 = 0,
    constructors: []const bindings.Binding = &.{},
    work: ?*u64 = null,
    references: ?struct { allocator: std.mem.Allocator, sink: *std.ArrayList(Reference) } = null,
    fn dupe(self: Mapper, comptime T: type, input: []const T) Error![]const T {
        try data.admission.spend(self.work, input.len);
        return self.a.dupe(T, input);
    }
    fn id(self: Mapper, kind: Kind, old: u64) Error!u64 {
        try data.admission.spend(self.work, 1);
        if (self.references) |references| {
            try references.sink.append(references.allocator, .{ .kind = kind, .id = old });
            return old;
        }
        if (kind == .region) {
            if (old >= self.region_original_count) return error.InvalidRelation;
            if (try findRegion(self.maps, old, self.work)) |new| return new;
            if (self.maps.region_count == self.region_original_count) return old;
            return error.InvalidRelation;
        }
        const map = switch (kind) {
            .region => unreachable,
            inline else => |tag| @field(self.maps, @tagName(tag) ++ "s"),
        };
        if (old >= map.len) return error.InvalidRelation;
        return map[@intCast(old)] orelse error.InvalidRelation;
    }
    fn ids(self: Mapper, kind: Kind, input: []const u64, set: bool) Error![]const u64 {
        try data.admission.spend(self.work, input.len);
        const output = try self.a.alloc(u64, input.len);
        for (output, input) |*out, old| out.* = try self.id(kind, old);
        if (set) try sortIds(output, self.work);
        return output;
    }
    fn schemas(self: Mapper, value_: p.Schema) Error!p.Schema {
        return switch (value_) {
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
            .enumeration => |v| .{ .enumeration = try self.dupe(u32, v) },
            .internal => |v| .{ .internal = try self.internal(v) },
            else => value_,
        };
    }
    fn internal(self: Mapper, value_: p.Internal) Error!p.Internal {
        return switch (value_) {
            .computation => |v| .{ .computation = .{
                .parameters = try self.ids(.schema, v.parameters, false),
                .result = try self.id(.schema, v.result),
                .effects = try self.ids(.effect, v.effects, true),
                .capture_bound = try self.ids(.schema, v.capture_bound, true),
                .use = v.use,
                .regions = try self.ids(.region, v.regions, true),
            } },
            .resumption => |v| .{ .resumption = .{
                .effect = try self.id(.effect, v.effect),
                .input = try self.id(.schema, v.input),
                .answer = try self.id(.schema, v.answer),
                .effects = try self.ids(.effect, v.effects, true),
                .capture_bound = try self.ids(.schema, v.capture_bound, true),
                .handled = try self.ids(.effect, v.handled, false),
                .escaping = try self.ids(.effect, v.escaping, true),
                .mode = v.mode,
                .use = v.use,
                .owned_regions = try self.ids(.region, v.owned_regions, true),
                .obligations = v.obligations,
            } },
            .capability => |v| .{ .capability = try self.id(.effect, v) },
            .cell => |v| .{ .cell = .{
                .element = try self.id(.schema, v.element),
                .region = try self.id(.region, v.region),
            } },
            .region => |v| .{ .region = try self.id(.region, v) },
            .suspension_package => |v| .{ .suspension_package = try self.id(.schema, v) },
            .abstract_resource => |v| .{ .abstract_resource = try self.id(.resource, v) },
            .borrowed => |v| .{ .borrowed = .{
                .value = try self.id(.schema, v.value),
                .region = try self.id(.region, v.region),
            } },
        };
    }
    fn constants(self: Mapper, v: p.Literal) Error!p.Literal {
        return .{ .schema = try self.id(.schema, v.schema), .bytes = try self.dupe(u8, v.bytes) };
    }
    fn effects(self: Mapper, v: p.Effect) Error!p.Effect {
        return .{
            .identity = try self.dupe(u8, v.identity),
            .payload = try self.id(.schema, v.payload),
            .result = try self.id(.schema, v.result),
            .use_site_effects = try self.ids(.effect, v.use_site_effects, false),
            .bodies = try self.ids(.schema, v.bodies, false),
            .control_use = v.control_use,
            .external = v.external,
        };
    }
    fn handlers(self: Mapper, v: p.Handler) Error!p.Handler {
        try data.admission.spend(self.work, v.clauses.len);
        const clauses = try self.a.alloc(p.Clause, v.clauses.len);
        for (clauses, v.clauses) |*out, old| out.* = .{
            .effect = try self.id(.effect, old.effect),
            .function = try self.id(.function, old.function),
            .resumption = try self.id(.schema, old.resumption),
        };
        return .{
            .mode = v.mode,
            .input = try self.id(.schema, v.input),
            .answer = try self.id(.schema, v.answer),
            .return_function = try self.id(.function, v.return_function),
            .clauses = clauses,
            .state = try self.ids(.schema, v.state, false),
            .effects = try self.ids(.effect, v.effects, true),
        };
    }
    fn resources(self: Mapper, v: p.Resource) Error!p.Resource {
        return .{
            .representation = try self.id(.schema, v.representation),
            .introducers = try self.ids(.function, v.introducers, true),
            .eliminators = try self.ids(.function, v.eliminators, true),
        };
    }
    fn variables(self: Mapper, v: u64) Error!u64 {
        return self.id(.schema, v);
    }
    fn functions(self: Mapper, v: ast.Function) Error!ast.Function {
        return .{
            .parameters = try self.ids(.variable, v.parameters, false),
            .result = try self.id(.schema, v.result),
            .effects = try self.ids(.effect, v.effects, true),
            .regions = try self.ids(.region, v.regions, true),
            .body = if (v.body) |body| try self.id(.term, body) else null,
        };
    }
    fn values(self: Mapper, v: ast.Value) Error!ast.Value {
        var result = v;
        result.schema = try self.id(.schema, v.schema);
        switch (v.expression) {
            .variable => |old| result.expression = .{ .variable = try self.id(.variable, old) },
            .literal => |old| result.expression = .{ .literal = try self.id(.constant, old) },
            .lambda => |old| result.expression = .{ .lambda = try self.id(.function, old) },
            .primitive => |old| {
                var op = old;
                op.operands = try self.ids(.value, old.operands, false);
                try data.admission.spend(self.work, old.failures.len);
                const failures = try self.a.alloc(p.InstructionFailure, old.failures.len);
                for (failures, old.failures) |*out, failure| out.* = .{
                    .kind = failure.kind,
                    .value = try self.id(.constant, failure.value),
                };
                op.failures = failures;
                if (op.opcode == .constant) op.immediate = try self.id(.constant, op.immediate);
                if (op.opcode == .computation) {
                    if (self.references != null) {
                        if (op.immediate >= self.constructors.len) return error.InvalidRelation;
                        const binding = self.constructors[@intCast(op.immediate)];
                        _ = try self.id(.function, binding.function);
                        _ = try self.id(.schema, binding.schema);
                        for (binding.captures) |capture| _ = try self.id(.variable, capture);
                    } else if (self.maps.constructors.len != 0) {
                        op.immediate = try bindings.Transport.id(
                            self.maps.constructors,
                            op.immediate,
                        );
                    }
                }
                result.expression = .{ .primitive = op };
            },
        }
        return result;
    }
    fn terms(self: Mapper, v: ast.Term) Error!ast.Term {
        return switch (v) {
            .value => |x| .{ .value = try self.id(.value, x) },
            .bind => |x| .{ .bind = .{
                .variable = try self.id(.variable, x.variable),
                .value = try self.id(.term, x.value),
                .next = try self.id(.term, x.next),
            } },
            .conditional => |x| .{ .conditional = .{
                .condition = try self.id(.value, x.condition),
                .when_true = try self.id(.term, x.when_true),
                .when_false = try self.id(.term, x.when_false),
            } },
            .call => |x| .{ .call = .{
                .function = try self.id(.function, x.function),
                .arguments = try self.ids(.value, x.arguments, false),
            } },
            .apply => |x| .{ .apply = .{
                .computation = try self.id(.value, x.computation),
                .arguments = try self.ids(.value, x.arguments, false),
            } },
            .perform => |x| .{ .perform = .{
                .effect = try self.id(.effect, x.effect),
                .capability = if (x.capability) |old| try self.id(.value, old) else null,
                .payload = try self.id(.value, x.payload),
                .bodies = try self.ids(.value, x.bodies, false),
                .use_site_capabilities = try self.ids(.value, x.use_site_capabilities, false),
            } },
            .handle => |x| .{ .handle = .{
                .handler = try self.id(.handler, x.handler),
                .body = try self.id(.value, x.body),
                .arguments = try self.ids(.value, x.arguments, false),
                .state = try self.ids(.value, x.state, false),
            } },
            .resume_value => |x| .{ .resume_value = .{
                .resumption = try self.id(.value, x.resumption),
                .argument = try self.id(.value, x.argument),
            } },
            .resume_with => |x| .{ .resume_with = .{
                .resumption = try self.id(.value, x.resumption),
                .argument = try self.id(.value, x.argument),
                .handler = try self.id(.handler, x.handler),
                .state = try self.ids(.value, x.state, false),
            } },
            .resume_computation => |x| .{ .resume_computation = .{
                .resumption = try self.id(.value, x.resumption),
                .computation = try self.id(.value, x.computation),
            } },
            .protect,
            .with_region,
            .dispose,
            .fail,
            .yield_then,
            .match_sum,
            .unpack_product,
            => self.termsScope(v),
        };
    }
    fn termsScope(self: Mapper, v: ast.Term) Error!ast.Term {
        return switch (v) {
            .protect => |x| .{ .protect = .{
                .body = try self.id(.value, x.body),
                .cleanup = try self.id(.value, x.cleanup),
                .arguments = try self.ids(.value, x.arguments, false),
                .resource = if (x.resource) |old| try self.id(.value, old) else null,
                .loan_region = if (x.loan_region) |old| try self.id(.region, old) else null,
            } },
            .with_region => |x| .{ .with_region = .{
                .region = try self.id(.region, x.region),
                .body = try self.id(.value, x.body),
                .arguments = try self.ids(.value, x.arguments, false),
            } },
            .dispose => |x| .{ .dispose = try self.id(.value, x) },
            .fail => |x| .{ .fail = try self.id(.value, x) },
            .yield_then => |x| .{ .yield_then = try self.id(.term, x) },
            .match_sum => |x| blk: {
                try data.admission.spend(self.work, x.cases.len);
                const T = std.meta.Elem(@TypeOf(x.cases));
                const cases = try self.a.alloc(T, x.cases.len);
                for (cases, x.cases) |*out, old| out.* = .{
                    .variable = try self.id(.variable, old.variable),
                    .body = try self.id(.term, old.body),
                };
                break :blk .{ .match_sum = .{
                    .value = try self.id(.value, x.value),
                    .cases = cases,
                } };
            },
            .unpack_product => |x| .{ .unpack_product = .{
                .value = try self.id(.value, x.value),
                .variables = try self.ids(.variable, x.variables, false),
                .body = try self.id(.term, x.body),
            } },
            else => unreachable,
        };
    }
};

fn sortIds(values: []u64, work: ?*u64) Error!void {
    var start = values.len / 2;
    while (start > 0) {
        try data.admission.spend(work, 1);
        start -= 1;
        try siftIds(values, start, work);
    }
    var end = values.len;
    while (end > 1) {
        try data.admission.spend(work, 1);
        end -= 1;
        std.mem.swap(u64, &values[0], &values[end]);
        try siftIds(values[0..end], 0, work);
    }
}

fn siftIds(values: []u64, start: usize, work: ?*u64) Error!void {
    var root = start;
    while (root < values.len / 2) {
        try data.admission.spend(work, 1);
        var child = root * 2 + 1;
        if (child + 1 < values.len and values[child] < values[child + 1]) child += 1;
        if (values[root] >= values[child]) break;
        std.mem.swap(u64, &values[root], &values[child]);
        root = child;
    }
}
