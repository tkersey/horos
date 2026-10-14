# Optional provenance, interaction and progress observations

These analyses extend the existing immutable-program admission lifetime. They do
not change admission, enable semantic optimization by default, or add runtime
formats. BPI3/BMO1/PST3 and invocation identities retain their existing meaning.
A program admitted without an optional property remains admissible when that
property is unresolved.

## Ownership and interfaces

`control_provenance.Analysis` remains the only target-provenance solver. The
existing capture observers accept an optional `explanation` callback. Its value
is borrowed until callback return; `Explanation.copy` retains independently
owned presentation arrays, including original numeric locations. Source lowering
maps available original slots to source variables before coalescing. A copied
`Selection` still borrows its original immutable program. Neither record is an
admission certificate.

An explanation records final converged origin memberships and finite rule
references. Keys distinguish program position, slot, concrete/relative row,
return, capture and suspension summary. Interning a key before visiting its
inputs closes recursion with backreferences. An explicit work queue expands each
interned fact once and fills all placeholders before publication; graph depth
does not consume native call stack. After dependency discovery, slot requests are
grouped by concrete/relative block and sorted by position. One forward replay of
each required prefix fills its final origin memberships with the existing transfer
function; individual facts no longer reconstruct and retain the same prefix again.
Reason identities and contents are unchanged. Strong local assignments select the
last definition; predecessor edges read the predecessor view simultaneously.
Input seeds distinguish introduced uncertainty from uncertainty propagated
around a cycle. Aggregate projection retains the owner's union approximation;
cell reads, unbound inputs and open components are conservative. Successor
bindings describe possible alternatives, not a combined execution. Implicit
owned cleanup follows the same disposal equations used by admission, including
suspension effects absent from an ordinary invocation row.

Recording is enabled only when requested. Explanation rendering occurs after the
capture constraint has been decided. Rendering failure supplies `null`; it cannot
erase a rejection. Required admission allocation failure remains an error. The
`capture_constraint` names the retained slot/schema and its actual result; other
borrow/region/type failures continue to use their existing diagnostics.

The compiler's existing observation options also accept `service`, selecting
three nominal declarations and receiving a borrowed scoped report. Final binding
and relocation precede this optional query. One final provenance owner supports
both its interaction and wait consumers; it does not retain the expired scratch
arenas of earlier candidate admissions. Evidence-forwarding qualification instead
borrows each existing intrinsic admission's owner through `CaptureObserver.analyzed`.
Only the copied target and monitor observations survive that callback.

## Finite interaction argument

`data/interactions.zig` is private and has no public root export. A query binds an
immutable program/provenance owner, imported-body set, event projection, finite
parameter interpretation and total monitor table. Symbols, monitor states and
parameter contexts each have at most 64 elements; these are analysis domains,
not limits on program size, recursion, requests or runtime lifetime.

The table contains one summary for each function, consumer context, incoming
monitor state and execution mode (ordinary or running cleanup). Ordinary queries
read the ordinary half. Calls inherit the execution mode, while every protection
cleanup enters running-cleanup mode. Each summary is a tuple of normal, failure,
cancellation and reachable prefix state sets, plus widening and possible-nonreturn flags. The transfer is
monotone over this finite product lattice. Starting with empty exit relations
and repeatedly joining transfers reaches a least fixed point. A function pass
uses a finite block/state worklist. Direct calls use only their callee's summary
at that call's continuation. Recursive calls do not receive invented successful
returns; nonreturning prefixes still contribute violations. `may_nonreturn` is
conservative and is never a termination proof.
Every incoming block-state set is recorded before subsequent events, so a bad
state remains a reachable prefix even if the monitor later leaves it.
Abrupt transfers carry cleanup prefixes separately from post-failure or
post-cancellation states. Normal disposal widening also records its closure before
the next instruction. In running-cleanup mode, cancellation records an exit and
closes its projected state transitions while retaining the current work, including
a pending request and its subsequent reply. This context propagates through helpers
and nested calls. Cleanup normal/failure states also remain possible cancellation
exits, conservatively forgetting whether cancellation was recorded. A primary body
failure remains failure after cleanup cancellation. No absorbing-bad-state
assumption is imposed on monitors.

For the covered transfer fragment:

- Instructions emit their projected event and retain declared failure and
  cancellation alternatives. Branches retain both program choices. Environmental
  replies and scheduling decisions remain identified as environmental choices.
  A pending external operation retains cancellation before any successful reply.
- Direct calls and known constructor applications compose finite relations.
  Constructors come from the existing provenance owner. A consumer's context
  transfer must interpret actual argument/capture relations; a spelling is never
  a validation or authorization contract.
- Checked deep one-shot administrative clauses resume their actual token exactly
  once. Their other instructions and return clauses must be total and silent for
  this projection, including cancellation at erased control positions. Executable
  disposal makes this reduction unavailable. The retained resume event uses the
  clause's parameter interpretation, through the same checked context transfer as
  direct calls. Writes, aliases or transfers of that token outside the checked
  resume make this reduction unavailable. Silent clause prefixes still contribute
  cancellation exits, and ordinary body returns compose the handler return
  function even when its events are silent. A silent event does not erase an exit.
- General local control and multi-shot resumptions use an alphabet closure over
  all compatible captured suffixes, handlers, return clauses, injected bodies and
  continuations. Every visited function closes over possible caller return/unwind
  actions: handler returns, protected cleanup, disposal continuations, injected
  captured suffixes and successor handlers. This closure also applies to suffixes
  that fail or are cancelled without returning. It never re-enters a caller body
  or its producer instructions solely to traverse its continuation. The producer
  prefix is excluded only when this static reachability bound excludes it. This bound deliberately loses path/call correlation; it is
  not a feasible witness. Unknown constructors, imports or latent disposal expand
  to the entire alphabet.
- An opaque region denotes the reflexive/transitive closure of its alphabet,
  with all exit kinds and possible nonreturn. It can emit zero, one or many events.
  Protection composes cleanup with body normal, failure and cancellation exits.
  Owned disposal is never treated as silent merely because the declared row is empty.

The disposal query follows the runtime's owned aggregate, closure, package and
one-shot capture traversal. Its finite schema fixed point is seeded by retained
protection obligations and propagates through owned captured contents. Admission
requires the obligation flag at protected capture edges. This query is distinct
from the existing escaping-effect equations: cleanup may yield with no escaping
effect. Obligation-free captures with no executable owned contents remain silent
for disposal, retaining the cloned producer's precise bound. Unknown executable
cleanup expands to the full monitor alphabet and can lose optional precision.

These rules give an induction over finite concrete execution prefixes: each local
step is represented, each matched call composes a represented relation, each
recursive finite derivation appears in a finite fixed-point iteration, and an
unsupported segment is contained in its alphabet closure. The implementation
checks every terminator kind exhaustively. This is a scoped abstraction argument,
not a proof of value equivalence or eventual completion. Source/native trace
inclusion tests independently falsify omitted transfers but cannot prove the
argument for all programs.

A bad abstract prefix is `potential`, never automatically `demonstrated`.
`established` means avoidance for the specified interpretation and scope, including
its overapproximations. An unrelated property can therefore be established despite
an opaque region. Changed code, linking, monitor or interpretation requires a new
owner/query. Same-session caching uses the complete immutable query binding;
mutating borrowed bindings is outside the native caller contract.

## Three consumers

The test-local validation monitor binds actual typed validation/write operations,
object A/B argument positions and the successful Boolean branch. Its finite
must-valid sets lose validity on mutation/replacement and unknown aliasing.
Opposite orders share the same effect row. Direct helper parameter substitution
uses actual call arguments; mutually recursive helpers use the same fixed point.
No remote truthfulness or product authorization policy is inferred.

Evidence forwarding observes its actual candidate before dead-argument elimination
and structural relocation. The existing validator first checks original/candidate
admission, every actual-slot substitution and unchanged records. Pair monitors
then compare ordered operation-site observations and independently compare nominal
target alternatives. Matching coarse observations never replace the local rule's
value/authority proof. Widened root relations are inconclusive. Qualification runs
this consumer automatically through `check-data`; ordinary optimization does not
pay for it. Subsequent dead-argument removal and P01 continue using their existing
checked correspondence, so this observation is not transported across relocation.

The service consumer checks the authored generator construction, not names or an
arbitrary supplied graph. It matches every executable function, block, instruction,
operand, edge, constructor, package, handler and request/reply relation. The actual
local offer's target must be the checked generator handler. Each activation uses
fresh definitions (multiple incoming phi edges may define a slot at the same
block), preventing a type-correct overwrite from changing a retained request id
or previous counter behind the checker. Unrecognized changes return unresolved.
This intentionally narrow reduction supports the authored witness and its checked
reply mutant; it does not claim to infer arbitrary libraries.

The derived phase graph executes startup once, retains the exclusive cell/turn
across yield, sends each local reply before requesting another command, consumes
the linear future on resume, and finalizes after close. Separate cleanup tails
cover failure and cancellation, including finalizer failure without rerunning it.
The monitor checks this order and reply identity. The XOR reply mutant preserves
final counter state while failing that property. Two simultaneously created
service instances are a separate runtime ownership witness; their combined program
is outside this single-service reduction's scope.

## Waits and conditional progress

The implementation checker binds the current turn and its exclusive cell owner,
driver, completion, command source, reply/finalizer acknowledgements and scheduler.
It derives dependencies at the checked request, resume, yield, close and finalizer
sites. A separate rank checker checks strict decrease on every edge. Coverage is
checked against all dependencies of that checked construction, including its region
and cell schema. Dropping a required edge cannot retain coverage just because the
remaining graph is acyclic.

The report keeps admission, ordered safety, represented waits, per-turn local
termination, finite spawning, scheduler fairness, external completion and end-to-end
claim separate. The service has finite local work per turn and one private cell
with one owned successor; arbitrary runtime batches remain legal. Completion is
conditional on a finite batch, fair scheduling, required external outcomes and
sufficient physical resources. External completion remains unresolved in the report.
An acyclic graph cannot establish fairness. Opposite edges from mutually exclusive
program branches are a cycle candidate, not a demonstrated deadlock. Pure divergence
has no invented normal exit. A changed implementation loses its prior wait claim.

## Qualification map

The exhaustive [validator coverage map](../src/data/validator_coverage.md) covers all
37 current compiler stages and credits their existing semantic mutants. The
following tests add the paper-specific relationships; names identify executable
assertions, not just planned coverage.

| Requirement | Deciding checks |
| --- | --- |
| EX-01–04 | `evidence_forwarding_tests`: qualified outer/union targets, successor bindings, final outer argument/capture explanations; unused same-effect handlers stay absent. |
| EX-05 | Cell read explanation; open component/unwitnessed inputs identify conservative expansion. |
| EX-06 | Recursive helper backreferences; implicit disposal outside a direct helper row has finite explanation. |
| EX-07 | Copied explanation allocation failures and rejected capture presentation; source observer on/off image identities and retained source mapping; admitted 10,000-instruction and 4,096-definition blocks retain available explanations. |
| IN-01–04 | `interactions_tests`: same-object validation order, wrong object, mutation/replacement/failure, swapped helper arguments, mutually recursive summaries and nonreturning bad prefixes. |
| IN-05–08, IN-10–11 | Outer target owner tests; opaque import multiple-event closure; cleanup/injection baseline fixtures; cloned suffix without repeated producer; relinked body and changed property; potential-only verdicts. |
| IN-09, IN-12 | Three consumers in existing roots; `service_interactions.mjs` independently includes source traces and rejects omitted yield edges and wrong reply labels; Kosmos applies the same membership check to actual native/WASM traces. |
| IN-03, IN-07 | Regressions retain nonabsorbing bad states after branch/switch and cleanup even when later exits reset them, pending-request cancellation, cancellation in administrative clauses/returns, clause parameter interpretation, effect-free owned cleanup, cancellation followed by a cleanup reply/helper request, primary failure after cleanup cancellation, silent administrative cancellation exits, and nested handler-return order. |
| WT-01–03, WT-07 | Source service observer checks derived rank and coverage; omitted dependency and nondecreasing rank reject; admitted arithmetic and slot-overwrite mutants lose the report. |
| WT-04–05 | Actual exclusive-branch wait operations produce only a cycle candidate; effect-free recursion has no successful return and allows nonreturn. |
| WT-06 | Service report retains unresolved external outcomes and explicit fairness premises; existing scheduler/FIFO and held-worker tests retain independent eligible work. No new scheduler claim is inferred. |
| SV-01–06 | New empty/two-request/overflow/cancel scenarios, independent labeled reply/final counter expectations, yield and checkpoint/restore comparison, swapped replies with equal final state. |
| SV-07–09 | Two live equal-typed services each return previous zero and finalize one; existing package alias/reuse rejection; existing multi-shot fixture; source/native/common-domain WASM comparisons. |

Kosmos's existing `publication.zig` tests retain exact encoded/hash publication,
issuer/generation/consumed receipt rejection and failure retry. Its
`stable_source.zig` tests retain unique-package alias rejection after graph
renumbering, owned FIFO checkpoints and live shared aliases. The source oracle
also retains distinct owned snapshots versus deliberately shared cells. A digest
is not an invertible representation, and equal scalar leaves do not imply equal
owners. Native/WASM agreement is cross-target evidence; the authored source
oracle supplies the independent semantic expectations.

Legal multi-shot suffix reuse is not duplicate settlement authority. Kernel reply
binding does not prove global uniqueness across copied kernels. Checkpoint transfer
receipts do not prove durable-store commit. The join helper's write does not itself
establish at-most-once settlement; its enclosing ownership/control construction
supplies that law. Protean's external occurrence custody remains unchanged.

## Costs and retained checks

The optional `control_provenance_bench` accepts `derive`, `explain`, `interactions`,
`service`, `candidate-validate` or `candidate-observe`, plus an optional fixture
name. Its existing default fixture set and 11 samples remain unchanged. Reported
bytes are requested allocation/retained bytes, not process RSS. Repeated exact
queries check that the same stored result is returned. Finite relation sizes,
worklist visits, widenings and explanation nodes accompany timing measurements.

The measurement results and exact coordinated qualification tuple are recorded
with the implementation's delivery report. Ordinary compile/admission uses the
same 10 fixtures as pinned baseline `af67ec9`; optional analyses are measured
separately. No timing threshold, application quota or CI budget increase is used.

### Executed measurements (14 October 2026)

Apple M2 Pro, arm64 macOS 27.2 (26B5112a), exact Zig 0.17.0, ReleaseFast.
Three process batches per variant, alternating baseline/candidate order, each
with one discarded first sample and ten warm samples (30 measured observations
per row). Inputs are the existing ten-fixture corpus; all compile image hashes
match baseline `af67ec9ca7b76e4e75e81c28f575f557b2345be3`. Decode/setup is outside
the private-analysis timing. Timings are medians, not latency percentiles or
guarantees; background load and sub-millisecond timer noise remain limitations.

| Fixture | Baseline compile ms | Candidate compile ms | Baseline admit ms | Candidate admit ms | Compile peak bytes baseline → candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| recursive | 0.027 | 0.027 | 0.006 | 0.006 | 43478 → 43478 |
| generator | 0.192 | 0.192 | 0.050 | 0.049 | 205970 → 206310 |
| scoped-reader | 1.017 | 1.027 | 0.143 | 0.147 | 972624 → 972640 |
| state-local | 0.255 | 0.260 | 0.044 | 0.044 | 219998 → 219974 |
| state-shared | 0.232 | 0.232 | 0.039 | 0.040 | 226522 → 226610 |
| choices-all | 0.055 | 0.056 | 0.015 | 0.016 | 70942 → 71022 |
| recursive-choice | 1.180 | 1.195 | 0.231 | 0.232 | 968192 → 968232 |
| install-8 | 0.118 | 0.119 | 0.032 | 0.032 | 115082 → 114962 |
| install-64 | 1.207 | 1.210 | 0.343 | 0.345 | 1059342 → 1059302 |
| install-128 | 2.626 | 2.654 | 0.767 | 0.776 | 2356236 → 2356116 |

Retained compile/admission bytes are identical for every baseline/candidate pair.
Ordinary compile median changes range from about -0.2% to +2.7%;
this small run does not establish a general speedup or zero overhead. Admission
median changes range from -2.1% to +2.7%. No extra analysis runs on the ordinary
path. The storage extension can change arena growth boundaries. The aggregate
check exposed an existing affine constructor that copied its arena before its last
allocations; allocating those arrays before moving the arena fixes that leak.

Private derivation medians (baseline → candidate) are 24.81 → 24.38 µs for
generator, 41.90 → 42.29 µs for scoped-reader, and 551.58 → 556.98 µs for
128 installations. Each performs one target derivation.

Optional rows below include their shared target derivation; candidate rows include
both existing intrinsic admissions. Peak/retained are requested bytes, not RSS.
Edges are graph edges for service, worklist visits for general monitors.

| Fixture / operation | µs | Peak / retained bytes | Allocation calls | Target solves / queries | States / edges | Relations / widened sites | Explanation reasons |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| generator / explain | 35.62 | 106110 / 106110 | 8 | 1 / 3 | 0 / 0 | 0 / 0 | 40 |
| scoped-reader / explain | 59.06 | 179930 / 179930 | 8 | 1 / 11 | 0 / 0 | 0 / 0 | 90 |
| source-stateful-service / derive | 37.25 | 77014 / 77014 | 7 | 1 / 0 | 0 / 0 | 0 / 0 | 0 |
| source-stateful-service / explain | 47.58 | 128446 / 128446 | 8 | 1 / 5 | 0 / 0 | 0 / 0 | 56 |
| source-cloned / interactions | 33.23 | 45632 / 45632 | 7 | 1 / 1 | 30 / 342 | 102 / 3 | 0 |
| source-stateful-service / service | 39.15 | 77014 / 77014 | 7 | 1 / 2 | 160 / 38 | 5 / 0 | 0 |
| forwarding / candidate-validate | 24.60 | 24744 / 0 | 36 | 2 / 0 | 0 / 0 | 0 / 0 | 0 |
| forwarding / candidate-observe | 56.25 | 34960 / 0 | 40 | 2 / 2 | 100 / 820 | 388 / 2 | 0 |

Service adds six wait edges checked independently of its 38 phase edges. The
cloned fixture reaches its fixed point in four iterations. Widened sites count
all analyzed functions, including summaries unreachable from the selected root;
the forwarding root comparison can therefore be established despite a nonzero
global count. Forwarding observation uses two target solves total, the same as
ordinary candidate validation; it previously duplicated those solves. The general
engine caches constructor, disposal, administrative-clause and suffix-alphabet
queries within the same subject. Exact repeated query assertions retain the same
result storage. There is no persisted cache or emitted runtime analysis data.


### Explanation scaling discriminator

The admitted fresh-capability-slot chain in `evidence_forwarding_tests` separates
prefix reconstruction cost from graph recursion. At 128/256/512/1024 moves, the
reason graphs have 136/264/520/1032 nodes. ReleaseSafe probes against predecessor
`5520a19cb1130062163ca1994254e9a97009e030` and the batch-readback implementation
used three alternating process batches with three observations per size (nine
per variant). Serialized reason graphs were byte-identical at every size.

| Fresh definitions | Retained bytes before → after | Explanation median µs before → after |
| --- | ---: | ---: |
| 128 | 2746900–2747984 → 393912–396216 | 1026.83 → 79.71 |
| 256 | 9667192 → 1106384 | 4436.04 → 150.25 |
| 512 | 51077464 → 1753900 | 20184.71 → 316.75 |
| 1024 | 175063212 → 4478726 | 97326.25 → 682.79 |

Retained bytes include the unchanged target derivation; explanation timing
excludes it. The 1024-move timing ranges were 95.76–101.69 ms before and
0.61–1.31 ms after. This is a synthetic allocation discriminator, not a general
compiler speedup claim. The existing test retains the same-slot and long unrelated
instruction cases; the fresh-slot test also checks every definition's actual
handler origin and uses a loose 32 MiB fixture-only allocation guard. No runtime
program quota or optional-result truncation was added.
