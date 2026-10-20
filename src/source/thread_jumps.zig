//! Eliminate administrative paths without moving values or crossing custody.
//! Input has passed target admission. Cycles retain their original blocks.
const std = @import("std");
const data = @import("horos_data");
const ir = data.activation;
const Id = data.program.Id;

pub fn optimize(
    allocator: std.mem.Allocator,
    input: ir.Program,
) std.mem.Allocator.Error!ir.Program {
    const targets = try allocator.alloc(Id, input.blocks.len);
    defer allocator.free(targets);
    const visited = try allocator.alloc(u2, input.blocks.len);
    defer allocator.free(visited);
    @memset(visited, 0);
    for (targets, 0..) |*target, id| target.* = id;
    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(allocator);
    for (input.blocks, 0..) |_, start| {
        if (visited[start] != 0) continue;
        path.clearRetainingCapacity();
        var current = start;
        while (visited[current] == 0) {
            visited[current] = 1;
            try path.append(allocator, current);
            const block = input.blocks[current];
            if (block.instructions.len != 0 or block.terminator != .jump or
                block.terminator.jump.assignments.len != 0) break;
            const next: usize = @intCast(block.terminator.jump.block);
            if (block.function != input.blocks[next].function or
                block.custody != input.blocks[next].custody)
                break;
            current = next;
        }
        // A repeated current at the end of the path is its non-forwarding sink;
        // any earlier occurrence is a cycle, whose control behavior must remain.
        const cycle = visited[current] == 1 and path.items[path.items.len - 1] != current;
        const target = targets[current];
        for (path.items) |id| {
            targets[id] = if (cycle) id else target;
            visited[id] = 2;
        }
    }
    const functions = try allocator.dupe(ir.Function, input.functions);
    for (functions) |*function| if (function.entry != data.relocation.missing) {
        function.entry = targets[@intCast(function.entry)];
    };
    const blocks = try allocator.dupe(ir.Block, input.blocks);
    for (blocks) |*block| block.terminator = try redirect(
        ir.Terminator,
        allocator,
        block.terminator,
        targets,
    );
    var result = input;
    result.functions = functions;
    result.blocks = blocks;
    return result;
}

fn redirect(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: T,
    targets: []const Id,
) std.mem.Allocator.Error!T {
    if (T == ir.Edge) {
        var edge = input;
        edge.block = targets[@intCast(input.block)];
        return edge;
    }
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var result = input;
            inline for (
                info.field_names,
                info.field_types,
            ) |field_name, FieldType| @field(result, field_name) = try redirect(
                FieldType,
                allocator,
                @field(input, field_name),
                targets,
            );
            break :blk result;
        },
        .@"union" => switch (input) {
            inline else => |value, tag| @unionInit(
                T,
                @tagName(tag),
                try redirect(@TypeOf(value), allocator, value, targets),
            ),
        },
        .pointer => |info| blk: {
            if (@typeInfo(info.child) == .int) break :blk input;
            const result = try allocator.alloc(info.child, input.len);
            for (
                result,
                input,
            ) |*to, from| to.* = try redirect(info.child, allocator, from, targets);
            break :blk result;
        },
        .optional => |info| if (input) |value| try redirect(
            info.child,
            allocator,
            value,
            targets,
        ) else null,
        else => input,
    };
}

test "jump threading preserves assignments, custody boundaries and cycles" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit },
        .constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{0} },
            .result = 0,
            .custody = &.{ .{}, .{ .parent = 0 } },
        }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 1 } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 2 } } },
            .{
                .function = 0,
                .instructions = &.{.{ .destination = 0, .opcode = .constant }},
                .terminator = .{ .return_value = 0 },
            },
            .{
                .function = 0,
                .instructions = &.{},
                .terminator = .{ .jump = .{
                    .block = 4,
                    .assignments = &.{.{ .destination = 0, .source = .{ .slot = 0 } }},
                } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 2 } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 6 } } },
            .{
                .function = 0,
                .custody = 1,
                .instructions = &.{},
                .terminator = .{ .jump = .{ .block = 2 } },
            },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 8 } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 7 } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 9 } } },
        },
    };
    var checked = try data.activation_ownership.analyze(testing.allocator, input);
    defer checked.deinit();
    const output = try optimize(arena.allocator(), input);
    try testing.expectEqual(2, output.functions[0].entry);
    try testing.expectEqual(2, output.blocks[0].terminator.jump.block);
    try testing.expectEqual(2, output.blocks[3].terminator.jump.block);
    try testing.expectEqualSlices(
        ir.Assignment,
        input.blocks[3].terminator.jump.assignments,
        output.blocks[3].terminator.jump.assignments,
    );
    try testing.expectEqual(6, output.blocks[5].terminator.jump.block);
    try testing.expectEqual(2, output.blocks[6].terminator.jump.block);
    try testing.expectEqual(8, output.blocks[7].terminator.jump.block);
    try testing.expectEqual(7, output.blocks[8].terminator.jump.block);
    try testing.expectEqual(9, output.blocks[9].terminator.jump.block);
    try testing.expectEqualDeep(input.blocks[2], output.blocks[2]);
    try testing.expectEqual(0, input.functions[0].entry);
    var verified = try data.activation_ownership.analyze(testing.allocator, output);
    defer verified.deinit();
}

test "jump threading handles long paths without recursive control traversal" {
    const testing = std.testing;
    const blocks = try testing.allocator.alloc(ir.Block, 10000);
    defer testing.allocator.free(blocks);
    for (
        blocks,
        0..,
    ) |*block, i| block.* = .{
        .function = 0,
        .instructions = &.{},
        .terminator = .{ .jump = .{ .block = @min(i + 1, blocks.len - 1) } },
    };
    const input: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.unit},
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{} }, .result = 0 }},
        .blocks = blocks,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const output = try optimize(arena.allocator(), input);
    try testing.expectEqual(blocks.len - 1, output.functions[0].entry);
    try testing.expectEqual(blocks.len - 1, output.blocks[blocks.len - 1].terminator.jump.block);
    try testing.expectEqual(1, input.blocks[0].terminator.jump.block);
}
