import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {workflowPages} from './workflow-artifact.mjs';
import {decodeRecord, encodeRecord, maximumRecordBytes, sha256} from './encoding.mjs';
import {proposalBranch, proposalCommitOid, proposalMessage} from './proposal.mjs';

export const writerIntentWorkflow = '.github/workflows/repository-automation.yml';
export const writerIntentJob = 'Repository-local proposal and promotion';
export const writerIntentPlanStep = 'Prepare original source-write intent';
export const writerIntentUploadStep = 'Retain original source-write intent before mutation';
export const writerIntentWriteStep = 'Observe controls and perform admitted repository-local work';
export const maximumWriterIntentBytes = 4 * 1024 * 1024;
const intentLimits = Object.freeze({maximumBytes: maximumWriterIntentBytes, maximumValues: 65536, maximumDepth: 33});
const repository = 'tkersey/horos', repositoryId = 1176152390;
const oid = value => {assert.match(value, /^[0-9a-f]{40}$/); return value;};
const digest = value => {assert.match(value, /^[0-9a-f]{64}$/); return value;};
const id = value => {assert.ok(Number.isSafeInteger(value) && value > 0); return value;};
const time = value => {const result = Date.parse(value); assert.ok(Number.isFinite(result)); return result;};

export function writerIntentName(base, head) {
  return `horos-writer-intent-${oid(base)}-${oid(head)}.json`;
}

export function writerCandidate(candidate) {
  assert.ok(Buffer.isBuffer(candidate.manifestBytes) && candidate.manifestBytes.length > 0 &&
    candidate.manifestBytes.length <= maximumRecordBytes, 'unsupported candidate manifest size');
  assert.equal(candidate.message, proposalMessage(candidate));
  assert.equal(proposalCommitOid(candidate), candidate.head);
  return {base: candidate.base, head: candidate.head, tree: candidate.tree, version: candidate.version,
    message: candidate.message, author: candidate.author, committer: candidate.committer,
    manifest: candidate.manifestBytes.toString('base64'), manifestSha256: sha256(candidate.manifestBytes)};
}

export function encodeWriterIntent({candidate, boundary, controlCommit, runId, workflowSha256, identity, actor, toolSha256, branchBefore}) {
  const value = {schema: 'horos-writer-intent/v1', context: {repository, repositoryId, controlCommit,
    runId, attempt: 1, workflow: writerIntentWorkflow, workflowSha256},
  actor: {id: actor.id, login: actor.login, appId: identity.appId, installationId: identity.installationId},
  tool: {sourceCommit: controlCommit, sha256: toolSha256},
  branch: {name: proposalBranch, before: branchBefore, after: candidate.head},
  candidate: writerCandidate(candidate), boundary: boundary.record, boundarySha256: boundary.sha256};
  const bytes = encodeRecord(value, intentLimits);
  readWriterIntentBytes(bytes);
  return bytes;
}

export function readWriterIntentBytes(bytes) {
  const value = decodeRecord(bytes, intentLimits);
  assert.deepEqual(Object.keys(value).sort(), ['actor', 'boundary', 'boundarySha256', 'branch', 'candidate', 'context', 'schema', 'tool']);
  assert.equal(value.schema, 'horos-writer-intent/v1');
  const {context, actor, branch, tool, boundary, candidate: descriptor} = value;
  assert.deepEqual(Object.keys(context).sort(), ['attempt', 'controlCommit', 'repository', 'repositoryId', 'runId', 'workflow', 'workflowSha256']);
  assert.equal(context.repository, repository); assert.equal(context.repositoryId, repositoryId);
  oid(context.controlCommit); id(context.runId); assert.equal(context.attempt, 1);
  assert.equal(context.workflow, writerIntentWorkflow); digest(context.workflowSha256);
  assert.deepEqual(Object.keys(actor).sort(), ['appId', 'id', 'installationId', 'login']);
  id(actor.id); id(actor.appId); id(actor.installationId); assert.match(actor.login, /^[a-z0-9][a-z0-9-]*\[bot\]$/);
  assert.deepEqual(Object.keys(tool).sort(), ['sha256', 'sourceCommit']);
  assert.equal(tool.sourceCommit, context.controlCommit); digest(tool.sha256);
  assert.deepEqual(Object.keys(branch).sort(), ['after', 'before', 'name']);
  assert.equal(branch.name, proposalBranch); if (branch.before !== null) oid(branch.before);
  oid(branch.after); assert.notEqual(branch.before, branch.after, 'intent must precede its source transition');
  assert.deepEqual(Object.keys(descriptor).sort(), ['author', 'base', 'committer', 'head', 'manifest', 'manifestSha256', 'message', 'tree', 'version']);
  const {manifest, manifestSha256, ...fields} = descriptor;
  assert.equal(typeof manifest, 'string');
  const candidate = {...fields, manifestBytes: Buffer.from(manifest, 'base64')};
  assert.equal(candidate.manifestBytes.toString('base64'), manifest);
  assert.equal(sha256(candidate.manifestBytes), manifestSha256);
  assert.deepEqual(writerCandidate(candidate), descriptor);
  assert.equal(candidate.base, context.controlCommit); assert.equal(candidate.head, branch.after);
  assert.notEqual(candidate.head, candidate.base);
  assert.equal(candidate.author.name, actor.login); assert.equal(candidate.committer.name, actor.login);
  const email = `${actor.id}+${actor.login}@users.noreply.github.com`;
  assert.equal(candidate.author.email, email); assert.equal(candidate.committer.email, email);
  assert.equal(boundary.schema, 'repository-publication-boundary/v1'); assert.equal(boundary.repository, repository);
  assert.equal(boundary.source.commit, candidate.base); oid(boundary.source.tree);
  assert.equal(boundary.status, 'prepare'); assert.equal(boundary.version, candidate.version);
  assert.equal(sha256(encodeRecord(boundary)), value.boundarySha256);
  return {value, candidate};
}

export async function authenticateWriterIntent(artifact, command = githubCommand) {
  const reader = new GitHubReader(repository, command);
  await reader.verifyRepository(); id(artifact.id);
  assert.equal(artifact.expired, false, 'original writer intent expired; restore its original evidence before branch recovery');
  const runId = id(artifact.workflow_run?.id), controlCommit = oid(artifact.workflow_run.head_sha);
  assert.equal(artifact.workflow_run.repository_id, repositoryId); assert.equal(artifact.workflow_run.head_repository_id, repositoryId);
  assert.ok(Number.isSafeInteger(artifact.size_in_bytes) && artifact.size_in_bytes > 0 && artifact.size_in_bytes <= maximumWriterIntentBytes);
  const bytes = await command(['api', `repos/${repository}/actions/artifacts/${artifact.id}/zip`], maximumWriterIntentBytes);
  assert.ok(Buffer.isBuffer(bytes)); assert.equal(bytes.length, artifact.size_in_bytes);
  assert.equal(artifact.digest, `sha256:${sha256(bytes)}`, 'original writer intent bytes changed');
  const decoded = readWriterIntentBytes(bytes), {context} = decoded.value;
  assert.equal(context.runId, runId); assert.equal(context.controlCommit, controlCommit);
  assert.equal(artifact.name, writerIntentName(decoded.candidate.base, decoded.candidate.head));
  const run = await reader.api(`actions/runs/${runId}`);
  assert.equal(run.id, runId); assert.equal(run.repository.id, repositoryId); assert.equal(run.head_repository.id, repositoryId);
  assert.equal(run.head_sha, controlCommit); assert.equal(run.head_branch, 'main'); assert.equal(run.run_attempt, 1);
  assert.equal(run.path, writerIntentWorkflow); assert.ok(['schedule', 'workflow_dispatch', 'workflow_run'].includes(run.event));
  assert.ok(['in_progress', 'completed'].includes(run.status), 'intent producer has not started');
  const main = await reader.api('git/ref/heads/main');
  assert.equal(main.ref, 'refs/heads/main'); assert.equal(main.object.type, 'commit');
  assert.ok(await reader.forward(controlCommit, main.object.sha), 'writer intent control lineage changed');
  assert.equal((await reader.api(`actions/workflows/${run.workflow_id}`)).path, writerIntentWorkflow);
  const definition = await reader.api(`contents/${writerIntentWorkflow}?ref=${controlCommit}`);
  assert.equal(definition.type, 'file'); assert.equal(definition.encoding, 'base64');
  assert.equal(sha256(Buffer.from(definition.content.replaceAll('\n', ''), 'base64')), context.workflowSha256);
  const jobs = (await workflowPages(reader, `actions/runs/${runId}/attempts/1/jobs`, 'jobs')).filter(job => job.name === writerIntentJob);
  assert.equal(jobs.length, 1, 'original writer intent producer is ambiguous');
  const job = jobs[0];
  assert.equal(job.run_id, runId); assert.equal(job.run_attempt, 1); assert.equal(job.head_sha, controlCommit);
  assert.ok(job.labels?.includes('ubuntu-24.04')); const started = time(job.started_at);
  const step = name => {
    const matches = job.steps.filter(item => item.name === name);
    assert.equal(matches.length, 1, `missing unique original intent step: ${name}`);
    return matches[0];
  };
  const planned = step(writerIntentPlanStep), uploaded = step(writerIntentUploadStep), writer = step(writerIntentWriteStep);
  for (const item of [planned, uploaded]) {
    assert.equal(item.status, 'completed'); assert.equal(item.conclusion, 'success', 'original writer intent production did not succeed');
    id(item.number); assert.ok(time(item.started_at) >= started && time(item.completed_at) >= time(item.started_at));
    assert.ok(time(item.completed_at) - started <= 600000, 'writer intent production exceeded deadline');
  }
  assert.ok(planned.number < uploaded.number && uploaded.number < writer.number, 'writer intent must precede source mutation');
  assert.ok(time(planned.completed_at) <= time(uploaded.started_at));
  if (writer.started_at !== null && writer.started_at !== undefined)
    assert.ok(time(uploaded.completed_at) <= time(writer.started_at), 'source writer started before intent retention');
  return {...decoded, bytes, run, job, artifact};
}

export async function readHorosWriterIntent({head, base, actor, optional = false}, command = githubCommand) {
  oid(head); if (base !== undefined) oid(base);
  const reader = new GitHubReader(repository, command);
  const matches = (await workflowPages(reader, 'actions/artifacts', 'artifacts')).filter(artifact => {
    const name = /^horos-writer-intent-([0-9a-f]{40})-([0-9a-f]{40})\.json$/.exec(artifact.name);
    return name && name[2] === head && (base === undefined || name[1] === base) &&
      artifact.workflow_run?.repository_id === repositoryId && artifact.workflow_run?.head_repository_id === repositoryId;
  });
  assert.ok(matches.length <= 64, 'original writer intent capacity exceeded');
  if (matches.length === 0) {
    assert.equal(optional, true, 'original writer intent unavailable; unknown human branch source cannot be replaced');
    return null;
  }
  let original = null;
  for (const artifact of matches.sort((left, right) => left.id - right.id)) {
    const current = await authenticateWriterIntent(artifact, command);
    assert.equal(current.candidate.head, head); if (base !== undefined) assert.equal(current.candidate.base, base);
    if (actor) {assert.equal(current.value.actor.id, actor.id); assert.equal(current.value.actor.login, actor.login);}
    if (original) {
      for (const field of ['actor', 'branch', 'candidate', 'boundary', 'tool'])
        assert.deepEqual(current.value[field], original.value[field], 'conflicting original writer intents');
    } else original = current;
  }
  return original;
}
