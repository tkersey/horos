import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {closeSync, openSync, writeSync} from 'node:fs';
import {join} from 'node:path';

export async function runOwnerProcess(command, args, {workspace, captureRoot, env, input, timeoutMs = 540000, maximumBytes = 64 * 1024 * 1024}) {
  assert.ok(['darwin', 'linux'].includes(process.platform));
  assert.ok(Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= 540000);
  assert.ok(Number.isSafeInteger(maximumBytes) && maximumBytes > 0 && maximumBytes <= 64 * 1024 * 1024);
  const stdout = openSync(join(captureRoot, 'owner-events.jsonl'), 'wx', 0o600);
  let stderr;
  try {
    stderr = openSync(join(captureRoot, 'owner-stderr.txt'), 'wx', 0o600);
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
      timer = setTimeout(() => stop('deadline'), timeoutMs);
      child.stdin.end(input);
    });
  } finally {
    closeSync(stdout);
    if (stderr !== undefined) closeSync(stderr);
  }
}
