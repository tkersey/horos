import assert from 'node:assert/strict';
import test from 'node:test';
import {sha256} from './encoding.mjs';
import {impactBlock, impactInput, versionPreparationImpact} from './impact.mjs';
import {proposalBranch, proposalCommitOid, proposalMessage} from './proposal.mjs';
import {admitHorosQualification, horosJobs} from './qualification.mjs';
import {retainedFixture} from './promotion-test-support.mjs';
import {createHorosPromotionAdmission, admitHorosLanding, reviewCheckBinding,
  validatePromotionProtection} from './promotion-admission.mjs';

const repository = 'tkersey/horos', repositoryId = 1176152390;
const base = 'a'.repeat(40), tree = 'b'.repeat(40), landed = 'c'.repeat(40);
const qualificationBytes = Buffer.from('accepted qualification workflow');
const person = {name: 'Release', email: 'release@example.test', date: '2026-10-30T00:00:00Z'};
const file = bytes => ({type: 'file', encoding: 'base64', content: bytes.toString('base64')});

async function fixture() {
  const candidate = {base, tree, manifestBytes: Buffer.from('.{ .version = "1.0.1" }\n'),
    version: '1.0.1', author: person, committer: person};
  candidate.message = proposalMessage(candidate); candidate.head = proposalCommitOid(candidate);
  const controlBytes = Buffer.from('accepted control workflow'), reviewBytes = Buffer.from('accepted owner workflow');
  const expected = {control: {commit: base, path: '.github/workflows/repository-automation.yml', sha256: sha256(controlBytes)},
    reviewWorkflow: {commit: base, path: '.github/workflows/repository-review.yml', sha256: sha256(reviewBytes)},
    qualificationWorkflow: {path: '.github/workflows/zig.yml', sha256: sha256(qualificationBytes)},
    checks: {qualification: {name: 'native', appId: 15368}, review: {name: 'Repository owner review', appId: 777}},
    reviews: {requiredApprovingReviewCount: 1, dismissStaleReviews: true,
      requireCodeOwnerReviews: false, requireLastPushApproval: false},
    acceptedRequirements: {reviewContract: 'repository-review-contract/v1', native: 'full-original-qualification'},
    reviewSettings: {codexSha256: '1'.repeat(64), casSha256: '2'.repeat(64),
      model: 'gpt-6', reasoningEffort: 'high', serviceTier: 'priority'}};
  const replies = new Map([['repos/tkersey/horos', {full_name: repository, id: repositoryId, default_branch: 'main'}]]);
  const qualifications = new Map();
  function qualification(runId, commit, event) {
    const run = {id: runId, repository: {id: repositoryId}, head_repository: {id: repositoryId},
      path: '.github/workflows/zig.yml', head_sha: commit, event, head_branch: event === 'push' ? 'main' : proposalBranch,
      run_attempt: 1, status: 'completed', conclusion: 'success', workflow_id: 23, check_suite_id: runId + 100};
    const jobs = Object.keys(horosJobs).map((name, index) => ({id: runId * 10 + index, name, run_id: runId,
      run_attempt: 1, head_sha: commit, status: 'completed', conclusion: 'success',
      check_run_url: `https://api.github.com/repos/${repository}/check-runs/${runId * 100 + index}`,
      started_at: '2026-10-30T00:00:00Z', completed_at: '2026-10-30T00:01:00Z',
      labels: ['ubuntu-24.04'], steps: [{name: 'executed fixture operation', status: 'completed', conclusion: 'success'}]}));
    const archive = Buffer.from(`fixture payload for ${commit}`);
    const inventory = Buffer.from(JSON.stringify({commit, tree, compiler: '0.17.0', archive: 'source.tar',
      sha256: sha256(archive), size: archive.length}));
    const artifacts = [['source.tar', archive], ['source.json', inventory]].map(([name, bytes], index) => ({
      id: runId * 1000 + index, name, expired: false, size_in_bytes: bytes.length, digest: `sha256:${sha256(bytes)}`,
      workflow_run: {id: runId, repository_id: repositoryId, head_repository_id: repositoryId, head_sha: commit}}));
    const entries = [
      [`actions/runs/${runId}`, run],
      [`actions/workflows/zig.yml/runs?head_sha=${commit}&event=${event}&per_page=100&page=1`, {workflow_runs: [run]}],
      ['actions/workflows/23', {path: run.path}],
      [`contents/${run.path}?ref=${commit}`, file(qualificationBytes)],
      [`actions/runs/${runId}/attempts/1/jobs?per_page=100&page=1`, {jobs}],
      [`actions/runs/${runId}/artifacts?per_page=100&page=1`, {artifacts}],
      [`actions/artifacts/${artifacts[0].id}/zip`, archive],
      [`actions/artifacts/${artifacts[1].id}/zip`, inventory],
      [`git/commits/${commit}`, {sha: commit, tree: {sha: tree}}],
    ];
    for (const [path, body] of entries) replies.set(`repos/${repository}/${path}`, body);
    qualifications.set(runId, {run, jobs, artifacts});
  }
  qualification(17, candidate.head, 'pull_request'); qualification(18, landed, 'push');
  const command = async args => {
    assert.ok(replies.has(args[1]), `unexpected qualification API: ${args[1]}`);
    const body = replies.get(args[1]); return Buffer.isBuffer(body) ? Buffer.from(body) : Buffer.from(JSON.stringify(body));
  };
  const source = await admitHorosQualification({runId: 17, commit: candidate.head, tree, event: 'pull_request'}, command);
  const body = impactBlock(versionPreparationImpact);
  const context = {repository, base, head: candidate.head, tree, pullNumber: 42, impact: impactInput(body, base, candidate.head),
    qualification: {runId: 17, workflow: source.workflow, evidenceSha256: sha256(source.evidence), originalEvidence: source.evidence.toString('base64')},
    acceptedRequirements: expected.acceptedRequirements};
  const retained = retainedFixture(context, expected.reviewSettings);
  const envelope = {schema: 'repository-review-result/v1', status: 'complete', epochClosed: true,
    reason: 'Original owner epoch complete.', turn: 1, previousSha256: null, stateSha256: null,
    context, retainedEvidence: Buffer.from(JSON.stringify(retained)).toString('base64')};
  const artifact = {bytes: Buffer.from(JSON.stringify(envelope)), workflow: {...expected.reviewWorkflow},
    run: {id: 101, head_sha: base, html_url: `https://github.com/${repository}/actions/runs/101`},
    artifact: {id: 111}};
  const protection = {enforce_admins: {enabled: true}, allow_force_pushes: {enabled: false},
    allow_deletions: {enabled: false}, required_conversation_resolution: {enabled: true},
    required_status_checks: {strict: true, checks: Object.values(expected.checks).map(check => ({context: check.name, app_id: check.appId}))},
    required_pull_request_reviews: {required_approving_review_count: 1, dismiss_stale_reviews: true,
      require_code_owner_reviews: false, require_last_push_approval: false}};
  const pull = {number: 42, node_id: 'PR_42', state: 'open', draft: false, body, labels: [], user: {id: 66},
    _links: {self: {href: `https://api.github.com/repos/${repository}/pulls/42`}},
    base: {ref: 'main', sha: base, repo: {id: repositoryId}},
    head: {ref: proposalBranch, sha: candidate.head, repo: {id: repositoryId}}};
  const state = {repository: {full_name: repository, id: repositoryId, default_branch: 'main', allow_auto_merge: true, allow_rebase_merge: true},
    branch: {protected: true, commit: {sha: base}}, pull, protection, rules: [], rulesets: [],
    reviews: [{id: 55, user: {id: 77, type: 'User', login: 'reviewer'}, state: 'APPROVED',
      submitted_at: '2026-10-30T01:00:00Z', commit_id: candidate.head}],
    permission: {permission: 'write', user: {id: 77}},
    decision: {state: 'OPEN', reviewDecision: 'APPROVED', mergeable: 'MERGEABLE', mergeStateStatus: 'CLEAN'},
    threads: [{id: 'THREAD', isResolved: true, isOutdated: false}],
    checks: [{id: 1704, name: 'native', head_sha: candidate.head, app: {id: 15368}, status: 'completed', conclusion: 'success', check_suite: {id: 117}},
      {id: 1001, name: 'Repository owner review', head_sha: candidate.head, app: {id: 777}, status: 'completed',
        conclusion: 'success', external_id: reviewCheckBinding(artifact), details_url: artifact.run.html_url}],
    calls: [], admissions: 0, authenticateCalls: 0, onRequest: null};
  const objects = new Map([
    [`/contents/${expected.control.path}?ref=${base}`, file(controlBytes)],
    [`/contents/${expected.reviewWorkflow.path}?ref=${base}`, file(reviewBytes)],
    [`/contents/${expected.qualificationWorkflow.path}?ref=${base}`, file(qualificationBytes)],
    ['/pulls/42/commits?per_page=100&page=1', [{sha: candidate.head}]],
    [`/git/commits/${candidate.head}`, {sha: candidate.head, tree: {sha: tree}, parents: [{sha: base}]}],
    [`/git/commits/${landed}`, {sha: landed, tree: {sha: tree}, parents: [{sha: base}]}],
    ['/git/ref/heads/main', {ref: 'refs/heads/main', object: {type: 'commit', sha: landed}}],
    [`/compare/${landed}...${landed}`, {base_commit: {sha: landed}, merge_base_commit: {sha: landed}, status: 'identical'}],
  ]);
  const client = {
    async request(request) {
      assert.equal(request.method ?? 'GET', 'GET'); state.calls.push(request.path);
      await state.onRequest?.(request, state);
      const path = request.path;
      const lookup = new Map([
        ['', state.repository], ['/branches/main', state.branch], ['/pulls/42', state.pull],
        ['/branches/main/protection', state.protection], ['/rules/branches/main?per_page=100&page=1', state.rules],
        ['/pulls/42/reviews?per_page=100&page=1', state.reviews], ['/collaborators/reviewer/permission', state.permission],
        [`/commits/${candidate.head}/check-runs?filter=all&per_page=100&page=1`, {check_runs: state.checks}],
        ...state.rulesets.map(value => [`/rulesets/${value.id}?includes_parents=true`, value]), ...objects,
      ]);
      assert.ok(lookup.has(path), `unexpected promotion API: ${path}`);
      const body = lookup.get(path); return body === null ? {status: 404} : {status: 200, body: structuredClone(body)};
    },
    async graphql(query, variables) {
      assert.equal(variables.number, 42); assert.equal(variables.cursor, null);
      return {repository: {databaseId: repositoryId, pullRequest: {id: state.pull.node_id,
        headRefOid: state.pull.head.sha, baseRefOid: state.pull.base.sha, isDraft: state.pull.draft,
        ...state.decision, reviewThreads: {nodes: structuredClone(state.threads), pageInfo: {hasNextPage: false, endCursor: null}}}}};
    },
  };
  const options = {expected, client, command, qualificationRunId: 17,
    authenticateReview: async subject => {
      assert.deepEqual(subject, {base, head: candidate.head, tree, purpose: 'pull'}); state.authenticateCalls++; return artifact;
    },
    admitCandidate: async ({candidate: admitted}) => {assert.equal(admitted.head, candidate.head); state.admissions++;},
  };
  const promote = () => createHorosPromotionAdmission(options)({candidate, pull});
  const land = () => admitHorosLanding({candidate, number: 42, landedRunId: 18}, options);
  const merged = () => Object.assign(pull, {state: 'closed', merged: true, merged_at: '2026-10-30T02:00:00Z', merge_commit_sha: landed});
  const updateEnvelope = () => {artifact.bytes = Buffer.from(JSON.stringify(envelope)); state.checks[1].external_id = reviewCheckBinding(artifact);};
  return {candidate, expected, replies, qualifications, state, options, artifact, envelope, retained, context, objects,
    promote, land, merged, updateEnvelope};
}

test('protected promotion admits exact original owner and native proofs using only reads', async () => {
  const value = await fixture(); const result = await value.promote();
  assert.deepEqual(result.record.subject, {base, head: value.candidate.head, tree});
  assert.equal(result.record.qualificationRunId, 17); assert.equal(result.record.review.artifactId, 111);
  assert.equal(value.state.admissions, 1); assert.equal(value.state.authenticateCalls, 1);
  assert.equal(value.state.calls.filter(path => path === '/branches/main').length, 2);
});

for (const kind of ['different pull', 'bootstrap']) test(`promotion distinguishes an otherwise complete ${kind} owner result`, async () => {
  const value = await fixture();
  if (kind === 'different pull') value.context.pullNumber = 43;
  else value.context.bootstrap = {boundary: {base, head: value.candidate.head, tree}};
  value.envelope.retainedEvidence = Buffer.from(JSON.stringify(retainedFixture(value.context, value.expected.reviewSettings))).toString('base64');
  value.updateEnvelope();
  await assert.rejects(value.promote, kind === 'different pull' ? /different pull request/ : /bootstrap review cannot/);
});

for (const [name, mutate] of [
  ['unprotected main', v => {v.state.branch.protected = false;}],
  ['changed base', v => {v.state.branch.commit.sha = landed;}],
  ['changed pull head', v => {v.state.pull.head.sha = landed;}],
  ['hold label', v => {v.state.pull.labels.push({name: 'automation-hold'});}],
  ['draft proposal', v => {v.state.pull.draft = true;}],
  ['closed proposal', v => {v.state.pull.state = 'closed';}],
  ['disabled auto merge', v => {v.state.repository.allow_auto_merge = false;}],
  ['disabled rebase merge', v => {v.state.repository.allow_rebase_merge = false;}],
  ['administrator bypass', v => {v.state.protection.enforce_admins.enabled = false;}],
  ['force pushes', v => {v.state.protection.allow_force_pushes.enabled = true;}],
  ['branch deletion', v => {v.state.protection.allow_deletions.enabled = true;}],
  ['stale base allowed', v => {v.state.protection.required_status_checks.strict = false;}],
  ['unrequired resolution', v => {v.state.protection.required_conversation_resolution.enabled = false;}],
  ['missing required check', v => {v.state.protection.required_status_checks.checks.pop();}],
  ['extra unverified check', v => {v.state.protection.required_status_checks.checks.push({context: 'unverified', app_id: 99});}],
  ['wrong required producer', v => {v.state.protection.required_status_checks.checks[0].app_id++;}],
  ['weakened human review', v => {v.state.protection.required_pull_request_reviews.required_approving_review_count = 0;}],
  ['stale approvals allowed', v => {v.state.protection.required_pull_request_reviews.dismiss_stale_reviews = false;}],
  ['review bypass', v => {v.state.protection.required_pull_request_reviews.bypass_pull_request_allowances = {users: [{id: 4}], teams: [], apps: []};}],
  ['unresolved old thread', v => {v.state.threads[0].isResolved = false; v.state.threads[0].isOutdated = true;}],
  ['merge conflict', v => {v.state.decision.mergeable = 'CONFLICTING';}],
  ['unknown merge gate', v => {v.state.decision.mergeStateStatus = 'UNKNOWN';}],
  ['changes requested', v => {v.state.decision.reviewDecision = 'CHANGES_REQUESTED';}],
  ['stale approval', v => {v.state.reviews[0].commit_id = base;}],
  ['self approval', v => {v.state.reviews[0].user.id = v.state.pull.user.id;}],
  ['bot approval', v => {v.state.reviews[0].user.type = 'Bot';}],
  ['unauthorized approval', v => {v.state.permission.permission = 'read';}],
  ['missing approval', v => {v.state.reviews.length = 0;}],
  ['dismissed approval', v => {v.state.reviews[0].state = 'DISMISSED';}],
  ['missed change request', v => {v.state.reviews[0].state = 'CHANGES_REQUESTED';}],
  ['wrong check producer', v => {v.state.checks[0].app.id++;}],
  ['wrong check subject', v => {v.state.checks[0].head_sha = base;}],
  ['duplicate successful check', v => {v.state.checks.push({...v.state.checks[0], id: 7777});}],
  ['neutral check', v => {v.state.checks[0].conclusion = 'neutral';}],
  ['skipped review check', v => {v.state.checks[1].conclusion = 'skipped';}],
  ['missing check', v => {v.state.checks.pop();}],
  ['wrong job producer', v => {v.state.checks[0].id++;}],
  ['wrong suite producer', v => {v.state.checks[0].check_suite.id++;}],
  ['wrong artifact binding', v => {v.state.checks[1].external_id += 'x';}],
  ['wrong review run URL', v => {v.state.checks[1].details_url += '/x';}],
  ['wrong control revision', v => {v.expected.control.commit = landed;}],
  ['changed control contents', v => {v.objects.set(`/contents/${v.expected.control.path}?ref=${base}`, file(Buffer.from('changed')));}],
  ['wrong original review workflow', v => {v.artifact.workflow.sha256 = 'e'.repeat(64);}],
  ['review run on candidate', v => {v.artifact.run.head_sha = v.candidate.head;}],
  ['changed impact after review', v => {v.state.pull.body = impactBlock({...versionPreparationImpact, impact: 'minor'});}],
  ['native admission refusal', v => {v.options.admitCandidate = async () => {throw new Error('native refusal');};}],
  ['artifact authentication refusal', v => {v.options.authenticateReview = async () => {throw new Error('artifact refusal');};}],
  ['second qualification attempt', v => {v.qualifications.get(17).run.run_attempt = 2;}],
  ['changed original qualification workflow', v => {v.replies.set(`repos/${repository}/contents/.github/workflows/zig.yml?ref=${v.candidate.head}`, file(Buffer.from('changed')));}],
  ['missing native lane', v => {v.qualifications.get(17).jobs.pop();}],
  ['incomplete original owner', v => {v.envelope.status = 'blocked'; v.updateEnvelope();}],
  ['forged envelope context', v => {v.envelope.context = {...v.context, tree: landed}; v.updateEnvelope();}],
  ['runtime drift', v => {v.expected.reviewSettings.model = 'another-model';}],
  ['accepted requirement drift', v => {v.expected.acceptedRequirements.native = 'narrow';}],
  ['missing native callback', v => {delete v.options.admitCandidate;}],
  ['missing artifact callback', v => {delete v.options.authenticateReview;}],
]) test(`promotion refuses ${name}`, async () => {
  const value = await fixture(); mutate(value); await assert.rejects(async () => value.promote());
});

test('promotion refuses observations that change after original proof admission', async () => {
  const value = await fixture(); let count = 0;
  value.state.onRequest = request => {if (request.path === '/branches/main' && ++count === 2) value.state.pull.labels.push({name: 'changed'});};
  await assert.rejects(value.promote(), /observations changed/);
});

test('native callback cannot mutate the frozen candidate that gets admitted', async () => {
  const value = await fixture();
  value.options.admitCandidate = async ({candidate}) => {candidate.head = landed; candidate.manifestBytes.fill(0);};
  const result = await value.promote(); assert.equal(result.record.subject.head, value.candidate.head);
});

function rulesetFixture(value) {
  const rules = [
    {type: 'required_status_checks', parameters: {strict_required_status_checks_policy: true,
      required_status_checks: Object.values(value.expected.checks).map(check => ({context: check.name, integration_id: check.appId}))}},
    {type: 'pull_request', parameters: {required_approving_review_count: 1, dismiss_stale_reviews_on_push: true,
      require_code_owner_review: false, require_last_push_approval: false, required_review_thread_resolution: true}},
    {type: 'non_fast_forward'}, {type: 'deletion'},
  ];
  return {protection: null, rules: rules.map(rule => ({...structuredClone(rule), ruleset_id: 5})),
    rulesets: [{id: 5, enforcement: 'active', target: 'branch', bypass_actors: [], rules}]};
}

test('ruleset-only protection proves its owner rules and producer inventory', async () => {
  const value = await fixture(), policy = rulesetFixture(value);
  assert.equal(validatePromotionProtection(policy, value.expected).requiredApprovingReviewCount, 1);
  Object.assign(value.state, policy); await value.promote();
});

for (const [name, mutate] of [
  ['missing ruleset details', p => {p.rulesets.length = 0;}],
  ['ruleset bypass', p => {p.rulesets[0].bypass_actors.push({actor_id: 1});}],
  ['inactive ruleset', p => {p.rulesets[0].enforcement = 'evaluate';}],
  ['owner rule mismatch', p => {p.rulesets[0].rules[0].parameters.strict_required_status_checks_policy = false;}],
  ['unverified required rule', p => {p.rules.push({type: 'required_signatures', ruleset_id: 5}); p.rulesets[0].rules.push({type: 'required_signatures'});}],
  ['deletion allowed', p => {p.rules = p.rules.filter(rule => rule.type !== 'deletion');}],
]) test(`ruleset protection refuses ${name}`, async () => {
  const value = await fixture(), policy = rulesetFixture(value); mutate(policy);
  assert.throws(() => validatePromotionProtection(policy, value.expected));
});

test('landing preserves reviewed identity while independently qualifying actual landed commit', async () => {
  const value = await fixture(); value.merged(); const result = await value.land();
  assert.deepEqual(result.record.reviewed, {base, head: value.candidate.head, tree});
  assert.deepEqual(result.record.landed, {commit: landed, tree, parent: base});
  assert.equal(result.record.originalQualificationRunId, 17); assert.equal(result.record.landedQualificationRunId, 18);
  assert.equal(result.qualification.run.head_sha, landed);
  assert.equal(JSON.parse(result.qualification.payloads.get('source.json')).commit, landed);
});

for (const [name, mutate] of [
  ['unmerged pull', v => {v.state.pull.merged = false;}],
  ['open pull', v => {v.state.pull.state = 'open';}],
  ['different original head', v => {v.state.pull.head.sha = base;}],
  ['multiple original commits', v => {v.objects.get('/pulls/42/commits?per_page=100&page=1').push({sha: base});}],
  ['original parent mismatch', v => {v.objects.get(`/git/commits/${v.candidate.head}`).parents = [{sha: landed}];}],
  ['landed tree mismatch', v => {v.objects.get(`/git/commits/${landed}`).tree.sha = base;}],
  ['landed parent mismatch', v => {v.objects.get(`/git/commits/${landed}`).parents = [{sha: v.candidate.head}];}],
  ['merge commit', v => {v.objects.get(`/git/commits/${landed}`).parents.push({sha: v.candidate.head});}],
  ['landed commit outside main', v => {v.objects.get(`/compare/${landed}...${landed}`).status = 'diverged';}],
  ['old reviewed qualification replay', v => {v.qualifications.get(18).run.head_sha = v.candidate.head;}],
  ['landed retried qualification', v => {v.qualifications.get(18).run.run_attempt = 2;}],
  ['landed missing lane', v => {v.qualifications.get(18).jobs.pop();}],
  ['changed landed workflow', v => {v.replies.set(`repos/${repository}/contents/.github/workflows/zig.yml?ref=${landed}`, file(Buffer.from('changed')));}],
  ['changed original qualification workflow', v => {v.replies.set(`repos/${repository}/contents/.github/workflows/zig.yml?ref=${v.candidate.head}`, file(Buffer.from('changed')));}],
]) test(`landing refuses ${name}`, async () => {
  const value = await fixture(); value.merged(); mutate(value); await assert.rejects(value.land());
});
