import assert from 'node:assert/strict';
import test from 'node:test';
import {readReviewResult, reviewNames} from './review-result.mjs';
import {sha256} from './encoding.mjs';

function fixture(purpose = 'pull') {
  const subject = {repository: 'tkersey/horos', base: 'a'.repeat(40), head: 'b'.repeat(40), tree: 'c'.repeat(40), purpose};
  const names = reviewNames(subject.base, subject.head, purpose);
  const results = [], starts = [], checks = [], runs = new Map(); let fallbacks = 0;
  const command = async args => {
    const path = args[1].replace('repos/tkersey/horos/', '');
    let value;
    if (path === `actions/artifacts?name=${names.result}&per_page=100&page=1`) value = {artifacts: results};
    else if (path === `actions/artifacts?name=${names.start}&per_page=100&page=1`) value = {artifacts: starts};
    else if (path === `commits/${subject.head}/check-runs?filter=all&per_page=100&page=1`) value = {check_runs: checks};
    else if (/^actions\/runs\/[0-9]+$/.test(path)) value = runs.get(Number(path.split('/').at(-1)));
    assert.ok(value, `unexpected read: ${path}`); return Buffer.from(JSON.stringify(value));
  };
  const published = async actual => {assert.deepEqual(actual, subject); fallbacks++; return null;};
  const artifact = (name, runId = 8) => ({id: runId + 100, name, expired: true, created_at: '2026-10-30T01:00:00Z',
    workflow_run: {id: runId, repository_id: 1176152390, head_repository_id: 1176152390, head_branch: 'main', head_sha: subject.base}});
  runs.set(8, {id: 8, path: '.github/workflows/repository-review.yml', head_branch: 'main', event: 'schedule', status: 'completed'});
  return {subject, names, results, starts, checks, runs, command, published, artifact, fallbackCount: () => fallbacks};
}

test('only an unobserved subject with no original or retained evidence is absent', async () => {
  const value = fixture(); assert.deepEqual(await readReviewResult(value.subject, value.command, value.published), {status: 'absent'});
  assert.equal(value.fallbackCount(), 1);
});

for (const purpose of ['pull', 'bootstrap']) for (const external of ['v1', 'unresolved']) test(`${purpose} ${external} invocation survives artifact expiry`, async () => {
  const value = fixture(purpose);
  value.checks.push({id: 77, name: purpose === 'pull' ? 'Repository owner review' : 'Repository bootstrap review', head_sha: value.subject.head,
    external_id: external === 'v1' ? `repository-review/v1:8:108:${'d'.repeat(64)}` : `repository-review/unresolved:8:${value.subject.base}:${value.subject.head}`});
  assert.equal((await readReviewResult(value.subject, value.command, value.published)).status, 'blocked');
});

test('authenticated retained publication restores a deleted original artifact', async () => {
  const value = fixture(), original = {status: 'complete', bytes: Buffer.from('original retained test bytes')};
  assert.equal(await readReviewResult(value.subject, value.command, async subject => {assert.deepEqual(subject, value.subject); return original;}), original);
});

test('expired original must match retained exact bytes and cannot start a favorable new attempt', async () => {
  const value = fixture(), original = {status: 'complete', bytes: Buffer.from('original retained test bytes')};
  value.results.push({...value.artifact(value.names.result), digest: `sha256:${sha256(original.bytes)}`});
  assert.equal(await readReviewResult(value.subject, value.command, async () => original), original);
  await assert.rejects(() => readReviewResult(value.subject, value.command, value.published), /expired/);
  await assert.rejects(() => readReviewResult(value.subject, value.command, async () => ({...original, bytes: Buffer.from('changed')})), /differs from expired/);
});

for (const status of ['completed', 'in_progress']) test(`started ${status} invocation without result stays owned`, async () => {
  const value = fixture(); value.starts.push(value.artifact(value.names.start)); value.runs.get(8).status = status;
  assert.equal((await readReviewResult(value.subject, value.command, value.published)).status, status === 'completed' ? 'blocked' : 'running');
  assert.equal(value.fallbackCount(), 0);
});

test('candidate-supplied or unrelated workflow artifacts cannot impersonate a main owner invocation', async () => {
  const value = fixture();
  value.results.push({...value.artifact(value.names.result), workflow_run: {...value.artifact(value.names.result).workflow_run, head_repository_id: 999}});
  value.starts.push(value.artifact(value.names.start)); value.runs.get(8).path = '.github/workflows/candidate.yml';
  assert.equal((await readReviewResult(value.subject, value.command, value.published)).status, 'absent');
});

test('a later interrupted invocation blocks even when an earlier favorable retained result exists', async () => {
  const value = fixture(); value.results.push(value.artifact(value.names.result));
  value.starts.push({...value.artifact(value.names.start, 9), created_at: '2026-10-30T02:00:00Z'});
  value.runs.set(9, {...value.runs.get(8), id: 9});
  const result = await readReviewResult(value.subject, value.command, async () => {throw new Error('must retain later invocation');});
  assert.equal(result.status, 'blocked'); assert.equal(result.run.id, 9);
});
