import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {GitHubReader, githubCommand} from './github.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readReviewResult, reviewEnvelope} from './review-result.mjs';
import {validateRetainedReview} from './review-owner.mjs';
import {workflowPages} from './workflow-artifact.mjs';
import {admitPublishedRelease} from './release-admission.mjs';
import {sha256} from './encoding.mjs';
import {sourceManifest, prepareHorosCandidate, classifyNativeVersion} from './native-manifest.mjs';
import {expectedReviewSettings} from './review-check.mjs';
import {proposalBranch, describedProposalSubject} from './proposal.mjs';

export async function observation(client, path, missing = false) {
  const response = await client.request({path});
  if (missing && response.status === 404) return null;
  assert.equal(response.status, 200, `repository observation unavailable: ${path}`);
  return response.body;
}

export async function observationPages(client, path) {
  const values = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const rows = await observation(client, `${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    assert.ok(Array.isArray(rows) && rows.length <= 100);
    for (const row of rows) {
      assert.ok(Number.isSafeInteger(row.id) && row.id > 0 && !seen.has(row.id), 'repository pagination changed');
      seen.add(row.id); values.push(row);
    }
    if (rows.length < 100) return values;
  }
  throw new Error('repository observation capacity exceeded');
}

export async function currentHorosSource(client = new HorosProposalClient()) {
  const repository = await observation(client, '');
  assert.equal(repository.full_name, 'tkersey/horos'); assert.equal(repository.id, 1176152390);
  assert.equal(repository.default_branch, 'main');
  const ref = await observation(client, '/git/ref/heads/main');
  assert.equal(ref.ref, 'refs/heads/main'); assert.equal(ref.object.type, 'commit');
  assert.match(ref.object.sha, /^[0-9a-f]{40}$/);
  const commit = await observation(client, `/git/commits/${ref.object.sha}`);
  assert.equal(commit.sha, ref.object.sha); assert.match(commit.tree.sha, /^[0-9a-f]{40}$/);
  return {commit: commit.sha, tree: commit.tree.sha};
}

export async function appActor(identity, command = githubCommand) {
  assert.equal(identity.repository, 'tkersey/horos'); assert.equal(identity.repositoryId, 1176152390);
  assert.ok(Number.isSafeInteger(identity.appId) && identity.appId > 0);
  assert.match(identity.login, /^[a-z0-9][a-z0-9-]*\[bot\]$/);
  const actor = parseEvidenceJson(await command(['api', `users/${encodeURIComponent(identity.login)}`]));
  assert.equal(actor.login, identity.login); assert.equal(actor.type, 'Bot');
  assert.ok(Number.isSafeInteger(actor.id) && actor.id > 0);
  return {id: actor.id, login: actor.login};
}

export async function storedHorosCandidate(head, {client, native, actor}) {
  assert.match(head, /^[0-9a-f]{40}$/);
  const commit = await observation(client, `/git/commits/${head}`);
  assert.equal(commit.sha, head); assert.equal(commit.parents.length, 1);
  const manifest = await sourceManifest(client, head);
  const candidate = await prepareHorosCandidate({base: commit.parents[0].sha, version: native.read(manifest), actor}, {client, native});
  assert.ok(candidate, 'original proposal had no native version change');
  assert.equal(candidate.head, head, 'unknown branch source differs from native preparation');
  assert.equal(candidate.tree, commit.tree.sha); assert.equal(candidate.message, commit.message);
  assert.deepEqual(candidate.manifestBytes, manifest);
  return candidate;
}

export async function preparationPulls(client) {
  const values = await observationPages(client, `/pulls?state=all&head=tkersey:${encodeURIComponent(proposalBranch)}`);
  for (const pull of values) {
    assert.equal(pull.head.ref, proposalBranch); assert.equal(pull.head.repo.id, 1176152390);
    assert.equal(pull.base.ref, 'main'); assert.equal(pull.base.repo.id, 1176152390);
  }
  assert.ok(values.filter(pull => pull.state === 'open').length <= 1, 'multiple open preparation PRs');
  return values.sort((left, right) => right.number - left.number);
}

async function definition(client, path, commit) {
  const value = await observation(client, `/contents/${path}?ref=${commit}`);
  assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
  const bytes = Buffer.from(value.content.replaceAll('\n', ''), 'base64');
  return {path, commit, sha256: sha256(bytes), bytes};
}

export async function promotionRequirements(base, appId, client) {
  assert.match(base, /^[0-9a-f]{40}$/); assert.ok(Number.isSafeInteger(appId) && appId > 0);
  const items = await Promise.all(['.github/workflows/repository-automation.yml', '.github/workflows/repository-review.yml',
    '.github/workflows/zig.yml', 'docs/repository-local-releases.md'].map(path => definition(client, path, base)));
  const [control, review, qualification, accepted] = items;
  const withoutBytes = ({path, commit, sha256}) => ({path, commit, sha256});
  return {control: withoutBytes(control), reviewWorkflow: withoutBytes(review),
    qualificationWorkflow: {path: qualification.path, sha256: qualification.sha256},
    checks: {qualification: {name: 'native', appId: 15368}, review: {name: 'Repository owner review', appId}},
    reviews: {requiredApprovingReviewCount: 0, dismissStaleReviews: false, requireCodeOwnerReviews: false, requireLastPushApproval: false},
    acceptedRequirements: {...withoutBytes(accepted), text: accepted.bytes.toString('utf8')}, reviewSettings: {...expectedReviewSettings}};
}

export async function findHorosBootstrap(source, command = githubCommand) {
  const reader = new GitHubReader('tkersey/horos', command), subjects = new Map();
  const artifacts = await workflowPages(reader, 'actions/artifacts', 'artifacts');
  for (const artifact of artifacts) {
    if (artifact.workflow_run?.repository_id !== 1176152390 || artifact.workflow_run?.head_repository_id !== 1176152390 ||
      artifact.workflow_run?.head_branch !== 'main') continue;
    const match = /^bootstrap-review-([0-9a-f]{40})-([0-9a-f]{40})\.json$/.exec(artifact.name);
    if (match) subjects.set(`${match[1]}:${match[2]}`, {base: match[1], head: match[2]});
  }
  assert.ok(subjects.size <= 64, 'bootstrap evidence capacity exceeded');
  let selected = null;
  for (const subject of subjects.values()) {
    if (!await reader.forward(subject.head, source.commit)) continue;
    const commit = await reader.api(`git/commits/${subject.head}`);
    const value = await readReviewResult({repository: reader.repository, ...subject, tree: commit.tree.sha, purpose: 'bootstrap'}, command);
    if (value.status !== 'complete') continue;
    if (selected !== null) {
      assert.notEqual(subject.head, selected.head, 'ambiguous bootstrap dispositions for one source');
      if (await reader.forward(subject.head, selected.head)) continue;
      assert.ok(await reader.forward(selected.head, subject.head), 'bootstrap ranges diverge');
    }
    selected = {...subject, tree: commit.tree.sha};
  }
  return selected;
}

export function horosBoundaryOperations({client = new HorosProposalClient(), native, actor, command = githubCommand}) {
  return {client,
    readVersion: ({manifestBytes}) => native.read(manifestBytes),
    classifyVersionPreparation: classifyNativeVersion({client, native, actor}),
    findBootstrap: source => findHorosBootstrap(source, command),
    authenticateReview: async subject => {
      const result = await readReviewResult({repository: 'tkersey/horos', ...subject}, command);
      assert.equal(result.status, 'complete', 'original owner closeout unavailable');
      const retained = validateRetainedReview(Buffer.from(result.envelope.retainedEvidence, 'base64'), subject);
      for (const [key, value] of Object.entries(expectedReviewSettings)) assert.equal(retained.binding[key], value, `original review runtime differs: ${key}`);
      return result;
    },
    admitPublishedRelease: async selection => {
      const directory = mkdtempSync(join(tmpdir(), 'horos-admission-'));
      try { return await admitPublishedRelease({...selection, outputDirectory: join(directory, 'release')}, command); }
      finally { rmSync(directory, {recursive: true, force: true}); }
    },
  };
}

export async function originalHorosQualification(head, command = githubCommand) {
  assert.match(head, /^[0-9a-f]{40}$/);
  const reader = new GitHubReader('tkersey/horos', command);
  const runs = await workflowPages(reader, `actions/workflows/zig.yml/runs?head_sha=${head}&event=pull_request`, 'workflow_runs');
  assert.ok(runs.length <= 1, 'duplicate original qualification cannot authorize automation');
  if (runs.length === 0) return null;
  const run = await reader.api(`actions/runs/${runs[0].id}`);
  assert.equal(run.id, runs[0].id); assert.equal(run.head_sha, head); assert.equal(run.event, 'pull_request');
  assert.equal(run.repository.id, 1176152390); assert.equal(run.head_repository.id, 1176152390);
  assert.equal(run.path, '.github/workflows/zig.yml'); assert.equal(run.run_attempt, 1);
  return run;
}

export function retireHorosProposal({client, native, actor, command = githubCommand, readResult = readReviewResult, readCandidate = storedHorosCandidate}) {
  return async ({pull, knownHead, candidate, previousSubject = describedProposalSubject(pull.body)}) => {
    assert.equal(pull.head.sha, knownHead);
    assert.ok(knownHead === previousSubject.head || knownHead === candidate?.head,
      'live branch differs from the described predecessor and admitted successor');
    const previousCandidate = await readCandidate(previousSubject.head, {client, native, actor});
    assert.equal(previousCandidate.head, previousSubject.head); assert.equal(previousCandidate.base, previousSubject.base);
    const subject = {repository: 'tkersey/horos', base: previousCandidate.base, head: previousCandidate.head,
      tree: previousCandidate.tree, purpose: 'pull'};
    const result = await readResult(subject, command);
    if (result.status === 'absent') {
      const run = await originalHorosQualification(previousCandidate.head, command);
      assert.ok(run !== null && run.status === 'completed' &&
        ['failure', 'timed_out', 'cancelled', 'startup_failure'].includes(run.conclusion),
      'unreviewed subject can retire only after its unique original qualification failed');
      return {epochClosed: true, previousCandidate, qualificationFailure: {runId: run.id, conclusion: run.conclusion}};
    }
    assert.ok(['complete', 'blocked'].includes(result.status), 'original owner epoch is still active');
    assert.ok(Buffer.isBuffer(result.bytes), 'authenticated original owner disposition missing');
    const envelope = reviewEnvelope(result.bytes, subject);
    assert.equal(envelope.context.pullNumber, pull.number); assert.equal(envelope.context.bootstrap, undefined);
    assert.equal(envelope.epochClosed, true, 'original owner did not close its epoch');
    return {epochClosed: true, previousCandidate, review: {runId: result.run.id, artifactId: result.artifact.id, sha256: sha256(result.bytes)}};
  };
}
