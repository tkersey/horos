import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {GitHubReader, githubCommand} from './github.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {sha256} from './encoding.mjs';
import {readRecord, repositories} from './record.mjs';
import {admitPublishedRelease} from './release-admission.mjs';
import {reviewEnvelope, reviewNames} from './review-result.mjs';

function positive(value) { assert.ok(Number.isSafeInteger(value) && value > 0); }

export function serializeReviewArtifact(result, subject) {
  const bytes = Buffer.from(JSON.stringify({schema: 'repository-retained-review/v1',
    bytes: result.bytes.toString('base64'), run: result.run, job: result.job,
    artifact: result.artifact, workflow: result.workflow}));
  deserializeReviewArtifact(bytes, subject);
  return bytes;
}

export function deserializeReviewArtifact(bytes, subject) {
  const value = parseEvidenceJson(bytes, 192 * 1024 * 1024);
  assert.equal(value.schema, 'repository-retained-review/v1');
  const original = Buffer.from(value.bytes, 'base64');
  assert.equal(original.toString('base64'), value.bytes);
  const envelope = reviewEnvelope(original, subject);
  assert.equal(envelope.status, 'complete', 'published review was not complete');
  assert.equal(Boolean(envelope.context.bootstrap), subject.purpose === 'bootstrap');
  const {run, job, artifact, workflow} = value;
  positive(run.id); positive(job.id); positive(artifact.id);
  assert.equal(run.repository.id, repositories[subject.repository]);
  assert.equal(run.head_repository.id, repositories[subject.repository]);
  assert.equal(run.run_attempt, 1); assert.equal(run.head_branch, 'main');
  assert.equal(run.status, 'completed'); assert.equal(run.conclusion, 'success');
  assert.ok(['schedule', 'workflow_dispatch', 'workflow_run'].includes(run.event));
  assert.equal(run.html_url, `https://github.com/${subject.repository}/actions/runs/${run.id}`);
  assert.equal(workflow.path, '.github/workflows/repository-review.yml');
  assert.equal(run.path, workflow.path); assert.equal(run.head_sha, workflow.commit);
  assert.match(workflow.commit, /^[0-9a-f]{40}$/); assert.match(workflow.sha256, /^[0-9a-f]{64}$/);
  assert.equal(job.name, 'Owner review'); assert.equal(job.run_id, run.id); assert.equal(job.run_attempt, 1);
  assert.equal(job.head_sha, run.head_sha); assert.equal(job.status, 'completed'); assert.equal(job.conclusion, 'success');
  assert.ok(job.labels.includes('ubuntu-24.04'));
  const start = Date.parse(job.started_at), end = Date.parse(job.completed_at);
  assert.ok(Number.isFinite(start) && Number.isFinite(end) && end >= start && end - start <= 600000);
  assert.equal(artifact.name, reviewNames(subject.base, subject.head, subject.purpose ?? 'pull').result);
  assert.equal(artifact.workflow_run.id, run.id);
  assert.equal(artifact.workflow_run.repository_id, repositories[subject.repository]);
  assert.equal(artifact.workflow_run.head_repository_id, repositories[subject.repository]);
  assert.equal(artifact.workflow_run.head_sha, run.head_sha);
  assert.equal(artifact.size_in_bytes, original.length); assert.equal(artifact.digest, `sha256:${sha256(original)}`);
  return {status: 'complete', bytes: original, envelope, run, job, artifact, workflow};
}

async function assets(reader, id) {
  const result = [], seen = new Set();
  for (let page = 1; page <= 3; page++) {
    const rows = await reader.api(`releases/${id}/assets?per_page=100&page=${page}`);
    assert.ok(Array.isArray(rows) && rows.length <= 100);
    for (const row of rows) {positive(row.id); assert.ok(!seen.has(row.id)); seen.add(row.id); result.push(row);}
    if (rows.length < 100) return result;
  }
  throw new Error('published review asset inventory exceeds bound');
}

export async function readPublishedReview(subject, command = githubCommand, admit = admitPublishedRelease) {
  const reader = new GitHubReader(subject.repository, command), name = reviewNames(subject.base, subject.head, subject.purpose ?? 'pull').result;
  let selected = null;
  for (const release of await reader.releases()) {
    const records = (await assets(reader, release.id)).filter(asset => asset.name === 'release.json');
    assert.ok(records.length <= 1, 'ambiguous published release record');
    if (records.length === 0) continue;
    const asset = records[0];
    assert.ok(asset.size > 0 && asset.size <= 1024 * 1024);
    const hint = readRecord(await command(['api', `repos/${subject.repository}/releases/assets/${asset.id}`,
      '-H', 'Accept: application/octet-stream'], asset.size + 1));
    if (!hint.artifacts.some(item => item.name === name && item.role === 'evidence')) continue;
    const directory = mkdtempSync(join(tmpdir(), 'retained-review-'));
    try {
      const published = await admit({repository: subject.repository, releaseId: release.id, outputDirectory: join(directory, 'release')}, command);
      assert.equal(published.id, release.id);
      const result = deserializeReviewArtifact(published.payloads.get(name), subject);
      if (selected !== null) {
        assert.deepEqual(result.bytes, selected.bytes, 'published copies disagree about original owner result');
        assert.deepEqual(result.workflow, selected.workflow); assert.equal(result.run.id, selected.run.id); assert.equal(result.artifact.id, selected.artifact.id);
      } else selected = {...result, retainedPublication: {id: release.id, recordSha256: published.recordSha256}};
    } finally {rmSync(directory, {recursive: true, force: true});}
  }
  return selected;
}
