# Defunctionalized hyperfunctions and recursive interaction

Typed authoring for the recursive-interaction design in user specification v1.1
(September 19, 2026). The original incomplete milestones remain in the
[Boundary draft](https://github.com/tkersey/boundary/pull/153) and
[Agent companion](https://github.com/tkersey/agent/pull/33).

## Pure meaning and public operations

The pure core uses explicit call-by-name delays, including endpoint values.
The rest of Horos remains strict. Native Zig builders construct source; no
native closure is serialized or called by Kosmos. Runtime recursion may remain
nonproductive, and work-quantum exhaustion is never an authored result.

In lazy semantic notation:

```
invoke(make(body), peer) = body(peer)
invoke(base(value), peer) = value
invoke(push(f, tail), peer) = f(invoke(peer, tail))
invoke(compose(left, right), peer) = invoke(left, compose(right, peer))
lift(f) = push(f, lift(f))
identity = lift(id)
run(h) = invoke(h, identity)
project(h, x) = invoke(h, base(x))
invoke(ana(step, s), peer) = step(s, next -> invoke(peer, ana(step, next)))
```

`library.hyper` supplies the canonical typed interface. `A`, `B` and `S` below
are retained authoring shapes. `Hyper(A, B)` is a callable with named parameter
`peer: Delayed(Hyper(B, A))` and result `Delayed(B)`. A `Pair(A, B)` provides the
reciprocal callable and delay schemas. Its accessors are `input()`, `output()`,
`forward()`, `backward()`, `peerForward()`, `peerBackward()`, `answerForward()`,
`answerBackward()` and `swap()`.

| Operation | Typed construction |
| --- | --- |
| `pair(c, a, b, options)` | Opaque reciprocal family with explicit `captures` |
| `group(c, endpoints, options)`, `group.get(from, to)` | Named finite family of compatible reciprocal interfaces |
| `delayed(c, result, options)` | Pure zero-argument callable schema retaining `Delayed(Result)` |
| `deferValue(body, delay_schema, value)`, `force(body, delay)` | Wrap an existing value; demand one pure result layer |
| `make(body, pair, function)` | Wrap a typed function matching `pair.forward()` |
| `invoke(body, participant, delayed_peer)` | Return `Delayed(B)` without demanding the participant or peer |
| `base(body, pair, delayed_b)` | Constant participant that ignores its peer |
| `push(body, pair, transform, delayed_tail)` | Transform a delayed counterpart answer and retain the delayed H(A,B) tail |
| `lift(body, pair, transform)`, `identity(body, pair)` | Tie the recursive tail; identity requires compatible A and B |
| `compose(body, group, from, middle, to, left, right)` | H(B,C) × H(A,B) → H(A,C), retaining reciprocal paths |
| `run(body, pair, participant)`, `project(body, pair, participant, delayed_a)` | Return `Delayed(B)` through identity or a constant counterpart |
| `ana(body, pair, state_schema, emitter)`, `start(body, definition, state)` | Author one configured definition, then construct runtime participants |
| `query.ask(body, delayed_successor)` | Return `Delayed(A)` with an explicit pure successor delay |
| `demand.family/request/interpret/handle` | Lexical typed Need requests interpreted as counterpart task calls |
| `lazyProduct(body, fields)`, `lazySum(body, alternatives, name, payload)` | Named aggregate observations without forcing delayed payloads |
| `stream(c, element, options)`, `cons`, `emptyStream` | Typed delayed elements and successor spines |

These operations use ordinary `Schema`, `Value`, `Function`, `Body` and
`Computation` handles. Calls that construct runtime work append it to the supplied
body and return typed values. Raw source IDs and manual term binding are not part
of ordinary hyperfunction authoring. `run` requires equal endpoint contracts;
`project` permits distinct endpoints. Composition with lifted maps supplies
checked endpoint adaptation. The complete public
[`hyper_client.zig`](../examples/hyper_client.zig) emits an ordinary BPI3 image.

## Delayed transforms and successor state

`push` and `lift` take an ordinary typed Function with named parameter
`argument: Delayed(A)` and result `Delayed(B)`. The function is pure; demanding its
argument is explicit. For equal u64 endpoints, an increment transform can be
written with the ordinary authoring operations:

```zig
const types = try hyper.pair(c, integer, integer, .{});
const increment = try c.function(
    "increment", .{ .argument = types.answerBackward() }, types.answerForward(), .{},
);
const transform = try c.body(increment);
const argument = try transform.parameter("argument");
const answer = try c.functionFor("increment answer", types.answerForward());
const delayed = try transform.closureBody(answer);
const value = try hyper.force(delayed, argument);
const result = try delayed.checkedAdd(
    value, try delayed.constant(u64, 1), try c.literalFailure(void, {}),
);
try c.define(answer, try delayed.ret(result));
try c.define(increment, try transform.ret(try transform.lambda(answer, types.answerForward())));
const lifted = try hyper.lift(body, types, increment);
```

The increment and its possible overflow occur only when the returned answer is
forced. `deferValue(body, schema, value)` instead captures a value already produced
in `body`: wrapping an earlier `force`, effect or checked arithmetic does not
move that work into the delay. Use `functionFor`, `closureBody`, `define` and
`lambda` when the work itself must remain delayed. `force` checks that the actual
callable has no parameters, effects or region requirements.

`ana` calls the supplied instance's `emit(step_body, query)` once for each
authoring call. The method returns a `Computation(Delayed(B))`; it can access
`query.state()` and `query.types()`. Runtime emitter configuration and authored
captures belong to that invocation. The Zig emitter type is not a cache key.
Keep the opaque `Ana(S, A, B)` and call `start` to reuse its maker without emitting
new bodies. The step may author zero, one or several adaptive queries and
non-tail work. Runtime states and exchange histories do not expand native code.

`query.ask` accepts a `Delayed(S)`, not an already-computed successor state. It
constructs a delayed reply and defers successor forcing, participant construction
and counterpart invocation to their demand points. A counterpart may return a
constant without demanding the successor. To retain this behavior, put successor
calculation inside its zero-argument pure function; `deferValue` is sufficient
only when the successor is already available. Create its schema with
`hyper.delayed(c, state_schema, .{ .captures = ... })` before the pair and include
that schema and required state captures in the pair's capture bound.

The [demand fixtures](../src/hyper_cases.zig) distinguish an ignored reply, an
ignored successor and a demanded failing successor. The
[emission fixtures](../src/coalescing_hyper_cases.zig) author different runtime
configurations of one emitter type and reuse the retained definitions without
re-emitting their steps.

## Promised tasks and lexical Need

A task endpoint is an ordinary callable whose effects occur when it is applied.
Declare its typed promise before constructing the reciprocal pair, then complete
its capture contract with the pair's peer delays:

```zig
const Task = a.Internal(.{ .callable = a.Signature(
    native.Fields(&.{}, &.{}), a.Shape(u64),
) });
const task = try c.declareSchema(.callable, Task);
const state_delay = try hyper.delayed(c, integer, .{ .captures = .{integer} });
const types = try hyper.pair(c, task.schema(), task.schema(), .{
    .captures = .{ integer, state_delay },
});
try c.defineCallable(task, .{}, integer, .{read}, .{
    .use = .reusable,
    .captures = .{ integer, types.peerForward(), types.peerBackward() },
});
```

Here the runtime state is u64 and `read` is an ordinary external operation.
Publication still rejects an unfinished promise or a reusable task containing
exclusive ownership. The endpoint description has two stages:

```zig
const description = try hyper.invoke(body, participant, delayed_peer);
const task_value = try hyper.force(body, description);
const contribution = try body.apply(task_value, .{});
```

Obtaining the task does not perform its effects. Use `body.apply` to execute it;
`hyper.force` rejects effectful callables even if their static result shape is
identical to a pure delay. `hyper.invoke` checks the actual peer delay's purity
even when the participant ignores it.

`demand.family(c, name, state_schema, contribution_schema)` creates a nominal
local operation and capability. Its `state()`, `contribution()`, `effect()` and
`capability()` accessors retain those contracts. Family construction and ordinary
requests support exclusive state under the existing local-operation ownership
rules. Hyper interpretation creates the reusable successor-state delay where it
adapts the request; that construction retains its existing capture checks.
In a step, construct
`demand.interpret(body, query, need, result_schema, options)`, author work using
`interpretation.body()`, and call `demand.handle(body, interpretation, work)`.
The interpretation retains an ordinary response function that captures its
lexical peer and the actual step and completion values. `handle` constructs its
closure in the active task body and passes it through ordinary handler state;
the closed clause calls it with the payload and actual owned resumption. Each
response schema remains pending until the Context's ordinary source analysis
derives its actual free variables and checks them against the participant and
interpretation capture allowances. Publication completes that private bound;
unused entries in the allowance do not become closure captures. This also
supports completion values created inside the running task's region. Each
`demand.request(body, need, capability, state)` is an ordinary local operation:
the handler asks the counterpart, obtains its task, applies it and resumes the
requester with the contribution. `interpretWith` accepts a typed completion
emitter for explicit resumption or disposal.

Repeated requests and work after a request retain ordinary caller frames. Capture
bounds must cover values live across the suspension; projecting a field before
a request can retain that field independently of its enclosing record. Families
with the same display name remain distinct nominal capabilities. The
[task fixtures](../src/hyper_task_cases.zig) and
[nested Need fixture](../src/hyper_need_cases.zig) exercise these paths through
ordinary source construction.

## Composition and capture contracts

The compiler's existing computation contracts admit captures by schema. A
composition retains H(B,C), H(A,B), and its reciprocal H(C,A), and the nested call
rotates those endpoints. Independently declared narrow pair capture bounds need
not permit that rotation. `group` declares the shared finite type cohort before
participants are authored or independently compiled. It enumerates endpoint type
pairs, never endpoint values, runtime states, or exchange histories. A component
must share a compatible contract; unrelated contracts are not silently coerced.

```zig
const cohort = try hyper.group(c, .{ .input = byte, .middle = integer, .output = record }, .{});
const ab = cohort.get("input", "middle");
const bc = cohort.get("middle", "output");
const ac_value = try hyper.compose(body, cohort, "input", "middle", "output", bc_value, ab_value);
```

Names supplied to `get` and `compose` are compile-time selections. Known endpoint
mismatches, missing names and counterfeit group handles reject at Zig compilation.
The shared runtime owner checks actual schemas, captures and Context identity.
The only runtime selection boundary is `hyper.ir`: `from(group, known_from,
name)` retains A in `Pair(A, Dynamic)`, `to(group, name, known_to)` retains B in
`Pair(Dynamic, B)`, and `select(group, from_name, to_name)` returns
`Pair(Dynamic, Dynamic)`. Unknown runtime names reject. This boundary selects
checked group members; it does not expose a second raw constructor API.

`run` and `project` retain a participant's known answer shape when the selected
pair has a Dynamic output. When the participant's answer is Dynamic, checked
refinement uses the pair's output shape. Projection still checks the participant's
known input, and `run` requires matching input and output endpoints. Actual
reciprocal interfaces and capture contracts remain checked in both cases.

Each pair has ordinary callable and delay schemas. Composition uses three
mutually referring maker functions, declared before their bodies are defined.
There is no recursive native expansion, new opcode, wire format or interpreter.
Actual environments contain only the captures used by their bodies. Existing
fixed-point trait analysis and constructor checking remain authoritative; reusable
recursive wrapping cannot hide an exclusive capture. Group construction checks
schema IDs, arithmetic, declaration counts and the total capture-reference budget
before reserving its graph. Oversized groups fail with Capacity.

Constructor equations give the local source-to-target correspondence: each delay
is a zero-argument source computation; invocation's thunk calls the selected body
and then forces its answer; push constructs an argument thunk without demanding
it; lift ties its tail through code references; composition's three functions
implement the same reciprocal rotation; ana's query thunk defers both counterpart
lookup and successor construction. Normal selective lowering turns these closures
into code IDs and checked environments. Kosmos retains actual non-tail callers and
serializes their reachable finite state without executing delayed code.

The intended pure identity, associativity and lifting laws are scoped to the
supported non-strict interface and corresponding observations. In particular,
`project(lift(f), x) = f(x)` and `run(lift(f)) = fix(f)` follow by unfolding the
constructor equations. Equal Program hashes do not establish extensional equality.
Current finite tests distinguish these constructions but are not a universal
proof about partial terms. No unrestricted fold/build rewrite or effectful
commutativity is claimed.

## Component integration

Keep typed construction inside the component and explicit IDs at its registry
and linker boundary. `authoring.interop.importFunction(c, id, expected_callable)`
checks an undefined raw function declaration against the expected parameter and
result schemas, effect row and region row before making it callable through
ordinary typed bodies. It does not adopt an arbitrary raw implementation.

`authoring.interop.componentModule(c, entry, failure, interface)` permits undefined
functions only when the component interface lists them as imports. It retains
pending-declaration, lexical-scope and capture checks, and independently admits
the open component before returning a snapshot. Compile that snapshot with
`source.component.compile` and the same interface. Final source-free linking
checks the concrete imported function and effect bindings.

## Construction and image costs

The stronger successor boundary adds an ordinary state-delay closure for each
emitted querying definition. `Query.ask` captures that delay and forces it inside
the successor constructor before calling the retained maker. The coalescing
fixtures emit two such definitions, so their source function counts increase by
two. Their source schema catalog grows from nine to ten entries; schema capture
references grow from 54 to 61, including the state delay's own bound. Typed body
sequencing also introduces explicit value bindings, and configured definitions
now retain their distinct captured adjustment values. These are ordinary source
and closure records, with no additional runtime tags or dispatch.

Compared with `ae8ace5feecfda2e194b8ecad6fbe3a86ff91108`, the measured images are:

| Fixture | Source functions | Compiled functions | Constructors | Reachable schemas | Schema capture references | Environment capture references | BPI3 bytes |
|---|---:|---:|---:|---:|---:|---:|---:|
| duplicate | 19 → 21 | 12 → 12 | 9 → 10 | 6 → 7 | 12 → 16 | 6 → 10 | 499 → 546 |
| configured | 19 → 21 | 18 → 17 | 14 → 14 | 6 → 7 | 12 → 16 | 6 → 10 | 707 → 733 |
| lazy | 16 → 18 | 9 → 10 | 7 → 8 | 6 → 7 | 12 → 16 | 6 → 10 | 416 → 475 |

All compiled schemas are reachable in these fixtures. Twenty-one independent
source-oracle comparisons retain the previous results, including overflow and
ignored peers. The configured result remains distinct. These image changes are
intentional; the separate 42-image historical byte baseline remains unchanged.

Local measurements used Zig 0.17.0 `safe`, Apple M2 Pro arm64, macOS 27.2
(26B118), on October 23, 2026. Each snapshot ran eleven fresh-owner samples per
fixture, interleaved by fixture; the table reports the median of the final ten.
Baseline ran before candidate, with other development activity present. Candidate
timings include the final shared native-descriptor lowering; its source records,
images and allocation counts match the preceding typed construction exactly.

| Fixture | Authoring µs | Allocation calls | Requested bytes | Peak live bytes | Subsequent lowering µs |
|---|---:|---:|---:|---:|---:|
| duplicate | 16.48 → 602.75 | 4 → 236 | 86,336 → 789,426 | 86,336 → 525,728 | 491.06 → 515.06 |
| configured | 17.29 → 685.73 | 4 → 234 | 85,184 → 782,368 | 85,184 → 540,372 | 605.38 → 609.38 |
| lazy | 12.25 → 515.23 | 3 → 226 | 51,336 → 782,816 | 51,336 → 559,872 | 424.48 → 449.60 |

Authoring includes `Context.module`'s checked capture-publication lowering and
source snapshot. Raw baseline publication did neither. The subsequent lowering
column measures the same default `source.lower` call on each resulting module;
it therefore includes a second compilation on the typed path. This measurement
does not isolate type-index overhead. The existing `Context.compile` operation
performs checked publication and image construction together when a caller does
not need a source snapshot. Allocation counts use the existing requested-byte
meter, include successful growth, and exclude allocator metadata and RSS. Every
owner released its allocations. Graph counting, encoding and output are outside
timed intervals. These measurements are observations, not performance gates.

The October 26 Need-family repair was also compared with `fc5607bc` using eleven
fresh-owner samples for each of the five task/Need fixtures. Source and compiled
graph counts, allocation calls, requested bytes and BPI3 identities were unchanged.
The obtain/run/repeated/adaptive/dispose images remained 1,200/1,201/1,221/1,265/1,218
bytes. Median authoring times moved in both directions within 3%; no speedup is
claimed. The obtain fixture's peak requested storage decreased by twelve bytes.

The captured-Need construction adds one ordinary response schema and function
per interpretation, with a closure created at each `handle`. Against `2c9811c2`,
the five task fixtures each grow from 25 to 27 source functions, 17 to 19 source
schemas and 80 to 84 source capture references. Their compiled graphs grow from
20 to 23 functions, 14 to 16 constructors and reachable schemas, 31 to 35 schema
capture references, and 11 to 12 environment capture references. This replaces
the unbound lexical dependencies in a closed handler clause with explicit state;
it adds no runtime value category or special execution path.

Measurements on October 26 used the same machine, toolchain, requested-byte meter
and eleven-sample method described above, with fresh owners and the baseline run
before the candidate. Existing compiler optimization was enabled in both runs.

| Task fixture | Authoring µs | Allocation calls | Requested bytes | Peak live bytes | Subsequent lowering µs | BPI3 bytes |
|---|---:|---:|---:|---:|---:|---:|
| obtain | 1,955.54 → 2,312.17 | 297 → 296 | 1,730,742 → 2,067,694 | 932,136 → 989,686 | 1,828.62 → 1,952.21 | 1,200 → 1,325 |
| run | 1,925.50 → 2,248.79 | 295 → 298 | 1,703,398 → 2,182,068 | 913,738 → 989,888 | 1,888.58 → 2,065.17 | 1,201 → 1,326 |
| repeated | 1,997.88 → 2,351.29 | 306 → 303 | 1,901,086 → 2,153,714 | 1,018,704 → 973,748 | 1,888.21 → 2,151.21 | 1,221 → 1,346 |
| adaptive | 2,059.12 → 2,518.92 | 310 → 304 | 2,148,152 → 2,095,344 | 1,029,204 → 993,050 | 2,272.58 → 2,266.38 | 1,265 → 1,390 |
| dispose | 2,027.62 → 2,303.38 | 301 → 303 | 1,639,092 → 2,213,394 | 924,318 → 951,882 | 2,009.12 → 2,064.50 | 1,218 → 1,343 |

The response closure and shared capture analysis cost about 14–22% authoring time
in this local sample and 125 image bytes per fixture. All pending response
bounds share one source-analysis pass per publication; only actual free-variable
schemas enter those bounds. Removing the old query rebinding reduces some
allocations, but does not eliminate the helper's graph and analysis costs.
All measured owners released their storage. The new captured-state fixtures use
two distinct entry arguments and independently check exact effects and results
for obtaining a task, resuming, repeated requests and disposal. A separate fixture
checks a completion using a cell allocated inside the running task's region.

Completing a reserved callable directly avoids generating a second copy of its
schema. On the three-endpoint composition fixture this reduced the initial typed
graph from 47 schemas and 1,008 capture references to 26 and 504, with 33 source
functions in both versions. All 256 source-oracle input observations agreed.

## Verification

The native authoring/data roots retain the construction and ownership contracts.
`check-static-authoring` includes endpoint, category, option and counterfeit-handle
rejections. The independent higher-order source oracle covers demand boundaries,
task effects, repeated Need, heterogeneous composition and configured emission;
Kosmos owns execution agreement and checkpoint behavior. `check-package` consumes
the exported package, including the typed hyperfunction client and rejection
fixtures. Local module tests do not qualify a downstream dependency tuple.
Historical hyperfunction experiment emitters, duplicate
reference implementations, timing/measurement collectors and optional campaigns
are retired; their prior results remain in Git history.
