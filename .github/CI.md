# Qualification

Source syntax/formatting, the tracked Zig source inventory and the
[TigerStyle gate](../docs/tiger-style.md) run alongside compilation; the final
gate requires both to pass. The source job checks out the actual proposed head
with its history,
tests the pinned native auditor and audits every tracked Zig file.
The source preflight retains its five-minute timeout. The existing installation
and contracts jobs remain independent and each has a ten-minute timeout:

```sh
zig build check-package -Doptimize=safe --summary all
zig build check -Doptimize=safe --summary all
```

The package check requires a clean committed candidate. One native driver
exports that commit, uses Zig to construct its package, then compiles the public
authoring and data-only APIs in a fresh consumer. Native category/owner/lifecycle
rejections and actual linker CLI behavior remain checked. There is no Node/Python
setup or source/package checker in the native path.

`check-native` is the interpreter-free subset. `check` additionally selects the
independent source oracle and wasm32 ABI byte/identity observations. The oracle
has only its exact-value helper and actual semantic cases; optional historical
experiments and their collectors are removed.

Compiler cache retention uses ordinary CI filesystem operations. Only a complete
regular-file/directory tree containing compiler objects and within four GiB is
saved. Over-budget or unsupported caches are left in place and not uploaded;
local data is never deleted to meet the upload bound. Package qualification owns
fresh caches; a cache hit never establishes source or execution qualification.
Cache upload starts only in the workflow's first eight minutes and has a
one-minute step limit, reserving time for cleanup and the final gate.
Linux x86-64 build-host programs use a reproducible baseline target, retaining
native execution while avoiding runner-specific CPU and OS target cache inputs.
Extracted-package consumers inherit the exported module target, including Debug
rejection tests. Zig 0.17.0 native x86-64 code generation can emit an aligned
32-byte AVX load from a stack frame aligned only to 16 bytes. The consistent
baseline target avoids that compiler defect without selecting LLVM or changing
the package fixtures, assertions, or optimization modes.

Rerun only the affected check after a change. Results apply to their actual
candidate and selected inputs; prior release qualification is not new-head proof.
