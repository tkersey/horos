# Handler relevance and its transfer argument

Horos 5 checks continuation capture against possible recipients at the original
control boundary. A capability selects its actual runtime attachment; an operation
without a capability is environmental. Lexical proximity and matching effect or
schema IDs do not select a handler. A fully valid unused handler therefore does
not narrow a proven fresh installation's capture allowance.

The private owner is `src/data/control_provenance.zig`. Its obligation is
`ConcreteTargets(program, boundary) ⊆ Targets(program, boundary)`. The argument
below describes the implemented abstraction and its conservative limits. It is
an engineering argument supported by independent semantic checks, not a claim
of a machine-checked proof for arbitrary native code.

## Admission and lifetime

`activation_types.validateWithFacts` first checks catalog/index structure,
intrinsic schema and use contracts, every instruction and terminator's types,
and region structure. It then derives relevance, checks contextual terminators,
and passes the same facts to borrow admission. `activation_ownership` uses that
same result with authoritative liveness. Relevance is not inferred from the
success of the capture or borrow checks it refines.

Facts borrow one immutable program for the admission invocation. Opaque
`Analysis` and `Selection` values carry that program and the original block/role;
queries cannot accept a caller-supplied replacement image or weaker target map.
The trusted native author must preserve the documented lifetime and immutability
of the input. Copied optimizer observations retain their selection through the
owner's copy operation. Source observers translate original activation slots to
source variables before named capture checks. Transformations and linking admit
their outputs afresh; no fact is serialized into BPI3 or BMO1.

## Finite domain and convergence

An origin set contains members of six disjoint finite kinds: unknown,
environmental suspension, handler descriptor, resumption delimiter descriptor,
closure constructor, and formal input position. Their ranges are computed with
checked arithmetic from the program's catalogs and maximum slot count (which
also bounds formal inputs and position-query sources).
These descriptor IDs represent possibly many runtime objects; they never prove
that two capabilities or tokens are the same object.

There are finitely many block-slot rows, return sets, constructor capture fields,
function/effect suspension summaries, and handler-to-handler binding entries.
Persistent slot rows share storage, but row joins and origin joins are exact
unions. Straight-line assignments recompute an exit from its entry; CFG entry
rows, captures, returns and summaries grow monotonically. `converge` stops only
when those sets stop changing. Formal summary substitution introduces only
members already in the finite universe. It creates no call strings, recursive
projection paths, dynamic branch IDs, or semantic-round cutoff.

Root inputs and non-resumption handler inputs start unknown. After the first
fixed point, unwitnessed formal inputs become unknown and the concrete analysis
converges again. An unbound declaration is not a proof of an empty recipient set.
Reduced results are published only after convergence and successor-binding
closure. Allocation or representation failure returns an error; it cannot
produce an empty result or silently approve a program.

## Transfer invariant

For each represented slot or capture, every possible concrete capability,
constructor or token origin is in its set, or the set contains unknown. A
symbolic suspension summary states the same fact relative to the function's
formal inputs. Unknown expands at the query owner to all clauses for the actual
effect; it does not mean no targets.

| Transfer | Preservation of the invariant |
|---|---|
| Fresh `handle` | `body` binds only installation-supplied capability formals to the installed descriptor. Actual arguments and captures retain their own origins. |
| Move, products, alternatives, sequences, resources, packages and explicit clone | The result includes the union of operand origins. Field extraction intentionally retains the aggregate union. This loses correlation but cannot discard a possible recipient. |
| Runtime selection and CFG joins | Both selected value alternatives and every predecessor contribute unions. Edge assignments read the same predecessor snapshot, including permutations and unpacking. |
| Cells, opaque operations and unrepresented values | The result is unknown. An untracked mutation therefore cannot establish an empty or local-only recipient set. |
| Direct calls and returns | Concrete argument sets flow into the callee. Relative return and suspension summaries substitute actual argument sets for formal-input members, including recursive calls. |
| Closure construction and application | Captures join by constructor and field. Known applications follow every represented compatible constructor; unknown applications seed every compatible possibility conservatively. Schema equality alone never selects a constructor. |
| Scoped bodies, forwarding and injected computation | Captured origins persist; supplied use-site inputs are unknown where their correlation is not represented. An outer capability remains outer beneath a same-effect installation. |
| Handler clauses and state | Clause inputs other than the retained resumption are unknown. The resumption input names the receiving delimiter descriptor. Handler state does not acquire local capability provenance by schema equality. |
| Deep and plain shallow resume | Resumed-boundary queries retain the conservative effect bound. Deep resume preserves the saved delimiter. Plain shallow resume does not rewrite explicit capabilities to a lexical successor. |
| `resume_with` | Binding rows retain the original descriptor and add every possible successor, then take transitive closure. An unknown resumption adds the successor to every row. No existing binding is overwritten. |
| Multi-shot copy/clone | Copies preserve origin unions. Successor bindings are may-relations, so a branch cannot erase the original template or another branch's possible binding. Intrinsic clone/use and cleanup restrictions remain separate checks. |
| Protection, disposal, failure and cancellation | Body and cleanup boundaries are distinct. Known cleanup closures use their captured origins; unrepresented resumed/disposal/handler contexts fall back conservatively. The analysis does not prune registered cleanup based on a presumed normal exit. |

The step argument follows these transfers from the admitted inputs. Union joins
preserve the invariant across branches and iteration; the finite fixed point
therefore covers every number of repetitions represented by those transfers.
The shared immutable row representation changes storage sharing, not set meaning.

`closureTargets` discharges an installed body's suspension only when its symbolic
origin is one of the capability formals supplied by that fresh installation.
Captured outer capabilities are a separate prefix and are never discharged by
descriptor equality, even if an outer installation uses the same descriptor.
Direct operations with unknown or unwitnessed provenance, unknown symbolic
summaries, and unsupported boundary roles use the conservative query branch.

## Successor precision and persisted state

Binding rows deliberately merge views that this abstraction cannot distinguish.
They retain both the original and all transitively reachable successor handlers.
The implementation does **not** infer unique runtime identity from a static
installation or perform a strong update of its binding. Consequently some valid
programs with complex aliases still receive conservative checks. Precise fresh
local installation, direct-helper substitution, explicit outer forwarding and
known runtime unions do not depend on that stronger alias precision.

Restoration is another execution-state constructor. Ordinary PST3 graph, type,
scope, custody, region and cleanup admission remains mandatory. After those
checks, `Analysis.validateState` relates concrete activation slots and closure
captures to the same abstract origins: attachment definitions must be possible
bindings, constructors must be represented, and tokens must name a represented
capture delimiter. Aggregates/resources/packages are traversed with their allowed
sets. Unknown values keep the ordinary concrete checks; they do not bypass them.
The visited key includes both node and allowed set, so one alias does not certify
a different abstract view. Recursive graphs need no depth cutoff.

Concrete future capture additionally requires executable suspension, not merely
a retained capability. `state_effects` derives two finite attachment-origin
relations: values reachable from a component, and effects executable through it.
The first remains the conservative fallback. The second uses
`Analysis.suspensionSources` for current activations and saved return edges. A
pure helper can return a capability without capturing its caller; an effectful
helper can use an inner capability while carrying an unused outer capability
with the very same handler descriptor.

The position query seeds stable slots at the exact block and instruction position,
then reuses the relative value transfers and direct-call suspension summaries.
Callee summary input ordinals are substituted through argument slots before
becoming position sources. They are never interpreted as current function input
slots: those inputs may already have been overwritten. A saved continuation
starts at its return edge, with the not-yet-delivered value unknown. Ordinary
activation admission has already required all live, available saved bindings.
Missing demanded bindings reject instead of certifying an empty target set.

Only reachable successor blocks enter the position fixed point. The initial
instruction suffix is separate from later backedges, which execute the full
block. Strong instruction assignments and simultaneous edge substitution use
the same transfer owner as program admission. Recursive callees use their full
function summaries, while the position query accumulates a separate result.
Unknown instructions, opaque/scoped calls and unrepresented contexts retain the
conservative effect interface and reachable origins; they cannot produce a
false empty set. Environmental operations select no attachment.

For each frame, future capture examines its child execution, since returning
consumes that frame before its own suffix runs. A continuation's executable row
therefore combines child execution with its own later suffix for its ancestors.
Attachments mask only origins inside the actual reinstated delimiter; handler
effects remain conservatively represented. Protection also includes possible
cleanup effects for enclosing frames. Regions and injected computations forward
child execution. Dormant token children retain their use-site capabilities for
possible injection; environmental pending children add none because their
response values are first-order. Cancellation and failure also discard owned
activation bindings. A separate finite disposal relation follows only owned
fields of aggregates, computations and packages: discarding these containers
does not invoke a copied capability or the computation itself. Resources have
no implicit effectful finalizer. One-shot tokens conservatively retain their
reachable origins because discarding them activates captured cleanup.
Cleanup-return, disposal and unwind contexts include these latent disposals,
including owned normal results and discarded values in enclosing exits. Their
current child's effect interface alone cannot bound that later cleanup.
All existing custody, captured-region, cleanup and resumption-use checks still
run independently.

Position results are cached only within the same immutable admitted program and
admission lifetime, keyed by block, instruction position and saved/current role.
Their domain is bounded by the program's slots and effects; executable rows are
bounded by state nodes times concrete attachment count. The fixed points use
monotone finite unions with no iteration cutoff. Allocation failure returns an
error. Neither position facts nor attachment-origin rows are serialized.

Open components use conservative relevance; imported implementations are not
assumed local. All declarations still receive intrinsic validation. Closing a
link derives fresh facts after resolution and relocation. For an unchanged
intrinsically valid program, reduced contextual checks use subsets of the old
effect-wide clause set; they do not add a new capture obligation. Concrete state
qualification additionally rejects forged states inconsistent with the program
facts. Preserving valid execution does not require admitting those forgeries.

## Consumers and deciding evidence

Capture liveness and named source capture checks, region/cleanup contracts,
borrow-flow clause requirements and writes, call-pattern capture replacement,
and persisted-state qualification all query this owner. They retain their own
intrinsic schema, nominal identity, liveness, outlives and use laws.

`src/authoring_tests.zig` includes the unused conflicting-handler witness,
positive and negative direct-helper propagation, separate obligations through
one shared helper, and named-capture/coalescing preservation.
`src/data/evidence_forwarding_tests.zig` distinguishes equal descriptor IDs from
equal attachments, verifies explicit outer forwarding and runtime unions,
rejects malformed unused declarations, exercises conservative valid/invalid
admission, and checks cyclic successor bindings and narrower successor rejection.
Dense-vector comparisons in `control_provenance.zig` check row copying and unions
independently of the persistent representation.

Kosmos's `test/v2/control_provenance.zig` and
`test/v2/control_provenance_alias.zig` exercise authentic restore and forged
same-schema substitutions. They also round-trip authentic yielded checkpoints
with effect-free helpers, yielded cleanup and nested same-descriptor handlers, and distinguish a
local effectful dispatch from a retained outer capability. Original and restored
execution must agree on the exact result. The independent Horos source oracle and Kosmos's
44-fixture source/native/WASM comparison retain deep, shallow, successor,
injection, cleanup and local one-/multi-shot observations. The 42 historical
BPI3 fixtures stay unchanged. These are falsification and preservation evidence
for the stated construction; passing tests alone is not the transfer argument.

Use `zig build check -Doptimize=safe` for the full Horos gates and the coordinated
Kosmos checks for execution/restore evidence. See
[admission measurements](authoring-migration.md#admission-measurements-horos-5)
for the measured cost and retained-storage limits.
