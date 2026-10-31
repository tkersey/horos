import assert from 'node:assert/strict';
import {existsSync, lstatSync, mkdirSync, opendirSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync} from 'node:fs';
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

function statePath(root, path) {
  safePath(path);
  const parts = path.split('/');
  let current = root, stat;
  for (let index = 0; index < parts.length; index++) {
    current = join(current, parts[index]);
    try {stat = lstatSync(current);}
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    assert.ok(!stat.isSymbolicLink(), 'symlink in active review state');
    if (index + 1 < parts.length) assert.ok(stat.isDirectory(), 'non-directory active state ancestor');
  }
  return stat;
}

function collect(root, path, entries, totals) {
  try {
    assert.ok(performance.now() < totals.deadline, 'review evidence retention deadline exhausted');
    const stat = statePath(root, path);
    if (stat === null) return;
    if (stat.isDirectory()) {
      const directory = opendirSync(join(root, path));
      try {
        for (let child = directory.readSync(); child !== null; child = directory.readSync()) {
          if (totals.exhausted) break;
          totals.paths += Buffer.byteLength(child.name) + 1;
          assert.ok(totals.paths <= maximumRawBytes, 'active review path capacity exceeded');
          collect(root, `${path}/${child.name}`, entries, totals);
        }
      } finally {directory.closeSync();}
      return;
    }
    assert.ok(stat.isFile(), 'nonregular active review state');
    if (entries.has(path)) return;
    assert.ok(entries.size < 8192, 'active review file capacity exceeded');
    const bytes = readRegular(join(root, path), Math.min(64 * 1024 * 1024, maximumRawBytes - totals.bytes));
    totals.bytes += bytes.length;
    entries.set(path, {path, sha256: sha256(bytes), bytes: bytes.toString('base64')});
  } catch (error) {
    if (!totals.errors) throw error;
    totals.errors.push({path, reason: String(error.message).slice(0, 4096)});
    if (totals.errors.length >= 128 || performance.now() >= totals.deadline || entries.size >= 8192 || totals.bytes >= maximumRawBytes || totals.paths > maximumRawBytes) totals.exhausted = true;
  }
}

function collectRuntime(root, directory, entries, totals) {
  collect(root, `${directory}/sessions`, entries, totals);
  if (statePath(root, directory) === null) return;
  const handle = opendirSync(join(root, directory));
  try {
    for (let child = handle.readSync(); child !== null && !totals.exhausted; child = handle.readSync()) {
      assert.ok(performance.now() < totals.deadline, 'review evidence retention deadline exhausted');
      totals.paths += Buffer.byteLength(child.name) + 1;
      assert.ok(totals.paths <= maximumRawBytes, 'active review path capacity exceeded');
      if (/^state_[0-9]+\.sqlite(?:-wal|-shm)?$/.test(child.name) || child.name === 'session_index.jsonl') {
        collect(root, `${directory}/${child.name}`, entries, totals);
      }
    }
  } finally {handle.closeSync();}
}

export function snapshotActiveReview({root: inputRoot, base, head, thread, deadline = performance.now() + 60000}) {
  const root = realpathSync(inputRoot);
  assert.match(base, /^[0-9a-f]{40}$/); assert.match(head, /^[0-9a-f]{40}$/);
  assert.match(thread, /^[0-9a-f-]{36}$/);
  const entries = new Map(), totals = {bytes: 0, paths: 0, deadline};
  collect(root, 'captures', entries, totals);
  for (const entry of entries.values()) {
    if (!entry.path.endsWith('/owner-final.json')) continue;
    const output = parseEvidenceJson(Buffer.from(entry.bytes, 'base64'));
    assert.equal(output.schema, 'repository-review-owner/v1');
    assert.equal(output.base, base); assert.equal(output.head, head);
    assert.equal(output.policySha256, reviewPolicyDigest);
  }
  assert.ok(entries.size > 0, 'missing owner captures');
  collect(root, 'workspace/cas', entries, totals);
  collectRuntime(root, 'home/.codex', entries, totals);
  collectRuntime(root, 'workspace/reviewer-home', entries, totals);
  const bytes = Buffer.from(JSON.stringify({schema: 'repository-active-review/v1', root, base, head, thread,
    policySha256: reviewPolicyDigest, files: [...entries.values()].sort((a, b) => a.path.localeCompare(b.path, 'en'))}));
  assert.ok(bytes.length <= maximumEncodedBytes);
  return gzipSync(bytes, {level: 6});
}

export function snapshotReviewDiagnostic({root: inputRoot, captureRoot, base, head, reason, deadline = performance.now() + 60000}) {
  const root = realpathSync(inputRoot), entries = new Map();
  const totals = {bytes: 0, paths: 0, deadline, errors: [], exhausted: false};
  const capture = relative(root, captureRoot);
  collect(root, capture, entries, totals);
  for (const path of ['workspace/cas', 'captures']) {
    if (!totals.exhausted) collect(root, path, entries, totals);
  }
  for (const directory of ['home/.codex', 'workspace/reviewer-home']) {
    if (totals.exhausted) break;
    try {collectRuntime(root, directory, entries, totals);}
    catch (error) {totals.errors.push({path: directory, reason: String(error.message).slice(0, 4096)});}
  }
  const bytes = Buffer.from(JSON.stringify({schema: 'repository-review-diagnostic/v1', base, head, reason,
    errors: totals.errors, files: [...entries.values()]}));
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
  const files = [], seen = new Set();
  let total = 0;
  for (const file of record.files) {
    safePath(file.path);
    assert.ok(!seen.has(file.path), 'duplicate state path'); seen.add(file.path);
    const allowed = file.path.startsWith('captures/') || file.path.startsWith('workspace/cas/') ||
      file.path.startsWith('home/.codex/sessions/') || file.path.startsWith('workspace/reviewer-home/sessions/') ||
      /^(?:home\/\.codex|workspace\/reviewer-home)\/(?:state_[0-9]+\.sqlite(?:-wal|-shm)?|session_index\.jsonl)$/.test(file.path);
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
