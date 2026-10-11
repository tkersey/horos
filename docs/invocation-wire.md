# Current invocation and external-interaction envelopes

`data/invocation.zig` defines PKI3, PKO3, ERQ3 and ERS3. Kosmos executes them
through the public stable Session evaluator and generic ABI 3 kernel.

## Framing and records

Every envelope has an eight-byte ASCII magic (`ABL_PKI3`, `ABL_PKO3`, `ABL_ERQ3`
or `ABL_ERS3`), little-endian u16 version 3, u16 reserved flags zero, and u64
exact body byte length. Other families, versions, flags and trailing bytes reject.

`N` is minimal unsigned LEB128 bounded by u64, at most ten bytes. `B` is N(length)
followed by bytes. `Hash` is exactly 32 bytes. `?T` is byte 0, or byte 1 followed
by T. Tagged alternatives are N(tag) and their payload. Records concatenate the
listed fields without padding. Reason tags are text=0 with UTF-8 B, bytes=1 with B.

PKI3 is `(image:B, instance:Instance, control:Control, quantum:?N)`.

| Type | Tag | Payload |
| --- | --- | --- |
| Instance | 0 initial_args | B |
| Instance | 1 state | complete PST3:B |
| Control | 0 none | none |
| Control | 1 reply | complete ERS3:B |
| Control | 2 resume_yield | none |
| Control | 3 cancel | Reason |

The image must be admitted BPI3 before execution. Initial arguments reject reply
and resume_yield. Cancellation may start before the first instruction. Runtime
status determines whether control is applicable; terminal Sessions reject replies,
resume_yield and cancellation.

`none` runs active/unwinding work and polls parked/yielded/terminal work. Polling
never consumes a yield. Null quantum runs to a public boundary; a numeric quantum
bounds instruction/control transitions. Control is applied first, including with
zero quantum: a valid reply creates its successor position, resume_yield clears
the yield, and cancellation starts or updates unwind. Zero then observes that
state without executing an instruction/control transition. It is not an authored
failure or stop request.

| PKO3 tag | Outcome | Payload |
| --- | --- | --- |
| 0 | progressed | checkpoint:?B |
| 1 | requested | checkpoint:?B, ERQ3:B |
| 2 | yielded | checkpoint:?B |
| 3 | completed | typed result:B |
| 4 | failed | typed failure:B, cleanup_failures:B, cancellation:?Reason |
| 5 | cancelled | Reason, cleanup_failures:B |
| 6 | needs_capacity | Capacity |

A present checkpoint is complete canonical PST3. Fresh invocation always supplies
it on incomplete outcomes. Resident drive omits it by default, and supplies it
when explicitly requested. Absence is not a portable recovery unit or a promise
of durability; the resident owner remains required until checkpoint export.

Cleanup failures contain N(count) followed by each typed failure as B, in order,
under the Program's root failure schema. Capacity is `(arena:N, input:Bound,
working:Bound, output:Bound, memory_pages:Bound)`. Arena tags are input=0,
working=1, output=2, memory=3. Bound is `(amount:N, provenance:N)`, with
not_observed=0, exact=1, lower_bound=2. Not-observed amounts must be zero. The final
field counts pages; others count bytes. Capacity is an operational report, never
an authored failure or evidence of a published successor.

ERQ3 is `(Binding, request_identity:Hash)`. Binding is:

```
program_identity:Hash, pending_state_digest:Hash, effect:N,
semantic_identity:B, payload_schema:B, resume_schema:B, payload:B
```

Effect is the nominal Program catalog ID. Its nonempty UTF-8 name does not replace
that identity. Schemas are self-contained canonical structural descriptors: root
N=0, then a counted Schema catalog with the [declared schema fields](bpi3-wire.md),
using ordinary counted ID lists, not BPI3's compressed vectors. They retain the
existing external value grammar and canonical type equivalence, with no outer
frame. Internal handles cannot cross this boundary. Descriptor decoding has a
configurable physical record-storage budget, default 64 MiB.

ERS3 is `(request_identity:Hash, value:B)`. Identity already binds the resume
schema, so no second schema hash is needed. Value is checked under that descriptor.

## Binding, ownership and evidence

State digest is SHA-256 of ASCII `boundary.pending-state/v3`, a zero byte, and the
complete canonical PST3 bytes. Request identity is SHA-256 of ASCII
`boundary.effect-request/v3`, a zero byte, and Binding's exact record bytes.
It excludes itself. PST3 contains no derived request digest, avoiding self-reference.

PST3 includes continuation position, live values, handlers, resources and cleanup.
Its Program identity binds code and contracts. Repeated polling/export/restoration
preserves identity; changed captures or cancellation context change it. The runtime
reconstructs the expected request from its own pending Session before accepting
ERS3. A caller's self-consistent ERQ3 does not establish that runtime binding.

Cancellation can change the challenge while retaining the same cleanup operation
and payload. A host with an already obtained typed result may explicitly encode
it against the successor challenge. The runtime does not repeat the operation,
silently rebind old bytes, or claim global exactly-once execution.

`decode` owns input before trusting contents, with a configurable 64 MiB default
input budget. Returned slices belong to that owner. `encode` validates, sizes,
and checks capacity/overlap before writing. Failure releases partial owners.
Fresh Kosmos invocation owns input, executes privately and publishes no successor
on operational failure. Failed output allocation/capacity leaves the command reusable.

Horos tests cover independent PKI3 bytes, ownership, stale binding, typed
replies, flags/families, atomic output and allocation failures.
`zig build check-invocation-wasm -Doptimize=safe` checks independent bytes
for all four families and a JavaScript-computed request hash on import-free wasm32.
Kosmos compares fresh, resident and restored execution at matching quanta, retaining
the source corpus's independent expectations. Tests distinguish identical visible
requests with different captures, stale replies, explicit yields, zero quanta and
cancellation during pending cleanup. Fresh allocation-failure sweeps preserve
commands and output. Native prepared lifetimes retain immutable admitted data
across sequential starts and restores. Resident transactions preserve entry State
on drive/output failure, with checkpoint publication optional. ABI 3, cross-host
execution, Protean migration and final public cutover remain mandatory.
