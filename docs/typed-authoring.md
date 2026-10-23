# Authoring with retained schema shapes

Import `horos.authoring`. `Context.schema(T)`, named declarations, and body
operations retain known structure in opaque Zig handle types. The shared runtime
core still checks actual schemas, context ownership, scopes, nominal capabilities,
regions and lifecycle. Source compilation and portable admission remain separate
from Kosmos execution.

`horos.source` serves explicit IR inspection, malformed fixtures, components and
compiler integrations. It is not an alternate ordinary authoring tutorial.

## Construct and call a function

```zig
const a = horos.authoring;
const c = try a.Context.init(&builder);
const integer = try c.schema(u64);
const request = try c.schema(struct { input: u64, offset: u64 });
const run = try c.function("run", .{ .request = request }, integer, .{});
const body = try c.body(run);
const argument = try body.parameter("request");
const input = try body.field(argument, "input");
const offset = try body.field(argument, "offset");
const sum = try body.checkedAdd(input, offset, try c.literalFailure(void, {}));
try c.define(run, try body.ret(sum));
```

A call uses `.{ .request = value }`.
Argument order may differ from declaration order. Already-created handles are
packed into declared order; authoring computations are not reordered. Parameters
are materialized when requested.

An explicitly composed record uses the same interface:

```zig
const request = try c.record(.{ .input = integer, .offset = integer });
const supplied = try caller.product(request, .{
    .offset = offset_value,
    .input = input_value,
});
const answer = try caller.call(run, .{ .request = supplied });
```

`input`, `offset`, `sum` and `answer` retain the u64 contract. A Boolean supplied
for a known integer field, a missing or extra argument, an unknown static name,
or the wrong handle category fails Zig compilation. Diagnostics identify the
operation and nested field where the relationship fails.

[`structured_branch.zig`](../examples/structured_branch.zig) and
[`authoring_client.zig`](../examples/authoring_client.zig) are complete clients:

```sh
zig build emit-structured-branch -Doptimize=safe > branch.bpi3
zig build emit-authoring-client -Doptimize=safe > client.bpi3
```

The latter emits two interpreted questions, residual environmental lookups, named
records, branches and checked arithmetic. All that work executes in Kosmos.

## Native contracts and opaque handles

`schema(T)` supports void, bool, 8/16/32/64-bit integers, exhaustive enums with
u32 tags, records, tagged unions, optionals, arrays and unsentinelled slices.
`horos.data.schema.native` owns the shared wrappers:

| Native type | Portable contract |
|---|---|
| `native.Text(null)` / `native.Utf8` | Unbounded UTF-8 text |
| `native.Text(n)` | Text bounded by n bytes |
| `native.Bytes(null)` / `[]const u8` | Unbounded bytes |
| `native.Bytes(n)` | Bytes bounded by n bytes |
| `native.Vector(T, null)` / `[]const T` (T other than u8) | Sequence of T |
| `native.Vector(T, n)` | Vector of T bounded by n elements |
| `[n]T` | Exactly n elements |
| `?T` | Named alternatives `none` and `some` |

Absent bounds and zero bounds differ. Native layout, alignment, defaults and type
identity do not create distinct portable record shapes. Ordered field names do.
Enums normalize numeric tags, independently of native enum labels. Unsupported
pointers and recursive native types fail with a field path; recursive authored
schemas use explicit declarations.

Schema lowering shares generated helpers for repeated normalized descriptors.
A compile-time finiteness check rejects cyclic raw native descriptors before
construction; recursive authored schemas still use the declaration lifecycle.

`Schema(Shape)`, `Value(Shape)`, `Function(Signature)`, `Body(Parameters)`,
`Computation(Result)` and `Operation(Signature)` are canonical opaque families.
Callers normally infer those indices. Case payloads, destructured parts, schema
reflection, handler-derived functions, resumptions and library results retain
corresponding known children. Copying a metadata declaration onto an unrelated
Zig type cannot manufacture a canonical handle.

`try schema.fields()` returns named typed child handles. `try
schema.resultSchema()` retains its result relationship. `parameter`, `field`,
`ProductParts.get`, `variant` and `caseOf` take compile-time names when used through
the ordinary interface. `match` takes named finished cases:

```zig
const absent = try body.caseOf(optional, "none");
const present = try body.caseOf(optional, "some");
const result = try body.match(optional, .{
    .some = try present.ret(present.payload()),
    .none = try absent.ret(try absent.body().constant(u64, 0)),
});
```

A body describes available parameters, independently of the result of a branch.
`branch` has no function parameters but retains its runtime parent scope. `ret`
and `fail` return result-indexed computations; `conditional`, `block` and `match`
check their results without requiring every intermediate branch to return the
surrounding function's eventual result.

## Staging, ownership and lifetime

| Emitter action | Generated computation |
|---|---|
| Zig `if` chooses source to construct | `conditional` chooses runtime work |
| Zig `try` propagates construction failure | Checked arithmetic emits an authored failure |
| Zig `defer` releases host resources | `protect` installs portable cleanup |
| Calling an emitter helper constructs source | `apply` executes an authored callable |
| `lambda` constructs a callable value | `apply` forces it when demanded |

Keep the source Builder at a stable address. Contexts and handles borrow its
arena until `deinit`. Aliases share lifecycle. `ret` and `abandon` close a body
and its descendants. A closure can capture ancestor values; sibling values and
branch-local values cannot escape directly. Join them through a checked branch
operation. `Compiled` owns its output independently; `module` snapshots source
arrays so later Builder growth does not stale them.

Matching shape parameters do not establish runtime identity. Two same-named
local operations still have distinct capabilities. Runtime compatibility checks
actual schema identity and the complete named metadata graph, including recursive
and shared graphs and capture bounds. Source and target admission continue to
check effect rows, linear/affine use, borrowing, regions and ownership. Mutually
exclusive one-shot uses can be valid while sequential duplicate uses are rejected.

Construction failures after mutation may poison a Context. Retain its diagnostic
and discard it; general transactional recovery is not promised. `lastDiagnostic`,
`render` and `renderAlloc` retain the failed relationship and expected/actual
schemas. Diagnostic labels do not affect portable program identities.

## Specialization and source recovery

`source.specialize` propagates immutable exportable facts within its covered
first-order fragment. Unsupported callees can remain intact as generic functions.
Resource introducers and eliminators retain their original function identities
and permission records; requesting one as the root returns
`UnsupportedSpecialization`. Closed functions whose direct calls need lexical
captures remain whole generic callees, preserving their original binding and
ownership scopes. Requesting such a function as the specialization root returns
`UnsupportedSpecialization`; the original module remains usable. Capture analysis
includes transitive calls. Captured lambdas are outside the covered fragment;
encountering one during specialization leaves the request unselected and the
original module usable. Its independent translation checker relates
lexically active source and residual binders by a partial injection: introducing
a source shadow retires that source binding, while another live source binding
cannot share its residual variable. Parameters, ordinary binds, product unpacking
and sum branches all use that environment construction.

`source.lowerObserved(..., .{ .recovery = true })` records formal-parameter
origins when their input slots are created, after any captured inputs. Slot
ordering and checked structural coalescing transport those origins.
`source.recovery.parameters` reconstructs the trusted frontend input from the
supplied source, independently checks the finite correspondence against the
actual candidate program, and returns its verified formal bindings.
`source.recovery.validate` additionally compares those bindings with a compiled
result. The evidence carries no alternative lowering input. Recovery lowering
retains general handler clauses because direct tail conversion does not yet
provide an origin transport; ordinary lowering keeps that optimization.

## Operations and interpretations

`external`, `local` and `scoped` retain payload, reply and named body contracts.
Calls, effect performance, callable application, cells, resources and containers
retain known results. `sequenceValue`, `sequenceGet`, `pop`, `sequencePopLast` and
updates preserve element and container relationships.

`append` and `concat` take an options struct: `.{} ` for an unbounded sequence,
`.{ .capacity = failure }` for a finite vector. Arithmetic uses checked
`FailureLiteral` handles from `literalFailure`; divide and remainder also require
`division_by_zero`. Narrowing integer conversion requires an overflow literal;
widening conversion does not. Blob slicing requires the applicable capacity and
UTF-8 failure clauses. The shared admission owner validates dynamic categories.

Handlers retain operation payloads, state, body parameters, input and answer
relationships. Declare deep/shallow mode, use, residual effects, captures and
regions explicitly. `return_effects` and `clause_effects` may narrow their arms;
omission retains the residual allowance. `obligations = true` permits a local
resumption to retain protected cleanup, subject to independent admission.

Continuation checks share a program-derived relevance analysis. A known local
capability selects its receiving handler; an unrelated same-operation declaration
does not narrow that capture allowance. Direct helper calls instantiate suspension
summaries from their actual arguments, and known closure boundaries include their
captured values. A fresh installation discharges only its supplied capability
parameters, preserving captured outer capabilities even when both installations
use the same handler descriptor. Named diagnostics, borrow requirements, region
and cleanup checks, and optimizer capture checks use this same owner.

Unknown flows and open components retain the conservative clause union. Mutable
cell reads and unrepresented saved resumption contexts currently fall back to
that union. Successor rebinding follows token provenance: it joins the original
handler with every possible successor, including transitive successors. It never
rewrites an installation or multi-shot template globally. Unknown token origins
retain all possible original handlers; unrelated known origins stay separate.
All declarations still undergo structural and intrinsic validation, including
unused handlers. These
facts are transient; transformations and final linking derive them again.

Checkpoint admission also qualifies concrete activation and closure bindings
against these facts. It checks possible future captures against actual runtime
attachment identity: two installations of one handler descriptor are distinct
delimiters. A restored binding cannot redirect a locally discharged operation
through an outer delimiter whose intervening frames violate its capture contract.

`returnFunction`, `clauseFunctionFor` and `handledSchema` derive typed interfaces.
Deep resumptions return the handler answer; shallow resumptions return the handled
body's input. `resumeWith` supplies the successor for shallow work. A statically
known mode yields the corresponding handler type. An actual runtime mode yields
`.deep` or `.shallow` typed alternatives; switch on that result before using its
derived interfaces. `state.interpret` similarly returns a tagged answer policy.
Runtime choices remain runtime choices.

Multi-shot resumptions retain their original continuation; resuming them does
not re-run their producer. `cloneableResumption` and `cloneResumption` construct
explicit copies only when source use, capture safety and admission permit them.
`package` and `unpack` transfer suspension ownership. `resumePackage` and
`disposePackage` consume a package directly. `destructure` transfers named product
parts; ordinary field projection has its separate borrowing meaning.

`protect`, `bracket`, `withRegion`, `resourceAuthority` and nominal region schemas
retain their existing ownership obligations. `Body.fail(result_schema, value)`
closes its branch with an explicit failure. Publication validates executable
failure literals and cleanup contracts, including later helper definitions;
abandoned staging branches do not contribute executable failures.

Choice, State, Reader, Writer, Raise, Search, Generator and Scheduler expose
shape-preserving results over shared runtime graph construction. Their cache keys
retain complete actual schema/operation identity and ordered capture and region
rows. Reusing an interface reuses declarations; it does not erase nominal identity
or turn an emitter configuration into a cache keyed only by Zig type.

## Recursive interaction

`horos.library.hyper` uses the same typed bodies and values. `Hyper(A, B)` retains
both endpoint shapes: its named `peer` is `Delayed(Hyper(B, A))`, and its result is
`Delayed(B)`. `Pair(A, B)` is an opaque reciprocal schema family; use `forward()`,
`backward()`, `peerForward()`, `peerBackward()`, `answerForward()`,
`answerBackward()` and `swap()` to obtain its related interfaces.

```zig
const hyper = horos.library.hyper;
const types = try hyper.pair(c, integer, integer, .{});
const answer = try hyper.deferValue(body, types.answerForward(), try body.constant(u64, 42));
const participant = try hyper.base(body, types, answer);
const argument = try hyper.deferValue(body, types.answerBackward(), try body.constant(u64, 7));
const result = try hyper.force(body, try hyper.project(body, types, participant, argument));
```

`base`, `push`, `lift`, `identity`, `compose`, `run`, `project`, `ana` and `start`
retain their endpoint relationships. Calls return typed values directly; callers
use ordinary body operations instead of binding raw source terms. `push` and
`lift` accept an ordinary typed Function with one named `argument` parameter of
`Delayed(A)` and result `Delayed(B)`. Author the argument force and result work
inside the returned delay. `deferValue` only wraps a value already produced by
its enclosing body; it cannot defer an earlier force, effect or failure.

For heterogeneous composition, declare a named group before constructing its
participants:

```zig
const cohort = try hyper.group(c, .{ .input = byte, .middle = integer, .output = record }, .{});
const input_to_middle = cohort.get("input", "middle");
const middle_to_output = cohort.get("middle", "output");
const combined = try hyper.compose(body, cohort, "input", "middle", "output", left, right);
```

Here `left` has the second interface and `right` the first. Composition checks the
middle endpoint and the actual shared capture contracts. Runtime endpoint names
use the single explicit `hyper.ir` boundary: `from`, `to` and `select` retain
known sides and mark only unavailable endpoint shapes `Dynamic`.

`ana(body, types, state_schema, emitter)` invokes `emitter.emit(step_body, query)`
once for that authoring call and returns an opaque definition. The emitter is an
instance, so its runtime configuration and captured authored values remain part
of that construction. `start(body, definition, state)` reuses the definition.
`query.state()` exposes typed state; `query.ask(body, delayed_successor)` requires
a pure `Delayed(State)`. Compute successor work inside that delay when it must
remain unevaluated until demanded. An ignored reply does not force the successor.

Task-valued endpoints can be declared before their reciprocal pair is complete.
Use `declareSchema(.callable, Task)`, construct the pair with `task.schema()`, then
`defineCallable` with the task's effects and peer capture bounds. Obtain the task
by forcing its pure description, then execute it with `body.apply(task, .{})`.
`hyper.force` checks purity and does not execute an effectful task. The lexical
`hyper.demand` helpers interpret typed Need requests as counterpart task calls;
ordinary handlers retain their non-tail continuations and ownership checks.

See [recursive interaction](recursive-interaction.md) for the complete algebra,
explicit delay construction and task knot. The public
[`hyper_client.zig`](../examples/hyper_client.zig) exercises typed recursive
schema promises and emits an ordinary BPI3 image.

## Explicit runtime integration

`authoring.interop` owns runtime-selected names, raw IDs and checked refinement.
A `Dynamic` index marks unavailable structural knowledge; known surrounding
fields and function results remain known.

```zig
const parameters = try a.interop.RuntimeNamed(.schema).init(c, &.{
    .{ .name = runtime_name, .handle = a.interop.erase(integer) },
});
const function = try c.function("runtime interface", parameters, integer, .{});
```

The canonical `RuntimeNamed` collection snapshots entries and names in the
Context. Schema declarations, value arguments, operation sets and finished cases
use that representation. Its `len` and `at` support runtime inspection. Consumers
still validate actual names, cardinality, schemas, ownership and scope.
`interop.parameter`, `field`, `caseOf` and `fields` expose runtime selection.

`refineSchema`, `refineValue` and `refineFunction` check actual metadata before
returning the expected known shape. Positional imported schemas use `mapSchema`
or `mapValue` to validate and assign an expected named interface; these operations
cannot relabel an already-authored incompatible named schema. Raw ID import checks
available bounds and categories but cannot reconstruct historical provenance.
Keep adopted catalogs stable; raw mutation is outside the checked guarantee.

`interop.importFunction(c, id, expected_callable)` admits an undefined raw
component function declaration after checking its actual parameter and result
schemas, effect row and region row. It supplies the expected named metadata for
ordinary typed calls. Already registered functions keep their existing metadata
and scope; an arbitrary raw defined body cannot be imported this way.

`interop.componentModule(c, entry, failure, interface)` snapshots a typed open
component. Only functions listed in `interface.imports` may remain undefined.
Pending schema declarations, lexical capture checks and independent component
admission still apply. Pass the returned module and the same interface to
`source.component.compile`; final linking checks the actual imported bindings.

`interop.encodedLiteral(c, schema, bytes)` validates canonical bytes against the
reachable schema and creates a Context-owned typed value reusable across bodies.
`interop.literalFailure(c, value)` verifies global literal status before producing
a typed failure literal. Unrelated pending declarations do not invalidate a
complete literal schema. Body-local values cannot be promoted to global literals.

`declareSchema(kind, shape)` reserves a recursive schema; its definition must
prove any promised static structure. Use explicit `Dynamic` for unknown structure
and refine after completion. Undefined, wrong-kind and repeated definitions remain
checked. Raw terms and values do not acquire typed trust through an unchecked
adoption assertion.

## Verification

`zig build check-authoring -Doptimize=safe` runs authoring and compile-rejection
witnesses. `check-authoring-bytes` compares all 42 examples with the captured
pre-migration BPI3 images. `check-native` includes data, authoring and actual
linker/client checks. `check` adds the independent source oracle and wasm32
byte/identity checks; Kosmos owns execution comparisons.

`check-package` exports clean committed HEAD and consumes the actual extracted
Zig package. It runs the public client, dynamic rejection cases and static shape,
category, counterfeit-handle and lifecycle rejections. A local module build does
not replace that package check.
