# Source relations and callable slices

Horos 6.1 exposes `source.relation` and `source.slice` over the existing
`source.Module`. These operations neither execute a submitted producer nor
establish arbitrary program equivalence. BMO1, BPI3, PST3 and ABI 3 retain their
existing grammars. Runtime selection and environmental authority remain with
the consuming system.

## Checked transformations

`source.relation.validate` checks an immutable predecessor, an ordered chain of
steps, and the actual final module. Every step accounts for the whole successor;
an unexplained change in an unused declaration or branch is rejected. Ordinary
source and target admission remain mandatory.

The finite rules are identity and exact relocation, scalar and product
simplification, one-level closed pure inlining, independently checked
specialization, and private product-coordinate bijections. Inlining preserves
argument evaluation order and multiplicity, and excludes captured callees,
nominal resource roles, internal state and protected recovery functions.
Specialization uses owner-approved immutable static scopes. A private product
change transports affected schemas, literals, constructors, projections and
unpack bindings, while fixed interfaces and authority identities remain fixed.
Unsupported transport is an error, not evidence of equivalence.

The caller supplies private schemas, fixed schemas and protected function roots
through `relation.Policy`. A consuming runtime must derive those facts from its
own approved source. Submitted evidence cannot authorize its own root or scope.
Successful source checking does not replace final lowering correspondence or
the consumer's recovery and observation requirements.

Raw `.computation` values refer to the constructor catalog actually generated
during source emission. Matching signatures alone do not identify a callable.
Validation retains each constructor's function, schema and ordered capture
origins. A relocation may supply `Maps.constructors` to transport those indices;
it must preserve each supplied operand's capture association and evaluation
order. A rewrite that silently rebinds a raw constructor is rejected.

`Policy.work` is shared across record traversal, source analysis and emission,
mandatory target admission, and relation checking. Expanded structures reserve
work before materialization. Exhaustion returns `RelationLimit`. Optional
compiler optimization is outside this admission operation; ordinary compilation
continues to run its existing optimizations. `decodeRecordStep` separately
charges all owned rule and successor allocations against its caller's byte
allowance. Exhaustion returns `Capacity`; underlying allocation failure remains
`OutOfMemory`. Decoded records must be retained in caller-owned storage.

Specialization's request policy separately limits argument normalization and
derivation checking. Standalone specialization performs ordinary admission
outside that local allowance. Inside a relation, admission and envelope analysis
consume the relation allowance; normalization and derivation checking consume
both allowances. Neither allowance replenishes the other.

## Executable source slices

`source.slice.extract` first admits the complete original module, computes the
selected entry's transitive dependencies, relocates retained declarations and
admits the result. `require_pure` requires an empty entry effect row and no
retained external effects. Malformed declarations cannot be hidden by pruning.
The returned owner contains the exact selected entry signature, schemas,
constants and mappings; call `deinit` when finished.

A raw closure can depend on a constructor whose original registration function
also contains an unreachable bridge. Extraction replaces that registration with
an ordinary, closed helper that constructs the same closure. The target body and
explicitly supplied captures remain unchanged under relocation. Helpers occupy
the function prefix reported by `Output.generated_functions`. When that prefix
is nonempty, `Output.maps.functions` maps original declarations into the final
module containing the generated helpers; it is not a dense relocation by itself.
`Output.module()` is the complete executable module. A page or redacted source
projection is not a substitute for it.

The native source tests exercise scalar mutants, protected roots, recursive
literal transport, constructor-index permutations, capture ordering, bridge
removal, work exhaustion and allocation failure. Consumer qualification must
also execute exported slices and preserve its own private and speculative
authority checks.
