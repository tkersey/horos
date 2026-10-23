# Horos authoring migration

Horos 7.0.0 replaces the ordinary raw-ID hyperfunction signatures with the typed
`library.hyper` surface described below. Existing typed authoring, portable
formats and runtime authority remain in place.

Canonical option records now reject unknown fields before runtime lowering.
For example, `return_effect` is an error; use `return_effects`. Helpers passing
superset records must explicitly construct the accepted options for each call.
Callable, handler, collection/fault, Choice, Search, Generator, and nested
capture options follow this rule. User-defined parameter and schema field names
retain their own declaration checks. Option values, including handler mode and
runtime rows, need not be comptime; empty `.{}` records remain supported where
no fields are required. Omitted fields and explicit `null` keep their existing
meanings.

Horos 4.0.0 replaced the ordinary authoring interface. BMO1, BPI3, PST3,
ABI 3 and nominal runtime authority retain their existing contracts.

| Previous construction | Current construction |
|---|---|
| `c.scalar(T)` | `c.schema(T)` |
| `c.record(&.{.{ .name = "x", .schema = integer }})` | `c.record(.{ .x = integer })` |
| `body.call(f, &.{.{ .name = "x", .value = value }})` | `body.call(f, .{ .x = value })` |
| Erased `*const Schema` / `*const Value` annotations | Infer handles, or use `Schema(Shape)` / `Value(Shape)` with the actual retained contract |
| Runtime field/parameter selection | `interop.field` / `interop.parameter` |
| Runtime variant construction | `interop.variant(body, schema, name, payload)` retains the whole sum shape |
| Runtime destructured field selection | `interop.get(parts, name)` returns a checked Dynamic child |
| Runtime name/arity slices | Context-owned `interop.RuntimeNamed` collections |
| `schema.fields()[i].schema` | `try schema.fields()` with named typed children, or `interop.fields` for runtime inspection |
| A slice of finished cases | A named struct of finished cases |
| Sequence `append(left, item)` | `append(left, item, .{})` |
| Raw literal adoption | `interop.encodedLiteral(c, schema, bytes)` |
| Raw-ID failure assertion | `interop.literalFailure(c, checked_literal)` |
| Known external operation integration | `interop.externalOperation(c, id, payload, result)` |
| `declareSchema(kind)` | `declareSchema(kind, known_shape)` or explicit `Dynamic` |

Static mismatches now fail at Zig compilation: wrong nested shapes, missing or
extra fields, unknown names, wrong handle categories, incompatible branches,
bounds or enum tags, unsupported native types, counterfeit handles, and unproved
known recursive declarations. The public package includes compile-rejection
witnesses for these cases. Actual context, scope, named metadata, nominal identity,
mutation lifecycle and portable admission checks still run at authoring time.

Helpers should retain their available input and result shapes. Do not replace
ordinary annotations with `Dynamic`. Use `interop.erase` when an actual runtime
heterogeneous collection or integration boundary requires it; checked refinement
recovers known structure from actual compatible metadata. A struct can retain
known children alongside a Dynamic child. A declaration carrying a known completion
shape cannot be erased: existing aliases rely on that promise. Complete it through
its original typed handle, then erase `declaration.schema()` if needed. Choose
`declareSchema(kind, Dynamic)` when completion names or shapes arrive at runtime.

`externalOperation` checks the environmental operation's actual contracts before
retaining their names. `interop.performSite`
uses the ordinary checked effect producer and also returns its exact source term
for consumers that certify individual environmental sites. `interop.valueId`
accepts a Body for lexical use or a Context for a global encoded literal.

Schema-dependent faults remain explicit. Finite vectors require a capacity
failure for append/concat, unbounded sequences do not. Text and bytes retain their
distinct contracts. Bounds use optional values; absent, zero and finite bounds
must not be collapsed into a numeric sentinel.

Actual runtime handler mode selection returns a tagged typed choice. Switch on
`.deep` or `.shallow` before authoring its mode-dependent interfaces. Deep answers,
shallow successor behavior and multi-shot continuation reuse retain their existing
meaning. State's runtime answer policy also returns a tagged choice.
Optional `resumption_slots` retain their runtime policy: null requests automatic
declarations, while a supplied list (including an empty list) is checked against
the handled operations.

## Typed hyperfunctions

The public `hyper_authoring` adapter is retired. `library.hyper` now directly
accepts canonical authoring schemas, bodies, values and functions. Its ordinary
operations preserve endpoint, delayed-result and state shapes; they no longer
accept raw Builder IDs or return raw terms. There is no parallel raw facade.

| Previous hyper construction | Typed construction |
|---|---|
| `pairWith(builder, a, b, captures)` | `pair(context, a, b, .{ .captures = captures })` |
| Pair schema ID fields | Opaque pair accessors such as `forward()` and `answerForward()` |
| Positional endpoint group and numeric selection | `group(context, .{ .input = a, .output = b }, options)` and `get("input", "output")` |
| Raw transform function ID | Ordinary typed Function with `.{ .argument = delayed_a }`, returning `delayed_b` |
| `ana(builder, pair, state, StepType)` | `ana(body, pair, state_schema, Step{ ... })` |
| `query.state` and a strict successor in `query.ask` | `query.state()` and `query.ask(body, delayed_successor)` |
| Binding raw invocation terms | Typed values returned by `invoke`, `start`, `force` and ordinary body calls |
| Executing a task with `force` | Force its pure description, then `body.apply(task, .{})` |

Create a pure successor delay before the pair when it belongs in that pair's
capture bound. Put successor computation inside the delay; `deferValue` only
wraps an already-produced value. Retain each `Ana` definition to reuse its emitted
code, and pass actual emitter instances when authoring distinct configurations.
Task promises use `declareSchema(.callable, Task)` before the pair, followed by
`defineCallable` with the actual effects and reciprocal peer captures.

Runtime endpoint selection uses `hyper.ir.from`, `to` or `select`; only unknown
sides become `Dynamic`. Component integrations use checked
`authoring.interop.importFunction` for raw undefined function declarations and
`componentModule` for publication with explicit imported functions. Raw IDs stay
at those component, registry and deliberate malformed-fixture boundaries.

See [recursive interaction](recursive-interaction.md) for operation signatures,
Need interpretation and the shared group capture contract.

## Coordinated dependency qualification

The implementation series migrates Horos, Kosmos and Protean together. Qualify
Horos first, then Kosmos against that committed Horos package, then Protean against
the selected Horos and Kosmos. Record exact revisions and authenticated source,
archive, package and API-file identities in the consuming locks and the final
qualification report. A stable version number alone does not qualify an
untested downstream tuple.

Rollback restores the entire previously qualified dependency/artifact tuple;
a package pin, source inventory and kernel binding from different candidates do
not form a supported rollback.

See [the authoring guide](typed-authoring.md) for current construction patterns.

## Admission measurements (Horos 5)

`zig build bench-admission -Doptimize=safe` writes
`zig-out/admission-compile.jsonl` and `zig-out/admission-derive.jsonl`.
The optional target is separate from correctness checks. It uses the ordinary
structural compiler, canonical image admission, and the private control owner;
it neither changes optimization policy nor exports another analysis API.

The measured core is `f04359ca8b958a07d1bcc14748e35adfacd3ffed`, with the
benchmark sources in this revision. On Apple M2 Pro, macOS 27.2 (26B5101f),
Zig 0.17.0, `safe`, these are medians of ten repetitions after the first
observation. Each repetition constructs fresh owners; this is not a cached
admission benchmark. Builders, image encoding, file I/O, output formatting and
owner destruction are outside the timed operations. The compilation and private
derivation executables run sequentially. All seven named semantic examples
retain their frozen BPI3 bytes; every repetition checks its image identity.

| Fixture | Compile µs | Admit µs | Derive µs | Derivation arena bytes, maximum | Admitted owner bytes |
|---|---:|---:|---:|---:|---:|
| recursive | 44.5 | 9.2 | 0.1 | 760 | 9396 |
| generator | 292.2 | 74.1 | 34.2 | 94092 | 35054 |
| scoped-reader | 1587.4 | 216.9 | 55.6 | 97520 | 32046 |
| state-local | 419.8 | 62.7 | 31.8 | 36220 | 30808 |
| state-shared | 385.5 | 56.2 | 26.8 | 33656 | 31048 |
| choices-all | 108.5 | 23.5 | 11.8 | 30564 | 11108 |
| recursive-choice | 1573.9 | 290.4 | 179.1 | 211448 | 65106 |
| install-8 | 193.9 | 59.4 | 30.3 | 41616 | 30720 |
| install-64 | 1532.9 | 441.1 | 292.0 | 678328 | 94980 |
| install-128 | 3212.4 | 927.8 | 642.6 | 1112992 | 152144 |

The existing allocation meter forwards allocation, resize, remap and free to the
process allocator. Counts are requested live bytes, not RSS or allocator metadata.
The derivation column includes arena backing and intermediate dataflow storage
retained until the invocation ends, not just a minimal set of resulting facts.
Admission's temporary control derivation is released before the admitted-owner
measurement. The small recursive example has no handlers; `recursive-choice`
measures the existing recursive depth-first Queens/Choice example as well.

Raw JSONL retains the first observation, all individual times, image hashes,
peak and retained allocations, and admitted storage estimates. Every measured
owner must release all of its allocations. Small operations and process-allocator
reuse are sensitive to clock resolution, power state and concurrent load. These
are local cost observations, not a baseline-relative speedup or a timing gate.
