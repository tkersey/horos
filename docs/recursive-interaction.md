# Defunctionalized hyperfunctions and recursive interaction

Implementation of the complete user specification v1.1 (September 19, 2026).
The milestone was recorded as incomplete in the original Boundary draft:
https://github.com/tkersey/boundary/pull/153 and Agent companion:
https://github.com/tkersey/agent/pull/33.

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

`library.hyper` supplies:

| Operation | Staged meaning |
| --- | --- |
| `pair`, `pairWith` | Checked reciprocal interfaces with explicit capture bounds |
| `group`, `Group.get` | Compatible interfaces for a finite monomorphic endpoint cohort |
| `deferValue`, `delayed`, `force` | Construct a typed delay and demand one result layer |
| `make`, `invoke` | General checked body and suspended invocation |
| `base`, `push`, `lift`, `identity` | The non-strict constructors above |
| `compose` | H(B,C) × H(A,B) → H(A,C), retaining reciprocal return paths |
| `run`, `project` | Observe through identity or a constant counterpart |
| `ana`, `start`, `Query.ask` | Runtime-state construction with arbitrary staged queries |
| `demand.family/request/interpret/handle` | Lexical internal Need effects interpreted as counterpart tasks |
| `lazyProduct`, `lazySum` | Observe fields/tags without forcing unused delayed payloads |
| `stream`, `cons`, `emptyStream` | Delayed elements and successor spines |

IDs refer to checked source values/functions/schemas. Operations that execute a
source call return a source term yielding the delayed value or participant;
`make`, `base`, and value constructors return source values. Bind terms using the
normal Builder before referring to their values. `push` and `lift` take a source
function `Delayed<A> -> Delayed<B>`; a strict function must explicitly force its
argument in its authored body. The library does not silently perform that force.
`run`/identity require equal endpoint types; `project` permits distinct endpoints.
Composition with lifted maps supplies checked endpoint adaptation.

`ana` gives `Step.emit` source values for state and a query builder. Each authored
call emits the current step configuration; the Zig step type is not a cache key.
Keep the returned `Ana` and call `start` to reuse that definition. Runtime queries
reuse its maker without emitting code. The step may emit zero, one, or several
adaptive runtime queries and non-tail work. It is not a
fixed stream schedule. Only finitely authored code is generated; successor states
and repeated interactions are runtime values.

The `ana_config` and `ana_capture` regressions construct two definitions using
the same step type, selecting constants and captured bindings respectively. The
former reproduced the old type-only cache returning 38 instead of 42. Both now
returned 42 through fresh World transfers (33 and 31 transfers). The unit regression
also starts each retained definition 100 times without adding function bodies.

## Composition and capture contracts

The compiler's existing computation contracts admit captures by schema. A
composition retains H(B,C), H(A,B), and its reciprocal H(C,A), and the nested call
rotates those endpoints. Independently declared narrow pair capture bounds need
not permit that rotation. `group` declares the shared finite type cohort before
participants are authored or independently compiled. It enumerates endpoint type
pairs, never endpoint values, runtime states, or exchange histories. A component
must share a compatible contract; unrelated contracts are not silently coerced.

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

## Verification

The native authoring/data roots retain the construction and ownership contracts.
The independent higher-order source oracle and Kosmos source agreement retain
execution semantics. Historical hyperfunction experiment emitters, duplicate
reference implementations, timing/measurement collectors and optional campaigns
are retired; their prior results remain in Git history.
