import assert from 'node:assert/strict';
import test from 'node:test';
import {encodeRecord, maximumRecordBytes, sha256} from './encoding.mjs';
import {proposalMessage, proposalCommitOid} from './proposal.mjs';
import {encodeWriterIntent, readWriterIntentBytes, authenticateWriterIntent, readHorosWriterIntent,
  writerIntentName, writerIntentWorkflow, writerIntentJob, writerIntentPlanStep,
  writerIntentUploadStep, writerIntentWriteStep, maximumWriterIntentBytes} from './proposal-intent.mjs';
import {automationOperations} from './automation-runner.mjs';

const base = 'a'.repeat(40), successor = 'b'.repeat(40), tree = 'c'.repeat(40);
const actor = {id: 42, login: 'horos-release[bot]'};
const workflow = Buffer.from('trusted workflow fixture');

function fixture({manifestBytes = Buffer.from('native manifest fixture')} = {}) {
  const person = {name: actor.login, email: `${actor.id}+${actor.login}@users.noreply.github.com`, date: '2026-10-30T00:00:00Z'};
  const candidate = {base, tree, version: '1.0.1', manifestBytes, author: person, committer: person};
  candidate.message = proposalMessage(candidate); candidate.head = proposalCommitOid(candidate);
  const record = {schema: 'repository-publication-boundary/v1', repository: 'tkersey/horos',
    source: {commit: base, tree}, status: 'prepare', version: candidate.version};
  const input = {candidate, actor, boundary: {record, sha256: sha256(encodeRecord(record))},
    controlCommit: base, runId: 12, workflowSha256: sha256(workflow), identity: {appId: 9, installationId: 10},
    toolSha256: 'd'.repeat(64), branchBefore: null};
  const bytes = encodeWriterIntent(input);
  const run = {id: 12, repository: {id: 1176152390}, head_repository: {id: 1176152390},
    path: writerIntentWorkflow, head_sha: base, head_branch: 'main', event: 'schedule',
    run_attempt: 1, status: 'completed', conclusion: 'failure', workflow_id: 50};
  const step = (name, number, start, end) => ({name, number, status: 'completed', conclusion: 'success',
    started_at: `2026-10-30T00:0${start}:00Z`, completed_at: `2026-10-30T00:0${end}:00Z`});
  const job = {id: 15, name: writerIntentJob, run_id: 12, run_attempt: 1, head_sha: base,
    status: 'completed', conclusion: 'failure', labels: ['ubuntu-24.04'], started_at: '2026-10-30T00:00:00Z',
    steps: [step(writerIntentPlanStep, 6, 1, 2), step(writerIntentUploadStep, 7, 2, 3),
      {...step(writerIntentWriteStep, 8, 3, 4), conclusion: 'failure'}]};
  const artifact = {id: 16, name: writerIntentName(base, candidate.head), expired: false, size_in_bytes: bytes.length,
    digest: `sha256:${sha256(bytes)}`, workflow_run: {id: 12, repository_id: 1176152390,
      head_repository_id: 1176152390, head_sha: base}};
  const replies = new Map([
    ['', {full_name: 'tkersey/horos', id: 1176152390, default_branch: 'main'}],
    ['/actions/runs/12', run],
    ['/git/ref/heads/main', {ref: 'refs/heads/main', object: {type: 'commit', sha: successor}}],
    [`/compare/${base}...${successor}`, {base_commit: {sha: base}, merge_base_commit: {sha: base}, status: 'ahead'}],
    ['/actions/workflows/50', {path: writerIntentWorkflow}],
    [`/contents/${writerIntentWorkflow}?ref=${base}`, {type: 'file', encoding: 'base64', content: workflow.toString('base64')}],
    ['/actions/runs/12/attempts/1/jobs?per_page=100&page=1', {jobs: [job]}],
    ['/actions/artifacts?per_page=100&page=1', {artifacts: [artifact]}],
    ['/actions/artifacts/16/zip', bytes],
  ]);
  const command = async (args, maximumBytes) => {
    assert.equal(args[0], 'api'); const key = args[1].slice('repos/tkersey/horos'.length);
    assert.ok(replies.has(key), `unexpected API ${key}`); const value = replies.get(key);
    if (Buffer.isBuffer(value)) assert.equal(maximumBytes, maximumWriterIntentBytes);
    return Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
  };
  const replace = value => {
    const next = encodeRecord(value);
    replies.set('/actions/artifacts/16/zip', next); artifact.size_in_bytes = next.length;
    artifact.digest = `sha256:${sha256(next)}`;
  };
  return {input, bytes, candidate, run, job, artifact, replies, command, replace};
}

for (const status of ['in_progress', 'completed']) test(`original prewrite intent survives later writer failure with run ${status}`, async () => {
  const f = fixture(); f.run.status = status;
  const result = await readHorosWriterIntent({head: f.candidate.head, actor}, f.command);
  assert.deepEqual(result.candidate, f.candidate); assert.deepEqual(result.bytes, f.bytes);
  assert.equal(result.run.id, 12); assert.equal(result.job.id, 15);
});

for (const [name, mutate] of [
  ['candidate control', f => {f.run.head_sha = successor;}],
  ['wrong workflow', f => {f.run.path = '.github/workflows/diagnostics.yml';}],
  ['untrusted trigger', f => {f.run.event = 'pull_request';}],
  ['untrusted branch', f => {f.run.head_branch = 'candidate';}],
  ['repeated attempt', f => {f.run.run_attempt = 2;}],
  ['unstarted producer', f => {f.run.status = 'queued';}],
  ['wrong job head', f => {f.job.head_sha = successor;}],
  ['wrong runner', f => {f.job.labels = ['self-hosted'];}],
  ['expired intent', f => {f.artifact.expired = true;}],
  ['cross repository artifact', f => {f.artifact.workflow_run.repository_id++;}],
  ['wrong artifact run', f => {f.artifact.workflow_run.id++;}],
  ['changed digest', f => {f.artifact.digest = `sha256:${'0'.repeat(64)}`;}],
  ['oversized intent', f => {f.artifact.size_in_bytes = maximumWriterIntentBytes + 1;}],
  ['changed workflow', f => {f.replies.get(`/contents/${writerIntentWorkflow}?ref=${base}`).content = Buffer.from('other').toString('base64');}],
  ['rewritten control lineage', f => {f.replies.get(`/compare/${base}...${successor}`).status = 'diverged';}],
  ['duplicate producer job', f => {f.replies.get('/actions/runs/12/attempts/1/jobs?per_page=100&page=1').jobs.push({...f.job, id: 99});}],
  ['failed planning', f => {f.job.steps[0].conclusion = 'failure';}],
  ['failed upload', f => {f.job.steps[1].conclusion = 'failure';}],
  ['unfinished upload', f => {f.job.steps[1].status = 'in_progress';}],
  ['missing upload', f => {f.job.steps.splice(1, 1);}],
  ['duplicate upload', f => {f.job.steps.push({...f.job.steps[1]});}],
  ['writer before upload', f => {f.job.steps[2].number = 5;}],
  ['writer starts before retained bytes', f => {f.job.steps[2].started_at = '2026-10-30T00:02:59Z';}],
  ['upload before plan finishes', f => {f.job.steps[1].started_at = '2026-10-30T00:01:59Z';}],
  ['production exceeds deadline', f => {f.job.steps[1].completed_at = '2026-10-30T00:10:01Z';}],
]) test(`intent authentication rejects ${name}`, async () => {
  const f = fixture(); mutate(f);
  await assert.rejects(authenticateWriterIntent(f.artifact, f.command));
});

for (const [name, mutate] of [
  ['changed candidate head', value => {value.candidate.head = successor;}],
  ['changed manifest', value => {value.candidate.manifest = Buffer.from('other manifest').toString('base64');}],
  ['changed tree', value => {value.candidate.tree = successor;}],
  ['different actor', value => {value.actor.id++;}],
  ['different parser source', value => {value.tool.sourceCommit = successor;}],
  ['invalid parser digest', value => {value.tool.sha256 = 'unknown';}],
  ['changed boundary', value => {value.boundary.version = '99.0.0';}],
  ['already written intent', value => {value.branch.before = value.branch.after;}],
]) test(`intent record rejects ${name}`, () => {
  const f = fixture(), value = JSON.parse(f.bytes); mutate(value);
  assert.throws(() => readWriterIntentBytes(encodeRecord(value)));
});

test('required original intent cannot be replaced by absent or expired evidence', async () => {
  const f = fixture(); f.replies.get('/actions/artifacts?per_page=100&page=1').artifacts = [];
  await assert.rejects(readHorosWriterIntent({head: f.candidate.head, actor}, f.command), /unavailable/);
  assert.equal(await readHorosWriterIntent({head: f.candidate.head, actor, optional: true}, f.command), null);
  f.replies.get('/actions/artifacts?per_page=100&page=1').artifacts = [f.artifact]; f.artifact.expired = true;
  await assert.rejects(readHorosWriterIntent({head: f.candidate.head, actor, optional: true}, f.command), /expired/);
});

test('original intent must match the current App actor and exact branch predecessor', async () => {
  const f = fixture();
  await assert.rejects(readHorosWriterIntent({head: f.candidate.head, actor: {...actor, id: 43}}, f.command));
  const operations = automationOperations({actor, command: f.command, native: {}, client: {}});
  await operations.intent({candidate: f.candidate, branchBefore: null});
  await assert.rejects(operations.intent({candidate: f.candidate, branchBefore: successor}), /different predecessor/);
});

test('original intent reuses identical candidate evidence without another producer', async () => {
  const f = fixture(), operations = automationOperations({actor, command: f.command, native: {}, client: {}});
  assert.deepEqual(await operations.prepareIntent(f.input), {status: 'writer intent retained', intentRunId: 12, head: f.candidate.head});
});

test('planning never certifies a preexisting unknown orphan retroactively', async () => {
  const f = fixture(); f.replies.get('/actions/artifacts?per_page=100&page=1').artifacts = [];
  const client = {request: async ({path}) => {
    if (path === '/git/ref/heads/automation/dependency-release') return {status: 200,
      body: {ref: 'refs/heads/automation/dependency-release', object: {type: 'commit', sha: f.candidate.head}}};
    assert.match(path, /^\/pulls\?/); return {status: 200, body: []};
  }};
  const operations = automationOperations({actor, command: f.command, native: {sha256: f.input.toolSha256}, client});
  await assert.rejects(operations.prepareIntent(f.input), /original writer intent unavailable/);
});

test('intent transport preserves the full supported manifest capacity through authenticated download', async () => {
  const manifestBytes = Buffer.alloc(maximumRecordBytes, 0x20);
  Buffer.from('.{ .name = .horos, .version = "1.0.1" }\n').copy(manifestBytes);
  const f = fixture({manifestBytes});
  assert.ok(f.bytes.length > maximumRecordBytes);
  const retained = await readHorosWriterIntent({head: f.candidate.head, actor}, f.command);
  assert.deepEqual(retained.candidate.manifestBytes, manifestBytes);
  assert.equal(retained.value.boundarySha256, sha256(encodeRecord(f.input.boundary.record)));
});

test('larger intent transport preserves source manifest and boundary limits', () => {
  for (const manifestBytes of [Buffer.alloc(0), Buffer.alloc(maximumRecordBytes + 1)])
    assert.throws(() => fixture({manifestBytes}), /unsupported candidate manifest size/);
  const f = fixture(), boundary = {...f.input.boundary.record, rationale: 'x'.repeat(maximumRecordBytes)};
  assert.throws(() => encodeWriterIntent({...f.input,
    boundary: {record: boundary, sha256: 'a'.repeat(64)}}), /record too large/);
  assert.throws(() => readWriterIntentBytes(Buffer.alloc(maximumWriterIntentBytes + 1)), /too large/);
});
