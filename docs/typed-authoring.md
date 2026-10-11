# Typed, structured authoring

Import `horos.authoring`. It stages ordinary Horos source; the existing
source checker, lowering, target admission and unchanged Kosmos interpreter remain
authoritative. `horos.source` is the single low-level IR interface for source
inspection, negative fixtures, component construction and internal generation.
The duplicate `horos.computation` export is removed. Ordinary construction
uses the typed frontend; IR access does not select another compiler or checker.

Handlers may declare `return_effects` separately from their residual row. Omit it
to retain the full residual allowance, or use `&.{}` for a pure return arm while
the operation clause still performs residual effects. Authoritative source
admission rejects a return body that exceeds its declared row.
`clause_effects` similarly narrows the operation clause's row, without changing
the effects of its captured resumption. A clause that only packages a suspension
can therefore be pure while later resumption performs residual effects.

Use `Context.suspensionPackage` for its typed schema and `Body.package` /
`Body.unpack` to move a resumption into or out of an owned suspension package.
These emit the existing source operations. Their named schema metadata is retained;
ordinary source admission still rejects repeated consumption and invalid custody.

`Body.destructure(product)` consumes a product and returns named parts accessed
with `parts.get(name)`. It is distinct from borrowing field projections: owned
suspensions can move through the parts, and source admission rejects consuming
the original product or an owned part twice. Parts retain their lexical scope.
`Body.pop(sequence)` returns `empty` or `item`, whose product has `head` and `tail`;
`append` and `equal` complete ordinary forward sequence-search construction.

Construct handlers and regions through `authoring.Context.handler` and
`authoring.Context.region`. The former top-level `horos.handler` and
`horos.region` aliases are removed. Expert record inspection uses
`horos.data.program` types; it does not require those construction facades.

Declare operations with `Context.external`, `local`, or `scoped`. The raw-ID
`horos.effect` facade and its indexed-declaration wrapper are removed. A finite
native collection of typed operation handles retains each operation's result
schema. The independent indexed source-IR fixture keeps its explicit source terms
to test row-polymorphic composition, using checked operation declarations.

## Start here

[`examples/structured_branch.zig`](../examples/structured_branch.zig) is a complete
public example. [`examples/authoring_client.zig`](../examples/authoring_client.zig)
adds a reusable callable, two ordered calls, named records, a derived responder,
residual lookup and checked overflow. Both emit ordinary BPI3:

```sh
zig build emit-structured-branch -Doptimize=safe > branch.bpi3
zig build emit-authoring-client -Doptimize=safe > client.bpi3
```

The canonical route is:

1. Initialize a source `Builder`, then `authoring.Context.init(&builder)`.
2. Declare schemas, external/local operations, and named function interfaces with
   explicit allowed effects. Retain declarations to reuse their code.
3. Open a function body with `body`, or a capturing nested body with `closureBody`.
   Calls, applications, effects, projections and checked arithmetic bind their
   results in forward order. `parameter` and `field` use declared names.
4. Finish with `ret`, then `Context.define`. `Context.compile` checks and lowers
   while retaining source-oriented diagnostics. Alternatively return `module`
   from `Application.emit` and call `horos.program.lower`.
5. Encode the returned owning `Compiled` with `encode`; deinitialize it afterward.
6. Use the separately verified Kosmos package to prepare/start or invoke the image.
   Supply only environmental replies and transfer actual State; host code does
   not reconstruct authored branches, handlers or continuations.

The client takes one Boolean byte followed by a record containing little-endian
u64 `input` and `offset`. False returns their checked sum without a request. True
interprets two local questions as two external `client/lookup` requests carrying
`input`, then returns `first_reply + offset + second_reply` with checked addition.
Its overflow is an authored unit failure. Replies must bind to the current actual
request, including after restoration.

## Staging and lifetimes

| Zig emitter operation | Generated computation |
|---|---|
| Zig `if` selects code to construct | `conditional` selects runtime work |
| Zig `try` propagates construction/allocation failure | `checkedAdd` emits an authored failure edge |
| Zig `defer` releases native resources | `protect` installs portable cleanup |
| Calling a staging function constructs source | `apply` executes an authored callable in Kosmos |
| `lambda` constructs and binds a callable value | `apply` forces a zero-argument delay when demanded |

No native callback enters the Program. Inspecting schemas or diagnostics does not
force delayed work. Recursive function declarations can be used before definition;
all declarations must be defined before `module` or `compile` publishes a snapshot.
Calls and lambda constructions made before a body is opened are rechecked against
that function's eventual lexical parent at publication. Valid uses in that parent
and forward uses of global functions remain supported; discarded branches do not
contribute pending scope obligations.
Publication also compares the declared named failure layout with executable
arithmetic faults and protected cleanup contracts, including late helper
definitions. Abandoned staging branches do not contribute executable uses.
The recursive adapter retains the existing finite `hyper.ana` construction.

Keep the source builder at a stable address. Contexts, handles, copied names and
source snapshots borrow its arena until `Builder.deinit`. `Context` and `Body` are opaque arena-owned handles; pointer aliases share lifecycle
state. Clients cannot copy, reopen, or retarget staging storage. `Compiled` owns its output independently.
`module` copies the source arrays, so later builder growth cannot stale its slices.

`ret` and `abandon` close a body and its descendants to further authoring. Abandoning
an unused branch is harmless; abandoning a declared function leaves it undefined
and prevents publication. A closure legitimately captures ancestor values while
being authored. The runtime lifetime of those captures is checked independently.
Sibling values and branch-local values cannot escape directly: use `conditional`,
`block` or `match` to produce a parent-scope result.

`Body.fail(result_schema, failure_value)` closes a body with an explicit authored
failure. The result schema lets a failing branch join a returning branch.
The failure value keeps its lexical scope and named schema; module publication
checks it against the declared failure contract. Discarded staging branches do
not introduce executable failures. Protected cleanup follows the same runtime
failure semantics, including when a failing clause still owns a continuation.

Construction errors, including allocation and named-argument validation failures,
may poison the context. After an error, retain its diagnostic, discard the context
and tear down its source builder; general transactional recovery is not promised. No successful checked
module is returned from a failed operation. Diagnostic handles remain valid until
that builder is destroyed; `renderAlloc` returns caller-owned text.

## Declarations and guarantees

`Schema`, `Operation`, `Function`, `Value`, `FailureLiteral`, `Computation`, `Handler` and `Region`
are distinct opaque handle categories. Zig rejects category substitution. Runtime
checks reject foreign contexts, out-of-scope values, incompatible named layouts,
arguments, branch results and capability instances. Final source/target admission
still owns effect allowances, affine/linear use, capture safety and borrowed-region
escape. In particular, one-shot use in mutually exclusive arms is allowed; two
sequential uses are rejected. Lambda and aggregate construction bind once rather than silently
creating a fresh one-shot value at each use.

`checked` supports add, subtract, multiply, divide and remainder with opaque
`FailureLiteral` handles constructed once with `c.literalFailure(T, item)`. Ordinary
`Value` handles cannot substitute for this category. The constructor establishes
literal status; arithmetic checks origin and publication checks the failure schema. Overflow is explicit; division and remainder additionally require
an explicit zero-divisor failure. `checkedAdd` is the short addition spelling.
The operand schemas determine the result; no expression is evaluated in the host.

`scalar(T)` supports the existing portable scalar subset (void, bool and supported
fixed-width integers). `record` and `alternatives` accept dynamically selected
named fields. `sequence` describes homogeneous sequences. `product`, `field`,
`variant`, `caseOf` and `match` preserve these names and schemas. `Schema.fields`
and `describe` inspect the metadata. This is not a serializer for arbitrary Zig
pointers or recursive native structures; unsupported `scalar` types fail clearly.

Compatibility compares builder origin, raw schema identity and the complete named
metadata graph, including callable and resumption capture bounds. Memoized schema
pairs handle sharing and recursion without
repeated unfolding; allocation identity is only a fast path. Names are compared
within declarations; equal raw product shapes do not make
incompatible named layouts interchangeable. Operation identity is nominal: two
`local` calls with identical display names create distinct capabilities.
`external` explicitly permits environmental performance; `local` requires the
matching capability. `scoped` additionally declares named authored body operands.

`callable` fixes named parameters, result, allowed effects, use, capture allowance
and regions. `functionFor` derives a declaration from that interface. `lambda`
checks the function's complete declared interface. Actual lexical captures and
values retained across effects are compared with named capture bounds using the
existing compiler's capture and liveness observations. Ownership, borrowing and
multiplicity remain checked by the unchanged admission rules. A value used only
before suspension does not become a continuation capture. Reusing a returned function emits calls without rebuilding its
body. Staging configurations are values, not a cache keyed only by Zig type.

## Interpretation, ownership and diagnostics

`handler` derives the operation payload, capability, clause signature and
resumption input. Intentional choices remain explicit: deep/shallow mode, body
input and interpretation answer, resumption use, body use (`body_use`), residual effects, continuation
captures, body captures, handler state and owned/borrowed regions.
`obligations` defaults to `false`; set it to `true` when a local resumption may
capture a pending protected cleanup. This carries the existing source/data bound,
including through `responder`; it does not change effects, regions or resumption
use. Independent admission still rejects invalid combinations and captures.

Use `returnFunction`, `clauseFunction` and `handledSchema` to author its pieces.
Return functions expose `result`; clauses expose `payload`, named state and scoped
bodies, and `resumption`. `resumeValue` continues and returns for postprocessing.
`resumeWith` installs a successor for a shallow resumption. Deep resumptions return
the interpretation answer; shallow resumptions return the handled body's input
schema. For shallow work, explicitly allow effects that its resumed body can use;
`escaping` names effects that can select outside attachments (such as residual
external lookups). The authoritative checker validates this allowance.

`responder` derives the ordinary resume clause from an authored function. Its
residual effects remain explicit. Body capture and continuation capture bounds are
separate: allowing a capability in a continuation does not silently grant a body
permission to capture an outside instance. Nothing widens an effect/capture/use
allowance to make admission pass. Capture applicability follows the existing
admission rule: every declared handler sharing an effect instance contributes its
continuation capture bound, including unused handler declarations. A successful
raw check after names have been erased does not make incompatible named bounds
interchangeable.

`protect` keeps local cleanup inside the Program across suspension. `dispose`
expresses local owned-resumption disposal; it does not cancel the enclosing
session. `regionBodySchema` derives the implicit region-token parameter and
contract; `withRegion` supplies that token and takes only the remaining named
arguments. `region` and these contracts retain nominal region boundaries. Existing low-level resource/loan constructions remain supported.

`Context.lastDiagnostic()` contains a stable error category, entity, failed relationship,
and expected/actual schema handles when available. `render` and `renderAlloc`
render that same information. `Context.compile` also retains the authoritative
source/target diagnostic for failed effects, captures, borrows, uses and answers.
Diagnostic function labels are not emitted and do not change executable bytes.
Errors explain the relationship rather than recommend widening permissions.

`authoring.interop` is the deliberate advanced boundary for existing source
libraries. Its caller promises that raw IDs come from the supplied source builder;
it checks available bounds, categories and schema relationships. Erased numeric
provenance cannot be reconstructed. Imported positional schemas use positional
names unless the adapter supplies checked names. Scoped operation imports retain
their body schemas and expose those operands under positional names. `cleanupInfo`
retains the supplied typed failure layout in both the primary-failure alternative
and the cleanup-failures sequence; it does not erase known names through import. Ordinary covered clients need
neither these adapters nor mutable source catalogs. Finish low-level recursive
schema definitions before adoption, and keep adopted declarations stable afterward;
appending independent declarations is supported. Raw catalog mutation is outside
the checked handle contract.

## Migrated constructions

The migrated source consumers retain their existing behavior:
`one_effect`, `Context.twice`, choice family/first/all/allScoped, and
`hyper_demand`. The hyper bridge handles recursive interface setup and existing
library calls; the example retains its own demands, runtime branch, checked
additions, delayed descriptors and reciprocal startup. Two Need instances remain
nominally distinct despite identical display strings.

`Context.twice` shares its complete definition for repeated use of the same
checked callable in one context. Its key preserves named result layouts and
effect identities; it does not identify schemas solely by their raw record ID.
The former raw-ID combinator wrapper has been removed.

Before, `twice` allocated destination variables, built references, and nested two
binds backward. Its implementation now expresses:

```zig
const first = try forward.apply(callable_value, &.{});
const second = try forward.apply(callable_value, &.{});
const result = try forward.product(pair, &.{
    .{ .name = "first", .value = first },
    .{ .name = "second", .value = second },
});
try self.define(function_handle, try forward.ret(result));
```

Choice formerly repeated payload, result, answer, capability and clause ordinal
relationships in schema/function/handler records. It now declares the operation
and explicit handler policy once, obtains named clause inputs, resumes each branch
and concatenates the results. Multi-shot use, answer transformation, captures and
region allowances remain intentional decisions.

## Verification

`zig build check-native -Doptimize=safe` checks the shared authoring/data roots,
actual data-only linker and public authoring client without Node or Python.
`zig build check-package -Doptimize=safe` checks committed HEAD as a clean Zig
package in an unrelated consumer, including data-only import and nominal-category,
foreign-owner and lifecycle rejection. Its native driver is shared with component
CLI checks; it requires a clean committed candidate.

`zig build check -Doptimize=safe` additionally runs the independent source oracle
and small wasm32 byte/identity checks. Kosmos owns the comparison between
source meaning and actual native/WASM evaluation.

Historical paired timing, platform, search and experimental application campaigns
and their wrappers are retired. Core language, optimizer, ownership, borrow and
wire behavior remains implemented and checked by the retained native roots.
