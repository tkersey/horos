import assert from 'node:assert/strict';
import {GitHubReader, githubCommand} from './github.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {workflowPages} from './workflow-artifact.mjs';
import {admitHorosQualification} from './qualification.mjs';
import {previousReviewForHead, resolveReviewSubject} from './review-subject.mjs';
import {impactInput, requireCurrentImpact} from './impact.mjs';
import {sha256} from './encoding.mjs';

export async function automationMode(client = new HorosProposalClient()) {
  const response = await client.request({path: '/actions/variables/REPOSITORY_AUTOMATION'});
  if (response.status === 404) return 'off';
  assert.equal(response.status, 200, 'automation controls unavailable');
  assert.equal(response.body.name, 'REPOSITORY_AUTOMATION');
  assert.ok(['off', 'propose', 'promote'].includes(response.body.value));
  return response.body.value;
}

async function file(reader, path, commit) {
  const value = await reader.api(`contents/${path}?ref=${commit}`);
  assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
  return Buffer.from(value.content.replaceAll('\n', ''), 'base64');
}

async function pulls(reader) {
  const all = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const values = await reader.api(`pulls?state=open&base=main&per_page=100&page=${page}`);
    assert.ok(Array.isArray(values) && values.length <= 100);
    for (const value of values) {
      assert.ok(Number.isSafeInteger(value.number) && !seen.has(value.number));
      seen.add(value.number); all.push(value);
    }
    if (values.length < 100) return all;
  }
  throw new Error('pull request pagination capacity exceeded');
}

export async function observeHorosReview({controlCommit, requestedPull = null}, command = githubCommand,
  client = new HorosProposalClient(), previousReader = previousReviewForHead, qualify = admitHorosQualification) {
  assert.match(controlCommit, /^[0-9a-f]{40}$/);
  const reader = new GitHubReader('tkersey/horos', command);
  await reader.verifyRepository();
  const mode = await automationMode(client);
  if (mode === 'off') return {status: 'disabled', reason: 'REPOSITORY_AUTOMATION is off; no owner invocation admitted.'};
  const main = await reader.api('git/ref/heads/main');
  assert.equal(main.ref, 'refs/heads/main'); assert.equal(main.object.type, 'commit');
  assert.equal(main.object.sha, controlCommit, 'accepted control checkout is stale');
  const candidates = (await pulls(reader)).filter(pull => !pull.draft && pull.head.repo?.id === 1176152390 &&
    pull.base.repo?.id === 1176152390 && !pull.labels.some(label => label.name === 'automation-hold') &&
    (requestedPull === null || pull.number === requestedPull)).sort((a, b) =>
    Number(b.head.ref === 'automation/dependency-release') - Number(a.head.ref === 'automation/dependency-release') || a.number - b.number);
  const observations = [];
  for (const listed of candidates) {
    try {
      const pull = await reader.api(`pulls/${listed.number}`);
      assert.equal(pull.state, 'open'); assert.equal(pull.draft, false);
      assert.equal(pull.base.sha, controlCommit, 'pull base differs from accepted main');
      const head = pull.head.sha;
      assert.match(head, /^[0-9a-f]{40}$/);
      const commit = await reader.api(`git/commits/${head}`);
      assert.equal(commit.sha, head); const tree = commit.tree.sha;
      assert.match(tree, /^[0-9a-f]{40}$/);
      const {base, prior} = await resolveReviewSubject(reader, pull, commit, controlCommit, command, previousReader);
      if (prior && ['blocked', 'running'].includes(prior.value.status)) {
        observations.push({number: pull.number, status: prior.value.status, reason: prior.value.reason ?? prior.value.envelope?.reason});
        continue;
      }
      const impact = impactInput(pull.body, base, head);
      if (prior?.base === base) {
        requireCurrentImpact(prior.value.envelope.context.impact, pull.body, base, head);
        if (prior.value.status === 'complete') {
          observations.push({number: pull.number, status: 'complete', reason: 'Original owner closeout already admitted.'});
          continue;
        }
      }
      const runs = await workflowPages(reader, `actions/workflows/zig.yml/runs?head_sha=${head}&event=pull_request`, 'workflow_runs');
      if (runs.length === 0 || (runs.length === 1 && runs[0].status !== 'completed')) {
        observations.push({number: pull.number, status: 'qualification pending', reason: 'Original qualification has not completed.'});
        continue;
      }
      assert.equal(runs.length, 1, 'duplicate qualification runs cannot replace original evidence');
      const qualification = await qualify({runId: runs[0].id, commit: head, tree, event: 'pull_request'}, command);
      const accepted = await file(reader, 'docs/repository-local-releases.md', base);
      const context = prior?.value.status === 'pending' ? prior.value.envelope.context : {
        repository: 'tkersey/horos', pullNumber: pull.number, base, head, tree, impact,
        acceptedRequirements: {path: 'docs/repository-local-releases.md', commit: base, sha256: sha256(accepted), text: accepted.toString('utf8')},
        change: {title: pull.title, description: pull.body},
        qualification: {runId: qualification.run.id, workflow: qualification.workflow,
          evidenceSha256: sha256(qualification.evidence), originalEvidence: qualification.evidence.toString('base64')},
        proof_inventory: qualification.jobs.map(job => ({name: job.name, command: 'original accepted qualification job',
          head, run: qualification.run.html_url, jobId: job.id, platform: 'linux-x86_64', status: job.conclusion,
          observation: 'Actual successful original run and job, exact qualified archive source, all required lanes and deadlines admitted.'})),
      };
      assert.equal(context.qualification.runId, qualification.run.id);
      assert.equal(context.qualification.workflow.sha256, qualification.workflow.sha256, 'qualification definition changed');
      assert.equal(context.qualification.evidenceSha256, sha256(qualification.evidence), 'original qualification evidence changed');
      const current = await reader.api(`pulls/${pull.number}`);
      assert.equal(current.head.sha, head); assert.equal(current.base.sha, pull.base.sha); assert.equal(current.state, 'open');
      assert.equal(current.draft, false); assert.ok(!current.labels.some(label => label.name === 'automation-hold'));
      requireCurrentImpact(impact, current.body, base, head);
      return {status: 'ready', context, previous: prior?.value.status === 'pending' ? {
        runId: prior.value.run.id, artifactId: prior.value.artifact.id, sha256: sha256(prior.value.bytes),
        controlCommit: prior.value.workflow.commit, workflowSha256: prior.value.workflow.sha256,
      } : null, observations};
    } catch (error) {
      observations.push({number: listed.number, status: 'blocked', reason: String(error.message).slice(0, 8192)});
    }
  }
  return {status: observations.length === 0 ? 'unchanged' : 'waiting', observations};
}
