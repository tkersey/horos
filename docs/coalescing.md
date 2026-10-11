# Checked whole-program coalescing

Closed compilation and final linking always run P01. Typed/direct compilation,
standalone linking and Protean's compiled-tool path share the same mandatory
checked pipeline. There is no public off/safe selector. Open components defer
whole-program coalescing until closed linking.

P01 shares code and immutable descriptions. Effects, regions and resources keep
their nominal distinctions; entry and authority-sensitive functions stay pinned.
Function-local slot bijections and ordered captures/operands/edges are checked
independently of discovery. Runtime closures, cells, activations, handler
installations and resumptions keep their dynamic identities and custody.

Original admission and named-capture checks run before transformation. A separate
raw-record validator checks correspondence, and the candidate receives fresh
admission. Selection uses the exact encoded size with no growth; legal no-op and
deterministic work-limit rollback retain the original baseline. Observers and
diagnostics do not bypass those checks.

Structural compilation preserves its declared cross-build logical-step relation.
Additional semantic passes require the semantic contract and preserve specified
external behavior. Kosmos always preserves the exact same-image stepping and
interruption contract. A changed image has a changed identity: old checkpoints and
reply envelopes cannot be transplanted. Ordinary codecs retain valid duplicate
records and do not silently optimize images.

Historical comparison runners use separately built predecessor executables through
`BOUNDARY_PREDECESSOR_BIN`; current emitters accept no mode. The 39 frozen Program
images from accepted `6313768` remain independent test inputs. No old compiler or
selector is embedded in the production library.

See the [T01–T42 witness map](https://github.com/tkersey/boundary/blob/codex/canonical-durable-3183/docs/coalescing-acceptance.md) and the
[consolidated acceptance report](https://github.com/tkersey/boundary/blob/codex/canonical-durable-3183/docs/optimization-acceptance.md) for exact subjects,
commands, current and cumulative costs, accepted tradeoffs, failures and limits.
Historical raw reports are available through that report's immutable archive
index rather than shipped in the dependency package.
