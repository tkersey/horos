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
    [`/git/commits/${head}`, {sha: head, tree: {sha: tree}}],
    [`/actions/workflows/zig.yml/runs?head_sha=${head}&event=pull_request&per_page=100&page=1`, {workflow_runs: [run]}],
    [`/contents/docs/repository-local-releases.md?ref=${base}`, {type: 'file', encoding: 'base64', content: Buffer.from('Accepted local fixture requirements').toString('base64')}],
  ]);
  let qualified = 0;
  const command = async args => {
    const key = args[1].slice('repos/tkersey/horos'.length);
    assert.ok(responses.has(key), `unexpected observer API ${key}`);
    return Buffer.from(JSON.stringify(responses.get(key)));
  };
  const client = {request: async ({path, method}) => {
    assert.equal(method, undefined); assert.equal(path, '/actions/variables/REPOSITORY_AUTOMATION'); return mode;
  }};
  const qualify = async options => {
    qualified++;
    assert.deepEqual(options, {runId: 10, commit: head, tree, event: 'pull_request'});
    assert.equal(run.conclusion, 'success', 'original qualification failed');
    return qualification;
  };
  let prior = null;
  const observe = () => observeHorosReview({controlCommit: base}, command, client, async () => prior, qualify);
  return {mode, main, pull, run, responses, qualification, observe, qualified: () => qualified, setPrior: value => {prior = value;}};
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
