import assert from 'node:assert/strict';
import test from 'node:test';
import {reviewArchives, verifyToolArchive} from './review-tools.mjs';
import {sha256} from './encoding.mjs';

test('review installers pin complete release bytes independently of download metadata', () => {
  const bytes = Buffer.from('test-only archive');
  const expected = {size: bytes.length, sha256: sha256(bytes)};
  verifyToolArchive(bytes, expected);
  assert.throws(() => verifyToolArchive(Buffer.from('changed'), expected));
  assert.throws(() => verifyToolArchive(Buffer.from('x'.repeat(bytes.length)), expected));
  assert.match(reviewArchives.cas.url, /cas-v0\.8\.4\/cas-v0\.8\.4-linux-x86_64\.tar\.gz$/);
  assert.match(reviewArchives.codex.url, /rust-v0\.166\.0\/codex-x86_64-unknown-linux-musl\.tar\.gz$/);
  assert.equal(new Set(reviewArchives.cas.members).size, reviewArchives.cas.members.length);
});
