// Copyright (c) 2026 Boundary contributors. MIT license.
const std = @import("std");
const source = @import("../source.zig");
const lower = @import("activation_lower.zig");
const data = @import("horos_data");
pub const Interface = struct {
    imports: []const data.component.Symbol = &.{},
    exports: []const data.component.Symbol,
    /// Explicit assumptions for each imported function. Empty means no borrowed
    /// dependencies, writes or outlives requirements, and is checked at linking.
    borrows: []const data.borrow_contract.Summary = &.{},
};
pub const Compiled = struct {
    construction: lower.Construction,
    object: data.component.Object,
    pub fn deinit(self: *Compiled) void {
        self.construction.deinit();
        self.* = undefined;
    }
    pub fn encode(self: *const Compiled, allocator: std.mem.Allocator, output: []u8) ![]const u8 {
        return data.component.encode(allocator, self.object, output);
    }
};
fn less(_: void, a: data.component.Symbol, b: data.component.Symbol) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
pub fn compile(
    allocator: std.mem.Allocator,
    module: source.Module,
    interface: Interface,
) !Compiled {
    return compileObserved(allocator, module, interface, .{});
}
pub fn compileObserved(
    allocator: std.mem.Allocator,
    module: source.Module,
    interface: Interface,
    options: source.CompileOptions,
) !Compiled {
    options.resetObservations();
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    var functions: std.ArrayList(data.program.Id) = .empty;
    for (interface.imports) |symbol| if (symbol.reference.kind == .function) try functions.append(
        temporary.allocator(),
        symbol.reference.id,
    );
    const assumed = try temporary.allocator().dupe(data.borrow_contract.Summary, interface.borrows);
    const order = struct {
        fn lessThan(
            _: void,
            left: data.borrow_contract.Summary,
            right: data.borrow_contract.Summary,
        ) bool {
            return left.function < right.function;
        }
    };
    std.mem.sort(data.borrow_contract.Summary, assumed, {}, order.lessThan);
    var construction = try lower.lowerComponentObserved(
        allocator,
        module,
        functions.items,
        assumed,
        options,
    );
    errdefer construction.deinit();
    const a = construction.arena.allocator();
    const imports = try source.own([]const data.component.Symbol, a, interface.imports);
    const exports = try source.own([]const data.component.Symbol, a, interface.exports);
    std.mem.sort(data.component.Symbol, @constCast(imports), {}, less);
    std.mem.sort(data.component.Symbol, @constCast(exports), {}, less);
    var borrows: std.ArrayList(data.borrow_contract.Summary) = .empty;
    try borrows.appendSlice(
        a,
        try source.own([]const data.borrow_contract.Summary, a, interface.borrows),
    );
    std.mem.sort(data.borrow_contract.Summary, borrows.items, {}, order.lessThan);
    const schemas = try data.admission.schemas(a, construction.program.schemas);
    var solver = try data.borrow_flow.contracted(
        a,
        construction.program,
        functions.items,
        schemas.exportable,
        borrows.items,
    );
    const required = try data.component.interfaceFunctions(a, .{
        .program = construction.program,
        .imports = imports,
        .exports = exports,
    });
    for (required) |function| {
        for (borrows.items) |summary| {
            if (summary.function == function) break;
        } else try borrows.append(a, try data.borrow_contract.infer(&solver, function));
    }
    std.mem.sort(data.borrow_contract.Summary, borrows.items, {}, order.lessThan);
    const object: data.component.Object = .{
        .program = construction.program,
        .imports = imports,
        .exports = exports,
        .borrows = borrows.items,
    };
    try data.component.validate(allocator, object);
    return .{ .construction = construction, .object = object };
}
