import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {encodeRecord, sha256} from './encoding.mjs';
import {requireCurrentImpact, validateImpact} from './impact.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {readRecord} from './record.mjs';
import {reviewEnvelope} from './review-result.mjs';
import {parseVersion, prepareVersion} from './version.mjs';

const repository = 'tkersey/horos', repositoryId = 1176152390;
const oid = value => {assert.match(value, /^[0-9a-f]{40}$/); return value;};
const id = value => {assert.ok(Number.isSafeInteger(value) && value > 0); return value;};
const compareVersions = (left, right) => {
  const a = parseVersion(left), b = parseVersion(right);
  for (let index = 0; index < 3; index++) if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  return 0;
};

async function get(client, path, missing = false) {
  const response = await client.request({path});
  if (missing && response.status === 404) return null;
  assert.equal(response.status, 200, `publication boundary observation unavailable: ${path}`);
  return response.body;
}

async function pages(client, path, identity = 'id') {
  const values = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const rows = await get(client, `${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    assert.ok(Array.isArray(rows) && rows.length <= 100);
    for (const row of rows) {
      const key = row[identity];
      if (identity === 'sha') oid(key); else id(key);
      assert.ok(!seen.has(key), 'publication boundary pagination changed'); seen.add(key); values.push(row);
    }
    if (rows.length < 100) return values;
  }
  throw new Error('publication boundary observation capacity exceeded');
}

async function commit(client, sha) {
  const value = await get(client, `/git/commits/${oid(sha)}`);
  assert.equal(value.sha, sha); oid(value.tree.sha);
  assert.ok(Array.isArray(value.parents) && value.parents.length <= 2);
  for (const parent of value.parents) oid(parent.sha);
  return value;
}

async function forward(client, base, head) {
  if (base === head) return true;
  const value = await get(client, `/compare/${oid(base)}...${oid(head)}`);
  assert.equal(value.base_commit.sha, base);
  return value.status === 'ahead' && value.merge_base_commit.sha === base;
}

async function manifest(client, sha) {
  const value = await get(client, `/contents/build.zig.zon?ref=${oid(sha)}`);
  assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
  assert.ok(typeof value.content === 'string' && value.content.length <= 2 * 1024 * 1024);
  const bytes = Buffer.from(value.content.replaceAll('\n', ''), 'base64');
  assert.ok(bytes.length > 0 && bytes.length <= 1024 * 1024);
  assert.equal(createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex'), value.sha,
    'manifest bytes differ from captured Git blob');
  return bytes;
}

async function admittedPublication(client, release, options) {
  id(release.id); assert.equal(release.draft, false); assert.equal(release.prerelease, false);
  const assets = await pages(client, `/releases/${release.id}/assets`);
  const records = assets.filter(value => value.name === 'release.json');
  assert.ok(records.length <= 1, 'ambiguous published record');
  if (records.length === 0) return null;
  assert.equal(release.immutable, true, 'recorded publication is mutable');
  const admitted = await options.admitPublishedRelease({repository, releaseId: release.id});
  assert.equal(admitted.id, release.id);
  const recordBytes = encodeRecord(admitted.record), record = readRecord(recordBytes);
  assert.equal(admitted.recordSha256, sha256(recordBytes));
  assert.equal(record.repository.name, repository); assert.equal(record.repository.id, repositoryId);
  assert.equal(record.tag, release.tag_name);
  const actual = await commit(client, record.source.commit);
  assert.equal(actual.tree.sha, record.source.tree);
  return {releaseId: release.id, recordSha256: admitted.recordSha256, source: record.source};
}

async function originalReview(subject, options, pull = null) {
  const artifact = await options.authenticateReview(subject);
  assert.ok(Buffer.isBuffer(artifact.bytes)); id(artifact.run.id); id(artifact.artifact.id);
  const envelope = reviewEnvelope(artifact.bytes, {repository, ...subject});
  assert.equal(envelope.status, 'complete', 'publication boundary review incomplete');
  const impact = pull === null ? envelope.context.impact.declaration :
    requireCurrentImpact(envelope.context.impact, pull.body, subject.base, subject.head);
  validateImpact(impact);
  if (pull === null) {
    assert.equal(envelope.context.impact.base, subject.base); assert.equal(envelope.context.impact.head, subject.head);
    assert.equal(envelope.context.impact.sha256, sha256(encodeRecord({base: subject.base, head: subject.head, declaration: impact})));
  }
  if (impact.disposition === 'breaking') assert.equal(impact.impact, 'major', 'breaking public contracts require a major declaration');
  options.retainedReviews.set(sha256(artifact.bytes), Buffer.from(artifact.bytes));
  return {context: envelope.context, impact, artifact: {runId: artifact.run.id,
    artifactId: artifact.artifact.id, sha256: sha256(artifact.bytes)}};
}

async function mergedChange(client, end, options) {
  const associated = await pages(client, `/commits/${end.sha}/pulls`);
  const matches = associated.filter(pull => pull.merged_at !== null && pull.merge_commit_sha === end.sha &&
    pull.base?.ref === 'main' && pull.base.repo?.id === repositoryId && pull.head?.repo?.id === repositoryId);
  assert.equal(matches.length, 1, 'source commit lacks a unique merged local change');
  const pull = await get(client, `/pulls/${id(matches[0].number)}`);
  assert.equal(pull.number, matches[0].number); assert.equal(pull.id, matches[0].id);
  assert.equal(pull.state, 'closed'); assert.equal(pull.merged, true);
  assert.ok(Number.isFinite(Date.parse(pull.merged_at))); assert.equal(pull.merge_commit_sha, end.sha);
  assert.equal(pull.base.ref, 'main'); assert.equal(pull.base.repo.id, repositoryId); assert.equal(pull.head.repo.id, repositoryId);
  const originalRows = await pages(client, `/pulls/${pull.number}/commits`, 'sha');
  assert.ok(originalRows.length > 0, 'merged change has no original commits');
  assert.equal(originalRows.at(-1).sha, pull.head.sha);
  const originals = [];
  for (const row of originalRows) {
    const value = await commit(client, row.sha);
    assert.equal(value.parents.length, 1, 'original merge graph needs explicit owner correspondence');
    if (originals.length > 0) assert.equal(value.parents[0].sha, originals.at(-1).sha, 'original change is not a contiguous source chain');
    originals.push(value);
  }
  const base = originals[0].parents[0].sha, head = originals.at(-1), actual = [];
  assert.equal(head.tree.sha, end.tree.sha, 'merged source differs from original reviewed source');
  let current = end;
  for (let index = originals.length - 1; index >= 0; index--) {
    assert.equal(current.parents.length, 1, 'landed merge graph needs explicit owner correspondence');
    actual.unshift(current);
    if (current.parents[0].sha === base) break;
    assert.equal(current.tree.sha, originals[index].tree.sha, 'rebased intermediate source differs from original');
    current = await commit(client, current.parents[0].sha);
  }
  assert.equal(actual[0].parents[0].sha, base, 'landed base changed; explicit owner correspondence required');
  assert.ok(actual.length === 1 || actual.length === originals.length, 'ambiguous partial squash correspondence');
  if (actual.length === originals.length) {
    for (let index = 0; index < actual.length; index++) assert.equal(actual[index].tree.sha, originals[index].tree.sha);
  }
  const subject = {base, head: head.sha, tree: head.tree.sha}, review = await originalReview(subject, options, pull);
  const baseline = await commit(client, base);
  const [baseManifestBytes, manifestBytes] = await Promise.all([manifest(client, base), manifest(client, head.sha)]);
  const classification = await options.classifyVersionPreparation({subject, pull: structuredClone(pull),
    context: structuredClone(review.context), baseTree: baseline.tree.sha,
    baseManifestBytes, manifestBytes, originalCommits: structuredClone(originals)});
  assert.equal(typeof classification.versionOnly, 'boolean', 'native version-only classification missing');
  return {context: review.context, record: {base, head: end.sha, pull: pull.number, subject,
    landedCommits: actual.map(value => value.sha), review: review.artifact,
    declaration: review.impact, versionOnly: classification.versionOnly}};
}

function result(source, pending, version, status, baseline, changes, bootstrap = null) {
  const record = {schema: 'repository-publication-boundary/v1', repository, source, pendingVersion: pending,
    version, status, baseline, bootstrap, changes};
  const bytes = encodeRecord(record);
  return {status, version, record, bytes, sha256: sha256(bytes), reviewArtifacts: new Map()};
}

export async function computeHorosPublicationBoundary({source: input, publicationRequired = false, bootstrap}, inputOptions) {
  const source = structuredClone(input); oid(source.commit); oid(source.tree);
  assert.equal(typeof publicationRequired, 'boolean');
  for (const name of ['admitPublishedRelease', 'authenticateReview', 'readVersion', 'classifyVersionPreparation']) {
    assert.equal(typeof inputOptions[name], 'function', `${name} trusted procedure required`);
  }
  const options = {...inputOptions, retainedReviews: new Map(), client: inputOptions.client ?? new HorosProposalClient()}, client = options.client;
  const repo = await get(client, '');
  assert.equal(repo.full_name, repository); assert.equal(repo.id, repositoryId); assert.equal(repo.default_branch, 'main');
  const main = await get(client, '/git/ref/heads/main');
  assert.equal(main.ref, 'refs/heads/main'); assert.equal(main.object.type, 'commit'); assert.equal(main.object.sha, source.commit);
  const current = await commit(client, source.commit); assert.equal(current.tree.sha, source.tree);
  const manifestBytes = await manifest(client, source.commit);
  const pending = await options.readVersion({source: structuredClone(source), manifestBytes}); parseVersion(pending);
  const direct = await get(client, `/releases/tags/v${pending}`, true);
  const cached = new Map(), errors = [];
  if (direct !== null && !direct.draft && !direct.prerelease) {
    try {
      const admitted = await admittedPublication(client, direct, options); cached.set(direct.id, admitted);
      if (admitted?.source.commit === source.commit) {
        assert.equal(admitted.source.tree, source.tree); assert.equal(admitted.source.version, pending);
        return result(source, pending, pending, 'unchanged', admitted, []);
      }
    } catch (error) {errors.push(error);}
  }
  const releases = (await pages(client, '/releases')).filter(value => !value.draft && !value.prerelease);
  const admitted = [], versions = new Set();
  for (const release of releases) {
    assert.equal(typeof release.draft, 'boolean'); assert.equal(typeof release.prerelease, 'boolean');
    if (/^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(release.tag_name)) {
      const version = release.tag_name.slice(1); parseVersion(version);
      assert.ok(!versions.has(version), 'ambiguous published version'); versions.add(version);
    }
    try {
      const value = cached.has(release.id) ? cached.get(release.id) : await admittedPublication(client, release, options);
      if (value === null) continue;
      if (value.source.commit === source.commit) {
        assert.equal(value.source.tree, source.tree); assert.equal(value.source.version, pending);
        return result(source, pending, pending, 'unchanged', value, []);
      }
      admitted.push(value);
    } catch (error) {errors.push(error);}
  }
  if (errors.length > 0) throw new AggregateError(errors, 'publication discovery has unadmitted evidence');
  let baseline = null;
  for (const value of admitted) {
    assert.ok(await forward(client, value.source.commit, source.commit), 'published history is not an ancestor of frozen source');
    if (baseline === null || await forward(client, baseline.source.commit, value.source.commit)) baseline = value;
    else assert.ok(await forward(client, value.source.commit, baseline.source.commit), 'published boundaries are not ordered');
  }
  let stop, initialVersion, bootstrapEvidence = null;
  if (baseline === null) {
    assert.ok(bootstrap, 'missing admitted publication requires an authenticated bootstrap review');
    const subject = {base: oid(bootstrap.base), head: oid(bootstrap.head), tree: oid(bootstrap.tree)};
    const actual = await commit(client, subject.head); assert.equal(actual.tree.sha, subject.tree);
    assert.ok(await forward(client, subject.base, subject.head), 'bootstrap range is not forward source history');
    let review, correspondence = null;
    if (bootstrap.landed !== undefined) {
      const end = await commit(client, oid(bootstrap.landed)), mapped = await mergedChange(client, end, options);
      assert.deepEqual(mapped.record.subject, subject, 'bootstrap landing differs from original reviewed range');
      assert.ok(await forward(client, end.sha, source.commit), 'bootstrap landing is outside frozen source history');
      review = {context: mapped.context, impact: mapped.record.declaration, artifact: mapped.record.review};
      correspondence = mapped.record; stop = end.sha;
    } else {
      assert.ok(await forward(client, subject.head, source.commit), 'bootstrap is outside frozen source history');
      review = await originalReview(subject, options); stop = subject.head;
    }
    const disposition = review.context.bootstrap;
    assert.ok(disposition, 'original owner did not approve bootstrap');
    assert.deepEqual(disposition.boundary, subject); parseVersion(disposition.initialVersion);
    assert.equal(disposition.disposition, review.impact.disposition, 'bootstrap compatibility contradicts original declaration');
    assert.ok(typeof disposition.rationale === 'string' && disposition.rationale.length > 0);
    initialVersion = disposition.initialVersion;
    bootstrapEvidence = {subject, initialVersion, disposition: disposition.disposition,
      rationale: disposition.rationale, declaration: review.impact, review: review.artifact, correspondence};
  } else {stop = baseline.source.commit; initialVersion = baseline.source.version;}
  const changes = [], seen = new Set();
  let cursor = current;
  while (cursor.sha !== stop) {
    assert.ok(changes.length < 10000 && !seen.has(cursor.sha), 'unreleased history capacity or cycle'); seen.add(cursor.sha);
    const {record: change} = await mergedChange(client, cursor, options);
    assert.ok(await forward(client, stop, change.base), 'change crosses the admitted publication boundary');
    changes.unshift(change); cursor = await commit(client, change.base);
  }
  assert.ok(compareVersions(pending, initialVersion) >= 0, 'pending version predates approved source boundary');
  const declarations = changes.filter(change => !change.versionOnly).map(change => change.declaration.impact);
  const substantive = declarations.some(impact => impact !== 'none');
  const preparation = changes.some(change => change.versionOnly && change.declaration.impact !== 'none');
  let version = pending;
  if (baseline !== null || declarations.length > 0) {
    version = prepareVersion({published: initialVersion, pending, declarations: declarations.length > 0 ? declarations : ['none'],
      publicationRequired: publicationRequired || substantive || preparation});
  }
  const needed = publicationRequired || substantive || preparation || baseline === null;
  if (needed) {
    assert.ok(!versions.has(version), 'approved pending version is already published for different source');
    for (const previous of versions) assert.ok(compareVersions(version, previous) > 0,
      'automatic publication cannot downgrade an existing public version');
  }
  const after = await get(client, '/git/ref/heads/main'); assert.deepEqual(after, main, 'publication source changed while computing boundary');
  return {...result(source, pending, version, !needed ? 'idle' : version === pending ? 'ready' : 'prepare', baseline, changes, bootstrapEvidence),
    reviewArtifacts: options.retainedReviews};
}
