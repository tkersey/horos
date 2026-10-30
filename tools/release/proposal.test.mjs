import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {proposalBranch, proposalMessage, proposalCommitOid, proposalDescription, proposeHoros, promoteHoros} from './proposal.mjs';

const actor = {id: 42, login: 'horos-release[bot]'};
const person = {name: 'Horos Release', email: 'release@example.test', date: '2026-10-30T00:00:00Z'};

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'horos-proposal-test-'));
  t.after(() => rmSync(directory, {recursive: true, force: true}));
  const environment = {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: person.name, GIT_AUTHOR_EMAIL: person.email, GIT_AUTHOR_DATE: person.date,
    GIT_COMMITTER_NAME: person.name, GIT_COMMITTER_EMAIL: person.email, GIT_COMMITTER_DATE: person.date};
  const git = (args, input) => execFileSync('git', ['-C', directory, ...args], {input, encoding: 'utf8', env: environment}).trimEnd();
  git(['init', '--bare', '--quiet']);
  const baseManifest = Buffer.from('.{ .name = .horos, .version = "1.0.0" }\n');
  const manifestBytes = Buffer.from('.{ .name = .horos, .version = "1.0.1" }\n');
  const baseBlob = git(['hash-object', '-w', '--stdin'], baseManifest);
  const readme = git(['hash-object', '-w', '--stdin'], 'Horos\n');
  const newBlob = git(['hash-object', '-w', '--stdin'], manifestBytes);
  const entries = blob => [{path: 'README.md', mode: '100644', type: 'blob', sha: readme},
    {path: 'build.zig.zon', mode: '100644', type: 'blob', sha: blob}];
  const tree = blob => git(['mktree'], entries(blob).map(value => `${value.mode} ${value.type} ${value.sha}\t${value.path}\n`).join(''));
  const baseTree = tree(baseBlob), newTree = tree(newBlob);
  const base = git(['-c', 'commit.gpgsign=false', 'commit-tree', baseTree], 'Base\n');
  const candidate = {base, tree: newTree, manifestBytes, version: '1.0.1', author: {...person}, committer: {...person}};
  candidate.message = proposalMessage(candidate);
  candidate.head = git(['-c', 'commit.gpgsign=false', 'commit-tree', newTree, '-p', base], candidate.message);
  const blob = (sha, bytes) => ({sha, encoding: 'base64', size: bytes.length, content: bytes.toString('base64')});
  const commit = (sha, selectedTree, message, parents) => ({sha, tree: {sha: selectedTree}, message,
    parents: parents.map(sha => ({sha})), author: {...person}, committer: {...person}});
  const objects = new Map([
    [`/git/commits/${base}`, commit(base, baseTree, 'Base\n', [])],
    [`/git/trees/${baseTree}`, {sha: baseTree, truncated: false, tree: entries(baseBlob)}],
    [`/git/blobs/${baseBlob}`, blob(baseBlob, baseManifest)],
  ]);
  const expectedObjects = new Map([
    ['/git/blobs', blob(newBlob, manifestBytes)],
    ['/git/trees', {sha: newTree, truncated: false, tree: entries(newBlob)}],
    ['/git/commits', commit(candidate.head, newTree, candidate.message, [base])],
  ]);
  const state = {mode: 'propose', main: base, branch: null, pulls: [], objects, calls: [],
    autoMerge: null, events: [], admissions: [], retirements: [], resumes: [],
    protected: true, protection: {required_status_checks: {strict: true, checks: [{context: 'qualification', app_id: 123}]}},
    rules: [], autoMergeAllowed: true, rebaseAllowed: true, onRequest: null, onGraphql: null, failAfter: null, failBefore: null};
  const reply = body => ({status: 200, body: structuredClone(body)});
  const client = {
    async request(request) {
      const method = request.method ?? 'GET', path = request.path;
      state.calls.push({method, path, body: structuredClone(request.body)});
      await state.onRequest?.(request, state);
      if (method !== 'GET' && state.failBefore?.({method, path})) throw new Error('request failed before write');
      if (method === 'GET') {
        if (path === '') return reply({id: 1176152390, node_id: 'REPO', full_name: 'tkersey/horos', default_branch: 'main', allow_auto_merge: state.autoMergeAllowed, allow_rebase_merge: state.rebaseAllowed});
        if (path === '/actions/variables/REPOSITORY_AUTOMATION') return state.mode === null ? {status: 404} : reply({name: 'REPOSITORY_AUTOMATION', value: state.mode});
        if (path.startsWith('/git/ref/heads/')) {
          const branch = path.slice('/git/ref/heads/'.length), sha = branch === 'main' ? state.main : state.branch;
          return sha === null ? {status: 404} : reply({ref: `refs/heads/${branch}`, object: {type: 'commit', sha}});
        }
        if (path.startsWith('/pulls?')) {
          const page = Number(new URL(`https://example.test${path}`).searchParams.get('page'));
          return reply(state.pulls.slice((page - 1) * 100, page * 100));
        }
        if (/^\/pulls\/[0-9]+$/.test(path)) return reply(state.pulls.find(value => value.number === Number(path.split('/').at(-1))));
        if (path === '/branches/main') return reply({protected: state.protected, commit: {sha: state.main}});
        if (path === '/branches/main/protection') return state.protection === null ? {status: 404} : reply(state.protection);
        if (path.startsWith('/rules/branches/main?')) return reply(state.rules);
        return objects.has(path) ? reply(objects.get(path)) : {status: 404};
      }
      let response;
      if (expectedObjects.has(path)) {
        const value = expectedObjects.get(path);
        if (path === '/git/trees') assert.deepEqual(request.body, {base_tree: baseTree, tree: [{path: 'build.zig.zon', mode: '100644', type: 'blob', sha: newBlob}]});
        if (path === '/git/commits') assert.deepEqual(request.body.parents, [base]);
        objects.set(`${path}/${value.sha}`, structuredClone(value));
        response = {status: 201, body: structuredClone(value)};
      } else if (path === '/pulls') {
        assert.equal(request.body.head, proposalBranch); assert.equal(request.body.base, 'main');
        assert.equal(state.pulls.filter(value => value.state === 'open').length, 0);
        const number = state.pulls.length + 1;
        const value = {number, node_id: `PR${number}`, state: 'open', merged: false, draft: false,
          head: {ref: proposalBranch, sha: state.branch, repo: {id: 1176152390}},
          base: {ref: 'main', sha: state.main, repo: {id: 1176152390}}, user: {...actor},
          title: request.body.title, body: request.body.body, labels: [], assignees: []};
        state.pulls.push(value); response = {status: 201, body: structuredClone(value)};
      } else if (/^\/issues\/[0-9]+\/assignees$/.test(path)) {
        assert.deepEqual(request.body, {assignees: ['tkersey']});
        const value = state.pulls.find(value => value.number === Number(path.split('/')[2]));
        value.assignees = [{login: 'tkersey'}]; response = reply(value);
      } else throw new Error(`unexpected write ${method} ${path}`);
      if (state.failAfter?.({method, path})) throw new Error('response lost after write');
      return response;
    },
    async graphql(query, variables) {
      const operation = /^\w+ (\w+)/.exec(query)[1];
      state.calls.push({method: operation === 'ProposalHistory' ? 'QUERY' : 'MUTATION', path: operation, variables: structuredClone(variables)});
      await state.onGraphql?.(operation, variables, state);
      if (operation === 'ProposalHistory') {
        const pull = state.pulls.find(value => value.number === variables.number);
        return {repository: {databaseId: 1176152390, pullRequest: {id: pull.node_id, headRefOid: pull.head.sha,
          baseRefOid: pull.base.sha, state: pull.merged ? 'MERGED' : pull.state.toUpperCase(), autoMergeRequest: structuredClone(state.autoMerge),
          timelineItems: {nodes: structuredClone(state.events), pageInfo: {hasNextPage: false, endCursor: null}}}}};
      }
      if (state.failBefore?.({method: 'MUTATION', path: operation})) throw new Error('mutation failed before write');
      if (operation === 'UpdateProposal') {
        const updates = variables.input.refUpdates;
        assert.equal(updates.length, 1); assert.equal(variables.input.repositoryId, 'REPO');
        assert.equal(updates[0].name, `refs/heads/${proposalBranch}`);
        assert.equal(updates[0].beforeOid, state.branch ?? '0'.repeat(40), 'lease mismatch');
        state.branch = updates[0].afterOid;
      } else if (operation === 'PromoteProposal') {
        const pull = state.pulls.find(value => value.node_id === variables.input.pullRequestId);
        assert.equal(variables.input.expectedHeadOid, pull.head.sha);
        assert.equal(variables.input.mergeMethod, 'REBASE');
        state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}};
      } else if (operation === 'PauseProposal') state.autoMerge = null;
      else throw new Error(`unexpected GraphQL operation ${operation}`);
      if (state.failAfter?.({method: 'MUTATION', path: operation})) throw new Error('mutation response lost');
      return {};
    },
  };
  const options = {candidate, actor, client,
    admitCandidate: async ({candidate: value, baseManifest: previous}) => {
      state.admissions.push('candidate'); assert.deepEqual(previous, baseManifest);
      assert.equal(value.version, '1.0.1'); assert.deepEqual(value.manifestBytes, manifestBytes);
    },
    admitRetirement: async value => { state.retirements.push(value.knownHead); },
    admitPromotion: async value => {
      state.admissions.push('promotion'); assert.equal(value.candidate.head, candidate.head);
      assert.ok(value.protection?.required_status_checks?.strict || value.rules.length > 0);
    },
  };
  return {state, candidate, options, baseTree, newBlob, baseBlob, objects, expectedObjects,
    propose: overrides => proposeHoros({...options, ...overrides}),
    promote: overrides => promoteHoros({...options, number: 1, ...overrides}),
    writes: () => state.calls.filter(value => !['GET', 'QUERY'].includes(value.method)),
  };
}

test('candidate Git commit identity matches independent git commit-tree bytes', t => {
  const f = fixture(t);
  assert.equal(proposalCommitOid(f.candidate), f.candidate.head);
});

test('creates one ordinary assigned proposal with exact content-addressed objects', async t => {
  const f = fixture(t);
  const result = await f.propose();
  assert.equal(result.status, 'proposal open'); assert.equal(result.number, 1);
  assert.equal(f.state.branch, f.candidate.head); assert.equal(f.state.pulls.length, 1);
  assert.deepEqual(f.state.pulls[0].assignees, [{login: 'tkersey'}]);
  assert.equal(f.writes().length, 6);
  const ref = f.writes().find(value => value.path === 'UpdateProposal').variables.input.refUpdates[0];
  assert.equal(ref.beforeOid, '0'.repeat(40)); assert.equal(ref.afterOid, f.candidate.head); assert.equal(ref.force, false);
});

test('identical proposal converges without object branch PR or assignment writes', async t => {
  const f = fixture(t); await f.propose(); f.state.calls = [];
  assert.equal((await f.propose()).status, 'proposal open');
  assert.equal(f.writes().length, 0); assert.equal(f.state.pulls.length, 1);
});

test('off and absent controls are read-only', async t => {
  for (const mode of ['off', null]) {
    const f = fixture(t); f.state.mode = mode;
    assert.equal((await f.propose()).status, 'disabled'); assert.equal(f.writes().length, 0);
  }
});

test('unknown human branch head and stale base are held without overwrite', async t => {
  for (const field of ['branch', 'main']) {
    const f = fixture(t); f.state[field] = 'd'.repeat(40);
    assert.equal((await f.propose()).status, 'held'); assert.equal(f.writes().length, 0);
  }
});

test('open proposal freezes both head and candidate during later observations', async t => {
  const f = fixture(t); await f.propose(); f.state.calls = [];
  f.state.branch = 'd'.repeat(40); f.state.pulls[0].head.sha = f.state.branch;
  assert.equal((await f.propose()).status, 'held'); assert.equal(f.writes().length, 0);
});

test('manual closure hold and auto-merge disable are retained until owner resume', async t => {
  for (const mutate of [
    state => { state.pulls[0].state = 'closed'; },
    state => { state.pulls[0].labels = [{name: 'automation-hold'}]; },
    state => { state.events = [{__typename: 'AutoMergeDisabledEvent', id: 'event-1', actor: {login: 'tkersey'}}]; },
  ]) {
    const f = fixture(t); await f.propose(); mutate(f.state); f.state.calls = [];
    assert.equal((await f.propose()).status, 'held'); assert.equal(f.writes().length, 0);
  }
});

test('retired merged proposal allows exact leased stable-branch reset after owner admission', async t => {
  const f = fixture(t); await f.propose();
  const previous = 'd'.repeat(40);
  f.state.pulls[0].state = 'closed'; f.state.pulls[0].merged = true;
  f.state.pulls[0].head.sha = previous; f.state.branch = previous; f.state.calls = [];
  await f.propose();
  assert.deepEqual(f.state.retirements, [previous]);
  const update = f.writes().find(value => value.path === 'UpdateProposal').variables.input.refUpdates[0];
  assert.equal(update.beforeOid, previous); assert.equal(update.force, true);
  assert.equal(f.state.pulls.length, 2);
});

test('retirement proof is mandatory and cannot overwrite a human post-merge edit', async t => {
  const f = fixture(t); await f.propose();
  const previous = 'd'.repeat(40);
  f.state.pulls[0].state = 'closed'; f.state.pulls[0].merged = true;
  f.state.pulls[0].head.sha = previous; f.state.branch = previous; f.state.calls = [];
  await assert.rejects(f.propose({admitRetirement: undefined}), /retirement/);
  assert.equal(f.writes().length, 0);
  f.state.branch = 'e'.repeat(40);
  assert.equal((await f.propose()).status, 'held'); assert.equal(f.writes().length, 0);
});

test('atomic branch lease detects races and preserves new human work', async t => {
  const f = fixture(t);
  f.state.onGraphql = (operation, _variables, state) => { if (operation === 'UpdateProposal') state.branch = 'd'.repeat(40); };
  await assert.rejects(f.propose(), /not confirmed/);
  assert.equal(f.state.branch, 'd'.repeat(40)); assert.equal(f.state.pulls.length, 0);
});

test('uncertain successful writes are observed with no duplicate object or PR writes', async t => {
  const f = fixture(t); f.state.failAfter = () => true;
  await f.propose();
  assert.equal(f.writes().length, 6); assert.equal(f.state.pulls.length, 1);
});

test('interrupted partial object or PR preparation resumes only missing work', async t => {
  for (const stop of ['/git/trees', '/pulls', '/issues/1/assignees']) {
    const f = fixture(t); f.state.failBefore = value => value.path === stop;
    await assert.rejects(f.propose(), /not confirmed/);
    const before = new Set(f.state.objects.keys());
    f.state.failBefore = null; f.state.calls = [];
    await f.propose();
    assert.equal(f.state.pulls.length, 1);
    for (const write of f.writes().filter(value => value.path.startsWith('/git/'))) {
      assert.ok(!before.has(`${write.path}/${f.expectedObjects.get(write.path).sha}`));
    }
  }
});

test('candidate field corruption and unapproved semantic delta never become branch writes', async t => {
  const f = fixture(t);
  await assert.rejects(f.propose({candidate: {...f.candidate, head: 'd'.repeat(40)}}), /identity/);
  assert.equal(f.writes().length, 0);
  await assert.rejects(f.propose({admitCandidate: async () => { throw new Error('version-only native proof missing'); }}), /native proof/);
  assert.equal(f.writes().length, 0);
  const altered = {...f.candidate, tree: 'd'.repeat(40)}; altered.head = proposalCommitOid(altered);
  await assert.rejects(f.propose({candidate: altered}), /more than the manifest/);
  assert.equal(f.writes().length, 0);
});

test('truncated or corrupt base tree fails independent object authentication', async t => {
  const f = fixture(t);
  const root = f.objects.get(`/git/trees/${f.baseTree}`);
  root.truncated = true;
  await assert.rejects(f.propose(), /truncated/);
  root.truncated = false; root.tree[0].mode = '100755';
  await assert.rejects(f.propose(), /tree identity/);
  assert.equal(f.writes().length, 0);
});

test('controls and base are reobserved before each write', async t => {
  const f = fixture(t);
  f.state.onRequest = (request, state) => {
    if (request.path === '/actions/variables/REPOSITORY_AUTOMATION' && state.objects.has(`/git/blobs/${f.newBlob}`)) state.mode = 'off';
  };
  await assert.rejects(f.propose(), /disabled/);
  assert.equal(f.writes().length, 1); assert.equal(f.state.branch, null);
});

test('promote requires protected gates and requests expected-head rebase auto-merge', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.calls = [];
  assert.equal((await f.promote()).status, 'promotion requested');
  assert.deepEqual(f.writes().map(value => value.path), ['PromoteProposal']);
  assert.equal(f.writes()[0].variables.input.expectedHeadOid, f.candidate.head);
  assert.equal(f.writes()[0].variables.input.mergeMethod, 'REBASE');
  f.state.calls = [];
  assert.equal((await f.promote()).status, 'promotion pending'); assert.equal(f.writes().length, 0);
});

test('propose control cannot request automatic merge', async t => {
  const f = fixture(t); await f.propose(); f.state.calls = [];
  assert.equal((await f.promote()).status, 'disabled'); assert.equal(f.writes().length, 0);
});

test('turning promotion off cancels only automation-owned pending requests', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; await f.promote();
  f.state.mode = 'off'; f.state.calls = [];
  assert.equal((await f.promote()).status, 'held'); assert.equal(f.state.autoMerge, null);
  assert.deepEqual(f.writes().map(value => value.path), ['PauseProposal']);
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: 'human'}}; f.state.calls = [];
  await assert.rejects(f.promote(), /unknown auto-merge owner/); assert.equal(f.writes().length, 0);
});

test('stale base human head and manually disabled auto-merge block promotion', async t => {
  for (const mutate of [state => { state.main = 'd'.repeat(40); }, state => { state.branch = 'd'.repeat(40); },
    state => { state.events.push({__typename: 'AutoMergeDisabledEvent', id: 'event-1'}); }]) {
    const f = fixture(t); await f.propose(); f.state.mode = 'promote'; mutate(f.state); f.state.calls = [];
    assert.equal((await f.promote()).status, 'held'); assert.equal(f.writes().length, 0);
  }
});

test('missing protection and failed trusted gate admission cannot promote', async t => {
  for (const mutate of [state => { state.protected = false; }, state => { state.protection = null; },
    state => { state.autoMergeAllowed = false; }, state => { state.rebaseAllowed = false; }]) {
    const f = fixture(t); await f.propose(); f.state.mode = 'promote'; mutate(f.state); f.state.calls = [];
    await assert.rejects(f.promote()); assert.equal(f.writes().length, 0);
  }
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.calls = [];
  await assert.rejects(f.promote({admitPromotion: async () => { throw new Error('unresolved owner review'); }}), /owner review/);
  assert.equal(f.writes().length, 0);
});

test('human hold introduced during gate admission is reobserved before promotion', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.calls = [];
  await assert.rejects(f.promote({admitPromotion: async () => { f.state.pulls[0].labels.push({name: 'automation-hold'}); }}), /held during/);
  assert.equal(f.writes().length, 0);
});

test('uncertain successful auto-merge request is observed and not repeated', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.calls = [];
  f.state.failAfter = value => value.path === 'PromoteProposal';
  assert.equal((await f.promote()).status, 'promotion requested');
  assert.equal(f.writes().length, 1);
});

test('effective rulesets can be admitted by owner without inventing replacement protection policy', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.protection = null;
  f.state.rules = [{type: 'required_status_checks', parameters: {strict_required_status_checks_policy: true}}];
  assert.equal((await f.promote()).status, 'promotion requested');
});

test('foreign actor and changed PR provenance cannot acquire automation ownership', async t => {
  for (const mutate of [state => { state.pulls[0].user.id = 7; }, state => { state.pulls[0].body = 'human PR'; },
    state => { state.pulls[0].base.ref = 'other'; }]) {
    const f = fixture(t); await f.propose(); mutate(f.state); f.state.calls = [];
    await assert.rejects(f.propose()); assert.equal(f.writes().length, 0);
  }
});

test('candidate attribution includes exact version manifest and frozen subject', t => {
  const f = fixture(t), description = proposalDescription(f.candidate);
  assert.ok(description.body.includes(f.candidate.base) && description.body.includes(f.candidate.head));
  assert.ok(description.body.startsWith(description.marker));
  assert.ok(description.body.includes('build.zig.zon version only'));
});
