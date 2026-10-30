import assert from 'node:assert/strict';
import {existsSync, lstatSync, mkdirSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import {basename, dirname, join, relative, resolve, sep} from 'node:path';
import {gzipSync, gunzipSync} from 'node:zlib';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRegular, reviewPolicyDigest} from './review-owner.mjs';
import {sha256} from './encoding.mjs';

const maximumRawBytes = 128 * 1024 * 1024;
const maximumEncodedBytes = 192 * 1024 * 1024;

function safePath(path) {
  assert.ok(typeof path === 'string' && path.length > 0 && path.length <= 1024 && !/[\x00-\x20\x7f\\]/.test(path));
  assert.ok(!path.startsWith('/') && path.split('/').every(part => part !== '.' && part !== '..' && part.length > 0));
  assert.ok(!path.split('/').some(part => ['auth.json', 'config.toml', '.env'].includes(part)), 'credentials or configuration in active state');
}

function collect(root, path, entries, totals) {
  safePath(path);
  if (!existsSync(join(root, path))) return;
  const stat = lstatSync(join(root, path));
  assert.ok(!stat.isSymbolicLink(), 'symlink in active review state');
  if (stat.isDirectory()) {
    for (const child of readdirSync(join(root, path)).sort()) collect(root, `${path}/${child}`, entries, totals);
    return;
  }
  assert.ok(stat.isFile(), 'nonregular active review state');
  assert.ok(entries.size < 8192, 'active review file capacity exceeded');
  const bytes = readRegular(join(root, path), 64 * 1024 * 1024);
  totals.bytes += bytes.length;
  assert.ok(totals.bytes <= maximumRawBytes, 'active review state capacity exceeded');
  assert.ok(!entries.has(path), 'duplicate active state path');
  entries.set(path, {path, sha256: sha256(bytes), bytes: bytes.toString('base64')});
}

function collectRuntime(root, directory, entries, totals) {
  collect(root, `${directory}/sessions`, entries, totals);
  if (!existsSync(join(root, directory))) return;
  for (const name of readdirSync(join(root, directory)).sort()) {
    if (/^state_[0-9]+\.sqlite(?:-wal|-shm)?$/.test(name) || name === 'session_index.jsonl') {
      collect(root, `${directory}/${name}`, entries, totals);
    }
  }
}

export function snapshotActiveReview({root: inputRoot, base, head, thread}) {
  const root = realpathSync(inputRoot);
  assert.match(base, /^[0-9a-f]{40}$/); assert.match(head, /^[0-9a-f]{40}$/);
  assert.match(thread, /^[0-9a-f-]{36}$/);
  const entries = new Map(), totals = {bytes: 0};
  collect(root, 'captures', entries, totals);
  const receiptPaths = new Set();
  for (const entry of entries.values()) {
    if (!entry.path.endsWith('/owner-final.json')) continue;
    const output = parseEvidenceJson(Buffer.from(entry.bytes, 'base64'));
    assert.equal(output.schema, 'repository-review-owner/v1');
    assert.equal(output.base, base); assert.equal(output.head, head);
    assert.equal(output.policySha256, reviewPolicyDigest);
    for (const request of output.requests) {
      for (const path of [request.receipt, request.start_receipt, ...(request.prior_receipts ?? [])].filter(Boolean)) {
        safePath(path);
        assert.ok(!['reviewer-home', 'cache', 'tmp', 'cas'].includes(path.split('/')[0]), 'receipt overlaps private runtime state');
        receiptPaths.add(`workspace/${path}`);
      }
    }
  }
  assert.ok(entries.size > 0, 'missing owner captures');
  for (const path of receiptPaths) {
    const value = parseEvidenceJson(readRegular(join(root, path), 8 * 1024 * 1024));
    assert.ok(['start', 'wait'].includes(value.action), 'not an original CAS receipt');
    collect(root, path, entries, totals);
  }
  collect(root, 'workspace/cas', entries, totals);
  collectRuntime(root, 'home/.codex', entries, totals);
  collectRuntime(root, 'workspace/reviewer-home', entries, totals);
  const bytes = Buffer.from(JSON.stringify({schema: 'repository-active-review/v1', root, base, head, thread,
    policySha256: reviewPolicyDigest, files: [...entries.values()].sort((a, b) => a.path.localeCompare(b.path, 'en'))}));
  assert.ok(bytes.length <= maximumEncodedBytes);
  return gzipSync(bytes, {level: 6});
}

export function restoreActiveReview(bytes, {root: inputRoot, base, head}) {
  assert.ok(Buffer.isBuffer(bytes) && bytes.length <= maximumRawBytes);
  const record = parseEvidenceJson(gunzipSync(bytes, {maxOutputLength: maximumEncodedBytes}), maximumEncodedBytes);
  const requested = resolve(inputRoot), root = join(realpathSync(dirname(requested)), basename(requested));
  assert.equal(record.schema, 'repository-active-review/v1');
  assert.equal(record.root, root, 'review state cannot move to another execution root');
  assert.equal(record.base, base); assert.equal(record.head, head);
  assert.equal(record.policySha256, reviewPolicyDigest);
  assert.match(record.thread, /^[0-9a-f-]{36}$/);
  assert.ok(Array.isArray(record.files) && record.files.length > 0 && record.files.length <= 8192);
  const receiptPaths = new Set();
  for (const file of record.files) {
    if (!file.path.startsWith('captures/') || !file.path.endsWith('/owner-final.json')) continue;
    const output = parseEvidenceJson(Buffer.from(file.bytes, 'base64'));
    assert.equal(output.base, base); assert.equal(output.head, head);
    for (const request of output.requests) {
      for (const path of [request.receipt, request.start_receipt, ...(request.prior_receipts ?? [])].filter(Boolean)) {
        safePath(path); receiptPaths.add(`workspace/${path}`);
      }
    }
  }
  const files = [], seen = new Set();
  let total = 0;
  for (const file of record.files) {
    safePath(file.path);
    assert.ok(!seen.has(file.path), 'duplicate state path'); seen.add(file.path);
    const allowed = file.path.startsWith('captures/') || file.path.startsWith('workspace/cas/') ||
      file.path.startsWith('home/.codex/sessions/') || file.path.startsWith('workspace/reviewer-home/sessions/') ||
      /^(?:home\/\.codex|workspace\/reviewer-home)\/(?:state_[0-9]+\.sqlite(?:-wal|-shm)?|session_index\.jsonl)$/.test(file.path) ||
      receiptPaths.has(file.path);
    assert.ok(allowed, 'unexpected active state file');
    assert.equal(typeof file.bytes, 'string');
    const content = Buffer.from(file.bytes, 'base64');
    assert.equal(content.toString('base64'), file.bytes);
    assert.equal(sha256(content), file.sha256, 'active state bytes changed');
    total += content.length; assert.ok(total <= maximumRawBytes);
    files.push({path: file.path, content});
  }
  assert.ok(!existsSync(root), 'active state destination exists');
  const stage = `${root}.restore`;
  mkdirSync(stage, {mode: 0o700});
  try {
    for (const file of files) {
      const target = join(stage, file.path);
      const distance = relative(stage, target);
      assert.ok(distance !== '..' && !distance.startsWith(`..${sep}`));
      mkdirSync(dirname(target), {recursive: true, mode: 0o700});
      writeFileSync(target, file.content, {flag: 'wx', mode: 0o600});
    }
    for (const path of ['workspace/tmp', 'workspace/cache', 'workspace/reviewer-home', 'home/.codex']) {
      mkdirSync(join(stage, path), {recursive: true, mode: 0o700});
    }
    renameSync(stage, root);
  } catch (error) {
    rmSync(stage, {recursive: true, force: true});
    throw error;
  }
  return {thread: record.thread, captures: readdirSync(join(root, 'captures')).sort().map(name => join(root, 'captures', name))};
}
