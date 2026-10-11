# BPI3 stable-activation Program grammar

This development format directly encodes `activation.Program`. The implementation
is `src/data/program_image.zig` and `program_record.zig`; it neither builds nor
accepts predecessor Programs. The ordinary public compiler emits this format.

## Framing, primitives and identity

```
"ABL_BPI3"[8] | version:u16LE=3 | flags:u16LE=0 | body_length:u64LE | body
```

The length is exact. Padding, trailing data, unknown versions, nonzero flags and
other families reject. There is no fallback or negotiation.

`N` is minimal unsigned LEB128, at most ten bytes, representing `0..2^64-1`.
Overflow and overlong integers reject. `Bool` is one byte 0 or 1. `?T` is one
byte 0, or byte 1 followed by T. `B` is a natural byte length followed by raw
bytes. `Text` is B with valid UTF-8, without normalization. `[T]` is a natural
count followed by T records in order. **Every vector of IDs uses `IDs`, below,
instead of ordinary `[N]`.** Explicit enumeration tags are u32 values, not IDs,
and use ordinary `[N]` with each value bounded by `2^32-1`. Structs concatenate
the fields listed here. Tagged alternatives contain N(tag) then their fields.
There is no native padding, pointer, section directory, or fixed-size index.

Program identity is SHA-256 of the ASCII bytes `boundary.program/v3`, one zero
byte, then the complete canonical BPI3 image, including its 20-byte frame.
It is not a transport checksum or a predecessor identity. Catalog order and
nominal declarations are retained, even if names or contents happen to match.
Canonicality is deterministic structural form, not behavioral equivalence.

## Body and common records

The body is exactly these nine fields:

```
roots, [Schema], [Literal], [Effect], [Function], [Block],
[Handler], scopes, [Constructor]
```

Roots is `(profile:N=1, entry:N, result:N, failure:N)`. Only profile 1 is
implemented. Catalog IDs are zero-based indexes into their named catalogs.
Scopes is `(captures:[Capture], region_count:N, resources:[Resource])`.
Nominal region IDs are below region_count. No debug or private execution state
is encoded. Meaningful catalog order is preserved; effects/regions declared as
sets must be sorted and unique. Ordered parameter, capture, handler-clause and
evidence lists retain their order and their existing uniqueness rules.

Use tags: reusable=0, affine=1, linear=2, multi=3. Mode: deep=0, shallow=1.

| Record | Fields in order |
| --- | --- |
| Effect | identity:Text, payload:N, result:N, use_site_effects:IDs, bodies:IDs, control_use:Use, external:Bool |
| Clause | effect:N, function:N, resumption:N, strategy:N |
| Handler | mode:Mode, input:N, answer:N, return_function:N, clauses:[Clause], reserved:u8=0, state:IDs, effects:IDs |
| Capture | fields:IDs, owned_regions:IDs, borrowed_regions:IDs, use:Use |
| Resource | representation:N, introducers:IDs, eliminators:IDs |
| Constructor | function:N, capture:N, schema:N |

Effect identities are nonempty UTF-8, but text equality grants no nominal
authority. Admission derives ownership, effect, region and borrow facts from
these records and code. Clause strategy is general=0 or total-tail=2; the
predecessor straight-line flag 1 rejects. Total-tail requires deep, linear
handling with no higher-order operation bodies. Its function receives state and
payload, returns the operation result, has only copyable slots and no residual
effects, and has an acyclic CFG of total instructions, branches, product/sum
elimination and returns. Admission derives these properties from the actual code;
a stored strategy is not proof. The independent Clause golden is `03 04 05 02`
(effect 3, function 4, resumption schema 5, total-tail).

### Schemas

| Tag | Name | Payload |
| --- | --- | --- |
| 0, 1 | unit, boolean | none |
| 2, 3, 4, 5 | i8, i16, i32, i64 | none |
| 6, 7, 8, 9 | u8, u16, u32, u64 | none |
| 10, 11 | bytes, text | none |
| 12, 13 | product, sum | field/variant schema IDs:IDs |
| 14 | seq | element:N |
| 15 | vector | element:N, maximum:N |
| 16 | internal | Internal below |
| 17 | array | element:N, length:N |
| 18, 19 | bounded_bytes, bounded_text | maximum:N |
| 20 | enumeration | sorted unique tags:[N], each u32 |

| Internal tag | Name | Fields in order |
| --- | --- | --- |
| 0 | computation | parameters:IDs, result:N, effects:IDs, capture_bound:IDs, use:Use, regions:IDs |
| 1 | capability | effect:N |
| 2 | cell | element:N, region:N |
| 3 | region | region:N |
| 4 | resumption | effect:N, input:N, answer:N, effects:IDs, capture_bound:IDs, handled:IDs, escaping:IDs, mode:Mode, use:Use, owned_regions:IDs, obligations:Bool |
| 5 | suspension_package | resumption:N |
| 6 | abstract_resource | resource:N |
| 7 | borrowed | value:N, region:N |

### Constants and external values

Literal is `(schema:N, length:N, payload)`. For length 8 only, payload begins
with mode byte 0 for eight raw bytes or 1 for an N holding the unsigned
little-endian bit pattern. Use mode 1 exactly when N uses fewer than eight bytes.
Otherwise use mode 0. Other lengths store exactly length raw bytes, no mode.

Value bytes are schema-directed: unit empty; Bool one byte; integers exactly
their declared width, little endian, signed two's complement; bytes/text B/Text;
products concatenate fields; sums N(variant) then payload; seq/vector N(length)
then elements; arrays exactly their declared number of elements with no count;
bounded bytes/text use B/Text; enumerations use a u32LE declared tag. Empty
enumerations admit no value. Bounds and UTF-8 are checked. Internal schemas
cannot cross external value boundaries. Recursive references must be guarded.

### Canonical ID vectors

IDs starts with N(count). Zero has no payload. Counts one and two have exactly
that many N values. Larger counts have a byte mode: 0 for literal N values,
1 for flat segments whose positive counts total exactly count:

| Segment byte | Following fields |
| --- | --- |
| 0 | N(count), that many N values |
| 1 | N(count), one N repeated count times |
| 2 | N(count), starting N; ascending by one without overflow |

The canonical writer at each offset measures the maximal equal and ascending
runs (ties select equal). It selects that run only if count is at least three
and its segment byte, count and value cost strictly less than the literal values.
Otherwise it starts a literal segment and extends it until the next position
starting three equal or ascending values, or the end. It selects segmented mode
only if all segments together are strictly smaller than all literal values;
ties select literal. The decoder re-emits to reject other spellings. Segments
are nonrecursive and have no shared-backing or predecessor-interface references.

## Stable code

Function begins with a flags byte (bits 0 effects present, 1 regions present,
2 custody present), then `(entry:N, inputs:IDs, layout_slots:IDs, result:N)`.
Flagged fields follow in effects, regions, custody order. Effects and regions
default to empty. Custody is `[CustodyScope]`, each `(parent:?N)`, and defaults
to the singleton root with no parent. Flags must omit these exact defaults.
Unknown flag bits reject. Parent indexes precede their children, with one root.

Inputs are ordered actual argument destinations. Layout_slots maps every
function-local slot to its schema. It is not a block-live interface. Instruction
destinations, reads, simultaneous edges, initialization and ownership are checked
against the owning function and exact control/instruction position.

Block begins with a flags byte (bit 0 function present, bit 1 custody present).
Flagged `(function:N, custody:N)` follow, then `[Instruction], Terminator`.
An omitted function repeats the preceding block's function, initially zero.
Omitted custody is zero. Equal-to-default fields must be omitted. The previous
function changes after each block and has no relation to runtime execution order.

Edge is `(block:N, header:N, assignments)`. Header 1 is exactly one returned
assignment followed by its destination:N. Otherwise the header is twice the
assignment count; each assignment is `(destination:N, source:N)`, where source
zero means returned and source n+1 means slot n. Other odd headers reject.
The single-return case must use header 1. Ordered assignments are simultaneous;
unmentioned bindings retain their current activation view. Duplicate
destinations reject. No predecessor pass-through interface is materialized.

### Instructions

The header is exactly **one byte**: opcode in bits 0–5, immediate-present bit 6,
failures-present bit 7. It is followed by destination:N, operands, then flagged
immediate:N and failure constant IDs. Zero immediates and empty failures must
omit their flags. Opcode values 48–63 reject.

Operands have no count for these opcodes:

| Count | Opcodes |
| --- | --- |
| 0 | 0 |
| 1 | 1, 8, 24, 25, 26, 30, 34, 35 |
| 2 | 2, 3, 4, 5, 6, 7, 29, 31, 32, 33 |

Those operands are exactly count N values. All other opcodes use IDs. Result
schema comes from the destination's layout slot and is never encoded here.

| Opcode | Operation |
| --- | --- |
| 0–8 | constant, move, integer_add, integer_sub, integer_mul, integer_div, equal, less, boolean_not |
| 9–19 | product, field, variant, variant_tag, variant_payload, sequence, sequence_length, sequence_get, sequence_append, sequence_concat, sequence_pop |
| 20–28 | computation, cell_new, cell_get, cell_set, clone_resumption, package, unpack, resource_pack, resource_unpack |
| 29–35 | integer_rem, integer_bit_not, integer_bit_and, integer_bit_or, integer_bit_xor, integer_convert, enum_tag |
| 36–47 | blob_length, blob_concat, blob_slice, blob_compare, blob_byte, text_scalar, text_integer, sequence_set, sequence_take, blob_from_byte, sequence_pop_last, select |

When failures are present their count/kinds are implied, except blob_slice,
which first stores N(count), one for bytes or two for text. Each following N
names a constant of the root failure schema. Add/sub/mul/convert use overflow;
div/rem overflow then division-by-zero; variant_payload invalid-variant;
sequence_set invalid-index; sequence_append/concat and blob_concat capacity;
blob_slice capacity then invalid-UTF8; text_scalar invalid-UTF8. Convert omits
failure when its admitted source range fits the target; sequence append/concat
omit failure for unbounded sequences. Other opcodes cannot carry failures.
Admission checks the exact required shape, types, authority and immediate meaning.

### Terminators

All slot fields are function-local slots. Bodies, cleanup and computations
below are slots containing computation values, not function IDs.

Perform is `(effect:N, capability:?N, payload:N, bodies:IDs,
use_site_capabilities:IDs, next:Edge)`.

| Tag | Name | Fields in order |
| --- | --- | --- |
| 0 | return_value | slot:N |
| 1 | jump | Edge |
| 2 | branch | condition:N, when_true:Edge, when_false:Edge |
| 3 | switch_variant | value:N, cases:[Edge] |
| 4 | unpack_product | value:N, destinations:IDs, next:Edge |
| 5 | call | function:N, arguments:IDs, next:Edge |
| 6 | perform | Perform |
| 7 | yield_value | Edge |
| 8 | fail | slot:N |
| 9 | apply | computation:N, arguments:IDs, next:Edge |
| 10 | handle | handler:N, body:N, arguments:IDs, state:IDs, next:Edge |
| 11 | resume_value | resumption:N, argument:N, next:Edge |
| 12 | resume_with | resumption:N, argument:N, handler:N, state:IDs, next:Edge |
| 13 | resume_computation | resumption:N, computation:N, next:Edge |
| 14 | retired; rejects | — |
| 15 | dispose | owned:N, next:Edge |
| 16 | protect | body:N, cleanup:N, arguments:IDs, resource:?N, loan_region:?N, next:Edge |
| 17 | with_region | region:N, body:N, arguments:IDs, next:Edge |

Tag 14 is retired and rejects during decoding. Handler records retain a mandatory
zero byte at the retired optional-field position, preserving every previously
accepted BPI3/BMO1 encoding. There is no corresponding public constructor or
handler field. Forwarding uses explicit older-capability dispatch.

## Owners, limits and failure safety

`encodedLength` sizes borrowed records without granting admission. `encode`
performs full stable admission, sizing, capacity and recursive borrowed-storage
overlap checks before writing any output. `identity` also performs admission.

`decode` copies input, checks framing, reads records, performs full stable
admission and checks canonical bytes by re-emission. Its returned owner contains
all record and literal storage and survives caller input overwrite/free. On any
failure, all partial owners are released. The default physical decoded-storage
budget is 64 MiB; `decodeLimited` takes an explicit `max_decoded_bytes`.
It charges owned input plus requested expanded record/ID/literal bytes before
each allocation. Arithmetic overflow rejects, and compressed descriptors are
validated before expansion. The budget is not a semantic collection bound, peak
RSS estimate, or a cap on the separate admission scratch allocator.

Independent scalar and unit goldens are in `program_image_tests.zig`. Tests also
cover truncations, wrong framing, redundant-default rejection, compressed
expansion limits, output overlap/capacity, allocation failures and all 37 staged
generalized-effects example round trips. Kosmos source agreement executes images
after their input storage has been overwritten and released.

`Admitted.decode` provides a separate opaque immutable admission owner for
reusable preparation. It retains the same decoding pass's control-flow facts,
plus read-only schema, use and effect facts. It accepts bytes only; callers cannot
install a mutable Program/facts pair or assert trusted status. Ordinary `decode`
still returns record ownership and releases its temporary analysis.

An admitted owner creates private analysis overlays that borrow its original
maps. Lookup crosses at most one immutable base, and new set nodes belong to the
consumer; no whole-pool copy or chain of predecessor versions is introduced.
The owner must outlive these borrowed overlays. Kosmos establishes that lifetime
through strong session references. `validateAdmitted` checks State against that
opaque owner without re-admitting or re-hashing its Program. State graph, scope,
borrow and ownership checks remain required on every incoming checkpoint.
