import assert from 'node:assert/strict';
import {workflowPages} from './workflow-artifact.mjs';
import {readReviewResult} from './review-result.mjs';
import {repositories} from './record.mjs';
import {proposalBranch} from './proposal.mjs';

export async function previousReviewForHead(reader, head, tree, command, subjectBase, readResult = readReviewResult) {
  const artifacts = await workflowPages(reader, 'actions/artifacts', 'artifacts');
  const bases = new Set();
  for (const artifact of artifacts) {
    if (artifact.workflow_run?.repository_id !== repositories[reader.repository] ||
      artifact.workflow_run?.head_repository_id !== repositories[reader.repository] || artifact.workflow_run?.head_branch !== 'main') continue;
    const match = new RegExp(`^review-(?:start-)?([0-9a-f]{40})-${head}\\.json$`).exec(artifact.name);
    if (match) bases.add(match[1]);
  }
  assert.ok(bases.size <= 64, 'review subject history capacity exceeded');
  const previous = [];
  for (const base of bases) {
    const value = await readResult({repository: reader.repository, base, head, tree}, command);
    if (value.status !== 'absent') previous.push({base, value});
  }
  const open = previous.filter(item => item.value.status !== 'complete');
  assert.ok(open.length <= 1, 'multiple unclosed owner subjects; recover original epochs before continuing');
  const selected = open[0] ?? previous.find(item => item.base === subjectBase);
  if (selected) return selected;
  if (bases.has(subjectBase)) return null;
  const value = await readResult({repository: reader.repository, base: subjectBase, head, tree}, command);
  return value.status === 'absent' ? null : {base: value.invocation?.base ?? subjectBase, value};
}

export async function resolveReviewSubject(reader, pull, commit, controlCommit, command, previousReader = previousReviewForHead) {
  const head = pull.head.sha, tree = commit.tree.sha;
  let subjectBase = controlCommit;
  if (pull.head.ref === proposalBranch) {
    assert.equal(commit.parents?.length, 1, 'generated proposal must have one immutable Git parent');
    subjectBase = commit.parents[0].sha;
    assert.match(subjectBase, /^[0-9a-f]{40}$/);
  }
  if (subjectBase !== controlCommit) assert.ok(await reader.forward(subjectBase, controlCommit),
    'current review control predates or diverges from original candidate base');
  const prior = await previousReader(reader, head, tree, command, subjectBase);
  const base = prior && prior.value.status !== 'complete' ? prior.base : subjectBase;
  if (base !== subjectBase && base !== controlCommit) assert.ok(await reader.forward(base, controlCommit),
    'current review control predates or diverges from pending owner subject');
  return {base, prior};
}
