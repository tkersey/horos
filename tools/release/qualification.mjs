import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

export const horosJobs = Object.freeze({
  'Source preflight': 300,
  'Qualification / installation': 600,
  'Qualification / contracts': 600,
  'Release tooling': 600,
  native: 300,
});

async function pages(reader, path, field) {
  const all = [], ids = new Set();
  for (let page = 1; page <= 100; page++) {
    const value = await reader.api(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    const values = value[field];
    assert.ok(Array.isArray(values) && values.length <= 100, 'invalid qualification page');
    for (const item of values) {
      assert.ok(Number.isSafeInteger(item.id) && item.id > 0 && !ids.has(item.id), 'duplicate qualification observation');
      ids.add(item.id); all.push(item);
    }
    if (values.length < 100) return all;
  }
  throw new Error('qualification pagination capacity exceeded');
}

export function validateHorosJobs(jobs, run) {
  assert.ok(Array.isArray(jobs));
  assert.deepEqual(jobs.map(job => job.name).sort(), Object.keys(horosJobs).sort(), 'required qualification inventory differs');
  for (const job of jobs) {
    assert.equal(job.run_id, run.id);
    assert.equal(job.run_attempt, 1);
    assert.equal(job.head_sha, run.head_sha);
    assert.equal(job.status, 'completed');
    assert.equal(job.conclusion, 'success', `qualification failed: ${job.name}`);
    const started = Date.parse(job.started_at), completed = Date.parse(job.completed_at);
    assert.ok(Number.isFinite(started) && Number.isFinite(completed) && completed >= started);
    assert.ok(completed - started <= horosJobs[job.name] * 1000, `qualification budget exceeded: ${job.name}`);
    assert.ok(Array.isArray(job.labels) && job.labels.includes('ubuntu-24.04'), 'wrong qualification platform');
    assert.ok(Array.isArray(job.steps) && job.steps.length > 0, 'missing original step outcomes');
  }
}

export async function admitHorosQualification({runId, commit, tree, event = 'push'}, command = githubCommand) {
  assert.match(commit, /^[0-9a-f]{40}$/); assert.match(tree, /^[0-9a-f]{40}$/);
  assert.ok(Number.isSafeInteger(runId) && runId > 0);
  assert.ok(['push', 'pull_request'].includes(event));
  const reader = new GitHubReader('tkersey/horos', command);
  await reader.verifyRepository();
  const run = await reader.api(`actions/runs/${runId}`);
  assert.equal(run.id, runId);
  assert.equal(run.repository.id, 1176152390);
  assert.equal(run.head_repository.id, 1176152390);
  assert.equal(run.path, '.github/workflows/zig.yml');
  assert.equal(run.head_sha, commit);
  assert.equal(run.event, event);
  if (event === 'push') assert.equal(run.head_branch, 'main');
  assert.equal(run.run_attempt, 1, 'qualification retry cannot replace original evidence');
  assert.equal(run.status, 'completed');
  assert.equal(run.conclusion, 'success');
  const observed = await pages(reader, `actions/workflows/zig.yml/runs?head_sha=${commit}&event=${event}`, 'workflow_runs');
  assert.equal(observed.length, 1, 'ambiguous duplicate qualification runs');
  assert.equal(observed[0].id, runId);
  const workflow = await reader.api(`actions/workflows/${run.workflow_id}`);
  assert.equal(workflow.path, run.path);
  const definition = await reader.api(`contents/${run.path}?ref=${commit}`);
  assert.equal(definition.type, 'file'); assert.equal(definition.encoding, 'base64');
  const workflowBytes = Buffer.from(definition.content.replace(/\n/g, ''), 'base64');
  const jobs = await pages(reader, `actions/runs/${runId}/attempts/1/jobs`, 'jobs');
  validateHorosJobs(jobs, run);
  const artifacts = await pages(reader, `actions/runs/${runId}/artifacts`, 'artifacts');
  const payloads = new Map();
  for (const [name, maximum] of [['source.tar', 512 * 1024 * 1024], ['source.json', 4 * 1024 * 1024]]) {
    const matches = artifacts.filter(artifact => artifact.name === name);
    assert.equal(matches.length, 1, `missing unique qualified artifact: ${name}`);
    const artifact = matches[0];
    assert.equal(artifact.expired, false, 'required qualification artifact expired');
    assert.equal(artifact.workflow_run.id, runId);
    assert.equal(artifact.workflow_run.repository_id, 1176152390);
    assert.equal(artifact.workflow_run.head_repository_id, 1176152390);
    assert.equal(artifact.workflow_run.head_sha, commit);
    assert.ok(Number.isSafeInteger(artifact.size_in_bytes) && artifact.size_in_bytes > 0 && artifact.size_in_bytes <= maximum);
    const bytes = await command(['api', `repos/tkersey/horos/actions/artifacts/${artifact.id}/zip`], maximum);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length === artifact.size_in_bytes, 'artifact transport size differs');
    assert.equal(artifact.digest, `sha256:${sha256(bytes)}`, 'artifact transport digest differs');
    payloads.set(name, bytes);
  }
  const inventory = parseEvidenceJson(payloads.get('source.json'));
  assert.equal(inventory.commit, commit, 'actual packaged checkout differs');
  assert.equal(inventory.tree, tree, 'actual packaged tree differs');
  assert.equal(inventory.compiler, '0.17.0');
  assert.equal(inventory.archive, 'source.tar');
  assert.equal(inventory.sha256, sha256(payloads.get('source.tar')));
  assert.equal(inventory.size, payloads.get('source.tar').length);
  const actual = await reader.api(`git/commits/${commit}`);
  assert.equal(actual.sha, commit); assert.equal(actual.tree.sha, tree);
  const evidence = encodeRecord({run, jobs, artifacts, workflowSha256: sha256(workflowBytes)});
  return {run, jobs, payloads, evidence,
    workflow: {path: run.path, commit, sha256: sha256(workflowBytes)}};
}
