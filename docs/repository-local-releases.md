# Horos repository-local release operations

Implementation is in progress. Native source packaging and release-record
structure are implemented. Native version preparation, release admission,
publication/recovery, ordinary preparation PRs, and the review-owner adapter have
executable implementations and focused tests. Their privileged workflow wiring
and complete end-to-end verification remain in progress. No
production activation or release is authorized by this document. Product
qualification and serial owner reviews of the final implementation remain
required before PR readiness.

Horos qualifies and publishes itself. Kosmos consumes a completed qualified
Horos release through its own ordinary PR. Protean consumes Kosmos and derives
Horos from that exact selection. Neither publication nor discovery installs a
runtime or migrates a saved task.

## Source and evidence

The inspected implementation starts at Horos main
`a541cbe0ebd142f35b4cecc0774aea983541f972`, PR #181 scaffold
`2fbcc41c98887bcd6ece56060d263730394b1bc6`. The corresponding inspected consumer
bases are Kosmos `79384cc621269959e861f137278552b76a9d1fea` (PR #80) and Protean
`e4bbeaa1739905579f798c1bef5b72d9c4523d60` (PR #64). These identify the inspection;
they are not future reset instructions or dependency selections.

`build.zig.zon` remains the version authority. `release.json` is derived,
external evidence, never an editable source lock. Its complete structural format
and authentication boundary are in [repository-release-v1.md](repository-release-v1.md).
A structurally valid record or passing tool test does not grant publication.

## Local commands

Use exact Zig 0.17.0. CI's release adapters use Node 26.9.0. From a clean
committed candidate:

```sh
node tools/release/test.mjs
zig build check-release-source -Doptimize=safe --summary all
zig build check-package -Doptimize=safe --summary all
zig build release-source -Doptimize=safe --summary all
zig build check-release-manifest build-release-tools -Doptimize=safe --summary all
zig-out/bin/horos-manifest read build.zig.zon
zig-out/bin/horos-manifest prepare build.zig.zon 8.0.1 /tmp/horos-candidate.zon
```

The test runner rejects empty file discovery, files without tests, failed,
skipped, cancelled, and unfinished tests. The ordinary installation gate runs
native archive tests as part of `check-package`. `release-source` retains
`zig-out/release-source/source.tar` and `source.json` after executing the existing
clean public package consumer. The inventory binds complete Git paths, blob
identities, executable modes, commit/tree, final archive bytes, compiler, and
Zig package identity. Archive verification precedes extraction and package use.

To test supplied final archive bytes using the native verifier and the same
public consumer:

```sh
zig build build-release-tools -Doptimize=safe
mkdir -p /tmp/horos-archive-check
zig-out/bin/horos-checks check-release-archive \
  "$(command -v zig)" "$PWD" COMMIT TREE SOURCE_TAR /tmp/horos-archive-check
```

Replace the uppercase arguments with exact immutable identities and an archive
path. This command does not discover releases or claim authentication of a remote
publisher; the repository must independently contain the authenticated Git source.
A malformed source, changed archive, unsupported entry, or consumer failure
rejects the operation.

The manifest operation parses the complete ZON document and replaces only the
root version literal. It preserves exact input bytes for a semantic no-op and
refuses an existing different candidate. Version decisions come from admitted
release impacts; the publisher never changes source versions. Source preparation
binds the exact Git head as a lazy build input, so a new source cannot reuse an
old output slot merely because its repository directory has the same name.

`tools/release/assemble.mjs` assembles record bytes from the native receipt,
matching manifest bytes, final payloads, and separately admitted evidence. It
checks manifest Git blob identity and archive size/digest correspondence, then
derives source fields and final artifact hashes. The function does not fabricate
review or qualification evidence and does not upload anything.

`tools/release/github.mjs` provides read-only repository identity checks,
paginated stable-release observations, annotated-tag resolution, and forward
source-lineage selection. Observed legacy releases remain ordinary legacy inputs;
no automatic consumer may admit them as new-format qualified releases.

The repository-private adapter entry point is:

```sh
node tools/release/cli.mjs admit-release tkersey/horos RELEASE_ID OUTPUT_DIRECTORY
node tools/release/cli.mjs check-qualification RUN_ID COMMIT TREE
node tools/release/cli.mjs review-owner CONFIG_JSON
```

Replace uppercase values with frozen inputs. `admit-release` downloads the exact
record and payload assets, checks numeric repository identity, immutable
publication, tag, source tree and workflow definition, then invokes GitHub's
artifact and release attestation verification. The expected certificate identity
names this repository's admission workflow on `main`; signer/source digests
bind the actual accepted control revision. It never admits a fixture or treats
payload checksums as signatures. Its output directory must not already exist.

`check-qualification` admits one original landed workflow run. It requires every
listed job to have actually succeeded on the expected source, platform and first
attempt within its existing budget. It rejects ambiguous duplicate runs and
downloads the exact installation artifact bytes, checking both GitHub's artifact
digest and the native source inventory. These are admission checks around the
existing qualification, not replacement product tests.

`publishHoros` in `tools/release/publish.mjs` stages exactly one Horos release.
Its trusted admission and final-attestation callbacks are mandatory. It downloads
and compares every existing asset, uploads only matching missing work, preserves
conflicting objects, and reobserves uncertain writes before deciding whether
they succeeded. It checks controls and effective immutable-release settings
before each write. `proposeHoros` and `promoteHoros` in `proposal.mjs` own the
single `automation/dependency-release` branch and ordinary PR. Promotion uses
protected rebase auto-merge with the expected head. A retired merged proposal may
yield its branch through an atomic expected-old-head update; an open epoch,
manual closure, hold, disabled auto-merge, or unknown human edit cannot be erased
by that update.

Feature PRs provide a `repository-release-impact/v1` JSON declaration in their
body, containing `impact`, `disposition`, `rationale`, and `contracts`.
`impactBlock` in `tools/release/impact.mjs` renders its exact syntax. The review
input captures the declaration with its base/head; a later semantic edit to it
invalidates admission. A PR body alone is never review authority. Generated
version-preparation PRs include the approved packaging-impact declaration.

## Required qualification inventory

The authoritative commands and platform rules remain in [.github/CI.md](../.github/CI.md).
The implementation adds a required release-tool result to the same terminal gate.

| Job | Required evidence | Timeout |
| --- | --- | --- |
| Source preflight | Tracked Zig inventory, formatting, full-source TigerStyle with pinned auditor tests, launcher behavior tests. | 5 minutes |
| Installation | `zig build check-package -Doptimize=safe --summary all`; fresh exported-package authoring/data consumers, negative category/lifecycle/compiler checks, and native archive tests. | 10 minutes |
| Contracts | `zig build check -Doptimize=safe --summary all --verbose`; native contracts, component/linker behavior, independent source oracle, and WASM byte/identity observations. | 10 minutes |
| Release tooling | `node tools/release/test.mjs`, using pinned Node 26.9.0. | 10 minutes |
| `native` aggregate | Runs even after prerequisite failures and requires actual success of source, both qualification lanes, and release tooling. | 5 minutes |

CI executes on native Ubuntu 24.04 x86-64 with Zig 0.17.0. Native macOS checks
supplement Linux qualification. No cache hit substitutes for test execution.
The source package is the current Horos distribution boundary; this project does
not introduce an evaluator binary or downstream runtime distribution in Horos.

## Review integration and deployment prerequisites

The inspected external tools are CAS 0.8.4 and Codex 0.166.0. The inspected
Actuating policy is dotfiles commit
`7aac0823b02dc31905ba57521dd9c1477686351e`, contract
`actuating-review-contract-v27`. Its contract file SHA-256 is
`cb72f160d9ff1ea1743513cee3058ca2f72e287599158e2763f296ab73b6e511`.
The Linux review installer pins the complete CAS and Codex release archives by
size and SHA-256 before extraction and fetches this exact policy revision.
`node tools/release/cli.mjs setup-review-tools OUTPUT_DIRECTORY` installs them
into a new private directory on native Linux x86-64. It does not install a global
command or change the product toolchain.

CAS supplies individual owner-lived reviews and original evidence. Actuating
owns the complete inventory, finding adjudication, per-request credit,
recovery, epoch closure, and convergence. A new loop counting five clean CAS
outputs cannot replace that procedure. The repository adapter must invoke the
ordinary owner noninteractively and retain its actual output plus original
executor evidence. Missing authentication, strong account identity, runtime
compatibility, or owner closeout blocks review admission.

`review-owner CONFIG_JSON` takes `repository`, `base`, `head`, `policyDirectory`,
`contextPath`, `workspace`, `captureRoot`, `reviewHome`, `path`, `casPath`,
`codexPath`, both executable SHA-256 values, and explicit `model`,
`reasoningEffort`, `serviceTier`. The context contains the accepted requirements,
release-impact input, and complete exact-subject proof inventory. `reviewHome`
contains dedicated Codex authentication under `.codex/auth.json`. It must not
contain GitHub writer credentials.

Each invocation lets the ordinary owner select at most one next review or
recovery, exporting `pending`, `blocked`, or `complete`. `previousCaptures`
resumes the same owner session and frozen inputs; a terminal blocked result is
not an automatic retry. The caller preserves active owner/CAS state between
jobs, excluding authentication and compiler caches from retained evidence.
Parent-owned capture directories remain outside the model's writable scratch.
Every credited CAS receipt must match an actual pinned command and its exact
runtime-captured output. Completion checks the full pinned lens/file inventory,
owner credit and limitation dispositions, epoch closure, and serial standard
convergence. `review-evidence.json` retains the original relevant runtime events,
receipts, owner facts and bound inputs; it excludes unrelated model commands and
authentication. Its structure alone is not provenance: the trusted workflow
must authenticate the exported artifact before another job can admit it.

A real disposable owner invocation returned `blocked` for deliberately absent
product qualification without dispatching any review. Direct CAS review-profile
preflight passed on the inspected native macOS runtime. Nested CAS preflight
inside the owner sandbox also passed after directing its schema cache into
permitted scratch; writes to the protected capture directory were denied. Full
review execution, resumption in Actions, and final closeout are still unverified.

The final runbook must record the implemented invocation, exact delivered heads,
full qualification results, review closeout, and live commissioning observations.
Until those exist, this implementation is not PR-ready or commissioned. Required
remaining components are review invocation/export/admission, authenticated
release admission, local version preparation, one ordinary local PR lifecycle,
protected promotion, and collision-safe publication/recovery.

## Merge and commissioning order

Keep `REPOSITORY_AUTOMATION=off` and `RELEASE_PUBLICATION_ENABLED=false` in all
three repositories during implementation merges. These are deployment
prerequisites; this work has not changed repository variables or settings.
With explicit merge authorization, merge Horos #181, verify qualification of the
actual landed source, then Kosmos #80 with its landed qualification, then
Protean #64 with its landed qualification. Stop the sequence on failure.

Only after independent authorization and verification of App permissions,
review authentication, protected merge requirements, required human approvals,
immutable releases, and provenance permissions may commissioning begin. Publish
a qualified Horos successor first; then run Kosmos's genuine consumption PR,
review/merge/landed qualification/publication; then Protean's corresponding path.
Live App-created PR triggers, protected merging, immutable publication, and
interrupted-write recovery remain unverified. No implementation fixture is a
production release, and implementation PRs do not require a production dependency
update merely because an upstream implementation merged.
