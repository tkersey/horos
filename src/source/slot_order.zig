//! Alpha-rename function-local slots so control bindings precede temporaries.
//! Input is admitted. No value, instruction, edge assignment or scope is removed.
const std = @import("std");
const data = @import("horos_data");
const ir = data.activation;
const Id = data.program.Id;
const Error = std.mem.Allocator.Error;

/// Uses the compilation arena; the transient result borrows input catalogues.
pub fn optimize(a: std.mem.Allocator, input: ir.Program) Error!ir.Program {
    return optimizeObserved(a, input, null);
}

pub const Observer = struct {
    context: *anyopaque,
    receive: *const fn (*anyopaque, []const ?[]const Id) Error!void,
};

pub fn optimizeObserved(
    a: std.mem.Allocator,
    input: ir.Program,
    observer: ?Observer,
) Error!ir.Program {
    const visited = try a.alloc(bool, input.blocks.len);
    defer a.free(visited);
    @memset(visited, false);
    const maps = try a.alloc(?[]Id, input.functions.len);
    defer a.free(maps);
    @memset(maps, null);
    const temporary = try a.alloc([]bool, input.functions.len);
    defer a.free(temporary);
    for (input.functions, 0..) |function, id| {
        temporary[id] = try a.alloc(bool, function.layout.slots.len);
        @memset(temporary[id], false);
    }
    defer for (maps, temporary) |mapping, flags| {
        if (mapping) |slots| a.free(slots);
        a.free(flags);
    };
    for (input.blocks) |block| for (block.instructions) |instruction| {
        temporary[@intCast(block.function)][@intCast(instruction.destination)] = true;
    };
    const functions = try a.dupe(ir.Function, input.functions);
    for (functions, maps, temporary) |*function, *map, flags| {
        // A single word already represents arbitrary small subsets directly.
        // Avoid changing those layouts without a multiword fragmentation gain.
        var saw_temporary = false;
        const scattered = for (flags, 0..) |is_temporary, slot| {
            if (is_temporary)
                saw_temporary = true
            else if (saw_temporary and
                slot >= 64)
                break true;
        } else false;
        if (!scattered or !try accumulates(a, input, function.*, visited)) continue;
        const mapping = try a.alloc(Id, flags.len);
        map.* = mapping;
        const layout = try a.alloc(Id, mapping.len);
        var next: usize = 0;
        for ([_]bool{ false, true }) |kind| {
            for (flags, 0..) |is_temporary, old| {
                if (is_temporary != kind) continue;
                mapping[old] = next;
                layout[next] = function.layout.slots[old];
                next += 1;
            }
        }
        function.inputs = try ids(a, function.inputs, mapping);
        function.layout.slots = layout;
    }
    const blocks = try a.dupe(ir.Block, input.blocks);
    for (blocks) |*block| {
        const mapping = maps[@intCast(block.function)] orelse continue;
        const instructions = try a.dupe(ir.Instruction, block.instructions);
        for (instructions) |*instruction| {
            instruction.destination = mapping[@intCast(instruction.destination)];
            instruction.operands = try ids(a, instruction.operands, mapping);
        }
        block.instructions = instructions;
        block.terminator = try control(a, block.terminator, mapping);
    }
    var result = input;
    result.functions = functions;
    result.blocks = blocks;
    if (observer) |sink| {
        const borrowed = try a.alloc(?[]const Id, maps.len);
        defer a.free(borrowed);
        for (maps, borrowed) |map, *to| to.* = map;
        try sink.receive(sink.context, borrowed);
    }
    return result;
}

// Group only a growing live prefix, not arbitrary branching or recycling
// lifetimes. Each block has one function owner, so the shared visited map bounds
// all chain walks together and also rejects cycles without native recursion.
fn accumulates(
    a: std.mem.Allocator,
    input: ir.Program,
    function: ir.Function,
    visited: []bool,
) Error!bool {
    if (function.entry == data.relocation.missing) return false;
    var bindings: std.ArrayList(Id) = .empty;
    defer bindings.deinit(a);
    var current = function.entry;
    while (!visited[@intCast(current)]) {
        visited[@intCast(current)] = true;
        const block = input.blocks[@intCast(current)];
        const next = switch (block.terminator) {
            .jump => |v| v,
            inline .handle, .call, .perform => |v| v.next,
            .return_value => |returned| {
                if (bindings.items.len < 2) return false;
                const read = try a.alloc(bool, function.layout.slots.len);
                defer a.free(read);
                @memset(read, false);
                read[@intCast(returned)] = true;
                for (block.instructions) |instruction| for (instruction.operands) |slot| {
                    read[@intCast(slot)] = true;
                };
                for (bindings.items) |slot| if (!read[@intCast(slot)]) return false;
                return true;
            },
            else => return false,
        };
        for (next.assignments) |assignment| {
            if (input.schemas[
                @intCast(function.layout.slots[
                    @intCast(assignment.destination)
                ])
            ] != .unit)
                try bindings.append(a, assignment.destination);
        }
        current = next.block;
    }
    return false;
}

fn ids(a: std.mem.Allocator, values: []const Id, mapping: []const Id) Error![]const Id {
    const result = try a.alloc(Id, values.len);
    for (result, values) |*to, from| to.* = mapping[@intCast(from)];
    return result;
}
fn edge(a: std.mem.Allocator, value: ir.Edge, mapping: []const Id) Error!ir.Edge {
    var result = value;
    const assignments = try a.dupe(ir.Assignment, value.assignments);
    for (assignments) |*assignment| {
        assignment.destination = mapping[@intCast(assignment.destination)];
        if (assignment.source == .slot) assignment.source.slot = mapping[
            @intCast(assignment.source.slot)
        ];
    }
    result.assignments = assignments;
    return result;
}
fn local(comptime T: type, value: T, mapping: []const Id) T {
    return if (@typeInfo(T) == .optional)
        (if (value) |id| mapping[@intCast(id)] else null)
    else
        mapping[@intCast(value)];
}
fn named(comptime name: []const u8, comptime choices: []const []const u8) bool {
    inline for (choices) |choice| if (comptime std.mem.eql(u8, name, choice)) return true;
    return false;
}
fn control(a: std.mem.Allocator, value: ir.Terminator, mapping: []const Id) Error!ir.Terminator {
    @setEvalBranchQuota(10000); // Finite field classification across the control union.
    return switch (value) {
        .return_value => |id| .{ .return_value = mapping[@intCast(id)] },
        .fail => |id| .{ .fail = mapping[@intCast(id)] },
        .jump => |v| .{ .jump = try edge(a, v, mapping) },
        .yield_value => |v| .{ .yield_value = try edge(a, v, mapping) },
        inline .branch,
        .switch_variant,
        .unpack_product,
        .call,
        .perform,
        .apply,
        .handle,
        .resume_value,
        .resume_with,
        .resume_computation,

        .dispose,
        .protect,
        .with_region,
        => |v, tag| blk: {
            var result = v;
            inline for (
                @typeInfo(@TypeOf(v)).@"struct".field_names,
                @typeInfo(@TypeOf(v)).@"struct".field_types,
            ) |field_name, FieldType| {
                const original = @field(v, field_name);
                if (comptime named(
                    field_name,
                    &.{
                        "condition",
                        "value",
                        "computation",
                        "body",
                        "cleanup",
                        "owned",
                        "payload",
                        "resumption",
                        "argument",
                        "capability",
                        "resource",
                    },
                )) {
                    @field(result, field_name) = local(FieldType, original, mapping);
                } else if (comptime named(
                    field_name,
                    &.{ "arguments", "state", "bodies", "use_site_capabilities", "destinations" },
                )) {
                    @field(result, field_name) = try ids(a, original, mapping);
                } else if (comptime named(field_name, &.{ "next", "when_true", "when_false" })) {
                    @field(result, field_name) = try edge(a, original, mapping);
                } else if (comptime std.mem.eql(u8, field_name, "cases")) {
                    const cases = try a.alloc(ir.Edge, original.len);
                    for (cases, original) |*to, from| to.* = try edge(a, from, mapping);
                    @field(result, field_name) = cases;
                } else if (comptime !named(
                    field_name,
                    &.{ "function", "effect", "handler", "region", "loan_region" },
                )) {
                    @compileError(
                        "classify the new control field before relabeling slots: " ++ field_name,
                    );
                }
            }
            break :blk @unionInit(ir.Terminator, @tagName(tag), result);
        },
    };
}

test "slot ordering is an immutable idempotent renaming of schemas and simultaneous edges" {
    const testing = std.testing;
    const layout = [_]Id{ 0, 1, 0, 0, 0, 3 } ++ @as([60]Id, @splat(0));
    const input: ir.Program = .{
        .roots = .{ .entry = 0, .result = 3, .failure = 2 },
        .schemas = &.{ .u64, .boolean, .unit, .{ .product = &.{ 0, 0 } } },
        .constants = &.{
            .{ .schema = 1, .bytes = &.{0} },
            .{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &layout },
            .result = 3,
        }},
        .blocks = &.{
            .{
                .function = 0,
                .instructions = &.{
                    .{ .destination = 1, .opcode = .constant },
                    .{ .destination = 2, .opcode = .constant, .immediate = 1 },
                },
                .terminator = .{ .jump = .{
                    .block = 1,
                    .assignments = &.{
                        .{ .destination = 64, .source = .{ .slot = 2 } },
                        .{ .destination = 65, .source = .{ .slot = 0 } },
                    },
                } },
            },
            .{
                .function = 0,
                .instructions = &.{.{
                    .destination = 5,
                    .opcode = .product,
                    .operands = &.{ 64, 65 },
                }},
                .terminator = .{ .return_value = 5 },
            },
        },
    };
    var admitted = try data.activation_ownership.analyze(testing.allocator, input);
    defer admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const output = try optimize(arena.allocator(), input);
    var checked = try data.activation_ownership.analyze(testing.allocator, output);
    defer checked.deinit();
    var expected = @as([66]Id, @splat(0));
    expected[63] = 1;
    expected[65] = 3;
    try testing.expectEqualSlices(Id, &expected, output.functions[0].layout.slots);
    try testing.expectEqualSlices(Id, &.{0}, output.functions[0].inputs);
    try testing.expectEqual(63, output.blocks[0].instructions[0].destination);
    try testing.expectEqual(64, output.blocks[0].instructions[1].destination);
    try testing.expectEqual(61, output.blocks[0].terminator.jump.assignments[0].destination);
    try testing.expectEqual(64, output.blocks[0].terminator.jump.assignments[0].source.slot);
    try testing.expectEqual(62, output.blocks[0].terminator.jump.assignments[1].destination);
    try testing.expectEqual(0, output.blocks[0].terminator.jump.assignments[1].source.slot);
    try testing.expectEqualSlices(Id, &.{ 61, 62 }, output.blocks[1].instructions[0].operands);
    try testing.expectEqualDeep(output, try optimize(arena.allocator(), output));
    try testing.expectEqualSlices(Id, &layout, input.functions[0].layout.slots);
    try testing.expectEqual(64, input.blocks[0].terminator.jump.assignments[0].destination);

    var recycling_blocks = [_]ir.Block{ input.blocks[0], input.blocks[1] };
    recycling_blocks[1].instructions = &.{.{
        .destination = 5,
        .opcode = .product,
        .operands = &.{ 0, 65 },
    }};
    var recycling = input;
    recycling.blocks = &recycling_blocks;
    var recycling_facts = try data.activation_ownership.analyze(testing.allocator, recycling);
    defer recycling_facts.deinit();
    try testing.expectEqualDeep(recycling, try optimize(arena.allocator(), recycling));

    var branching_blocks = [_]ir.Block{ input.blocks[0], input.blocks[1] };
    branching_blocks[0].terminator = .{ .branch = .{
        .condition = 1,
        .when_true = input.blocks[0].terminator.jump,
        .when_false = input.blocks[0].terminator.jump,
    } };
    var branching = input;
    branching.blocks = &branching_blocks;
    var branching_facts = try data.activation_ownership.analyze(testing.allocator, branching);
    defer branching_facts.deinit();
    try testing.expectEqualDeep(branching, try optimize(arena.allocator(), branching));
}
