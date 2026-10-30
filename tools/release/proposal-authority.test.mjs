import assert from 'node:assert/strict';
import test from 'node:test';
import {admitOwnerResume, automationStatusBody, reportAutomationStatus} from './proposal-authority.mjs';

const head = 'a'.repeat(40), actor = {id: 40, login: 'horos-release[bot]'}, appId = 41;
function fixture() {
  const owner = {id: 1, login: 'tkersey', type: 'User'};
  const pull = {number: 42, state: 'open', user: actor, labels: [],
    head: {sha: head, repo: {id: 1176152390}}, base: {ref: 'main', repo: {id: 1176152390}}};
  const resume = {id: 30, user: owner, body: `/repository-automation resume ${head}`,
    created_at: '2026-10-30T01:00:00Z', updated_at: '2026-10-30T01:00:00Z'};
  const events = [{id: 'event', __typename: 'AutoMergeDisabledEvent', createdAt: '2026-10-30T00:00:00Z'}];
  const state = {mode: 'propose', pull, owner, comments: [resume], issueEvents: [], writes: [], onRead: null,
    loseResponse: false, failWrite: false};
  const client = {async request({path, method = 'GET', body}) {
    if (method === 'GET') {
      state.onRead?.(path);
      const values = new Map([
        ['', {full_name: 'tkersey/horos', id: 1176152390, owner: state.owner}],
        ['/actions/variables/REPOSITORY_AUTOMATION', {name: 'REPOSITORY_AUTOMATION', value: state.mode}],
        ['/pulls/42', state.pull], ['/issues/42/events?per_page=100&page=1', state.issueEvents],
        ['/issues/42/comments?per_page=100&page=1', state.comments],
        ...state.comments.map(value => [`/issues/comments/${value.id}`, value]),
      ]);
      assert.ok(values.has(path), path); return {status: 200, body: structuredClone(values.get(path))};
    }
    state.writes.push({path, method, body});
    if (state.failWrite) throw new Error('write failed');
    if (method === 'POST') {
      assert.equal(path, '/issues/42/comments');
      state.comments.push({id: 50, user: {...actor}, performed_via_github_app: {id: appId}, body: body.body});
    } else {
      assert.equal(method, 'PATCH'); assert.equal(path, '/issues/comments/50');
      state.comments.find(value => value.id === 50).body = body.body;
    }
    if (state.loseResponse) throw new Error('response lost');
    return {status: method === 'POST' ? 201 : 200};
  }};
  const resumeOwner = () => admitOwnerResume({pull: structuredClone(pull), events}, client);
  const status = {status: 'qualification pending', version: '1.0.1'};
  const report = () => reportAutomationStatus({number: 42, actor, appId, state: status}, client);
  return {state, resume, events, resumeOwner, report, status};
}

test('resume requires an original exact owner comment later than the complete hold timeline', async () => {
  const f = fixture(); const result = await f.resumeOwner();
  assert.equal(result.commentId, 30); assert.equal(result.ownerId, 1); assert.equal(result.head, head);
  assert.equal(f.state.writes.length, 0);
});

for (const [name, mutate] of [
  ['wrong owner', f => {f.resume.user = {...f.resume.user, id: 2};}],
  ['bot owner command', f => {f.resume.user = {...f.resume.user, type: 'Bot'};}],
  ['edited command', f => {f.resume.updated_at = '2026-10-30T02:00:00Z';}],
  ['old command', f => {f.resume.created_at = f.resume.updated_at = '2026-10-29T01:00:00Z';}],
  ['different head', f => {f.resume.body = `/repository-automation resume ${'b'.repeat(40)}`;}],
  ['extra command text', f => {f.resume.body += '\nplease';}],
  ['no original hold', f => {f.events.length = 0;}],
  ['label still held', f => {f.state.pull.labels.push({name: 'automation-hold'});}],
  ['still closed', f => {f.state.pull.state = 'closed';}],
  ['later label hold', f => {f.state.issueEvents.push({id: 51, event: 'labeled', label: {name: 'automation-hold'}, created_at: '2026-10-30T02:00:00Z'});}],
  ['later manual closure', f => {f.events.push({id: 'closed', __typename: 'ClosedEvent', createdAt: '2026-10-30T02:00:00Z'});}],
  ['owner account changed', f => {f.state.owner = {...f.state.owner, id: 9};}],
]) test(`resume refuses ${name}`, async () => {
  const f = fixture(); mutate(f); await assert.rejects(f.resumeOwner()); assert.equal(f.state.writes.length, 0);
});

test('resume refuses an authority comment edited during observation', async () => {
  const f = fixture();
  f.state.onRead = path => {if (path === '/issues/comments/30') f.resume.updated_at = '2026-10-30T02:00:00Z';};
  await assert.rejects(f.resumeOwner(), /changed during admission/);
});

test('one owned status comment converges, then updates without duplicating', async () => {
  const f = fixture(); assert.equal((await f.report()).status, 'reported');
  assert.equal((await f.report()).status, 'unchanged'); assert.equal(f.state.writes.length, 1);
  f.status.status = 'review pending'; assert.equal((await f.report()).status, 'reported');
  assert.equal(f.state.writes.at(-1).method, 'PATCH'); assert.equal(f.state.comments.length, 2);
});

test('off mode never writes a status comment', async () => {
  const f = fixture(); f.state.mode = 'off'; assert.equal((await f.report()).status, 'disabled');
  assert.equal(f.state.writes.length, 0);
});

test('status reobserves controls before its write', async () => {
  const f = fixture(); let reads = 0;
  f.state.onRead = path => {if (path.includes('/actions/variables') && ++reads === 2) f.state.mode = 'off';};
  await assert.rejects(f.report(), /paused/); assert.equal(f.state.writes.length, 0);
});

test('status recovers a successful uncertain write by reading the actual comment', async () => {
  const f = fixture(); f.state.loseResponse = true;
  assert.equal((await f.report()).status, 'reported'); assert.equal(f.state.writes.length, 1);
  assert.equal((await f.report()).status, 'unchanged');
});

test('unobserved status write remains failed', async () => {
  const f = fixture(); f.state.failWrite = true; await assert.rejects(f.report(), /write failed/);
  assert.equal(f.state.writes.length, 1);
});

test('status refuses an unknown App comment and duplicate owned comments', async () => {
  const f = fixture(); await f.report();
  const comment = f.state.comments.at(-1); comment.performed_via_github_app.id++;
  await assert.rejects(f.report(), /App authority/);
  comment.performed_via_github_app.id = appId; f.state.comments.push({...comment, id: 51});
  await assert.rejects(f.report(), /multiple/);
});

test('status bounds rendering inputs', () => {
  assert.throws(() => automationStatusBody({status: 'pending', head: 'wrong'}));
  assert.throws(() => automationStatusBody({status: 'pending', version: 'v1.0.0'}));
});
