# Qualification

All qualification lanes require exact Zig 0.17.1.

Source syntax/formatting, the tracked Zig source inventory and the
[TigerStyle gate](../docs/tiger-style.md) run alongside compilation; the final
gate requires both to pass. The source job checks out the actual proposed head
with its history,
tests the pinned native auditor and audits every tracked Zig file.
The source preflight retains its five-minute timeout. Three independent
qualification jobs run in parallel, each with a ten-minute timeout: installation,
and the `check` aggregate split into two contracts lanes. `check-semantics`
already runs the authoring test root and the source recovery tests, so the
observations lane also selects `check-authoring`; the native lane selects the
rest of `check-native`. Together the two contracts lanes select exactly the steps
`check` depends on:

```sh
zig build check-package -Doptimize=safe --summary all
zig build check-data check-components check-recovery-optimization \
  -Doptimize=safe --summary all
zig build check-authoring check-semantics check-program-image-wasm \
  check-state-image-wasm check-invocation-wasm -Doptimize=safe --summary all
```

A cold compiler cache made the single contracts job take more than ten minutes.
Splitting it keeps every check while each lane fits its timeout, and the
449-test authoring root, the longest compilation, is compiled in one lane only.

The package check requires a clean committed candidate. One native driver
exports that commit, uses Zig to construct its package, then compiles the public
authoring and data-only APIs in a fresh consumer. Native category/owner/lifecycle
rejections and actual linker CLI behavior remain checked. There is no Node/Python
setup or source/package checker in the native path.

`check-native` is the interpreter-free subset. `check` additionally selects the
independent source oracle and wasm32 ABI byte/identity observations. The oracle
has only its exact-value helper and actual semantic cases; optional historical
experiments and their collectors are removed.

Native relation regressions include source-valid capture mutations, unexplained
edits in composed successors, scalar boundary folds and unused failing arguments.
The source oracle independently expects capture subtraction, strict argument
fault order and delayed/task observations. Shared admission and codecs remain
trusted inputs to these checks. Finite agreement does not establish arbitrary
program equivalence, and an exhausted or interrupted run supplies no passing
evidence.

Downstream comparisons distinguish three contracts: restoration of one guest
image preserves canonical guest state at corresponding cuts; a transformed image
preserves contractual behavior through checked mappings without equating its
image-bound checkpoints; an approved realization switch preserves the same guest
state and revision without requiring the same runtime artifact or pump count.
Host authorization remains a separate condition of a live switch.

Each contracts lane keeps its own compiler cache. Compiler cache retention uses
ordinary CI filesystem operations. Only a complete
regular-file/directory tree containing compiler objects and within four GiB is
saved. Over-budget or unsupported caches are left in place and not uploaded;
local data is never deleted to meet the upload bound. Package qualification owns
fresh caches; a cache hit never establishes source or execution qualification.
Cache upload starts only in the job's first eight minutes and has a
one-minute step limit, reserving time for cleanup and the final gate.
Linux x86-64 build-host programs use a reproducible baseline target, retaining
native execution while avoiding runner-specific CPU and OS target cache inputs.
Extracted-package consumers inherit the exported module target, including Debug
rejection tests. Zig 0.17.0 native x86-64 code generation was observed to emit an aligned
32-byte AVX load from a stack frame aligned only to 16 bytes. The consistent
baseline target avoids that compiler defect without selecting LLVM or changing
the package fixtures, assertions, or optimization modes.

Rerun only the affected check after a change. Results apply to their actual
candidate and selected inputs; prior release qualification is not new-head proof.
