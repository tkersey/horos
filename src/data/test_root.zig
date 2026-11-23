//! Separate pure-data test entry point; never imported by the production module.
test {
    _ = @import("contract_tests.zig");
    _ = @import("expression_reuse_tests.zig");
}
