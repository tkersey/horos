import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {proposalBranch, proposalMessage, proposalCommitOid, proposalDescription, proposeHoros, promoteHoros, pauseHorosProposals, recoverProposalMetadata} from './proposal.mjs';

import {retireHorosProposal, storedHorosCandidate} from './release-observation.mjs';
import {admitOwnerResume} from './proposal-authority.mjs';

import {runHorosAutomation} from './automation-runner.mjs';
import {jobPermissions} from './app-token.mjs';

const actor = {id: 42, login: 'horos-release[bot]'};
const person = {name: actor.login, email: `${actor.id}+${actor.login}@users.noreply.github.com`, date: '2026-10-30T00:00:00Z'};

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
    autoMerge: null, events: [], issueEvents: [], comments: [], owner: {id: 1, login: 'tkersey', type: 'User'}, admissions: [], retirements: [], resumes: [],
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
        if (path === '') return reply({id: 1176152390, node_id: 'REPO', full_name: 'tkersey/horos', default_branch: 'main', owner: state.owner, allow_auto_merge: state.autoMergeAllowed, allow_rebase_merge: state.rebaseAllowed});
        if (path === '/actions/variables/REPOSITORY_AUTOMATION') return state.mode === null ? {status: 404} : reply({name: 'REPOSITORY_AUTOMATION', value: state.mode});
        if (path.startsWith('/git/ref/heads/')) {
          const branch = path.slice('/git/ref/heads/'.length), sha = branch === 'main' ? state.main : state.branch;
          return sha === null ? {status: 404} : reply({ref: `refs/heads/${branch}`, object: {type: 'commit', sha}});
        }
        if (/^\/issues\/[0-9]+\/events\?/.test(path)) return reply(state.issueEvents);
        if (/^\/issues\/[0-9]+\/comments\?/.test(path)) return reply(state.comments);
        if (path.startsWith('/issues/comments/')) return reply(state.comments.find(value => value.id === Number(path.split('/').at(-1))));
        if (path.startsWith('/contents/')) {
          const [file, ref] = path.slice('/contents/'.length).split('?ref=');
          let tree = objects.get(`/git/commits/${ref}`).tree.sha;
          const parts = file.split('/');
          for (const name of parts.slice(0, -1)) tree = objects.get(`/git/trees/${tree}`).tree.find(value => value.path === name).sha;
          const sha = objects.get(`/git/trees/${tree}`).tree.find(value => value.path === parts.at(-1)).sha;
          return reply({...objects.get(`/git/blobs/${sha}`), type: 'file'});
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
        if (path === '/git/trees') assert.deepEqual(request.body, {base_tree: baseTree,
          tree: [{path: 'build.zig.zon', mode: '100644', type: 'blob', sha: value.tree.find(entry => entry.path === 'build.zig.zon').sha}]});
        if (path === '/git/commits') assert.deepEqual(request.body.parents, value.parents.map(parent => parent.sha));
        objects.set(`${path}/${value.sha}`, structuredClone(value));
        response = {status: 201, body: structuredClone(value)};
      } else if (path === '/pulls') {
        assert.equal(request.body.head, proposalBranch); assert.equal(request.body.base, 'main');
        assert.equal(state.pulls.filter(value => value.state === 'open').length, 0);
        const number = state.pulls.length + 1;
        const value = {id: number, number, node_id: `PR${number}`, state: 'open', merged: false, draft: false,
          head: {ref: proposalBranch, sha: state.branch, repo: {id: 1176152390}},
          base: {ref: 'main', sha: state.main, repo: {id: 1176152390}}, user: {...actor},
          title: request.body.title, body: request.body.body, labels: [], assignees: []};
        state.pulls.push(value); response = {status: 201, body: structuredClone(value)};
      } else if (method === 'PATCH' && /^\/pulls\/[0-9]+$/.test(path)) {
        const value = state.pulls.find(value => value.number === Number(path.split('/')[2]));
        assert.deepEqual(Object.keys(request.body).sort(), ['body', 'title']);
        Object.assign(value, request.body); response = reply(value);
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
        assert.match(query, /CLOSED_EVENT,REOPENED_EVENT,LABELED_EVENT,UNLABELED_EVENT/);
        assert.match(query, /on LabeledEvent\{id createdAt label\{name\}/);
        assert.match(query, /on UnlabeledEvent\{id createdAt label\{name\}/);
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
        for (const pull of state.pulls.filter(value => value.state === 'open')) pull.head.sha = state.branch;
        if (updates[0].beforeOid !== '0'.repeat(40) && state.pulls.some(value => value.state === 'open'))
          state.events.push({id: `PUSH-${state.events.length}`, __typename: 'HeadRefForcePushedEvent',
            beforeCommit: {oid: updates[0].beforeOid}, afterCommit: {oid: updates[0].afterOid},
            actor: {login: actor.login}, createdAt: '2026-10-30T01:00:00Z'});
      } else if (operation === 'PromoteProposal') {
        const pull = state.pulls.find(value => value.node_id === variables.input.pullRequestId);
        assert.equal(variables.input.expectedHeadOid, pull.head.sha);
        assert.equal(variables.input.mergeMethod, 'REBASE');
        assert.match(query, /\$input:MergePullRequestInput!/);
        assert.match(query, /mergePullRequest\(input:/);
        pull.merged = true; pull.state = 'closed'; pull.merged_at = '2026-10-30T02:00:00Z';
        pull.merge_commit_sha = pull.head.sha; state.main = pull.head.sha;
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
  const successor = (version = '1.0.2', advance = false) => {
    const manifestBytes = Buffer.from(`.{ .name = .horos, .version = "${version}" }\n`);
    const selectedBlob = git(['hash-object', '-w', '--stdin'], manifestBytes), selectedTree = tree(selectedBlob);
    const selectedBase = advance ? git(['-c', 'commit.gpgsign=false', 'commit-tree', baseTree, '-p', base], 'Advanced base\n') : base;
    if (advance) {
      objects.set(`/git/commits/${selectedBase}`, commit(selectedBase, baseTree, 'Advanced base\n', [base]));
      state.main = selectedBase;
      for (const pull of state.pulls.filter(value => value.state === 'open')) pull.base.sha = selectedBase;
    }
    const value = {base: selectedBase, tree: selectedTree, manifestBytes, version, author: {...person}, committer: {...person}};
    value.message = proposalMessage(value); value.head = proposalCommitOid(value);
    expectedObjects.set('/git/blobs', blob(selectedBlob, manifestBytes));
    expectedObjects.set('/git/trees', {sha: selectedTree, truncated: false, tree: entries(selectedBlob)});
    expectedObjects.set('/git/commits', commit(value.head, selectedTree, value.message, [selectedBase]));
    return {candidate: value,
      admitCandidate: async ({candidate: observed, baseManifest: previous}) => {
        assert.equal(observed.head, value.head); assert.deepEqual(previous, baseManifest);
      },
      admitRetirement: async value => {state.retirements.push(value.knownHead); return {epochClosed: true, previousCandidate: candidate};},
    };
  };
  return {state, candidate, options, baseTree, newBlob, baseBlob, objects, expectedObjects, successor,
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

test('CLEAN promotion uses normal protected expected-head rebase merge', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.calls = [];
  assert.equal((await f.promote()).status, 'landed—qualification pending');
  assert.deepEqual(f.writes().map(value => value.path), ['PromoteProposal']);
  assert.equal(f.writes()[0].variables.input.expectedHeadOid, f.candidate.head);
  assert.equal(f.writes()[0].variables.input.mergeMethod, 'REBASE');
  f.state.calls = [];
  assert.equal((await f.promote()).status, 'landed—qualification pending'); assert.equal(f.writes().length, 0);
});

test('propose control cannot request automatic merge', async t => {
  const f = fixture(t); await f.propose(); f.state.calls = [];
  assert.equal((await f.promote()).status, 'disabled'); assert.equal(f.writes().length, 0);
});

test('turning promotion off cancels only automation-owned pending requests', async t => {
  const f = fixture(t); await f.propose(); f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}};
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

test('uncertain successful protected merge is observed and not repeated', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.calls = [];
  f.state.failAfter = value => value.path === 'PromoteProposal';
  assert.equal((await f.promote()).status, 'landed—qualification pending');
  assert.equal(f.writes().length, 1);
});

test('effective rulesets can be admitted by owner without inventing replacement protection policy', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.protection = null;
  f.state.rules = [{type: 'required_status_checks', parameters: {strict_required_status_checks_policy: true}}];
  assert.equal((await f.promote()).status, 'landed—qualification pending');
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

test('closed original epoch admits successor on same ordinary PR with exact branch lease', async t => {
  for (const advance of [false, true]) {
    const f = fixture(t); await f.propose(); const next = f.successor('1.0.2', advance);
    f.state.pulls[0].labels = [{name: 'retained-label'}]; f.state.pulls[0].assignees.push({login: 'human'});
    f.state.calls = [];
    const result = await f.propose(next);
    assert.equal(result.status, 'proposal open'); assert.equal(result.number, 1);
    assert.equal(result.previousHead, f.candidate.head); assert.equal(result.head, next.candidate.head);
    assert.equal(f.state.pulls.length, 1); assert.equal(f.state.branch, next.candidate.head);
    assert.equal(f.state.pulls[0].body, proposalDescription(next.candidate).body);
    assert.deepEqual(f.state.pulls[0].labels, [{name: 'retained-label'}]);
    assert.deepEqual(f.state.pulls[0].assignees, [{login: 'tkersey'}, {login: 'human'}]);
    const update = f.writes().find(value => value.path === 'UpdateProposal').variables.input.refUpdates[0];
    assert.equal(update.beforeOid, f.candidate.head); assert.equal(update.afterOid, next.candidate.head); assert.equal(update.force, true);
    assert.deepEqual(f.writes().filter(value => value.path.startsWith('/pulls')).map(value => [value.method, value.path]), [['PATCH', '/pulls/1']]);
    f.state.calls = []; await f.propose(next); assert.equal(f.writes().length, 0);
  }
});

for (const [name, mutate] of [
  ['missing original owner closure', (f, next) => {next.admitRetirement = undefined;}],
  ['still-open original epoch', (f, next) => {next.admitRetirement = async () => ({epochClosed: false, previousCandidate: f.candidate});}],
  ['missing authenticated old candidate', (f, next) => {next.admitRetirement = async () => ({epochClosed: true});}],
  ['human body edit', f => {f.state.pulls[0].body += '\nHuman note.\n';}],
  ['human title edit', f => {f.state.pulls[0].title = 'Owner edited title';}],
  ['human draft hold', f => {f.state.pulls[0].draft = true;}],
  ['manual hold label', f => {f.state.pulls[0].labels.push({name: 'automation-hold'});}],
  ['human branch edit', f => {f.state.branch = 'd'.repeat(40); f.state.pulls[0].head.sha = f.state.branch;}],
  ['pending auto merge', f => {f.state.autoMerge = {enabledBy: {login: actor.login}, mergeMethod: 'REBASE'};}],
  ['manual auto merge cancellation', f => {f.state.events.push({id: 'event-1', __typename: 'AutoMergeDisabledEvent', actor: {login: 'human'}});}],
]) test(`successor holds ${name} without branch or metadata writes`, async t => {
  const f = fixture(t); await f.propose(); const next = f.successor(); mutate(f, next); f.state.calls = [];
  assert.equal((await f.propose(next)).status, 'held'); assert.equal(f.writes().length, 0);
});

test('retirement proof corruption cannot replace original Git source', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor(); f.state.calls = [];
  next.admitRetirement = async () => ({epochClosed: true, previousCandidate: {...f.candidate, manifestBytes: Buffer.from('forged')}});
  await assert.rejects(f.propose(next)); assert.equal(f.writes().length, 0);
});

test('lost successor branch response is observed and completes metadata on the same PR', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor(); f.state.calls = [];
  f.state.failAfter = value => value.path === 'UpdateProposal';
  await f.propose(next); assert.equal(f.state.pulls.length, 1); assert.equal(f.state.branch, next.candidate.head);
  assert.equal(f.writes().filter(value => value.path === 'UpdateProposal').length, 1);
  assert.equal(f.state.pulls[0].body, proposalDescription(next.candidate).body);
});

test('interrupted successor metadata resumes only the same frozen candidate', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  f.state.failBefore = value => value.method === 'PATCH' && value.path === '/pulls/1';
  await assert.rejects(f.propose(next), /not confirmed/);
  assert.equal(f.state.branch, next.candidate.head); assert.equal(f.state.pulls[0].body, proposalDescription(f.candidate).body);
  f.state.failBefore = null; f.state.calls = [];
  const third = f.successor('1.0.3');
  assert.equal((await f.propose(third)).status, 'held'); assert.equal(f.writes().length, 0);
  await f.propose(next);
  assert.deepEqual(f.writes().map(value => [value.method, value.path]), [['PATCH', '/pulls/1']]);
  assert.equal(f.state.pulls[0].body, proposalDescription(next.candidate).body);
});

test('lost metadata response converges without another branch or PR write', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  f.state.failAfter = value => value.method === 'PATCH' && value.path === '/pulls/1';
  await f.propose(next); f.state.calls = []; await f.propose(next);
  assert.equal(f.writes().length, 0); assert.equal(f.state.pulls.length, 1);
});

test('successor CAS preserves concurrent human branch edits', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  f.state.onGraphql = (operation, _variables, state) => {if (operation === 'UpdateProposal') state.branch = 'd'.repeat(40);};
  await assert.rejects(f.propose(next), /not confirmed/);
  assert.equal(f.state.branch, 'd'.repeat(40)); assert.equal(f.state.pulls[0].body, proposalDescription(f.candidate).body);
});

test('new hold during successor admission stops before branch replacement', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  next.admitCandidate = async () => {f.state.pulls[0].labels.push({name: 'automation-hold'});}; f.state.calls = [];
  await assert.rejects(f.propose(next), /labels changed/);
  assert.equal(f.writes().some(value => value.path === 'UpdateProposal' || value.method === 'PATCH'), false);
});

test('trusted cancellation resume preserves original failure and closure history', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  const event = {id: 'cancel-1', __typename: 'AutoMergeDisabledEvent', actor: {login: actor.login}};
  f.state.events.push(event); let resumed = 0;
  next.admitResume = async ({events}) => {assert.deepEqual(events.filter(value => value.__typename === 'AutoMergeDisabledEvent'), [event]); resumed++;};
  await f.propose(next); assert.equal(resumed, 3); assert.deepEqual(f.state.events.filter(value => value.__typename === 'AutoMergeDisabledEvent'), [event]);
});

test('successor restores required assignee after admitted metadata replacement', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor(); f.state.pulls[0].assignees = [];
  await f.propose(next); assert.deepEqual(f.state.pulls[0].assignees, [{login: 'tkersey'}]);
});

for (const mode of ['off', 'propose']) test(`pause independently cancels owned auto-merge in ${mode} mode without decoding candidate`, async t => {
  const f = fixture(t); await proposeHoros(f.options);
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}};
  f.state.mode = mode; f.state.pulls[0].head.sha = 'e'.repeat(40);
  f.state.calls.length = 0;
  const result = await pauseHorosProposals({actor, client: f.options.client});
  assert.equal(result.length, 1); assert.equal(f.state.autoMerge, null);
  assert.equal(f.state.calls.filter(value => value.method === 'MUTATION').length, 1);
  assert.ok(!f.state.calls.some(value => value.path.startsWith('/git/commits/')));
});

test('pause with no existing auto-merge converges without writes', async t => {
  const f = fixture(t); await proposeHoros(f.options); f.state.calls.length = 0; f.state.mode = 'off';
  assert.deepEqual(await pauseHorosProposals({actor, client: f.options.client}), []);
  assert.ok(!f.state.calls.some(value => ['POST', 'PATCH', 'MUTATION'].includes(value.method)));
});

test('pause refuses an auto-merge enabled by an unknown actor', async t => {
  const f = fixture(t); await proposeHoros(f.options); f.state.mode = 'off';
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: 'human'}}; f.state.calls.length = 0;
  await assert.rejects(pauseHorosProposals({actor, client: f.options.client}), /unknown auto-merge owner/);
  assert.ok(!f.state.calls.some(value => value.method === 'MUTATION'));
});

test('pause preserves an uncertain successful cancellation through readback', async t => {
  const f = fixture(t); await proposeHoros(f.options); f.state.mode = 'off';
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}};
  f.state.failAfter = value => value.path === 'PauseProposal';
  assert.equal((await pauseHorosProposals({actor, client: f.options.client})).length, 1);
  assert.equal(f.state.autoMerge, null);
});

for (const hold of ['label', 'draft']) test(`owner ${hold} cancels previously enabled owned auto-merge even in promote mode`, async t => {
  const f = fixture(t); await proposeHoros(f.options); f.state.mode = 'promote';
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}};
  assert.deepEqual(await pauseHorosProposals({actor, client: f.options.client}), []);
  assert.notEqual(f.state.autoMerge, null);
  if (hold === 'label') f.state.pulls[0].labels.push({name: 'automation-hold'});
  else f.state.pulls[0].draft = true;
  assert.equal((await pauseHorosProposals({actor, client: f.options.client})).length, 1);
  assert.equal(f.state.autoMerge, null);
});

test('a hold removed during observation cannot cancel an active promote request', async t => {
  const f = fixture(t); await proposeHoros(f.options); f.state.mode = 'promote';
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}};
  f.state.pulls[0].labels.push({name: 'automation-hold'});
  let histories = 0;
  f.state.onGraphql = operation => {if (operation === 'ProposalHistory' && ++histories === 1) f.state.pulls[0].labels = [];};
  f.state.calls.length = 0;
  assert.deepEqual(await pauseHorosProposals({actor, client: f.options.client}), []);
  assert.notEqual(f.state.autoMerge, null); assert.ok(!f.state.calls.some(value => value.method === 'MUTATION'));
});

for (const changed of ['mode', 'hold']) test(`pause rechecks ${changed} after its final auto-merge observation`, async t => {
  const f = fixture(t); await proposeHoros(f.options); f.state.mode = changed === 'mode' ? 'off' : 'promote';
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}};
  if (changed === 'hold') f.state.pulls[0].labels.push({name: 'automation-hold'});
  let histories = 0;
  f.state.onGraphql = operation => {
    if (operation !== 'ProposalHistory' || ++histories !== 2) return;
    f.state.mode = 'promote'; f.state.pulls[0].labels = [];
  };
  f.state.calls.length = 0;
  assert.deepEqual(await pauseHorosProposals({actor, client: f.options.client}), []);
  assert.notEqual(f.state.autoMerge, null); assert.ok(!f.state.calls.some(value => value.method === 'MUTATION'));
});

function originalLifecycle(f, candidates) {
  const native = {read: bytes => /\.version = "([0-9.]+)"/.exec(bytes.toString())[1],
    prepare: (bytes, version) => Buffer.from(bytes.toString().replace(/\.version = "[0-9.]+"/, `.version = "${version}"`))};
  const readCandidate = head => storedHorosCandidate(head, {client: f.options.client, actor, native});
  const state = {closed: true, status: 'blocked', subjects: []};
  const readResult = async subject => {
    state.subjects.push(subject.head);
    const candidate = candidates.get(subject.head);
    assert.ok(candidate); assert.equal(subject.base, candidate.base); assert.equal(subject.tree, candidate.tree);
    if (state.status === 'pending') return {status: 'pending'};
    const envelope = {schema: 'repository-review-result/v1', context: {repository: 'tkersey/horos',
      base: candidate.base, head: candidate.head, tree: candidate.tree, pullNumber: 1},
      status: 'blocked', reason: 'Original owner disposition.', epochClosed: state.closed, turn: 1,
      previousSha256: null, stateSha256: null, retainedEvidence: null};
    return {status: 'blocked', bytes: Buffer.from(JSON.stringify(envelope)), run: {id: 21}, artifact: {id: 22}};
  };
  const admitRetirement = retireHorosProposal({client: f.options.client, actor, readCandidate, readResult});
  const admitResume = value => admitOwnerResume(value, f.options.client);
  return {state, readCandidate, admitRetirement, admitResume,
    recover: () => recoverProposalMetadata({pull: structuredClone(f.state.pulls[0]), actor,
      client: f.options.client, readCandidate, admitRetirement, admitResume})};
}

for (const advanceAgain of [false, true]) test(`real retirement recovers interrupted metadata with later base advance ${advanceAgain}`, async t => {
  const f = fixture(t); await f.propose(); const next = f.successor('1.0.2');
  const lifecycle = originalLifecycle(f, new Map([[f.candidate.head, f.candidate], [next.candidate.head, next.candidate]]));
  f.state.failBefore = value => value.method === 'PATCH' && value.path === '/pulls/1';
  await assert.rejects(f.propose({...next, admitRetirement: lifecycle.admitRetirement}), /not confirmed/);
  assert.equal(f.state.branch, next.candidate.head);
  assert.equal(f.state.pulls[0].body, proposalDescription(f.candidate).body);
  if (advanceAgain) f.successor('1.0.3', true);
  f.state.failBefore = null; f.state.calls = [];
  const recovered = await lifecycle.recover();
  assert.equal(recovered.result.status, 'proposal open'); assert.equal(recovered.candidate.head, next.candidate.head);
  assert.deepEqual(f.writes().map(value => [value.method, value.path]), [['PATCH', '/pulls/1']]);
  assert.equal(f.state.pulls[0].body, proposalDescription(next.candidate).body);
  assert.deepEqual(lifecycle.state.subjects, [f.candidate.head, f.candidate.head]);
  f.state.calls = [];
  assert.equal(await lifecycle.recover(), null); assert.equal(f.writes().length, 0);
});

for (const [name, change] of [
  ['open owner epoch', (f, lifecycle) => {lifecycle.state.closed = false;}],
  ['missing owner disposition', (f, lifecycle) => {lifecycle.state.status = 'pending';}],
  ['unknown human head', f => {f.state.branch = 'f'.repeat(40); f.state.pulls[0].head.sha = f.state.branch;}],
  ['edited predecessor body', f => {f.state.pulls[0].body += 'Human note.\n';}],
  ['ambiguous predecessor identity', f => {f.state.pulls[0].body += `\nHead: \`${f.candidate.head}\`\n`;}],
]) test(`real metadata recovery holds ${name}`, async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  const lifecycle = originalLifecycle(f, new Map([[f.candidate.head, f.candidate], [next.candidate.head, next.candidate]]));
  f.state.failBefore = value => value.method === 'PATCH';
  await assert.rejects(f.propose({...next, admitRetirement: lifecycle.admitRetirement}));
  f.state.failBefore = null; f.state.calls = []; change(f, lifecycle);
  if (name === 'edited predecessor body') assert.equal((await lifecycle.recover()).result.status, 'held');
  else await assert.rejects(lifecycle.recover());
  assert.equal(f.writes().length, 0);
});

for (const kind of ['closure', 'label']) for (const operation of ['propose', 'promote'])
  test(`real owner resume is required for prior ${kind} before any auto-merge in ${operation}`, async t => {
    const f = fixture(t); await f.propose(); f.state.mode = 'promote';
    f.state.events = kind === 'closure' ? [
      {id: 'C', __typename: 'ClosedEvent', createdAt: '2026-10-30T00:00:00Z'},
      {id: 'R', __typename: 'ReopenedEvent', createdAt: '2026-10-30T00:10:00Z'},
    ] : [
      {id: 'L', __typename: 'LabeledEvent', label: {name: 'automation-hold'}, createdAt: '2026-10-30T00:00:00Z'},
      {id: 'U', __typename: 'UnlabeledEvent', label: {name: 'automation-hold'}, createdAt: '2026-10-30T00:10:00Z'},
    ];
    const admitResume = value => admitOwnerResume(value, f.options.client);
    f.state.calls = [];
    await assert.rejects(f[operation]({admitResume}), /fresh unedited/); assert.equal(f.writes().length, 0);
    f.state.comments.push({id: 9, user: f.state.owner, body: `/repository-automation resume ${f.candidate.head}`,
      created_at: '2026-10-30T00:05:00Z', updated_at: '2026-10-30T00:05:00Z'});
    await assert.rejects(f[operation]({admitResume}), /fresh unedited/); assert.equal(f.writes().length, 0);
    Object.assign(f.state.comments[0], {created_at: '2026-10-30T00:20:00Z', updated_at: '2026-10-30T00:20:00Z'});
    assert.equal((await f[operation]({admitResume})).status,
      operation === 'propose' ? 'proposal open' : 'landed—qualification pending');
  });

test('pending automation-owned auto-merge is preserved without another merge mutation', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote';
  f.state.autoMerge = {mergeMethod: 'REBASE', enabledBy: {login: actor.login}}; f.state.calls = [];
  assert.equal((await f.promote()).status, 'promotion pending'); assert.equal(f.writes().length, 0);
});

test('protected merge refuses a head changed at the mutation boundary', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote';
  f.state.onGraphql = (operation, variables) => {
    if (operation === 'PromoteProposal') {
      assert.equal(variables.input.expectedHeadOid, f.candidate.head);
      f.state.pulls[0].head.sha = 'e'.repeat(40);
    }
  };
  await assert.rejects(f.promote(), /not confirmed/); assert.equal(f.state.pulls[0].merged, false);
});

test('rejected protected merge remains unconfirmed and cannot become a success', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote';
  f.state.failBefore = value => value.path === 'PromoteProposal';
  await assert.rejects(f.promote(), /not confirmed/); assert.equal(f.state.pulls[0].merged, false);
});


test('writer restart finishes authenticated interrupted metadata before current-source planning', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  const lifecycle = originalLifecycle(f, new Map([[f.candidate.head, f.candidate], [next.candidate.head, next.candidate]]));
  f.state.failBefore = value => value.method === 'PATCH';
  await assert.rejects(f.propose({...next, admitRetirement: lifecycle.admitRetirement}));
  f.state.failBefore = null; f.successor('1.0.3', true); f.state.calls = [];
  const identity = {repository: 'tkersey/horos', repositoryId: 1176152390, role: 'writer', appId: 9,
    permissions: jobPermissions.writer, expiresAt: '2099-01-01T00:00:00Z'};
  const result = await runHorosAutomation({controlCommit: f.state.main, identity,
    native: {read: () => '1.0.0', prepare: () => assert.fail('recovery does not regenerate native source'), facts: () => assert.fail('recovery does not plan new native inputs')}}, {
    client: f.options.client, actorReader: async () => actor,
    sourceReader: async () => ({commit: f.state.main, tree: f.baseTree}), pause: async () => [],
    reportReview: async () => ({status: 'reported'}), reportStatus: async () => ({status: 'reported'}),
    operations: () => ({recover: pull => recoverProposalMetadata({pull, actor, client: f.options.client,
      readCandidate: lifecycle.readCandidate, admitRetirement: lifecycle.admitRetirement, admitResume: lifecycle.admitResume}),
      boundary: async () => assert.fail('recovery precedes new publication planning'),
      freeze: async () => assert.fail('recovery precedes new candidate selection'),
    }),
  });
  assert.equal(result.status, 'proposal open', result.reason);
  assert.equal(result.head, next.candidate.head);
  assert.deepEqual(f.writes().map(value => [value.method, value.path]), [['PATCH', '/pulls/1']]);
});

test('reviewed body changed after trusted promotion admission prevents merge', async t => {
  const f = fixture(t); await f.propose(); f.state.mode = 'promote'; f.state.calls = [];
  await assert.rejects(f.promote({admitPromotion: async () => {f.state.pulls[0].body += 'Changed reviewed rationale.\n';}}), /body changed/);
  assert.equal(f.writes().length, 0);
});

test('new historical hold during successor admission stops the branch transition', async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  const admit = next.admitCandidate;
  next.admitCandidate = async input => {
    const result = await admit(input);
    f.state.events.push({id: 'NEW', __typename: 'UnlabeledEvent', label: {name: 'automation-hold'}, createdAt: '2026-10-30T01:00:00Z'});
    return result;
  };
  f.state.calls = [];
  await assert.rejects(f.propose(next), /history changed/);
  assert.ok(!f.writes().some(value => value.path === 'UpdateProposal' || value.method === 'PATCH'));
});


for (const laterHold of [false, true]) test(`interrupted held successor resumes with a current-head command after later hold ${laterHold}`, async t => {
  const f = fixture(t); await f.propose(); const next = f.successor();
  const lifecycle = originalLifecycle(f, new Map([[f.candidate.head, f.candidate], [next.candidate.head, next.candidate]]));
  f.state.events.push({id: 'HOLD', __typename: 'ClosedEvent', createdAt: '2026-10-30T00:00:00Z'});
  f.state.comments.push({id: 9, user: f.state.owner, body: `/repository-automation resume ${f.candidate.head}`,
    created_at: '2026-10-30T00:20:00Z', updated_at: '2026-10-30T00:20:00Z'});
  f.state.failBefore = value => value.method === 'PATCH';
  await assert.rejects(f.propose({...next, admitRetirement: lifecycle.admitRetirement, admitResume: lifecycle.admitResume}), /not confirmed/);
  assert.equal(f.state.branch, next.candidate.head);
  f.state.failBefore = null; f.state.calls = [];
  if (laterHold) {
    f.state.events.push({id: 'LATER', __typename: 'UnlabeledEvent', label: {name: 'automation-hold'}, createdAt: '2026-10-30T01:10:00Z'});
    await assert.rejects(lifecycle.recover(), /fresh unedited/); assert.equal(f.writes().length, 0);
    f.state.comments.push({id: 10, user: f.state.owner, body: `/repository-automation resume ${next.candidate.head}`,
      created_at: '2026-10-30T01:20:00Z', updated_at: '2026-10-30T01:20:00Z'});
  }
  assert.equal((await lifecycle.recover()).result.status, 'proposal open');
  assert.deepEqual(f.writes().map(value => [value.method, value.path]), [['PATCH', '/pulls/1']]);
});


for (const change of ['missing', 'ambiguous', 'wrong actor'])
  test(`predecessor resume cannot rely on ${change} branch transition evidence`, async t => {
    const f = fixture(t); await f.propose(); const next = f.successor();
    const lifecycle = originalLifecycle(f, new Map([[f.candidate.head, f.candidate], [next.candidate.head, next.candidate]]));
    f.state.events.push({id: 'HOLD', __typename: 'ClosedEvent', createdAt: '2026-10-30T00:00:00Z'});
    f.state.comments.push({id: 9, user: f.state.owner, body: `/repository-automation resume ${f.candidate.head}`,
      created_at: '2026-10-30T00:20:00Z', updated_at: '2026-10-30T00:20:00Z'});
    f.state.failBefore = value => value.method === 'PATCH';
    await assert.rejects(f.propose({...next, admitRetirement: lifecycle.admitRetirement, admitResume: lifecycle.admitResume}));
    f.state.failBefore = null; f.state.calls = [];
    const transition = f.state.events.find(event => event.__typename === 'HeadRefForcePushedEvent');
    assert.ok(transition);
    if (change === 'missing') f.state.events = f.state.events.filter(event => event !== transition);
    else if (change === 'ambiguous') f.state.events.push({...structuredClone(transition), id: 'ANOTHER'});
    else transition.actor.login = 'unknown-human';
    await assert.rejects(lifecycle.recover(), /fresh unedited/); assert.equal(f.writes().length, 0);
  });
