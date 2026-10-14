//! Keep the source-based observation audit exhaustive as the compiler evolves.
const std = @import("std");
const Stage = @import("closed_compilation.zig").Stage;

test "every compiler stage has exactly one observation coverage disposition" {
    const names = @typeInfo(Stage).@"enum".field_names;
    var seen: [names.len]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, @embedFile("validator_coverage.md"), '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        var cells = std.mem.splitScalar(u8, line, '|');
        _ = cells.next();
        const name = std.mem.trim(u8, cells.next().?, " `");
        var found = false;
        inline for (names, 0..) |known, index| {
            if (std.mem.eql(u8, name, known)) {
                try std.testing.expect(!seen[index]);
                seen[index] = true;
                found = true;
            }
        }
        try std.testing.expect(found);
        // Validator, observation, positive, negative and gap/disposition.
        for (0..5) |_| {
            const cell = cells.next() orelse return error.MissingDisposition;
            try std.testing.expect(std.mem.trim(u8, cell, " ").len != 0);
        }
        try std.testing.expectEqualStrings("", cells.next().?);
        try std.testing.expect(cells.next() == null);
    }
    for (seen) |present| try std.testing.expect(present);
}
