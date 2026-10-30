import assert from 'node:assert/strict';
import test from 'node:test';
import {observeHorosBootstrap} from './bootstrap-review.mjs';
import {bootstrapInput} from './review-runner.mjs';
import {sha256} from './encoding.mjs';

const base = 'a'.repeat(40), head = 'b'.repeat(40), tree = 'c'.repeat(40);

function fixture() {
  const request = {base, initialVersion: '8.0.0', declaration: {impact: 'major', disposition: 'compatible',
    rationale: 'Explicit reviewed initial publication.', contracts: ['library public contracts', 'package identity']}};
  const run = {id: 12, status: 'completed', conclusion: 'success'};
  const inventory = {commit: head, tree, packageIdentity: `horos-8.0.0-${'x'.repeat(44)}`};
  const evidence = Buffer.from('original full landed qualification');
  const qualification = {run: {...run, html_url: 'https://github.com/tkersey/horos/actions/runs/12'},
    workflow: {path: '.github/workflows/zig.yml', commit: head, sha256: 'd'.repeat(64)}, evidence,
    jobs: [{id: 13, name: 'original admitted inventory', conclusion: 'success'}], payloads: new Map()};
  const main = {ref: 'refs/heads/main', object: {type: 'commit', sha: head}};
  const responses = new Map([
    ['', {full_name: 'tkersey/horos', id: 1176152390, default_branch: 'main'}],
    ['/git/ref/heads/main', main],
    [`/compare/${base}...${head}`, {base_commit: {sha: base}, merge_base_commit: {sha: base}, status: 'ahead'}],
    [`/compare/${head}...${head}`, {base_commit: {sha: head}, merge_base_commit: {sha: head}, status: 'identical'}],
    [`/git/commits/${head}`, {sha: head, tree: {sha: tree}}],
    [`/actions/workflows/zig.yml/runs?head_sha=${head}&event=push&per_page=100&page=1`, {workflow_runs: [run]}],
    [`/contents/docs/repository-local-releases.md?ref=${head}`, {type: 'file', encoding: 'base64', content: Buffer.from('Accepted bootstrap requirements').toString('base64')}],
  ]);
  const command = async args => {
    const path = args[1].slice('repos/tkersey/horos'.length);
    assert.ok(responses.has(path), `unexpected bootstrap API ${path}`);
    return Buffer.from(JSON.stringify(responses.get(path)));
  };
  const client = {request: async ({path}) => {
    assert.equal(path, '/actions/variables/REPOSITORY_AUTOMATION');
    return {status: 200, body: {name: 'REPOSITORY_AUTOMATION', value: 'propose'}};
  }};
  let calls = 0, previous = {status: 'absent'};
  const qualify = async options => {
    calls++; assert.deepEqual(options, {runId: 12, commit: head, tree, event: 'push'});
    assert.equal(run.conclusion, 'success');
    qualification.payloads.set('source.json', Buffer.from(JSON.stringify(inventory)));
    return qualification;
  };
  const observe = (override = {}) => observeHorosBootstrap({controlCommit: head, request, ...override}, command,
    client, qualify, async () => previous);
  return {request, run, inventory, qualification, main, responses, observe, calls: () => calls, setPrevious: value => {previous = value;}};
}

test('explicit bootstrap uses original landed proof and commits the native version into owner input', async () => {
  const value = fixture(), result = await value.observe();
  assert.equal(result.status, 'ready'); assert.equal(value.calls(), 1);
  assert.equal(result.context.pullNumber, null);
  assert.deepEqual(result.context.bootstrap.boundary, {base, head, tree});
  assert.equal(result.context.bootstrap.initialVersion, '8.0.0');
  assert.equal(result.context.qualification.evidenceSha256, sha256(value.qualification.evidence));
  assert.equal(result.context.acceptedRequirements.commit, head);
  assert.equal(result.previous, null);
});

test('pending bootstrap resumes its original context instead of inventing new authority', async () => {
  const value = fixture(), first = await value.observe();
  const original = {status: 'pending', envelope: {context: first.context}, run: {id: 14}, artifact: {id: 15},
    bytes: Buffer.from('authenticated original pending artifact'), workflow: {commit: head, sha256: 'e'.repeat(64)}};
  const result = await value.observe({request: null, original});
  assert.deepEqual(result.context, first.context); assert.equal(result.previous.runId, 14);
  value.qualification.evidence = Buffer.from('changed original proof');
  await assert.rejects(value.observe({request: null, original}), /proof changed/);
});

test('finished or blocked bootstrap is never rerun for a more favorable outcome', async () => {
  const value = fixture(), first = await value.observe();
  for (const status of ['complete', 'blocked']) {
    value.setPrevious({status, envelope: {context: first.context, reason: 'Original outcome.'}});
    assert.equal((await value.observe()).status, status);
  }
  assert.equal(value.calls(), 1);
});

for (const [name, mutate] of [
  ['different package version', value => {value.inventory.packageIdentity = `horos-8.0.1-${'x'.repeat(44)}`;}],
  ['different actual source', value => {value.inventory.commit = base;}],
  ['failed landed qualification', value => {value.run.conclusion = 'failure';}],
  ['duplicate landed run', value => {value.responses.get(`/actions/workflows/zig.yml/runs?head_sha=${head}&event=push&per_page=100&page=1`).workflow_runs.push({...value.run, id: 16});}],
  ['empty source range', value => {value.request.base = head;}],
  ['rewritten source history', value => {value.responses.get(`/compare/${base}...${head}`).status = 'diverged';}],
  ['contradictory breaking impact', value => {value.request.declaration.disposition = 'breaking'; value.request.declaration.impact = 'patch';}],
  ['stale accepted control', value => {value.main.object.sha = base;}],
]) {
  test(`bootstrap rejects ${name}`, async () => {
    const value = fixture(); mutate(value); await assert.rejects(value.observe());
  });
}

test('bootstrap waits for the original landed qualification without starting a review', async () => {
  const value = fixture(); value.run.status = 'in_progress';
  assert.equal((await value.observe()).status, 'qualification pending'); assert.equal(value.calls(), 0);
});

test('manual bootstrap fields are data and incomplete requests cannot silently become ordinary reviews', () => {
  assert.equal(bootstrapInput({}), null);
  assert.throws(() => bootstrapInput({BOOTSTRAP_VERSION: '8.0.0'}), /base is missing/);
  const value = bootstrapInput({BOOTSTRAP_BASE: base, BOOTSTRAP_VERSION: '8.0.0', BOOTSTRAP_IMPACT: 'major',
    BOOTSTRAP_DISPOSITION: 'compatible', BOOTSTRAP_RATIONALE: 'Exact source review.', BOOTSTRAP_CONTRACTS: '["package API"]'});
  assert.deepEqual(value.declaration.contracts, ['package API']); assert.equal(value.initialVersion, '8.0.0');
  assert.throws(() => bootstrapInput({BOOTSTRAP_BASE: base, BOOTSTRAP_CONTRACTS: 'invalid'}));
});
