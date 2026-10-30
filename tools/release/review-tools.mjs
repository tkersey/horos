import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, lstatSync, readFileSync, realpathSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {sha256} from './encoding.mjs';
import {reviewPolicyCommit, reviewPolicyDigest} from './review-owner.mjs';

export const reviewArchives = Object.freeze({
  cas: Object.freeze({
    url: 'https://github.com/tkersey/skills-zig/releases/download/cas-v0.8.4/cas-v0.8.4-linux-x86_64.tar.gz',
    sha256: '1341dda106c9b6ed736da5c2567e631bb98268586aae8cf18813c64561e58120', size: 32387477,
    binarySha256: '75563ebff7226e8b8586ad7ba92abc55d9eb87329e22fc2ac04cc67332fcfac5',
    members: ['.', 'cas_account', 'cas_instance_runner', 'cas_automation', 'cas_session_inquiry',
      'cas_app_server_preflight', 'cas-session-inquiry', 'cas', 'cas-instance-runner', 'cas-smoke-check',
      'cas_smoke_check', 'cas_review_session', 'cas-review-session', 'cas-goal', 'cas-conformance-suite',
      'cas_goal', 'cas_conformance_suite'],
  }),
  codex: Object.freeze({
    url: 'https://github.com/openai/codex/releases/download/rust-v0.166.0/codex-x86_64-unknown-linux-musl.tar.gz',
    sha256: 'a0bf572d2f93f056c6712a6da348e96078dc84f3885fd7be67807ef389cb3978', size: 121764138,
    binarySha256: 'b8a11fedf24b2dfb59a70c9e52b030f9a508dcd49cd2dd0d41956f4c785156b8',
    members: ['codex-x86_64-unknown-linux-musl'],
  }),
});

export function verifyToolArchive(bytes, expected) {
  assert.ok(Buffer.isBuffer(bytes) && bytes.length === expected.size, 'review tool archive size differs');
  assert.equal(sha256(bytes), expected.sha256, 'review tool archive digest differs');
}

async function download(expected) {
  const response = await fetch(expected.url, {signal: AbortSignal.timeout(120000)});
  assert.equal(response.status, 200, 'review tool download failed');
  const chunks = [];
  let total = 0;
  for await (const chunk of response.body) {
    total += chunk.length;
    assert.ok(total <= expected.size, 'review tool download exceeds expected size');
    chunks.push(Buffer.from(chunk));
  }
  const bytes = Buffer.concat(chunks);
  verifyToolArchive(bytes, expected);
  return bytes;
}

export async function installReviewTools(directory) {
  assert.equal(process.platform, 'linux', 'automated review tools require native Linux');
  assert.equal(process.arch, 'x64', 'automated review tools require native x86-64');
  mkdirSync(directory, {mode: 0o700});
  const root = realpathSync(directory);
  for (const [name, expected] of Object.entries(reviewArchives)) {
    const bytes = await download(expected);
    const archive = join(root, `${name}.tar.gz`), output = join(root, name);
    writeFileSync(archive, bytes, {flag: 'wx', mode: 0o400});
    const entries = execFileSync('tar', ['-tzf', archive], {encoding: 'utf8', maxBuffer: 1024 * 1024, timeout: 30000})
      .trimEnd().split('\n').map(value => value === './' ? '.' : value.replace(/^\.\//, ''));
    assert.deepEqual(entries.sort(), [...expected.members].sort(), 'unexpected review tool archive members');
    mkdirSync(output, {mode: 0o700});
    execFileSync('tar', ['-xzf', archive, '--no-same-owner', '--directory', output], {timeout: 30000});
    for (const entry of entries.filter(value => value !== '.')) {
      const stat = lstatSync(join(output, entry));
      assert.ok(stat.isFile() && !stat.isSymbolicLink(), 'unsupported review tool file');
    }
  }
  const policyDirectory = join(root, 'policy');
  mkdirSync(policyDirectory, {mode: 0o700});
  const git = args => execFileSync('git', ['-c', 'core.hooksPath=/dev/null', '-c', 'protocol.file.allow=never', ...args],
    {cwd: policyDirectory, encoding: 'utf8', timeout: 120000, env: {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null'}}).trimEnd();
  git(['init', '--quiet']);
  git(['fetch', '--quiet', '--depth=1', 'https://github.com/tkersey/dotfiles.git', reviewPolicyCommit]);
  git(['checkout', '--quiet', '--detach', reviewPolicyCommit]);
  assert.equal(git(['rev-parse', 'HEAD']), reviewPolicyCommit);
  assert.equal(sha256(readFileSync(join(policyDirectory, 'agents/skills/actuating/references/review-contract.json'))), reviewPolicyDigest);
  const casPath = join(root, 'cas/cas'), codexPath = join(root, 'codex/codex-x86_64-unknown-linux-musl');
  assert.equal(sha256(readFileSync(casPath)), reviewArchives.cas.binarySha256);
  assert.equal(sha256(readFileSync(codexPath)), reviewArchives.codex.binarySha256);
  assert.equal(execFileSync(casPath, ['--version'], {encoding: 'utf8', timeout: 30000}).trim(), '0.8.4');
  assert.equal(execFileSync(codexPath, ['--version'], {encoding: 'utf8', timeout: 30000}).trim(), 'codex-cli 0.166.0');
  return {casPath, codexPath, policyDirectory, casSha256: sha256(readFileSync(casPath)),
    codexSha256: sha256(readFileSync(codexPath)), archives: Object.fromEntries(Object.entries(reviewArchives).map(([name, value]) => [name, value.sha256]))};
}
