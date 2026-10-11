const key = @import("cache_key.zig");
const a = @import("../authoring.zig");
const mode = @import("rejection_mode").value;
comptime {
    const Fake = opaque {
        pub const horos_handle = a.Schema(a.Shape(u64)).horos_handle;
    };
    const Unsupported = if (@import("std").mem.eql(u8, mode, "pointer")) *u64 else *const Fake;
    _ = key.KeyOps(struct { identity: Unsupported }, key.DefaultPolicy);
}
