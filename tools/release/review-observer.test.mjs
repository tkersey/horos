import {createHash} from 'node:crypto';
import {readReviewResult, reviewNames, authenticateReviewContinuation} from './review-result.mjs';
import {retainedFixture} from './promotion-test-support.mjs';
import {expectedReviewSettings, reportHorosReview} from './review-check.mjs';
import {markHorosReviewStarted} from './review-start.mjs';
import {retireHorosProposal, storedHorosCandidate} from './release-observation.mjs';
import {proposalBranch, proposalDescription, rootTree} from './proposal.mjs';
import {prepareHorosCandidate} from './native-manifest.mjs';
import assert from 'node:assert/strict';
import test from 'node:test';
import {observeHorosReview} from './review-observer.mjs';
import {impactBlock, versionPreparationImpact} from './impact.mjs';
import {sha256} from './encoding.mjs';
import {horosJobs} from './qualification.mjs';

const base = 'a'.repeat(40), head = 'b'.repeat(40), tree = 'c'.repeat(40);

function fixture() {
  const mode = {status: 200, body: {name: 'REPOSITORY_AUTOMATION', value: 'propose'}};
  const main = {ref: 'refs/heads/main', object: {type: 'commit', sha: base}};
  const pull = {number: 4, state: 'open', draft: false, labels: [], title: 'Prepare version',
    body: impactBlock(versionPreparationImpact), base: {sha: base, ref: 'main', repo: {id: 1176152390}},
    head: {sha: head, ref: 'automation/dependency-release', repo: {id: 1176152390}}};
  const run = {id: 10, status: 'completed', conclusion: 'success'};
  const evidence = Buffer.from('original verified qualification fixture');
  const qualification = {run: {...run, html_url: 'https://github.com/tkersey/horos/actions/runs/10'}, evidence,
    workflow: {path: '.github/workflows/zig.yml', commit: head, sha256: sha256(Buffer.from('qualification definition'))},
    jobs: Object.keys(horosJobs).map((name, index) => ({id: index + 20, name, conclusion: 'success'}))};
  const responses = new Map([
    ['', {full_name: 'tkersey/horos', id: 1176152390, default_branch: 'main'}],
    ['/git/ref/heads/main', main],
    ['/pulls?state=open&base=main&per_page=100&page=1', [pull]],
    ['/pulls/4', pull],
    [`/git/commits/${head}`, {sha: head, tree: {sha: tree}, parents: [{sha: base}]}],
    [`/actions/workflows/zig.yml/runs?head_sha=${head}&event=pull_request&per_page=100&page=1`, {workflow_runs: [run]}],
    [`/contents/docs/repository-local-releases.md?ref=${base}`, {type: 'file', encoding: 'base64', content: Buffer.from('Accepted local fixture requirements').toString('base64')}],
  ]);
  let qualified = 0;
  const command = async args => {
    const key = args[1].slice('repos/tkersey/horos'.length);
    assert.ok(responses.has(key), `unexpected observer API ${key}`);
    const value = responses.get(key); return Buffer.isBuffer(value) ? Buffer.from(value) : Buffer.from(JSON.stringify(value));
  };
  const client = {request: async ({path, method}) => {
    assert.equal(method, undefined);
    if (path === '/actions/variables/REPOSITORY_AUTOMATION') return mode;
    assert.ok(responses.has(path), `unexpected client API ${path}`);
    return {status: 200, body: structuredClone(responses.get(path))};
  }};
  const qualify = async options => {
    qualified++;
    assert.deepEqual(options, {runId: 10, commit: pull.head.sha,
      tree: responses.get(`/git/commits/${pull.head.sha}`).tree.sha, event: 'pull_request'});
    assert.equal(run.conclusion, 'success', 'original qualification failed');
    return qualification;
  };
  let prior = null;
  const observe = (controlCommit = base, previousReader = async () => prior) => observeHorosReview({controlCommit}, command, client,
    previousReader === null ? undefined : previousReader, qualify);
  return {mode, main, pull, run, responses, qualification, command, client, observe, qualified: () => qualified, setPrior: value => {prior = value;}};
}

test('qualification inventory remains independently fixed by the repository contract', () => {
  assert.deepEqual(Object.keys(horosJobs).sort(), ['Source preflight', 'Qualification / installation',
    'Qualification / contracts', 'Release tooling', 'native'].sort());
});

test('read-only observer binds exact original qualification, impact and requirements before owner dispatch', async () => {
  const value = fixture(), result = await value.observe();
  assert.equal(result.status, 'ready'); assert.equal(value.qualified(), 1);
  assert.equal(result.context.base, base); assert.equal(result.context.head, head); assert.equal(result.context.tree, tree);
  assert.equal(result.context.qualification.evidenceSha256, sha256(value.qualification.evidence));
  assert.deepEqual(Buffer.from(result.context.qualification.originalEvidence, 'base64'), value.qualification.evidence);
  assert.equal(result.context.proof_inventory.length, 5); assert.equal(result.previous, null);
});

test('missing control defaults off without qualification or model admission', async () => {
  const value = fixture(); value.mode.status = 404;
  assert.equal((await value.observe()).status, 'disabled'); assert.equal(value.qualified(), 0);
});

test('uncompleted original qualification stays pending and is never replaced', async () => {
  const value = fixture(); value.run.status = 'in_progress';
  const result = await value.observe();
  assert.equal(result.status, 'waiting'); assert.equal(result.observations[0].status, 'qualification pending');
  assert.equal(value.qualified(), 0);
});

for (const [name, change] of [
  ['failed original qualification', value => {value.run.conclusion = 'failure';}],
  ['duplicate favorable run', value => {value.responses.get(`/actions/workflows/zig.yml/runs?head_sha=${head}&event=pull_request&per_page=100&page=1`).workflow_runs.push({...value.run, id: 11});}],
  ['missing declaration', value => {value.pull.body = 'No reviewed impact.';}],
  ['stale pull base', value => {value.pull.base.sha = tree;}],
]) {
  test(`observer blocks ${name}`, async () => {
    const value = fixture(); change(value);
    const result = await value.observe(); assert.equal(result.status, 'waiting');
    assert.equal(result.observations[0].status, 'blocked');
  });
}

test('pending owner state resumes unchanged original context and cannot rewrite impact', async () => {
  const value = fixture(), first = await value.observe();
  const prior = {base, value: {status: 'pending', envelope: {context: first.context}, run: {id: 40}, artifact: {id: 41},
    bytes: Buffer.from('original pending owner result'), workflow: {commit: base, sha256: 'd'.repeat(64)}}};
  value.setPrior(prior);
  const resumed = await value.observe();
  assert.equal(resumed.status, 'ready'); assert.deepEqual(resumed.context, first.context);
  assert.equal(resumed.previous.runId, 40);
  value.pull.body = impactBlock({...versionPreparationImpact, rationale: 'Changed after review.'});
  const changed = await value.observe();
  assert.equal(changed.observations[0].status, 'blocked'); assert.match(changed.observations[0].reason, /impact changed/);
});

test('terminal or already-running owner blocks a second invocation', async () => {
  for (const status of ['blocked', 'running']) {
    const value = fixture(); value.setPrior({base, value: {status, reason: 'Retain original invocation.'}});
    const result = await value.observe(); assert.equal(result.observations[0].status, status);
    assert.equal(value.qualified(), 0);
  }
});

test('draft, explicit hold and foreign candidates are not automatic review subjects', async () => {
  for (const mutate of [value => {value.pull.draft = true;}, value => {value.pull.labels = [{name: 'automation-hold'}];},
    value => {value.pull.head.repo.id++;}]) {
    const value = fixture(); mutate(value);
    assert.equal((await value.observe()).status, 'unchanged'); assert.equal(value.qualified(), 0);
  }
});

test('changed accepted main blocks the stale control checkout', async () => {
  const value = fixture(); value.main.object.sha = tree;
  await assert.rejects(value.observe(), /control checkout is stale/);
});


const advanced = 'd'.repeat(40);
const gitFile = bytes => ({type: 'file', encoding: 'base64', content: bytes.toString('base64'),
  sha: createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex')});

function advanceControl(f, control = advanced) {
  f.main.object.sha = control; f.pull.base.sha = control;
  f.responses.set(`/contents/docs/repository-local-releases.md?ref=${control}`,
    f.responses.get(`/contents/docs/repository-local-releases.md?ref=${base}`));
  if (control !== base) {
    const names = reviewNames(control, f.pull.head.sha);
    f.responses.set(`/actions/artifacts?name=${names.result}&per_page=100&page=1`, {artifacts: []});
    f.responses.set(`/actions/artifacts?name=${names.start}&per_page=100&page=1`, {artifacts: []});
  }
  f.responses.set(`/compare/${base}...${control}`, {status: base === control ? 'identical' : 'ahead',
    base_commit: {sha: base}, merge_base_commit: {sha: base}});
  f.responses.set(`/compare/${control}...${control}`, {status: 'identical', base_commit: {sha: control}, merge_base_commit: {sha: control}});
}

function reviewStorage(f, candidate) {
  const names = reviewNames(candidate.base, candidate.head);
  f.responses.set('/actions/artifacts?per_page=100&page=1', {artifacts: []});
  f.responses.set(`/actions/artifacts?name=${names.result}&per_page=100&page=1`, {artifacts: []});
  f.responses.set(`/actions/artifacts?name=${names.start}&per_page=100&page=1`, {artifacts: []});
  f.responses.set(`/commits/${candidate.head}/check-runs?filter=all&per_page=100&page=1`, {check_runs: []});
  f.responses.set('/releases?per_page=100&page=1', []);
}

function originalOwnerResult(f, context, controlCommit, status = 'complete') {
  const names = reviewNames(context.base, context.head, context.bootstrap ? 'bootstrap' : 'pull'), workflowPath = '.github/workflows/repository-review.yml';
  const envelope = {schema: 'repository-review-result/v1', status, epochClosed: status === 'complete',
    reason: 'Original test owner disposition.', turn: 1, previousSha256: null, context,
    stateSha256: status === 'pending' ? 'f'.repeat(64) : null,
    retainedEvidence: status === 'complete' ? Buffer.from(JSON.stringify(retainedFixture(context, expectedReviewSettings))).toString('base64') : null};
  const bytes = Buffer.from(JSON.stringify(envelope));
  const run = {id: 101, repository: {id: 1176152390}, head_repository: {id: 1176152390}, path: workflowPath,
    head_sha: controlCommit, head_branch: 'main', event: 'schedule', run_attempt: 1, workflow_id: 9,
    status: 'completed', conclusion: 'success', html_url: 'https://github.com/tkersey/horos/actions/runs/101'};
  const artifact = {id: 111, name: names.result, expired: false, created_at: '2026-10-30T01:00:00Z',
    size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`, workflow_run: {id: run.id,
      repository_id: 1176152390, head_repository_id: 1176152390, head_sha: controlCommit, head_branch: 'main'}};
  const job = {id: 110, run_id: run.id, run_attempt: 1, name: 'Owner review', head_sha: controlCommit,
    status: 'completed', conclusion: 'success', labels: ['ubuntu-24.04'],
    started_at: '2026-10-30T00:00:00Z', completed_at: '2026-10-30T00:01:00Z'};
  f.responses.set('/actions/artifacts?per_page=100&page=1', {artifacts: [artifact]});
  f.responses.set(`/actions/artifacts?name=${names.result}&per_page=100&page=1`, {artifacts: [artifact]});
  f.responses.set(`/actions/artifacts?name=${names.start}&per_page=100&page=1`, {artifacts: []});
  f.responses.set('/actions/runs/101', run);
  f.responses.set('/actions/workflows/9', {path: workflowPath});
  f.responses.set(`/contents/${workflowPath}?ref=${controlCommit}`, gitFile(Buffer.from('original accepted review workflow')));
  f.responses.set('/actions/runs/101/attempts/1/jobs?per_page=100&page=1', {jobs: [job]});
  f.responses.set('/actions/runs/101/artifacts?per_page=100&page=1', {artifacts: [artifact]});
  f.responses.set('/actions/artifacts/111/zip', bytes);
  f.responses.set(`/commits/${context.head}/check-runs?filter=all&per_page=100&page=1`, {check_runs: [
    {id: 77, name: context.bootstrap ? 'Repository bootstrap review' : 'Repository owner review', head_sha: context.head,
      external_id: `repository-review/v1:101:111:${sha256(bytes)}`},
  ]});
  return {envelope, bytes, run, artifact};
}

async function generatedReviewFixture() {
  const f = fixture(), actor = {id: 42, login: 'horos-release[bot]'};
  const person = {name: actor.login, email: `${actor.id}+${actor.login}@users.noreply.github.com`, date: '2026-10-30T00:00:00Z'};
  const baseBytes = Buffer.from('.{ .version = "1.0.0" }');
  const baseEntries = [{path: 'build.zig.zon', mode: '100644', type: 'blob', sha: gitFile(baseBytes).sha}];
  const baseTree = rootTree(baseEntries);
  f.responses.set(`/git/commits/${base}`, {sha: base, tree: {sha: baseTree}, committer: person});
  f.responses.set(`/git/trees/${baseTree}`, {sha: baseTree, truncated: false, tree: baseEntries});
  f.responses.set(`/contents/build.zig.zon?ref=${base}`, gitFile(baseBytes));
  const native = {read: bytes => /\.version = "([0-9.]+)"/.exec(bytes.toString())[1],
    prepare: (bytes, version) => Buffer.from(bytes.toString().replace(/\.version = "[0-9.]+"/, `.version = "${version}"`))};
  const candidate = await prepareHorosCandidate({base, version: '1.0.1', actor}, {client: f.client, native});
  f.responses.set(`/contents/build.zig.zon?ref=${candidate.head}`, gitFile(candidate.manifestBytes));
  const readCandidate = value => storedHorosCandidate(value, {client: f.client, native, actor});
  f.pull.head.ref = proposalBranch; f.pull.head.sha = candidate.head; f.pull.user = actor;
  f.pull.body = proposalDescription(candidate).body; f.pull.title = `Prepare Horos ${candidate.version}`;
  f.responses.set(`/git/commits/${candidate.head}`, {sha: candidate.head, tree: {sha: candidate.tree}, parents: [{sha: base}],
    message: candidate.message, author: candidate.author, committer: candidate.committer});
  Object.assign(f.run, {head_sha: candidate.head, event: 'pull_request', repository: {id: 1176152390},
    head_repository: {id: 1176152390}, path: '.github/workflows/zig.yml', run_attempt: 1});
  Object.assign(f.qualification.run, f.run); f.qualification.workflow.commit = candidate.head;
  f.responses.set(`/actions/workflows/zig.yml/runs?head_sha=${candidate.head}&event=pull_request&per_page=100&page=1`, {workflow_runs: [f.run]});
  f.responses.set('/actions/runs/10', f.run);
  reviewStorage(f, candidate); advanceControl(f, base);
  const retire = retireHorosProposal({client: f.client, actor, command: f.command, readCandidate});
  return {...f, candidate, readCandidate, retire: () => retire({pull: f.pull, knownHead: candidate.head})};
}

for (const control of [base, advanced]) test(`generated review authenticates original subject and closes it under control ${control.slice(0, 1)}`, async () => {
  const f = await generatedReviewFixture(); advanceControl(f, control);
  await assert.rejects(f.retire(), /unique original qualification failed/);
  const observed = await f.observe(control, null);
  assert.equal(observed.status, 'ready', JSON.stringify(observed));
  assert.equal(observed.context.base, base); assert.equal(observed.context.head, f.candidate.head);
  assert.equal(observed.context.tree, f.candidate.tree); assert.equal(observed.context.acceptedRequirements.commit, base);
  originalOwnerResult(f, observed.context, control);
  const original = await readReviewResult({repository: 'tkersey/horos', base, head: f.candidate.head, tree: f.candidate.tree}, f.command);
  assert.equal(original.status, 'complete'); assert.equal(original.workflow.commit, control);
  assert.equal((await f.retire()).epochClosed, true);
  const calls = f.qualified(), repeated = await f.observe(control, null);
  assert.equal(repeated.status, 'waiting'); assert.equal(repeated.observations[0].status, 'complete');
  assert.equal(f.qualified(), calls, 'completed original cannot start another owner epoch');
});

for (const generated of [false, true]) test(`real pending original survives forward control with generated subject ${generated}`, async () => {
  const f = await generatedReviewFixture();
  if (!generated) f.pull.head.ref = 'feature/source-change';
  const observed = await f.observe(base, null); assert.equal(observed.status, 'ready');
  originalOwnerResult(f, observed.context, base, 'pending');
  advanceControl(f);
  const resumed = await f.observe(advanced, null);
  assert.equal(resumed.status, 'ready', JSON.stringify(resumed)); assert.deepEqual(resumed.context, observed.context);
  assert.equal(resumed.previous.controlCommit, base); assert.equal(resumed.previous.runId, 101);
});

for (const changed of ['diverged control', 'missing parent', 'multiple parents'])
  test(`generated owner admission refuses ${changed}`, async () => {
    const f = await generatedReviewFixture(); advanceControl(f);
    if (changed === 'diverged control') f.responses.get(`/compare/${base}...${advanced}`).status = 'diverged';
    else f.responses.get(`/git/commits/${f.candidate.head}`).parents = changed === 'missing parent' ? [] : [{sha: base}, {sha: advanced}];
    const observed = await f.observe(advanced, null);
    assert.equal(observed.status, 'waiting'); assert.equal(observed.observations[0].status, 'blocked');
    assert.equal(f.qualified(), 0);
  });

test('durable original invocation without available artifacts cannot become an absent fresh review', async () => {
  const f = await generatedReviewFixture(); advanceControl(f);
  f.responses.get(`/commits/${f.candidate.head}/check-runs?filter=all&per_page=100&page=1`).check_runs.push({
    id: 77, name: 'Repository owner review', head_sha: f.candidate.head,
    external_id: `repository-review/unresolved:101:${base}:${f.candidate.head}`,
  });
  const observed = await f.observe(advanced, null);
  assert.equal(observed.status, 'waiting'); assert.equal(observed.observations[0].status, 'blocked');
  assert.match(observed.observations[0].reason, /evidence is unavailable/); assert.equal(f.qualified(), 0);
});


test('completed original owner result is reused after control advances without a new review', async () => {
  const f = await generatedReviewFixture(), observed = await f.observe(base, null);
  assert.equal(observed.status, 'ready'); originalOwnerResult(f, observed.context, base);
  advanceControl(f);
  const count = f.qualified(), repeated = await f.observe(advanced, null);
  assert.equal(repeated.status, 'waiting'); assert.equal(repeated.observations[0].status, 'complete');
  assert.equal(f.qualified(), count); assert.equal((await f.retire()).epochClosed, true);
});

for (const generated of [false, true]) test(`pending original refuses diverged control with generated subject ${generated}`, async () => {
  const f = await generatedReviewFixture(); if (!generated) f.pull.head.ref = 'feature/source-change';
  const observed = await f.observe(base, null); assert.equal(observed.status, 'ready');
  originalOwnerResult(f, observed.context, base, 'pending'); advanceControl(f);
  f.responses.get(`/compare/${base}...${advanced}`).status = 'diverged';
  const count = f.qualified(), blocked = await f.observe(advanced, null);
  assert.equal(blocked.status, 'waiting'); assert.equal(blocked.observations[0].status, 'blocked');
  assert.equal(f.qualified(), count); assert.match(blocked.observations[0].reason, /lineage|diverges/);
});


function checkLifecycle(f) {
  const checkPath = `/commits/${f.candidate.head}/check-runs?filter=all&per_page=100&page=1`, mutations = [];
  const checks = () => f.responses.get(checkPath).check_runs;
  const client = {async request(request) {
    if (request.method === undefined) return f.client.request(request);
    mutations.push(structuredClone(request));
    if (request.method === 'POST') {
      assert.equal(request.path, '/check-runs'); assert.equal(checks().length, 0);
      checks().push({id: 77, app: {id: 777}, ...structuredClone(request.body)});
    } else {
      assert.equal(request.method, 'PATCH'); assert.equal(request.path, '/check-runs/77');
      Object.assign(checks()[0], structuredClone(request.body));
      if (request.body.status !== 'completed') checks()[0].conclusion = null;
    }
    return {status: request.method === 'POST' ? 201 : 200};
  }};
  const report = () => reportHorosReview({number: f.pull.number, appId: 777}, {client,
    readResult: subject => readReviewResult(subject, f.command)});
  const start = async (plan, runId = 202) => {
    assert.equal(plan.status, 'ready');
    f.responses.set(`/actions/runs/${runId}`, {id: runId, repository: {id: 1176152390}, head_repository: {id: 1176152390},
      head_sha: f.main.object.sha, head_branch: 'main', path: '.github/workflows/repository-review.yml',
      event: 'schedule', run_attempt: 1, status: 'in_progress'});
    return markHorosReviewStarted({...plan, controlCommit: f.main.object.sha, runId, appId: 777}, client,
      binding => authenticateReviewContinuation(binding, f.command));
  };
  const store = (context, control, status = 'pending') => {
    const original = originalOwnerResult(f, context, control, status);
    Object.assign(checks()[0], {app: {id: 777}, status: status === 'pending' ? 'in_progress' : 'completed',
      conclusion: status === 'pending' ? null : status === 'complete' ? 'success' : 'failure'});
    return original;
  };
  const hideArtifacts = () => {
    const originals = new Map();
    for (const [key, value] of f.responses) if (Array.isArray(value?.artifacts)) {
      originals.set(key, value); f.responses.set(key, {artifacts: []});
    }
    return () => {for (const [key, value] of originals) f.responses.set(key, value);};
  };
  return {report, start, store, hideArtifacts, mutations, checks};
}

test('reporter observer and start share the generated original subject before first review after base advancement', async () => {
  const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f); advanceControl(f);
  await lifecycle.report();
  assert.equal(lifecycle.checks()[0].external_id, `repository-review/pending:${base}:${f.candidate.head}`);
  const plan = await f.observe(advanced, null);
  assert.equal(plan.context.base, base); assert.equal(plan.previous, null);
  await lifecycle.start(plan);
  assert.equal(lifecycle.checks()[0].external_id, `repository-review/unresolved:202:${base}:${f.candidate.head}`);
});

for (const generated of [false, true]) test(`reporter observer and start resume the original pending subject after base advancement generated=${generated}`, async () => {
  const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f);
  if (!generated) f.pull.head.ref = 'feature/ordinary-source';
  const first = await f.observe(base, null); lifecycle.store(first.context, base); advanceControl(f);
  await lifecycle.report(); assert.equal(lifecycle.checks()[0].status, 'in_progress');
  const plan = await f.observe(advanced, null);
  assert.deepEqual(plan.context, first.context); assert.equal(plan.previous.runId, 101);
  await lifecycle.start(plan);
  assert.equal(lifecycle.checks()[0].external_id, `repository-review/unresolved:202:${base}:${f.candidate.head}`);
});

for (const status of ['complete', 'blocked']) test(`reporter and observer retain original ${status} after generated base advancement`, async () => {
  const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f), first = await f.observe(base, null);
  lifecycle.store(first.context, base, status); advanceControl(f);
  await lifecycle.report();
  assert.equal(lifecycle.checks()[0].status, 'completed');
  assert.equal(lifecycle.checks()[0].conclusion, status === 'complete' ? 'success' : 'failure');
  const plan = await f.observe(advanced, null);
  assert.equal(plan.status, 'waiting'); assert.equal(plan.observations[0].status, status);
});

for (const marker of ['v1', 'unresolved']) for (const order of ['report-first', 'start-first'])
  test(`missing evidence remains owned across repeated polls and authenticated recovery ${marker} ${order}`, async () => {
    const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f), first = await f.observe(base, null);
    lifecycle.store(first.context, base);
    if (marker === 'unresolved') lifecycle.checks()[0].external_id = `repository-review/unresolved:101:${base}:${f.candidate.head}`;
    const originalMarker = lifecycle.checks()[0].external_id, restore = lifecycle.hideArtifacts(); advanceControl(f);
    for (let poll = 0; poll < 3; poll++) {
      await lifecycle.report();
      assert.equal(lifecycle.checks()[0].external_id, originalMarker);
      assert.equal(lifecycle.checks()[0].status, 'completed'); assert.equal(lifecycle.checks()[0].conclusion, 'failure');
      const waiting = await f.observe(advanced, null);
      assert.equal(waiting.status, 'waiting'); assert.equal(waiting.observations[0].status, 'blocked');
    }
    assert.equal(lifecycle.mutations.length, 1);
    restore();
    const plan = await f.observe(advanced, null);
    assert.equal(plan.status, 'ready'); assert.deepEqual(plan.context, first.context); assert.equal(plan.previous.runId, 101);
    if (order === 'report-first') {
      await lifecycle.report(); assert.equal(lifecycle.checks()[0].status, 'in_progress');
    }
    await lifecycle.start(plan);
    assert.equal(lifecycle.checks()[0].external_id, `repository-review/unresolved:202:${base}:${f.candidate.head}`);
    await lifecycle.report();
    assert.equal(lifecycle.checks()[0].external_id, `repository-review/unresolved:202:${base}:${f.candidate.head}`);
    assert.equal(lifecycle.checks()[0].conclusion, 'failure');
    const later = await f.observe(advanced, null);
    assert.equal(later.status, 'waiting'); assert.equal(later.observations[0].status, 'blocked');
  });

test('uploaded next start before marker visibility preserves the original pending continuation', async () => {
  const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f), first = await f.observe(base, null);
  const original = lifecycle.store(first.context, base), plan = await f.observe(base, null);
  const names = reviewNames(base, f.candidate.head), start = {...original.artifact, id: 212, name: names.start,
    created_at: '2026-10-30T02:00:00Z', workflow_run: {...original.artifact.workflow_run, id: 202}};
  f.responses.set('/actions/runs/202', {...original.run, id: 202, status: 'in_progress', conclusion: null});
  f.responses.get('/actions/artifacts?per_page=100&page=1').artifacts.push(start);
  f.responses.set(`/actions/artifacts?name=${names.start}&per_page=100&page=1`, {artifacts: [start]});
  const originalMarker = lifecycle.checks()[0].external_id;
  await lifecycle.report(); assert.equal(lifecycle.checks()[0].external_id, originalMarker);
  assert.equal(lifecycle.checks()[0].conclusion, 'failure');
  await lifecycle.start(plan);
  await lifecycle.report();
  assert.equal(lifecycle.checks()[0].external_id, `repository-review/unresolved:202:${base}:${f.candidate.head}`);
  assert.equal(lifecycle.checks()[0].status, 'in_progress');
});

for (const status of ['blocked', 'complete']) test(`actual original ${status} cannot masquerade as a pending recovery`, async () => {
  const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f), first = await f.observe(base, null);
  const original = lifecycle.store(first.context, base, status);
  const previous = {runId: original.run.id, artifactId: original.artifact.id, sha256: sha256(original.bytes),
    controlCommit: base, workflowSha256: sha256(Buffer.from('original accepted review workflow'))};
  await assert.rejects(() => lifecycle.start({...first, previous}), /terminal owner result/);
  assert.equal(lifecycle.mutations.length, 0);
});

for (const status of ['pending', 'blocked']) test(`bootstrap missing evidence and recovery retain original ${status} identity`, async () => {
  const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f), first = await f.observe(base, null);
  const context = {...first.context, pullNumber: null,
    bootstrap: {boundary: {base, head: f.candidate.head, tree: f.candidate.tree}}};
  const original = lifecycle.store(context, base, status), marker = lifecycle.checks()[0].external_id;
  const restore = lifecycle.hideArtifacts(), subject = {...context, purpose: 'bootstrap'};
  for (let poll = 0; poll < 3; poll++) {
    const result = await readReviewResult(subject, f.command);
    assert.equal(result.status, 'blocked'); assert.equal(result.invocation.externalId, marker);
  }
  restore(); advanceControl(f);
  const result = await readReviewResult(subject, f.command); assert.equal(result.status, status);
  const previous = {runId: original.run.id, artifactId: original.artifact.id, sha256: sha256(original.bytes),
    controlCommit: base, workflowSha256: sha256(Buffer.from('original accepted review workflow'))};
  Object.assign(lifecycle.checks()[0], {status: 'completed', conclusion: 'failure'});
  if (status === 'pending') {
    await lifecycle.start({status: 'ready', context, previous});
    assert.equal(lifecycle.checks()[0].external_id, `repository-review/unresolved:202:${base}:${f.candidate.head}`);
  } else await assert.rejects(() => lifecycle.start({status: 'ready', context, previous}), /terminal owner result/);
});


for (const status of ['pending', 'blocked']) test(`provider-staled check resumes only authenticated original ${status} evidence`, async () => {
  const f = await generatedReviewFixture(), lifecycle = checkLifecycle(f), first = await f.observe(base, null);
  const original = lifecycle.store(first.context, base, status);
  Object.assign(lifecycle.checks()[0], {status: 'completed', conclusion: 'stale'});
  const previous = {runId: original.run.id, artifactId: original.artifact.id, sha256: sha256(original.bytes),
    controlCommit: base, workflowSha256: sha256(Buffer.from('original accepted review workflow'))};
  if (status === 'pending') {
    await lifecycle.start({...first, previous});
    assert.equal(lifecycle.checks()[0].status, 'in_progress');
    assert.equal(lifecycle.checks()[0].external_id, `repository-review/unresolved:202:${base}:${f.candidate.head}`);
  } else {
    await assert.rejects(() => lifecycle.start({...first, previous}), /terminal owner result/);
    assert.equal(lifecycle.mutations.length, 0);
  }
});
