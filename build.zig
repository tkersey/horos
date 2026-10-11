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
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/data/test_root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const data_step = b.step("check-data", "Check canonical records and pure admission");
    const run_data_tests = b.addRunArtifact(tests);
    data_step.dependOn(&run_data_tests.step);
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
    b.step("build-compiler", "Build the source-independent BMO1 linker").dependOn(&installed_linker.step);
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
    const component_step = b.step("check-components", "Check actual data-only linker admission and composition");
    component_step.dependOn(&component_checks.step);
    const package = b.addRunArtifact(helper);
    package.addArg("check-package");
    package.addFileArg2(.zig_exe, .{ .make_absolute = true });
    package.addDirectoryArg2(b.path("."), .{ .make_absolute = true });
    _ = package.addOutputDirectoryArg2("package", .{});
    package.has_side_effects = true;
    b.step("check-package", "Build a clean public source package through Zig").dependOn(&package.step);
    const authoring = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    }) });
    // Both complete test roots already include the component cases. Share their
    // runners instead of compiling and executing two subset-only test binaries.
    const run_authoring_tests = b.addRunArtifact(authoring);

    b.step("check-authoring", "Check typed construction, ownership and optimization").dependOn(&run_authoring_tests.step);
    const native = b.step("check-native", "Check native authoring, data and linker contracts without an interpreter");
    native.dependOn(data_step);
    native.dependOn(&run_authoring_tests.step);
    native.dependOn(component_step);
    const compact_emit = b.addExecutable(.{ .name = "emit-compact-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/emit_compact.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    const compact_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const compact_wasm_data = b.createModule(.{
        .root_source_file = b.path("src/data/root.zig"),
        .target = compact_target,
        .optimize = .small,
    });
    const compact_wasm = b.addExecutable(.{ .name = "compact-codec-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/compact_wasm.zig"),
        .target = compact_target,
        .optimize = .small,
        .imports = &.{.{ .name = "horos_data", .module = compact_wasm_data }},
    }) });
    compact_wasm.entry = .disabled;
    compact_wasm.rdynamic = true;
    compact_wasm.export_memory = true;
    compact_wasm.stack_size = 65536;
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
    const authoring_cases = b.addExecutable(.{ .name = "authoring-cases", .root_module = b.createModule(.{
        .root_source_file = b.path("src/authoring_cases.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    }) });
    const source_fixtures = b.step("emit-examples", "Emit higher-order source examples and BPI3 images");
    const oracle = b.addSystemCommand(&.{"node"});
    oracle.addFileArg2(b.path("test/v2/source_oracle.mjs"), .{});
    const source_emitter = b.addExecutable(.{ .name = "source-example", .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/emit_source.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    for ([_][]const u8{ "lexical", "deep", "recursive", "choices-all", "choices-first", "generator", "state-local", "state-shared", "resource-scalar", "resource-pair", "answers", "scoped-reader", "writer-raise", "scheduler", "queens-dfs", "queens-bfs", "cell-order", "nested", "shallow", "injection", "indexed", "abort-custody", "unwind", "reentrant", "cloned", "clause-abort", "bounded-values", "scalar-contracts", "ownership", "shallow-resumptions", "shallow-injection", "handle-operand-order", "protect-operand-order", "successor-state", "clause-payload", "yielding-cleanup", "borrow-operands", "cleanup-disposal", "cleanup-disposal-running", "cleanup-disposal-failure", "cleanup-disposal-owned", "product-projection" }, 0..) |name, index| {
        for ([_][]const u8{ "json", "bpi3" }) |format| {
            const run = b.addRunArtifact(source_emitter);
            run.addArgs(&.{ b.fmt("{d}", .{index}), format });
            const file = run.captureStdOut(.{});
            source_fixtures.dependOn(&b.addInstallFileWithDir(file, .prefix, b.fmt("source-{s}.{s}", .{ name, format })).step);
            if (std.mem.eql(u8, format, "json")) oracle.addFileArg2(file, .{});
        }
    }
    oracle.has_side_effects = true;
    const semantics = b.step("check-semantics", "Check higher-order source semantics without Kosmos");
    semantics.dependOn(&oracle.step);
    semantics.dependOn(&oracleScopeChecks(b, horos, optimize, authoring_cases).step);
    semantics.dependOn(&borrowReturnChecks(b, horos, optimize).step);
    semantics.dependOn(&run_authoring_tests.step);
    const exact_json = b.addSystemCommand(&.{ "node", "--test" });
    exact_json.addFileArg2(b.path("test/v2/exact_json.test.mjs"), .{});
    semantics.dependOn(&exact_json.step);

    const aggregate = b.step("check", "Check native contracts and independent source/wasm observations");
    aggregate.dependOn(native);
    aggregate.dependOn(semantics);
    aggregate.dependOn(&program_wasm_run.step);
    aggregate.dependOn(&state_wasm_run.step);
    aggregate.dependOn(&invocation_wasm_run.step);
    const client = b.addExecutable(.{ .name = "authoring-client", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/authoring_client.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    const public_example = b.addRunArtifact(client);
    _ = public_example.captureStdOut(.{});
    native.dependOn(&public_example.step);
    b.step("emit-authoring-client", "Emit the public authoring client").dependOn(&b.addRunArtifact(client).step);
    inline for (.{ .{ "one_effect", "emit-one-effect" }, .{ "structured_branch", "emit-structured-branch" } }) |entry| {
        const example = b.addExecutable(.{ .name = entry[0], .root_module = b.createModule(.{ .root_source_file = b.path("examples/" ++ entry[0] ++ ".zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{.{ .name = "horos", .module = horos }} }) });
        b.step(entry[1], "Emit a public typed-authoring example").dependOn(&b.addRunArtifact(example).step);
    }
    b.default_step = aggregate;
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
