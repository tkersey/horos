import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import test from 'node:test';
import {encodeRecord, maximumRecordBytes, sha256} from './encoding.mjs';
import {impactBlock, impactInput} from './impact.mjs';
import {computeHorosPublicationBoundary} from './publication-boundary.mjs';
import {retainedFixture} from './promotion-test-support.mjs';
import {metadata} from './test-support.mjs';
import {proposalCommitOid, proposalMessage} from './proposal.mjs';
import {encodeWriterIntent, readWriterIntentBytes} from './proposal-intent.mjs';

const repository = 'tkersey/horos', repositoryId = 1176152390;
const oid = number => number.toString(16).padStart(40, '0');
const settings = {codexSha256: '1'.repeat(64), casSha256: '2'.repeat(64),
  model: 'gpt-6', reasoningEffort: 'high', serviceTier: 'priority'};
const declaration = (impact = 'patch') => ({impact, disposition: 'compatible', rationale: 'Reviewed fixture compatibility.', contracts: ['fixture API']});

function fixture() {
  const commits = new Map(), manifests = new Map(), pulls = new Map(), originals = new Map(), associated = new Map();
  const releases = [], admitted = new Map(), reviews = new Map(), classifications = new Map();
  const failures = new Set(), calls = [];
  let next = 1, main;
  function addCommit(parent, version = '1.0.0', tree = oid(next + 1000)) {
    const sha = oid(next++), value = {sha, tree: {sha: tree}, parents: parent === null ? [] : [{sha: parent}]};
    commits.set(sha, value); manifests.set(sha, Buffer.from(JSON.stringify({version}))); return value;
  }
  const root = addCommit(null); main = root.sha;
  function addRelease(commit = root, version = '1.0.0', legacy = false) {
    const id = releases.length + 11;
    const release = {id, draft: false, prerelease: false, immutable: true, tag_name: `v${version}`, legacy};
    releases.push(release);
    if (!legacy) {
      const record = metadata(); Object.assign(record.source, {commit: commit.sha, tree: commit.tree.sha, version,
        packageIdentity: `horos-${version}-${'a'.repeat(44)}`});
      record.tag = release.tag_name; record.qualification.run.commit = commit.sha; record.qualification.run.tree = commit.tree.sha;
      record.review.landing.commit = commit.sha; record.review.landing.tree = commit.tree.sha;
      admitted.set(id, {id, record, recordSha256: sha256(encodeRecord(record))});
    }
    return release;
  }
  function storeReview(subject, context) {
    const retained = retainedFixture(context, settings);
    const envelope = {schema: 'repository-review-result/v1', status: 'complete', epochClosed: true,
      reason: 'Original owner complete.', turn: 1, previousSha256: null, stateSha256: null,
      context, retainedEvidence: Buffer.from(JSON.stringify(retained)).toString('base64')};
    const artifact = {bytes: Buffer.from(JSON.stringify(envelope)), run: {id: 100 + reviews.size}, artifact: {id: 200 + reviews.size}};
    reviews.set(`${subject.base}:${subject.head}`, artifact); return {artifact, envelope};
  }
  function addChange({impact = 'patch', version = '1.0.0', count = 1, squash = false, versionOnly = false, contracts = null} = {}) {
    const base = main, source = [];
    for (let index = 0; index < count; index++) source.push(addCommit(source.at(-1)?.sha ?? base, version));
    const landed = [];
    for (const original of squash ? source.slice(-1) : source) landed.push(addCommit(landed.at(-1)?.sha ?? base, version, original.tree.sha));
    main = landed.at(-1).sha;
    const reviewed = declaration(impact);
    if (contracts !== null) reviewed.contracts = contracts;
    const number = pulls.size + 1, body = impactBlock(reviewed);
    const pull = {id: number + 500, number, state: 'closed', merged: true, merged_at: '2026-10-30T00:00:00Z',
      body, merge_commit_sha: main, base: {ref: 'main', sha: base, repo: {id: repositoryId}},
      head: {sha: source.at(-1).sha, repo: {id: repositoryId}}};
    pulls.set(number, pull); originals.set(number, source.map(value => ({sha: value.sha}))); associated.set(main, [pull]);
    const subject = {base, head: pull.head.sha, tree: source.at(-1).tree.sha};
    const context = {repository, ...subject, impact: impactInput(body, base, pull.head.sha)};
    const review = storeReview(subject, context); classifications.set(pull.head.sha, versionOnly);
    return {base, source, landed, pull, subject, context, ...review};
  }
  function bootstrap(initialVersion = '1.0.0') {
    const subject = {base: root.sha, head: main, tree: commits.get(main).tree.sha};
    const body = impactBlock(declaration());
    const context = {repository, ...subject, impact: impactInput(body, subject.base, subject.head),
      bootstrap: {boundary: subject, initialVersion, disposition: 'compatible', rationale: 'Reviewed initial source and free version.'}};
    return {subject, context, ...storeReview(subject, context)};
  }
  const state = {unavailableList: false, onRequest: null};
  const ancestor = (base, head) => {
    const seen = new Set(); let cursor = head;
    while (cursor !== undefined && !seen.has(cursor)) {
      if (cursor === base) return true; seen.add(cursor); cursor = commits.get(cursor)?.parents[0]?.sha;
    }
    return false;
  };
  const client = {async request(request) {
    assert.equal(request.method ?? 'GET', 'GET'); const path = request.path; calls.push(path); await state.onRequest?.(path);
    const reply = body => ({status: 200, body: structuredClone(body)}), missing = {status: 404};
    if (path === '') return reply({full_name: repository, id: repositoryId, default_branch: 'main'});
    if (path === '/git/ref/heads/main') return reply({ref: 'refs/heads/main', object: {type: 'commit', sha: main}});
    if (path.startsWith('/git/commits/')) return commits.has(path.slice(13)) ? reply(commits.get(path.slice(13))) : missing;
    if (path.startsWith('/contents/build.zig.zon?ref=')) {
      const bytes = manifests.get(path.split('=')[1]);
      return reply({type: 'file', encoding: 'base64', content: bytes.toString('base64'),
        sha: createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex')});
    }
    if (path.startsWith('/releases/tags/')) {
      const release = releases.find(value => value.tag_name === path.slice(15)); return release ? reply(release) : missing;
    }
    if (path === '/releases?per_page=100&page=1') return state.unavailableList ? {status: 403} : reply(releases);
    const asset = path.match(/^\/releases\/(\d+)\/assets\?per_page=100&page=1$/);
    if (asset) {
      const release = releases.find(value => value.id === Number(asset[1]));
      return reply(release.legacy ? [] : [{id: release.id + 1000, name: 'release.json'}]);
    }
    const comparison = path.match(/^\/compare\/([a-f0-9]{40})\.\.\.([a-f0-9]{40})$/);
    if (comparison) {
      const [, base, head] = comparison, forward = ancestor(base, head);
      return reply({base_commit: {sha: base}, merge_base_commit: {sha: forward ? base : root.sha},
        status: forward ? base === head ? 'identical' : 'ahead' : 'diverged'});
    }
    const association = path.match(/^\/commits\/([a-f0-9]{40})\/pulls\?per_page=100&page=1$/);
    if (association) return reply(associated.get(association[1]) ?? []);
    const pull = path.match(/^\/pulls\/(\d+)$/);
    if (pull) return reply(pulls.get(Number(pull[1])));
    const rows = path.match(/^\/pulls\/(\d+)\/commits\?per_page=100&page=1$/);
    if (rows) return reply(originals.get(Number(rows[1])));
    throw new Error(`unexpected boundary API: ${path}`);
  }};
  const options = {client,
    admitPublishedRelease: async ({repository: name, releaseId}) => {
      assert.equal(name, repository); if (failures.has(releaseId)) throw new Error('original release evidence unavailable');
      return structuredClone(admitted.get(releaseId));
    },
    authenticateReview: async subject => {
      const artifact = reviews.get(`${subject.base}:${subject.head}`); assert.ok(artifact, 'original review unavailable'); return artifact;
    },
    readVersion: async ({manifestBytes}) => JSON.parse(manifestBytes).version,
    classifyVersionPreparation: async ({subject, manifestBytes, baseManifestBytes}) => {
      assert.ok(Buffer.isBuffer(manifestBytes) && Buffer.isBuffer(baseManifestBytes));
      return {versionOnly: classifications.get(subject.head)};
    },
  };
  const run = input => computeHorosPublicationBoundary({source: {commit: main, tree: commits.get(main).tree.sha}, ...input}, options);
  return {root, commits, manifests, pulls, originals, associated, releases, admitted, reviews, classifications,
    failures, calls, state, options, addCommit, addRelease, addChange, bootstrap, run, current: () => commits.get(main),
    setMain: value => {main = value;}};
}

test('highest original admitted unreleased impact determines deterministic required version', async () => {
  const value = fixture(); value.addRelease(); value.addChange(); value.addChange({impact: 'minor', count: 2});
  const first = await value.run(), second = await value.run();
  assert.equal(first.status, 'prepare'); assert.equal(first.version, '1.1.0');
  assert.equal(first.record.changes.length, 2); assert.deepEqual(first.bytes, second.bytes);
  for (const change of first.record.changes) assert.equal(sha256(first.reviewArtifacts.get(change.review.sha256)), change.review.sha256);
});

test('multi-commit squash preserves actual merged-to-original source correspondence', async () => {
  const value = fixture(); value.addRelease(); const change = value.addChange({count: 3, squash: true});
  const result = await value.run(); assert.equal(result.version, '1.0.1');
  assert.deepEqual(result.record.changes[0].landedCommits, [change.landed[0].sha]);
  assert.equal(result.record.changes[0].subject.head, change.source.at(-1).sha);
});

test('native-proven version preparation adds no second increment and preserves sufficient version', async () => {
  const value = fixture(); value.addRelease(); value.addChange(); value.addChange({version: '1.0.1', versionOnly: true});
  const prepared = await value.run(); assert.equal(prepared.status, 'ready'); assert.equal(prepared.version, '1.0.1');
  assert.equal(prepared.record.changes[1].versionOnly, true);
  const published = value.addRelease(value.current(), '1.0.1');
  value.state.unavailableList = true;
  const after = await value.run({publicationRequired: true}); assert.equal(after.status, 'unchanged');
  assert.equal(after.record.baseline.releaseId, published.id);
});

test('explicit packaging-only preparation converges without another bump', async () => {
  const value = fixture(); value.addRelease(); value.addChange({version: '1.0.1', versionOnly: true});
  const result = await value.run(); assert.equal(result.status, 'ready'); assert.equal(result.version, '1.0.1');
});

test('already approved larger pending version is never downgraded', async () => {
  const value = fixture(); value.addRelease(); value.addChange({impact: 'minor', version: '1.5.0'});
  const result = await value.run(); assert.equal(result.version, '1.5.0'); assert.equal(result.status, 'ready');
});

test('none is idle unless distinct publication is explicitly requested', async () => {
  const value = fixture(); value.addRelease(); value.addChange({impact: 'none'});
  assert.equal((await value.run()).status, 'idle');
  const explicit = await value.run({publicationRequired: true}); assert.equal(explicit.version, '1.0.1'); assert.equal(explicit.status, 'prepare');
});

test('publication boundary is selected by source ancestry instead of release order', async () => {
  const value = fixture(); value.addRelease(); value.addChange({version: '1.0.1'}); const latest = value.addRelease(value.current(), '1.0.1');
  value.addChange({version: '1.0.1'}); value.releases.reverse();
  const result = await value.run(); assert.equal(result.record.baseline.releaseId, latest.id); assert.equal(result.version, '1.0.2');
});

test('reviewed compatible major source impact retains its explicit version semantics', async () => {
  const value = fixture(); value.addRelease(); value.addChange({impact: 'major'});
  assert.equal((await value.run()).version, '2.0.0');
});

test('exact published source is a no-op despite unrelated unavailable release evidence', async () => {
  const value = fixture(); value.addRelease();
  const foreign = value.addCommit(value.root.sha, '2.0.0'); const unrelated = value.addRelease(foreign, '2.0.0'); value.failures.add(unrelated.id);
  value.state.unavailableList = true;
  assert.equal((await value.run({publicationRequired: true})).status, 'unchanged');
  assert.ok(!value.calls.includes('/releases?per_page=100&page=1'));
});

test('authenticated bootstrap approves initial free version without fabricated publication or bump', async () => {
  const value = fixture(); value.addChange({version: '2.5.0'}); const bootstrap = value.bootstrap('2.5.0');
  const result = await value.run({bootstrap: bootstrap.subject});
  assert.equal(result.status, 'ready'); assert.equal(result.version, '2.5.0'); assert.equal(result.record.baseline, null);
  assert.deepEqual(result.record.bootstrap.subject, bootstrap.subject);
  assert.equal(result.record.bootstrap.review.artifactId, bootstrap.artifact.artifact.id);
});

test('bootstrap preserves approved sufficient initial version and accounts later source changes', async () => {
  const value = fixture(); value.addChange({version: '2.5.0'}); const bootstrap = value.bootstrap('2.0.0');
  assert.equal((await value.run({bootstrap: bootstrap.subject})).version, '2.5.0');
  value.addChange({impact: 'minor', version: '2.5.0'});
  assert.equal((await value.run({bootstrap: bootstrap.subject})).version, '2.5.0');
});

for (const [name, mutate] of [
  ['unmapped main commit', v => {v.associated.clear();}],
  ['multiple merged owners', v => {const rows = v.associated.get(v.current().sha); rows.push({...rows[0], id: 900, number: 900});}],
  ['unmerged pull', (v, c) => {c.pull.merged = false;}],
  ['foreign source repository', (v, c) => {c.pull.head.repo.id++;}],
  ['changed declaration after review', (v, c) => {c.pull.body = impactBlock(declaration('minor'));}],
  ['missing declaration', (v, c) => {c.pull.body = 'No retained impact.';}],
  ['missing original owner', v => {v.reviews.clear();}],
  ['incomplete original owner', (v, c) => {c.envelope.status = 'blocked'; c.artifact.bytes = Buffer.from(JSON.stringify(c.envelope));}],
  ['source differing from review', (v, c) => {c.landed[0].tree.sha = oid(9900);}],
  ['landed base changed', (v, c) => {const unknown = v.addCommit(v.root.sha); c.landed[0].parents = [{sha: unknown.sha}];}],
  ['noncontiguous original source', (v, c) => {c.source[1].parents = [{sha: oid(9901)}];}],
  ['rebased intermediate source changed', (v, c) => {c.landed[0].tree.sha = oid(9902);}],
  ['original merge graph without correspondence', (v, c) => {c.source[0].parents.push({sha: v.root.sha});}],
  ['landed merge graph without correspondence', (v, c) => {c.landed[0].parents.push({sha: v.root.sha});}],
  ['native version classification missing', v => {v.options.classifyVersionPreparation = undefined;}],
  ['native version reader missing', v => {v.options.readVersion = undefined;}],
  ['authentic artifact callback missing', v => {v.options.authenticateReview = undefined;}],
  ['admitted release callback missing', v => {v.options.admitPublishedRelease = undefined;}],
  ['unadmitted published evidence', v => {v.failures.add(v.releases[0].id);}],
  ['mutable recorded publication', v => {v.releases[0].immutable = false;}],
  ['rewritten published history', v => {const foreign = v.addCommit(null, '2.0.0'); v.addRelease(foreign, '2.0.0');}],
  ['pending version downgrade', v => {v.options.readVersion = async () => '0.9.0';}],
  ['changed native parser source', v => {v.options.readVersion = async () => 'invalid';}],
]) test(`publication boundary refuses ${name}`, async () => {
  const value = fixture(); value.addRelease(); const change = value.addChange({count: 2}); mutate(value, change);
  await assert.rejects(value.run());
});

test('reviewed own major breaking change may publish while retaining its downstream disposition', async () => {
  const value = fixture(); value.addRelease(); const change = value.addChange();
  const breaking = {...declaration('major'), disposition: 'breaking'};
  change.pull.body = impactBlock(breaking); change.context.impact = impactInput(change.pull.body, change.subject.base, change.subject.head);
  change.envelope.retainedEvidence = Buffer.from(JSON.stringify(retainedFixture(change.context, settings))).toString('base64');
  change.artifact.bytes = Buffer.from(JSON.stringify(change.envelope));
  const result = await value.run();
  assert.equal(result.version, '2.0.0');
  assert.equal(result.record.changes[0].declaration.disposition, 'breaking');
  assert.equal(result.record.changes[0].declaration.impact, 'major');
  change.pull.body = impactBlock({...breaking, impact: 'patch'});
  change.context.impact = impactInput(change.pull.body, change.subject.base, change.subject.head);
  change.envelope.retainedEvidence = Buffer.from(JSON.stringify(retainedFixture(change.context, settings))).toString('base64');
  change.artifact.bytes = Buffer.from(JSON.stringify(change.envelope));
  await assert.rejects(value.run(), /major declaration/);
});

test('legacy version cannot be reused by a bootstrap with different source', async () => {
  const value = fixture(); value.addRelease(value.root, '1.0.0', true); value.addChange(); const bootstrap = value.bootstrap();
  await assert.rejects(value.run({bootstrap: bootstrap.subject}), /already published/);
});

test('a free bootstrap version cannot silently downgrade an existing legacy public version', async () => {
  const value = fixture(); value.addRelease(value.root, '2.0.0', true); value.addChange(); const bootstrap = value.bootstrap();
  await assert.rejects(value.run({bootstrap: bootstrap.subject}), /cannot downgrade/);
});

test('absence of admitted publication requires original reviewed bootstrap authority', async () => {
  const value = fixture(); const change = value.addChange();
  await assert.rejects(value.run(), /authenticated bootstrap/);
  await assert.rejects(value.run({bootstrap: {...change.subject, landed: value.current().sha}}), /did not approve bootstrap/);
});

test('bootstrap retains original reviewed subject across a proved multi-commit rebase', async () => {
  const value = fixture(); const change = value.addChange({count: 2, version: '2.5.0'});
  change.context.bootstrap = {boundary: change.subject, initialVersion: '2.5.0', disposition: 'compatible', rationale: 'Explicit initial source review.'};
  change.envelope.retainedEvidence = Buffer.from(JSON.stringify(retainedFixture(change.context, settings))).toString('base64');
  change.artifact.bytes = Buffer.from(JSON.stringify(change.envelope));
  const result = await value.run({bootstrap: {...change.subject, landed: value.current().sha}});
  assert.equal(result.status, 'ready'); assert.equal(result.version, '2.5.0');
  assert.equal(result.record.bootstrap.subject.head, change.source.at(-1).sha);
  assert.equal(result.record.bootstrap.correspondence.head, value.current().sha);
});

test('self-authored bootstrap JSON cannot replace an authenticated owner envelope', async () => {
  const value = fixture(); value.addChange(); const bootstrap = value.bootstrap();
  value.options.authenticateReview = async () => bootstrap.context;
  await assert.rejects(value.run({bootstrap: bootstrap.subject}));
});

test('source movement during boundary observation prevents publication', async () => {
  const value = fixture(); value.addRelease(); value.addChange(); let reads = 0;
  value.state.onRequest = path => {
    if (path === '/git/ref/heads/main' && ++reads === 2) value.setMain(value.root.sha);
  };
  await assert.rejects(value.run(), /source changed/);
});

test('intent encloses a computed boundary at its existing value limit and a full-sized manifest', async () => {
  const f = fixture(); f.addRelease();
  const contracts = Array.from({length: 128}, (_, index) => `contract${index}`);
  for (let index = 0; index < 221; index++) f.addChange({contracts});
  f.addChange({contracts: contracts.slice(0, 19)});
  const boundary = await f.run();
  const count = value => 1 + (value !== null && typeof value === 'object' ?
    Object.values(value).reduce((total, child) => total + count(child), 0) : 0);
  assert.equal(boundary.status, 'prepare'); assert.equal(count(boundary.record), 32768);
  assert.deepEqual(encodeRecord(boundary.record), boundary.bytes);
  assert.ok(boundary.bytes.length <= maximumRecordBytes);
  const actor = {id: 42, login: 'horos-release[bot]'};
  const person = {name: actor.login, email: `${actor.id}+${actor.login}@users.noreply.github.com`, date: '2026-10-30T00:00:00Z'};
  const manifestBytes = Buffer.alloc(maximumRecordBytes, 0x20);
  Buffer.from(`.{ .name = .horos, .version = "${boundary.version}" }\n`).copy(manifestBytes);
  const candidate = {base: boundary.record.source.commit, tree: oid(99999), version: boundary.version,
    manifestBytes, author: person, committer: person};
  candidate.message = proposalMessage(candidate); candidate.head = proposalCommitOid(candidate);
  const bytes = encodeWriterIntent({candidate, boundary, controlCommit: candidate.base,
    runId: 12, workflowSha256: 'a'.repeat(64), identity: {appId: 9, installationId: 10}, actor,
    toolSha256: 'b'.repeat(64), branchBefore: null});
  assert.ok(bytes.length > maximumRecordBytes);
  const admitted = readWriterIntentBytes(bytes);
  assert.deepEqual(admitted.candidate, candidate); assert.deepEqual(admitted.value.boundary, boundary.record);
  assert.equal(admitted.value.boundarySha256, boundary.sha256);
});
