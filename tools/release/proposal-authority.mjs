import assert from 'node:assert/strict';
import {HorosProposalClient} from './proposal-github.mjs';
import {automationMode} from './review-observer.mjs';
import {observation, observationPages} from './release-observation.mjs';

const marker = '<!-- repository-automation-status/v1 -->';
const timestamp = value => {
  assert.equal(typeof value, 'string');
  const time = Date.parse(value); assert.ok(Number.isFinite(time), 'missing original authority time');
  return time;
};

function localPull(pull) {
  assert.ok(Number.isSafeInteger(pull.number) && pull.number > 0);
  assert.equal(pull.base.ref, 'main');
  assert.equal(pull.base.repo.id, 1176152390); assert.equal(pull.head.repo.id, 1176152390);
  assert.match(pull.head.sha, /^[0-9a-f]{40}$/);
}

export async function readOwnerResume({pull, events, resumeHead = pull.head.sha}, client = new HorosProposalClient()) {
  localPull(pull); assert.match(resumeHead, /^[0-9a-f]{40}$/);
  assert.equal(pull.state, 'open', 'owner must reopen the proposal before resuming');
  assert.ok(!pull.labels.some(label => label.name === 'automation-hold'), 'owner must remove the hold label before resuming');
  const repository = await observation(client, '');
  assert.equal(repository.full_name, 'tkersey/horos'); assert.equal(repository.id, 1176152390);
  assert.equal(repository.owner.type, 'User');
  assert.ok(Number.isSafeInteger(repository.owner.id) && repository.owner.id > 0);
  assert.equal(repository.owner.login, 'tkersey');
  const issueEvents = await observationPages(client, `/issues/${pull.number}/events`);
  const holds = [...events.filter(event => ['AutoMergeDisabledEvent', 'ClosedEvent', 'ReopenedEvent', 'LabeledEvent', 'UnlabeledEvent'].includes(event.__typename) &&
    (!['LabeledEvent', 'UnlabeledEvent'].includes(event.__typename) || event.label?.name === 'automation-hold'))
    .map(event => timestamp(event.createdAt)),
  ...issueEvents.filter(event => ['closed', 'reopened'].includes(event.event) ||
    (['labeled', 'unlabeled'].includes(event.event) && event.label?.name === 'automation-hold'))
    .map(event => timestamp(event.created_at))];
  assert.ok(holds.length > 0, 'original hold timeline unavailable');
  const lastHold = Math.max(...holds), command = `/repository-automation resume ${pull.head.sha}`;
  const transitions = events.filter(event => event.__typename === 'HeadRefForcePushedEvent' &&
    event.beforeCommit?.oid === resumeHead && event.afterCommit?.oid === pull.head.sha && event.actor?.login === pull.user?.login);
  const predecessorDeadline = resumeHead !== pull.head.sha && transitions.length === 1 ? timestamp(transitions[0].createdAt) : null;
  const authorizesHead = comment => comment.body === command || (predecessorDeadline !== null &&
    comment.body === `/repository-automation resume ${resumeHead}` && timestamp(comment.created_at) < predecessorDeadline &&
    lastHold < predecessorDeadline);
  const comments = await observationPages(client, `/issues/${pull.number}/comments`);
  const accepted = comments.filter(comment => comment.user?.id === repository.owner.id &&
    comment.user?.login === repository.owner.login && comment.user?.type === 'User' &&
    authorizesHead(comment) && comment.created_at === comment.updated_at &&
    timestamp(comment.created_at) > lastHold);
  const selected = accepted.sort((left, right) => timestamp(right.created_at) - timestamp(left.created_at) || right.id - left.id)[0];
  if (selected) {
    const original = await observation(client, `/issues/comments/${selected.id}`);
    assert.deepEqual(original, selected, 'owner resume changed during admission');
  }
  const current = await observation(client, `/pulls/${pull.number}`);
  assert.equal(current.state, 'open'); assert.equal(current.head.sha, pull.head.sha);
  assert.deepEqual(current.labels, pull.labels, 'hold labels changed during resume admission');
  assert.deepEqual(await observationPages(client, `/issues/${pull.number}/events`), issueEvents, 'hold timeline changed during resume admission');
  assert.deepEqual((await observation(client, '')).owner, repository.owner, 'repository owner changed');
  return selected ? {head: selected.body === command ? pull.head.sha : resumeHead, commentId: selected.id, ownerId: repository.owner.id, createdAt: selected.created_at} : null;
}

export async function admitOwnerResume(input, client = new HorosProposalClient()) {
  const resume = await readOwnerResume(input, client);
  assert.ok(resume, 'exact fresh unedited repository-owner resume command required');
  return resume;
}

export function automationStatusBody({status, reason = null, head = null, version = null}) {
  assert.ok(typeof status === 'string' && status.length > 0 && status.length <= 256);
  if (head !== null) assert.match(head, /^[0-9a-f]{40}$/);
  if (reason !== null) assert.ok(typeof reason === 'string' && reason.length <= 12000);
  if (version !== null) assert.match(version, /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/);
  return `${marker}\n\nRepository automation: ${status}.\n${head ? `\nSource: \`${head}\`.\n` : ''}${version ? `\nPrepared version: \`${version}\`.\n` : ''}${reason ? `\n${reason}\n` : ''}`;
}

export async function reportAutomationStatus({number, actor, appId, state}, client = new HorosProposalClient()) {
  assert.ok(Number.isSafeInteger(appId) && appId > 0);
  assert.ok(Number.isSafeInteger(actor.id) && actor.id > 0);
  assert.match(actor.login, /^[a-z0-9][a-z0-9-]*\[bot\]$/);
  if (await automationMode(client) === 'off') return {status: 'disabled'};
  const pull = await observation(client, `/pulls/${number}`); localPull(pull);
  assert.equal(pull.number, number); assert.equal(pull.user.id, actor.id); assert.equal(pull.user.login, actor.login);
  if (pull.state !== 'open') return {status: 'closed'};
  const body = automationStatusBody({...state, head: pull.head.sha});
  const owned = async () => {
    const comments = await observationPages(client, `/issues/${number}/comments`);
    const matches = comments.filter(comment => comment.user?.id === actor.id && comment.user?.login === actor.login &&
      comment.body.startsWith(marker));
    assert.ok(matches.length <= 1, 'multiple automation-owned status comments');
    if (matches.length) assert.equal(matches[0].performed_via_github_app?.id, appId, 'status comment App authority differs');
    return matches[0] ?? null;
  };
  const previous = await owned();
  if (previous?.body === body) return {status: 'unchanged', commentId: previous.id};
  assert.notEqual(await automationMode(client), 'off', 'automation paused before status update');
  const current = await observation(client, `/pulls/${number}`);
  assert.equal(current.head.sha, pull.head.sha); assert.equal(current.state, 'open');
  assert.deepEqual(current.labels, pull.labels, 'proposal labels changed before status update');
  assert.equal(current.user.id, actor.id); assert.equal(current.user.login, actor.login);
  let failure;
  try {
    const response = await client.request({method: previous ? 'PATCH' : 'POST',
      path: previous ? `/issues/comments/${previous.id}` : `/issues/${number}/comments`, body: {body}});
    assert.equal(response.status, previous ? 200 : 201);
  } catch (error) { failure = error; }
  const actual = await owned();
  assert.equal(actual?.body, body, failure?.message ?? 'status write not observed; reobserve before retry');
  if (previous) assert.equal(actual.id, previous.id);
  return {status: 'reported', commentId: actual.id};
}
