# Repository-local releases: Horos

Status: implementation contract, not implemented automation. This document replaces the Horos portion of the proposed shared `align` / coordinated-stack-publication architecture. The implementation remains outstanding until the acceptance requirements below have executable evidence.

## Decision

Horos qualifies and publishes Horos. Kosmos discovers eligible Horos releases and proposes changes in Kosmos. Protean discovers eligible Kosmos releases and derives its Horos selection from that Kosmos. No repository writes another repository's source, prepares another repository's version, or publishes another repository's release.

Use publish-before-consume for automatic propagation. A qualified development commit is not automatically a published dependency. Releases can be frequent, but no downstream workflow consumes moving `main` or independently chooses three latest versions.

Do not add `align`, an orchestration application to `skills-zig`, a central coordinator, a scheduler database, cross-repository dispatch, a second version registry, or a replacement review engine. This is a repository-owned workflow change, not a new product.

## Existing authorities

`build.zig.zon` owns the package version and toolchain constraint. Source, package-consumer, and contract qualification remain owned by `.github/workflows/zig.yml` and `.github/CI.md`. Preserve the full existing `native` aggregate and all later accepted gates. Repository instructions in `AGENTS.md` continue to apply.

The inspected starting point was commit `a541cbe0ebd142f35b4cecc0774aea983541f972`, package 8.0.0, Zig 0.17.0. These are historical inspection coordinates, not instructions to reset current source or upgrade unrelated dependencies.

Package, wire, ABI, application, and state versions are different authorities. Never replace every version-looking string. A source version is not proof of publication, and a release title is not proof of qualification.

## Local implementation

Extend the existing qualification and source-package paths. Add only narrowly scoped repository-local operations where the existing paths cannot supply the required result. Keep ordinary builds and package consumption independent of GitHub, Node additions, sibling repositories, globally installed release tools, and network freshness checks.

1. Prepare the final package version before qualification. Use the repository's approved compatibility decision, not an inferred version bump based solely on compilation. When an approved pending version already covers the change, preserve it. A repeated run on unchanged input must not increment the version again. Version preparation is an ordinary reviewed PR, assigned to `tkersey`; never mutate the version in a publisher.
2. Qualify the actual landed source and prepare its authenticated source archive through a credential-restricted job. Bind the archive's complete paths, Git blobs, executable modes, source commit, source tree, package version, and exact Zig package identity. Hashing an arbitrary download does not authenticate its claimed Git source.
3. Run the existing clean package-consumer qualification against the final distributable source. Preserve every required review and native qualification obligation. A skipped, interrupted, diagnostic, timed-out, or incomplete result does not qualify.
4. A separate trusted publisher receives the exact admitted source and tested artifacts. It performs no candidate builds and does not run candidate code with release credentials. It publishes only Horos using repository-scoped authority and explicit owner enablement.
5. Re-read the published tag and assets and verify their identities. Preserve enough qualification and review references or evidence in the release to survive routine CI artifact expiry. Consumers discover the completed release; Horos does not notify or mutate Kosmos.

A `workflow_run` event may wake a local publisher, but its payload is not an admission verdict. Re-fetch and validate the actual source, originating workflow, event, branch, attempt, aggregate, artifacts, and review evidence under trusted accepted control definitions.

Reuse the current source archive and checksum distribution rather than inventing a new package format. A compact derived release record may expose the immutable source, package identity, artifact sizes/digests, and original qualification/review references needed by consumers. It is external publication evidence, not a second source-selection registry, and must not include a hash of itself in its own hashed bytes.

## Review and merge ownership

Actuating and CAS continue to own review execution, original receipts, adjudication, model/reasoning parity, auxiliary obligations, applicable focused-file obligations, and the five consecutive credited standard reviews on an unchanged candidate. Do not reproduce those rules in a release script or accept a JSON counter, label, comment, process exit, or check title as substitute evidence.

Any missing unattended execution or trusted closeout interface is an explicit implementation dependency. Until that interface and effective branch protections are verified, automatic promotion stays disabled. Required human approvals are not silently replaced.

Use the existing protected merge path. Changes to base, head, selected inputs, or controlling review policy invalidate affected evidence. Post-merge qualification binds the actual landed commit, including explicit handling of squash/rebase identity changes. Tree equivalence alone does not transfer artifact or review eligibility.

## Publication safety and operator control

Publication is disabled until separately authorized by the owner. This contract does not authorize creating credentials, changing repository protections, merging PRs, publishing releases, or installing runtimes.

The publisher has only local release authority. Candidate jobs have no release or branch-write credentials; source checkouts use `persist-credentials: false`. Trusted control code does not execute candidate-controlled caches or scripts. Pin workflow actions and retain existing toolchain pins.

Use local concurrency with active-writer cancellation disabled. Before repeating an uncertain write, inspect whether it succeeded. A collision with different tag/source/asset identity blocks; never retag, overwrite published bytes, or delete a valid release to simulate rollback. Prefer the platform's immutable-release protection when enabled, while still checking source, qualification, and artifact evidence independently.

Failure leaves an ordinary Horos PR, qualification run, or release attempt blocked with its specific cause. It is not a global stack failure. Failed product qualification is not retried until green through repeated triggers or empty commits. A manually closed preparation PR, changed branch, or owner pause is respected.

Do not update installed tools, saved tasks, executable retention records, state formats, or downstream source as a side effect. Routine artifacts retain existing bounded retention; preserve required release evidence before it expires. New jobs remain at most ten minutes and do not reset or weaken existing product qualification clocks.

## Acceptance and completion

Implementation must demonstrate:

- Final version preparation is deterministic, precedes qualification, and never reuses a published version for different source or artifacts.
- Wrong source/tree, incomplete lanes, wrong attempts, missing review evidence, expired artifacts, and changed final archive bytes block publication.
- The normal source-package and clean-consumer checks pass for the exact published inputs with no new global tool dependency.
- The publisher cannot execute candidate code with its write credentials and can write only this repository.
- Duplicate wake-ups are no-ops after success; uncertain uploads are inspected before retry; collisions preserve existing objects; an owner pause prevents writes.
- Real authorized test publication verifies the final tag, source archive, package identity, and retained evidence. Fixture tests alone do not establish live deployment.

The implementation PR must report code implemented, tests actually run, full qualification/review outstanding, configuration required, and whether publication is enabled. A design document, dry-run reporter, draft PR, or unexecuted workflow is not completion.

## Related repository responsibilities

Kosmos owns Horos discovery, its local refresh, ordinary PR, qualification, and Kosmos publication. Protean owns Kosmos discovery, deriving the shared Horos binding, its authenticated lock refresh, ordinary PR, qualification, and Protean publication. Those implementations may proceed independently against the explicit release handoff; rollout proceeds upstream first.
