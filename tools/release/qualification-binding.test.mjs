import assert from 'node:assert/strict';
import test from 'node:test';
import {requireSameQualification} from './qualification-binding.mjs';
import {sha256} from './encoding.mjs';

function fixture() {
  const run = {id: 1, run_attempt: 1, workflow_id: 2, path: '.github/workflows/qualification.yml',
    head_sha: 'a'.repeat(40), head_branch: 'candidate', event: 'pull_request', status: 'completed', conclusion: 'success',
    created_at: '2026-10-30T00:00:00Z', run_started_at: '2026-10-30T00:00:01Z', check_suite_id: 3,
    repository: {id: 4, description: 'Before'}, head_repository: {id: 4}};
  const step = {number: 1, name: 'Qualify', status: 'completed', conclusion: 'success',
    started_at: '2026-10-30T00:00:02Z', completed_at: '2026-10-30T00:00:03Z'};
  const job = {id: 5, name: 'native', run_id: 1, run_attempt: 1, head_sha: run.head_sha,
    check_run_url: 'https://api.github.com/repos/example/project/check-runs/6', status: 'completed', conclusion: 'success',
    started_at: step.started_at, completed_at: step.completed_at, labels: ['x64', 'ubuntu-24.04'], steps: [step]};
  const artifact = {id: 7, name: 'source.tar', size_in_bytes: 2, digest: 'sha256:' + 'b'.repeat(64), expired: false,
    workflow_run: {id: 1, repository_id: 4, head_repository_id: 4, head_sha: run.head_sha}};
  const observed = {run, jobs: [job], artifacts: [artifact], workflowSha256: 'c'.repeat(64), profileSha256: 'd'.repeat(64)};
  const workflow = {path: run.path, commit: run.head_sha, sha256: observed.workflowSha256};
  const bytes = Buffer.from(JSON.stringify(observed));
  const original = {runId: 1, workflow, evidenceSha256: sha256(bytes), originalEvidence: bytes.toString('base64')};
  const current = () => ({run, workflow, evidence: Buffer.from(JSON.stringify(observed))});
  return {observed, original, current};
}

test('qualification correspondence preserves original bytes while ignoring provider display metadata', () => {
  const f = fixture(), original = structuredClone(f.original);
  f.observed.run.repository.description = 'After';
  f.observed.run.repository.owner = {avatar_url: 'https://example.test/new-avatar'};
  f.observed.run.display_title = 'Changed title';
  f.observed.jobs[0].runner_name = 'Retired runner';
  f.observed.jobs[0].labels.reverse();
  f.observed.artifacts[0].archive_download_url = 'https://example.test/refreshed-url';
  requireSameQualification(f.original, f.current());
  assert.deepEqual(f.original, original);
  assert.notEqual(sha256(f.current().evidence), original.evidenceSha256);
});

for (const [name, mutate] of [
  ['run', f => {f.observed.run.id++;}],
  ['attempt', f => {f.observed.run.run_attempt++;}],
  ['workflow producer', f => {f.observed.run.workflow_id++;}],
  ['source', f => {f.observed.run.head_sha = 'e'.repeat(40);}],
  ['trigger', f => {f.observed.run.event = 'workflow_dispatch';}],
  ['original trigger clock', f => {f.observed.run.created_at = '2026-10-30T00:00:02Z';}],
  ['aggregate check identity', f => {f.observed.run.check_suite_id++;}],
  ['repository identity', f => {f.observed.run.repository.id++;}],
  ['job identity', f => {f.observed.jobs[0].id++;}],
  ['job outcome', f => {f.observed.jobs[0].conclusion = 'skipped';}],
  ['job clock', f => {f.observed.jobs[0].completed_at = '2026-10-30T00:10:01Z';}],
  ['platform', f => {f.observed.jobs[0].labels = ['macos'];}],
  ['step outcome', f => {f.observed.jobs[0].steps[0].conclusion = 'failure';}],
  ['step clock', f => {f.observed.jobs[0].steps[0].completed_at = '2026-10-30T00:10:01Z';}],
  ['artifact identity', f => {f.observed.artifacts[0].id++;}],
  ['artifact bytes', f => {f.observed.artifacts[0].digest = 'sha256:' + 'e'.repeat(64);}],
  ['artifact expiry', f => {f.observed.artifacts[0].expired = true;}],
  ['artifact source', f => {f.observed.artifacts[0].workflow_run.head_sha = 'e'.repeat(40);}],
  ['workflow definition', f => {f.observed.workflowSha256 = 'e'.repeat(64);}],
  ['build profile', f => {f.observed.profileSha256 = 'e'.repeat(64);}],
]) test('qualification correspondence rejects changed ' + name, () => {
  const f = fixture(); mutate(f);
  assert.throws(() => requireSameQualification(f.original, f.current()));
});

test('qualification correspondence authenticates retained raw evidence before interpretation', () => {
  const f = fixture(); f.original.originalEvidence = f.current().evidence.subarray(1).toString('base64');
  assert.throws(() => requireSameQualification(f.original, f.current()), /digest changed/);
});
