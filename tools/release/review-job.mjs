import assert from 'node:assert/strict';
import {existsSync, mkdirSync, readdirSync, rmSync, writeFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {gzipSync} from 'node:zlib';
import {invokeOwner, readRegular} from './review-owner.mjs';
import {snapshotActiveReview, restoreActiveReview} from './active-review.mjs';
import {reviewEnvelope, reviewNames} from './review-result.mjs';
import {sha256} from './encoding.mjs';

export async function executeReviewTurn({root: inputRoot, outputDirectory, repositoryPath, context, tools,
  authentication, settings, previous = null, activeState = null, timeoutMs = 540000, deadline}, invoke = invokeOwner) {
  const root = resolve(inputRoot), names = reviewNames(context.base, context.head, context.bootstrap ? 'bootstrap' : 'pull');
  assert.ok(Buffer.isBuffer(authentication) && authentication.length > 0 && authentication.length <= 1024 * 1024);
  assert.ok(context.repository === 'tkersey/horos');
  assert.match(context.tree, /^[0-9a-f]{40}$/);
  const turn = previous === null ? 1 : previous.envelope.turn + 1;
  assert.ok(turn <= 64, 'owner active-state turn capacity exceeded');
  let previousCaptures = [];
  if (previous !== null) {
    assert.equal(previous.status, 'pending');
    assert.deepEqual(previous.envelope.context, context, 'frozen owner inputs changed');
    assert.equal(sha256(activeState), previous.envelope.stateSha256);
    previousCaptures = restoreActiveReview(activeState, {root, base: context.base, head: context.head}).captures;
  } else {
    assert.equal(activeState, null);
    mkdirSync(root, {mode: 0o700});
    mkdirSync(join(root, 'captures'), {mode: 0o700});
    mkdirSync(join(root, 'home/.codex'), {recursive: true, mode: 0o700});
  }
  mkdirSync(outputDirectory, {recursive: true, mode: 0o700});
  const authPath = join(root, 'home/.codex/auth.json'), contextPath = join(root, 'context.json');
  assert.ok(!existsSync(authPath), 'unexpected retained authentication');
  writeFileSync(authPath, authentication, {flag: 'wx', mode: 0o600});
  writeFileSync(contextPath, JSON.stringify(context), {flag: 'wx', mode: 0o400});
  const captureRoot = join(root, 'captures', String(turn).padStart(3, '0'));
  const envelope = {schema: 'repository-review-result/v1', context, status: 'blocked', reason: 'Owner did not finish.',
    epochClosed: false, turn, previousSha256: previous === null ? null : sha256(previous.bytes), stateSha256: null, retainedEvidence: null};
  try {
    const result = await invoke({...tools, ...settings, workspace: join(root, 'workspace'), captureRoot,
      reviewHome: join(root, 'home'), repository: repositoryPath, contextPath,
      base: context.base, head: context.head, previousCaptures, path: process.env.PATH, timeoutMs, deadline});
    envelope.status = result.output.status;
    envelope.epochClosed = result.output.epochClosed;
    envelope.reason = result.output.closureBasis;
    if (envelope.status === 'pending') {
      const state = snapshotActiveReview({root, base: context.base, head: context.head, thread: result.thread});
      writeFileSync(join(outputDirectory, names.state), state, {flag: 'wx', mode: 0o600});
      envelope.stateSha256 = sha256(state);
    } else if (envelope.status === 'complete') {
      envelope.retainedEvidence = readRegular(join(captureRoot, 'review-evidence.json'), 64 * 1024 * 1024).toString('base64');
    }
  } catch (error) {
    envelope.status = 'blocked'; envelope.epochClosed = false; envelope.stateSha256 = null; envelope.retainedEvidence = null;
    envelope.reason = `Owner invocation requires original-evidence recovery: ${String(error.message).slice(0, 12000)}`;
  } finally {
    rmSync(authPath, {force: true});
    rmSync(join(root, 'workspace/reviewer-home/auth.json'), {force: true});
  }
  if (envelope.status === 'blocked' && existsSync(captureRoot)) {
    let total = 0;
    const files = readdirSync(captureRoot).sort().map(name => {
      const bytes = readRegular(join(captureRoot, name), 64 * 1024 * 1024);
      total += bytes.length; assert.ok(total <= 128 * 1024 * 1024);
      return {name, sha256: sha256(bytes), bytes: bytes.toString('base64')};
    });
    const diagnostic = gzipSync(Buffer.from(JSON.stringify({schema: 'repository-review-diagnostic/v1',
      base: context.base, head: context.head, reason: envelope.reason, files})));
    writeFileSync(join(outputDirectory, names.diagnostic), diagnostic, {flag: 'wx', mode: 0o600});
  }
  const bytes = Buffer.from(JSON.stringify(envelope));
  reviewEnvelope(bytes, context);
  writeFileSync(join(outputDirectory, names.result), bytes, {flag: 'wx', mode: 0o600});
  return {status: envelope.status, reason: envelope.reason, resultPath: join(outputDirectory, names.result),
    statePath: envelope.status === 'pending' ? join(outputDirectory, names.state) : null};
}
