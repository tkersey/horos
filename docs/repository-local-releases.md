# Horos repository-local release operations

Native source packaging, version preparation, authenticated release admission,
proposal/review workflows, protected promotion, and publication/recovery have
repository-local implementations and executable tests. Automation defaults to
off. Exact-head product qualification and original serial owner reviews establish
PR readiness; authorized live commissioning establishes service operation. This
document does not authorize production activation, publication, or installation.

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

Native source admission opens regular files without blocking on FIFOs and checks
raw and PAX sizes before iterator arithmetic. Output exclusion belongs to the
opened directory, so alternate path spellings share the same lock. Replacement
removes the old receipt before publishing new archive bytes. Compiler execution
and its recorded digest use the same captured executable; native Zig library
discovery retains the original installation and explicit compiler environment.

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
the normal protected rebase merge operation for an already `MERGEABLE/CLEAN` PR,
with `expectedHeadOid` binding the admitted head. It preserves required checks,
human approvals, and protections; it never uses an administrative bypass.
A retired merged proposal may
yield its branch through an atomic expected-old-head update; an open epoch,
manual closure, hold, disabled auto-merge, or unknown human edit cannot be erased
by that update.

Feature PRs provide a `repository-release-impact/v1` JSON declaration in their
body, containing `impact`, `disposition`, `rationale`, and `contracts`.
`impactBlock` in `tools/release/impact.mjs` renders its exact syntax. The review
input captures the declaration with its base/head; a later semantic edit to it
invalidates admission. A PR body alone is never review authority. Generated
version-preparation PRs include the approved packaging-impact declaration.

## Automated proposal controls

`repository-automation.yml` observes hourly at minute seven, on manual dispatch,
and after qualification or owner-review completion. Its writer concurrency group
never cancels an in-flight writer. It checks out the accepted `main` revision and
compiles `tools/release_manifest.zig` before requesting any App credential. The
writer executes only that trusted native parser on captured Git manifest bytes;
it does not build or run candidate code. Checkout credentials are not retained.

The `repository-automation` environment supplies the repository-local App key
and client ID. The writer token is restricted to Horos and is revoked after the
job. `REPOSITORY_AUTOMATION` defaults to `off`. Off mode permits authenticated
required-review check reporting and cancellation of automation-owned pending
auto-merge, while prohibiting source, proposal, status-comment and promotion
writes. Without a configured App, the job reports read-only source and release
observations and explicitly leaves auto-merge cancellation unverified.
This fallback reads the workflow's configured mode without querying the
Variables API. Publication reports the missing App credential before attempting
credentialed control reads. Enabled writers still reobserve live controls.

`propose` computes the current publication boundary, admits its original review
and publication evidence, and creates or updates the one ordinary preparation PR.
Native admission recomputes the current approved version decision and exact
version-only bytes before source writes. `promote` additionally requires the
original successful qualification, authenticated complete owner evidence,
resolved threads, exact check producers, effective protection and all actual
required human approvals. A zero configured minimum does not waive the effective
repository approval policy. A changed base, source, control or decision blocks
promotion. Publication is a separately enabled operation.


A generated proposal is reviewed against its immutable original Git parent, even
if main advances before review begins. Trusted current control must descend from
that base; original preparation, impact, and pending review inputs remain bound to
the original subject. A completed candidate stays frozen while its base remains
current. After the base advances, its authenticated closed epoch permits a fresh
candidate and fresh qualification/review. If a branch update succeeded before the PR description
update, the writer authenticates the described predecessor and actual successor
independently, then finishes only the missing metadata update. Further base
movement does not authorize another source transition during that recovery.
Unknown source edits, altered metadata, or unavailable original evidence hold
recovery. Branch updates use atomic expected-head checks; PR metadata uses
before/after observations and has no claimed atomic conditional-edit guarantee.
Historical closure/reopen and hold-label removal still require explicit owner
resume; removing the hold alone does not grant authority.

An already active owner epoch remains frozen. Successor preparation requires the
original authenticated closed epoch and a reconstructed native candidate. The
only pre-review absence exception is a unique original first-attempt qualification
that has completed with a failure; a missing, pending, skipped, neutral or successful
run cannot supply retirement authority. Existing failure history remains intact.

An `automation-hold` label or draft state cancels an existing automation-owned
auto-merge request even in `promote` mode. Unknown or human-owned auto-merge is
never cancelled by this adapter. Resumption requires reopening the PR, removing
the hold label, and a new unedited comment from the numeric repository owner:

```text
/repository-automation resume HEAD
```

Replace `HEAD` with the exact held PR head. The whole comment must match that
command, and its creation time must follow the original hold/closure timeline.
Edited comments, an older command, a different author or source, and a mutable PR
body cannot grant resume authority. The adapter reobserves the owner, comment,
head, labels and hold events before accepting it. Resume does not grant review,
qualification or merge credit.

Enabled automation maintains one App-owned status comment on its preparation PR.
An unchanged status is a no-op; uncertain writes are read back before retry.
Status comments explain the outstanding gate and do not carry review authority.
Normal required checks also cover ordinary qualified local PRs.

The executable entry point is
`node tools/release/automation-runner.mjs CONTROL_DIRECTORY TRUSTED_MANIFEST_TOOL [APP_IDENTITY_JSON]`.
The optional identity file is the exact output of the scoped App-token helper;
without it the runner cannot perform writer operations. Local adapter tests and
workflow lint do not establish live App-created PR triggers or protected merging.

## Required qualification inventory

The authoritative commands and platform rules remain in [.github/CI.md](../.github/CI.md).
The implementation adds a required release-tool result to the same terminal gate.

| Job | Required evidence | Timeout |
| --- | --- | --- |
| Source preflight | Tracked Zig inventory, formatting, full-source TigerStyle with pinned auditor tests, launcher behavior tests. | 5 minutes |
| Installation | `zig build check-package -Doptimize=safe --summary all`; fresh exported-package authoring/data consumers, negative category/lifecycle/compiler checks, and native archive tests. | 10 minutes |
| Contracts | `zig build check -Doptimize=safe --summary all --verbose`; native contracts, component/linker behavior, independent source oracle, and WASM byte/identity observations. | 10 minutes |
| Release tooling | `node tools/release/test.mjs`, using pinned Node 26.9.0 and the actual Zig manifest helper; `node tools/release/review-tools-smoke.mjs OUTPUT_DIRECTORY` verifies native Linux review tool compatibility and sandbox confinement. | 10 minutes |
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

Observer, start marker, and check reporter use the same original review subject.
Missing evidence preserves the durable invocation identity across repeated polls.
Recovering a failed or stale check display requires the authenticated original
pending result; a terminal owner result cannot reopen. The owner process deadline
includes elapsed setup and leaves one minute within both the eight-minute step
and ten-minute job limits for termination, diagnostics, and retention.

A real disposable owner invocation returned `blocked` for deliberately absent
product qualification without dispatching any review. Direct CAS review-profile
preflight passed on the inspected native macOS runtime. Nested CAS preflight
inside the owner sandbox also passed after directing its schema cache into
permitted scratch; writes to the protected capture directory were denied. Full
review execution, resumption in Actions, and final closeout are still unverified.
An actual bounded owner/CAS review attempt on macOS subsequently stopped before
review creation with `SystemBootIdentityUnavailable`: the Codex sandbox denied
CAS's `kern.boottime` query. That attempt received no review credit. The automated
execution target remains native Linux x86-64; its added interface smoke is a
separate observation and does not count as an executed product review.

`repository-review.yml` polls qualified local PRs and accepts an explicit initial
publication review range through its `bootstrap_*` manual inputs. It uses only a
repository-local read token and separate model authentication, starts at most one
owner-selected review per job, and retains the same owner session for subsequent
turns. Pending results and credential-free active state are ordinary Actions
artifacts with 14-day retention. Expired or incomplete original evidence blocks
automatic recovery. The current pinned runtime is `gpt-6-astra`, high reasoning,
priority service, CAS 0.8.4 and Codex 0.166.0; changing these bindings invalidates
an active epoch.

Required deployment inputs are `REPOSITORY_APP_CLIENT_ID`, the
`REPOSITORY_APP_PRIVATE_KEY` secret, and `REPOSITORY_REVIEW_AUTH_JSON`. The
`repository-review` environment must be configured by the owner. Token creation
requests exactly this repository and the job's explicit permissions; model
processes never receive the App key or writer token. These inputs have not been
provisioned by this implementation.

The native version adapter prepares only `build.zig.zon` through
`horos-manifest`, preserves the base commit's timestamp for deterministic Git
identity, and authenticates root-tree contents independently. Promotion and
publication-boundary adapters require original qualification, authenticated owner
evidence, declared impact and effective branch protection. The review check writer
updates one App-owned check for the exact head and never grants credit for pending,
blocked, forged, stale-declaration or mismatched-runtime evidence.

The implementation PR proof and final handoff record exact delivered heads,
qualification commands/results, and original review closeout. PR readiness
requires all applicable checks and reviews on those subjects. Live App-created
PR triggers, effective protected merging, immutable publication, and recovery
require separate owner-authorized commissioning evidence.

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

### Local publication

`repository-release.yml` runs on accepted `main`, after qualification/review
completion and on its own schedule. Its default controls are
`REPOSITORY_AUTOMATION=off` and `RELEASE_PUBLICATION_ENABLED=false`. A read-only
App token admits the original landed qualification and owner review; the native
manifest parser is compiled before introducing App credentials. The publisher
never builds a candidate or an upstream payload with write authority.

The executable entry points are:

```sh
node tools/release/publication-runner.mjs prepare "$CONTROL" "$MANIFEST_TOOL" "$OUTPUT" "$OBSERVER_IDENTITY"
node tools/release/publication-runner.mjs publish "$CONTROL" "$MANIFEST_TOOL" "$OUTPUT" "$PUBLISHER_IDENTITY"
```

Preparation derives `release.json` from the exact original `source.tar` and
`source.json`, complete qualification outcomes, reviewed publication boundary,
original owner closeouts, and original authenticated review artifact envelopes.
It retains compiler and reviewer binary identities separately. It does not
rebuild a package or fetch a more recent dependency. A pending landed run is
reported as pending; failed, duplicated, expired, or missing required evidence
cannot authorize publication.

The workflow signs the finalized record and assets with GitHub artifact
attestations before minting the separate publication token. Publication verifies
the expected workflow signer and re-observes the source, controls, original
qualification, reviews, and exact bytes before staging and before publishing.
It requires immutable-release protection, uploads only missing identical assets,
and verifies the platform release attestation and every published byte. Existing
matching completed publications are verified no-ops. Conflicting tags, drafts,
or asset bytes remain untouched. A matching interrupted draft resumes from its
observed missing assets; expired evidence or an advanced source blocks that
attempt and requires operator diagnosis without moving the tag.

The workflow uses pinned `actions/attest` in provenance mode with
`create-storage-record: false`; its GitHub token has only the additional
`id-token: write` and `attestations: write` authorities needed for signing.
The separately minted local App token provides release writes and read-only
administrative inspection of immutable-release protection. Live immutable
publication and interrupted-write recovery remain commissioning checks requiring
an owner-authorized environment.

The Ubuntu review sandbox installs an application-scoped AppArmor profile for
`/usr/bin/bwrap` allowing user namespace creation. Ubuntu documents this
[per-application prerequisite](https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces).
The host-wide restrictions remain enabled. The qualification smoke test must
still prove protected capture writes fail, permitted workspace writes succeed,
and the original CAS sandbox interface works.
