const std = @import("std");

pub fn build(b: *std.Build) void {
    comptime {
        if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
            @compileError("Zig 0.17.0 is required");
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const public_data = b.addModule("horos_data", .{
        .root_source_file = b.path("src/data/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // This exit constructs only the separately importable pure contract module.
    if (b.option(bool, "data-only", "Construct only horos_data") orelse false) return;
    // Build-host generators must not inherit an exported consumer's target.
    const data = b.createModule(.{
        .root_source_file = b.path("src/data/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    _ = b.addModule("horos", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = public_data }},
    });
    const horos = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    });
    benchmarks(b, data, optimize);
    const static_contracts = staticContracts(b, data, optimize);
    const data_step = dataChecks(b, static_contracts, optimize);
    const static_authoring = staticAuthoring(b, horos, data);
    const native_linker = compiler(b, target, public_data, data, optimize);
    const component_step = componentChecks(b, horos, native_linker, optimize);
    const authoring_checks = authoringChecks(b, data, static_authoring, optimize);
    const native = b.step(
        "check-native",
        "Check native authoring, data and linker contracts without an interpreter",
    );
    native.dependOn(data_step);
    native.dependOn(authoring_checks.step);
    native.dependOn(component_step);
    const wasm_checks = wasmChecks(b, compactProbe(b), compactEmitter(b, horos, optimize));
    const semantics = semanticsChecks(b, data, horos, authoring_checks.run, optimize);
    const aggregate = b.step(
        "check",
        "Check native contracts and independent source/wasm observations",
    );
    aggregate.dependOn(native);
    aggregate.dependOn(semantics);
    aggregate.dependOn(wasm_checks.program);
    aggregate.dependOn(wasm_checks.state);
    aggregate.dependOn(wasm_checks.invocation);
    publicExamples(b, horos, native, optimize);
    b.default_step = aggregate;
}

const source_examples = [_][]const u8{
    "lexical",
    "deep",
    "recursive",
    "choices-all",
    "choices-first",
    "generator",
    "state-local",
    "state-shared",
    "resource-scalar",
    "resource-pair",
    "answers",
    "scoped-reader",
    "writer-raise",
    "scheduler",
    "queens-dfs",
    "queens-bfs",
    "cell-order",
    "nested",
    "shallow",
    "injection",
    "indexed",
    "abort-custody",
    "unwind",
    "reentrant",
    "cloned",
    "clause-abort",
    "bounded-values",
    "scalar-contracts",
    "ownership",
    "shallow-resumptions",
    "shallow-injection",
    "handle-operand-order",
    "protect-operand-order",
    "successor-state",
    "clause-payload",
    "yielding-cleanup",
    "borrow-operands",
    "cleanup-disposal",
    "cleanup-disposal-running",
    "cleanup-disposal-failure",
    "cleanup-disposal-owned",
    "product-projection",
};

fn staticContracts(
    b: *std.Build,
    data: *std.Build.Module,
    optimize: std.lang.Optimize,
) *std.Build.Step {
    const static_contracts = b.step(
        "check-static-contracts",
        "Reject unclassified opcode and reference-contract mutations",
    );
    portableRoleChecks(b, static_contracts, optimize);
    sourceRoleChecks(b, data, static_contracts, optimize);
    opcodeCheck(b, static_contracts, optimize);
    return static_contracts;
}

fn portableRoleChecks(
    b: *std.Build,
    static_contracts: *std.Build.Step,
    optimize: std.lang.Optimize,
) void {
    inline for (.{ "field", "type", "edge", "assignment", "source" }) |mode| {
        const options = b.addOptions();
        options.addOption([]const u8, "value", mode);
        const check = b.addObject(.{
            .name = "portable-role-" ++ mode,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/data/reference_roles_rejections.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });
        check.root_module.addOptions("rejection_mode", options);
        check.expect_errors = .{
            .contains = if (comptime std.mem.eql(u8, mode, "type"))
                "portable reference roles: changed type of capability"
            else if (comptime std.mem.eql(u8, mode, "assignment"))
                "portable reference roles: changed type of destination"
            else if (comptime std.mem.eql(u8, mode, "source"))
                "portable reference roles: changed assignment source"
            else
                "portable reference roles: unclassified or missing field",
        };
        static_contracts.dependOn(&check.step);
    }
}

fn sourceRoleChecks(
    b: *std.Build,
    data: *std.Build.Module,
    static_contracts: *std.Build.Step,
    optimize: std.lang.Optimize,
) void {
    inline for (.{ "field", "type", "case" }) |mode| {
        const options = b.addOptions();
        options.addOption([]const u8, "value", mode);
        const check = b.addObject(.{
            .name = "source-role-" ++ mode,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/source/reference_roles_rejections.zig"),
                .target = b.graph.host,
                .optimize = optimize,
                .imports = &.{.{ .name = "horos_data", .module = data }},
            }),
        });
        check.root_module.addOptions("rejection_mode", options);
        check.expect_errors = .{
            .contains = if (comptime std.mem.eql(u8, mode, "type"))
                "source reference roles: changed type of capability"
            else
                "source reference roles: unclassified or missing field",
        };
        static_contracts.dependOn(&check.step);
    }
}

fn opcodeCheck(b: *std.Build, static_contracts: *std.Build.Step, optimize: std.lang.Optimize) void {
    const mutation = b.addWriteFiles();
    _ = mutation.add(
        "program.zig",
        std.mem.replaceOwned(
            u8,
            b.allocator,
            @embedFile("src/data/program.zig"),
            "    select = 47,",
            "    select = 47,\n    unclassified = 48,",
        ) catch @panic("out of memory"),
    );
    _ = mutation.add("opcode_contract.zig", @embedFile("src/data/opcode_contract.zig"));
    const mutation_root = mutation.add(
        "opcode_mutation.zig",
        "comptime { _ = @import(\"opcode_contract.zig\").describe(.unclassified); }\n",
    );
    const mutated_opcode = b.addObject(.{
        .name = "unclassified-opcode",
        .root_module = b.createModule(.{
            .root_source_file = mutation_root,
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    mutated_opcode.expect_errors = .{ .contains = "switch must handle all possibilities" };
    static_contracts.dependOn(&mutated_opcode.step);
}

fn dataChecks(
    b: *std.Build,
    static_contracts: *std.Build.Step,
    optimize: std.lang.Optimize,
) *std.Build.Step {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/data/test_root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const data_step = b.step("check-data", "Check canonical records and pure admission");
    const run_data_tests = b.addRunArtifact(tests);
    run_data_tests.has_side_effects = true;
    data_step.dependOn(&run_data_tests.step);
    data_step.dependOn(static_contracts);
    return data_step;
}

fn benchmarks(b: *std.Build, data: *std.Build.Module, optimize: std.lang.Optimize) void {
    // Optional measurements use the ordinary structural compiler and admission.
    // Timing is deliberately not a correctness threshold or part of `check`.
    const admission_bench = b.addExecutable(
        .{
            .name = "admission-bench",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/admission_bench.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "horos_data", .module = data }},
                },
            ),
        },
    );
    const run_admission_bench = b.addRunArtifact(admission_bench);
    run_admission_bench.has_side_effects = true;
    const bench_images = run_admission_bench.addOutputDirectoryArg("admission-images");
    const control_bench = b.addExecutable(
        .{
            .name = "control-provenance-bench",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/control_provenance_bench.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                },
            ),
        },
    );
    const run_control_bench = b.addRunArtifact(control_bench);
    run_control_bench.has_side_effects = true;
    run_control_bench.addDirectoryArg(bench_images);
    const bench_step = b.step(
        "bench-admission",
        "Measure structural compilation, admission and private control derivation (JSONL)",
    );
    bench_step.dependOn(&b.addInstallFile(
        run_admission_bench.captureStdOut(.{}),
        "admission-compile.jsonl",
    ).step);
    bench_step.dependOn(&b.addInstallFile(
        run_control_bench.captureStdOut(.{}),
        "admission-derive.jsonl",
    ).step);
}

fn staticAuthoring(
    b: *std.Build,
    horos: *std.Build.Module,
    data: *std.Build.Module,
) *std.Build.Step {
    const static_authoring = b.step(
        "check-static-authoring",
        "Reject incompatible authoring shapes through the public module",
    );
    inline for (@import("test/package_authoring/static_cases.zig").cases) |case| {
        const options = b.addOptions();
        options.addOption([]const u8, "value", case[0]);
        const wrong = b.addExecutable(.{ .name = case[0], .root_module = b.createModule(.{
            .root_source_file = b.path("test/package_authoring/static.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "horos", .module = horos }},
        }) });
        wrong.root_module.addOptions("rejection_mode", options);
        wrong.expect_errors = .{ .contains = case[1] };
        static_authoring.dependOn(&wrong.step);
    }
    inline for (.{ "pointer", "fake" }) |mode| {
        const options = b.addOptions();
        options.addOption([]const u8, "value", mode);
        const rejected_key = b.addObject(
            .{
                .name = "cache-key-" ++ mode,
                .root_module = b.createModule(
                    .{
                        .root_source_file = b.path("src/cache_key_rejections.zig"),
                        .target = b.graph.host,
                        .imports = &.{.{ .name = "horos_data", .module = data }},
                    },
                ),
            },
        );
        rejected_key.root_module.addOptions("rejection_mode", options);
        rejected_key.expect_errors = .{
            .contains = "Horos cache key: pointer needs an explicit identity or ownership policy",
        };
        static_authoring.dependOn(&rejected_key.step);
    }
    return static_authoring;
}

fn compiler(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    public_data: *std.Build.Module,
    data: *std.Build.Module,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const linker = b.addExecutable(.{ .name = "horos-link", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/component_link.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = public_data }},
    }) });
    const native_linker = if (target.query.isNative()) linker else b.addExecutable(.{
        .name = "horos-link-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/component_link.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "horos_data", .module = data }},
        }),
    });

    const installed_linker = b.addInstallArtifact(linker, .{});
    b.getInstallStep().dependOn(&installed_linker.step);
    b.step(
        "build-compiler",
        "Build the source-independent BMO1 linker",
    ).dependOn(&installed_linker.step);
    return native_linker;
}

fn componentChecks(
    b: *std.Build,
    horos: *std.Build.Module,
    native_linker: *std.Build.Step.Compile,
    optimize: std.lang.Optimize,
) *std.Build.Step {
    const helper = b.addExecutable(.{ .name = "horos-checks", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/component_example.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    const component_checks = b.addRunArtifact(helper);
    component_checks.addArg("check-components");
    component_checks.addArtifactArg2(native_linker, .{ .make_absolute = true });
    _ = component_checks.addOutputDirectoryArg2("components", .{});
    component_checks.has_side_effects = true;
    const component_step = b.step(
        "check-components",
        "Check actual data-only linker admission and composition",
    );
    component_step.dependOn(&component_checks.step);
    const package = b.addRunArtifact(helper);
    package.addArg("check-package");
    package.addFileArg2(.zig_exe, .{ .make_absolute = true });
    package.addDirectoryArg2(b.path("."), .{ .make_absolute = true });
    _ = package.addOutputDirectoryArg2("package", .{});
    package.has_side_effects = true;
    b.step(
        "check-package",
        "Build a clean public source package through Zig",
    ).dependOn(&package.step);
    return component_step;
}

const AuthoringChecks = struct { step: *std.Build.Step, run: *std.Build.Step.Run };

fn authoringChecks(
    b: *std.Build,
    data: *std.Build.Module,
    static_authoring: *std.Build.Step,
    optimize: std.lang.Optimize,
) AuthoringChecks {
    const authoring = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    }) });
    // Both complete test roots already include the component cases. Share their
    // runners instead of compiling and executing two subset-only test binaries.
    const run_authoring_tests = b.addRunArtifact(authoring);
    run_authoring_tests.has_side_effects = true;

    const authoring_step = b.step(
        "check-authoring",
        "Check typed construction, ownership and optimization",
    );
    authoring_step.dependOn(&run_authoring_tests.step);
    authoring_step.dependOn(static_authoring);
    return .{ .step = authoring_step, .run = run_authoring_tests };
}

fn compactEmitter(
    b: *std.Build,
    horos: *std.Build.Module,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    const compact_emit = b.addExecutable(
        .{
            .name = "emit-compact-fixture",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/v2/emit_compact.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "horos", .module = horos }},
                },
            ),
        },
    );
    return compact_emit;
}

fn compactProbe(b: *std.Build) *std.Build.Step.Compile {
    const compact_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const compact_wasm_data = b.createModule(.{
        .root_source_file = b.path("src/data/root.zig"),
        .target = compact_target,
        .optimize = .small,
    });
    const compact_wasm = b.addExecutable(
        .{
            .name = "compact-codec-probe",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/v2/compact_wasm.zig"),
                    .target = compact_target,
                    .optimize = .small,
                    .imports = &.{.{ .name = "horos_data", .module = compact_wasm_data }},
                },
            ),
        },
    );
    compact_wasm.entry = .disabled;
    compact_wasm.rdynamic = true;
    compact_wasm.export_memory = true;
    compact_wasm.stack_size = 65536;
    return compact_wasm;
}

const WasmChecks = struct {
    program: *std.Build.Step,
    state: *std.Build.Step,
    invocation: *std.Build.Step,
};

fn wasmChecks(
    b: *std.Build,
    compact_wasm: *std.Build.Step.Compile,
    compact_emit: *std.Build.Step.Compile,
) WasmChecks {
    const program_wasm_run = b.addSystemCommand(&.{"node"});
    program_wasm_run.addFileArg2(b.path("test/v2/program_wasm.mjs"), .{});
    program_wasm_run.addFileArg2(compact_wasm.getEmittedBin(), .{});
    program_wasm_run.addFileArg2(compact_emit.getEmittedBin(), .{});
    b.step("check-program-image-wasm", "Compare BPI3 native and wasm32 bytes and identity")
        .dependOn(&program_wasm_run.step);
    const state_wasm_run = b.addSystemCommand(&.{"node"});
    state_wasm_run.addFileArg2(b.path("test/v2/state_wasm.mjs"), .{});
    state_wasm_run.addFileArg2(compact_wasm.getEmittedBin(), .{});
    b.step("check-state-image-wasm", "Check PST3 canonical graph bytes on wasm32")
        .dependOn(&state_wasm_run.step);
    const invocation_wasm_run = b.addSystemCommand(&.{"node"});
    invocation_wasm_run.addFileArg2(b.path("test/v2/invocation_wasm.mjs"), .{});
    invocation_wasm_run.addFileArg2(compact_wasm.getEmittedBin(), .{});
    b.step("check-invocation-wasm", "Check current envelope bytes and request identity on wasm32")
        .dependOn(&invocation_wasm_run.step);
    return .{
        .program = &program_wasm_run.step,
        .state = &state_wasm_run.step,
        .invocation = &invocation_wasm_run.step,
    };
}

fn semanticsChecks(
    b: *std.Build,
    data: *std.Build.Module,
    horos: *std.Build.Module,
    run_authoring_tests: *std.Build.Step.Run,
    optimize: std.lang.Optimize,
) *std.Build.Step {
    const authoring_cases = b.addExecutable(
        .{
            .name = "authoring-cases",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/authoring_cases.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "horos_data", .module = data }},
                },
            ),
        },
    );
    const source_fixtures = b.step(
        "emit-examples",
        "Emit higher-order source examples and BPI3 images",
    );
    const oracle = b.addSystemCommand(&.{"node"});
    oracle.addFileArg2(b.path("test/v2/source_oracle.mjs"), .{});
    const source_emitter = b.addExecutable(
        .{
            .name = "source-example",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/v2/emit_source.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "horos", .module = horos }},
                },
            ),
        },
    );
    const portable_baseline = b.step(
        "check-authoring-bytes",
        "Compare all 42 source images against the pre-migration baseline",
    );
    baselineFixtures(b, source_emitter, source_fixtures, oracle, portable_baseline);
    const interaction_traces = interactionFixtures(b, source_emitter, source_fixtures, oracle);
    oracle.has_side_effects = true;
    const semantics = b.step(
        "check-semantics",
        "Check higher-order source semantics without Kosmos",
    );
    semantics.dependOn(&oracle.step);
    semantics.dependOn(&interaction_traces.step);
    semantics.dependOn(portable_baseline);
    semantics.dependOn(&oracleScopeChecks(b, horos, optimize, authoring_cases).step);
    semantics.dependOn(&borrowReturnChecks(b, horos, optimize).step);
    semantics.dependOn(&run_authoring_tests.step);
    const exact_json = b.addSystemCommand(&.{ "node", "--test" });
    exact_json.addFileArg2(b.path("test/v2/exact_json.test.mjs"), .{});
    semantics.dependOn(&exact_json.step);

    return semantics;
}

fn baselineFixtures(
    b: *std.Build,
    source_emitter: *std.Build.Step.Compile,
    source_fixtures: *std.Build.Step,
    oracle: *std.Build.Step.Run,
    portable_baseline: *std.Build.Step,
) void {
    inline for (
        source_examples,
        0..,
    ) |name, index| {
        for ([_][]const u8{ "json", "bpi3" }) |format| {
            const run = b.addRunArtifact(source_emitter);
            run.addArgs(&.{ b.fmt("{d}", .{index}), format });
            const file = run.captureStdOut(.{});
            source_fixtures.dependOn(&b.addInstallFileWithDir(
                file,
                .prefix,
                b.fmt("source-{s}.{s}", .{ name, format }),
            ).step);
            if (std.mem.eql(u8, format, "json")) {
                oracle.addFileArg2(file, .{});
            } else {
                const checked = b.addCheckFile(
                    file,
                    .{
                        .expected_exact = @embedFile(
                            "test/authoring-baseline/source-" ++ name ++ ".bpi3",
                        ),
                    },
                );
                checked.setName("baseline BPI3: " ++ name);
                portable_baseline.dependOn(&checked.step);
            }
        }
    }
}

fn interactionFixtures(
    b: *std.Build,
    source_emitter: *std.Build.Step.Compile,
    source_fixtures: *std.Build.Step,
    oracle: *std.Build.Step.Run,
) *std.Build.Step.Run {
    const interaction_traces = b.addSystemCommand(&.{"node"});
    interaction_traces.addFileArg2(b.path("test/v2/service_interactions.mjs"), .{});
    inline for (
        .{
            "local-one-shot",
            "local-multi-shot",
            "stateful-service",
            "swapped-service-replies",
            "paired-services",
        },
        42..,
    ) |name, index| {
        for ([_][]const u8{ "json", "bpi3" }) |format| {
            const run = b.addRunArtifact(source_emitter);
            run.addArgs(&.{ b.fmt("{d}", .{index}), format });
            const file = run.captureStdOut(.{});
            source_fixtures.dependOn(&b.addInstallFileWithDir(
                file,
                .prefix,
                b.fmt("source-{s}.{s}", .{ name, format }),
            ).step);
            if (std.mem.eql(u8, format, "json")) {
                oracle.addFileArg2(file, .{});
                if (index == 44 or index == 45) interaction_traces.addFileArg2(file, .{});
            }
        }
        if (index == 44 or index == 45) {
            const analysis = b.addRunArtifact(source_emitter);
            analysis.addArgs(&.{ b.fmt("{d}", .{index}), "analysis" });
            const file = analysis.captureStdOut(.{});
            source_fixtures.dependOn(&b.addInstallFileWithDir(
                file,
                .prefix,
                b.fmt("source-{s}.analysis.json", .{name}),
            ).step);
            interaction_traces.addFileArg2(file, .{});
        }
    }
    return interaction_traces;
}

fn publicExamples(
    b: *std.Build,
    horos: *std.Build.Module,
    native: *std.Build.Step,
    optimize: std.lang.Optimize,
) void {
    const client = b.addExecutable(.{ .name = "authoring-client", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/authoring_client.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    const public_example = b.addRunArtifact(client);
    _ = public_example.captureStdOut(.{});
    native.dependOn(&public_example.step);
    b.step(
        "emit-authoring-client",
        "Emit the public authoring client",
    ).dependOn(&b.addRunArtifact(client).step);
    inline for (.{
        .{ "one_effect", "emit-one-effect" },
        .{ "structured_branch", "emit-structured-branch" },
    }) |entry| {
        const example = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ entry[0] ++ ".zig"),
                .target = b.graph.host,
                .optimize = optimize,
                .imports = &.{.{ .name = "horos", .module = horos }},
            }),
        });
        b.step(
            entry[1],
            "Emit a public typed-authoring example",
        ).dependOn(&b.addRunArtifact(example).step);
    }
}

fn oracleScopeChecks(
    b: *std.Build,
    horos: *std.Build.Module,
    optimize: std.lang.Optimize,
    authoring_cases: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const emitter = b.addExecutable(.{
        .name = "oracle-scopes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/v2/oracle_scopes.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "horos", .module = horos }},
        }),
    });
    const check = b.addSystemCommand(&.{"node"});
    check.addFileArg2(b.path("test/v2/oracle_scopes.mjs"), .{});
    check.addFileArg2(b.addRunArtifact(emitter).captureStdOut(.{}), .{});
    check.addFileArg2(authoring_cases.getEmittedBin(), .{});
    check.has_side_effects = true;
    return check;
}

fn borrowReturnChecks(
    b: *std.Build,
    horos: *std.Build.Module,
    optimize: std.lang.Optimize,
) *std.Build.Step.Run {
    const tests = b.addExecutable(.{
        .name = "borrow-returns",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/v2/borrow_returns.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "horos", .module = horos }},
        }),
    });
    return b.addRunArtifact(tests);
}
