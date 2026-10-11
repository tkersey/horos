# PST3 stable execution graph

This development grammar is implemented by `process_state.zig`, `state_image.zig`
and the shared ordered graph traversal. The codec establishes framing, bounded
record decoding, references, canonical graph order and activation record shape.
`state_admission.validateStable` separately checks the graph against the admitted
Program, including identity, code position, slot availability, ownership, effects,
borrow lifetimes and cleanup custody. Kosmos now restores these checked records
into its native stable controller. Current envelopes and Kosmos ABI 3 carry this
same State through fresh and resident execution and the cross-host checks.

## Framing and primitive grammar

```
"ABL_PST3"[8] | version:u16LE=3 | flags:u16LE=0 | body_length:u64LE | body
```

Length is exact; other families, versions, flags, trailing bytes and padding
reject. `N` is minimal unsigned LEB128, at most ten bytes and bounded by u64.
`B` is N(byte length) followed by bytes. `[T]` is N(count) followed by T records.
`?T` is byte 0 or byte 1 followed by T. Fixed arrays are raw bytes. A tagged
alternative is N(tag) followed by the listed fields. Struct fields concatenate
in the listed order without padding. Unlike BPI3's ID vectors, PST3 vectors use
ordinary counts and records; they do not serialize Program analysis maps.

Node references, blob references, Program IDs and slots all use N but have
distinct owners. An OwnedRef is a node reference with no additional wire tag;
ownership is carried by its enclosing field/value, not by the integer itself.

```
State = program_identity:[32 bytes], status:N, Roots, [Node], [Blob]
Roots = current:?NodeRef, evidence:?NodeRef, detached:[OwnedRef],
        exit:?NodeRef, pending:?NodeRef
Node = Record, activation:?Activation
Blob = schema:N, bytes:B
Activation = position:N, scope:N, bindings:[Binding], owners:[Owner]
Binding = slot:N, Value
Owner = scope:N, slot:N
Value = schema:N, tagged body
```

Status tags: active=0, yielded=1, parked=2, unwinding=3, completed=4, failed=5,
cancelled=6. Terminal projection places its full result/exit in Roots.exit.
Value bodies: scalar=0 followed by eight bytes; blob=1 then BlobRef;
reference=2 then NodeRef; owned=3 then OwnedRef. Scalar padding and schema-directed
values need Program-relative checking, independently of graph canonicality.

Activation is present exactly on control and continuation nodes. Bindings have
strictly increasing slot IDs. Each owned binding occurs exactly once in owners;
ordinary references never enter that list. Owners run from the innermost active
lexical scope to the root, retaining establishment order within each scope.
Position is the next instruction index for control, or the source terminator
index for a saved continuation. Scope is a Program custody-scope ID. Neither is
a native instruction pointer, pool index, generation, or memory-page identity.

## Record tags

All fields below are mandatory in order, including empty lists and absent
optionals. Control and continuation values reside only in the activation view;
there are no predecessor block-argument vectors. This development grammar
supersedes earlier draft PST3 records containing empty argument vectors.

| Tag | Record | Fields |
| --- | --- | --- |
| 0 | control | block:N, parent:?NodeRef, evidence:?NodeRef, region:?NodeRef |
| 1 | continuation | source_block:N, parent:?NodeRef, evidence:?NodeRef, region:?NodeRef |
| 2 | handler | definition:N, state:[Value], evidence:?NodeRef, region:?NodeRef |
| 3 | attachment | handler:NodeRef, outer:?NodeRef, return_to:?NodeRef, phase:N, region:?NodeRef |
| 4 | environment | values:[Value], tail:?NodeRef |
| 5 | aggregate | schema:N, tag:N, fields:[Value] |
| 6 | region | descriptor:N, outer:?NodeRef, obligations:[OwnedRef] |
| 7 | region_scope | source_block:N, region:NodeRef, return_to:?NodeRef |
| 8 | injection | continuation:NodeRef |
| 9 | protection | source_block:N, obligation:OwnedRef, return_to:?NodeRef, evidence:?NodeRef, region:?NodeRef, loan:?NodeRef |
| 10 | cleanup_return | obligation:OwnedRef, parent:?NodeRef, exit:NodeRef |
| 11 | disposal_return | schema:N, parent:?NodeRef, values:[Value] |
| 12 | unwind | cursor:?NodeRef, values:[Value] |
| 13 | cell | schema:N, region:NodeRef, value:?Value |
| 14 | one_shot | Capture |
| 15 | multi_template | Capture |
| 16 | branch | template:NodeRef, attachment:NodeRef, regions:[(source:NodeRef,target:NodeRef)] |
| 17 | package | schema:N, continuation:Value |
| 18 | computation | constructor:N, environment:NodeRef |
| 19 | resource | schema:N, value:Value |
| 20 | borrow | schema:N, resource:NodeRef, region:NodeRef |
| 21 | obligation | source_block:N, cleanup:?Value, resource:?Value, ObligationStatus |
| 22 | pending | effect:N, payload:Value, continuation:NodeRef, source_block:N |
| 23 | exit | Exit |

Attachment phases are active=0 and suspended=1. Capture is `(schema:N,
capture:?NodeRef, delimiter:NodeRef, evidence:?NodeRef,
use_site_capabilities:[Value])`. ObligationStatus tags are pending=0, running=1
with NodeRef, completed=2, failed=3 with Value.

Exit is `(reason:ExitReason, cleanup_failures:[Value], cancellation:?Reason,
stop:?NodeRef, outer:?NodeRef, discarded:[Value])`. ExitReason tags are normal=0
with Value, failure=1 with Value, cancellation=2 with no payload, abandoned=3
with no payload. Cancellation Reason tags are text=0 with B, bytes=1 with B;
the text case requires UTF-8 at semantic admission.

## Canonical graph order and ownership

Discovery is iterative depth-first preorder, starting from Roots fields in their
declared order. At each first node visit, visit Record fields first, then the
activation's bindings in increasing slot order. Arrays use element order;
optionals and active union cases use their listed field order. Each first-seen
node gets the next zero-based node ID. Shared references and cycles revisit that
ID; equal-looking nodes never merge. Unreachable nodes are omitted on export and
rejected on decode.

Blobs are numbered by first discovery, interning identical `(schema, bytes)`
pairs only. Referents with authority or mutable identity are never content-interned.
Every referenced blob is present, and unused/duplicate blob entries reject.
No physical allocation order, private slot pages, refcount, hash iteration order,
or superseded activation history enters the canonical traversal.

Each activation belongs to its control node. This avoids a separately rooted
frame side table that could preserve dead views or lose frame-only references.
The falsifiers are lost captures/cycles, reordered cleanup, or changed bytes after
renumbering physical nodes. Tests exercise those graph distinctions and runtime
checkpoint idempotence through the existing semantic source suite.

## API limits and current evidence

`encode` first owns the complete normalized graph and checks shape/capacity before
writing caller output; input/output overlap is therefore safe. `emit` returns
independently allocated bytes. Failed export does not mutate resident execution.

`decodeGraph` owns input bytes and parsed records. It checks discovery order in
place, without constructing a second complete graph owner. `decodeGraphLimited`
defaults to a 64 MiB physical budget for owned input plus requested decoded
record storage. Count/size arithmetic is checked before allocation. Temporary
discovery indexes and allocator backing slack are separate from this budget.
Record recursion has fixed type depth; runtime cycles use checked references.

Tests include an independently specified terminal-unit golden, native and wasm32
golden re-encoding, graph permutation and cycles, immutable blob ownership,
truncation, malformed shape, allocation failures, and output atomicity. Kosmos's
stable source suite checkpoints after drive boundaries and verifies identical
repeated export and decode/re-encode. Its export allocation-failure sweep checks
that the original resident boundary remains byte-for-byte unchanged.

The Program-relative checker shares the existing type/scope/custody rules, with
stable activation values participating directly in capability and ownership
analysis. Its borrow queries distinguish function-input ordinals from stable
slots at a specific instruction position, excluding completed writes while
retaining possible loop reentry. Continuations map future slot projections
through simultaneous assignments and their returned-result hole. No predecessor
block interfaces are reconstructed.

Restore tests reject wrong Program identity, invalid positions, unavailable
slots, forged cleanup status and aliased unique packages after canonical graph
renumbering. Fresh native restoration agrees with resident execution after the
same next quantum on the source corpus. Pending-response binding, current
envelopes and cross-host execution remain mandatory. Structural graph success
alone still grants no executable authority.
