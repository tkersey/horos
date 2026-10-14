//! Private derivation/observation measurement. No authoring/data API or threshold.
const std = @import("std");
const image = @import("data/program_image.zig");
const provenance = @import("data/control_provenance.zig");
const interactions = @import("data/interactions.zig");
const forwarding = @import("data/evidence_forwarding.zig");
const Meter = @import("coalescing_allocation_meter.zig").Meter;
const fixtures = @import("admission_bench_fixtures.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const directory = args.next() orelse return error.MissingDirectory;
    const operation = args.next() orelse "derive";
    const requested_name = args.next();
    if (args.next() != null) return error.InvalidArguments;
    const names: []const []const u8 = if (requested_name) |name| &.{name} else &fixtures.names;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    for (names) |name| {
        var inputs = std.heap.ArenaAllocator.init(init.gpa);
        defer inputs.deinit();
        const input = inputs.allocator();
        const candidate_mode = std.mem.startsWith(u8, operation, "candidate-");
        var decoded: ?image.Decoded = null;
        defer if (decoded) |*value| value.deinit();
        const program = if (candidate_mode) try @import("data/evidence_forwarding_tests.zig").fixture(input) else load: {
            const path = try std.fmt.allocPrint(input, "{s}/{s}.bpi3", .{ directory, name });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, input, .unlimited);
            decoded = try image.decode(init.gpa, bytes);
            break :load decoded.?.program;
        };
        var candidate = if (candidate_mode) try forwarding.construct(init.gpa, program, .{}) else null;
        defer if (candidate) |*value| value.deinit();
        for (0..fixtures.samples) |sample| {
            var meter: Meter = .{ .parent = init.gpa };
            var arena = std.heap.ArenaAllocator.init(meter.allocator());
            var reasons: usize = 0;
            var states: usize = 0;
            var edges: usize = 0;
            var wait_edges: usize = 0;
            var relations: usize = 0;
            var widenings: usize = 0;
            var iterations: usize = 0;
            var recipients: usize = 0;
            var queries: usize = 0;
            var derivations: usize = 0;
            var derivation_ns: ?i96 = null;
            const start = std.Io.Clock.awake.now(init.io);
            if (candidate_mode) {
                const proposed = candidate orelse return error.MissingCandidate;
                if (std.mem.eql(u8, operation, "candidate-validate")) {
                    try forwarding.validate(meter.allocator(), program, proposed.program, proposed.pairs, 10_000_000);
                    derivations = 2;
                } else if (std.mem.eql(u8, operation, "candidate-observe")) {
                    const observation = try forwarding.observeInteractions(meter.allocator(), program, proposed.program, proposed.pairs, 10_000_000);
                    relations = observation.relations;
                    widenings = observation.opaque_sites;
                    queries = observation.monitors * 2;
                    states = observation.finite_states;
                    edges = observation.control_states;
                    iterations = observation.iterations;
                    derivations = 2; // borrow each intrinsic admission's owner
                } else return error.InvalidArguments;
            } else {
                const explain = std.mem.eql(u8, operation, "explain");
                const control = try provenance.deriveObserved(arena.allocator(), program, &.{}, false, explain);
                if (std.mem.eql(u8, operation, "derive")) derivation_ns = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
                derivations = 1;
                for (program.blocks, 0..) |block, index| if (block.terminator == .perform) {
                    recipients += control.targets(.{ .block = index, .role = .operation }, block.terminator.perform.effect).len;
                    if (explain) {
                        const selected = try control.select(.{ .block = index, .role = .operation }, block.terminator.perform.effect);
                        const presentation = try control.explain(selected);
                        reasons += presentation.reasons.len;
                        queries += 1;
                        const again = try control.explain(selected);
                        if (presentation.reasons.ptr != again.reasons.ptr) return error.RepeatedDerivation;
                    }
                };
                if (std.mem.eql(u8, operation, "interactions")) {
                    const Probe = struct {
                        fn project(_: *const anyopaque, subject: @import("data/activation.zig").Program, site: interactions.Site, _: usize) interactions.Mask {
                            if (site.phase != .operation) return 0;
                            return interactions.bit(@intCast(subject.blocks[@intCast(site.block)].terminator.perform.effect % 2));
                        }
                    };
                    const binding: u8 = 0;
                    const monitor: interactions.Monitor = .{ .binding = &binding, .states = 3, .alphabet = 2, .bad = 0, .transitions = &.{ 1, 2, 1, 2, 1, 2 }, .project = Probe.project };
                    var session: interactions.Session = .{ .allocator = arena.allocator(), .owner = control };
                    defer session.deinit();
                    const result = try session.analyze(monitor);
                    if (result.summaries.ptr != (try session.analyze(monitor)).summaries.ptr) return error.RepeatedDerivation;
                    states = program.functions.len * monitor.states;
                    edges = result.statistics.control_states;
                    relations = result.statistics.relations;
                    widenings = result.statistics.opaque_sites;
                    iterations = result.statistics.iterations;
                    queries = 1;
                } else if (std.mem.eql(u8, operation, "service")) {
                    const report = try @import("data/service_interactions.zig").observe(arena.allocator(), control, .{ .command = "example/service-command", .reply = "example/service-reply", .finalizer = "example/service-finalize" });
                    const phases = report.phases orelse return error.UnrecognizedService;
                    states = phases.nodes * 10;
                    edges = phases.edges.len;
                    wait_edges = report.waits.?.edges.len;
                    const summary = report.summary.?;
                    relations = @popCount(summary.normal) + @popCount(summary.failure) + @popCount(summary.cancellation);
                    queries = 2; // ordered lifecycle and waits, one target owner
                } else if (!explain and !std.mem.eql(u8, operation, "derive")) return error.InvalidArguments;
            }
            const elapsed = derivation_ns orelse start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            try std.json.Stringify.value(.{ .fixture = name, .operation = operation, .sample = sample, .ns = elapsed, .retained_bytes = meter.live, .peak_bytes = meter.peak, .allocation_calls = meter.calls, .arena_capacity = arena.queryCapacity(), .direct_recipients = recipients, .target_derivations = derivations, .queries = queries, .explanation_reasons = reasons, .finite_states = states, .phase_or_worklist_edges = edges, .wait_edges = wait_edges, .relations = relations, .widening_sites = widenings, .iterations = iterations }, .{}, &output.interface);
            try output.interface.writeByte('\n');
            arena.deinit();
            if (meter.live != 0) return error.LeakedDerivation;
        }
        try output.interface.flush();
    }
}
