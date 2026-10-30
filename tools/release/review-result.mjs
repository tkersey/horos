import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {authenticateWorkflowArtifact, workflowPages} from './workflow-artifact.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {sha256} from './encoding.mjs';
import {validateRetainedReview} from './review-owner.mjs';
import {repositories} from './record.mjs';
import {readPublishedReview} from './retained-review.mjs';

export function reviewNames(base, head, purpose = 'pull') {
  assert.match(base, /^[0-9a-f]{40}$/); assert.match(head, /^[0-9a-f]{40}$/);
  assert.ok(['pull', 'bootstrap'].includes(purpose));
  const subject = `${base}-${head}`;
  const prefix = purpose === 'bootstrap' ? 'bootstrap-review' : 'review';
  return {result: `${prefix}-${subject}.json`, state: `${prefix}-${subject}.json.gz`, start: `${prefix}-start-${subject}.json`,
    diagnostic: `${prefix}-diagnostic-${subject}.json.gz`};
}

export function reviewEnvelope(bytes, expected) {
  const value = parseEvidenceJson(bytes, 128 * 1024 * 1024);
  assert.equal(value.schema, 'repository-review-result/v1');
  assert.equal(value.context.repository, expected.repository);
  assert.equal(value.context.base, expected.base); assert.equal(value.context.head, expected.head);
  assert.equal(value.context.tree, expected.tree);
  assert.ok(['pending', 'complete', 'blocked'].includes(value.status));
  assert.equal(typeof value.epochClosed, 'boolean');
  if (value.status === 'complete') assert.equal(value.epochClosed, true);
  if (value.status === 'pending') assert.equal(value.epochClosed, false);
  assert.ok(typeof value.reason === 'string' && value.reason.length > 0 && value.reason.length <= 16384);
  assert.ok(Number.isSafeInteger(value.turn) && value.turn >= 1 && value.turn <= 64);
  if (value.turn === 1) assert.equal(value.previousSha256, null);
  else assert.match(value.previousSha256, /^[0-9a-f]{64}$/);
  if (value.status === 'pending') {
    assert.match(value.stateSha256, /^[0-9a-f]{64}$/);
    assert.equal(value.retainedEvidence, null);
  } else assert.equal(value.stateSha256, null);
  if (value.status === 'complete') {
    assert.equal(typeof value.retainedEvidence, 'string');
    const evidence = Buffer.from(value.retainedEvidence, 'base64');
    assert.equal(evidence.toString('base64'), value.retainedEvidence);
    const retained = validateRetainedReview(evidence, expected);
    assert.deepEqual(retained.context, value.context, 'published context differs from original owner input');
  } else assert.equal(value.retainedEvidence, null);
  return value;
}

export function reviewInvocation(check, subject) {
  if (check === null) return null;
  const name = subject.purpose === 'bootstrap' ? 'Repository bootstrap review' : 'Repository owner review';
  if (check.name !== name || check.head_sha !== subject.head) return null;
  const artifact = /^repository-review\/v1:([1-9][0-9]*):([1-9][0-9]*):([0-9a-f]{64})$/.exec(check.external_id);
  const start = /^repository-review\/unresolved:([1-9][0-9]*):([0-9a-f]{40}):([0-9a-f]{40})$/.exec(check.external_id);
  const lost = check.status === 'completed' && check.conclusion === 'failure' &&
    /^repository-review\/pending:([0-9a-f]{40}):([0-9a-f]{40})$/.exec(check.external_id);
  if (!artifact && !start && !lost) return null;
  const value = {externalId: check.external_id};
  if (artifact || start) {
    value.runId = Number((artifact ?? start)[1]);
    assert.ok(Number.isSafeInteger(value.runId));
    value.detailsUrl = `https://github.com/${subject.repository}/actions/runs/${value.runId}`;
  }
  if (artifact) {
    value.artifactId = Number(artifact[2]); assert.ok(Number.isSafeInteger(value.artifactId));
    value.sha256 = artifact[3];
  } else {
    value.base = (start ?? lost)[start ? 2 : 1];
    assert.equal((start ?? lost)[start ? 3 : 2], subject.head, 'original check subject differs');
  }
  return value;
}

export function bindReviewInvocation(result, invocation) {
  if (invocation?.runId) assert.equal(result.run.id, invocation.runId, 'original invocation differs from durable check');
  if (invocation?.artifactId) {
    assert.equal(result.artifact.id, invocation.artifactId, 'original artifact differs from durable check');
    assert.equal(sha256(result.bytes), invocation.sha256, 'original result differs from durable check');
  }
  return result;
}

export async function readReviewResult({repository, base, head, tree, controlCommit, workflowSha256, purpose = 'pull'}, command = githubCommand,
  publishedReader = readPublishedReview) {
  const subject = {repository, base, head, tree, purpose};
  const names = reviewNames(base, head, purpose), reader = new GitHubReader(repository, command);
  const checks = await workflowPages(reader, `commits/${head}/check-runs?filter=all`, 'check_runs');
  const invocations = checks.map(check => reviewInvocation(check, subject)).filter(Boolean);
  assert.ok(invocations.length <= 1, 'multiple durable original owner invocations require recovery');
  const invocation = invocations[0];
  const unavailable = () => ({status: 'blocked', ...(invocation ? {invocation} : {}),
    reason: 'An original owner invocation was reported, but its required evidence is unavailable; recover it before another review.'});
  if (invocation?.base && invocation.base !== base) return unavailable();
  const raw = await Promise.all([names.result, names.start].map(name =>
    workflowPages(reader, `actions/artifacts?name=${name}`, 'artifacts')));
  const admittedRuns = new Map();
  const filtered = [];
  for (const items of raw) {
    const selected = [];
    for (const item of items) {
      if (item.workflow_run?.repository_id !== repositories[repository] ||
        item.workflow_run?.head_repository_id !== repositories[repository] || item.workflow_run?.head_branch !== 'main') continue;
      if (!admittedRuns.has(item.workflow_run.id)) admittedRuns.set(item.workflow_run.id, await reader.api(`actions/runs/${item.workflow_run.id}`));
      const run = admittedRuns.get(item.workflow_run.id);
      if (run.path !== '.github/workflows/repository-review.yml' || run.head_branch !== 'main' ||
        !['schedule', 'workflow_dispatch', 'workflow_run'].includes(run.event)) continue;
      selected.push(item);
    }
    filtered.push(selected);
  }
  const [resultArtifacts, startArtifacts] = filtered;
  const values = [...resultArtifacts, ...startArtifacts];
  for (const item of values) {
    assert.ok([names.result, names.start].includes(item.name));
    assert.ok(Number.isFinite(Date.parse(item.created_at)), 'missing artifact creation time');
    assert.ok(Number.isSafeInteger(item.workflow_run?.id) && item.workflow_run.id > 0);
  }
  if (values.length === 0) {
    const published = await publishedReader(subject, command);
    if (published !== null) return bindReviewInvocation(published, invocation);
    if (invocation) return unavailable();
    return {status: 'absent'};
  }
  const latest = values.sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.id - a.id)[0];
  if (invocation?.runId && invocation.runId !== latest.workflow_run.id) return unavailable();
  const original = resultArtifacts.filter(item => item.workflow_run.id === latest.workflow_run.id);
  assert.ok(original.length <= 1, 'ambiguous original review result');
  if (original.length === 0) {
    const run = await reader.api(`actions/runs/${latest.workflow_run.id}`);
    return {status: run.status === 'completed' ? 'blocked' : 'running', ...(invocation ? {invocation} : {}),
      reason: 'original owner invocation has no completed result; original evidence must be recovered before another invocation', run};
  }
  if (original[0].expired) {
    const published = await publishedReader(subject, command);
    assert.ok(published, 'original review artifact expired and no authenticated publication retains it');
    assert.equal(`sha256:${sha256(published.bytes)}`, original[0].digest, 'published evidence differs from expired original artifact');
    return bindReviewInvocation(published, invocation);
  }
  if (controlCommit === undefined) {
    controlCommit = original[0].workflow_run.head_sha;
    assert.match(controlCommit, /^[0-9a-f]{40}$/);
    assert.ok(await reader.forward(base, controlCommit), 'review control predates or diverges from accepted subject base');
    const definition = await reader.api(`contents/.github/workflows/repository-review.yml?ref=${controlCommit}`);
    assert.equal(definition.type, 'file'); assert.equal(definition.encoding, 'base64');
    workflowSha256 = sha256(Buffer.from(definition.content.replaceAll('\n', ''), 'base64'));
  }
  const authenticated = await authenticateWorkflowArtifact({repository, runId: original[0].workflow_run.id,
    controlCommit, workflowPath: '.github/workflows/repository-review.yml', workflowSha256,
    jobName: 'Owner review', name: names.result}, command);
  const envelope = reviewEnvelope(authenticated.bytes, {repository, base, head, tree});
  assert.equal(Boolean(envelope.context.bootstrap), purpose === 'bootstrap', 'review purpose differs from original context');
  return bindReviewInvocation({status: envelope.status, envelope, ...authenticated}, invocation);
}

export async function authenticateReviewContinuation({context, previous}, command = githubCommand) {
  const authenticated = await authenticateWorkflowArtifact({repository: context.repository, runId: previous.runId,
    controlCommit: previous.controlCommit, workflowPath: '.github/workflows/repository-review.yml', workflowSha256: previous.workflowSha256,
    jobName: 'Owner review', name: reviewNames(context.base, context.head, context.bootstrap ? 'bootstrap' : 'pull').result}, command);
  assert.equal(authenticated.artifact.id, previous.artifactId, 'original continuation artifact changed');
  assert.equal(sha256(authenticated.bytes), previous.sha256, 'original continuation result changed');
  const envelope = reviewEnvelope(authenticated.bytes, context);
  assert.equal(envelope.status, 'pending', 'terminal owner result cannot be reopened');
  assert.deepEqual(envelope.context, context, 'original continuation context changed');
  return authenticated;
}

export async function readActiveReview(result, expected, command = githubCommand) {
  assert.equal(result.status, 'pending');
  const authenticated = await authenticateWorkflowArtifact({repository: expected.repository, runId: result.run.id,
    controlCommit: result.workflow.commit, workflowPath: result.workflow.path, workflowSha256: result.workflow.sha256,
    jobName: 'Owner review', name: reviewNames(expected.base, expected.head, result.envelope.context.bootstrap ? 'bootstrap' : 'pull').state}, command);
  assert.equal(sha256(authenticated.bytes), result.envelope.stateSha256, 'active state differs from owner result');
  return authenticated.bytes;
}
