// Copyright (c) 2026 Boundary contributors. MIT license.
//! Exact word-coordinate GF(2) spaces used by affine capture extraction.
//! A bit selects an entire unsigned word, never a bit lane or nominal object.
const std = @import("std");
pub const max_dimension = 128;
pub const Row = u128;
pub const Error = error{ InvalidAffineSpace, WorkLimit };
pub const Budget = struct {
    remaining: u64,
    pub fn charge(self: *Budget) Error!void {
        if (self.remaining == 0) return error.WorkLimit;
        self.remaining -= 1;
    }
};
pub fn coordinate(index: usize) Row {
    std.debug.assert(index < max_dimension);
    return @as(Row, 1) << @intCast(index);
}
pub fn mask(dimension: usize) Row {
    std.debug.assert(dimension <= max_dimension);
    return if (dimension == max_dimension) std.math.maxInt(Row) else (@as(
        Row,
        1,
    ) << @intCast(dimension)) - 1;
}
pub const Space = struct {
    dimension: usize,
    pivots: [max_dimension]Row = @splat(0),
    rank: usize = 0,

    pub fn init(dimension: usize) Error!Space {
        if (dimension > max_dimension) return error.InvalidAffineSpace;
        return .{ .dimension = dimension };
    }
    pub fn insert(self: *Space, input: Row, budget: *Budget) Error!bool {
        if (input & ~mask(self.dimension) != 0) return error.InvalidAffineSpace;
        var row = input;
        for (0..self.dimension) |pivot| {
            try budget.charge();
            if (row & coordinate(pivot) == 0) continue;
            if (self.pivots[pivot] != 0) {
                row ^= self.pivots[pivot];
            } else {
                self.pivots[pivot] = row;
                self.rank += 1;
                return true;
            }
        }
        return false;
    }
    /// Coordinates in the ordered nonzero pivot rows, or null outside this span.
    pub fn coefficients(self: *const Space, input: Row, budget: *Budget) Error!?Row {
        if (input & ~mask(self.dimension) != 0) return error.InvalidAffineSpace;
        var row = input;
        var coefficients_row: Row = 0;
        var basis_index: usize = 0;
        for (0..self.dimension) |pivot| {
            try budget.charge();
            const basis = self.pivots[pivot];
            if (basis == 0) {
                if (row & coordinate(pivot) != 0) return null;
                continue;
            }
            if (row & coordinate(pivot) != 0) {
                row ^= basis;
                coefficients_row ^= coordinate(basis_index);
            }
            basis_index += 1;
        }
        return if (row == 0) coefficients_row else null;
    }
    /// Unique reduced row-echelon basis; the represented row space is unchanged.
    pub fn canonical(self: Space, budget: *Budget) Error!Space {
        var result = self;
        var pivot = self.dimension;
        while (pivot != 0) {
            pivot -= 1;
            const row = result.pivots[pivot];
            if (row == 0) continue;
            for (0..pivot) |prior| {
                try budget.charge();
                if (result.pivots[prior] & coordinate(pivot) != 0) result.pivots[prior] ^= row;
            }
        }
        return result;
    }
    pub fn rows(self: *const Space, output: *[max_dimension]Row) []const Row {
        var count: usize = 0;
        for (self.pivots[0..self.dimension]) |row| if (row != 0) {
            output[count] = row;
            count += 1;
        };
        return output[0..count];
    }
};

/// Pull a successor observation back through a parallel word update. Each
/// transition row is an expression in the predecessor coordinates.
pub fn pull(row: Row, transition: []const Row, source_dimension: usize, budget: *Budget) Error!Row {
    if (transition.len > max_dimension or source_dimension > max_dimension or row & ~mask(
        transition.len,
    ) != 0) return error.InvalidAffineSpace;
    var result: Row = 0;
    for (transition, 0..) |input, index| {
        try budget.charge();
        if (input & ~mask(source_dimension) != 0) return error.InvalidAffineSpace;
        if (row & coordinate(index) != 0) result ^= input;
    }
    return result;
}

pub const Edge = struct { source: usize, target: usize, matrix: []const Row };

/// Propagate changed successor requirements through indexed predecessor edges.
/// The caller owns the returned spaces; failures release every partial owner.
pub fn closeLocations(
    allocator: std.mem.Allocator,
    seeds: []const Space,
    edges: []const Edge,
    budget: *Budget,
) (Error || std.mem.Allocator.Error)![]Space {
    const result = try allocator.dupe(Space, seeds);
    errdefer allocator.free(result);
    const none = std.math.maxInt(usize);
    const heads = try allocator.alloc(usize, seeds.len);
    defer allocator.free(heads);
    @memset(heads, none);
    const next = try allocator.alloc(usize, edges.len);
    defer allocator.free(next);
    for (edges, 0..) |edge, index| {
        try budget.charge();
        if (edge.source >= seeds.len or
            edge.target >= seeds.len or
            edge.matrix.len != seeds[edge.target].dimension)
            return error.InvalidAffineSpace;
        for (edge.matrix) |row| if (row & ~mask(
            seeds[edge.source].dimension,
        ) != 0) return error.InvalidAffineSpace;
        next[index] = heads[edge.target];
        heads[edge.target] = index;
    }
    const pending = try allocator.alloc(bool, seeds.len);
    defer allocator.free(pending);
    @memset(pending, true);
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    for (seeds, 0..) |_, index| try queue.append(allocator, index);
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        try budget.charge();
        const target = queue.items[cursor];
        pending[target] = false;
        var buffer: [max_dimension]Row = undefined;
        const observations = result[target].rows(&buffer);
        var index = heads[target];
        while (index != none) : (index = next[index]) {
            const edge = edges[index];
            var changed = false;
            for (observations) |row| {
                const predecessor = try pull(
                    row,
                    edge.matrix,
                    result[edge.source].dimension,
                    budget,
                );
                changed = try result[edge.source].insert(predecessor, budget) or changed;
            }
            if (changed and !pending[edge.source]) {
                try queue.append(allocator, edge.source);
                pending[edge.source] = true;
            }
        }
    }
    return result;
}

/// Single-location adapter uses the same predecessor-worklist implementation.
pub fn close(
    allocator: std.mem.Allocator,
    seed: Space,
    transitions: []const []const Row,
    budget: *Budget,
) (Error || std.mem.Allocator.Error)!Space {
    const edges = try allocator.alloc(Edge, transitions.len);
    defer allocator.free(edges);
    for (
        transitions,
        edges,
    ) |matrix, *edge| edge.* = .{ .source = 0, .target = 0, .matrix = matrix };
    const result = try closeLocations(allocator, &.{seed}, edges, budget);
    defer allocator.free(result);
    return result[0];
}

/// Independent certificate primitive: reconstruct an equation from supplied
/// coefficients rather than invoking the closure finder or elimination routine.
pub fn equation(
    expected: Row,
    coefficients_row: Row,
    basis: []const Row,
    dimension: usize,
    budget: *Budget,
) Error!void {
    if (basis.len > max_dimension or dimension > max_dimension or coefficients_row & ~mask(
        basis.len,
    ) != 0 or expected & ~mask(dimension) != 0) return error.InvalidAffineSpace;
    var actual: Row = 0;
    for (basis, 0..) |row, index| {
        try budget.charge();
        if (row & ~mask(dimension) != 0) return error.InvalidAffineSpace;
        if (coefficients_row & coordinate(index) != 0) actual ^= row;
    }
    if (actual != expected) return error.InvalidAffineSpace;
}

test "rotating three-word future observations close at rank two" {
    var budget: Budget = .{ .remaining = 10000 };
    var seed = try Space.init(3);
    _ = try seed.insert(0b011, &budget);
    _ = try seed.insert(0b110, &budget);
    const closed = try close(std.testing.allocator, seed, &.{&.{ 0b010, 0b100, 0b001 }}, &budget);
    try std.testing.expectEqual(@as(usize, 2), closed.rank);
    var buffer: [max_dimension]Row = undefined;
    const basis = closed.rows(&buffer);
    for (basis) |row| {
        const next = try pull(row, &.{ 0b010, 0b100, 0b001 }, 3, &budget);
        try equation(next, (try closed.coefficients(next, &budget)).?, basis, 3, &budget);
    }
    try std.testing.expectError(error.InvalidAffineSpace, equation(0b001, 1, basis, 3, &budget));
}

test "future reset distinguishes equal parity and budgets reject partial closure" {
    var budget: Budget = .{ .remaining = 10000 };
    var seed = try Space.init(2);
    _ = try seed.insert(0b11, &budget);
    const closed = try close(std.testing.allocator, seed, &.{&.{ 0, 0b10 }}, &budget);
    try std.testing.expectEqual(@as(usize, 2), closed.rank);
    var exhausted: Budget = .{ .remaining = 0 };
    try std.testing.expectError(
        error.WorkLimit,
        close(std.testing.allocator, seed, &.{&.{ 0, 0b10 }}, &exhausted),
    );
    try std.testing.expectEqual(@as(usize, 1), seed.rank);
}

test "generated permutation parity closes at all specified dimensions" {
    for ([_]usize{ 2, 3, 8, 32, 64, 128 }) |n| {
        var budget: Budget = .{ .remaining = 1000000 };
        var seed = try Space.init(n);
        _ = try seed.insert(mask(n), &budget);
        var transition: [max_dimension]Row = undefined;
        for (0..n) |i| transition[i] = coordinate((i + n - 1) % n);
        const closed = try close(std.testing.allocator, seed, &.{transition[0..n]}, &budget);
        try std.testing.expectEqual(@as(usize, 1), closed.rank);
    }
}

test "location closure retains full entry inspection and compresses future parity loop" {
    const a = std.testing.allocator;
    var budget: Budget = .{ .remaining = 10000 };
    var entry = try Space.init(2);
    _ = try entry.insert(1, &budget);
    _ = try entry.insert(2, &budget);
    var loop = try Space.init(2);
    _ = try loop.insert(3, &budget);
    const forward: Edge = .{ .source = 0, .target = 1, .matrix = &.{ 1, 2 } };
    const swap: Edge = .{ .source = 1, .target = 1, .matrix = &.{ 2, 1 } };
    const spaces = try closeLocations(a, &.{ entry, loop }, &.{ forward, swap }, &budget);
    defer a.free(spaces);
    try std.testing.expectEqual(@as(usize, 2), spaces[0].rank);
    try std.testing.expectEqual(@as(usize, 1), spaces[1].rank);
    const returned = try closeLocations(
        a,
        &.{ entry, loop },
        &.{ forward, swap, .{ .source = 1, .target = 0, .matrix = &.{ 1, 2 } } },
        &budget,
    );
    defer a.free(returned);
    try std.testing.expectEqual(@as(usize, 2), returned[1].rank);
}
