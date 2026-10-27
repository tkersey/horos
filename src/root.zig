// Copyright (c) 2026 Boundary contributors. MIT license.
pub const package_version = "8.0.0";
pub const authoring = @import("authoring.zig");
pub const source = @import("source.zig");
pub const library = struct {
    pub const hyper = @import("library/hyper.zig");
    pub const choice = @import("library/choice.zig");
    pub const generator = @import("library/generator.zig");
    pub const state = @import("library/state.zig");
    pub const reader = @import("library/reader.zig");
    pub const writer = @import("library/writer.zig");
    pub const raise = @import("library/raise.zig");
    pub const scheduler = @import("library/scheduler.zig");
    pub const search = @import("library/search.zig");
};
pub const program = struct {
    pub const lower = source.emit;
    pub const compile = source.lower;
    pub const compileObserved = source.lowerObserved;
    pub const Diagnostic = source.Diagnostic;
    pub const CompileOptions = source.CompileOptions;
};
pub const data = @import("horos_data");

test {
    _ = source;
    _ = library.hyper;
    _ = library.hyper.demand;
    _ = library.generator;
}
