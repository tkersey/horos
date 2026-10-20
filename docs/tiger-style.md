# TigerStyle for Horos

This contract applies to all tracked Zig code, including tests,
examples and build tools. It adapts [TigerBeetle's TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
and the [skills-zig implementation](https://github.com/tkersey/skills-zig/blob/d91552e788863ab43306164001c35ae99d2fbf53/docs/engineering/TIGER_STYLE.md).
The priorities are safety, performance and developer experience, in that order.

## Design and ownership

Establish the valid inputs, rejected inputs, owner, permitted transitions and
failure behavior before choosing a representation. Make trusted states require
checked admission, and preserve their invariants through every public operation.
Keep source authoring, compilation, portable data admission and external effects
at their existing boundaries. Horos has no production evaluator.

Pass allocators and I/O capabilities explicitly. Returned owners must remain
valid after their source storage is released. Keep borrows within their actual
storage lifetime; a growable collection's element pointer is not stable storage.
Use checked arithmetic and preserve ownership on allocation failure and partial
construction. Expected malformed input, exhausted resources and I/O failures are
returned errors. Assertions express internal invariants, never input validation
that disappears when runtime safety is disabled.

Use explicitly sized integers for portable IDs, protocol fields and serialized
counts. `usize` remains appropriate for in-memory indexes and allocator APIs.
Preserve canonical bytes and the supported input domain when changing an
internal representation. Avoid acquiring a global capability that the caller
already supplies.

## Work and allocation

Give native traversals an explicit progress argument over the admitted source
and bound temporary storage by that source or an existing caller-selected
budget. Prefer checked worklists to native call-stack recursion on input graphs.
Recursive authored programs, recursive schemas and mutually retaining handler
declarations remain supported; these are program data, not permission for an
unbounded native traversal.

Allocation after initialization is supported. Its owner, lifetime, growth and
failure behavior must be explicit. Do not add a universal input-size or allocation
cap to satisfy this policy. Preserve existing checked representation limits,
caller budgets and allocator failures. Name units and qualifiers last, such as
`output_bytes_max`, and check dependent limits together.

An intentional native event loop needs the auditor's same-line
`// tiger: event-loop` directive and a justification in the change's review
description identifying its external control and per-iteration work. This is a
machine directive, not a general exemption from bounds or error handling.

## Structure and performance

Use precise names, small scopes and one owner for each state transition. Keep
functions and test blocks within 70 physical lines and ordinary Zig lines within
100 columns. Zig multiline-string data is exempt from the column limit. Factor
according to the domain's responsibilities; preserve compile-time contracts and
independent test observations when restructuring.

Generic type factories are compile-time construction. Each nested method is
checked independently; its declaration is excluded from the enclosing factory's
line count. Explicitly `inline` type-driven expansion must terminate during
compilation and introduces no recursive native call frames. Runtime traversal
of recursive values uses caller-owned scratch storage and propagates allocation
errors. Recursive specialization knowledge has dedicated copying, comparison,
and encoding operations rather than generic finite-record traversal.

Do not add explanatory source comments, docstrings or optional API comments.
Use names, types and operations to communicate intent. Preserve unrelated
existing comments; mandatory legal notices and required machine directives
remain allowed.

For a new data path, state the expected CPU work and memory growth and preserve
the independent evidence needed to assess them. Measure before adding caches;
identify their key, invalidation and retained storage. Build inputs must remain
tracked so a cached build observes changed source. Prefer the existing native
Zig tools and shared checks over additional tooling dependencies.

## Mechanical gate

`tools/tiger-style.sh` runs the immutable skills-zig native auditor and its tests.
The auditor is a development dependency; it adds no dependency to the Horos
library, compiler, exported package or data-only consumer.

Run from a clean committed checkout with Zig 0.17.0 and Git available:

```sh
bash tools/tiger-style.sh --all HEAD
```

CI audits every tracked Zig file, including unchanged code. Whole-file checks
reject lines over 100 columns, tabs, trailing whitespace, unresolved
`TODO`/`FIXME`/`HACK` comments, discarded errors spelled `catch {}` or
`catch unreachable`, unmarked `while (true)` loops, direct native recursion,
and functions or test blocks longer than 70 lines. Zig's parser establishes
function boundaries, nested declarations, and multiline direct calls; invalid
syntax fails the audit. Tracked Zig symlinks and other nonregular source fail.

The optional `bash tools/tiger-style.sh <base-commit> HEAD` mode audits added
lines in existing files and fully audits new files. It is useful for inspecting
a committed difference; CI requires the whole-source mode. Binary-classified
Zig changes and changed file types fail this difference check.

Mechanical checks cannot establish the absence of indirect recursion, lifetime
errors, invalid error handling, or semantic regressions. Passing them establishes
only this subset. Review still applies the complete contract. The separate
skills-zig repository-mapping audit is not a Horos check.

The auditor bounds diff bytes, file bytes, file count, source lines and diagnostics.
Hitting a bound is a failed check, never a successful truncated audit. Its pin is
updated deliberately with the checker tests and integration checked again.
Run `bash tools/test-tiger-style.sh` after changing the launcher or its pin. Its
temporary Git histories check complete-source selection, inherited violations,
valid changes, added-line/new-file failures, invalid revisions, dirty indexes
and worktrees, binary diffs and nonregular source. CI retains no generated fixtures.

## Verification and review

Keep [.github/CI.md](../.github/CI.md) and the existing qualification roots
authoritative. The source preflight includes the TigerStyle gate. Installation,
native contracts, source-oracle and WASM observations retain their obligations.
The new gate does not replace them.

A change's review explains the affected invariant and owner, required-valid
behavior, invalid cases, resource growth, failure cleanup and compatibility
impact. Use focused positive, negative and boundary observations, including
allocation failure where ownership changes. Reuse the current native test
surfaces; do not accumulate large fixtures or repeat expensive preparation solely
to enlarge a test count. Every required check must finish successfully against
the delivered state before the change is called verified.
