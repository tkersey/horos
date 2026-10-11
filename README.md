# Horos 3

Formerly Boundary; see the [rename notes](docs/rename.md).

Horos checks staged Zig computations and handlers and compiles them into
portable BPI3 program data. Kosmos 6 executes that data with one generic native/WASM
interpreter. Horos contains no production evaluator.

Horos `4.0.0-dev.0` requires Zig `0.17.0`. The public modules are `horos` for
authoring and `horos_data` for data-only admission and linking. This version
uses BMO1 components, BPI3 programs, PST3 states and ABI 3; the major package
version does not introduce another wire format. See the
[current verification](.github/workflows/zig.yml).

## Author and compile

Import the Zig build module `horos`. Use `authoring` for ordinary construction,
`program` for compilation, `data` for portable records, and `library` for reusable
compositions. The `effect`, `handler`, and `region` raw-Builder facades have been removed.

Start with the [typed structured authoring guide](docs/typed-authoring.md) and
`horos.authoring` for named values, forward sequencing and derived handlers.
The [Horos 4 migration guide](docs/authoring-migration.md) covers the source break.

An application implements `emit(builder)` using the checked staged builder.
`horos.program.lower(allocator, Application)` compiles that application;
`horos.program.compile(allocator, module)` compiles an already constructed
source module. Both use the same stable-slot compiler. The returned owner must
be deinitialized; it owns the emitted records and derived flow facts independently
of the source builder. `compiled.encode(allocator, destination)` emits BPI3 into
caller-owned storage. Arbitrary native Zig function bodies are not translated.

`program.compileObserved` additionally accepts caller-owned diagnostics and a
phase observer. Diagnostics identify source variables or target calls and scopes
where applicable. Observation does not change emitted bytes. The compiler checks
the original target before specialization and the final target after normalization.

[Whole-program coalescing](docs/coalescing.md) shares checked code and immutable
descriptions automatically during compilation and final linking. The retired
mode selector is rejected. Diagnostics and bounded discovery remain available.

The [public example](examples/one_effect.zig) compiles without a runtime:

```sh
zig build emit-one-effect -Doptimize=safe > example.bpi3
```

Its initial argument and result are canonical little-endian `u32` values. Kosmos
returns a typed `example.lookup.v2` request, and the environment supplies its
result. Application handlers, search, scheduling and cleanup remain Program code.

`library` provides State, Reader/local, Writer, Raise/catch, answer-transforming
choice, first/all results, DFS/BFS search, owned generators and FIFO cooperative
scheduling. Typed bodies provide `protect` and `bracket`. Ownership, borrowing, nominal identities, failure
order and cleanup remain checked. Stable slots retain earlier bindings without
copying them into every intermediate continuation interface.

Choice, Search, State, Reader, Writer and Raise families use an `authoring.Context` and typed handles.
Choice/Writer/Raise expose `effect()` and `capability()`; State exposes `get()`, `put()`
and their capability schemas. Interpretations return typed handler and answer
handles. Repeated interpretations share definitions
without merging distinct named schemas. The
[Writer/Raise example](src/source/writer_raise_example.zig) includes typed cell
allocation, logging, abortive catch and protected cleanup.

`CaptureBounds` separates retained continuation values from the callable body's
captures. These bounds have different effect-scope meanings; admitting a captured
capability to a continuation does not give the body access to an older handler.
`Context.handlerSet` constructs one handler with named capabilities and multiple
clauses sharing its state and return arm. Select each clause or resumption schema
by operation with `clauseFunctionFor` or `resumptionSchemaFor`.
Use `body_parameters` and `handleWithArguments` for named inputs after the supplied
capabilities; handler state remains a separate named argument group.
Choice's `all` and `first` use the same typed `Options`, including separate owned
and borrowed regions. The [State/Choice examples](src/source/state_choice_example.zig)
exercise local versus shared state and mutually recursive work through that API.

`Context.resource` declares a nominal resource; `resourceAuthority` selects its
representation introducers and eliminators. `Body.packResource` and
`unpackResource` emit accesses checked by that authority. `Body.bracket` transfers
the owner to cleanup and gives its body a scoped loan. The
[resource example](src/source/resource_example.zig) runs one typed client against
scalar and structured representations. `library.cleanup.exitInfo` remains a
schema helper for explicit source-IR construction; typed code uses `cleanupInfo`.

Recursive interfaces use `declareSchema` and typed definitions. A declaration is
bound once, retains its named metadata through cycles, and must be complete before
module publication. `HandlerOptions.resumption_slots` lets handler construction
complete declared tokens for mutually retaining clauses. Reader/local uses these
declarations in the [scoped forwarding example](src/source/scoped_reader_example.zig).

Owned generators and bidirectional child exchanges share one Horos constructor.
Its recursive answer, linear package and handler use checked typed declarations.
Reusable child-dialogue constructions use this same mechanism.
Exchange composition now uses typed matching, package consumption and recursive
calls. A terminal identity binding is normalized by `Body.ret` without moving
intervening work.

Search uses `family`, `interpret` and typed `collect`, with explicit DFS/BFS
worklist order. The [queens example](src/source/queens_example.zig) uses typed
sequence queries, integer ordering, scoped cells and resource cleanup throughout.
Lowering keeps straight-line copyable value bindings in one block while retaining
owned custody boundaries, named provenance and statement-level evaluation order.

## Pure data and components

Use the separate build module `horos_data` for schemas, stable Program/State
records, codecs and admission. A dependency selecting `.@"data-only" = true`
constructs only that module; it does not build authoring, oracle or formal targets.
Current formats are [BPI3](docs/bpi3-wire.md), PST3 and the ABI 3 interaction
contracts. Versioned facade aliases have been removed.

[Separately compiled BMO1 components](docs/bmo1-components.md) carry explicit
interfaces and checked borrow contracts. The data-only `horos-link` tool
resolves instance bindings and emits an independently admitted closed BPI3 image,
without component source or emitters.

## Validation and native dependencies

`zig build check-native -Doptimize=safe` runs authoring/data tests and native CLI
checks. `zig build check-package -Doptimize=safe` checks the real exported package
and public modules from a fresh external consumer. Neither path needs an
interpreter. Ordinary imports and `build-compiler` use only Zig's package/build
mechanisms and the standard library.

`zig build check -Doptimize=safe` adds the independent source oracle and focused
wasm32 byte/identity checks. These are the only JavaScript responsibilities kept:
higher-order interpretation and its exact-value helper/cases, plus foreign-ABI
observations. They are explicit verification dependencies, never native import,
authoring, or data-only linker prerequisites.

The old timing/platform/economy/search/report campaigns and exclusive generators
are removed. Native language and optimizer tests remain; removing a campaign does
not redefine language semantics or establish a performance improvement. Published
release artifacts are unchanged. The next coordinated consumers use the actual
successor source/package hash, not a relabeled release.

See [.github/CI.md](.github/CI.md) for source preflight, package checks and caching.
