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
    const rejection = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("rejection.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "horos", .module = horos }},
    }) });
    b.step(
        "reject",
        "Check rejected public-package neighbor",
    ).dependOn(&b.addRunArtifact(rejection).step);
    const static = b.step(
        "comptime-reject",
        "Reject incompatible shapes through the public package",
    );
    inline for (@import("static_cases.zig").cases) |case| {
        const options = b.addOptions();
        options.addOption([]const u8, "value", case[0]);
        const wrong = b.addExecutable(.{ .name = case[0], .root_module = b.createModule(.{
            .root_source_file = b.path("static.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "horos", .module = horos }},
        }) });
        wrong.root_module.addOptions("rejection_mode", options);
        wrong.expect_errors = .{ .contains = case[1] };
        static.dependOn(&wrong.step);
    }
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
