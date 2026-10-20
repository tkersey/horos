// Copyright (c) 2026 Boundary contributors. MIT license.
//! Well-typed semantic mutants: ordinary admission is deliberately insufficient.
const std = @import("std");
const testing = std.testing;
const p = @import("program.zig");
const ir = @import("activation.zig");
const r = @import("relocation.zig");
const w = @import("coalescing_witness.zig");
const validator = @import("coalescing_validation.zig");
const admission = @import("activation_ownership.zig");
const pass = @import("coalescing.zig");

fn admitted(program: ir.Program) !void {
    var facts = try admission.analyze(testing.allocator, program);
    facts.deinit();
}
fn identity(a: std.mem.Allocator, program: ir.Program) !w.Witness {
    const maps = try r.identityMaps(a, try r.sizes(program));
    const locals = try a.alloc(w.Local, program.functions.len);
    for (locals, program.functions) |*local, function| {
        const slots = try a.alloc(p.Id, function.layout.slots.len);
        const custody = try a.alloc(p.Id, function.custody.len);
        for (slots, 0..) |*id, index| id.* = index;
        for (custody, 0..) |*id, index| id.* = index;
        local.* = .{ .slots = slots, .custody = custody };
    }
    return .{ .representatives = maps, .final = maps, .locals = locals };
}
fn rejectMutation(before: ir.Program, after: ir.Program) !void {
    try admitted(before);
    try admitted(after);
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const map = try identity(scratch.allocator(), before);
    try validator.validate(testing.allocator, before, before, map);
    try testing.expectError(
        error.InvalidCorrespondence,
        validator.validate(testing.allocator, before, after, map),
    );
}

test "coalescing preserves callable use effect and capture-bound distinctions" {
    const callable: p.Schema = .{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = 0,
        .use = .reusable,
        .capture_bound = &.{0},
    } } };
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{ .u64, .unit, callable, callable },
        .constants = &.{},
        .effects = &.{.{ .identity = "latent", .payload = 1, .result = 0 }},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 0, 2, 3 } },
            .result = 0,
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        }},
    };
    var equivalent = try pass.run(testing.allocator, program, .{});
    defer equivalent.deinit();
    try testing.expectEqual(@as(usize, 3), equivalent.program.schemas.len);
    for (0..3) |mutation| {
        var changed = program;
        var schemas = program.schemas[0..4].*;
        switch (mutation) {
            0 => schemas[3].internal.computation.use = .linear,
            1 => schemas[3].internal.computation.effects = &.{0},
            else => schemas[3].internal.computation.capture_bound = &.{},
        }
        changed.schemas = &schemas;
        try rejectMutation(program, changed);
        var distinct = try pass.run(testing.allocator, changed, .{});
        defer distinct.deinit();
        try testing.expectEqual(@as(usize, 4), distinct.program.schemas.len);
    }
}

test "coalescing rejects changed region and resource contracts independently" {
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 1 },
        .schemas = &.{
            .u64,                                                         .unit,
            .{ .internal = .{ .cell = .{ .element = 0, .region = 0 } } }, .{ .internal = .{ .cell = .{ .element = 0, .region = 1 } } },
            .{ .internal = .{ .abstract_resource = 0 } },                 .{ .internal = .{ .abstract_resource = 1 } },
        },
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 0, 2, 3, 4, 5 } },
            .result = 0,
            .regions = &.{ 0, 1 },
        }},
        .blocks = &.{.{
            .function = 0,
            .instructions = &.{},
            .terminator = .{ .return_value = 0 },
        }},
        .scopes = .{ .region_count = 2, .resources = &.{
            .{ .representation = 0, .introducers = &.{0}, .eliminators = &.{0} },
            .{ .representation = 0, .introducers = &.{0}, .eliminators = &.{0} },
        } },
    };
    var changed = program;
    var schemas = program.schemas[0..6].*;
    schemas[2].internal.cell.region = 1;
    changed.schemas = &schemas;
    try rejectMutation(program, changed);
    for (0..3) |mutation| {
        changed = program;
        var resources = program.scopes.resources[0..2].*;
        switch (mutation) {
            0 => resources[0].representation = 1,
            1 => resources[0].introducers = &.{},
            else => resources[0].eliminators = &.{},
        }
        changed.scopes.resources = &resources;
        try rejectMutation(program, changed);
    }
    var optimized = try pass.run(testing.allocator, program, .{});
    defer optimized.deinit();
    try testing.expectEqual(@as(usize, 2), optimized.program.scopes.resources.len);
    try testing.expectEqual(@as(p.Id, 2), optimized.program.scopes.region_count);
}

const arithmetic: ir.Program = .{
    .roots = .{ .entry = 2, .result = 1, .failure = 0 },
    .schemas = &.{ .u64, .{ .product = &.{ 0, 0 } } },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{ 41, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .schema = 0, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } },
    },
    .effects = &.{},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
        .{ .entry = 1, .inputs = &.{ 0, 1 }, .layout = .{ .slots = &.{ 0, 0, 0 } }, .result = 0 },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 0, 0, 0, 1 } },
            .result = 1,
        },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{.{
            .destination = 2,
            .opcode = .integer_add,
            .operands = &.{ 0, 1 },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
        }}, .terminator = .{ .return_value = 2 } },
        .{ .function = 1, .instructions = &.{.{
            .destination = 2,
            .opcode = .integer_add,
            .operands = &.{ 0, 1 },
            .failures = &.{.{ .kind = .arithmetic_overflow, .value = 0 }},
        }}, .terminator = .{ .return_value = 2 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 0,
            .arguments = &.{ 0, 1 },
            .next = .{
                .block = 3,
                .assignments = &.{.{ .destination = 2, .source = .returned }},
            },
        } } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
            .function = 1,
            .arguments = &.{ 0, 1 },
            .next = .{
                .block = 4,
                .assignments = &.{.{ .destination = 3, .source = .returned }},
            },
        } } },
        .{ .function = 2, .instructions = &.{.{
            .destination = 4,
            .opcode = .product,
            .operands = &.{ 2, 3 },
        }}, .terminator = .{ .return_value = 4 } },
    },
};

test "coalescing rejects changed arithmetic opcode operands and failure payload independently" {
    var equivalent = try pass.run(testing.allocator, arithmetic, .{});
    defer equivalent.deinit();
    try testing.expectEqual(@as(usize, 2), equivalent.program.functions.len);
    const Mutation = enum { opcode, operands, failure_payload, returned_slot };
    for (std.enums.values(Mutation)) |mutation| {
        var changed = arithmetic;
        var blocks = arithmetic.blocks[0..5].*;
        var instructions = arithmetic.blocks[1].instructions[0..1].*;
        switch (mutation) {
            .opcode => instructions[0].opcode = .integer_sub,
            .operands => instructions[0].operands = &.{ 1, 0 },
            .failure_payload => instructions[0].failures =
                &.{.{ .kind = .arithmetic_overflow, .value = 1 }},
            .returned_slot => blocks[1].terminator.return_value = 0,
        }
        blocks[1].instructions = &instructions;
        changed.blocks = &blocks;
        try rejectMutation(arithmetic, changed);
        var result = try pass.run(testing.allocator, changed, .{});
        defer result.deinit();
        try testing.expectEqual(@as(usize, 3), result.program.functions.len);
    }
}

test "coalescing raw checker distinguishes immediate ordinals and complete failure kinds" {
    const field: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = arithmetic.schemas,
        .constants = &.{},
        .effects = &.{},
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 1, 0 } },
            .result = 0,
        }},
        .blocks = &.{.{ .function = 0, .instructions = &.{.{
            .destination = 1,
            .opcode = .field,
            .operands = &.{0},
            .immediate = 0,
        }}, .terminator = .{ .return_value = 1 } }},
    };
    var changed = field;
    var blocks = field.blocks[0..1].*;
    var operations = blocks[0].instructions[0..1].*;
    operations[0].immediate = 1;
    blocks[0].instructions = &operations;
    changed.blocks = &blocks;
    try rejectMutation(field, changed);

    var division = arithmetic;
    var div_blocks = arithmetic.blocks[0..5].*;
    var div_operations = arithmetic.blocks[1].instructions[0..1].*;
    div_operations[0].opcode = .integer_div;
    div_operations[0].failures = &.{
        .{ .kind = .arithmetic_overflow, .value = 0 },
        .{ .kind = .division_by_zero, .value = 1 },
    };
    div_blocks[1].instructions = &div_operations;
    division.blocks = &div_blocks;
    try admitted(division);
    var mutant_blocks = div_blocks;
    var mutant_operations = div_operations;
    mutant_operations[0].failures = &.{
        .{ .kind = .arithmetic_overflow, .value = 1 },
        .{ .kind = .division_by_zero, .value = 0 },
    };
    mutant_blocks[1].instructions = &mutant_operations;
    var mutant = division;
    mutant.blocks = &mutant_blocks;
    try rejectMutation(division, mutant);
}

test "coalescing raw checker rejects swapped branch and sum-case roles" {
    for ([_]bool{ false, true }) |sum| {
        const program: ir.Program = .{
            .roots = .{ .entry = 0, .result = 0, .failure = 0 },
            .schemas = &.{ .u64, if (sum) .{ .sum = &.{ 0, 0 } } else .boolean },
            .constants = arithmetic.constants,
            .effects = &.{},
            .functions = &.{.{
                .entry = 0,
                .inputs = &.{0},
                .layout = .{ .slots = &.{ 1, 0 } },
                .result = 0,
            }},
            .blocks = &.{
                .{ .function = 0, .instructions = &.{}, .terminator = if (sum)
                    .{ .switch_variant = .{
                        .value = 0,
                        .cases = &.{ .{ .block = 1 }, .{ .block = 2 } },
                    } }
                else
                    .{ .branch = .{
                        .condition = 0,
                        .when_true = .{ .block = 1 },
                        .when_false = .{ .block = 2 },
                    } } },
                .{ .function = 0, .instructions = &.{.{
                    .destination = 1,
                    .opcode = .constant,
                    .immediate = 0,
                }}, .terminator = .{ .return_value = 1 } },
                .{ .function = 0, .instructions = &.{.{
                    .destination = 1,
                    .opcode = .constant,
                    .immediate = 1,
                }}, .terminator = .{ .return_value = 1 } },
            },
        };
        var changed = program;
        var blocks = program.blocks[0..3].*;
        blocks[0].terminator = if (sum) .{ .switch_variant = .{
            .value = 0,
            .cases = &.{ .{ .block = 2 }, .{ .block = 1 } },
        } } else .{ .branch = .{
            .condition = 0,
            .when_true = .{ .block = 2 },
            .when_false = .{ .block = 1 },
        } };
        changed.blocks = &blocks;
        try rejectMutation(program, changed);
    }
}

test "coalescing rejects changed nominal effect use and forged many-to-one effect maps" {
    const program: ir.Program = .{
        .roots = .{ .entry = 0, .result = 0, .failure = 0 },
        .schemas = &.{.u64},
        .constants = &.{},
        .effects = &.{
            .{ .identity = "same-name", .payload = 0, .result = 0 },
            .{ .identity = "same-name", .payload = 0, .result = 0 },
        },
        .functions = &.{.{
            .entry = 0,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 0, 0 } },
            .result = 0,
            .effects = &.{ 0, 1 },
        }},
        .blocks = &.{
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{
                .effect = 0,
                .payload = 0,
                .next = .{
                    .block = 1,
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .perform = .{
                .effect = 1,
                .payload = 1,
                .next = .{
                    .block = 2,
                    .assignments = &.{.{ .destination = 1, .source = .returned }},
                },
            } } },
            .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 1 } },
        },
    };
    var changed = program;
    var blocks = program.blocks[0..3].*;
    blocks[0].terminator.perform.effect = 1;
    changed.blocks = &blocks;
    try rejectMutation(program, changed);
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var forged = try identity(scratch.allocator(), program);
    forged.representatives[@backingInt(r.Kind.effect)] = &.{ 0, 0 };
    forged.final[@backingInt(r.Kind.effect)] = &.{ 0, 0 };
    try testing.expectError(
        error.InvalidCorrespondence,
        validator.validate(testing.allocator, program, program, forged),
    );
    var optimized = try pass.run(testing.allocator, program, .{});
    defer optimized.deinit();
    try testing.expectEqual(@as(usize, 2), optimized.program.effects.len);
    try testing.expectEqual(@as(p.Id, 0), optimized.program.blocks[0].terminator.perform.effect);
    try testing.expectEqual(@as(p.Id, 1), optimized.program.blocks[1].terminator.perform.effect);
}

test "coalescing does not erase same-shaped code type width sign bound or tag contracts" {
    const pairs = [_][2]p.Schema{
        .{ .u32, .i32 },
        .{ .u32, .u64 },
        .{ .{ .bounded_bytes = 8 }, .{ .bounded_bytes = 9 } },
        .{ .{ .bounded_text = 8 }, .{ .bounded_text = 9 } },
        .{
            .{ .array = .{ .element = 4, .length = 1 } },
            .{ .array = .{ .element = 4, .length = 2 } },
        },
        .{ .{ .enumeration = &.{ 0, 1 } }, .{ .enumeration = &.{ 0, 2 } } },
    };
    for (pairs) |pair| {
        const schemas = [_]p.Schema{ pair[0], pair[1], .{ .product = &.{ 0, 1 } }, .unit, .u8 };
        const program: ir.Program = .{
            .roots = .{ .entry = 2, .result = 2, .failure = 3 },
            .schemas = &schemas,
            .constants = &.{},
            .effects = &.{},
            .functions = &.{
                .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
                .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{1} }, .result = 1 },
                .{
                    .entry = 2,
                    .inputs = &.{ 0, 1 },
                    .layout = .{ .slots = &.{ 0, 1, 0, 1, 2 } },
                    .result = 2,
                },
            },
            .blocks = &.{
                .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
                .{ .function = 1, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
                .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
                    .function = 0,
                    .arguments = &.{0},
                    .next = .{
                        .block = 3,
                        .assignments = &.{.{ .destination = 2, .source = .returned }},
                    },
                } } },
                .{ .function = 2, .instructions = &.{}, .terminator = .{ .call = .{
                    .function = 1,
                    .arguments = &.{1},
                    .next = .{
                        .block = 4,
                        .assignments = &.{.{ .destination = 3, .source = .returned }},
                    },
                } } },
                .{ .function = 2, .instructions = &.{.{
                    .opcode = .product,
                    .destination = 4,
                    .operands = &.{ 2, 3 },
                }}, .terminator = .{ .return_value = 4 } },
            },
        };
        var result = try pass.run(testing.allocator, program, .{});
        defer result.deinit();
        try testing.expectEqual(@as(usize, 3), result.program.functions.len);
        const first = result.program.schemas[@intCast(result.program.functions[0].result)];
        const second = result.program.schemas[@intCast(result.program.functions[1].result)];
        try testing.expect(!@import("record.zig").equal(p.Schema, first, second));
    }
}

const handler_strategies: ir.Program = .{
    .roots = .{ .entry = 4, .result = 5, .failure = 0 },
    .schemas = &.{
        .unit,                                 .u64,
        .{ .internal = .{ .capability = 0 } },
        .{
            .internal = .{
                .resumption = .{
                    .effect = 0,
                    .input = 1,
                    .answer = 1,
                    .handled = &.{0},
                    .capture_bound = &.{ 0, 1, 2 },
                    .mode = .deep,
                    .use = .linear,
                },
            },
        },
        .{ .internal = .{ .computation = .{
            .parameters = &.{2},
            .result = 1,
            .effects = &.{0},
        } } },
        .{ .product = &.{ 1, 1 } },
    },
    .constants = &.{
        .{ .schema = 0, .bytes = &.{} },
        .{ .schema = 1, .bytes = &.{ 42, 0, 0, 0, 0, 0, 0, 0 } },
    },
    .effects = &.{.{ .identity = "handled", .payload = 0, .result = 1, .external = false }},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{1} }, .result = 1 },
        .{ .entry = 1, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 1 } }, .result = 1 },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 3, 1, 1 } },
            .result = 1,
        },
        .{
            .entry = 4,
            .inputs = &.{0},
            .layout = .{ .slots = &.{ 2, 0, 1 } },
            .result = 1,
            .effects = &.{0},
        },
        .{ .entry = 6, .inputs = &.{}, .layout = .{ .slots = &.{ 4, 1, 1, 5 } }, .result = 5 },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{ .function = 1, .instructions = &.{.{
            .opcode = .constant,
            .destination = 1,
            .immediate = 1,
        }}, .terminator = .{ .return_value = 1 } },
        .{ .function = 2, .instructions = &.{.{
            .opcode = .constant,
            .destination = 2,
            .immediate = 1,
        }}, .terminator = .{ .resume_value = .{
            .resumption = 1,
            .argument = 2,
            .next = .{ .block = 3, .assignments = &.{.{ .destination = 3, .source = .returned }} },
        } } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 3 } },
        .{ .function = 3, .instructions = &.{.{
            .opcode = .constant,
            .destination = 1,
        }}, .terminator = .{ .perform = .{
            .effect = 0,
            .capability = 0,
            .payload = 1,
            .next = .{ .block = 5, .assignments = &.{.{ .destination = 2, .source = .returned }} },
        } } },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{ .function = 4, .instructions = &.{.{
            .opcode = .computation,
            .destination = 0,
        }}, .terminator = .{ .handle = .{
            .handler = 0,
            .body = 0,
            .arguments = &.{},
            .state = &.{},
            .next = .{
                .block = 7,
                .assignments = &.{.{ .destination = 1, .source = .returned }},
            },
        } } },
        .{ .function = 4, .instructions = &.{}, .terminator = .{ .handle = .{
            .handler = 1,
            .body = 0,
            .arguments = &.{},
            .state = &.{},
            .next = .{
                .block = 8,
                .assignments = &.{.{ .destination = 2, .source = .returned }},
            },
        } } },
        .{ .function = 4, .instructions = &.{.{
            .opcode = .product,
            .destination = 3,
            .operands = &.{ 1, 2 },
        }}, .terminator = .{ .return_value = 3 } },
    },
    .handlers = &.{
        .{
            .mode = .deep,
            .input = 1,
            .answer = 1,
            .return_function = 0,
            .clauses = &.{.{ .effect = 0, .function = 1, .resumption = 3, .strategy = .tail }},
        },
        .{
            .mode = .deep,
            .input = 1,
            .answer = 1,
            .return_function = 0,
            .clauses = &.{.{ .effect = 0, .function = 2, .resumption = 3, .strategy = .general }},
        },
    },
    .constructors = &.{.{ .function = 3, .capture = 0, .schema = 4 }},
    .scopes = .{ .captures = &.{.{ .fields = &.{}, .use = .reusable }} },
};

test "coalescing preserves distinct valid tail and general handler contracts" {
    try admitted(handler_strategies);
    var result = try pass.run(testing.allocator, handler_strategies, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.program.handlers.len);
    try testing.expect(result.program.handlers[0].clauses[0].strategy == .tail);
    try testing.expect(result.program.handlers[1].clauses[0].strategy == .general);
    var changed = handler_strategies;
    changed.handlers = &.{ handler_strategies.handlers[1], handler_strategies.handlers[1] };
    try rejectMutation(handler_strategies, changed);
}
