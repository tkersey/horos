const std = @import("std");
pub fn build(b: *std.Build) void {
    const dependency = b.dependency("horos", .{ .optimize = .safe });
    const horos = dependency.module("horos");
    const pure = b.dependency("horos", .{ .@"data-only" = true });
    const pure_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("data.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "horos_data", .module = pure.module("horos_data") }},
    }) });
    b.step(
        "data",
        "Check isolated data-only dependency",
    ).dependOn(&b.addRunArtifact(pure_test).step);
    const client = b.addExecutable(.{ .name = "client", .root_module = b.createModule(.{
        .root_source_file = b.path("client.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    b.step("emit", "Emit public-package client").dependOn(&b.addRunArtifact(client).step);
    const hyper = b.addExecutable(.{ .name = "hyper-client", .root_module = b.createModule(.{
        .root_source_file = b.path("hyper_client.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    b.step("hyper", "Emit typed hyperfunction package client")
        .dependOn(&b.addRunArtifact(hyper).step);
    const rejection = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("rejection.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }), .use_llvm = true });
    b.step(
        "reject",
        "Check rejected public-package neighbor",
    ).dependOn(&b.addRunArtifact(rejection).step);
    const static = b.step(
        "comptime-reject",
        "Reject incompatible shapes through the public package",
    );
    staticCases(b, horos, static, "static.zig", @import("static_cases.zig").cases);
    staticCases(b, horos, static, "hyper_static.zig", @import("hyper_static_cases.zig").cases);
    inline for (.{ "category", "failure_literal_category", "lifecycle" }) |mode| {
        if (b.option(bool, mode, "Build a deliberate public API error") orelse false) {
            const wrong = b.addExecutable(.{ .name = mode, .root_module = b.createModule(.{
                .root_source_file = b.path(mode ++ ".zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "horos", .module = horos }},
            }) });
            b.getInstallStep().dependOn(&b.addInstallArtifact(wrong, .{}).step);
        }
    }
}

fn staticCases(
    b: *std.Build,
    horos: *std.Build.Module,
    step: *std.Build.Step,
    comptime path: []const u8,
    comptime cases: anytype,
) void {
    inline for (cases) |case| {
        const options = b.addOptions();
        options.addOption([]const u8, "value", case[0]);
        const wrong = b.addExecutable(.{ .name = case[0], .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
            .imports = &.{.{ .name = "horos", .module = horos }},
        }) });
        wrong.root_module.addOptions("rejection_mode", options);
        wrong.expect_errors = .{ .contains = case[1] };
        step.dependOn(&wrong.step);
    }
}
