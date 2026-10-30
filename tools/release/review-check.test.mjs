import assert from 'node:assert/strict';
import test from 'node:test';
import {reportHorosReview, reviewCheckName, expectedReviewSettings} from './review-check.mjs';
import {impactBlock, impactInput, versionPreparationImpact} from './impact.mjs';
import {retainedFixture} from './promotion-test-support.mjs';
import {reviewCheckBinding} from './promotion-admission.mjs';

const repository = 'tkersey/horos', base = 'a'.repeat(40), head = 'b'.repeat(40), tree = 'c'.repeat(40);

function fixture(status = 'complete') {
  const body = impactBlock(versionPreparationImpact);
  const context = {repository, base, head, tree, pullNumber: 42, impact: impactInput(body, base, head)};
  const retained = retainedFixture(context, expectedReviewSettings);
  const envelope = {schema: 'repository-review-result/v1', context, status, epochClosed: status === 'complete',
    reason: `Original owner ${status}.`, turn: 1, previousSha256: null,
    stateSha256: status === 'pending' ? 'd'.repeat(64) : null,
    retainedEvidence: status === 'complete' ? Buffer.from(JSON.stringify(retained)).toString('base64') : null};
  const state = {checks: [], calls: [], mutations: [], reads: 0, loseResponse: false, failWrite: false,
    onRead: null, beforeWrite: null,
    pull: {number: 42, state: 'open', draft: false, labels: [], body,
      base: {ref: 'main', sha: base, repo: {id: 1176152390}}, head: {sha: head, repo: {id: 1176152390}}},
    result: {status, envelope, bytes: Buffer.from(JSON.stringify(envelope)), artifact: {id: 7},
      run: {id: 8, html_url: `https://github.com/${repository}/actions/runs/8`}}};
  const client = {async request(request) {
    state.calls.push(request);
    if ((request.method ?? 'GET') === 'GET') {
      await state.onRead?.(request, state);
      const values = new Map([
        ['', {id: 1176152390, full_name: repository, default_branch: 'main'}],
        ['/actions/artifacts?per_page=100&page=1', {artifacts: []}],
        ['/pulls/42', state.pull], [`/git/commits/${head}`, {sha: head, tree: {sha: tree}}],
        [`/commits/${head}/check-runs?filter=all&per_page=100&page=1`, {check_runs: state.checks}],
      ]);
      assert.ok(values.has(request.path), request.path);
      return {status: 200, body: structuredClone(values.get(request.path))};
    }
    state.mutations.push(request); await state.beforeWrite?.(request, state);
    if (state.failWrite) throw new Error('write unavailable');
    let check;
    if (request.method === 'POST') {
      assert.equal(request.path, '/check-runs');
      check = {id: 9, app: {id: 777}, ...structuredClone(request.body)};
      state.checks.push(check);
    } else {
      assert.equal(request.method, 'PATCH'); assert.equal(request.path, '/check-runs/9');
      check = state.checks.find(row => row.id === 9);
      Object.assign(check, structuredClone(request.body));
      if (request.body.status !== 'completed') check.conclusion = null;
    }
    if (state.loseResponse) throw new Error('response lost');
    return {status: request.method === 'POST' ? 201 : 200, body: structuredClone(check)};
  }};
  const options = {client, readResult: async subject => {
    assert.equal(subject.base, base); assert.equal(subject.head, head); assert.equal(subject.tree, tree);
    state.reads++; return state.result;
  }};
  const run = () => reportHorosReview({number: 42, appId: 777}, options);
  return {state, options, run, envelope, retained};
}

test('reports original owner evidence, then repeats without another write', async () => {
  const value = fixture();
  assert.deepEqual(await value.run(), {status: 'reported', checkId: 9, conclusion: 'success'});
  assert.equal(value.state.checks[0].external_id, reviewCheckBinding(value.state.result));
  assert.equal(value.state.checks[0].details_url, value.state.result.run.html_url);
  assert.deepEqual(await value.run(), {status: 'unchanged', checkId: 9, conclusion: 'success'});
  assert.equal(value.state.mutations.length, 1);
});

for (const status of ['pending', 'blocked', 'absent', 'running']) test(`reports ${status} without favorable credit`, async () => {
  const value = fixture(['pending', 'blocked'].includes(status) ? status : 'complete');
  if (['absent', 'running'].includes(status)) value.state.result = {status};
  await value.run();
  assert.equal(value.state.checks[0].status, status === 'blocked' ? 'completed' : 'in_progress');
  assert.equal(value.state.checks[0].conclusion, status === 'blocked' ? 'failure' : undefined);
});

test('updates the one owned check as original evidence completes', async () => {
  const value = fixture('pending'); await value.run();
  value.state.result = fixture().state.result;
  value.state.result.run = {id: 55, html_url: `https://github.com/${repository}/actions/runs/55`};
  value.state.result.artifact = {id: 56};
  value.state.checks[0].external_id = `repository-review/unresolved:55:${base}:${head}`;
  await value.run(); assert.equal(value.state.checks.length, 1);
  assert.equal(value.state.mutations[1].method, 'PATCH');
  assert.equal(value.state.mutations[1].body.head_sha, undefined);
  assert.equal(value.state.checks[0].conclusion, 'success');
});

test('uncertain successful writes are observed before any retry', async () => {
  const value = fixture(); value.state.loseResponse = true;
  await value.run(); await value.run(); assert.equal(value.state.mutations.length, 1);
});

test('unsuccessful writes remain incomplete', async () => {
  const value = fixture(); value.state.failWrite = true;
  await assert.rejects(value.run, /write unavailable/); assert.equal(value.state.mutations.length, 1);
});

test('changed declaration withdraws favorable check credit', async () => {
  const value = fixture(); await value.run();
  value.state.pull.body = impactBlock({...versionPreparationImpact, rationale: 'Changed after review.'});
  await value.run(); assert.equal(value.state.checks[0].conclusion, 'failure');
});

for (const field of ['model', 'codexSha256']) test(`rejects original review with wrong ${field}`, async () => {
  const value = fixture(); value.options.settings = {...expectedReviewSettings, [field]: 'wrong'};
  await assert.rejects(value.run, /review runtime differs/); assert.equal(value.state.mutations.length, 0);
});

test('rejects forged original receipt output', async () => {
  const value = fixture(); value.retained.receipts['receipt-0.json'] = Buffer.from('{}').toString('base64');
  value.envelope.retainedEvidence = Buffer.from(JSON.stringify(value.retained)).toString('base64');
  value.state.result.bytes = Buffer.from(JSON.stringify(value.envelope));
  await assert.rejects(value.run); assert.equal(value.state.mutations.length, 0);
});

test('rejects wrong review purpose and pull identity', async () => {
  const value = fixture('pending'); value.envelope.context.pullNumber = 43;
  value.state.result.bytes = Buffer.from(JSON.stringify(value.envelope));
  await assert.rejects(value.run); assert.equal(value.state.mutations.length, 0);
});

test('does not adopt a same-name check from another App', async () => {
  const value = fixture(); value.state.checks.push({id: 10, name: reviewCheckName, app: {id: 999}, head_sha: head});
  await value.run(); assert.equal(value.state.checks.length, 2); assert.equal(value.state.mutations[0].method, 'POST');
});

test('blocks duplicate or unknown owned checks', async () => {
  const value = fixture(); await value.run();
  value.state.checks.push({...value.state.checks[0], id: 10});
  await assert.rejects(value.run, /multiple App-owned/);
  value.state.checks.pop(); value.state.checks[0].external_id = 'human-created';
  await assert.rejects(value.run, /unknown App-owned/);
});

for (const change of ['head', 'body', 'hold']) test(`reobserves ${change} before reporting`, async () => {
  const value = fixture(); let pulls = 0;
  value.state.onRead = (request, state) => {
    if (request.path !== '/pulls/42' || ++pulls !== 2) return;
    if (change === 'head') state.pull.head.sha = 'd'.repeat(40);
    if (change === 'body') state.pull.body += ' changed';
    if (change === 'hold') state.pull.labels = [{name: 'automation-hold'}];
  };
  await assert.rejects(value.run); assert.equal(value.state.mutations.length, 0);
});

for (const change of ['closed', 'draft', 'hold']) test(`does not report held ${change} pull`, async () => {
  const value = fixture();
  if (change === 'closed') value.state.pull.state = 'closed';
  if (change === 'draft') value.state.pull.draft = true;
  if (change === 'hold') value.state.pull.labels = [{name: 'automation-hold'}];
  assert.deepEqual(await value.run(), {status: 'held'});
  assert.equal(value.state.reads, 0); assert.equal(value.state.mutations.length, 0);
});


test('a failed legacy pending marker cannot be reset by repeated absent observations', async () => {
  const value = fixture(); value.state.result = {status: 'absent'};
  value.state.checks.push({id: 9, app: {id: 777}, name: reviewCheckName, head_sha: head,
    external_id: `repository-review/pending:${base}:${head}`, status: 'completed', conclusion: 'failure'});
  for (let poll = 0; poll < 3; poll++) {
    await value.run();
    assert.equal(value.state.checks[0].status, 'completed'); assert.equal(value.state.checks[0].conclusion, 'failure');
    assert.equal(value.state.checks[0].external_id, `repository-review/pending:${base}:${head}`);
  }
  assert.equal(value.state.mutations.length, 1);
});

test('an invocation observed after result lookup cannot be erased as absent', async () => {
  const value = fixture();
  value.options.readResult = async () => {
    value.state.checks.push({id: 9, app: {id: 777}, name: reviewCheckName, head_sha: head,
      external_id: `repository-review/unresolved:55:${base}:${head}`, status: 'in_progress', conclusion: null});
    return {status: 'absent'};
  };
  await value.run();
  assert.equal(value.state.checks[0].external_id, `repository-review/unresolved:55:${base}:${head}`);
  assert.equal(value.state.checks[0].conclusion, 'failure');
});

test('reporting cannot overwrite an invocation changed at the deciding read', async () => {
  const value = fixture('pending'); await value.run(); value.state.mutations = [];
  value.state.checks[0].output.summary = 'A display refresh is needed.';
  let reads = 0;
  value.state.onRead = request => {
    if (request.path.includes('/check-runs?') && ++reads === 2) {
      value.state.checks[0].external_id = `repository-review/unresolved:55:${base}:${head}`;
    }
  };
  await assert.rejects(value.run, /check changed before reporting/);
  assert.equal(value.state.mutations.length, 0);
});

for (const status of ['pending', 'blocked', 'complete', 'running'])
  test(`a newer invocation observed after the ${status} result cannot be overwritten`, async () => {
    const value = fixture(status === 'running' ? 'pending' : status);
    if (status === 'running') value.state.result = {status, run: value.state.result.run};
    value.options.readResult = async () => {
      value.state.checks.push({id: 9, app: {id: 777}, name: reviewCheckName, head_sha: head,
        external_id: `repository-review/unresolved:55:${base}:${head}`, status: 'in_progress', conclusion: null});
      return value.state.result;
    };
    await assert.rejects(value.run, /original invocation differs|original check invocation differs/);
    assert.equal(value.state.mutations.length, 0);
    assert.equal(value.state.checks[0].external_id, `repository-review/unresolved:55:${base}:${head}`);
  });

test('current artifact identity must agree with an already read result', async () => {
  const value = fixture('pending');
  value.options.readResult = async () => {
    value.state.checks.push({id: 9, app: {id: 777}, name: reviewCheckName, head_sha: head,
      external_id: `repository-review/v1:8:99:${'f'.repeat(64)}`, status: 'in_progress', conclusion: null});
    return value.state.result;
  };
  await assert.rejects(value.run, /original artifact differs/);
  assert.equal(value.state.mutations.length, 0);
});
