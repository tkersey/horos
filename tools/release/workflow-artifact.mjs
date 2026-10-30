import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {repositories} from './record.mjs';
import {sha256} from './encoding.mjs';

export async function workflowPages(reader, path, field) {
  const values = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const response = await reader.api(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    const items = response[field];
    assert.ok(Array.isArray(items) && items.length <= 100);
    for (const item of items) {
      assert.ok(Number.isSafeInteger(item.id) && item.id > 0 && !seen.has(item.id), 'ambiguous workflow observation');
      seen.add(item.id); values.push(item);
    }
    if (items.length < 100) return values;
  }
  throw new Error('workflow pagination capacity exceeded');
}

export async function authenticateWorkflowRun(reader, {runId, controlCommit, workflowPath, workflowSha256}) {
  assert.ok(Number.isSafeInteger(runId) && runId > 0);
  assert.match(controlCommit, /^[0-9a-f]{40}$/);
  assert.match(workflowPath, /^\.github\/workflows\/[a-z0-9-]+\.yml$/);
  assert.match(workflowSha256, /^[0-9a-f]{64}$/);
  await reader.verifyRepository();
  const run = await reader.api(`actions/runs/${runId}`);
  assert.equal(run.id, runId);
  assert.equal(run.repository.id, repositories[reader.repository]);
  assert.equal(run.head_repository.id, repositories[reader.repository]);
  assert.equal(run.path, workflowPath);
  assert.equal(run.head_sha, controlCommit, 'workflow did not execute accepted control revision');
  assert.equal(run.head_branch, 'main', 'workflow did not execute on trusted branch');
  assert.ok(['schedule', 'workflow_dispatch', 'workflow_run'].includes(run.event), 'unsupported control trigger');
  assert.equal(run.run_attempt, 1, 'repeated control execution is not original evidence');
  assert.equal(run.status, 'completed', 'control run is still pending');
  assert.equal(run.conclusion, 'success', 'control run failed');
  const main = await reader.api('git/ref/heads/main');
  assert.equal(main.ref, 'refs/heads/main'); assert.equal(main.object.type, 'commit');
  assert.ok(await reader.forward(controlCommit, main.object.sha), 'unapproved control lineage');
  const workflow = await reader.api(`actions/workflows/${run.workflow_id}`);
  assert.equal(workflow.path, workflowPath);
  const definition = await reader.api(`contents/${workflowPath}?ref=${controlCommit}`);
  assert.equal(definition.type, 'file'); assert.equal(definition.encoding, 'base64');
  const bytes = Buffer.from(definition.content.replaceAll('\n', ''), 'base64');
  assert.equal(sha256(bytes), workflowSha256, 'workflow definition differs');
  return run;
}

export async function authenticateWorkflowArtifact({repository, runId, controlCommit, workflowPath,
  workflowSha256, jobName, name, maximumBytes = 128 * 1024 * 1024}, command = githubCommand) {
  assert.match(name, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/);
  assert.ok(Number.isSafeInteger(maximumBytes) && maximumBytes > 0 && maximumBytes <= 512 * 1024 * 1024);
  const reader = new GitHubReader(repository, command);
  const run = await authenticateWorkflowRun(reader, {runId, controlCommit, workflowPath, workflowSha256});
  const jobs = await workflowPages(reader, `actions/runs/${runId}/attempts/1/jobs`, 'jobs');
  const matching = jobs.filter(job => job.name === jobName);
  assert.equal(matching.length, 1, 'missing unique trusted producer job');
  const job = matching[0];
  assert.equal(job.run_id, runId); assert.equal(job.run_attempt, 1); assert.equal(job.head_sha, controlCommit);
  assert.equal(job.status, 'completed'); assert.equal(job.conclusion, 'success', 'artifact producer did not succeed');
  assert.ok(job.labels?.includes('ubuntu-24.04'), 'unexpected producer platform');
  const start = Date.parse(job.started_at), end = Date.parse(job.completed_at);
  assert.ok(Number.isFinite(start) && Number.isFinite(end) && end >= start && end - start <= 600000, 'producer exceeded deadline');
  const artifacts = await workflowPages(reader, `actions/runs/${runId}/artifacts`, 'artifacts');
  const matches = artifacts.filter(item => item.name === name);
  assert.equal(matches.length, 1, 'missing unique original artifact');
  const artifact = matches[0];
  assert.equal(artifact.expired, false, 'original artifact expired');
  assert.equal(artifact.workflow_run.id, runId);
  assert.equal(artifact.workflow_run.repository_id, repositories[repository]);
  assert.equal(artifact.workflow_run.head_repository_id, repositories[repository]);
  assert.equal(artifact.workflow_run.head_sha, controlCommit);
  assert.ok(Number.isSafeInteger(artifact.size_in_bytes) && artifact.size_in_bytes > 0 && artifact.size_in_bytes <= maximumBytes);
  const bytes = await command(['api', `repos/${repository}/actions/artifacts/${artifact.id}/zip`], maximumBytes);
  assert.ok(Buffer.isBuffer(bytes)); assert.equal(bytes.length, artifact.size_in_bytes);
  assert.equal(artifact.digest, `sha256:${sha256(bytes)}`, 'artifact transport changed');
  return {bytes, run, job, artifact, workflow: {path: workflowPath, commit: controlCommit, sha256: workflowSha256}};
}
