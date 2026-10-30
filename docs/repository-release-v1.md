# Repository release handoff, version 1

`release.json` is a derived release asset. `tools/release/record.mjs` defines its
structural validation and exact-byte production. Structural validation is not
qualification, review credit, or authenticated publication. Consumers must also
verify the publisher's admission attestation, expected repository and workflow,
actual immutable release, exact tag commit, artifact bytes, and source lineage.
An unsigned structurally valid record is never a production release input.

## Encoding

The schema identifier is `repository-release/v1`. Encoding is UTF-8 without a
BOM, compact JSON followed by one LF. Object keys are ASCII identifiers matching
`[A-Za-z][A-Za-z0-9_-]*`, sorted lexicographically at every level. Arrays retain
order. Strings use JSON escaping and must contain well-formed Unicode. Numbers
are safe integers; negative zero and fractional or exponent encodings are not
accepted. The encoder emits ordinary JSON boolean and null values.

A record is at most 1 MiB, with at most 32 nested edges and 32,768 visited values.
The decoder requires exact equality with the canonical re-encoding. This also
rejects duplicate keys, alternative key escapes, whitespace variants, and rounded
integer spellings. Hashes cover exact bytes, including the final LF. SHA-256
identifies assets and documents; full lowercase 40-character Git object IDs
identify the currently supported Git repositories. Unsupported formats fail.

## Fields

Every object has exactly the documented fields; unknown fields require a new
schema. Null is explicit where documented. All three repositories use this
shape; there is no shared package or service.

| Field | Encoding and authority |
| --- | --- |
| `schema` | Literal `repository-release/v1`. |
| `repository` | `{name,id}`: `tkersey/horos` / 1176152390, `tkersey/kosmos` / 1251308461, or `tkersey/protean` / 1328996555. Both identities must match. |
| `source` | `{commit,tree,version,manifestSha256,packageIdentity,lockSha256}`. Version comes from the source manifest, whose exact bytes are hashed. Package identity comes from the admitted compiler's native package operation. `lockSha256` is the exact Protean source lock digest; null for Horos and Kosmos. |
| `tag` | `v` followed by the source version. The authenticated remote tag must resolve to `source.commit`. |
| `dependencies` | Array of `{repository,source,release}`; repository/source use the above shapes. Release is `{id,tag,recordSha256}` identifying an already completed upstream release and exact upstream record bytes. |
| `artifacts` | Array of `{name,role,platform,bytes,sha256}`. Names are unique safe basenames. Roles are `source`, `inventory`, `runtime`, `native`, or `evidence`. Native artifacts require a platform; other artifacts may use null. Exactly one complete source archive and one source inventory are required. |
| `qualification` | `{workflow,run,results,aggregate}` as described below. Original qualification remains owned by the repository's existing required workflow. |
| `admission` | `{workflow}` identifies the trusted local publisher, using `{path,commit,sha256}`. The path is `.github/workflows/repository-release.yml`; signer verification binds this revision and definition independently of qualification. |
| `review` | `{owner,executionMode,policy,tools,subject,landing,closeout,originalEvidence}` as described below. Review credit remains owned by Actuating. |
| `compatibility` | `{impact,disposition,rationale,contracts,evidence}`. Impact is `none`, `patch`, `minor`, or `major`; disposition is `compatible` or `breaking`. Contracts is a nonempty unique list of affected public contracts. Evidence references the admitted exact-subject declaration. |
| `toolchains` | Nonempty array of `{name,version,platform,sha256}`, identifying actual applicable tool bytes and platforms. |

Versions are stable `major.minor.patch` triples without leading zeroes. Prerelease
versions are outside this automatic handoff. `packageIdentity` has the source
package name/version followed by Zig's 44-character package fingerprint. A valid
spelling does not authenticate a package: source admission recomputes it using
the exact selected compiler.

Horos dependencies are empty. Kosmos dependencies contain exactly Horos.
Protean dependencies contain Horos then Kosmos. Protean admission must derive
Horos from the exact Kosmos source and verify equality of commit and package
identity with both records and the native source lock. Merely satisfying the
record's dependency shape does not establish transitive equality.

`workflow` is `{path,commit,sha256}`: the controlling workflow path, accepted
control revision, and exact definition bytes. `run` is
`{id,attempt,event,commit,tree}`. Release qualification uses an actual landed
`push` subject equal to the source commit/tree. Results is a nonempty array of
`{platform,profile,evidence}` with unique platform/profile pairs; each evidence
value names an evidence artifact. Aggregate is `{name,evidence}`. These fields
retain the owner's original results; they do not describe a second lane policy.
The publisher must check the complete current inventory and original run rules
before producing the record. A consumer authenticates that admission rather than
re-evaluating upstream qualification.

Review owner is `actuating`; executionMode is `cas` or `subagents` as selected by
the owner. Policy is `{repository,definition}`, where repository is
`tkersey/dotfiles` and definition is `{path,commit,sha256}`. Tools use the same
shape as toolchains. Subject is `{base,head,tree}`, preserving the actual reviewed
subject. Landing is `{commit,tree,evidence}`, equal to the released source and
referencing the owner's admitted correspondence evidence. Closeout names the
original owner closeout artifact. OriginalEvidence is a nonempty unique array
of original evidence artifact names. The original owner, executor, principal,
instructions, policy, and credited subjects must be authenticated at publisher
admission. No JSON field grants review credit on its own.

Artifact arrays are bounded to 128 entries, dependency arrays to two, review
tools to 16, and toolchains to 32. Evidence references must resolve to artifacts
with the `evidence` role. Artifact sizes are positive safe integers. The record
cannot list itself or `SHA256SUMS` as an artifact: those would create checksum
cycles. Detached checksums may cover the finalized record and payloads, but not
the checksum file itself. Server-assigned IDs for this new release are not put
into the record. Upstream IDs are available because those releases already exist.

## Production and verification boundary

`produceRecord(metadata, payloads)` takes a metadata object and a map of exact
artifact buffers. It derives every artifact size and digest, validates the
complete record, and returns canonical bytes without mutating its inputs.
`readRecord(bytes)` checks encoding and structure. Neither function grants
publication authority or reads mutable latest-release metadata.

All original compact review and qualification evidence must be finalized before
the record is produced. A trusted publisher authenticates this admission and
artifact set with GitHub attestations, stages all assets in a draft, and verifies
the final immutable tag and asset set after publication. The platform's later
release attestation is verified externally; it does not cause the record to be
rewritten. Release titles, notes, latest markers, and publication timestamps do
not establish compatibility or admission.

The unit tests intentionally use synthetic metadata and injected bytes. They
prove structural rejection and deterministic record production, not a real
qualified release or producer/consumer commissioning. Frozen native producer
fixtures and authenticated live verification are separate integration evidence.
