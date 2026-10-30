import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {closeSync, openSync, writeSync} from 'node:fs';
import {join} from 'node:path';

export const ownerStepTimeoutMs = 480000, ownerJobTimeoutMs = 600000, ownerCleanupMs = 60000;

export function ownerTurnDeadline({stepStarted, jobStarted, wallNow = Date.now(), monotonicNow = performance.now()}) {
  for (const value of [stepStarted, jobStarted, wallNow, monotonicNow]) assert.ok(Number.isFinite(value));
  assert.ok(jobStarted > 0 && jobStarted <= wallNow, 'invalid original owner job start');
  return Math.min(stepStarted + ownerStepTimeoutMs, monotonicNow + jobStarted + ownerJobTimeoutMs - wallNow) - ownerCleanupMs;
}

export function remainingOwnerTime(timeoutMs = 540000, deadline, now = performance.now()) {
  assert.ok(Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= 540000);
  if (deadline === undefined) return timeoutMs;
  assert.ok(Number.isFinite(deadline) && Number.isFinite(now));
  return Math.max(0, Math.floor(Math.min(timeoutMs, deadline - now)));
}

export async function runOwnerProcess(command, args, {workspace, captureRoot, env, input, timeoutMs = 540000, deadline, maximumBytes = 64 * 1024 * 1024}) {
  assert.ok(['darwin', 'linux'].includes(process.platform));
  assert.ok(Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= 540000);
  assert.ok(Number.isSafeInteger(maximumBytes) && maximumBytes > 0 && maximumBytes <= 64 * 1024 * 1024);
  const stdout = openSync(join(captureRoot, 'owner-events.jsonl'), 'wx', 0o600);
  let stderr;
  try {
    stderr = openSync(join(captureRoot, 'owner-stderr.txt'), 'wx', 0o600);
    if (remainingOwnerTime(timeoutMs, deadline) === 0) return {code: null, signal: null, failure: 'deadline'};
    return await new Promise(resolve => {
      const child = spawn(command, args, {cwd: workspace, env, stdio: ['pipe', 'pipe', 'pipe'], detached: true});
      let failure = null, timer, escalation, total = 0;
      const kill = signal => {
        if (!child.pid) return;
        try { process.kill(-child.pid, signal); }
        catch (error) { if (error.code !== 'ESRCH') failure ??= `cleanup:${error.code}`; }
      };
      const stop = reason => {
        if (failure) return;
        failure = reason;
        kill('SIGTERM');
        escalation = setTimeout(() => kill('SIGKILL'), 1000);
      };
      const retain = (descriptor, bytes) => {
        total += bytes.length;
        if (total > maximumBytes) return stop('output-limit');
        try { assert.equal(writeSync(descriptor, bytes), bytes.length, 'short evidence write'); }
        catch (error) { stop(`output:${error.code}`); }
      };
      child.stdout.on('data', bytes => retain(stdout, bytes));
      child.stderr.on('data', bytes => retain(stderr, bytes));
      child.stdin.on('error', error => { if (error.code !== 'EPIPE') stop(`input:${error.code}`); });
      child.once('error', error => { failure ??= `spawn:${error.code}`; });
      child.once('close', (code, signal) => {
        clearTimeout(timer);
        clearTimeout(escalation);
        kill('SIGKILL');
        resolve({code, signal, failure});
      });
      timer = setTimeout(() => stop('deadline'), remainingOwnerTime(timeoutMs, deadline));
      child.stdin.end(input);
    });
  } finally {
    closeSync(stdout);
    if (stderr !== undefined) closeSync(stderr);
  }
}
