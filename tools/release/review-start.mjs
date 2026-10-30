import assert from 'node:assert/strict';
import {readRegular} from './review-owner.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {requireCurrentImpact} from './impact.mjs';

async function get(client, path) {
  const response = await client.request({path}); assert.equal(response.status, 200); return response.body;
}

async function currentCheck(client, head, name, appId) {
  const selected = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const value = await get(client, `/commits/${head}/check-runs?filter=all&per_page=100&page=${page}`);
    assert.ok(Array.isArray(value.check_runs) && value.check_runs.length <= 100);
    for (const check of value.check_runs) {
      assert.ok(Number.isSafeInteger(check.id) && check.id > 0 && !seen.has(check.id)); seen.add(check.id);
      if (check.name === name && check.app?.id === appId) selected.push(check);
    }
    assert.ok(selected.length <= 1, 'ambiguous original review check');
    if (value.check_runs.length < 100) return selected[0] ?? null;
  }
  throw new Error('review check inventory exceeds bound');
}

export async function markHorosReviewStarted({context, previous, controlCommit, runId, appId}, client = new HorosProposalClient()) {
  assert.equal(context.repository, 'tkersey/horos');
  for (const value of [context.base, context.head, context.tree, controlCommit]) assert.match(value, /^[0-9a-f]{40}$/);
  for (const value of [runId, appId]) assert.ok(Number.isSafeInteger(value) && value > 0);
  const repository = await get(client, ''); assert.equal(repository.id, 1176152390); assert.equal(repository.full_name, context.repository);
  const run = await get(client, `/actions/runs/${runId}`);
  assert.equal(run.repository.id, repository.id); assert.equal(run.head_repository.id, repository.id);
  assert.equal(run.run_attempt, 1); assert.equal(run.head_sha, controlCommit); assert.equal(run.head_branch, 'main');
  assert.equal(run.path, '.github/workflows/repository-review.yml'); assert.equal(run.status, 'in_progress');
  assert.ok(['schedule', 'workflow_dispatch', 'workflow_run'].includes(run.event));
  if (context.bootstrap) {
    assert.equal(context.pullNumber, null);
    assert.deepEqual(context.bootstrap.boundary, {base: context.base, head: context.head, tree: context.tree});
  } else {
    assert.ok(Number.isSafeInteger(context.pullNumber) && context.pullNumber > 0);
    const pull = await get(client, `/pulls/${context.pullNumber}`);
    assert.equal(pull.state, 'open'); assert.equal(pull.draft, false);
    assert.equal(pull.head.sha, context.head); assert.equal(pull.base.sha, controlCommit);
    assert.equal(pull.head.repo.id, repository.id); assert.equal(pull.base.repo.id, repository.id);
    assert.ok(!pull.labels.some(label => label.name === 'automation-hold'));
    requireCurrentImpact(context.impact, pull.body, context.base, context.head);
  }
  const name = context.bootstrap ? 'Repository bootstrap review' : 'Repository owner review';
  const external = `repository-review/unresolved:${runId}:${context.base}:${context.head}`;
  const existing = await currentCheck(client, context.head, name, appId);
  if (existing !== null) {
    assert.equal(existing.head_sha, context.head); assert.ok(['queued', 'in_progress'].includes(existing.status), 'terminal owner result cannot be reopened');
    assert.ok(existing.conclusion === null || existing.conclusion === undefined);
    const allowed = [external];
    if (previous === null) allowed.push(`repository-review/pending:${context.base}:${context.head}`);
    else {
      allowed.push(`repository-review/v1:${previous.runId}:${previous.artifactId}:${previous.sha256}`,
        `repository-review/unresolved:${previous.runId}:${context.base}:${context.head}`);
    }
    assert.ok(allowed.includes(existing.external_id), 'original owner invocation must be recovered before another start');
    if (existing.external_id === external) return {checkId: existing.id};
  }
  const body = {name, status: 'in_progress', external_id: external,
    details_url: `https://github.com/${context.repository}/actions/runs/${runId}`,
    output: {title: 'Original owner invocation admitted', summary: `Frozen review ${context.base}..${context.head}. Original evidence is required before any successor invocation.`}};
  if (existing === null) body.head_sha = context.head;
  let failure;
  try {
    const response = await client.request({method: existing ? 'PATCH' : 'POST', path: existing ? `/check-runs/${existing.id}` : '/check-runs', body});
    assert.equal(response.status, existing ? 200 : 201);
  } catch (error) {failure = error;}
  const actual = await currentCheck(client, context.head, name, appId);
  assert.ok(actual && actual.external_id === external && actual.status === 'in_progress', failure?.message ?? 'review start marker not observed');
  assert.equal(actual.head_sha, context.head); assert.ok(actual.conclusion === null || actual.conclusion === undefined);
  return {checkId: actual.id};
}

if (import.meta.main) {
  assert.equal(process.argv.length, 4);
  const config = parseEvidenceJson(readRegular(process.argv[2], 4 * 1024 * 1024));
  const identity = parseEvidenceJson(readRegular(process.argv[3], 1024 * 1024));
  assert.equal(identity.role, 'check'); assert.equal(identity.repository, 'tkersey/horos');
  assert.equal(process.env.GITHUB_SHA, config.controlCommit); assert.equal(process.env.GITHUB_REPOSITORY, identity.repository);
  process.stdout.write(`${JSON.stringify(await markHorosReviewStarted({...config, runId: Number(process.env.GITHUB_RUN_ID), appId: identity.appId}))}\n`);
}
