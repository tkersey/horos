import assert from 'node:assert/strict';
import test from 'node:test';
import {authenticateWorkflowArtifact} from './workflow-artifact.mjs';
import {sha256} from './encoding.mjs';

const controlCommit = 'a'.repeat(40), successor = 'b'.repeat(40);
const workflow = Buffer.from('trusted fixture control'), payload = Buffer.from('original artifact bytes');
const options = {repository: 'tkersey/horos', runId: 12, controlCommit,
  workflowPath: '.github/workflows/repository-review.yml', workflowSha256: sha256(workflow),
  jobName: 'Owner review', name: 'review-state.json.gz'};

function fixture() {
  const run = {id: 12, repository: {id: 1176152390}, head_repository: {id: 1176152390},
    path: options.workflowPath, head_sha: controlCommit, head_branch: 'main', event: 'schedule',
    run_attempt: 1, status: 'completed', conclusion: 'success', workflow_id: 50};
  const job = {id: 15, name: options.jobName, run_id: 12, run_attempt: 1, head_sha: controlCommit,
    status: 'completed', conclusion: 'success', labels: ['ubuntu-24.04'],
    started_at: '2026-10-30T00:00:00Z', completed_at: '2026-10-30T00:08:00Z'};
  const artifact = {id: 16, name: options.name, expired: false, size_in_bytes: payload.length,
    digest: `sha256:${sha256(payload)}`, workflow_run: {id: 12, repository_id: 1176152390,
      head_repository_id: 1176152390, head_sha: controlCommit}};
  const replies = new Map([
    ['', {full_name: 'tkersey/horos', id: 1176152390, default_branch: 'main'}],
    ['/actions/runs/12', run],
    ['/git/ref/heads/main', {ref: 'refs/heads/main', object: {type: 'commit', sha: successor}}],
    [`/compare/${controlCommit}...${successor}`, {base_commit: {sha: controlCommit}, merge_base_commit: {sha: controlCommit}, status: 'ahead'}],
    ['/actions/workflows/50', {path: options.workflowPath}],
    [`/contents/${options.workflowPath}?ref=${controlCommit}`, {type: 'file', encoding: 'base64', content: workflow.toString('base64')}],
    ['/actions/runs/12/attempts/1/jobs?per_page=100&page=1', {jobs: [job]}],
    ['/actions/runs/12/artifacts?per_page=100&page=1', {artifacts: [artifact]}],
    ['/actions/artifacts/16/zip', payload],
  ]);
  const command = async args => {
    assert.equal(args[0], 'api');
    const key = args[1].slice('repos/tkersey/horos'.length);
    assert.ok(replies.has(key), `unexpected API ${key}`);
    const value = replies.get(key);
    return Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
  };
  return {run, job, artifact, replies, command};
}

test('original workflow and exact artifact authenticate before restoration', async () => {
  const value = fixture();
  const result = await authenticateWorkflowArtifact(options, value.command);
  assert.deepEqual(result.bytes, payload);
  assert.equal(result.run.id, 12); assert.equal(result.job.id, 15);
  assert.equal(result.workflow.sha256, sha256(workflow));
});

for (const [name, mutate] of [
  ['candidate control', value => {value.run.head_sha = successor;}],
  ['wrong workflow', value => {value.run.path = '.github/workflows/diagnostics.yml';}],
  ['untrusted trigger', value => {value.run.event = 'pull_request';}],
  ['untrusted branch', value => {value.run.head_branch = 'candidate';}],
  ['repeated attempt', value => {value.run.run_attempt = 2;}],
  ['failed producer run', value => {value.run.conclusion = 'failure';}],
  ['skipped producer job', value => {value.job.conclusion = 'skipped';}],
  ['wrong job head', value => {value.job.head_sha = successor;}],
  ['wrong runner', value => {value.job.labels = ['self-hosted'];}],
  ['expired state', value => {value.artifact.expired = true;}],
  ['cross repository artifact', value => {value.artifact.workflow_run.repository_id++;}],
  ['wrong artifact run', value => {value.artifact.workflow_run.id++;}],
  ['changed digest', value => {value.artifact.digest = `sha256:${'0'.repeat(64)}`;}],
  ['oversized artifact', value => {value.artifact.size_in_bytes = 512 * 1024 * 1024 + 1;}],
  ['changed workflow bytes', value => {value.replies.get(`/contents/${options.workflowPath}?ref=${controlCommit}`).content = Buffer.from('other').toString('base64');}],
  ['rewritten control lineage', value => {value.replies.get(`/compare/${controlCommit}...${successor}`).status = 'diverged';}],
  ['duplicate producer job', value => {value.replies.get('/actions/runs/12/attempts/1/jobs?per_page=100&page=1').jobs.push({...value.job, id: 99});}],
  ['duplicate artifact', value => {value.replies.get('/actions/runs/12/artifacts?per_page=100&page=1').artifacts.push({...value.artifact, id: 99});}],
  ['producer budget exceeded', value => {value.job.completed_at = '2026-10-30T00:10:01Z';}],
]) {
  test(`workflow admission rejects ${name}`, async () => {
    const value = fixture(); mutate(value);
    await assert.rejects(authenticateWorkflowArtifact(options, value.command));
  });
}
