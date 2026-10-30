import assert from 'node:assert/strict';
import test from 'node:test';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {executeReviewTurn} from './review-job.mjs';
import {runOwnerProcess, ownerTurnDeadline, remainingOwnerTime, ownerStepTimeoutMs, ownerJobTimeoutMs, ownerCleanupMs} from './owner-process.mjs';
import {reviewEnvelope, reviewNames} from './review-result.mjs';
import {reviewPolicyDigest} from './review-owner.mjs';

const context = {repository: 'tkersey/horos', base: 'a'.repeat(40), head: 'b'.repeat(40), tree: 'c'.repeat(40)};
const thread = '01234567-0123-4567-89ab-0123456789ab';

function scratch() {
  const directory = mkdtempSync(join(tmpdir(), 'horos-review-job-'));
  return {directory, options: {root: join(directory, 'active'), outputDirectory: join(directory, 'output'),
    repositoryPath: join(directory, 'candidate'), context, tools: {}, authentication: Buffer.from('secret'), settings: {}}};
}

async function pending(options) {
  mkdirSync(options.captureRoot);
  mkdirSync(options.workspace, {recursive: true});
  mkdirSync(join(options.workspace, 'reviewer-home'), {recursive: true});
  writeFileSync(join(options.workspace, 'reviewer-home/auth.json'), 'reviewer-secret');
  const output = {schema: 'repository-review-owner/v1', status: 'pending', base: context.base, head: context.head,
    policySha256: reviewPolicyDigest, requests: [], epochClosed: false, closureBasis: 'One original owner turn completed.'};
  writeFileSync(join(options.captureRoot, 'owner-final.json'), JSON.stringify(output));
  writeFileSync(join(options.captureRoot, 'owner-events.jsonl'), 'original runtime capture');
  return {thread, output};
}

test('bounded owner turn exports recoverable state, resumes subject, and removes model authentication', async () => {
  const {directory, options} = scratch();
  try {
    const result = await executeReviewTurn(options, pending);
    assert.equal(result.status, 'pending');
    assert.equal(existsSync(join(options.root, 'home/.codex/auth.json')), false);
    assert.equal(existsSync(join(options.root, 'workspace/reviewer-home/auth.json')), false);
    const bytes = readFileSync(result.resultPath), envelope = reviewEnvelope(bytes, context);
    const state = readFileSync(result.statePath);
    rmSync(options.root, {recursive: true});
    let observed = false;
    const resumed = await executeReviewTurn({...options, outputDirectory: join(directory, 'resumed'),
      previous: {status: 'pending', envelope, bytes}, activeState: state}, async values => {
      assert.equal(values.previousCaptures.length, 1);
      assert.equal(readFileSync(join(values.previousCaptures[0], 'owner-events.jsonl'), 'utf8'), 'original runtime capture');
      observed = true;
      return pending(values);
    });
    assert.equal(observed, true); assert.equal(resumed.status, 'pending');
    assert.equal(reviewEnvelope(readFileSync(resumed.resultPath), context).turn, 2);
  } finally {rmSync(directory, {recursive: true, force: true});}
});

test('failed owner process retains diagnostic evidence and blocks without a fresh review or credit', async () => {
  const {directory, options} = scratch();
  try {
    let calls = 0;
    const result = await executeReviewTurn(options, async values => {
      calls++;
      mkdirSync(values.captureRoot);
      writeFileSync(join(values.captureRoot, 'owner-events.jsonl'), 'partial original event');
      throw new Error('transport failed');
    });
    assert.equal(calls, 1); assert.equal(result.status, 'blocked'); assert.equal(result.statePath, null);
    assert.match(result.reason, /transport failed/);
    const envelope = reviewEnvelope(readFileSync(result.resultPath), context);
    assert.equal(envelope.retainedEvidence, null);
    assert.ok(existsSync(join(options.outputDirectory, reviewNames(context.base, context.head).diagnostic)));
    assert.equal(existsSync(join(options.root, 'home/.codex/auth.json')), false);
  } finally {rmSync(directory, {recursive: true, force: true});}
});

test('changed owner input and terminal prior disposition cannot resume', async () => {
  const {directory, options} = scratch();
  try {
    const result = await executeReviewTurn(options, pending);
    const bytes = readFileSync(result.resultPath), envelope = reviewEnvelope(bytes, context), activeState = readFileSync(result.statePath);
    rmSync(options.root, {recursive: true});
    await assert.rejects(executeReviewTurn({...options, context: {...context, tree: 'd'.repeat(40)},
      previous: {status: 'pending', envelope, bytes}, activeState}, pending), /frozen owner inputs/);
    await assert.rejects(executeReviewTurn({...options, previous: {status: 'blocked', envelope, bytes}, activeState}, pending));
  } finally {rmSync(directory, {recursive: true, force: true});}
});

test('result declarations cannot create review credit without original evidence', () => {
  const value = {schema: 'repository-review-result/v1', context, status: 'complete', reason: 'forged clean result',
    epochClosed: true, turn: 1, previousSha256: null, stateSha256: null, retainedEvidence: Buffer.from('{}').toString('base64')};
  assert.throws(() => reviewEnvelope(Buffer.from(JSON.stringify(value)), context));
  value.status = 'pending'; value.epochClosed = false; value.retainedEvidence = null; value.stateSha256 = 'd'.repeat(64);
  assert.equal(reviewEnvelope(Buffer.from(JSON.stringify(value)), context).status, 'pending');
  assert.throws(() => reviewEnvelope(Buffer.from(JSON.stringify(value)), {...context, head: 'e'.repeat(40)}));
});

test('owner deadline includes elapsed setup and reserves cleanup within both workflow limits', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/repository-review.yml', import.meta.url), 'utf8');
  assert.match(workflow, new RegExp('name: Owner review[\\s\\S]*?timeout-minutes: '+ownerJobTimeoutMs / 60000));
  assert.match(workflow, new RegExp('name: Execute one ordinary owner turn[\\s\\S]*?timeout-minutes: '+ownerStepTimeoutMs / 60000));
  const wallNow = 1800000000000, monotonicNow = 100000, stepStarted = 10000;
  const stepLimited = ownerTurnDeadline({stepStarted, jobStarted: wallNow - 90000, wallNow, monotonicNow});
  assert.equal(stepLimited, stepStarted + ownerStepTimeoutMs - ownerCleanupMs);
  const jobLimited = ownerTurnDeadline({stepStarted, jobStarted: wallNow - 420000, wallNow, monotonicNow});
  assert.equal(jobLimited, monotonicNow + 120000);
  assert.equal(remainingOwnerTime(480000, jobLimited, monotonicNow + 10000), 110000);
  assert.equal(remainingOwnerTime(480000, jobLimited, jobLimited + 1), 0);
  assert.throws(() => ownerTurnDeadline({stepStarted, jobStarted: NaN, wallNow, monotonicNow}));
});

test('hung owner is killed before the enclosing deadline and retains its original diagnostic', async () => {
  const {directory, options} = scratch(), started = performance.now();
  try {
    const result = await executeReviewTurn({...options, timeoutMs: ownerCleanupMs / 2, deadline: started + 800}, async values => {
      await new Promise(resolve => setTimeout(resolve, 75));
      mkdirSync(values.captureRoot); mkdirSync(values.workspace, {recursive: true});
      const processResult = await runOwnerProcess('/bin/sh',
        ['-c', "trap '' TERM; printf 'original event\\n'; while :; do /bin/sleep 10; done"],
        {...values, env: {}, input: ''});
      writeFileSync(join(values.captureRoot, 'process.json'), JSON.stringify(processResult));
      assert.equal(processResult.failure, 'deadline');
      assert.equal(processResult.signal, 'SIGKILL');
      throw new Error('owner deadline retained');
    });
    assert.equal(result.status, 'blocked'); assert.match(result.reason, /owner deadline retained/);
    assert.ok(performance.now() - started < ownerCleanupMs / 4, 'owner ignored the enclosing deadline');
    assert.equal(existsSync(join(options.root, 'home/.codex/auth.json')), false);
    assert.ok(existsSync(join(options.outputDirectory, reviewNames(context.base, context.head).diagnostic)));
    assert.match(readFileSync(join(options.root, 'captures/001/owner-events.jsonl'), 'utf8'), /original event/);
    assert.equal(reviewEnvelope(readFileSync(result.resultPath), context).epochClosed, false);
  } finally {rmSync(directory, {recursive: true, force: true});}
});
