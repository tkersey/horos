//! Shared names only: the private derivation probe consumes canonical bytes.
pub const names = [_][]const u8{
    "recursive",
    "generator",
    "scoped-reader",
    "state-local",
    "state-shared",
    "choices-all",
    "recursive-choice",
    "install-8",
    "install-64",
    "install-128",
};
pub const installations = [_]usize{ 8, 64, 128 };
pub const samples = 11; // First observation is separate from ten warm repetitions.
