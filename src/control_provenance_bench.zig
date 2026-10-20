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
        const program = if (candidate_mode) try @import(
            "data/evidence_forwarding_tests.zig",
        ).fixture(
            input,
        ) else load: {
            const path = try std.fmt.allocPrint(input, "{s}/{s}.bpi3", .{ directory, name });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, input, .unlimited);
            decoded = try image.decode(init.gpa, bytes);
            break :load decoded.?.program;
        };
        var candidate = if (candidate_mode) try forwarding.construct(
            init.gpa,
            program,
            .{},
        ) else null;
        defer if (candidate) |*value| value.deinit();
        const measurement: Measurement = .{
            .allocator = init.gpa,
            .io = init.io,
            .writer = &output.interface,
            .name = name,
            .operation = operation,
            .program = program,
            .candidate = candidate,
        };
        for (0..fixtures.samples) |sample| try measurement.run(sample);
        try output.interface.flush();
    }
}

const Program = @import("data/activation.zig").Program;
const Measurement = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    name: []const u8,
    operation: []const u8,
    program: Program,
    candidate: ?forwarding.Candidate,

    fn run(self: Measurement, sample: usize) !void {
        var meter: Meter = .{ .parent = self.allocator };
        var arena = std.heap.ArenaAllocator.init(meter.allocator());
        var result: Statistics = .{};
        const start = std.Io.Clock.awake.now(self.io);
        if (std.mem.startsWith(u8, self.operation, "candidate-")) {
            try result.candidate(
                meter.allocator(),
                self.operation,
                self.program,
                self.candidate orelse return error.MissingCandidate,
            );
        } else {
            try result.observed(arena.allocator(), self.io, self.operation, self.program, start);
        }
        const elapsed = result.derivation_ns orelse start.durationTo(
            std.Io.Clock.awake.now(self.io),
        ).nanoseconds;
        try std.json.Stringify.value(
            .{
                .fixture = self.name,
                .operation = self.operation,
                .sample = sample,
                .ns = elapsed,
                .retained_bytes = meter.live,
                .peak_bytes = meter.peak,
                .allocation_calls = meter.calls,
                .arena_capacity = arena.queryCapacity(),
                .direct_recipients = result.recipients,
                .target_derivations = result.derivations,
                .queries = result.queries,
                .explanation_reasons = result.reasons,
                .finite_states = result.states,
                .phase_or_worklist_edges = result.edges,
                .wait_edges = result.wait_edges,
                .relations = result.relations,
                .widening_sites = result.widenings,
                .iterations = result.iterations,
            },
            .{},
            self.writer,
        );
        try self.writer.writeByte('\n');
        arena.deinit();
        if (meter.live != 0) return error.LeakedDerivation;
    }
};

const Statistics = struct {
    reasons: usize = 0,
    states: usize = 0,
    edges: usize = 0,
    wait_edges: usize = 0,
    relations: usize = 0,
    widenings: usize = 0,
    iterations: usize = 0,
    recipients: usize = 0,
    queries: usize = 0,
    derivations: usize = 0,
    derivation_ns: ?i96 = null,

    fn candidate(
        self: *Statistics,
        allocator: std.mem.Allocator,
        operation: []const u8,
        program: Program,
        proposed: forwarding.Candidate,
    ) !void {
        if (std.mem.eql(u8, operation, "candidate-validate")) {
            try forwarding.validate(
                allocator,
                program,
                proposed.program,
                proposed.pairs,
                10_000_000,
            );
            self.derivations = 2;
        } else if (std.mem.eql(u8, operation, "candidate-observe")) {
            const observation = try forwarding.observeInteractions(
                allocator,
                program,
                proposed.program,
                proposed.pairs,
                10_000_000,
            );
            self.relations = observation.relations;
            self.widenings = observation.opaque_sites;
            self.queries = observation.monitors * 2;
            self.states = observation.finite_states;
            self.edges = observation.control_states;
            self.iterations = observation.iterations;
            self.derivations = 2; // borrow each intrinsic admission's owner
        } else return error.InvalidArguments;
    }

    fn observed(
        self: *Statistics,
        allocator: std.mem.Allocator,
        io: std.Io,
        operation: []const u8,
        program: Program,
        start: std.Io.Timestamp,
    ) !void {
        const explain = std.mem.eql(u8, operation, "explain");
        const control = try provenance.deriveObserved(
            allocator,
            program,
            &.{},
            false,
            explain,
        );
        if (std.mem.eql(
            u8,
            operation,
            "derive",
        )) self.derivation_ns = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        self.derivations = 1;
        try self.targets(program, control, explain);
        if (std.mem.eql(u8, operation, "interactions")) {
            try self.interaction(allocator, control);
        } else if (std.mem.eql(u8, operation, "service")) {
            try self.service(allocator, control);
        } else if (!explain and !std.mem.eql(u8, operation, "derive")) {
            return error.InvalidArguments;
        }
    }

    fn targets(
        self: *Statistics,
        program: Program,
        control: *const provenance.Analysis,
        explain: bool,
    ) !void {
        for (program.blocks, 0..) |block, index|
            if (block.terminator == .perform) {
                self.recipients += control.targets(
                    .{ .block = index, .role = .operation },
                    block.terminator.perform.effect,
                ).len;
                if (explain) {
                    const selected = try control.select(
                        .{ .block = index, .role = .operation },
                        block.terminator.perform.effect,
                    );
                    const presentation = try control.explain(selected);
                    self.reasons += presentation.reasons.len;
                    self.queries += 1;
                    const again = try control.explain(selected);
                    if (presentation.reasons.ptr != again.reasons.ptr)
                        return error.RepeatedDerivation;
                }
            };
    }

    fn interaction(
        self: *Statistics,
        allocator: std.mem.Allocator,
        control: *const provenance.Analysis,
    ) !void {
        const Probe = struct {
            fn project(
                _: *const anyopaque,
                subject: @import("data/activation.zig").Program,
                site: interactions.Site,
                _: usize,
            ) interactions.Mask {
                if (site.phase != .operation) return 0;
                return interactions.bit(
                    @intCast(
                        subject.blocks[
                            @intCast(site.block)
                        ].terminator.perform.effect % 2,
                    ),
                );
            }
        };
        const binding: u8 = 0;
        const monitor: interactions.Monitor = .{
            .binding = &binding,
            .states = 3,
            .alphabet = 2,
            .bad = 0,
            .transitions = &.{ 1, 2, 1, 2, 1, 2 },
            .project = Probe.project,
        };
        var session: interactions.Session = .{
            .allocator = allocator,
            .owner = control,
        };
        defer session.deinit();
        const result = try session.analyze(monitor);
        if (result.summaries.ptr != (try session.analyze(
            monitor,
        )).summaries.ptr) return error.RepeatedDerivation;
        self.states = result.summaries.len;
        self.edges = result.statistics.control_states;
        self.relations = result.statistics.relations;
        self.widenings = result.statistics.opaque_sites;
        self.iterations = result.statistics.iterations;
        self.queries = 1;
    }

    fn service(
        self: *Statistics,
        allocator: std.mem.Allocator,
        control: *const provenance.Analysis,
    ) !void {
        const report = try @import("data/service_interactions.zig").observe(
            allocator,
            control,
            .{
                .command = "example/service-command",
                .reply = "example/service-reply",
                .finalizer = "example/service-finalize",
            },
        );
        const phases = report.phases orelse return error.UnrecognizedService;
        self.states = phases.nodes * 10;
        self.edges = phases.edges.len;
        self.wait_edges = report.waits.?.edges.len;
        const summary = report.summary.?;
        self.relations = @popCount(summary.normal) + @popCount(summary.failure) + @popCount(
            summary.cancellation,
        );
        self.queries = 2; // ordered lifecycle and waits, one target owner

    }
};
