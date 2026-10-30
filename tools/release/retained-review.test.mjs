import assert from 'node:assert/strict';
import test from 'node:test';
import {retainedFixture} from './promotion-test-support.mjs';
import {expectedReviewSettings} from './review-check.mjs';
import {reviewNames} from './review-result.mjs';
import {serializeReviewArtifact, deserializeReviewArtifact, readPublishedReview} from './retained-review.mjs';
import {sha256} from './encoding.mjs';
import {metadata} from './test-support.mjs';
import {produceRecord} from './record.mjs';

function fixture() {
  const subject = {repository: 'tkersey/horos', base: 'a'.repeat(40), head: 'b'.repeat(40), tree: 'c'.repeat(40), purpose: 'pull'};
  const context = {...subject, pullNumber: 42}; delete context.purpose;
  const retained = retainedFixture(context, expectedReviewSettings);
  const envelope = {schema: 'repository-review-result/v1', context, status: 'complete', epochClosed: true,
    reason: 'Original complete owner result.', turn: 1, previousSha256: null, stateSha256: null,
    retainedEvidence: Buffer.from(JSON.stringify(retained)).toString('base64')};
  const bytes = Buffer.from(JSON.stringify(envelope));
  const workflow = {path: '.github/workflows/repository-review.yml', commit: subject.base, sha256: 'd'.repeat(64)};
  const result = {bytes, run: {id: 8, run_attempt: 1, head_sha: subject.base, head_branch: 'main',
    repository: {id: 1176152390}, head_repository: {id: 1176152390}, status: 'completed', conclusion: 'success',
    event: 'schedule', path: workflow.path, html_url: 'https://github.com/tkersey/horos/actions/runs/8'},
  job: {id: 9, name: 'Owner review', run_id: 8, run_attempt: 1, head_sha: subject.base, status: 'completed', conclusion: 'success',
    labels: ['ubuntu-24.04'], started_at: '2026-10-30T01:00:00Z', completed_at: '2026-10-30T01:09:00Z'},
  artifact: {id: 10, name: reviewNames(subject.base, subject.head).result, size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    workflow_run: {id: 8, repository_id: 1176152390, head_repository_id: 1176152390, head_sha: subject.base}}, workflow};
  return {subject, result};
}

test('retains original transport and owner facts without depending on artifact lifetime', () => {
  const value = fixture(), bytes = serializeReviewArtifact(value.result, value.subject);
  const restored = deserializeReviewArtifact(bytes, value.subject);
  assert.equal(restored.status, 'complete'); assert.deepEqual(restored.bytes, value.result.bytes);
  assert.deepEqual(restored.workflow, value.result.workflow); assert.deepEqual(restored.artifact, value.result.artifact);
});

for (const [name, change] of [
  ['failed original run', value => {value.run.conclusion = 'failure';}],
  ['candidate workflow source', value => {value.run.head_branch = 'candidate';}],
  ['repeated producer attempt', value => {value.run.run_attempt = 2;}],
  ['wrong workflow', value => {value.workflow.path = '.github/workflows/other.yml';}],
  ['wrong producer platform', value => {value.job.labels = ['self-hosted'];}],
  ['over-budget original producer', value => {value.job.completed_at = '2026-10-30T01:11:00Z';}],
  ['substituted artifact bytes', value => {value.artifact.digest = `sha256:${'0'.repeat(64)}`;}],
  ['wrong artifact name', value => {value.artifact.name = 'unrelated.json';}],
]) test(`retained evidence rejects ${name}`, () => {
  const value = fixture(); change(value.result);
  assert.throws(() => serializeReviewArtifact(value.result, value.subject));
});

test('retained evidence cannot replace a different review purpose or source', () => {
  const value = fixture(), bytes = serializeReviewArtifact(value.result, value.subject);
  assert.throws(() => deserializeReviewArtifact(bytes, {...value.subject, purpose: 'bootstrap'}));
  assert.throws(() => deserializeReviewArtifact(bytes, {...value.subject, head: 'e'.repeat(40)}));
});

test('published fallback uses a raw record only as a hint and authenticates before admission', async () => {
  const value = fixture(), retained = serializeReviewArtifact(value.result, value.subject), name = value.result.artifact.name;
  const record = metadata(); record.artifacts.push({name, role: 'evidence', platform: null, bytes: 1, sha256: 'a'.repeat(64)});
  const payloads = new Map([['source.tar', Buffer.from('fixture source')], ['inventory.json', Buffer.from('{}')],
    ['evidence.json', Buffer.from('{}')], [name, retained]]);
  const recordBytes = produceRecord(record, payloads); let admissions = 0;
  const command = async args => {
    const path = args[1];
    if (path.endsWith('/releases?per_page=100&page=1')) return Buffer.from(JSON.stringify([{id: 1, draft: false, prerelease: false}]));
    if (path.endsWith('/releases/1/assets?per_page=100&page=1')) return Buffer.from(JSON.stringify([{id: 2, name: 'release.json', size: recordBytes.length}]));
    assert.ok(path.endsWith('/releases/assets/2')); return recordBytes;
  };
  const admit = async input => {
    assert.equal(input.repository, value.subject.repository); assert.equal(input.releaseId, 1);
    admissions++; return {id: 1, recordSha256: sha256(recordBytes), payloads};
  };
  const restored = await readPublishedReview(value.subject, command, admit);
  assert.equal(admissions, 1); assert.deepEqual(restored.bytes, value.result.bytes);
  await assert.rejects(() => readPublishedReview(value.subject, command, async () => {throw new Error('signature rejected');}), /signature rejected/);
});
