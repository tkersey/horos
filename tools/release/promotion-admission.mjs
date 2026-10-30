import assert from 'node:assert/strict';
import {encodeRecord, sha256} from './encoding.mjs';
import {githubCommand} from './github.mjs';
import {requireCurrentImpact} from './impact.mjs';
import {HorosProposalClient} from './proposal-github.mjs';
import {proposalBranch, proposalCommitOid} from './proposal.mjs';
import {admitHorosQualification} from './qualification.mjs';
import {validateRetainedReview} from './review-owner.mjs';
import {reviewEnvelope} from './review-result.mjs';

const repositoryName = 'tkersey/horos', repositoryId = 1176152390;
const pullQuery = 'query PromotionPull($number:Int!,$cursor:String){repository(owner:"tkersey",name:"horos"){databaseId pullRequest(number:$number){id headRefOid baseRefOid isDraft state reviewDecision mergeable mergeStateStatus reviewThreads(first:100,after:$cursor){nodes{id isResolved isOutdated} pageInfo{hasNextPage endCursor}}}}}';
const oid = value => { assert.match(value, /^[0-9a-f]{40}$/); return value; };
const digest = value => { assert.match(value, /^[0-9a-f]{64}$/); return value; };
const identifier = value => { assert.ok(Number.isSafeInteger(value) && value > 0); return value; };

async function get(client, path, missing = false) {
  const response = await client.request({path});
  if (missing && response.status === 404) return null;
  assert.equal(response.status, 200, `promotion observation unavailable: ${path}`);
  return response.body;
}

async function pages(client, path, field = null) {
  const result = [], seen = new Set();
  for (let page = 1; page <= 100; page++) {
    const response = await get(client, `${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    const rows = field === null ? response : response[field];
    assert.ok(Array.isArray(rows) && rows.length <= 100, 'invalid promotion page');
    for (const row of rows) {
      if (row.id !== undefined) {
        identifier(row.id); assert.ok(!seen.has(row.id), 'promotion pagination changed'); seen.add(row.id);
      }
      result.push(row);
    }
    if (rows.length < 100) return result;
  }
  throw new Error('promotion observation capacity exceeded');
}

function definition(value) {
  assert.ok(value && typeof value === 'object'); oid(value.commit); digest(value.sha256);
  assert.match(value.path, /^\.github\/workflows\/[A-Za-z0-9_-]+\.yml$/);
}

function candidateCopy(value) {
  assert.ok(Buffer.isBuffer(value.manifestBytes));
  return {...structuredClone(value), manifestBytes: Buffer.from(value.manifestBytes)};
}

function requirements(value) {
  assert.ok(value && typeof value === 'object', 'accepted control requirements missing');
  definition(value.control); definition(value.reviewWorkflow);
  assert.equal(value.qualificationWorkflow.path, '.github/workflows/zig.yml');
  digest(value.qualificationWorkflow.sha256);
  assert.equal(value.checks.qualification.name, 'native');
  assert.equal(value.checks.review.name, 'Repository owner review');
  for (const check of Object.values(value.checks)) identifier(check.appId);
  assert.deepEqual(Object.keys(value.checks).sort(), ['qualification', 'review']);
  const review = value.reviews;
  assert.ok(Number.isInteger(review.requiredApprovingReviewCount) && review.requiredApprovingReviewCount >= 0 && review.requiredApprovingReviewCount <= 6);
  for (const key of ['dismissStaleReviews', 'requireCodeOwnerReviews', 'requireLastPushApproval']) assert.equal(typeof review[key], 'boolean');
  assert.ok(value.acceptedRequirements !== undefined, 'accepted requirements binding missing');
  encodeRecord(value.acceptedRequirements);
  for (const key of ['codexSha256', 'casSha256']) digest(value.reviewSettings[key]);
  for (const key of ['model', 'reasoningEffort', 'serviceTier']) assert.ok(typeof value.reviewSettings[key] === 'string' && value.reviewSettings[key].length > 0);
  return value;
}

async function acceptedDefinitions(client, candidate, expected) {
  assert.equal(expected.control.commit, candidate.base, 'control revision is not the frozen trusted base');
  assert.equal(expected.reviewWorkflow.commit, expected.control.commit, 'review control revision differs');
  for (const item of [expected.control, expected.reviewWorkflow,
    {...expected.qualificationWorkflow, commit: candidate.base}]) {
    const value = await get(client, `/contents/${item.path}?ref=${item.commit}`);
    assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
    const bytes = Buffer.from(value.content.replaceAll('\n', ''), 'base64');
    assert.equal(sha256(bytes), item.sha256, 'accepted workflow/control definition changed');
  }
}

function emptyAllowances(value) {
  if (value === undefined || value === null) return;
  for (const key of ['users', 'teams', 'apps']) assert.ok(Array.isArray(value[key]) && value[key].length === 0, 'review bypass allowance prevents unattended admission');
}

export function validatePromotionProtection({protection, rules, rulesets}, expected) {
  assert.ok(Array.isArray(rules) && Array.isArray(rulesets));
  assert.ok(protection !== null || rules.length > 0, 'effective branch protection missing');
  const checks = new Map(), approvals = {requiredApprovingReviewCount: 0,
    dismissStaleReviews: false, requireCodeOwnerReviews: false, requireLastPushApproval: false};
  let strict = false, conversation = false, pullRequired = false, forceForbidden = false, deletionForbidden = false;
  const addChecks = rows => {
    assert.ok(Array.isArray(rows));
    for (const row of rows) {
      const appId = row.app_id ?? row.integration_id;
      identifier(appId);
      assert.ok(typeof row.context === 'string' && row.context.length > 0);
      if (checks.has(row.context)) assert.equal(checks.get(row.context), appId, 'conflicting protected check producers');
      checks.set(row.context, appId);
    }
  };
  const addReviews = row => {
    assert.ok(Number.isInteger(row.count) && row.count >= 0);
    approvals.requiredApprovingReviewCount = Math.max(approvals.requiredApprovingReviewCount, row.count);
    for (const key of ['dismissStaleReviews', 'requireCodeOwnerReviews', 'requireLastPushApproval']) {
      assert.equal(typeof row[key], 'boolean', 'unknown effective review protection');
      approvals[key] ||= row[key];
    }
    pullRequired = true;
  };
  if (protection !== null) {
    assert.equal(protection.enforce_admins?.enabled, true, 'administrator protection is not enforced');
    assert.equal(protection.allow_force_pushes?.enabled, false, 'protected branch allows force pushes');
    assert.equal(protection.allow_deletions?.enabled, false, 'protected branch allows deletion');
    forceForbidden = true;
    deletionForbidden = true;
    strict ||= protection.required_status_checks?.strict === true;
    if (protection.required_status_checks) addChecks(protection.required_status_checks.checks);
    conversation ||= protection.required_conversation_resolution?.enabled === true;
    if (protection.required_pull_request_reviews) {
      const review = protection.required_pull_request_reviews;
      emptyAllowances(review.bypass_pull_request_allowances);
      addReviews({count: review.required_approving_review_count, dismissStaleReviews: review.dismiss_stale_reviews,
        requireCodeOwnerReviews: review.require_code_owner_reviews, requireLastPushApproval: review.require_last_push_approval});
    }
  }
  const byId = new Map(rulesets.map(value => [value.id, value]));
  assert.equal(byId.size, rulesets.length, 'duplicate ruleset evidence');
  for (const rule of rules) {
    const owner = byId.get(identifier(rule.ruleset_id));
    assert.ok(owner, 'effective ruleset details unavailable');
    assert.equal(owner.enforcement, 'active'); assert.equal(owner.target, 'branch');
    assert.ok(Array.isArray(owner.bypass_actors) && owner.bypass_actors.length === 0, 'ruleset bypass cannot authorize automation');
    assert.ok(Array.isArray(owner.rules) && owner.rules.some(item => item.type === rule.type &&
      sha256(encodeRecord(item.parameters ?? null)) === sha256(encodeRecord(rule.parameters ?? null))), 'effective rule differs from owner definition');
    const parameters = rule.parameters;
    switch (rule.type) {
      case 'required_status_checks':
        strict ||= parameters.strict_required_status_checks_policy === true;
        addChecks(parameters.required_status_checks); break;
      case 'pull_request':
        conversation ||= parameters.required_review_thread_resolution === true;
        addReviews({count: parameters.required_approving_review_count,
          dismissStaleReviews: parameters.dismiss_stale_reviews_on_push,
          requireCodeOwnerReviews: parameters.require_code_owner_review,
          requireLastPushApproval: parameters.require_last_push_approval}); break;
      case 'non_fast_forward': forceForbidden = true; break;
      case 'deletion': deletionForbidden = true; break;
      case 'required_linear_history': break;
      default: throw new Error(`unverified required branch rule: ${rule.type}`);
    }
  }
  assert.ok(strict && pullRequired && conversation && forceForbidden && deletionForbidden, 'required protected promotion semantics missing');
  const required = new Map(Object.values(expected.checks).map(value => [value.name, value.appId]));
  assert.deepEqual([...checks].sort(), [...required].sort(), 'required check inventory or producer differs');
  assert.ok(approvals.requiredApprovingReviewCount >= expected.reviews.requiredApprovingReviewCount, 'required human approval count weakened');
  for (const key of ['dismissStaleReviews', 'requireCodeOwnerReviews', 'requireLastPushApproval']) {
    if (expected.reviews[key]) assert.equal(approvals[key], true, `required review protection weakened: ${key}`);
  }
  return approvals;
}

async function protectionAt(client) {
  const protection = await get(client, '/branches/main/protection', true);
  const rules = await pages(client, '/rules/branches/main');
  const rulesets = [];
  for (const id of new Set(rules.map(value => identifier(value.ruleset_id)))) {
    const value = await get(client, `/rulesets/${id}?includes_parents=true`);
    assert.equal(value.id, id); rulesets.push(value);
  }
  return {protection, rules, rulesets};
}

async function threads(client, pull) {
  const all = [], ids = new Set(), cursors = new Set();
  let cursor = null, decision;
  for (let page = 0; page < 100; page++) {
    const data = await client.graphql(pullQuery, {number: pull.number, cursor});
    assert.equal(data.repository?.databaseId, repositoryId);
    const value = data.repository.pullRequest;
    assert.equal(value.id, pull.node_id); assert.equal(value.headRefOid, pull.head.sha);
    assert.equal(value.baseRefOid, pull.base.sha); assert.equal(value.isDraft, false);
    const observed = {state: value.state, reviewDecision: value.reviewDecision,
      mergeable: value.mergeable, mergeStateStatus: value.mergeStateStatus};
    if (decision !== undefined) assert.deepEqual(observed, decision, 'pull decision changed while reading threads');
    decision = observed;
    const connection = value.reviewThreads;
    assert.ok(Array.isArray(connection.nodes) && connection.nodes.length <= 100);
    for (const item of connection.nodes) {
      assert.ok(typeof item.id === 'string' && !ids.has(item.id), 'thread pagination changed'); ids.add(item.id);
      assert.equal(item.isResolved, true, 'unresolved review thread'); all.push(item);
    }
    if (connection.pageInfo.hasNextPage === false) return {decision, threads: all};
    cursor = connection.pageInfo.endCursor;
    assert.ok(typeof cursor === 'string' && cursor.length > 0 && !cursors.has(cursor)); cursors.add(cursor);
  }
  throw new Error('review thread pagination capacity exceeded');
}

async function humanReviews(client, pull, protection, decision) {
  const needsApproval = protection.requiredApprovingReviewCount > 0 || protection.requireCodeOwnerReviews || protection.requireLastPushApproval;
  if (needsApproval) assert.equal(decision.reviewDecision, 'APPROVED', 'GitHub required review decision is not approved');
  assert.notEqual(decision.reviewDecision, 'CHANGES_REQUESTED');
  const reviews = await pages(client, `/pulls/${pull.number}/reviews`), latest = new Map();
  for (const review of reviews) {
    identifier(review.user?.id);
    if (!['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'].includes(review.state)) continue;
    const previous = latest.get(review.user.id);
    if (previous) assert.ok(Date.parse(review.submitted_at) >= Date.parse(previous.submitted_at), 'review pagination order changed');
    assert.ok(Number.isFinite(Date.parse(review.submitted_at)));
    latest.set(review.user.id, review);
  }
  const admitted = [];
  for (const review of latest.values()) {
    if (review.user.type !== 'User' || review.user.id === pull.user.id) continue;
    assert.match(review.user.login, /^[A-Za-z0-9-]+$/);
    const permission = await get(client, `/collaborators/${encodeURIComponent(review.user.login)}/permission`);
    assert.equal(permission.user.id, review.user.id);
    if (!['admin', 'write', 'maintain'].includes(permission.permission)) continue;
    assert.notEqual(review.state, 'CHANGES_REQUESTED', 'required human reviewer requested changes');
    if (review.state !== 'APPROVED') continue;
    if (protection.dismissStaleReviews) assert.equal(review.commit_id, pull.head.sha, 'approval belongs to an earlier head');
    admitted.push(review);
  }
  assert.ok(admitted.length >= protection.requiredApprovingReviewCount, 'missing distinct authorized human approvals');
  return {reviews, admitted};
}

function pullIdentity(pull, candidate, open) {
  assert.equal(pull.base.repo?.id, repositoryId); assert.equal(pull.head.repo?.id, repositoryId);
  assert.equal(pull.base.ref, 'main'); assert.equal(pull.head.ref, proposalBranch);
  assert.equal(pull.head.sha, candidate.head); assert.equal(pull.base.sha, candidate.base);
  assert.equal(pull.draft, false);
  if (open) assert.equal(pull.state, 'open');
}

async function livePromotion(client, candidate, number, expected) {
  const repository = await get(client, '');
  assert.equal(repository.full_name, repositoryName); assert.equal(repository.id, repositoryId);
  assert.equal(repository.default_branch, 'main'); assert.equal(repository.allow_auto_merge, true);
  assert.equal(repository.allow_rebase_merge, true);
  const branch = await get(client, '/branches/main');
  assert.equal(branch.protected, true, 'main is not protected'); assert.equal(branch.commit.sha, candidate.base);
  const pull = await get(client, `/pulls/${identifier(number)}`);
  pullIdentity(pull, candidate, true);
  assert.ok(!pull.labels.some(label => label.name === 'automation-hold'), 'proposal held');
  const policy = await protectionAt(client);
  const effective = validatePromotionProtection(policy, expected);
  const threadState = await threads(client, pull);
  assert.equal(threadState.decision.state, 'OPEN');
  assert.equal(threadState.decision.mergeable, 'MERGEABLE');
  assert.equal(threadState.decision.mergeStateStatus, 'CLEAN', 'required GitHub gates are not ready');
  const reviews = await humanReviews(client, pull, effective, threadState.decision);
  const checks = await pages(client, `/commits/${candidate.head}/check-runs?filter=all`, 'check_runs');
  return {repository, pull, policy, effective, ...threadState, ...reviews, checks};
}

export function reviewCheckBinding(artifact) {
  return `repository-review/v1:${identifier(artifact.run.id)}:${identifier(artifact.artifact.id)}:${sha256(artifact.bytes)}`;
}

export function validatePromotionChecks(checks, expected, candidate, qualification, review) {
  const selected = {};
  for (const [kind, required] of Object.entries(expected.checks)) {
    const matching = checks.filter(check => check.name === required.name);
    assert.equal(matching.length, 1, `missing or ambiguous required check: ${required.name}`);
    const check = matching[0];
    identifier(check.id); assert.equal(check.head_sha, candidate.head);
    assert.equal(check.app?.id, required.appId); assert.equal(check.status, 'completed');
    assert.equal(check.conclusion, 'success', `required check did not succeed: ${required.name}`);
    selected[kind] = check;
  }
  const aggregate = qualification.jobs.filter(job => job.name === expected.checks.qualification.name);
  assert.equal(aggregate.length, 1);
  assert.equal(aggregate[0].check_run_url,
    `https://api.github.com/repos/${repositoryName}/check-runs/${selected.qualification.id}`, 'qualification check has a different job producer');
  assert.equal(identifier(selected.qualification.check_suite?.id), identifier(qualification.run.check_suite_id));
  assert.equal(qualification.workflow.path, expected.qualificationWorkflow.path);
  assert.equal(qualification.workflow.sha256, expected.qualificationWorkflow.sha256, 'qualification workflow differs from accepted base');
  assert.equal(selected.review.external_id, reviewCheckBinding(review), 'review check lacks its authenticated artifact binding');
  assert.equal(selected.review.details_url, review.run.html_url);
  return selected;
}

async function reviewedEvidence({candidate, pull, qualificationRunId}, options) {
  const qualification = await admitHorosQualification({runId: identifier(qualificationRunId),
    commit: candidate.head, tree: candidate.tree, event: 'pull_request'}, options.command);
  assert.equal(qualification.workflow.path, options.expected.qualificationWorkflow.path);
  assert.equal(qualification.workflow.sha256, options.expected.qualificationWorkflow.sha256,
    'original qualification workflow differs from accepted base');
  const artifact = await options.authenticateReview({base: candidate.base, head: candidate.head, tree: candidate.tree});
  assert.ok(Buffer.isBuffer(artifact.bytes), 'authenticated original review artifact missing');
  assert.deepEqual(artifact.workflow, options.expected.reviewWorkflow, 'review workflow/control source differs');
  assert.equal(artifact.run.head_sha, options.expected.control.commit);
  assert.equal(artifact.run.html_url, `https://github.com/${repositoryName}/actions/runs/${artifact.run.id}`);
  assert.ok(artifact.bytes.length <= 128 * 1024 * 1024);
  const envelope = reviewEnvelope(artifact.bytes, {repository: repositoryName,
    base: candidate.base, head: candidate.head, tree: candidate.tree});
  assert.equal(envelope.status, 'complete', 'owner review is incomplete');
  assert.ok(typeof envelope.retainedEvidence === 'string');
  const bytes = Buffer.from(envelope.retainedEvidence, 'base64');
  assert.equal(bytes.toString('base64'), envelope.retainedEvidence, 'noncanonical retained review evidence');
  const review = validateRetainedReview(bytes, {base: candidate.base, head: candidate.head});
  assert.equal(review.owner.output.status, 'complete');
  assert.deepEqual(envelope.context, review.context, 'review envelope differs from original owner context');
  assert.equal(review.context.repository, repositoryName); assert.equal(review.context.tree, candidate.tree);
  assert.deepEqual(review.context.qualification, {runId: qualification.run.id,
    workflow: qualification.workflow, evidenceSha256: sha256(qualification.evidence),
    originalEvidence: qualification.evidence.toString('base64')}, 'review proof inventory differs from actual qualification');
  assert.deepEqual(review.context.acceptedRequirements, options.expected.acceptedRequirements);
  for (const [key, value] of Object.entries(options.expected.reviewSettings)) assert.equal(review.binding[key], value, `review runtime changed: ${key}`);
  const impact = requireCurrentImpact(review.context.impact, pull.body, candidate.base, candidate.head);
  return {qualification, artifact, review, impact};
}

function admissionOptions(options) {
  assert.equal(typeof options.authenticateReview, 'function', 'authenticated workflow artifact reader required');
  assert.equal(typeof options.admitCandidate, 'function', 'native semantic candidate admission required');
  return {...options, expected: structuredClone(requirements(options.expected)),
    client: options.client ?? new HorosProposalClient(), command: options.command ?? githubCommand};
}

export function createHorosPromotionAdmission(input) {
  const options = admissionOptions(input);
  return async ({candidate: provided, pull}) => {
    const candidate = candidateCopy(provided);
    assert.equal(proposalCommitOid(candidate), oid(candidate.head)); oid(candidate.tree);
    const before = await livePromotion(options.client, candidate, pull.number, options.expected);
    await acceptedDefinitions(options.client, candidate, options.expected);
    await options.admitCandidate({candidate: candidateCopy(candidate), pull: structuredClone(before.pull)});
    const evidence = await reviewedEvidence({candidate, pull: before.pull,
      qualificationRunId: options.qualificationRunId}, options);
    validatePromotionChecks(before.checks, options.expected, candidate, evidence.qualification, evidence.artifact);
    const after = await livePromotion(options.client, candidate, pull.number, options.expected);
    assert.deepEqual(after, before, 'promotion observations changed during admission');
    const record = {schema: 'repository-promotion-admission/v1', repository: repositoryName,
      subject: {base: candidate.base, head: candidate.head, tree: candidate.tree},
      control: options.expected.control, impact: evidence.review.context.impact,
      qualificationRunId: evidence.qualification.run.id,
      review: {runId: evidence.artifact.run.id, artifactId: evidence.artifact.artifact.id,
        sha256: sha256(evidence.artifact.bytes)}, observationsSha256: sha256(Buffer.from(JSON.stringify(after)))};
    return {record, evidence: Buffer.from(JSON.stringify({record, observations: after})), ...evidence};
  };
}

export async function admitHorosLanding({candidate: provided, number, landedRunId}, input) {
  const candidate = candidateCopy(provided);
  const options = admissionOptions(input), client = options.client;
  assert.equal(proposalCommitOid(candidate), oid(candidate.head));
  const repository = await get(client, '');
  assert.equal(repository.full_name, repositoryName); assert.equal(repository.id, repositoryId);
  const pull = await get(client, `/pulls/${identifier(number)}`);
  assert.equal(pull.merged, true); assert.equal(pull.state, 'closed');
  assert.ok(Number.isFinite(Date.parse(pull.merged_at)));
  assert.equal(pull.head.sha, candidate.head); assert.equal(pull.base.ref, 'main');
  assert.equal(pull.base.repo.id, repositoryId); assert.equal(pull.head.repo.id, repositoryId);
  const commits = await pages(client, `/pulls/${number}/commits`);
  assert.equal(commits.length, 1, 'landing requires the admitted single-commit proposal');
  assert.equal(commits[0].sha, candidate.head);
  const original = await get(client, `/git/commits/${candidate.head}`);
  assert.equal(original.sha, candidate.head); assert.equal(original.tree.sha, candidate.tree);
  assert.deepEqual(original.parents.map(value => value.sha), [candidate.base]);
  const landed = oid(pull.merge_commit_sha), actual = await get(client, `/git/commits/${landed}`);
  assert.equal(actual.sha, landed); assert.equal(actual.tree.sha, candidate.tree, 'landed source differs from reviewed proposal');
  assert.deepEqual(actual.parents.map(value => value.sha), [candidate.base], 'landed base changed; owner successor mapping required');
  const main = await get(client, '/git/ref/heads/main');
  assert.equal(main.ref, 'refs/heads/main'); assert.equal(main.object.type, 'commit');
  const comparison = await get(client, `/compare/${landed}...${oid(main.object.sha)}`);
  assert.equal(comparison.base_commit.sha, landed); assert.equal(comparison.merge_base_commit.sha, landed);
  assert.ok(['ahead', 'identical'].includes(comparison.status), 'landed commit is outside accepted main lineage');
  if (comparison.status === 'identical') assert.equal(main.object.sha, landed);
  await acceptedDefinitions(client, candidate, options.expected);
  await options.admitCandidate({candidate: candidateCopy(candidate), pull: structuredClone(pull)});
  const evidence = await reviewedEvidence({candidate, pull, qualificationRunId: options.qualificationRunId}, options);
  const qualification = await admitHorosQualification({runId: identifier(landedRunId),
    commit: landed, tree: actual.tree.sha, event: 'push'}, options.command);
  assert.equal(qualification.workflow.sha256, options.expected.qualificationWorkflow.sha256);
  assert.notEqual(qualification.run.id, evidence.qualification.run.id, 'landed qualification must be independent');
  const record = {schema: 'repository-landing/v1', repository: repositoryName, pull: number,
    reviewed: {base: candidate.base, head: candidate.head, tree: candidate.tree},
    landed: {commit: landed, tree: actual.tree.sha, parent: candidate.base},
    correspondence: 'merged-single-commit-same-parent-and-tree',
    reviewArtifact: {runId: evidence.artifact.run.id, artifactId: evidence.artifact.artifact.id,
      sha256: sha256(evidence.artifact.bytes)},
    originalQualificationRunId: evidence.qualification.run.id, landedQualificationRunId: qualification.run.id,
    impact: evidence.review.context.impact};
  return {record, evidence: Buffer.from(JSON.stringify({record, pull, original, actual, comparison})),
    review: evidence.review, reviewArtifact: evidence.artifact, qualification};
}
