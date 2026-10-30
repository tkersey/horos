import assert from 'node:assert/strict';
import test from 'node:test';
import {markHorosReviewStarted} from './review-start.mjs';
import {impactBlock, impactInput, versionPreparationImpact} from './impact.mjs';

const base = 'a'.repeat(40), head = 'b'.repeat(40), tree = 'c'.repeat(40), body = impactBlock(versionPreparationImpact);

function fixture(bootstrap = false) {
  const context = {repository: 'tkersey/horos', base, head, tree, pullNumber: bootstrap ? null : 42,
    impact: impactInput(body, base, head), ...(bootstrap ? {bootstrap: {boundary: {base, head, tree}}} : {})};
  const input = {context, previous: null, controlCommit: base, runId: 8, appId: 777};
  const state = {checks: [], writes: [], lost: false,
    run: {id: 8, repository: {id: 1176152390}, head_repository: {id: 1176152390},
      head_sha: base, head_branch: 'main', path: '.github/workflows/repository-review.yml', event: 'schedule', run_attempt: 1, status: 'in_progress'},
    pull: {state: 'open', draft: false, head: {sha: head, repo: {id: 1176152390}},
      base: {sha: base, repo: {id: 1176152390}}, labels: [], body}};
  const client = {async request(request) {
    if ((request.method ?? 'GET') === 'GET') {
      const values = new Map([['', {id: 1176152390, full_name: context.repository}], ['/actions/runs/8', state.run],
        ['/pulls/42', state.pull], [`/commits/${head}/check-runs?filter=all&per_page=100&page=1`, {check_runs: state.checks}]]);
      assert.ok(values.has(request.path), request.path); return {status: 200, body: structuredClone(values.get(request.path))};
    }
    state.writes.push(request);
    if (request.method === 'POST') state.checks.push({id: 9, app: {id: 777}, ...request.body});
    else Object.assign(state.checks[0], request.body);
    if (state.lost) throw new Error('transport lost after accepted check');
    return {status: request.method === 'POST' ? 201 : 200};
  }};
  return {input, state, run: () => markHorosReviewStarted(input, client)};
}

for (const bootstrap of [false, true]) test(`start identity survives artifact expiry for ${bootstrap ? 'bootstrap' : 'pull'}`, async () => {
  const value = fixture(bootstrap);
  assert.deepEqual(await value.run(), {checkId: 9});
  assert.equal(value.state.checks[0].external_id, `repository-review/unresolved:8:${base}:${head}`);
  assert.equal(value.state.checks[0].status, 'in_progress');
  await value.run(); assert.equal(value.state.writes.length, 1);
});

test('uncertain marker write converges without duplicate checks', async () => {
  const value = fixture(); value.state.lost = true;
  await value.run(); await value.run(); assert.equal(value.state.writes.length, 1);
});

test('original pending owner state admits the next bounded turn on the same check', async () => {
  const value = fixture(); await value.run();
  value.state.checks[0].external_id = `repository-review/v1:7:70:${'d'.repeat(64)}`;
  value.input.previous = {runId: 7, artifactId: 70, sha256: 'd'.repeat(64)};
  await value.run(); assert.equal(value.state.writes.length, 2); assert.equal(value.state.writes[1].method, 'PATCH');
});

for (const [name, mutate] of [
  ['missing original recovery', value => {value.state.checks[0].external_id = `repository-review/unresolved:7:${base}:${head}`;}],
  ['terminal failure', value => {value.state.checks[0].status = 'completed'; value.state.checks[0].conclusion = 'failure';}],
  ['terminal success', value => {value.state.checks[0].status = 'completed'; value.state.checks[0].conclusion = 'success';}],
  ['repeated job', value => {value.state.run.run_attempt = 2;}],
  ['untrusted branch', value => {value.state.run.head_branch = 'candidate';}],
  ['changed head', value => {value.state.pull.head.sha = base;}],
  ['changed declaration', value => {value.state.pull.body = impactBlock({...versionPreparationImpact, impact: 'major'});}],
  ['manual hold', value => {value.state.pull.labels = [{name: 'automation-hold'}];}],
]) test(`start marker blocks ${name}`, async () => {
  const value = fixture(); await value.run(); mutate(value);
  await assert.rejects(value.run); assert.equal(value.state.writes.length, 1);
});
