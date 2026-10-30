import assert from 'node:assert/strict';
import test from 'node:test';
import {admitHorosQualification, horosJobs, validateHorosJobs} from './qualification.mjs';
import {sha256} from './encoding.mjs';

const commit = 'a'.repeat(40), tree = 'b'.repeat(40);
function fixture() {
  const run = {id: 17, repository: {id: 1176152390}, head_repository: {id: 1176152390},
    path: '.github/workflows/zig.yml', head_sha: commit, event: 'push', head_branch: 'main',
    run_attempt: 1, status: 'completed', conclusion: 'success', workflow_id: 23};
  const jobs = Object.keys(horosJobs).map((name, index) => ({id: index + 50, name, run_id: run.id,
    run_attempt: 1, head_sha: commit, status: 'completed', conclusion: 'success',
    started_at: '2026-10-30T00:00:00Z', completed_at: '2026-10-30T00:01:00Z',
    labels: ['ubuntu-24.04'], steps: [{name: 'fixture-only executed operation', status: 'completed', conclusion: 'success'}]}));
  const archive = Buffer.from('test adapter payload, not a native source fixture');
  const inventory = Buffer.from(JSON.stringify({commit, tree, compiler: '0.17.0', archive: 'source.tar',
    sha256: sha256(archive), size: archive.length}));
  const artifacts = [['source.tar', archive], ['source.json', inventory]].map(([name, bytes], index) => ({
    id: index + 80, name, expired: false, size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
    workflow_run: {id: run.id, repository_id: 1176152390, head_repository_id: 1176152390, head_sha: commit}}));
  const replies = new Map([
    ['repos/tkersey/horos', {full_name: 'tkersey/horos', id: 1176152390, default_branch: 'main'}],
    ['repos/tkersey/horos/actions/runs/17', run],
    [`repos/tkersey/horos/actions/workflows/zig.yml/runs?head_sha=${commit}&event=push&per_page=100&page=1`, {workflow_runs: [run]}],
    ['repos/tkersey/horos/actions/workflows/23', {path: run.path}],
    [`repos/tkersey/horos/contents/${run.path}?ref=${commit}`, {type: 'file', encoding: 'base64', content: Buffer.from('fixture workflow').toString('base64')}],
    ['repos/tkersey/horos/actions/runs/17/attempts/1/jobs?per_page=100&page=1', {jobs}],
    ['repos/tkersey/horos/actions/runs/17/artifacts?per_page=100&page=1', {artifacts}],
    ['repos/tkersey/horos/actions/artifacts/80/zip', archive],
    ['repos/tkersey/horos/actions/artifacts/81/zip', inventory],
    [`repos/tkersey/horos/git/commits/${commit}`, {sha: commit, tree: {sha: tree}}],
  ]);
  const command = async args => {
    assert.ok(replies.has(args[1]), `unexpected qualification API ${args[1]}`);
    const value = replies.get(args[1]);
    return Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
  };
  return {run, jobs, artifacts, replies, command};
}

test('admission retains original single-run evidence and exact consumer-tested source payloads', async () => {
  const value = fixture();
  const result = await admitHorosQualification({runId: 17, commit, tree}, value.command);
  assert.equal(result.run.id, 17);
  assert.equal(result.jobs.length, 5);
  assert.equal(result.payloads.size, 2);
  assert.deepEqual(JSON.parse(result.evidence).jobs, value.jobs);
});

for (const conclusion of ['skipped', 'neutral', 'failure', 'cancelled', 'timed_out', null]) {
  test(`required ${conclusion} result cannot qualify`, () => {
    const value = fixture(); value.jobs[0].conclusion = conclusion;
    assert.throws(() => validateHorosJobs(value.jobs, value.run), /qualification failed/);
  });
}

for (const [name, mutate] of [
  ['missing lane', value => {value.jobs.pop();}],
  ['duplicate favorable lane', value => {value.jobs[1] = value.jobs[0];}],
  ['wrong platform', value => {value.jobs[0].labels = ['macos-14'];}],
  ['wrong source', value => {value.jobs[0].head_sha = tree;}],
  ['budget overrun', value => {value.jobs[0].completed_at = '2026-10-30T00:05:01Z';}],
  ['wrong attempt', value => {value.run.run_attempt = 2;}],
  ['wrong workflow', value => {value.run.path = '.github/workflows/diagnostic.yml';}],
  ['nonlanded qualification', value => {value.run.event = 'workflow_dispatch';}],
  ['expired artifact', value => {value.artifacts[0].expired = true;}],
  ['wrong artifact run', value => {value.artifacts[0].workflow_run.id++;}],
  ['corrupt artifact', value => {value.replies.set('repos/tkersey/horos/actions/artifacts/80/zip', Buffer.from('corrupt'));}],
  ['duplicate original runs', value => {value.replies.get(`repos/tkersey/horos/actions/workflows/zig.yml/runs?head_sha=${commit}&event=push&per_page=100&page=1`).workflow_runs.push({...value.run, id: 18});}],
]) {
  test(`qualification rejects ${name}`, async () => {
    const value = fixture(); mutate(value);
    await assert.rejects(admitHorosQualification({runId: 17, commit, tree}, value.command));
  });
}
