const std = @import("std");
const p = @import("program.zig");
const wire = @import("wire.zig");
const admission = @import("admission.zig");
const allocation_testing = @import("allocation_testing.zig");

const Case = struct {
    catalog: []const p.Schema,
    facts: admission.SchemaFacts,
    schema: p.Id,
    input: []const u8,
    position: usize = 0,
};

const Outcome = struct {
    result: admission.Error![]const u8,
    position: usize,
    remaining: ?u64,
};

const budget_sweep_max = 256;
const sampled_positions_max = 48;
const generated_bytes_max = 4096;
const generated_steps_max = 100_000;
const seeds = [_]u64{
    0x5eed_0001, 0x5eed_0002, 0x5eed_0003, 0x5eed_0004,
    0x5eed_0005, 0x5eed_0006, 0x5eed_0007, 0x5eed_0008,
    0x5eed_0009, 0x5eed_000a, 0x5eed_000b, 0x5eed_000c,
};

fn decode(allocator: std.mem.Allocator, case: Case, budget: ?u64, reference: bool) Outcome {
    var reader: wire.Reader = .{ .input = case.input, .position = case.position };
    var left = budget orelse 0;
    const meter: ?*u64 = if (budget == null) null else &left;
    const result = if (reference)
        oracle.readValue(allocator, case.catalog, case.facts, case.schema, &reader, meter)
    else if (meter) |work|
        admission.readValueWithWork(allocator, case.catalog, case.facts, case.schema, &reader, work)
    else
        admission.readValue(allocator, case.catalog, case.facts, case.schema, &reader);
    const spent: ?u64 = if (budget == null) null else left;
    return .{ .result = result, .position = reader.position, .remaining = spent };
}

fn expectOutcome(expected: Outcome, actual: Outcome) !void {
    if (expected.result) |bytes| {
        const decoded = try actual.result;
        try std.testing.expectEqual(bytes.ptr, decoded.ptr);
        try std.testing.expectEqual(bytes.len, decoded.len);
    } else |err| try std.testing.expectError(err, actual.result);
    try std.testing.expectEqual(expected.position, actual.position);
    try std.testing.expectEqual(expected.remaining, actual.remaining);
}

fn expectBudget(case: Case, budget: ?u64) !void {
    const expected = decode(std.testing.allocator, case, budget, true);
    try expectOutcome(expected, decode(std.testing.allocator, case, budget, false));
}

fn workOf(case: Case) u64 {
    const unlimited = std.math.maxInt(u64);
    return unlimited - decode(std.testing.allocator, case, unlimited, true).remaining.?;
}

fn expectEveryBudget(case: Case) !void {
    try expectBudget(case, null);
    try expectBudget(case, std.math.maxInt(u64));
    const total = workOf(case);
    if (total <= budget_sweep_max) {
        for (0..total + 1) |budget| try expectBudget(case, budget);
    } else {
        for ([_]u64{ 0, 1, total / 2, total - 1, total }) |budget| try expectBudget(case, budget);
    }
}

fn expectSampledBudgets(case: Case) !void {
    const total = workOf(case);
    try expectBudget(case, null);
    try expectBudget(case, std.math.maxInt(u64));
    for ([_]u64{ 0, 1, total / 2, total -| 1, total }) |budget| try expectBudget(case, budget);
}

fn expectPositions(case: Case) !void {
    const prefixed = try std.testing.allocator.alloc(u8, case.input.len + 3);
    defer std.testing.allocator.free(prefixed);
    @memcpy(prefixed[0..3], &[_]u8{ 0xff, 0x80, 0x01 });
    @memcpy(prefixed[3..], case.input);
    var shifted = case;
    shifted.input = prefixed;
    shifted.position = 3;
    try expectEveryBudget(shifted);
    for ([_]usize{ case.input.len, case.input.len + 1 }) |position| {
        var outside = case;
        outside.position = position;
        try expectSampledBudgets(outside);
    }
}

fn sampledIndex(index: usize, length: usize) usize {
    if (length <= sampled_positions_max) return index;
    return index * length / sampled_positions_max;
}

fn expectMutations(case: Case, random: std.Random) !void {
    const length = case.input.len;
    const mutated = try std.testing.allocator.alloc(u8, length + 1);
    defer std.testing.allocator.free(mutated);
    const positions = @min(length, sampled_positions_max);
    var altered = case;
    for (0..positions + 1) |index| {
        altered.input = case.input[0..sampledIndex(index, length)];
        try expectSampledBudgets(altered);
    }
    for (0..positions) |index| {
        const at = sampledIndex(index, length);
        const original = case.input[at];
        for ([_]u8{ 0, 0xff, original ^ 1, original ^ 0x80, random.int(u8) }) |byte| {
            @memcpy(mutated[0..length], case.input);
            mutated[at] = byte;
            altered.input = mutated[0..length];
            try expectSampledBudgets(altered);
        }
    }
    @memcpy(mutated[0..length], case.input);
    mutated[length] = random.int(u8);
    altered.input = mutated;
    try expectSampledBudgets(altered);
}

fn expectNoise(catalog: []const p.Schema, facts: admission.SchemaFacts, random: std.Random) !void {
    var noise: [24]u8 = undefined;
    for (0..catalog.len) |schema| for (0..4) |_| {
        const length = random.uintAtMost(usize, noise.len);
        random.bytes(noise[0..length]);
        try expectSampledBudgets(.{
            .catalog = catalog,
            .facts = facts,
            .schema = schema,
            .input = noise[0..length],
        });
    };
}

fn expectValue(case: Case, random: std.Random) !void {
    try expectEveryBudget(case);
    try expectPositions(case);
    try expectMutations(case, random);
}

const Fixture = struct { schema: p.Id, bytes: []const u8 };

fn expectFixtures(catalog: []const p.Schema, fixtures: []const Fixture) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try admission.schemas(arena.allocator(), catalog);
    try expectHandMadeFixtures(catalog, facts, fixtures);
}

fn expectHandMadeFixtures(
    catalog: []const p.Schema,
    facts: admission.SchemaFacts,
    fixtures: []const Fixture,
) !void {
    var prng = std.Random.DefaultPrng.init(catalog.len);
    for (fixtures) |fixture| try expectValue(.{
        .catalog = catalog,
        .facts = facts,
        .schema = fixture.schema,
        .input = fixture.bytes,
    }, prng.random());
}

test "optimized value decoding matches the original decoder on existing fixtures" {
    try expectFixtures(&.{
        .unit,
        .{ .sum = &.{ 0, 2 } },
        .{ .product = &.{ 0, 1 } },
        .{ .seq = 0 },
    }, &.{
        .{ .schema = 1, .bytes = &.{ 1, 1, 0 } },
        .{ .schema = 3, .bytes = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 } },
    });
    try expectFixtures(&.{
        .u8,
        .{ .array = .{ .element = 0, .length = 2 } },
        .{ .bounded_bytes = 2 },
        .{ .bounded_text = 2 },
        .unit,
        .{ .array = .{ .element = 4, .length = std.math.maxInt(u64) } },
    }, &.{
        .{ .schema = 1, .bytes = &.{ 4, 5 } },          .{ .schema = 1, .bytes = &.{4} },
        .{ .schema = 1, .bytes = &.{ 4, 5, 6 } },       .{ .schema = 2, .bytes = &.{ 2, 0xff, 0 } },
        .{ .schema = 3, .bytes = &.{ 2, 0xc3, 0xa9 } }, .{ .schema = 2, .bytes = &.{ 3, 1, 2, 3 } },
        .{ .schema = 3, .bytes = &.{ 1, 0xff } },       .{ .schema = 5, .bytes = &.{} },
    });
    try expectFixtures(&.{ .{ .enumeration = &.{ 2, 7 } }, .{ .enumeration = &.{} } }, &.{
        .{ .schema = 0, .bytes = &.{ 7, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 5, 0, 0, 0 } },
        .{ .schema = 1, .bytes = &.{ 0, 0, 0, 0 } },
    });
    try expectFixtures(&.{ .text, .{ .enumeration = &.{ 1, 2, 3, 4 } } }, &.{
        .{ .schema = 0, .bytes = &.{ 4, 't', 'e', 's', 't' } },
        .{ .schema = 1, .bytes = &.{ 4, 0, 0, 0 } },
    });
    try expectFixtures(&.{ .{ .enumeration = &.{ 0, 7, 42 } }, .u32 }, &.{
        .{ .schema = 0, .bytes = &.{ 99, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 42, 0, 0, 0 } },
    });
}

test "optimized value decoding matches the original decoder on hand-made facts" {
    const catalog: []const p.Schema = &.{
        .unit,                         .u8,                           .u16,
        .{ .seq = 1 },                 .{ .product = &.{ 1, 0, 3 } }, .{ .product = &.{} },
        .{ .sum = &.{ 0, 1 } },        .boolean,                      .u64,
        .{ .product = &.{ 4, 5, 1 } },
    };
    try expectHandMadeFixtures(catalog, .{
        .minimum = &.{ 0, 1, 2, 1, 2, 0, 1, 1, 8, 3 },
        .exportable = &.{ true, true, true, true, true, true, true, true, true, true },
    }, &.{
        .{ .schema = 9, .bytes = &.{ 7, 2, 8, 9, 10 } },
        .{ .schema = 5, .bytes = &.{} },
        .{ .schema = 4, .bytes = &.{ 7, 2, 8, 9 } },
        .{ .schema = 6, .bytes = &.{ 1, 3 } },
        .{ .schema = 8, .bytes = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } },
    });
    var tags: [4096]u32 = undefined;
    for (&tags, 0..) |*tag, index| tag.* = @intCast(index);
    try expectHandMadeFixtures(&.{ .{ .enumeration = &tags }, .u32 }, .{
        .minimum = &.{ 4, 4 },
        .exportable = &.{ true, true },
    }, &.{
        .{ .schema = 0, .bytes = &.{ 255, 15, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 0, 16, 0, 0 } },
    });
}

const Emitter = struct {
    random: std.Random,
    catalog: []const p.Schema,
    facts: admission.SchemaFacts,
    output: std.ArrayList(u8) = .empty,
    elements_left: usize,

    const Task = struct { schema: p.Id, count: u64 };

    fn natural(self: *Emitter, allocator: std.mem.Allocator, value: u64) !void {
        var buffer: [10]u8 = undefined;
        var writer: wire.Writer = .{ .output = &buffer };
        try writer.natural(value);
        try self.output.appendSlice(allocator, buffer[0..writer.position]);
    }

    fn text(self: *Emitter, allocator: std.mem.Allocator, bytes_max: u64) !void {
        const pieces = [_][]const u8{ "a", "z", "\xc3\xa9", "\xe2\x82\xac" };
        var encoded: [12]u8 = undefined;
        var length: usize = 0;
        for (0..self.random.uintAtMost(usize, 4)) |_| {
            const piece = pieces[self.random.uintLessThan(usize, pieces.len)];
            if (length + piece.len > bytes_max) break;
            @memcpy(encoded[length..][0..piece.len], piece);
            length += piece.len;
        }
        try self.natural(allocator, length);
        try self.output.appendSlice(allocator, encoded[0..length]);
    }

    fn count(self: *Emitter, maximum: u64) u64 {
        if (self.elements_left == 0) return 0;
        return self.random.uintAtMost(u64, @min(maximum, 3));
    }

    fn variant(self: *Emitter, fields: []const p.Id) usize {
        if (self.elements_left != 0) return self.random.uintLessThan(usize, fields.len);
        var selected: usize = 0;
        for (fields, 0..) |field, index| {
            if (self.facts.minimum[@intCast(field)] <
                self.facts.minimum[@intCast(fields[selected])]) selected = index;
        }
        return selected;
    }

    fn emit(self: *Emitter, allocator: std.mem.Allocator, schema: p.Id) ![]const u8 {
        var pending: std.ArrayList(Task) = .empty;
        defer pending.deinit(allocator);
        try pending.append(allocator, .{ .schema = schema, .count = 1 });
        var steps: usize = 0;
        while (pending.pop()) |task| {
            steps += 1;
            if (steps > generated_steps_max or self.output.items.len > generated_bytes_max)
                return error.Oversized;
            if (task.count == 0) continue;
            if (task.count > 1)
                try pending.append(allocator, .{ .schema = task.schema, .count = task.count - 1 });
            try self.element(allocator, task.schema, &pending);
        }
        return self.output.items;
    }

    fn element(
        self: *Emitter,
        allocator: std.mem.Allocator,
        schema: p.Id,
        pending: *std.ArrayList(Task),
    ) !void {
        self.elements_left -|= 1;
        const random = self.random;
        switch (self.catalog[@intCast(schema)]) {
            .unit, .internal => {},
            .boolean => try self.output.append(allocator, random.uintAtMost(u8, 1)),
            .i8, .u8 => try self.output.append(allocator, random.int(u8)),
            .i16, .u16 => try self.output.appendSlice(allocator, &std.mem.toBytes(random.int(u16))),
            .i32, .u32 => try self.output.appendSlice(allocator, &std.mem.toBytes(random.int(u32))),
            .i64, .u64 => try self.output.appendSlice(allocator, &std.mem.toBytes(random.int(u64))),
            .enumeration => |tags| {
                const tag = if (tags.len == 0)
                    random.int(u32)
                else
                    tags[random.uintLessThan(usize, tags.len)];
                try self.output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(
                    u32,
                    tag,
                )));
            },
            .bytes, .bounded_bytes => {
                const maximum = if (self.catalog[@intCast(schema)] == .bytes)
                    4
                else
                    self.catalog[@intCast(schema)].bounded_bytes;
                const length = random.uintAtMost(u64, @min(maximum, 4));
                try self.natural(allocator, length);
                for (0..length) |_| try self.output.append(allocator, random.int(u8));
            },
            .text => try self.text(allocator, 12),
            .bounded_text => |maximum| try self.text(allocator, @min(maximum, 12)),
            else => try self.composite(allocator, schema, pending),
        }
    }

    fn composite(
        self: *Emitter,
        allocator: std.mem.Allocator,
        schema: p.Id,
        pending: *std.ArrayList(Task),
    ) !void {
        switch (self.catalog[@intCast(schema)]) {
            .product => |fields| {
                var index = fields.len;
                while (index != 0) {
                    index -= 1;
                    try pending.append(allocator, .{ .schema = fields[index], .count = 1 });
                }
            },
            .sum => |fields| {
                const tag = self.variant(fields);
                try self.natural(allocator, tag);
                try pending.append(allocator, .{ .schema = fields[tag], .count = 1 });
            },
            .seq => |element_schema| {
                const length = self.count(3);
                try self.natural(allocator, length);
                try pending.append(allocator, .{ .schema = element_schema, .count = length });
            },
            .vector => |vector| {
                const length = self.count(vector.maximum);
                try self.natural(allocator, length);
                try pending.append(allocator, .{ .schema = vector.element, .count = length });
            },
            .array => |array| try pending.append(
                allocator,
                .{ .schema = array.element, .count = array.length },
            ),
            else => return error.UnexpectedSchema,
        }
    }
};

fn randomIds(random: std.Random, arena: std.mem.Allocator, count: usize, least: usize) ![]p.Id {
    const ids = try arena.alloc(p.Id, least + random.uintAtMost(usize, 3 - least));
    for (ids) |*id| id.* = random.uintLessThan(p.Id, count);
    return ids;
}

fn randomTags(random: std.Random, arena: std.mem.Allocator) ![]u32 {
    const tags = try arena.alloc(u32, random.uintAtMost(usize, 5));
    const dense = random.boolean();
    var next: u32 = 0;
    for (tags) |*tag| {
        next += if (dense) 1 else random.uintAtMost(u32, 9) + 1;
        tag.* = next - 1;
    }
    return tags;
}

fn randomSchema(random: std.Random, arena: std.mem.Allocator, count: usize) !p.Schema {
    const element = random.uintLessThan(p.Id, count);
    const small = random.uintAtMost(u64, 4);
    return switch (random.uintLessThan(u8, 21)) {
        0 => .unit,
        1 => .boolean,
        2 => .i8,
        3 => .u16,
        4 => .i32,
        5 => .u32,
        6 => .i64,
        7, 8 => .u64,
        9 => .bytes,
        10 => .text,
        11, 12 => .{ .product = try randomIds(random, arena, count, 0) },
        13 => .{ .sum = try randomIds(random, arena, count, 1) },
        14 => .{ .seq = element },
        15 => .{ .vector = .{ .element = element, .maximum = small } },
        16 => .{ .array = .{ .element = element, .length = @min(small, 3) } },
        17 => .{ .bounded_bytes = small },
        18 => .{ .bounded_text = small },
        19 => .{ .enumeration = try randomTags(random, arena) },
        else => .{ .internal = .{ .region = element } },
    };
}

fn randomCatalog(random: std.Random, arena: std.mem.Allocator) ![]p.Schema {
    const catalog = try arena.alloc(p.Schema, 2 + random.uintAtMost(usize, 7));
    for (catalog) |*schema| schema.* = try randomSchema(random, arena, catalog.len);
    return catalog;
}

fn perturbedFacts(
    random: std.Random,
    arena: std.mem.Allocator,
    catalog: []p.Schema,
    facts: admission.SchemaFacts,
) !admission.SchemaFacts {
    const minimum = try arena.dupe(u64, facts.minimum);
    const exportable = try arena.dupe(bool, facts.exportable);
    for (minimum, exportable, catalog) |*width, *public, *schema| {
        if (random.uintLessThan(u8, 4) == 0) width.* = random.uintAtMost(u64, 9);
        if (random.uintLessThan(u8, 8) == 0) public.* = !public.*;
        if (schema.* == .enumeration and schema.enumeration.len > 1) {
            const shuffled = try arena.dupe(u32, schema.enumeration);
            random.shuffle(u32, shuffled);
            schema.* = .{ .enumeration = shuffled };
        }
    }
    return .{ .minimum = minimum, .exportable = exportable };
}

fn expectGeneratedCatalog(random: std.Random, arena: std.mem.Allocator, perturb: bool) !void {
    const catalog = try randomCatalog(random, arena);
    const admitted = admission.schemas(arena, catalog) catch |err| switch (err) {
        error.InvalidSchema => return,
        else => return err,
    };
    const facts = if (perturb) try perturbedFacts(random, arena, catalog, admitted) else admitted;
    try expectNoise(catalog, facts, random);
    for (0..catalog.len) |schema| for (0..3) |_| {
        var emitter: Emitter = .{
            .random = random,
            .catalog = catalog,
            .facts = admitted,
            .elements_left = random.uintAtMost(usize, 24),
        };
        defer emitter.output.deinit(std.testing.allocator);
        const bytes = emitter.emit(std.testing.allocator, schema) catch |err| switch (err) {
            error.Oversized => continue,
            else => return err,
        };
        try expectValue(.{
            .catalog = catalog,
            .facts = facts,
            .schema = schema,
            .input = bytes,
        }, random);
    };
}

test "optimized value decoding matches the original decoder on seeded generated values" {
    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        for (0..24) |index|
            try expectGeneratedCatalog(prng.random(), arena.allocator(), index % 4 == 3);
    }
}

const deep_levels = 100;

test "optimized value decoding matches the original decoder beyond the local worklist" {
    var storage: [deep_levels + 2]p.Schema = undefined;
    var fields: [deep_levels][2]p.Id = undefined;
    storage[0] = .u8;
    storage[1] = .{ .seq = 0 };
    for (&fields, 0..) |*pair, level| {
        pair.* = .{ level + 1, 0 };
        storage[level + 2] = .{ .product = pair };
    }
    var bytes: [deep_levels + 2]u8 = undefined;
    bytes[0] = 1;
    @memset(bytes[1..], 7);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try admission.schemas(arena.allocator(), &storage);
    var prng = std.Random.DefaultPrng.init(deep_levels);
    const case: Case = .{
        .catalog = &storage,
        .facts = facts,
        .schema = deep_levels + 1,
        .input = &bytes,
    };
    try expectValue(case, prng.random());
    const decoded = try decode(std.testing.allocator, case, null, false).result;
    try std.testing.expectEqual(bytes.len, decoded.len);
    try allocation_testing.check(std.testing.allocator, expectAllocationFailure, .{case});
}

fn expectAllocationFailure(allocator: std.mem.Allocator, case: Case) !void {
    const expected = decode(std.testing.allocator, case, null, true);
    const actual = decode(allocator, case, null, false);
    _ = actual.result catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };
    try expectOutcome(expected, actual);
}

const oracle = struct {
    const Error = admission.Error;
    const SchemaFacts = admission.SchemaFacts;
    const schemaAt = admission.schemaAt;

    pub fn readValue(
        allocator: std.mem.Allocator,
        catalog: []const p.Schema,
        facts: SchemaFacts,
        schema: p.Id,
        reader: *wire.Reader,
        remaining: ?*u64,
    ) Error![]const u8 {
        return readValueMetered(allocator, catalog, facts, schema, reader, remaining);
    }

    fn valueWork(remaining: ?*u64, count: usize) Error!void {
        const left = remaining orelse return;
        if (count > left.*) return error.ValueWorkLimit;
        left.* -= @intCast(count);
    }

    fn readValueMetered(
        allocator: std.mem.Allocator,
        catalog: []const p.Schema,
        facts: SchemaFacts,
        schema: p.Id,
        reader: *wire.Reader,
        remaining: ?*u64,
    ) Error![]const u8 {
        _ = try schemaAt(catalog, schema);
        if (!facts.exportable[@intCast(schema)]) return error.InvalidValue;
        if (reader.position > reader.input.len) return error.Truncated;
        const start = reader.position;
        var pending: std.ArrayList(ValueTask) = .empty;
        defer pending.deinit(allocator);
        try valueWork(remaining, 1);
        try pending.append(allocator, .{ .schema = schema, .count = 1 });
        while (pending.pop()) |task| {
            try valueWork(remaining, 1);
            const index: usize = @intCast(task.schema);
            const minimum = facts.minimum[index];
            if (task.count == 0 or minimum == 0) continue;
            if (task.count > (reader.input.len - reader.position) / minimum)
                return error.InvalidValue;
            if (task.count > 1) {
                try valueWork(remaining, 1);
                try pending.append(allocator, .{ .schema = task.schema, .count = task.count - 1 });
            }
            try readValueTask(allocator, catalog[index], minimum, reader, &pending, remaining);
        }
        return reader.input[start..reader.position];
    }

    const ValueTask = struct { schema: p.Id, count: u64 };

    fn readValueTask(
        allocator: std.mem.Allocator,
        shape: p.Schema,
        minimum: u64,
        reader: *wire.Reader,
        pending: *std.ArrayList(ValueTask),
        remaining: ?*u64,
    ) Error!void {
        switch (shape) {
            .unit => {},
            .boolean => {
                if (try reader.byte() > 1) return error.InvalidValue;
            },
            .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64 => {
                _ = try reader.take(@intCast(minimum));
            },
            .enumeration => |tags| {
                const bytes = try reader.take(4);
                const tag = std.mem.readInt(u32, bytes[0..4], .little);
                try valueWork(remaining, tags.len);
                if (std.mem.indexOfScalar(u32, tags, tag) == null) return error.InvalidValue;
            },
            .bytes => {
                _ = try reader.bytes();
            },
            .text => {
                _ = try readValueText(reader, remaining);
            },
            .bounded_bytes => |maximum| {
                if ((try reader.bytes()).len > maximum) return error.InvalidValue;
            },
            .bounded_text => |maximum| {
                if ((try readValueText(reader, remaining)).len > maximum) return error.InvalidValue;
            },
            else => try queueValueChildren(allocator, shape, reader, pending, remaining),
        }
    }

    fn readValueText(reader: *wire.Reader, remaining: ?*u64) Error![]const u8 {
        if (remaining != null) {
            var measured = reader.*;
            try valueWork(remaining, (try measured.bytes()).len);
        }
        return reader.text();
    }

    fn queueValueChildren(
        allocator: std.mem.Allocator,
        shape: p.Schema,
        reader: *wire.Reader,
        pending: *std.ArrayList(ValueTask),
        remaining: ?*u64,
    ) Error!void {
        try valueWork(remaining, if (shape == .product) shape.product.len else 1);
        switch (shape) {
            .product => |fields| {
                var i = fields.len;
                while (i != 0) {
                    i -= 1;
                    try pending.append(allocator, .{ .schema = fields[i], .count = 1 });
                }
            },
            .sum => |fields| {
                const tag = try reader.count();
                if (tag >= fields.len) return error.InvalidValue;
                try pending.append(allocator, .{ .schema = fields[tag], .count = 1 });
            },
            .seq => |element| try pending.append(
                allocator,
                .{ .schema = element, .count = try reader.natural() },
            ),
            .vector => |vector| {
                const count = try reader.natural();
                if (count > vector.maximum) return error.InvalidValue;
                try pending.append(allocator, .{ .schema = vector.element, .count = count });
            },
            .array => |array| try pending.append(
                allocator,
                .{ .schema = array.element, .count = array.length },
            ),
            else => return error.InvalidValue,
        }
    }
};
