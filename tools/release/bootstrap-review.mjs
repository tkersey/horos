import {requireSameQualification} from './qualification-binding.mjs';
import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {automationMode} from './review-observer.mjs';
import {workflowPages} from './workflow-artifact.mjs';
import {readReviewResult} from './review-result.mjs';
import {admitHorosQualification} from './qualification.mjs';
import {impactBlock, impactInput, validateImpact} from './impact.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {parseVersion} from './version.mjs';
import {sha256} from './encoding.mjs';

async function requirements(reader, controlCommit) {
  const path = 'docs/repository-local-releases.md';
  const value = await reader.api(`contents/${path}?ref=${controlCommit}`);
  assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
  const bytes = Buffer.from(value.content.replaceAll('\n', ''), 'base64');
  return {path, commit: controlCommit, sha256: sha256(bytes), text: bytes.toString('utf8')};
}

function previousBinding(value) {
  return {runId: value.run.id, artifactId: value.artifact.id, sha256: sha256(value.bytes),
    controlCommit: value.workflow.commit, workflowSha256: value.workflow.sha256};
}

export async function observeHorosBootstrap({controlCommit, request = null, original = null}, command = githubCommand,
  client = new HorosProposalClient(), qualify = admitHorosQualification, readPrevious = readReviewResult) {
  assert.match(controlCommit, /^[0-9a-f]{40}$/);
  const reader = new GitHubReader('tkersey/horos', command);
  await reader.verifyRepository();
  if (await automationMode(client) === 'off') return {status: 'disabled', reason: 'Bootstrap review admission is disabled.'};
  const main = await reader.api('git/ref/heads/main');
  assert.equal(main.ref, 'refs/heads/main'); assert.equal(main.object.type, 'commit');
  assert.equal(main.object.sha, controlCommit, 'bootstrap control checkout is stale');
  let base, head, initialVersion, declaration;
  if (original !== null) {
    assert.equal(request, null); assert.equal(original.status, 'pending');
    ({base, head} = original.envelope.context);
    initialVersion = original.envelope.context.bootstrap.initialVersion;
    declaration = original.envelope.context.impact.declaration;
  } else {
    assert.ok(request, 'explicit bootstrap review input required');
    ({base, initialVersion, declaration} = request); head = controlCommit;
  }
  assert.match(base, /^[0-9a-f]{40}$/); parseVersion(initialVersion); validateImpact(declaration);
  assert.notEqual(base, head, 'bootstrap review requires a nonempty source range');
  if (declaration.disposition === 'breaking') assert.equal(declaration.impact, 'major');
  assert.ok(await reader.forward(base, head), 'bootstrap source range is not on accepted history');
  assert.ok(await reader.forward(head, controlCommit), 'bootstrap source left main history');
  const source = await reader.api(`git/commits/${head}`);
  assert.equal(source.sha, head); const tree = source.tree.sha;
  assert.match(tree, /^[0-9a-f]{40}$/);
  const prior = original ?? await readPrevious({repository: reader.repository, base, head, tree, purpose: 'bootstrap'}, command);
  const bootstrap = {boundary: {base, head, tree}, initialVersion, disposition: declaration.disposition, rationale: declaration.rationale};
  const impact = impactInput(impactBlock(declaration), base, head);
  if (prior.status !== 'absent') {
    if (prior.envelope) {
      assert.deepEqual(prior.envelope.context.bootstrap, bootstrap, 'original bootstrap inputs changed');
      assert.deepEqual(prior.envelope.context.impact, impact, 'original bootstrap impact changed');
    }
    if (prior.status !== 'pending') return {status: prior.status, reason: prior.envelope?.reason ?? prior.reason};
  }
  const runs = await workflowPages(reader, `actions/workflows/zig.yml/runs?head_sha=${head}&event=push`, 'workflow_runs');
  if (runs.length === 0 || (runs.length === 1 && runs[0].status !== 'completed')) {
    return {status: 'qualification pending', reason: 'Original landed qualification has not completed.'};
  }
  assert.equal(runs.length, 1, 'bootstrap cannot choose a favorable duplicate qualification');
  const qualification = await qualify({runId: runs[0].id, commit: head, tree, event: 'push'}, command);
  const inventory = parseEvidenceJson(qualification.payloads.get('source.json'));
  assert.equal(inventory.commit, head); assert.equal(inventory.tree, tree);
  assert.ok(inventory.packageIdentity.startsWith(`horos-${initialVersion}-`), 'bootstrap version differs from final native source package');
  const context = prior.status === 'pending' ? prior.envelope.context : {
    repository: reader.repository, pullNumber: null, base, head, tree, impact, bootstrap,
    acceptedRequirements: await requirements(reader, controlCommit),
    qualification: {runId: qualification.run.id, workflow: qualification.workflow,
      evidenceSha256: sha256(qualification.evidence), originalEvidence: qualification.evidence.toString('base64')},
    proof_inventory: qualification.jobs.map(job => ({name: job.name, command: 'original accepted landed qualification job',
      head, run: qualification.run.html_url, jobId: job.id, platform: 'linux-x86_64', status: job.conclusion,
      observation: 'Exact landed source and all required original qualification obligations admitted before bootstrap review.'})),
  };
  assert.equal(context.qualification.runId, qualification.run.id);
  requireSameQualification(context.qualification, qualification);
  assert.equal((await reader.api('git/ref/heads/main')).object.sha, controlCommit, 'bootstrap control advanced');
  return {status: 'ready', context, previous: prior.status === 'pending' ? previousBinding(prior) : null};
}

export async function pendingHorosBootstrap(controlCommit, command = githubCommand) {
  const reader = new GitHubReader('tkersey/horos', command);
  const artifacts = await workflowPages(reader, 'actions/artifacts', 'artifacts');
  const subjects = new Map();
  for (const artifact of artifacts) {
    if (artifact.workflow_run?.repository_id !== 1176152390 || artifact.workflow_run?.head_repository_id !== 1176152390 ||
      artifact.workflow_run?.head_branch !== 'main') continue;
    const match = /^bootstrap-review-([0-9a-f]{40})-([0-9a-f]{40})\.json\.gz$/.exec(artifact.name);
    if (match && !artifact.expired) subjects.set(`${match[1]}-${match[2]}`, {base: match[1], head: match[2]});
  }
  assert.ok(subjects.size <= 64, 'bootstrap state capacity exceeded');
  const pending = [];
  for (const subject of subjects.values()) {
    if (!await reader.forward(subject.head, controlCommit)) continue;
    const value = await reader.api(`git/commits/${subject.head}`);
    const result = await readReviewResult({repository: reader.repository, ...subject, tree: value.tree.sha, purpose: 'bootstrap'}, command);
    if (result.status === 'pending') pending.push(result);
  }
  assert.ok(pending.length <= 1, 'multiple pending bootstrap epochs require owner recovery');
  return pending[0] ?? null;
}
