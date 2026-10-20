const std = @import("std");
const data = @import("root.zig");
const program_record = @import("program_record.zig");
const testing = std.testing;
const example: data.component.Object = .{
    .program = .{
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
            .instructions = &.{.{ .destination = 0, .opcode = .constant }},
            .terminator = .{ .return_value = 0 },
        }},
    },
    .exports = &.{.{ .name = "main", .reference = .{ .kind = .function, .id = 0 } }},
    .borrows = &.{.{ .function = 0 }},
};

// Independently transcribed grammar: stable scalar Program, no imports, main export.
const golden = "ABL_BMO1".* ++ [_]u8{
    1,   0,   0,   0, 46, 0, 0, 0, 0, 0, 0, 0,
    1,   0,   0,   1, 2,  9, 0, 1, 0, 8, 1, 42,
    0,   1,   0,   0, 0,  1, 0, 0, 1, 0, 1, 0,
    0,   0,   0,   0, 0,  0, 0, 0, 0, 1, 4, 'm',
    'a', 'i', 'n', 3, 0,  1, 0, 0, 0, 0,
};

test "link statistics describe the current invocation after early rejection" {
    const compilation = data.closed_compilation;
    for ([_]compilation.Contract{ .structural, .semantic }) |contract| {
        var stats: compilation.Statistics = .{};
        const options: compilation.Options = .{ .contract = contract, .statistics = &stats };
        const entry: data.linker.Endpoint = .{ .instance = "case", .symbol = "main" };
        const instance: data.linker.Instance = .{ .key = "case", .object = &golden };
        for (0..4) |failure| {
            var linked = try data.linker.linkWithCompilation(
                testing.allocator,
                &.{instance},
                &.{},
                entry,
                options,
            );
            linked.deinit();
            try testing.expect(stats.outcome != .not_run);
            try testing.expect(stats.final_bytes != 0);
            switch (failure) {
                0 => try testing.expectError(
                    error.InvalidSymbol,
                    data.linker.linkWithCompilation(
                        testing.allocator,
                        &.{.{ .key = "", .object = &golden }},
                        &.{},
                        entry,
                        options,
                    ),
                ),
                1 => try testing.expectError(
                    error.Truncated,
                    data.linker.linkWithCompilation(
                        testing.allocator,
                        &.{.{ .key = "case", .object = &.{} }},
                        &.{},
                        entry,
                        options,
                    ),
                ),
                2 => try testing.expectError(
                    error.DuplicateInstance,
                    data.linker.linkWithCompilation(
                        testing.allocator,
                        &.{ instance, instance },
                        &.{},
                        entry,
                        options,
                    ),
                ),
                3 => try testing.expectError(
                    error.MissingSymbol,
                    data.linker.linkWithCompilation(
                        testing.allocator,
                        &.{instance},
                        &.{},
                        .{ .instance = "case", .symbol = "absent" },
                        options,
                    ),
                ),
                else => unreachable,
            }
            try testing.expectEqualDeep(compilation.Statistics{}, stats);
        }
    }
}

test "BMO1 golden framing and canonical owned decode" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualSlices(
        u8,
        &golden,
        try data.component.encode(testing.allocator, example, &buffer),
    );
    var bytes = golden;
    var decoded = try data.component.decode(testing.allocator, &bytes);
    defer decoded.deinit();
    @memset(&bytes, 0xff);
    try testing.expectEqualDeep(example, decoded.object);
    for (0..golden.len) |length| {
        if (data.component.decode(testing.allocator, golden[0..length])) |owner| {
            var invalid = owner;
            invalid.deinit();
            return error.ExpectedError;
        } else |_| {}
    }
    bytes = golden;
    bytes[8] = 2;
    try testing.expectError(
        error.UnsupportedVersion,
        data.component.decode(testing.allocator, &bytes),
    );
    bytes = golden;
    bytes[10] = 1;
    try testing.expectError(error.InvalidFlags, data.component.decode(testing.allocator, &bytes));
    bytes = golden;
    bytes[golden.len - 7] = 10;
    try testing.expectError(error.InvalidTag, data.component.decode(testing.allocator, &bytes));
    bytes[golden.len - 7] = 255;
    try testing.expectError(error.NonCanonical, data.component.decode(testing.allocator, &bytes));
}

// Deliberately bypass the checked emitter to exercise untrusted public admission.
fn forgedObject(object_value: data.component.Object) ![]u8 {
    const bytes = try testing.allocator.alloc(u8, try data.component.encodedLength(object_value));
    errdefer testing.allocator.free(bytes);
    var writer: data.wire.Writer = .{ .output = bytes };
    try writer.put(data.component.magic);
    try writer.fixed(u16, 1);
    try writer.fixed(u16, 0);
    try writer.fixed(u64, bytes.len - data.wire.header_length);
    var context: program_record.Context = .{};
    try program_record.write(data.activation.Program, object_value.program, &writer, &context);
    try @import("record.zig").write([]const data.component.Symbol, object_value.imports, &writer);
    try @import("record.zig").write([]const data.component.Symbol, object_value.exports, &writer);
    try @import("record.zig").write(
        []const data.borrow_contract.Summary,
        object_value.borrows,
        &writer,
    );
    return bytes;
}

test "public linker rejects forged resource elimination authority" {
    const bytes = try forgedObject(example);
    defer testing.allocator.free(bytes);
    var decoded = try data.component.decode(testing.allocator, bytes);
    defer decoded.deinit();
    var forged = decoded.object;
    forged.program.scopes.resources = &.{.{
        .representation = forged.program.roots.result,
        .introducers = &.{},
        .eliminators = &.{0},
    }};
    forged.imports = &.{.{ .name = "resource", .reference = .{ .kind = .resource, .id = 0 } }};
    const invalid = try forgedObject(forged);
    defer testing.allocator.free(invalid);
    try testing.expectError(
        error.InvalidOwnership,
        data.linker.link(
            testing.allocator,
            &.{.{ .key = "forged", .object = invalid }},
            &.{},
            .{ .instance = "forged", .symbol = "main" },
        ),
    );
}

test "declared region cardinality is bounded before relocation allocation" {
    var excessive = example;
    excessive.program.scopes.region_count = std.math.maxInt(u64);
    const bytes = try forgedObject(excessive);
    defer testing.allocator.free(bytes);
    try testing.expectError(error.Capacity, data.component.decode(testing.allocator, bytes));
}

test "cyclic unresolved aliases reject without recursive linking" {
    var object_value = example;
    object_value.program.functions = &.{ example.program.functions[0], .{
        .entry = data.relocation.missing,
        .inputs = &.{},
        .layout = .{ .slots = &.{} },
        .result = 0,
    } };
    object_value.imports = &.{.{ .name = "need", .reference = .{ .kind = .function, .id = 1 } }};
    object_value.exports = &.{.{ .name = "alias", .reference = .{ .kind = .function, .id = 1 } }};
    object_value.borrows = &.{.{ .function = 1 }};
    var buffer: [256]u8 = undefined;
    const bytes = try data.component.encode(testing.allocator, object_value, &buffer);
    const bindings = [_]data.linker.Binding{
        .{
            .required = .{ .instance = "a", .symbol = "need" },
            .supplied = .{ .instance = "b", .symbol = "alias" },
        },
        .{
            .required = .{ .instance = "b", .symbol = "need" },
            .supplied = .{ .instance = "a", .symbol = "alias" },
        },
    };
    try testing.expectError(
        error.UnresolvedImport,
        data.linker.link(
            testing.allocator,
            &.{ .{ .key = "a", .object = bytes }, .{ .key = "b", .object = bytes } },
            &bindings,
            .{ .instance = "a", .symbol = "alias" },
        ),
    );
}

const input_borrow = [_]data.borrow_contract.Projection{.{ .source = .{ .input = 0 } }};
const borrow_example: data.component.Object = .{
    .program = .{
        .roots = .{ .entry = 3, .result = 0, .failure = 0 },
        .schemas = &.{ .unit, .{ .internal = .{ .capability = 0 } } },
        .constants = &.{.{ .schema = 0, .bytes = &.{} }},
        .effects = &.{.{ .identity = "borrow", .payload = 0, .result = 0, .external = false }},
        .functions = &.{
            .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{1} }, .result = 1 },
            .{
                .entry = data.relocation.missing,
                .inputs = &.{0},
                .layout = .{ .slots = &.{1} },
                .result = 1,
            },
            .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{ 1, 1 } }, .result = 1 },
            .{ .entry = 3, .inputs = &.{}, .layout = .{ .slots = &.{0} }, .result = 0 },
        },
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
            .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
                .function = 1,
                .arguments = &.{0},
                .next = .{
                    .block = 2,
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } } },
            .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
            .{
                .function = 3,
                .instructions = &.{.{ .destination = 0, .opcode = .constant }},
                .terminator = .{ .return_value = 0 },
            },
        },
    },
    .imports = &.{.{ .name = "need", .reference = .{ .kind = .function, .id = 1 } }},
    .exports = &.{
        .{ .name = "identity", .reference = .{ .kind = .function, .id = 0 } },
        .{ .name = "main", .reference = .{ .kind = .function, .id = 3 } },
    },
    .borrows = &.{
        .{ .function = 0, .returned = &input_borrow },
        .{ .function = 1, .returned = &input_borrow },
        .{ .function = 2, .returned = &input_borrow },
        .{ .function = 3 },
    },
};
const borrow_bindings = [_]data.linker.Binding{.{
    .required = .{ .instance = "case", .symbol = "need" },
    .supplied = .{ .instance = "case", .symbol = "identity" },
}};

test "public linker proves imported borrow promises against the actual implementation" {
    {
        inline for (.{ false, true }) |honest| {
            var object_value = borrow_example;
            var summaries = borrow_example.borrows[0..4].*;
            if (!honest) {
                summaries[1].returned = &.{};
                summaries[2].returned = &.{};
            }
            object_value.borrows = &summaries;
            var buffer: [1024]u8 = undefined;
            // Both clients are locally valid under their distinct import assumptions.
            const bytes = try data.component.encode(testing.allocator, object_value, &buffer);
            const result = data.linker.linkWithOptions(
                testing.allocator,
                &.{.{ .key = "case", .object = bytes }},
                &borrow_bindings,
                .{ .instance = "case", .symbol = "main" },
                .{},
            );
            if (honest) {
                var linked = try result;
                linked.deinit();
            } else try testing.expectError(error.InvalidOwnership, result);
        }
    }
}

test "BMO1 rejects absent, duplicate and malformed imported borrow contracts" {
    var object_value = borrow_example;
    object_value.borrows = &.{ borrow_example.borrows[0], borrow_example.borrows[2] };
    try testing.expectError(
        error.InvalidOwnership,
        data.component.validate(testing.allocator, object_value),
    );
    object_value.borrows = &.{ borrow_example.borrows[0], borrow_example.borrows[0] };
    try testing.expectError(
        error.NonCanonical,
        data.component.validate(testing.allocator, object_value),
    );
    const invalid = [_]data.borrow_contract.Projection{
        .{ .source = .{ .input = 1 } },
        .{ .source = .{ .input = 0 }, .path = &.{.{ .field = 0 }} },
        .{
            .source = .{ .input = 0 },
            .path = &.{.{ .environment = .{ .constructor = 99, .field = 0 } }},
        },
        .{
            .source = .{ .input = 0 },
            .path = &.{.{ .handler_state = .{ .handler = 99, .field = 0 } }},
        },
        .{ .source = .{ .ambient = .region }, .path = &.{.cell_content} },
    };
    for (invalid) |projection| {
        var summaries = borrow_example.borrows[0..4].*;
        summaries[1].returned = &.{projection};
        object_value.borrows = &summaries;
        const bytes = try forgedObject(object_value);
        defer testing.allocator.free(bytes);
        try testing.expectError(
            error.InvalidReference,
            data.component.decode(testing.allocator, bytes),
        );
    }
}

test "component guarantees bind cell writes and outlives requirements" {
    const value: data.borrow_contract.Projection = .{ .source = .{ .input = 1 } };
    const owner: data.borrow_contract.Projection = .{ .source = .{ .input = 0 } };
    const summary: data.borrow_contract.Summary = .{
        .function = 0,
        .requirements = &.{.{ .value = value, .owner = owner, .bound = .region }},
        .writes = &.{.{ .schema = 2, .sources = &.{value} }},
    };
    var object_value: data.component.Object = .{
        .program = .{
            .roots = .{ .entry = 0, .result = 0, .failure = 0 },
            .schemas = &.{
                .unit,
                .{ .internal = .{ .capability = 0 } },
                .{ .internal = .{ .cell = .{ .element = 1, .region = 0 } } },
            },
            .constants = &.{},
            .effects = &.{.{
                .identity = "cell-borrow",
                .payload = 0,
                .result = 0,
                .external = false,
            }},
            .functions = &.{.{
                .entry = 0,
                .inputs = &.{ 0, 1 },
                .layout = .{ .slots = &.{ 2, 1, 0 } },
                .result = 0,
                .regions = &.{0},
            }},
            .blocks = &.{.{
                .function = 0,
                .instructions = &.{.{
                    .destination = 2,
                    .opcode = .cell_set,
                    .operands = &.{ 0, 1 },
                }},
                .terminator = .{ .return_value = 2 },
            }},
            .scopes = .{ .region_count = 1 },
        },
        .exports = &.{.{ .name = "main", .reference = .{ .kind = .function, .id = 0 } }},
        .borrows = &.{summary},
    };
    try data.component.validate(testing.allocator, object_value);
    var missing = summary;
    missing.requirements = &.{};
    object_value.borrows = &.{missing};
    try testing.expectError(
        error.InvalidOwnership,
        data.component.validate(testing.allocator, object_value),
    );
    missing = summary;
    missing.writes = &.{};
    object_value.borrows = &.{missing};
    try testing.expectError(
        error.InvalidOwnership,
        data.component.validate(testing.allocator, object_value),
    );
}

test "imported handler and constructor functions cannot substitute different borrow provenance" {
    inline for (.{ data.relocation.Kind.handler, data.relocation.Kind.constructor }) |kind| {
        inline for (.{ false, true }) |honest| try checkImportedBorrow(kind, honest);
    }
}

fn checkImportedBorrow(comptime kind: data.relocation.Kind, comptime honest: bool) !void {
    const provider_input: data.program.Id = if (honest) 1 else 0;
    const declared = [_]data.borrow_contract.Projection{.{ .source = .{ .input = 1 } }};
    const provided = [_]data.borrow_contract.Projection{
        .{ .source = .{ .input = provider_input } },
    };
    const object_value: data.component.Object = .{
        .program = comptime importedBorrowProgram(kind, provider_input),
        .imports = &.{.{ .name = "need", .reference = .{ .kind = kind, .id = 0 } }},
        .exports = &.{
            .{ .name = "main", .reference = .{ .kind = .function, .id = 2 } },
            .{ .name = "provided", .reference = .{ .kind = kind, .id = 1 } },
        },
        .borrows = &.{
            .{ .function = 0, .returned = &declared },
            .{ .function = 1, .returned = &provided },
            .{ .function = 2 },
        },
    };
    var buffer: [2048]u8 = undefined;
    const bytes = try data.component.encode(testing.allocator, object_value, &buffer);
    const result = data.linker.linkWithOptions(testing.allocator, &.{.{
        .key = "case",
        .object = bytes,
    }}, &.{.{
        .required = .{ .instance = "case", .symbol = "need" },
        .supplied = .{ .instance = "case", .symbol = "provided" },
    }}, .{ .instance = "case", .symbol = "main" }, .{});
    if (honest) {
        var linked = try result;
        linked.deinit();
    } else try testing.expectError(error.InvalidOwnership, result);
}

const borrow_provider_functions = [_]data.activation.Function{
    .{
        .entry = 0,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 1, 1 } },
        .result = 1,
    },
    .{
        .entry = 1,
        .inputs = &.{ 0, 1 },
        .layout = .{ .slots = &.{ 1, 1 } },
        .result = 1,
    },
    .{
        .entry = 2,
        .inputs = &.{},
        .layout = .{ .slots = &.{0} },
        .result = 0,
    },
};
fn borrowProviderBlocks(comptime provider_input: data.program.Id) [3]data.activation.Block {
    return .{
        .{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .return_value = 1 },
        },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{ .return_value = provider_input },
        },
        .{
            .function = 2,
            .instructions = &.{.{ .destination = 0, .opcode = .constant }},
            .terminator = .{ .return_value = 0 },
        },
    };
}
fn importedBorrowProgram(
    comptime kind: data.relocation.Kind,
    comptime provider_input: data.program.Id,
) data.activation.Program {
    return .{
        .roots = .{ .entry = 2, .result = 0, .failure = 0 },
        .schemas = &.{
            .unit, .{ .internal = .{ .capability = 0 } },
            .{ .internal = .{ .computation = .{
                .parameters = &.{ 1, 1 },
                .result = 1,
            } } },
        },
        .constants = &.{.{ .schema = 0, .bytes = &.{} }},
        .effects = &.{.{
            .identity = "borrow-interface",
            .payload = 0,
            .result = 0,
            .external = false,
        }},
        .functions = &borrow_provider_functions,
        .blocks = &borrowProviderBlocks(provider_input),
        .handlers = if (kind == .handler) &.{
            .{
                .mode = .deep,
                .input = 1,
                .answer = 1,
                .return_function = 0,
                .state = &.{1},
                .clauses = &.{},
            },
            .{
                .mode = .deep,
                .input = 1,
                .answer = 1,
                .return_function = 1,
                .state = &.{1},
                .clauses = &.{},
            },
        } else &.{},
        .constructors = if (kind == .constructor) &.{
            .{ .function = 0, .capture = 0, .schema = 2 },
            .{ .function = 1, .capture = 0, .schema = 2 },
        } else &.{},
        .scopes = .{ .captures = if (kind == .constructor)
            &.{.{ .fields = &.{}, .use = .reusable }}
        else
            &.{} },
    };
}

fn borrowFailure(allocator: std.mem.Allocator) !void {
    var buffer: [1024]u8 = undefined;
    const bytes = try data.component.encode(allocator, borrow_example, &buffer);
    var linked = try data.linker.link(
        allocator,
        &.{.{ .key = "case", .object = bytes }},
        &borrow_bindings,
        .{ .instance = "case", .symbol = "main" },
    );
    defer linked.deinit();
    try testing.expectEqual(
        data.program.Schema.unit,
        linked.program.schemas[@intCast(linked.program.roots.result)],
    );
}

test "borrow contracts release every partial encode decode and link owner" {
    try @import("allocation_testing.zig").check(testing.allocator, borrowFailure, .{});
}
