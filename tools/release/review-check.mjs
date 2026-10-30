import assert from 'node:assert/strict';
import {HorosProposalClient} from './proposal-github.mjs';
import {readReviewResult, reviewEnvelope, reviewInvocation, bindReviewInvocation} from './review-result.mjs';
import {validateRetainedReview} from './review-owner.mjs';
import {requireCurrentImpact} from './impact.mjs';
import {reviewCheckBinding} from './promotion-admission.mjs';
import {reviewArchives} from './review-tools.mjs';
import {GitHubReader} from './github.mjs';
import {previousReviewForHead, resolveReviewSubject} from './review-subject.mjs';

export const reviewCheckName = 'Repository owner review';
export const expectedReviewSettings = Object.freeze({model: 'gpt-6-astra', reasoningEffort: 'high', serviceTier: 'priority',
  codexSha256: reviewArchives.codex.binarySha256, casSha256: reviewArchives.cas.binarySha256});

async function get(client, path) {
  const response = await client.request({path});
  assert.equal(response.status, 200, `review check observation unavailable: ${path}`);
  return response.body;
}

async function ownCheck(client, head, appId) {
  const matches = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const value = await get(client, `/commits/${head}/check-runs?filter=all&per_page=100&page=${page}`);
    assert.ok(Array.isArray(value.check_runs) && value.check_runs.length <= 100);
    for (const row of value.check_runs) {
      assert.ok(Number.isSafeInteger(row.id) && row.id > 0 && !seen.has(row.id), 'ambiguous check pagination');
      seen.add(row.id);
      if (row.name !== reviewCheckName || row.app?.id !== appId) continue;
      assert.equal(row.head_sha, head);
      assert.ok(typeof row.external_id === 'string' && row.external_id.startsWith('repository-review/'), 'unknown App-owned check');
      matches.push(row);
    }
    assert.ok(matches.length <= 1, 'multiple App-owned review checks for one subject');
    if (value.check_runs.length < 100) return matches[0] ?? null;
  }
  throw new Error('review check pagination capacity exceeded');
}

function matches(check, desired) {
  return check !== null && ['name', 'head_sha', 'status', 'external_id', 'details_url'].every(key => check[key] === desired[key]) &&
    (check.conclusion ?? null) === (desired.conclusion ?? null) &&
    check.output?.title === desired.output.title && check.output?.summary === desired.output.summary;
}

function desiredCheck(result, subject, settings, previous) {
  const retainedInvocation = reviewInvocation(previous, subject);
  if (result.bytes) bindReviewInvocation(result, retainedInvocation);
  else if (retainedInvocation?.runId && result.run)
    assert.equal(result.run.id, retainedInvocation.runId, 'original invocation differs from durable check');
  if (retainedInvocation && result.invocation)
    assert.equal(result.invocation.externalId, retainedInvocation.externalId, 'original check invocation differs');
  if (!result.bytes && retainedInvocation && !result.invocation && !result.run) result = {status: 'blocked', invocation: retainedInvocation,
    reason: 'The durable original invocation requires recovery; absent evidence cannot reset this review.'};
  const desired = {name: reviewCheckName, head_sha: subject.head, status: 'in_progress',
    external_id: `repository-review/pending:${subject.base}:${subject.head}`, details_url: subject.pullUrl,
    output: {title: 'Review pending', summary: 'The original qualified owner review has not completed.'}};
  if (result.status === 'absent') return desired;
  if (result.invocation) {
    desired.external_id = result.invocation.externalId;
    desired.details_url = result.invocation.detailsUrl ?? subject.pullUrl;
  }
  assert.ok(['running', 'pending', 'blocked', 'complete'].includes(result.status));
  if (result.run && !result.bytes && !result.invocation) {
    assert.ok(Number.isSafeInteger(result.run.id) && result.run.id > 0);
    desired.external_id = `repository-review/unresolved:${result.run.id}:${subject.base}:${subject.head}`;
    desired.details_url = `https://github.com/${subject.repository}/actions/runs/${result.run.id}`;
  }
  if (result.bytes) {
    const envelope = reviewEnvelope(result.bytes, subject);
    assert.equal(envelope.status, result.status);
    assert.equal(envelope.context.pullNumber, subject.number);
    assert.equal(envelope.context.bootstrap, undefined);
    desired.external_id = reviewCheckBinding(result);
    desired.details_url = result.run.html_url;
    assert.equal(desired.details_url, `https://github.com/${subject.repository}/actions/runs/${result.run.id}`);
    desired.output.summary = envelope.reason;
    if (envelope.status === 'complete') {
      const review = validateRetainedReview(Buffer.from(envelope.retainedEvidence, 'base64'), subject);
      for (const [key, value] of Object.entries(settings)) assert.equal(review.binding[key], value, `review runtime differs: ${key}`);
      try { requireCurrentImpact(review.context.impact, subject.body, subject.base, subject.head); }
      catch {
        desired.status = 'completed'; desired.conclusion = 'failure';
        desired.output = {title: 'Review declaration changed', summary: 'The current release-impact declaration differs from the original reviewed input.'};
        return desired;
      }
      desired.status = 'completed'; desired.conclusion = 'success'; desired.output.title = 'Owner review complete';
    }
  }
  if (result.status === 'blocked') {
    desired.status = 'completed'; desired.conclusion = 'failure'; desired.output.title = 'Owner review blocked';
    desired.output.summary = result.envelope?.reason ?? result.reason;
    assert.ok(typeof desired.output.summary === 'string' && desired.output.summary.length > 0);
  }
  return desired;
}

export async function reportHorosReview({number, appId}, {client = new HorosProposalClient(),
  readResult = readReviewResult, settings = expectedReviewSettings} = {}) {
  assert.ok(Number.isSafeInteger(number) && number > 0);
  assert.ok(Number.isSafeInteger(appId) && appId > 0);
  const repository = await get(client, '');
  assert.equal(repository.id, 1176152390); assert.equal(repository.full_name, 'tkersey/horos');
  assert.equal(repository.default_branch, 'main');
  const pull = await get(client, `/pulls/${number}`);
  assert.equal(pull.number, number); assert.equal(pull.base.ref, 'main');
  assert.equal(pull.base.repo.id, repository.id); assert.equal(pull.head.repo.id, repository.id);
  if (pull.state !== 'open' || pull.draft || pull.labels.some(label => label.name === 'automation-hold')) return {status: 'held'};
  const head = pull.head.sha, controlCommit = pull.base.sha;
  assert.match(head, /^[0-9a-f]{40}$/); assert.match(controlCommit, /^[0-9a-f]{40}$/);
  const commit = await get(client, `/git/commits/${head}`);
  assert.equal(commit.sha, head); assert.match(commit.tree.sha, /^[0-9a-f]{40}$/);
  const reader = new GitHubReader(repository.full_name);
  reader.api = path => get(client, `/${path}`);
  const {base, prior} = await resolveReviewSubject(reader, pull, commit, controlCommit, undefined,
    (source, selectedHead, tree, command, subjectBase) => previousReviewForHead(source, selectedHead, tree, command, subjectBase, readResult));
  const subject = {repository: repository.full_name, number, base, head, tree: commit.tree.sha,
    body: pull.body, pullUrl: `https://github.com/${repository.full_name}/pull/${number}`};
  const result = prior?.value ?? {status: 'absent'};
  const previous = await ownCheck(client, head, appId);
  const desired = desiredCheck(result, subject, settings, previous);
  if (matches(previous, desired)) return {status: 'unchanged', checkId: previous.id, conclusion: previous.conclusion};
  const current = await get(client, `/pulls/${number}`);
  assert.equal(current.head.sha, head); assert.equal(current.base.sha, controlCommit); assert.equal(current.body, pull.body);
  assert.equal(current.state, 'open'); assert.equal(current.draft, false);
  assert.ok(!current.labels.some(label => label.name === 'automation-hold'));
  assert.deepEqual(await ownCheck(client, head, appId), previous, 'original owner check changed before reporting');
  const body = {...desired};
  if (previous) delete body.head_sha;
  let writeError;
  try {
    const response = await client.request({method: previous ? 'PATCH' : 'POST',
      path: previous ? `/check-runs/${previous.id}` : '/check-runs', body});
    assert.equal(response.status, previous ? 200 : 201);
  } catch (error) { writeError = error; }
  const actual = await ownCheck(client, head, appId);
  assert.ok(matches(actual, desired), writeError?.message ?? 'review check write not observed; re-observe before retry');
  return {status: 'reported', checkId: actual.id, conclusion: actual.conclusion};
}
