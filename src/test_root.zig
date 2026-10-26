//! Separate staged-authoring test entry point.
test {
    _ = @import("source/static_value.zig");
    _ = @import("source/specialize.zig");
    _ = @import("source/specialize_tests.zig");
    _ = @import("source/recovery_tests.zig");
    _ = @import("source/relation_inline.zig");
    _ = @import("source/record_tests.zig");
    _ = @import("source/reference_roles_tests.zig");
    _ = @import("source/reference_roles.zig");
    _ = @import("authoring/cache_key.zig");
    _ = @import("authoring/checked_tests.zig");
    _ = @import("authoring_tests.zig");
    _ = @import("coalescing_tests.zig");
    _ = @import("coalescing_allocation_meter.zig");
    _ = @import("root.zig");
    _ = @import("source/tests.zig");
    _ = @import("source/capture_tests.zig");
    _ = @import("source/diagnostic_origins.zig");
    _ = @import("source/projection_tests.zig");
    _ = @import("source/activation_tests.zig");
    _ = @import("source/thread_jumps.zig");
    _ = @import("source/slot_order.zig");
    _ = @import("source/component_tests.zig");
    _ = @import("source/activation_admission_tests.zig");
}
