const std = @import("std");
const p = @import("horos_data").program;
const ast = @import("ast.zig");
pub const Error = @import("../source.zig").Error || error{InvalidRelation};
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
};
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
    inline for (catalogs) |name| {
        const map = @field(maps, name);
        if (map.len != @field(module, name).len) return error.InvalidRelation;
        const count = mappedCount(map);
        if (bijection and count != map.len) return error.InvalidRelation;
        const seen = try a.alloc(bool, count);
        defer a.free(seen);
        @memset(seen, false);
        for (map) |maybe| if (maybe) |id_| {
            if (id_ >= count or seen[@intCast(id_)]) return error.InvalidRelation;
            seen[@intCast(id_)] = true;
        };
    }
    if (bijection and maps.region_count != module.region_count) return error.InvalidRelation;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(a);
    for (maps.regions, 0..) |region, i| {
        if (region.old >= module.region_count or region.new >= maps.region_count)
            return error.InvalidRelation;
        if (i != 0 and maps.regions[i - 1].old >= region.old) return error.InvalidRelation;
        if ((bijection or maps.region_count == module.region_count) and
            region.old != region.new and findRegion(maps, region.new) == null)
            return error.InvalidRelation;
        const item = try seen.getOrPut(a, region.new);
        if (item.found_existing) return error.InvalidRelation;
    }
}
fn mappedCount(map: []const ?u64) usize {
    var count: usize = 0;
    for (map) |id_| count += @intFromBool(id_ != null);
    return count;
}
fn findRegion(maps: Maps, old: u64) ?u64 {
    var low: usize = 0;
    var high = maps.regions.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const region = maps.regions[mid];
        if (region.old == old) return region.new;
        if (region.old < old) low = mid + 1 else high = mid;
    }
    return null;
}

pub fn relocate(a: std.mem.Allocator, module: ast.Module, maps: Maps) Error!ast.Module {
    try validateMaps(a, module, maps, false);
    const mapper: Mapper = .{ .a = a, .maps = maps, .region_original_count = module.region_count };
    var result = module;
    result.entry = try mapper.id(.function, module.entry);
    result.failure = try mapper.id(.schema, module.failure);
    result.region_count = maps.region_count;
    inline for (catalogs) |name| {
        const values = @field(module, name);
        const map = @field(maps, name);
        const T = std.meta.Elem(@TypeOf(values));
        const output = try a.alloc(T, mappedCount(map));
        for (map, values) |maybe, value_| if (maybe) |new| {
            output[@intCast(new)] = try @field(Mapper, name)(mapper, value_);
        };
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
    const mapper: Mapper = .{ .a = a, .references = sink };
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
    references: ?*std.ArrayList(Reference) = null,
    fn id(self: Mapper, kind: Kind, old: u64) Error!u64 {
        if (self.references) |sink| {
            try sink.append(self.a, .{ .kind = kind, .id = old });
            return old;
        }
        if (kind == .region) {
            if (old >= self.region_original_count) return error.InvalidRelation;
            if (findRegion(self.maps, old)) |new| return new;
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
        const output = try self.a.alloc(u64, input.len);
        for (output, input) |*out, old| out.* = try self.id(kind, old);
        if (set) std.mem.sort(u64, output, {}, std.sort.asc(u64));
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
            .enumeration => |v| .{ .enumeration = try self.a.dupe(u32, v) },
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
        return .{ .schema = try self.id(.schema, v.schema), .bytes = try self.a.dupe(u8, v.bytes) };
    }
    fn effects(self: Mapper, v: p.Effect) Error!p.Effect {
        return .{
            .identity = try self.a.dupe(u8, v.identity),
            .payload = try self.id(.schema, v.payload),
            .result = try self.id(.schema, v.result),
            .use_site_effects = try self.ids(.effect, v.use_site_effects, false),
            .bodies = try self.ids(.schema, v.bodies, false),
            .control_use = v.control_use,
            .external = v.external,
        };
    }
    fn handlers(self: Mapper, v: p.Handler) Error!p.Handler {
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
                const failures = try self.a.alloc(p.InstructionFailure, old.failures.len);
                for (failures, old.failures) |*out, failure| out.* = .{
                    .kind = failure.kind,
                    .value = try self.id(.constant, failure.value),
                };
                op.failures = failures;
                if (op.opcode == .constant) op.immediate = try self.id(.constant, op.immediate);
                if (op.opcode == .computation) return error.InvalidRelation;
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
