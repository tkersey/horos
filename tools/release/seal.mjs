import assert from 'node:assert/strict';
import {assembleHoros} from './assemble.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {validateHorosJobs} from './qualification.mjs';
import {serializeReviewArtifact} from './retained-review.mjs';
import {reviewNames} from './review-result.mjs';
import {reviewPolicyCommit, reviewPolicyDigest, validateRetainedReview} from './review-owner.mjs';
import {expectedReviewSettings} from './review-check.mjs';

export function sealHorosPublication({boundary, qualification, manifestBytes, admission, node}) {
  assert.equal(boundary.status, 'ready', 'publication boundary is not ready');
  assert.deepEqual(boundary.bytes, encodeRecord(boundary.record));
  assert.equal(boundary.sha256, sha256(boundary.bytes));
  const {source, changes, bootstrap} = boundary.record;
  assert.equal(boundary.record.repository, 'tkersey/horos');
  assert.equal(qualification.run.event, 'push'); assert.equal(qualification.run.head_branch, 'main');
  assert.equal(qualification.run.head_sha, source.commit); assert.equal(qualification.run.run_attempt, 1);
  assert.equal(qualification.run.conclusion, 'success'); assert.equal(qualification.run.status, 'completed');
  validateHorosJobs(qualification.jobs, qualification.run);
  const evidence = parseEvidenceJson(qualification.evidence);
  assert.deepEqual(evidence.run, qualification.run); assert.deepEqual(evidence.jobs, qualification.jobs);
  assert.equal(evidence.workflowSha256, qualification.workflow.sha256);
  assert.equal(qualification.workflow.commit, source.commit);
  assert.equal(admission.path, '.github/workflows/repository-release.yml');
  const payloads = new Map([...qualification.payloads].map(([name, bytes]) => [name, Buffer.from(bytes)]));
  assert.deepEqual([...payloads.keys()].sort(), ['source.json', 'source.tar']);
  const inventory = parseEvidenceJson(payloads.get('source.json'));
  assert.equal(inventory.commit, source.commit); assert.equal(inventory.tree, source.tree);
  assert.equal(inventory.compiler, '0.17.0'); assert.match(inventory.compilerSha256, /^[0-9a-f]{64}$/);
  assert.equal(inventory.compilerPlatform, 'linux-x86_64');
  assert.equal(node.name, 'node'); assert.equal(node.version, '26.9.0'); assert.equal(node.platform, 'linux-x86_64');
  const last = changes.at(-1) ?? bootstrap;
  assert.ok(last && boundary.reviewProvenance instanceof Map, 'original owner closeout missing');
  assert.equal(last.subject.tree, source.tree, 'final source lacks reviewed tree correspondence');
  const originalNames = [];
  const entries = [...(bootstrap ? [bootstrap] : []), ...changes];
  for (const entry of entries) {
    const original = boundary.reviewProvenance.get(entry.review.sha256);
    assert.ok(original, 'original review provenance missing');
    assert.equal(sha256(original.bytes), entry.review.sha256);
    assert.equal(original.run.id, entry.review.runId); assert.equal(original.artifact.id, entry.review.artifactId);
    const purpose = original.envelope.context.bootstrap ? 'bootstrap' : 'pull';
    const subject = {repository: 'tkersey/horos', ...entry.subject, purpose};
    const name = reviewNames(subject.base, subject.head, purpose).result;
    const bytes = serializeReviewArtifact(original, subject);
    if (payloads.has(name)) assert.deepEqual(payloads.get(name), bytes);
    else {payloads.set(name, bytes); originalNames.push(name);}
  }
  const final = boundary.reviewProvenance.get(last.review.sha256);
  const retainedBytes = Buffer.from(final.envelope.retainedEvidence, 'base64');
  const retained = validateRetainedReview(retainedBytes, last.subject);
  for (const [key, value] of Object.entries(expectedReviewSettings)) assert.equal(retained.binding[key], value);
  const captures = parseEvidenceJson(retainedBytes).captures;
  payloads.set('owner-closeout.json', Buffer.from(captures.at(-1).final, 'base64'));
  payloads.set('qualification.json', Buffer.from(qualification.evidence));
  payloads.set('publication-boundary.json', Buffer.from(boundary.bytes));
  payloads.set('landing.json', encodeRecord({schema: 'repository-landing/v1', subject: last.subject,
    source, correspondence: changes.at(-1) ?? bootstrap.correspondence ?? {bootstrap: bootstrap.subject}}));
  const declarations = [...(bootstrap ? [bootstrap.declaration] : []), ...changes.filter(change => !change.versionOnly).map(change => change.declaration)];
  if (declarations.length === 0) declarations.push({impact: 'patch', disposition: 'compatible',
    rationale: 'Reviewed version preparation for publication.', contracts: ['packaging']});
  const order = ['none', 'patch', 'minor', 'major'];
  const compatibility = {impact: order[Math.max(...declarations.map(value => order.indexOf(value.impact)))],
    disposition: declarations.some(value => value.disposition === 'breaking') ? 'breaking' : 'compatible',
    rationale: 'Original reviewed declarations and their source ranges are retained in publication-boundary.json.',
    contracts: [...new Set(declarations.flatMap(value => value.contracts))].sort(), evidence: 'publication-boundary.json'};
  const metadata = {schema: 'repository-release/v1', repository: {name: 'tkersey/horos', id: 1176152390},
    dependencies: [], admission: {workflow: admission},
    artifacts: [...payloads].map(([name]) => ({name, role: name === 'source.tar' ? 'source' : name === 'source.json' ? 'inventory' : 'evidence', platform: null})),
    qualification: {workflow: qualification.workflow, run: {id: qualification.run.id, attempt: 1, event: 'push',
      commit: source.commit, tree: source.tree}, results: qualification.jobs.filter(job => job.name !== 'native').map(job =>
      ({platform: 'linux-x86_64', profile: job.name, evidence: 'qualification.json'})), aggregate: {name: 'native', evidence: 'qualification.json'}},
    review: {owner: 'actuating', executionMode: 'cas', policy: {repository: 'tkersey/dotfiles', definition: {
      path: 'agents/skills/actuating/references/review-contract.json', commit: reviewPolicyCommit, sha256: reviewPolicyDigest}},
    tools: [{name: 'cas', version: '0.8.4', platform: 'linux-x86_64', sha256: retained.binding.casSha256},
      {name: 'codex', version: '0.166.0', platform: 'linux-x86_64', sha256: retained.binding.codexSha256}],
    subject: last.subject, landing: {...source, evidence: 'landing.json'}, closeout: 'owner-closeout.json', originalEvidence: originalNames},
    compatibility, toolchains: [{name: 'zig', version: inventory.compiler, platform: inventory.compilerPlatform,
      sha256: inventory.compilerSha256}, node]};
  const recordBytes = assembleHoros(metadata, payloads, manifestBytes);
  const record = parseEvidenceJson(recordBytes);
  assert.equal(record.source.version, boundary.version);
  return {recordBytes, payloads};
}
