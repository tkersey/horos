# BMO1 components and source-independent linking

`source.component.compile` uses the stable-activation compiler to produce a
relocatable object. `horos_data.component.decode` checks its first-order
records. `horos_data.linker.link` binds objects and independently admits a
closed BPI3 Program. The linker neither runs source emitters nor executes code.
The current namespaces are `horos` for authoring and `horos_data` for
object admission and linking.

## Format

```
"ABL_BMO1"[8] | version:u16LE=1 | flags:u16LE=0 | body_length:u64LE | body
body = ProgramRecords | [Symbol] imports | [Symbol] exports | [BorrowSummary]
Symbol = name:Text | kind:N | id:N
BorrowSummary = function:N | [Projection] returned | [Requirement] | [Write]
Projection = source:Source | [Step] path
Source = input(0, ordinal:N) | ambient(1, component:N)
Requirement = value:Projection | owner:Projection | bound:N
Write = cell_schema:N | [Projection] sources
```

`ProgramRecords` is exactly the body grammar in [BPI3](bpi3-wire.md), without
its frame. Symbols use ordinary length-prefixed lists and minimal unsigned
LEB128 naturals. They do not use the Program's compact ID-vector encoding.
Names must be nonempty UTF-8 and each symbol list must be strictly sorted by
name bytes. Imports cannot repeat the same local reference. Exports may give
several distinct names to the same declaration.

Kind tags are schema=0, constant=1, effect=2, function=3, block=4, handler=5,
capture=6, region=7, resource=8, constructor=9. Every reference is checked against
its catalog. Constant, block and capture imports are unsupported and reject.
All ten kinds may be exported; executable entry selection requires a function.

An imported function has no blocks, has exactly its parameter slots, and has
entry `2^64-1`. Other functions have ordinary local entries. The object root is
a locally defined compilation entry whose parameters/result may be internal;
it is not an executable claim. Its failure schema is the component's failure
contract. A closed link requires one compatible failure contract across every
instance. Bodyless imports cannot enter BPI3 admission.

Decoding owns its input, checks all local records, and compares canonical
re-emission. Unknown families/versions/flags, trailing bytes, overlong integers,
invalid references and malformed symbols reject. Wire plus decoded-record
storage follows the caller's allocator and representable sizes. The compile-work
policy retains a total catalog-entry limit
of 1,048,576 per object and per link, including declared regions; a tiny region
count field cannot request an unbounded relocation table. Analysis scratch is
additional caller-allocated memory and can fail with `OutOfMemory`.

Component identity is SHA-256 of `boundary.component/v1`, one zero byte, and the
entire canonical BMO1 image. It is distinct from linked Program identity.

## Bindings and identity

An instance is an explicit nonempty UTF-8 key plus BMO1 bytes. Duplicate keys
reject. A binding names an importing instance/symbol and an exporting
instance/symbol. Every import resolves exactly once. Aliases are followed
iteratively with a finite bound; cycles without an implementation reject.
Mutually recursive function bodies may reference each other's concrete exports.

Instances are sorted by key bytes before catalog allocation. Concrete local
records retain local order. Relocation follows typed record fields, including
schema references, constants, effect/region/resource identities, functions,
blocks, constructors, captures and handler clauses. Slots, custody IDs and
immediate field/variant ordinals remain local. Ordered signatures and evidence
lists preserve order; set-valued rows are sorted and deduplicated after binding.

Private nominal declarations remain distinct between instances. Explicit imports
alone unify them. Structural schema partitioning then merges equal relocated
shapes while preserving those nominal distinctions. Filesystem paths and input
enumeration order do not participate. Keys determine ordering and sharing;
their spelling is not independently hashed into the closed Program. Renaming
keys while preserving the same ordered records and bindings can retain identity.

The linker compares parameter/result schemas, residual effects, regions,
callable/resumption use and capture schemas, handler contracts and constructor
captures. Resource imports cannot declare introducer/eliminator authority;
representation compatibility is checked and only defining-instance function
identities receive those rights. Full closed type/effect/use/borrow admission
runs after relocation. Names, hashes and interface summaries do not bypass it.

The object checker validates local types, effects, regions, ownership and capture
bounds, then solves every local borrow query under explicit import assumptions.
Missing imported-function contracts reject; unknown effects never imply an empty
borrow contract. The source compiler derives exported guarantees from the code.
Each function mentioned directly or through an imported/exported handler or
constructor must have a summary. Summaries are strictly ordered by function ID;
write rows are strictly ordered by cell schema ID. Additional local guarantees
are checked even when their code is unreachable from the selected root.

Input sources use call-interface ordinals, not activation slots. Ambient evidence
and region have tags 0 and 1. Requirement bounds region/clause/capture have tags
0/1/2. Paths use the borrow solver's ordinary tagged projections: field(0, N),
element(1), environment(2, constructor:N, field:N), handler_state(3, handler:N,
field:N), use_site(4, index:N, schema:N), cell_content(5), package_token(6),
outer(7, optional ambient), resumed(8, optional ambient), body_result(9, schema:N).
Optional values encode a 0/1 presence tag followed by the value when present.
Every selector is checked against its input schema and every catalog reference
is relocated by kind. Ambient sources have no path.

Returned and written sources bound the whole result, conservatively including
all its projections. A declared input subtree may cover a narrower actual
dependency. Outlives requirements keep both projections and the bound exactly;
widening an owner is not a valid lifetime proof. Whole-result bounds can reject
a safe client that relies on more precise field-specific imported behavior.
This is a precision limit, not permission to omit a dependency.

The linker independently derives guarantees from the complete relocated code
and checks each assumption. Imported handlers and constructors also check the
actual selected functions, not just their local signature placeholders. Tests
cover a protected borrow passed through an import, false result provenance,
hidden cell writes, missing outlives requirements, malformed projections, and
handler/constructor substitution. Full closed Program admission remains required.
The previous per-function deferral path has been removed. This development BMO1
grammar includes the contract table; objects emitted before it must be rebuilt.

## Standalone use and witnesses

The manifest contains `instances`, `bindings`, and `entry`. An optional `contract`
selects `"structural"` (the default) or `"semantic"`. The semantic contract runs the
shared record optimizer after every original object, interface and borrow guarantee
has been checked. Both contracts invoke mandatory checked P01; neither is an
optimization-off selector. Linking applies
the canonical optimizations automatically where their preconditions hold.
The retired `coalescing` selector is rejected; it cannot disable the pass.

The same manifest forwards `objective` (`size`, `balanced`, or `speed`),
`work_limit`, `round_limit`, `image_growth_bytes`, and `max_image_bytes` to shared
closed compilation. Omitted fields retain the shared API defaults. These bound
semantic search/selection; mandatory P01 retains its own checks and budget.
An optional `profile` uses the shared `ProfilePolicy` JSON shape (`record`,
`target`, and optional candidate limits). The record's version, toolchain identity,
32-byte image identity, original block counts and total are checked against the
original closed linked program. Its IDs are never interpreted against an optimized
or relocated candidate.
A stale profile rejects; it cannot establish semantic facts. No policy is stored
in the emitted program or state image.

```
zig build build-compiler
zig-out/bin/horos-link link.json > application.bpi3
zig build check-components
```

The linker executable imports only Horos's pure data module. It accepts one
JSON manifest; instance paths are relative to its working directory:

```json
{
  "instances": [
    {"key":"client","path":"client.bmo1"},
    {"key":"library","path":"library.bmo1"}
  ],
  "bindings": [
    {"required":{"instance":"client","symbol":"read"},
     "supplied":{"instance":"library","symbol":"read"}},
    {"required":{"instance":"client","symbol":"value"},
     "supplied":{"instance":"library","symbol":"value"}}
  ],
  "entry":{"instance":"client","symbol":"main"}
}
```

`zig build check-components` uses one native driver to construct objects, transport
the data-only linker, check deterministic binding order, admit its BPI3 output
through the canonical consumer, and reject obsolete coalescing selectors.
The linker process receives only objects and a manifest; it never runs a source
compiler. Full component semantics remain in the shared native test roots.
