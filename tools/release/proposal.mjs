import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseVersion} from './version.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {impactBlock, versionPreparationImpact} from './impact.mjs';

export const proposalBranch = 'automation/dependency-release';
const zero = '0'.repeat(40);
const updateRefs = 'mutation UpdateProposal($input:UpdateRefsInput!){updateRefs(input:$input){clientMutationId}}';
const enableMerge = 'mutation PromoteProposal($input:EnablePullRequestAutoMergeInput!){enablePullRequestAutoMerge(input:$input){pullRequest{id}}}';
const disableMerge = 'mutation PauseProposal($input:DisablePullRequestAutoMergeInput!){disablePullRequestAutoMerge(input:$input){pullRequest{id}}}';
const timelineQuery = 'query ProposalHistory($number:Int!,$cursor:String){repository(owner:"tkersey",name:"horos"){databaseId pullRequest(number:$number){id headRefOid baseRefOid state autoMergeRequest{enabledBy{login} mergeMethod} timelineItems(first:100,after:$cursor,itemTypes:[AUTO_MERGE_DISABLED_EVENT,CLOSED_EVENT,REOPENED_EVENT]){nodes{__typename ... on AutoMergeDisabledEvent{id createdAt reasonCode actor{login}} ... on ClosedEvent{id createdAt actor{login}} ... on ReopenedEvent{id createdAt actor{login}}} pageInfo{hasNextPage endCursor}}}}}';

function oid(value) { assert.match(value, /^[0-9a-f]{40}$/); return value; }
function objectId(type, bytes) { return createHash('sha1').update(`${type} ${bytes.length}\0`).update(bytes).digest('hex'); }
function identifier(value) { assert.ok(Number.isSafeInteger(value) && value > 0); return value; }

export function proposalMessage({base, version, manifestBytes}) {
  oid(base); parseVersion(version); assert.ok(Buffer.isBuffer(manifestBytes));
  return `Prepare Horos version ${version}\n\nrepository-proposal/v1\nbase: ${base}\nmanifest-sha256: ${sha256(manifestBytes)}\n`;
}

function person(value) {
  assert.deepEqual(Object.keys(value).sort(), ['date', 'email', 'name']);
  for (const key of ['name', 'email']) assert.ok(typeof value[key] === 'string' && value[key].length > 0 && value[key].length <= 256 && !/[\x00-\x1f\x7f<>]/.test(value[key]));
  assert.match(value.date, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  assert.equal(new Date(value.date).toISOString(), value.date.replace('Z', '.000Z'));
  return `${value.name} <${value.email}> ${Date.parse(value.date) / 1000} +0000`;
}

export function proposalCommitOid(candidate) {
  oid(candidate.base); oid(candidate.tree);
  assert.equal(candidate.message, proposalMessage(candidate), 'unexpected proposal commit message');
  return objectId('commit', Buffer.from(`tree ${candidate.tree}\nparent ${candidate.base}\nauthor ${person(candidate.author)}\ncommitter ${person(candidate.committer)}\n\n${candidate.message}`));
}

function candidateCopy(value) {
  assert.ok(Buffer.isBuffer(value.manifestBytes) && value.manifestBytes.length > 0 && value.manifestBytes.length <= 1024 * 1024);
  const candidate = {...structuredClone(value), manifestBytes: Buffer.from(value.manifestBytes)};
  oid(candidate.head);
  assert.equal(proposalCommitOid(candidate), candidate.head, 'candidate commit identity mismatch');
  assert.notEqual(candidate.head, candidate.base, 'empty proposal commit');
  return candidate;
}

export function proposalDescription(candidate) {
  const descriptor = {base: candidate.base, head: candidate.head, tree: candidate.tree,
    version: candidate.version, manifestSha256: sha256(candidate.manifestBytes)};
  const marker = `<!-- repository-proposal/v1 ${sha256(encodeRecord(descriptor))} -->`;
  return {marker, body: `${marker}\n\nPrepare Horos ${candidate.version}.\n\nBase: \`${candidate.base}\`\nHead: \`${candidate.head}\`\n\nScope: build.zig.zon version only. Dependencies unchanged.\n\n${impactBlock(versionPreparationImpact)}\n\nAwaiting full qualification and owner review; publication is separately controlled.\n`};
}

async function get(client, path, missing = false) {
  const response = await client.request({path});
  if (missing && response.status === 404) return null;
  assert.equal(response.status, 200, `GitHub observation unavailable: ${path}`);
  return response.body;
}

async function repository(client) {
  const value = await get(client, '');
  assert.equal(value.full_name, 'tkersey/horos'); assert.equal(value.id, 1176152390);
  assert.equal(value.default_branch, 'main');
  assert.ok(typeof value.node_id === 'string' && value.node_id.length > 0);
  return value;
}

async function mode(client) {
  const value = await get(client, '/actions/variables/REPOSITORY_AUTOMATION', true);
  if (value === null) return 'off';
  assert.equal(value.name, 'REPOSITORY_AUTOMATION');
  assert.ok(['off', 'propose', 'promote'].includes(value.value));
  return value.value;
}

async function reference(client, branch, missing = false) {
  const value = await get(client, `/git/ref/heads/${branch}`, missing);
  if (value === null) return null;
  assert.equal(value.ref, `refs/heads/${branch}`); assert.equal(value.object.type, 'commit');
  return oid(value.object.sha);
}

async function allPages(client, path) {
  const values = [];
  for (let page = 1; page <= 100; page++) {
    const part = await get(client, `${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    assert.ok(Array.isArray(part) && part.length <= 100);
    values.push(...part);
    if (part.length < 100) return values;
  }
  throw new Error('proposal observation capacity exceeded');
}

async function pulls(client) {
  const items = await allPages(client, `/pulls?state=all&head=tkersey:${encodeURIComponent(proposalBranch)}`);
  const seen = new Set();
  for (const value of items) {
    identifier(value.number); assert.ok(!seen.has(value.number), 'pull pagination changed'); seen.add(value.number);
    assert.equal(value.head.ref, proposalBranch); assert.equal(value.head.repo?.id, 1176152390);
    assert.equal(value.base.ref, 'main'); assert.equal(value.base.repo?.id, 1176152390);
  }
  assert.ok(items.filter(value => value.state === 'open').length <= 1, 'multiple automation branch proposals');
  return items.sort((a, b) => b.number - a.number);
}

function owned(pull, actor) {
  assert.equal(pull.user?.id, actor.id, 'proposal is not automation-owned');
  assert.equal(pull.user?.login, actor.login, 'proposal actor changed');
  assert.ok(typeof pull.body === 'string' && /^<!-- repository-proposal\/v1 [0-9a-f]{64} -->\n/.test(pull.body), 'missing proposal provenance');
}

async function history(client, pull) {
  const events = [], cursors = new Set();
  let cursor = null;
  for (let page = 0; page < 100; page++) {
    const data = await client.graphql(timelineQuery, {number: pull.number, cursor});
    assert.equal(data.repository?.databaseId, 1176152390);
    const value = data.repository.pullRequest;
    assert.equal(value.id, pull.node_id); assert.equal(value.headRefOid, pull.head.sha);
    assert.equal(value.baseRefOid, pull.base.sha);
    assert.equal(value.state.toLowerCase(), pull.merged === true ? 'merged' : pull.state);
    const connection = value.timelineItems;
    assert.ok(Array.isArray(connection.nodes) && connection.nodes.length <= 100);
    events.push(...connection.nodes);
    if (connection.pageInfo.hasNextPage === false) return {events, autoMerge: value.autoMergeRequest};
    assert.equal(connection.pageInfo.hasNextPage, true);
    cursor = connection.pageInfo.endCursor;
    assert.ok(typeof cursor === 'string' && cursor.length > 0 && !cursors.has(cursor), 'invalid proposal history cursor');
    cursors.add(cursor);
  }
  throw new Error('proposal history capacity exceeded');
}

async function guard(client, candidate, branchBefore, allowed = ['propose', 'promote']) {
  const repo = await repository(client);
  assert.equal(await reference(client, 'main'), candidate.base, 'stale proposal base');
  assert.equal(await reference(client, proposalBranch, true), branchBefore, 'automation branch changed');
  assert.ok(allowed.includes(await mode(client)), 'proposal mutation disabled');
  return repo;
}

async function writeObserved(write, observe) {
  let failure;
  try { await write(); } catch (error) { failure = error; }
  try { return await observe(); }
  catch (error) { throw new Error('proposal write not confirmed; reobserve before retry', {cause: failure ?? error}); }
}

async function restWrite(client, request) {
  const response = await client.request(request);
  assert.ok([200, 201].includes(response.status), 'proposal GitHub write rejected');
}

export function rootTree(entries) {
  assert.ok(Array.isArray(entries) && entries.length > 0 && entries.length <= 10000);
  const names = new Set();
  const values = entries.map(entry => {
    assert.ok(typeof entry.path === 'string' && entry.path.length > 0 && entry.path.isWellFormed() && !/[\0/]/.test(entry.path));
    assert.ok(!names.has(entry.path), 'duplicate Git tree path'); names.add(entry.path); oid(entry.sha);
    assert.ok(({blob: ['100644', '100755', '120000'], tree: ['040000'], commit: ['160000']})[entry.type]?.includes(entry.mode), 'invalid Git tree mode');
    return {entry, sort: Buffer.from(`${entry.path}${entry.type === 'tree' ? '/' : ''}`)};
  }).sort((a, b) => Buffer.compare(a.sort, b.sort));
  return objectId('tree', Buffer.concat(values.flatMap(({entry}) => [Buffer.from(`${entry.mode === '040000' ? '40000' : entry.mode} ${entry.path}\0`), Buffer.from(entry.sha, 'hex')])));
}

async function candidateObjects(client, candidate, branchBefore, admitCandidate) {
  const base = await get(client, `/git/commits/${candidate.base}`);
  assert.equal(base.sha, candidate.base); oid(base.tree.sha);
  const tree = await get(client, `/git/trees/${base.tree.sha}`);
  assert.equal(tree.truncated, false, 'truncated source tree');
  assert.equal(tree.sha, base.tree.sha);
  assert.equal(rootTree(tree.tree), base.tree.sha, 'base Git tree identity mismatch');
  const manifest = tree.tree.find(value => value.path === 'build.zig.zon');
  assert.ok(manifest && manifest.type === 'blob' && manifest.mode === '100644', 'unsupported manifest mode');
  const blob = await get(client, `/git/blobs/${manifest.sha}`);
  assert.equal(blob.sha, manifest.sha); assert.equal(blob.encoding, 'base64');
  assert.ok(typeof blob.content === 'string' && blob.content.length <= 2 * 1024 * 1024);
  const baseBytes = Buffer.from(blob.content.replaceAll('\n', ''), 'base64');
  assert.equal(baseBytes.length, blob.size); assert.equal(objectId('blob', baseBytes), manifest.sha);
  const blobOid = objectId('blob', candidate.manifestBytes);
  assert.notEqual(blobOid, manifest.sha, 'no semantic proposal change');
  const entries = tree.tree.map(entry => entry.path === 'build.zig.zon' ? {...entry, sha: blobOid} : entry);
  assert.equal(rootTree(entries), candidate.tree, 'candidate changes more than the manifest');
  await admitCandidate({candidate: candidateCopy(candidate), baseManifest: Buffer.from(baseBytes), baseTree: base.tree.sha});
  const create = async (path, expected, body, validate) => {
    let object = await get(client, `${path}/${expected}`, true);
    if (object === null) {
      await guard(client, candidate, branchBefore);
      object = await writeObserved(() => restWrite(client, {method: 'POST', path, body}), async () => {
        const value = await get(client, `${path}/${expected}`);
        assert.equal(value.sha, expected); return value;
      });
    }
    assert.equal(object.sha, expected); validate(object);
  };
  await create('/git/blobs', blobOid, {content: candidate.manifestBytes.toString('base64'), encoding: 'base64'}, value => {
    assert.equal(value.encoding, 'base64');
    assert.equal(objectId('blob', Buffer.from(value.content.replaceAll('\n', ''), 'base64')), blobOid);
  });
  await create('/git/trees', candidate.tree, {base_tree: base.tree.sha, tree: [{path: 'build.zig.zon', mode: '100644', type: 'blob', sha: blobOid}]}, value => {
    assert.equal(value.truncated, false); assert.equal(rootTree(value.tree), candidate.tree);
  });
  await create('/git/commits', candidate.head, {tree: candidate.tree, parents: [candidate.base], message: candidate.message,
    author: candidate.author, committer: candidate.committer}, value => {
    assert.equal(value.tree.sha, candidate.tree); assert.deepEqual(value.parents.map(parent => parent.sha), [candidate.base]);
    assert.equal(value.message, candidate.message);
    assert.equal(proposalCommitOid({...candidate, author: value.author, committer: value.committer}), candidate.head);
  });
}

async function storedCandidate(client, candidate) {
  const value = await get(client, `/git/commits/${candidate.head}`);
  assert.equal(value.sha, candidate.head); assert.equal(value.tree.sha, candidate.tree);
  assert.deepEqual(value.parents.map(parent => parent.sha), [candidate.base]);
  assert.equal(value.message, candidate.message);
  assert.equal(proposalCommitOid({...candidate, author: value.author, committer: value.committer}), candidate.head);
  const tree = await get(client, `/git/trees/${candidate.tree}`);
  assert.equal(tree.truncated, false); assert.equal(tree.sha, candidate.tree);
  assert.equal(rootTree(tree.tree), candidate.tree);
  const manifests = tree.tree.filter(entry => entry.path === 'build.zig.zon');
  assert.equal(manifests.length, 1); assert.equal(manifests[0].type, 'blob'); assert.equal(manifests[0].mode, '100644');
  assert.equal(manifests[0].sha, objectId('blob', candidate.manifestBytes), 'retired manifest differs from original Git source');
}

async function successorProposal({client, candidate, actor, pull, timeline, branchBefore, admitCandidate, admitRetirement}) {
  if (branchBefore !== pull.head.sha) return held('unknown human branch edit prevents successor preparation', pull);
  if (timeline.autoMerge !== null) return held('previous auto-merge request must be cancelled before successor preparation', pull);
  if (typeof admitRetirement !== 'function') return held('original owner epoch closure is required before successor preparation', pull);
  const retirement = await admitRetirement({pull: structuredClone(pull), knownHead: branchBefore,
    events: structuredClone(timeline.events), candidate: candidateCopy(candidate)});
  if (retirement?.epochClosed !== true || retirement.previousCandidate === undefined) {
    return held('authenticated original candidate and closed epoch are required before successor preparation', pull);
  }
  const previous = candidateCopy(retirement.previousCandidate), previousDescription = proposalDescription(previous);
  if (![previous.head, candidate.head].includes(branchBefore)) return held('unknown human branch edit prevents successor preparation', pull);
  if (pull.draft || pull.body !== previousDescription.body || pull.title !== `Prepare Horos ${previous.version}`) {
    return held('human proposal metadata edits prevent automatic successor replacement', pull);
  }
  assert.notEqual(previous.head, candidate.head, 'successor must name a distinct admitted candidate');
  await storedCandidate(client, previous);
  await candidateObjects(client, candidate, branchBefore, admitCandidate);
  const observe = async expectedHead => {
    await guard(client, candidate, expectedHead);
    const current = await get(client, `/pulls/${pull.number}`);
    owned(current, actor);
    assert.equal(current.state, 'open'); assert.equal(current.head.sha, expectedHead);
    assert.equal(current.base.sha, candidate.base); assert.equal(current.draft, false);
    assert.equal(current.body, pull.body, 'proposal body changed during successor preparation');
    assert.equal(current.title, pull.title, 'proposal title changed during successor preparation');
    assert.deepEqual(current.labels, pull.labels, 'proposal labels changed during successor preparation');
    const latest = await history(client, current);
    assert.deepEqual(latest, timeline, 'proposal history changed during successor preparation');
    return current;
  };
  await observe(branchBefore);
  if (branchBefore !== candidate.head) {
    const repo = await repository(client);
    await writeObserved(() => client.graphql(updateRefs, {input: {repositoryId: repo.node_id,
      refUpdates: [{name: `refs/heads/${proposalBranch}`, beforeOid: previous.head, afterOid: candidate.head, force: true}]} }), async () => {
      assert.equal(await reference(client, proposalBranch), candidate.head, 'successor branch update not observed');
    });
  }
  await observe(candidate.head);
  const description = proposalDescription(candidate);
  const updated = await writeObserved(() => restWrite(client, {method: 'PATCH', path: `/pulls/${pull.number}`,
    body: {title: `Prepare Horos ${candidate.version}`, body: description.body}}), async () => {
    const current = await get(client, `/pulls/${pull.number}`);
    owned(current, actor); assert.equal(current.state, 'open'); assert.equal(current.head.sha, candidate.head);
    assert.equal(current.body, description.body); assert.equal(current.title, `Prepare Horos ${candidate.version}`);
    return current;
  });
  if (!updated.assignees.some(value => value.login === 'tkersey')) {
    await guard(client, candidate, candidate.head);
    await writeObserved(() => restWrite(client, {method: 'POST', path: `/issues/${pull.number}/assignees`, body: {assignees: ['tkersey']}}), async () => {
      const assigned = await get(client, `/pulls/${pull.number}`);
      assert.ok(assigned.assignees.some(value => value.login === 'tkersey'));
    });
  }
  return {status: 'proposal open', number: pull.number, head: candidate.head, previousHead: previous.head};
}

function held(reason, pull) { return {status: 'held', reason, ...(pull ? {number: pull.number} : {})}; }

export async function pauseHorosProposals({actor, client = new HorosProposalClient()}) {
  await repository(client); identifier(actor.id);
  const results = [];
  const requiresPause = (pull, selectedMode) => selectedMode !== 'promote' || pull.draft ||
    pull.labels.some(label => label.name === 'automation-hold');
  for (const value of (await pulls(client)).filter(pull => pull.state === 'open')) {
    const pull = await get(client, `/pulls/${value.number}`);
    assert.equal(pull.user?.id, actor.id); assert.equal(pull.user?.login, actor.login);
    if (!requiresPause(pull, await mode(client))) continue;
    const current = await history(client, pull);
    if (current.autoMerge === null) continue;
    assert.equal(current.autoMerge.enabledBy?.login, actor.login, 'cannot cancel unknown auto-merge owner');
    const latest = await get(client, `/pulls/${pull.number}`);
    assert.equal(latest.user?.id, actor.id); assert.equal(latest.user?.login, actor.login);
    if (latest.state !== 'open' || !requiresPause(latest, await mode(client))) continue;
    const latestHistory = await history(client, latest);
    if (latestHistory.autoMerge === null) continue;
    assert.equal(latestHistory.autoMerge.enabledBy?.login, actor.login, 'cannot cancel unknown auto-merge owner');
    const deciding = await get(client, `/pulls/${pull.number}`);
    assert.equal(deciding.user?.id, actor.id); assert.equal(deciding.user?.login, actor.login);
    if (deciding.state !== 'open' || !requiresPause(deciding, await mode(client))) continue;
    assert.equal(deciding.node_id, latest.node_id);
    await writeObserved(() => client.graphql(disableMerge, {input: {pullRequestId: deciding.node_id}}), async () => {
      const observed = await get(client, `/pulls/${pull.number}`);
      assert.equal((await history(client, observed)).autoMerge, null, 'auto-merge cancellation not observed');
    });
    results.push(held('automation-owned auto-merge disabled by current controls or owner hold', pull));
  }
  return results;
}

export async function proposeHoros({candidate: input, actor, admitCandidate, admitRetirement, admitResume,
  client = new HorosProposalClient()}) {
  const candidate = candidateCopy(input), description = proposalDescription(candidate);
  identifier(actor.id); assert.ok(typeof actor.login === 'string' && actor.login.length > 0);
  assert.equal(typeof admitCandidate, 'function', 'native semantic admission required');
  await repository(client);
  const observedMode = await mode(client);
  if (observedMode === 'off') return {status: 'disabled'};
  if (await reference(client, 'main') !== candidate.base) return held('stale base; owner must close the previous epoch before regeneration');
  const branchBefore = await reference(client, proposalBranch, true);
  const existing = await pulls(client);
  let pull = existing.find(value => value.state === 'open') ?? existing[0];
  if (pull) {
    pull = await get(client, `/pulls/${pull.number}`);
    owned(pull, actor);
    const timeline = await history(client, pull);
    const holdEvents = pull.merged ? [] : timeline.events.filter(event => event.__typename === 'AutoMergeDisabledEvent');
    if (pull.labels.some(label => label.name === 'automation-hold') || (pull.state === 'closed' && !pull.merged) || holdEvents.length > 0) {
      if (typeof admitResume !== 'function') return held('manual closure, hold, or disabled auto-merge requires explicit owner resume', pull);
      await admitResume({pull: structuredClone(pull), events: structuredClone(timeline.events), candidate: candidateCopy(candidate)});
      if (pull.state === 'closed' && !pull.merged) return held('owner must reopen or retire the manually closed proposal before regeneration', pull);
    }
    if (pull.state === 'open') {
      if (pull.head.sha !== candidate.head || branchBefore !== candidate.head || !pull.body.startsWith(`${description.marker}\n`)) {
        return successorProposal({client, candidate, actor, pull, timeline, branchBefore, admitCandidate, admitRetirement});
      }
      assert.ok(pull.body.startsWith(`${description.marker}\n`), 'proposal binding changed');
      if (pull.base.sha !== candidate.base) return held('proposal base changed', pull);
      await candidateObjects(client, candidate, branchBefore, admitCandidate);
      if (!pull.assignees.some(value => value.login === 'tkersey')) {
        await guard(client, candidate, branchBefore);
        await writeObserved(() => restWrite(client, {method: 'POST', path: `/issues/${pull.number}/assignees`, body: {assignees: ['tkersey']}}), async () => {
          const assigned = await get(client, `/pulls/${pull.number}`);
          assert.ok(assigned.assignees.some(value => value.login === 'tkersey'));
        });
      }
      return {status: 'proposal open', number: pull.number, head: candidate.head};
    }
    if (pull.merged && pull.head.sha === candidate.head) return {status: 'landed—qualification pending', number: pull.number, head: candidate.head};
  }
  let reset = false;
  if (branchBefore !== null && branchBefore !== candidate.head) {
    if (!pull?.merged || pull.head.sha !== branchBefore) return held('unknown human branch edit; refusing branch replacement', pull);
    assert.equal(typeof admitRetirement, 'function', 'prior merged proposal epoch retirement required');
    await admitRetirement({pull: structuredClone(pull), knownHead: branchBefore, candidate: candidateCopy(candidate)});
    reset = true;
  }
  await candidateObjects(client, candidate, branchBefore, admitCandidate);
  if (branchBefore !== candidate.head) {
    const repo = await guard(client, candidate, branchBefore);
    assert.equal((await pulls(client)).filter(value => value.state === 'open').length, 0, 'proposal opened during preparation');
    await writeObserved(() => client.graphql(updateRefs, {input: {repositoryId: repo.node_id,
      refUpdates: [{name: `refs/heads/${proposalBranch}`, beforeOid: branchBefore ?? zero, afterOid: candidate.head, force: reset}]} }), async () => {
      assert.equal(await reference(client, proposalBranch), candidate.head, 'branch update not observed');
    });
  }
  await guard(client, candidate, candidate.head);
  assert.equal((await pulls(client)).filter(value => value.state === 'open').length, 0, 'proposal opened during preparation');
  pull = await writeObserved(() => restWrite(client, {method: 'POST', path: '/pulls', body: {
    title: `Prepare Horos ${candidate.version}`, head: proposalBranch, base: 'main', body: description.body,
    draft: false, maintainer_can_modify: false,
  }}), async () => {
    const found = (await pulls(client)).filter(value => value.state === 'open');
    assert.equal(found.length, 1, 'proposal creation not observed');
    const value = await get(client, `/pulls/${found[0].number}`);
    owned(value, actor); assert.equal(value.head.sha, candidate.head);
    assert.ok(value.body.startsWith(`${description.marker}\n`)); return value;
  });
  await guard(client, candidate, candidate.head);
  await writeObserved(() => restWrite(client, {method: 'POST', path: `/issues/${pull.number}/assignees`, body: {assignees: ['tkersey']}}), async () => {
    const value = await get(client, `/pulls/${pull.number}`);
    assert.ok(value.assignees.some(assignee => assignee.login === 'tkersey'));
  });
  return {status: 'proposal open', number: pull.number, head: candidate.head};
}

export async function promoteHoros({candidate: input, number, actor, admitPromotion, admitResume, client = new HorosProposalClient()}) {
  const candidate = candidateCopy(input);
  identifier(number); identifier(actor.id);
  assert.equal(typeof admitPromotion, 'function', 'trusted promotion admission required');
  await repository(client);
  let pull = await get(client, `/pulls/${number}`);
  owned(pull, actor);
  assert.equal(pull.head.ref, proposalBranch); assert.equal(pull.head.repo?.id, 1176152390);
  assert.equal(pull.base.ref, 'main'); assert.equal(pull.base.repo?.id, 1176152390);
  const timeline = await history(client, pull);
  const selectedMode = await mode(client);
  if (selectedMode !== 'promote') {
    if (timeline.autoMerge !== null && pull.state === 'open') {
      assert.equal(timeline.autoMerge.enabledBy?.login, actor.login, 'cannot cancel unknown auto-merge owner');
      assert.notEqual(await mode(client), 'promote', 'promotion control changed; reobserve');
      await writeObserved(() => client.graphql(disableMerge, {input: {pullRequestId: pull.node_id}}), async () => {
        const current = await get(client, `/pulls/${number}`);
        assert.equal((await history(client, current)).autoMerge, null, 'auto-merge cancellation not observed');
      });
      return {status: 'held', reason: 'automation-owned auto-merge disabled by current controls', number};
    }
    return {status: 'disabled', number};
  }
  if (pull.state !== 'open' || pull.draft || pull.labels.some(label => label.name === 'automation-hold')) return held('proposal is closed, draft, or explicitly held', pull);
  assert.ok(pull.assignees.some(value => value.login === 'tkersey'), 'proposal assignee missing');
  if (pull.head.sha !== candidate.head || pull.base.sha !== candidate.base || await reference(client, 'main') !== candidate.base ||
    await reference(client, proposalBranch) !== candidate.head) return held('stale base or human head edit prevents promotion', pull);
  assert.ok(pull.body.startsWith(`${proposalDescription(candidate).marker}\n`), 'proposal binding changed');
  const disabled = timeline.events.filter(event => event.__typename === 'AutoMergeDisabledEvent');
  if (disabled.length > 0) {
    if (typeof admitResume !== 'function') return held('disabled auto-merge requires explicit owner resume', pull);
    await admitResume({pull: structuredClone(pull), events: structuredClone(timeline.events), candidate: candidateCopy(candidate)});
  }
  const branch = await get(client, '/branches/main');
  assert.equal(branch.protected, true, 'main is not protected');
  assert.equal(branch.commit.sha, candidate.base, 'protected branch advanced');
  const protection = await get(client, '/branches/main/protection', true);
  const rules = await allPages(client, '/rules/branches/main');
  assert.ok(protection !== null || rules.length > 0, 'effective protection unavailable');
  const repo = await repository(client);
  assert.equal(repo.allow_auto_merge, true, 'repository auto-merge unavailable');
  assert.equal(repo.allow_rebase_merge, true, 'protected rebase merge unavailable');
  await admitPromotion({candidate: candidateCopy(candidate), pull: structuredClone(pull),
    protection: structuredClone(protection), rules: structuredClone(rules), history: structuredClone(timeline.events), repository: structuredClone(repo)});
  await guard(client, candidate, candidate.head, ['promote']);
  pull = await get(client, `/pulls/${number}`);
  assert.equal(pull.state, 'open'); assert.equal(pull.head.sha, candidate.head); assert.equal(pull.base.sha, candidate.base);
  owned(pull, actor);
  assert.equal(pull.draft, false);
  assert.ok(pull.assignees.some(value => value.login === 'tkersey'), 'proposal assignee changed during admission');
  assert.ok(!pull.labels.some(label => label.name === 'automation-hold'), 'proposal held during admission');
  assert.ok(pull.body.startsWith(`${proposalDescription(candidate).marker}\n`), 'proposal binding changed during admission');
  const current = await history(client, pull);
  assert.deepEqual(current.events, timeline.events, 'proposal history changed during admission');
  if (current.autoMerge !== null) {
    assert.equal(current.autoMerge.enabledBy?.login, actor.login, 'unknown auto-merge owner');
    assert.equal(current.autoMerge.mergeMethod, 'REBASE');
    return {status: 'promotion pending', number, head: candidate.head};
  }
  assert.equal(await mode(client), 'promote', 'promotion disabled');
  const merged = await writeObserved(() => client.graphql(enableMerge, {input: {pullRequestId: pull.node_id, expectedHeadOid: candidate.head, mergeMethod: 'REBASE'}}), async () => {
    const observed = await get(client, `/pulls/${number}`);
    assert.equal(observed.head.sha, candidate.head);
    if (observed.merged === true) return true;
    const enabled = (await history(client, observed)).autoMerge;
    assert.equal(enabled?.mergeMethod, 'REBASE'); assert.equal(enabled.enabledBy?.login, actor.login);
    return false;
  });
  return {status: merged ? 'landed—qualification pending' : 'promotion requested', number, head: candidate.head};
}
