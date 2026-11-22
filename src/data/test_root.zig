//! Complete pure-data test entry point.
test {
    _ = @import("contract_tests.zig");
    _ = @import("expression_reuse_tests.zig");
}
