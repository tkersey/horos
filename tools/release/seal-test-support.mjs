import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {retainedFixture} from './promotion-test-support.mjs';
import {expectedReviewSettings} from './review-check.mjs';
import {horosJobs} from './qualification.mjs';
import {reviewNames} from './review-result.mjs';
import {encodeRecord, sha256} from './encoding.mjs';

export function sealFixture() {
  const source = {commit: 'b'.repeat(40), tree: 'c'.repeat(40)}, subject = {base: 'a'.repeat(40), head: source.commit, tree: source.tree};
  const declaration = {impact: 'patch', disposition: 'compatible', rationale: 'Test declaration.', contracts: ['source']};
  const context = {repository: 'tkersey/horos', ...subject, pullNumber: 1};
  const retained = retainedFixture(context, expectedReviewSettings);
  const envelope = {schema: 'repository-review-result/v1', context, status: 'complete', epochClosed: true,
    reason: 'Test original result.', turn: 1, previousSha256: null, stateSha256: null,
    retainedEvidence: Buffer.from(JSON.stringify(retained)).toString('base64')};
  const bytes = Buffer.from(JSON.stringify(envelope));
  const result = {bytes, envelope, run: {id: 8, run_attempt: 1, head_sha: subject.base, head_branch: 'main',
    repository: {id: 1176152390}, head_repository: {id: 1176152390}, status: 'completed', conclusion: 'success',
    event: 'schedule', path: '.github/workflows/repository-review.yml', html_url: 'https://github.com/tkersey/horos/actions/runs/8'},
  job: {id: 9, name: 'Owner review', run_id: 8, run_attempt: 1, head_sha: subject.base, status: 'completed', conclusion: 'success',
    labels: ['ubuntu-24.04'], started_at: '2026-10-30T01:00:00Z', completed_at: '2026-10-30T01:09:00Z'},
  artifact: {id: 10, name: reviewNames(subject.base, subject.head).result, size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    workflow_run: {id: 8, repository_id: 1176152390, head_repository_id: 1176152390, head_sha: subject.base}},
  workflow: {path: '.github/workflows/repository-review.yml', commit: subject.base, sha256: 'd'.repeat(64)}};
  const record = {schema: 'repository-publication-boundary/v1', repository: 'tkersey/horos', source, pendingVersion: '1.0.0',
    version: '1.0.0', status: 'ready', baseline: null, bootstrap: null, changes: [{subject, declaration, versionOnly: false,
      review: {runId: 8, artifactId: 10, sha256: sha256(bytes)}}]};
  const boundaryBytes = encodeRecord(record);
  const boundary = {status: 'ready', version: '1.0.0', record, bytes: boundaryBytes, sha256: sha256(boundaryBytes),
    reviewProvenance: new Map([[sha256(bytes), result]])};
  const manifestBytes = Buffer.from('.{ .name = .horos, .version = "1.0.0" }\n'), archive = Buffer.from('Test transport payload.');
  const inventory = {archive: 'source.tar', ...source, sha256: sha256(archive), size: archive.length,
    compiler: '0.17.0', compilerPlatform: 'linux-x86_64', compilerSha256: 'f'.repeat(64), packageIdentity: `horos-1.0.0-${'A'.repeat(44)}`,
    files: [{path: 'build.zig.zon', mode: 0o644, blob: createHash('sha1').update(`blob ${manifestBytes.length}\0`).update(manifestBytes).digest('hex')}]};
  const run = {id: 17, head_sha: source.commit, event: 'push', head_branch: 'main', run_attempt: 1, status: 'completed', conclusion: 'success'};
  const jobs = Object.keys(horosJobs).map((name, index) => ({id: index + 50, name, run_id: 17, run_attempt: 1, head_sha: source.commit,
    status: 'completed', conclusion: 'success', labels: ['ubuntu-24.04'], steps: [{name: 'Test original step', conclusion: 'success'}],
    started_at: '2026-10-30T00:00:00Z', completed_at: '2026-10-30T00:01:00Z'}));
  const workflow = {path: '.github/workflows/zig.yml', commit: source.commit, sha256: 'e'.repeat(64)};
  const qualification = {run, jobs, workflow, evidence: encodeRecord({run, jobs, artifacts: [], workflowSha256: workflow.sha256}),
    payloads: new Map([['source.tar', archive], ['source.json', Buffer.from(JSON.stringify(inventory))]])};
  return {boundary, qualification, manifestBytes, admission: {path: '.github/workflows/repository-release.yml', commit: source.commit, sha256: 'f'.repeat(64)},
    node: {name: 'node', version: '26.9.0', platform: 'linux-x86_64', sha256: 'e'.repeat(64)}};
}
