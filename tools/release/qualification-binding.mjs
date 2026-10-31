import assert from 'node:assert/strict';
import {parseEvidenceJson} from './evidence-json.mjs';
import {sha256} from './encoding.mjs';

function fields(value, names) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value));
  return Object.fromEntries(names.split(' ').filter(name => Object.hasOwn(value, name)).map(name => [name, value[name]]));
}

function identity(bytes) {
  const value = parseEvidenceJson(bytes);
  const run = fields(value.run, 'id run_attempt workflow_id path head_sha head_branch event status conclusion created_at run_started_at check_suite_id');
  run.repository = fields(value.run.repository, 'id');
  run.head_repository = fields(value.run.head_repository, 'id');
  assert.ok(Array.isArray(value.jobs) && Array.isArray(value.artifacts));
  const jobs = value.jobs.map(job => ({
    ...fields(job, 'id run_id run_attempt head_sha name check_run_url status conclusion started_at completed_at'),
    labels: [...(job.labels ?? [])].sort(),
    steps: (job.steps ?? []).map(step => fields(step, 'number name status conclusion started_at completed_at')),
  })).sort((a, b) => a.id - b.id);
  const artifacts = value.artifacts.map(artifact => ({
    ...fields(artifact, 'id name size_in_bytes digest expired'),
    workflow_run: fields(artifact.workflow_run, 'id repository_id head_repository_id head_sha'),
  })).sort((a, b) => a.id - b.id);
  return {...fields(value, 'workflowSha256 profileSha256'), run, jobs, artifacts};
}

export function requireSameQualification(original, current) {
  assert.deepEqual(Object.keys(original).sort(), ['evidenceSha256', 'originalEvidence', 'runId', 'workflow']);
  assert.equal(original.runId, current.run.id, 'original qualification run changed');
  assert.deepEqual(original.workflow, current.workflow, 'original qualification workflow changed');
  assert.equal(typeof original.originalEvidence, 'string');
  const bytes = Buffer.from(original.originalEvidence, 'base64');
  assert.equal(bytes.toString('base64'), original.originalEvidence, 'noncanonical original qualification evidence');
  assert.equal(sha256(bytes), original.evidenceSha256, 'original qualification evidence digest changed');
  assert.deepEqual(identity(bytes), identity(current.evidence), 'review proof inventory differs from actual qualification');
}
