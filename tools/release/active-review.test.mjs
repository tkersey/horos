import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {gzipSync, gunzipSync} from 'node:zlib';
import test from 'node:test';
import {snapshotActiveReview, restoreActiveReview} from './active-review.mjs';
import {reviewPolicyDigest} from './review-owner.mjs';
import {sha256} from './encoding.mjs';

function fixture() {
  const parent = mkdtempSync(join(tmpdir(), 'horos-active-review-')), root = join(parent, 'owner');
  const expected = {root, base: 'a'.repeat(40), head: 'b'.repeat(40), thread: '01234567-0123-4567-89ab-0123456789ab'};
  for (const path of ['captures/000', 'home/.codex/sessions', 'workspace/cas', 'workspace/reviewer-home/sessions', 'workspace/cache']) {
    mkdirSync(join(root, path), {recursive: true});
  }
  writeFileSync(join(root, 'captures/000/owner-final.json'), JSON.stringify({schema: 'repository-review-owner/v1',
    base: expected.base, head: expected.head, policySha256: reviewPolicyDigest, status: 'pending', requests: []}));
  writeFileSync(join(root, 'home/.codex/sessions/owner.jsonl'), 'original runtime history\n');
  writeFileSync(join(root, 'home/.codex/auth.json'), 'test private credential');
  writeFileSync(join(root, 'workspace/reviewer-home/auth.json'), 'test reviewer credential');
  writeFileSync(join(root, 'workspace/reviewer-home/config.toml'), 'test runtime config');
  writeFileSync(join(root, 'workspace/cache/cache'), 'test cache');
  writeFileSync(join(root, 'workspace/unrelated.mjs'), 'test unrelated model scratch');
  return {parent, expected, root};
}

test('active review state retains runtime continuity but excludes auth, caches and unrelated model scratch', () => {
  const value = fixture();
  try {
    const bytes = snapshotActiveReview(value.expected);
    assert.deepEqual(snapshotActiveReview(value.expected), bytes);
    const raw = gunzipSync(bytes).toString();
    for (const forbidden of ['test private credential', 'test reviewer credential', 'test runtime config', 'test cache', 'test unrelated']) assert.ok(!raw.includes(forbidden));
    const record = JSON.parse(raw);
    assert.deepEqual(record.files.map(file => file.path), ['captures/000/owner-final.json', 'home/.codex/sessions/owner.jsonl']);
    renameSync(value.root, `${value.root}.previous`);
    const result = restoreActiveReview(bytes, value.expected);
    assert.equal(result.thread, value.expected.thread);
    assert.equal(readFileSync(join(value.root, 'home/.codex/sessions/owner.jsonl'), 'utf8'), 'original runtime history\n');
    assert.ok(!existsSync(join(value.root, 'home/.codex/auth.json')));
    assert.throws(() => restoreActiveReview(bytes, value.expected), /destination exists/);
  } finally { rmSync(value.parent, {recursive: true, force: true}); }
});

test('active snapshots reject linked and credential-shaped CAS state', () => {
  const value = fixture();
  try {
    const link = join(value.root, 'workspace/cas/linked');
    symlinkSync(join(value.root, 'home/.codex/auth.json'), link);
    assert.throws(() => snapshotActiveReview(value.expected), /symlink/);
    rmSync(link);
    writeFileSync(join(value.root, 'workspace/cas/auth.json'), 'secret');
    assert.throws(() => snapshotActiveReview(value.expected), /credentials/);
  } finally { rmSync(value.parent, {recursive: true, force: true}); }
});

test('restoration rejects wrong subjects, traversal, executable scratch and altered bytes before exposing output', () => {
  for (const mutate of [
    record => {record.head = 'f'.repeat(40);},
    record => {record.files[0].path = '../escaped';},
    record => {record.files[0].path = 'workspace/execute.mjs';},
    record => {record.files[0].bytes = Buffer.from('changed').toString('base64');},
    record => {record.files.push({...record.files[0]});},
    record => {record.files.push({path: 'home/.codex/auth.json', bytes: Buffer.from('auth').toString('base64'), sha256: sha256(Buffer.from('auth'))});},
  ]) {
    const value = fixture();
    try {
      const record = JSON.parse(gunzipSync(snapshotActiveReview(value.expected)));
      renameSync(value.root, `${value.root}.previous`);
      mutate(record);
      assert.throws(() => restoreActiveReview(gzipSync(Buffer.from(JSON.stringify(record))), value.expected));
      assert.ok(!existsSync(value.root));
    } finally { rmSync(value.parent, {recursive: true, force: true}); }
  }
});
