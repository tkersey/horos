const std = @import("std");
const ir = @import("activation.zig");
const p = @import("program.zig");
const interaction = @import("interactions.zig");
const a = std.testing.allocator;
const base: ir.Program = .{
    .roots = .{ .entry = 0, .result = 1, .failure = 1 },
    .schemas = &.{ .u64, .unit, .boolean },
    .constants = &.{.{ .schema = 1, .bytes = &.{} }},
    .effects = &.{ .{ .identity = "controlled-validation", .payload = 0, .result = 2 }, .{ .identity = "protected-write", .payload = 0, .result = 1 } },
    .functions = &.{.{ .entry = 0, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 2, 1 } }, .result = 1, .effects = &.{ 0, 1 } }},
    .blocks = &.{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .payload = 0, .next = .{ .block = 1, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .branch = .{ .condition = 2, .when_true = .{ .block = 2 }, .when_false = .{ .block = 3 } } } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 1, .payload = 0, .next = .{ .block = 3, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } },
        .{ .function = 0, .instructions = &.{.{ .destination = 3, .opcode = .constant, .immediate = 0 }}, .terminator = .{ .return_value = 3 } },
    },
};
const Binding = struct {
    success_block: p.Id = 1,
    mutation_block: ?p.Id = null,
    // The controlled validator's Boolean response is tested by this exact
    // branch. Contexts describe formal input order (A/B, B/A, unknown); monitor
    // states retain a must-valid subset of the two symbolic object versions.
    // Equal schemas/bytes never manufacture an A=B identity relationship.
    fn project(raw: *const anyopaque, image: ir.Program, site: interaction.Site, context: usize) interaction.Mask {
        const self: *const Binding = @ptrCast(@alignCast(raw));
        if (site.phase == .branch and site.block == self.success_block and site.alternative == 0) return if (context < 2) interaction.bit(context) else interaction.bit(4);
        if (site.phase == .instruction and self.mutation_block == site.block) return interaction.bit(4);
        if (site.phase == .operation and image.blocks[@intCast(site.block)].terminator.perform.effect == 1) {
            const slot = image.blocks[@intCast(site.block)].terminator.perform.payload;
            return interaction.bit(if (context < 2 and slot < 2) 2 + (context ^ @as(usize, @intCast(slot))) else 5);
        }
        return 0;
    }
    fn parameters(_: *const anyopaque, image: ir.Program, block: p.Id, _: p.Id, context: usize) interaction.Mask {
        const term = image.blocks[@intCast(block)].terminator;
        if (term != .call or context == 2) return interaction.bit(2);
        if (std.mem.eql(p.Id, term.call.arguments, &.{ 0, 1 })) return interaction.bit(context);
        if (std.mem.eql(p.Id, term.call.arguments, &.{ 1, 0 })) return interaction.bit(context ^ 1);
        return interaction.bit(2);
    }
    const transitions = table: {
        var result: [30]u8 = @splat(4);
        for (0..4) |state| {
            result[state * 6] = @intCast(state | 1);
            result[state * 6 + 1] = @intCast(state | 2);
            result[state * 6 + 2] = if (state & 1 != 0) @intCast(state) else 4;
            result[state * 6 + 3] = if (state & 2 != 0) @intCast(state) else 4;
            result[state * 6 + 4] = 0;
        }
        break :table result;
    };
    fn monitor(self: *const Binding) interaction.Monitor {
        return .{ .binding = self, .states = 5, .alphabet = 6, .contexts = 3, .bad = interaction.bit(4), .transitions = &transitions, .project = project, .parameters = parameters };
    }
};
fn analyze(image: ir.Program, binding: *const Binding, expected: interaction.Status) !void {
    var admitted = try @import("activation_ownership.zig").analyze(a, image);
    admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owner = try @import("control_provenance.zig").derive(arena.allocator(), image, &.{}, false);
    var session: interaction.Session = .{ .allocator = a, .owner = owner };
    defer session.deinit();
    const result = try session.analyze(binding.monitor());
    const root = result.get(image.roots.entry, 0, 0);
    try std.testing.expectEqual(expected, root.status(binding.monitor()));
    const repeated = try session.analyze(binding.monitor());
    try std.testing.expectEqual(result.summaries.ptr, repeated.summaries.ptr);
    try std.testing.expectEqual(@as(usize, 1), session.cached.items.len);
}
test "interaction validation success precedes same object version write" {
    try analyze(base, &.{}, .established);
    var blocks = base.blocks[0..4].*;
    var image = base;
    image.blocks = &blocks;
    blocks[0].terminator = .{ .perform = .{ .effect = 1, .payload = 0, .next = .{ .block = 2, .assignments = &.{.{ .destination = 3, .source = .returned }} } } };
    blocks[2].terminator = .{ .perform = .{ .effect = 0, .payload = 0, .next = .{ .block = 3, .assignments = &.{.{ .destination = 2, .source = .returned }} } } };
    try analyze(image, &.{}, .potential);
    blocks = base.blocks[0..4].*;
    blocks[2].terminator.perform.payload = 1;
    try analyze(image, &.{}, .potential);
    blocks = base.blocks[0..4].*;
    blocks[1].terminator.branch.when_false.block = 2;
    try analyze(image, &.{}, .potential);
    blocks = base.blocks[0..4].*;
    blocks[2].instructions = &.{.{ .destination = 0, .opcode = .move, .operands = &.{1} }};
    try analyze(image, &.{ .mutation_block = 2 }, .potential);
}
test "interaction mutually recursive helpers use matched least fixed point summaries" {
    var blocks: [9]ir.Block = undefined;
    @memcpy(blocks[0..4], base.blocks);
    blocks[4] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .payload = 0, .next = .{ .block = 5, .assignments = &.{.{ .destination = 2, .source = .returned }} } } } };
    blocks[5] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .branch = .{ .condition = 2, .when_true = .{ .block = 6 }, .when_false = .{ .block = 7 } } } };
    blocks[6] = .{ .function = 1, .instructions = &.{.{ .destination = 3, .opcode = .constant }}, .terminator = .{ .return_value = 3 } };
    blocks[7] = .{ .function = 1, .instructions = &.{}, .terminator = .{ .call = .{ .function = 2, .arguments = &.{ 0, 1 }, .next = .{ .block = 6, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } };
    blocks[8] = .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{ .function = 1, .arguments = &.{ 0, 1 }, .next = .{ .block = 1, .assignments = &.{.{ .destination = 3, .source = .returned }} } } } };
    blocks[1] = .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 3 } };
    blocks[0].terminator = .{ .call = .{ .function = 1, .arguments = &.{ 0, 1 }, .next = .{ .block = 2, .assignments = &.{.{ .destination = 3, .source = .returned }} } } };
    var functions = [_]ir.Function{ base.functions[0], base.functions[0], base.functions[0] };
    functions[1].entry = 4;
    functions[2].entry = 8;
    var image = base;
    image.blocks = &blocks;
    image.functions = &functions;
    try analyze(image, &.{ .success_block = 5 }, .established);
    blocks[0].terminator.call.arguments = &.{ 1, 0 };
    try analyze(image, &.{ .success_block = 5 }, .potential);
    blocks[0].terminator.call.arguments = &.{ 0, 1 };
    // No base return: root cannot return, but the bad prefix in the helper is
    // still observable. A depth bound or optimistic return seed is unnecessary.
    blocks[6].terminator = .{ .call = .{ .function = 2, .arguments = &.{ 0, 1 }, .next = .{ .block = 7, .assignments = &.{.{ .destination = 3, .source = .returned }} } } };
    blocks[4].terminator.perform.effect = 1;
    blocks[4].terminator.perform.next.assignments = &.{.{ .destination = 3, .source = .returned }};
    blocks[5].terminator = .{ .jump = .{ .block = 6 } };
    try analyze(image, &.{ .success_block = 5 }, .potential);
}

test "existing cloned source fixture retains multi shot suffix and one initialization" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/authoring-baseline/source-cloned.bpi3", a, .limited(1000000));
    defer a.free(bytes);
    var decoded = try @import("program_image.zig").decode(a, bytes);
    defer decoded.deinit();
    const image = decoded.program;
    var admitted = try @import("activation_ownership.zig").analyze(a, image);
    admitted.deinit();
    var producer: ?struct { block: p.Id, position: usize } = null;
    for (image.blocks, 0..) |block, id| for (block.instructions, 0..) |instruction, position| {
        if (instruction.opcode == .cell_new and producer == null) producer = .{ .block = id, .position = position };
    };
    const Bound = struct {
        block: p.Id,
        position: usize,
        fn project(raw: *const anyopaque, _: ir.Program, site: interaction.Site, _: usize) interaction.Mask {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            if (site.phase == .instruction and site.block == self.block and site.position == self.position) return 1;
            if (site.phase == .yield) return 2;
            return 0;
        }
    };
    const bound: Bound = .{ .block = producer.?.block, .position = producer.?.position };
    const monitor: interaction.Monitor = .{ .binding = &bound, .states = 3, .alphabet = 2, .bad = interaction.bit(2), .transitions = &.{ 1, 0, 2, 1, 2, 2 }, .project = Bound.project };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owner = try @import("control_provenance.zig").derive(arena.allocator(), image, &.{}, false);
    var session: interaction.Session = .{ .allocator = a, .owner = owner };
    defer session.deinit();
    const result = try session.analyze(monitor);
    const root = result.get(image.roots.entry, 0, 0);
    try std.testing.expect(root.widened);
    try std.testing.expectEqual(.established, root.status(monitor));
}

test "opaque imports include multiple events and relinking or property change derives fresh facts" {
    var blocks = base.blocks[0..4].*;
    blocks[0].terminator = .{ .call = .{ .function = 1, .arguments = &.{ 0, 1 }, .next = .{ .block = 3, .assignments = &.{.{ .destination = 3, .source = .returned }} } } };
    var functions = [_]ir.Function{ base.functions[0], base.functions[0] };
    functions[1].entry = @import("relocation.zig").missing;
    functions[1].layout.slots = &.{ 0, 0 };
    var image = base;
    image.blocks = &blocks;
    image.functions = &functions;
    var admitted = try @import("activation_ownership.zig").analyzeComponent(a, image, &.{1}, &.{.{ .function = 1 }});
    admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owner = try @import("control_provenance.zig").derive(arena.allocator(), image, &.{1}, true);
    var session: interaction.Session = .{ .allocator = a, .owner = owner, .imports = &.{1} };
    defer session.deinit();
    const Projection = struct {
        fn project(_: *const anyopaque, _: ir.Program, _: interaction.Site, _: usize) interaction.Mask {
            return 0;
        }
    };
    const binding: u8 = 0;
    // Neither event alone is bad. Only A then B reaches state 3: one wildcard
    // step would miss the violation, whereas alphabet closure retains it.
    const monitor: interaction.Monitor = .{ .binding = &binding, .states = 4, .alphabet = 2, .bad = interaction.bit(3), .transitions = &.{ 1, 2, 1, 3, 2, 2, 3, 3 }, .project = Projection.project };
    const opaque_result = (try session.analyze(monitor)).get(0, 0, 0);
    try std.testing.expectEqual(.potential, opaque_result.status(monitor));
    try std.testing.expect(opaque_result.widened and opaque_result.may_nonreturn);
    var independent = monitor;
    independent.bad = 0;
    try std.testing.expectEqual(.established, (try session.analyze(independent)).get(0, 0, 0).status(independent));
    try std.testing.expectEqual(@as(usize, 2), session.cached.items.len);
    // Resolve the previously opaque implementation to an actual silent return.
    var linked_blocks: [5]ir.Block = undefined;
    @memcpy(linked_blocks[0..4], &blocks);
    linked_blocks[4] = .{ .function = 1, .instructions = &.{.{ .destination = 3, .opcode = .constant }}, .terminator = .{ .return_value = 3 } };
    var linked_functions = functions;
    linked_functions[1].entry = 4;
    linked_functions[1].layout = base.functions[0].layout;
    image.functions = &linked_functions;
    image.blocks = &linked_blocks;
    const linked_owner = try @import("control_provenance.zig").derive(arena.allocator(), image, &.{}, false);
    var linked: interaction.Session = .{ .allocator = a, .owner = linked_owner };
    defer linked.deinit();
    const linked_result = (try linked.analyze(monitor)).get(0, 0, 0);
    try std.testing.expectEqual(.established, linked_result.status(monitor));
    try std.testing.expect(!linked_result.widened);
}

test "effect free divergence has no invented successful return" {
    var image = base;
    image.effects = &.{};
    image.functions = &.{.{ .entry = 0, .inputs = &.{}, .layout = .{ .slots = &.{} }, .result = 1 }};
    image.blocks = &.{.{ .function = 0, .instructions = &.{}, .terminator = .{ .jump = .{ .block = 0 } } }};
    var admitted = try @import("activation_ownership.zig").analyze(a, image);
    admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owner = try @import("control_provenance.zig").derive(arena.allocator(), image, &.{}, false);
    var session: interaction.Session = .{ .allocator = a, .owner = owner };
    defer session.deinit();
    const binding: Binding = .{};
    const result = (try session.analyze(binding.monitor())).get(0, 0, 0);
    try std.testing.expectEqual(@as(interaction.Mask, 0), result.normal);
    try std.testing.expect(result.may_nonreturn);
    try std.testing.expectEqual(.established, result.status(binding.monitor()));
}

test "exclusive controlled waits derive a cycle candidate from both actual branch operations" {
    // Test-local environment contract for these exact declarations: operation
    // zero waits for completion while the driver holds its turn; operation one
    // waits for that turn while completion is held. The input selects one host
    // scenario. No claim is made about arbitrary external operations.
    const image: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{ .unit, .boolean },
        .constants = &.{.{ .schema = 0, .bytes = &.{} }},
        .effects = &.{ .{ .identity = "controlled-wait-0", .payload = 0, .result = 0 }, .{ .identity = "controlled-wait-1", .payload = 0, .result = 0 } },
        .functions = &.{.{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 1, 0 } }, .result = 0, .effects = &.{ 0, 1 } }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{.{ .destination = 1, .opcode = .constant }}, .terminator = .{ .branch = .{ .condition = 0, .when_true = .{ .block = 1 }, .when_false = .{ .block = 2 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 0, .payload = 1, .next = .{ .block = 3 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{ .effect = 1, .payload = 1, .next = .{ .block = 3 } } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        },
    };
    var admitted = try @import("activation_ownership.zig").analyze(a, image);
    admitted.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owner = try @import("control_provenance.zig").derive(arena.allocator(), image, &.{}, false);
    var session: interaction.Session = .{ .allocator = a, .owner = owner };
    defer session.deinit();
    const Projection = struct {
        fn project(_: *const anyopaque, subject: ir.Program, site: interaction.Site, _: usize) interaction.Mask {
            return if (site.phase == .operation) interaction.bit(@intCast(subject.blocks[@intCast(site.block)].terminator.perform.effect)) else 0;
        }
    };
    const binding: u8 = 0;
    const monitor: interaction.Monitor = .{ .binding = &binding, .states = 4, .alphabet = 2, .bad = interaction.bit(3), .transitions = &.{ 1, 2, 1, 3, 3, 2, 3, 3 }, .project = Projection.project };
    const summary = (try session.analyze(monitor)).get(0, 0, 0);
    try std.testing.expectEqual(.established, summary.status(monitor)); // no concrete path has both waits
    const service = @import("service_interactions.zig");
    var edges: std.ArrayList(service.WaitEdge) = .empty;
    defer edges.deinit(a);
    for (image.blocks, 0..) |block, id| if (block.terminator == .perform) {
        const operation = block.terminator.perform.effect;
        if (summary.prefixes & interaction.bit(@as(usize, @intCast(operation)) + 1) == 0) continue;
        try edges.append(a, .{ .dependent = if (operation == 0) .driver else .completion, .required = if (operation == 0) .completion else .driver, .site = id });
    };
    const ranked = try service.rank(a, edges.items);
    defer a.free(ranked.ranks);
    try std.testing.expectEqual(.cycle_candidate, ranked.status);
    try std.testing.expect(!service.checkRanks(edges.items, ranked.ranks));
}

test "existing cleanup and injection programs retain exceptional and latent observations" {
    const provenance = @import("control_provenance.zig");
    for ([_][]const u8{ "cleanup-disposal", "cleanup-disposal-owned", "cleanup-disposal-running", "cleanup-disposal-failure", "injection", "shallow-injection" }) |name| {
        const path = try std.fmt.allocPrint(a, "test/authoring-baseline/source-{s}.bpi3", .{name});
        defer a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1000000));
        defer a.free(bytes);
        var decoded = try @import("program_image.zig").decode(a, bytes);
        defer decoded.deinit();
        const image = decoded.program;
        var admitted = try @import("activation_ownership.zig").analyze(a, image);
        admitted.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const owner = try provenance.deriveObserved(arena.allocator(), image, &.{}, false, true);
        const Projection = struct {
            fn project(_: *const anyopaque, _: ir.Program, site: interaction.Site, _: usize) interaction.Mask {
                return switch (site.phase) {
                    .operation => 1,
                    .failure => 2,
                    .cancellation => 4,
                    else => 0,
                };
            }
        };
        const binding: u8 = 0;
        const monitor: interaction.Monitor = .{ .binding = &binding, .states = 4, .alphabet = 3, .bad = interaction.bit(3), .transitions = &.{ 1, 2, 3, 1, 2, 3, 2, 2, 3, 3, 3, 3 }, .project = Projection.project };
        var session: interaction.Session = .{ .allocator = a, .owner = owner };
        defer session.deinit();
        const result = try session.analyze(monitor);
        const root = result.get(image.roots.entry, 0, 0);
        try std.testing.expect(root.failure != 0 and root.cancellation != 0);
        try std.testing.expectEqual(.potential, root.status(monitor));
    }
}
