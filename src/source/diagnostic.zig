//! Caller-owned diagnostics and optional compilation phase observations.
const data = @import("horos_data");
const p = data.program;
pub const Stage = enum {
    source_copy,
    source_check,
    lowering,
    target_check,
    direct_optimization,
    canonicalization,
    coalescing,
    semantic_optimization,
    complete,
};
pub const Diagnostic = struct {
    phase: Stage = .source_copy,
    code: ?anyerror = null,
    function: ?p.Id = null,
    term: ?p.Id = null,
    value: ?p.Id = null,
    variable: ?p.Id = null,
    /// `function` is a representative when this summary is ambiguous.
    origins: Origins = .{},
    target: data.admission.Diagnostic = .{},
};
pub const Origins = data.admission.Origins;
pub const Observer = struct {
    context: *anyopaque,
    enter: *const fn (*anyopaque, Stage) void,
};
/// A source variable retained at an effect boundary, derived by target liveness.
pub const CaptureObserver = struct {
    context: *anyopaque,
    capture: *const fn (*anyopaque, *const data.activation_ownership.CaptureSite, p.Id) void,
    closure: *const fn (*anyopaque, p.Id, p.Id) void,
};
pub const Options = struct {
    diagnostic: ?*Diagnostic = null,
    observer: ?Observer = null,
    captures: ?CaptureObserver = null,
    coalescing: data.coalescing.Options = .{},
    /// Structural preserves cross-build logical work; semantic preserves the
    /// declared external contract. Neither contract can disable P01.
    contract: data.closed_compilation.Contract = .structural,
    objective: data.closed_compilation.Objective = .balanced,
    image_growth_bytes: ?usize = null,
    max_image_bytes: ?usize = null,
    /// Bound to the original lowered record; validation belongs to the shared compiler.
    profile: ?data.closed_compilation.ProfilePolicy = null,
    semantic_work_limit: u64 = data.closed_compilation.default_work_limit,
    semantic_round_limit: usize = 4,
    semantic_statistics: ?*data.closed_compilation.Statistics = null,
    compilation_observer: ?data.closed_compilation.Observer = null,

    pub fn resetObservations(self: Options) void {
        const compilation: data.closed_compilation.Options = .{ .statistics = self.semantic_statistics, .coalescing = self.coalescing };
        compilation.resetObservations();
        if (self.diagnostic) |diagnostic| diagnostic.* = .{};
    }

    pub fn stage(self: Options, next: Stage) void {
        if (self.diagnostic) |d| d.phase = next;
        if (self.observer) |observer| observer.enter(observer.context, next);
    }
};
