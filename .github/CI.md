# Qualification

Source syntax/formatting, the tracked Zig source inventory and the
[TigerStyle gate](../docs/tiger-style.md) are checked before
compilation. The source job checks out the actual proposed head with its history,
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

Rerun only the affected check after a change. Results apply to their actual
candidate and selected inputs; prior release qualification is not new-head proof.
