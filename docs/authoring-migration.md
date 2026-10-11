# Horos 4 authoring migration

Horos 4.0.0-dev.0 replaces the ordinary authoring interface. BMO1, BPI3, PST3,
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

The public `hyper_authoring` adapter is retired. Its unchecked raw-value and term
assertions are not part of the new interface. Deliberate `library.hyper` source
construction remains available for its separate IR purpose. There is no old
slice overload or parallel named/typed facade.

## Coordinated dependency qualification

The implementation series migrates Horos, Kosmos and Protean together. Qualify
Horos first, then Kosmos against that committed Horos package, then Protean against
the selected Horos and Kosmos. Record exact revisions and authenticated source,
archive, package and API-file identities in the consuming locks and the final
qualification report. This development revision alone is not a qualification of
an untested downstream tuple.

Rollback restores the entire previously qualified dependency/artifact tuple;
a package pin, source inventory and kernel binding from different candidates do
not form a supported rollback.

See [the authoring guide](typed-authoring.md) for current construction patterns.
