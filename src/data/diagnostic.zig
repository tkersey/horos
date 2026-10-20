//! Optional admission locations. These are observations, never wire evidence.
const p = @import("program.zig");
pub const Diagnostic = struct {
    phase: enum {
        roots,
        schema,
        constant,
        effect,
        function,
        capture,
        constructor,
        handler,
        block,
        region,
    } = .roots,
    code: ?anyerror = null,
    schema: ?p.Id = null,
    function: ?p.Id = null,
    block: ?p.Id = null,
    instruction: ?p.Id = null,
    terminator: ?p.TerminatorTag = null,
    callee: ?p.Id = null,
    capture: ?p.Id = null,
    field: ?p.Id = null,
    handler: ?p.Id = null,
    slot: ?p.Id = null,
    effect: ?p.Id = null,
};

/// Bounded, caller-owned presentation; no compiler-arena slices survive failure.
pub const Origins = struct {
    functions: [8]p.Id = @splat(0),
    count: usize = 0,
    /// Multiple possible origins, or an unenumerated origin set after rewriting.
    ambiguous: bool = false,
    truncated: bool = false,

    pub fn items(self: *const Origins) []const p.Id {
        return self.functions[0..self.count];
    }
    pub fn add(self: *Origins, function: p.Id) void {
        if (self.count != 0 and self.functions[0] != function) self.ambiguous = true;
        for (self.items()) |prior| if (prior == function) return;
        if (self.count == self.functions.len) {
            self.truncated = true;
            return;
        }
        self.functions[self.count] = function;
        self.count += 1;
    }
};
