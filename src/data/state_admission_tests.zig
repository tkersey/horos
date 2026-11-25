const std = @import("std");
const ir = @import("activation.zig");
const image = @import("program_image.zig");
const admission = @import("state_admission.zig");
const state_image = @import("state_image.zig");
const ps = @import("process_state.zig");
const p = @import("program.zig");
const g = @import("graph.zig");
const a = std.testing.allocator;

const ordinary: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{ .u64, .unit },
    .constants = &.{.{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } }},
    .effects = &.{},
    .functions = &.{.{
        .entry = 0,
        .inputs = &.{},
        .layout = .{ .slots = &.{0} },
        .result = 0,
    }},
    .blocks = &.{.{
        .function = 0,
        .instructions = &.{.{ .opcode = .constant, .destination = 0 }},
        .terminator = .{ .return_value = 0 },
    }},
};

fn admit(program: ir.Program) !*image.Admitted {
    const bytes = try a.alloc(u8, try image.encodedLength(.unhinted(program)));
    defer a.free(bytes);
    _ = try image.encode(a, .unhinted(program), bytes);
    return image.Admitted.decode(a, bytes);
}

fn active(owner: *const image.Admitted) ps.State {
    return .{
        .program_identity = owner.identity(),
        .status = .active,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .control = .{ .block = 0 } }, .activation = .{
            .position = 1,
            .scope = 0,
            .owners = &.{},
            .bindings = &.{.{
                .slot = 0,
                .value = .{ .schema = 0, .body = .{ .scalar = .{ 42, 0, 0, 0, 0, 0, 0, 0 } } },
            }},
        } }},
    };
}

fn cancelled(owner: *const image.Admitted) ps.State {
    return .{
        .program_identity = owner.identity(),
        .status = .cancelled,
        .roots = .{ .exit = .{ .id = 0 } },
        .nodes = &.{.{ .record = .{ .exit = .{
            .reason = .cancellation,
            .cancellation = .{ .text = "cancelled" },
        } } }},
    };
}

fn roundTrip(owner: *const image.Admitted, state: ps.State) !void {
    const expected = try state_image.emit(a, state);
    defer a.free(expected);
    try admission.validateAdmitted(a, owner, state);
    try admission.validateStable(a, owner.image(), state);
    var restored = try state_image.decodeGraph(a, expected);
    defer restored.deinit();
    try admission.validateAdmitted(a, owner, restored.state);
    const actual = try state_image.emit(a, restored.state);
    defer a.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "public-only state admission storage is independent of unrelated program blocks" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const storage = arena.allocator();
    var bytes: [2]usize = undefined;
    for ([_]usize{ 1, 512 }, 0..) |count, sample| {
        var program = ordinary;
        const functions = try storage.alloc(ir.Function, count);
        const blocks = try storage.alloc(ir.Block, count);
        for (functions, blocks, 0..) |*function, *block, id| {
            function.* = ordinary.functions[0];
            function.entry = id;
            block.* = ordinary.blocks[0];
            block.function = id;
        }
        program.functions = functions;
        program.blocks = blocks;
        const owner = try admit(program);
        defer owner.deinit();
        const state = active(owner);
        var counted = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
        try admission.validateAdmitted(counted.allocator(), owner, state);
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
        bytes[sample] = counted.allocated_bytes;
        try roundTrip(owner, state);
    }
    try std.testing.expectEqual(bytes[0], bytes[1]);
}

test "public-only state admission rejects fabricated handler attachments and owned values" {
    const owner = try admit(ordinary);
    defer owner.deinit();
    const original = active(owner);
    var nodes = [_]ps.Node{
        original.nodes[0],
        .{ .record = .{ .attachment = .{
            .handler = .{ .id = 2 },
            .outer = null,
            .return_to = null,
        } } },
        .{ .record = .{ .handler = .{ .definition = 0, .state = &.{}, .evidence = null } } },
    };
    nodes[0].record.control.parent = .{ .id = 1 };
    var state = original;
    state.nodes = &nodes;
    try expectRejected(error.InvalidState, owner, state);
    nodes[0] = original.nodes[0];
    nodes[1] = .{ .record = .{ .aggregate = .{ .schema = 0, .tag = 0, .fields = &.{} } } };
    nodes[0].activation.?.bindings = &.{.{
        .slot = 0,
        .value = .{ .schema = 0, .body = .{ .owned = .{ .node = .{ .id = 1 } } } },
    }};
    state.nodes = nodes[0..2];
    try expectRejected(error.InvalidState, owner, state);
}

fn expectRejected(expected: anyerror, owner: *const image.Admitted, state: ps.State) !void {
    try std.testing.expectError(expected, admission.validateAdmitted(a, owner, state));
    try std.testing.expectError(expected, admission.validateStable(a, owner.image(), state));
}

test "state admission retains scoped-schema and handler analysis paths" {
    var scoped = ordinary;
    scoped.schemas = &.{ .u64, .unit, .{ .internal = .{ .region = 0 } } };
    scoped.scopes.region_count = 1;
    const scoped_owner = try admit(scoped);
    defer scoped_owner.deinit();
    try roundTrip(scoped_owner, active(scoped_owner));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const handled = try @import("evidence_forwarding_tests.zig").fixture(arena.allocator());
    const handler_owner = try admit(handled);
    defer handler_owner.deinit();
    try roundTrip(handler_owner, cancelled(handler_owner));
}

fn allocationFailure(allocator: std.mem.Allocator, owner: *const image.Admitted) !void {
    try admission.validateAdmitted(allocator, owner, active(owner));
}

test "public-only state admission releases every failed allocation" {
    const owner = try admit(ordinary);
    defer owner.deinit();
    try @import("allocation_testing.zig").check(a, allocationFailure, .{owner});
}

const closure_schema = 2;
const private_schemas: []const p.Schema = &.{
    .u64,
    .unit,
    .{ .internal = .{ .computation = .{ .parameters = &.{}, .result = 0 } } },
};
const unused_handler: []const ir.Handler = &.{.{
    .mode = .deep,
    .input = 0,
    .answer = 0,
    .return_function = 1,
    .clauses = &.{},
}};
const constant: []const ir.Instruction = &.{.{ .opcode = .constant, .destination = 0 }};

const closures: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = private_schemas,
    .constants = ordinary.constants,
    .effects = &.{},
    .functions = &.{
        .{
            .entry = 0,
            .inputs = &.{},
            .layout = .{ .slots = &.{ 0, closure_schema } },
            .result = 0,
        },
        .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 2, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{ .entry = 3, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
    },
    .blocks = &.{
        .{
            .function = 0,
            .instructions = &.{.{ .opcode = .computation, .destination = 1, .immediate = 0 }},
            .terminator = .{ .apply = .{ .computation = 1, .arguments = &.{}, .next = .{
                .block = 4,
                .assignments = &.{.{ .destination = 0, .source = .returned }},
            } } },
        },
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 2, .instructions = constant, .terminator = .{ .return_value = 0 } },
        .{ .function = 3, .instructions = constant, .terminator = .{ .return_value = 0 } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    },
    .handlers = unused_handler,
    .scopes = .{ .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
    .constructors = &.{
        .{ .function = 2, .capture = 0, .schema = closure_schema },
        .{ .function = 3, .capture = 0, .schema = closure_schema },
    },
};

fn closureState(owner: *const image.Admitted, comptime constructor: p.Id) ps.State {
    const closure: g.Value = .{ .schema = closure_schema, .body = .{ .reference = .{ .id = 1 } } };
    return .{
        .program_identity = owner.identity(),
        .status = .active,
        .roots = .{ .current = .{ .id = 0 } },
        .nodes = &.{
            .{ .record = .{ .control = .{ .block = 0 } }, .activation = .{
                .position = 1,
                .scope = 0,
                .owners = &.{},
                .bindings = &.{.{ .slot = 1, .value = closure }},
            } },
            .{ .record = .{ .computation = .{
                .constructor = constructor,
                .environment = .{ .id = 2 },
            } } },
            .{ .record = .{ .environment = .{ .values = &.{}, .tail = null } } },
        },
    };
}

test "handler provenance still rejects a forged closure that private schemas alone admit" {
    for ([_][]const ir.Handler{ unused_handler, &.{} }) |handlers| {
        var program = closures;
        program.handlers = handlers;
        const owner = try admit(program);
        defer owner.deinit();
        try admission.validateAdmitted(a, owner, closureState(owner, 0));
        try admission.validateStable(a, .unhinted(program), closureState(owner, 0));
        if (handlers.len == 0) {
            try admission.validateAdmitted(a, owner, closureState(owner, 1));
        } else try expectRejected(error.InvalidOwnership, owner, closureState(owner, 1));
    }
}

fn widened(storage: std.mem.Allocator, base: ir.Program, count: usize) !ir.Program {
    const functions = try storage.alloc(ir.Function, base.functions.len + count);
    const blocks = try storage.alloc(ir.Block, base.blocks.len + count);
    @memcpy(functions[0..base.functions.len], base.functions);
    @memcpy(blocks[0..base.blocks.len], base.blocks);
    for (
        functions[base.functions.len..],
        blocks[base.blocks.len..],
        0..,
    ) |*function, *block, index| {
        function.* = ordinary.functions[0];
        function.entry = base.blocks.len + index;
        block.* = ordinary.blocks[0];
        block.function = base.functions.len + index;
    }
    var program = base;
    program.functions = functions;
    program.blocks = blocks;
    return program;
}

test "handlers or private schemas still derive provenance for every program block" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var handled = ordinary;
    handled.functions = &.{
        ordinary.functions[0],
        .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
    };
    handled.blocks = &.{
        ordinary.blocks[0],
        .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
    };
    handled.handlers = unused_handler;
    var private = ordinary;
    private.schemas = private_schemas;
    for ([_]ir.Program{ handled, private }) |base| {
        var bytes: [2]usize = undefined;
        for ([_]usize{ 1, 512 }, &bytes) |count, *requested| {
            const owner = try admit(try widened(arena.allocator(), base, count));
            defer owner.deinit();
            var counted = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
            try admission.validateAdmitted(counted.allocator(), owner, active(owner));
            requested.* = counted.allocated_bytes;
            try @import("allocation_testing.zig").check(a, allocationFailure, .{owner});
        }
        try std.testing.expect(bytes[1] > bytes[0]);
    }
}
