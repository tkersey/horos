import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtempSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRegular} from './review-owner.mjs';
import {parseVersion} from './version.mjs';
import {rootTree, proposalCommitOid, proposalDescription, proposalMessage} from './proposal.mjs';

const blobOid = bytes => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');

export function manifestOperations(path) {
  const tool = realpathSync(path), digest = sha256(readRegular(tool, 32 * 1024 * 1024));
  const invoke = (bytes, version = null) => {
    assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 1024 * 1024);
    const directory = mkdtempSync(join(tmpdir(), 'horos-manifest-'));
    try {
      const input = join(directory, 'base.zon'), output = join(directory, 'candidate.zon');
      writeFileSync(input, bytes, {flag: 'wx', mode: 0o600});
      assert.equal(sha256(readRegular(tool, 32 * 1024 * 1024)), digest, 'trusted native manifest tool changed');
      const args = version === null ? ['read', input] : ['prepare', input, version, output];
      if (version !== null) parseVersion(version);
      const result = parseEvidenceJson(execFileSync(tool, args, {cwd: directory, encoding: 'buffer',
        env: {PATH: process.env.PATH, TMPDIR: directory}, timeout: 30000, maxBuffer: 65536}));
      parseVersion(result.version);
      if (version === null) return result.version;
      assert.equal(result.version, version);
      const prepared = readRegular(output, 1024 * 1024);
      assert.equal(result.changed, !bytes.equals(prepared));
      return prepared;
    } finally { rmSync(directory, {recursive: true, force: true}); }
  };
  return {sha256: digest, read: bytes => invoke(bytes), prepare: (bytes, version) => invoke(bytes, version)};
}

export async function sourceManifest(client, commit) {
  assert.match(commit, /^[0-9a-f]{40}$/);
  const response = await client.request({path: `/contents/build.zig.zon?ref=${commit}`});
  assert.equal(response.status, 200);
  const value = response.body;
  assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
  const bytes = Buffer.from(value.content.replaceAll('\n', ''), 'base64');
  assert.ok(bytes.length > 0 && bytes.length <= 1024 * 1024);
  assert.equal(blobOid(bytes), value.sha, 'manifest Git blob differs');
  return bytes;
}

async function commitTree(client, commit) {
  const response = await client.request({path: `/git/commits/${commit}`});
  assert.equal(response.status, 200); assert.equal(response.body.sha, commit);
  const source = response.body;
  const tree = await client.request({path: `/git/trees/${source.tree.sha}`});
  assert.equal(tree.status, 200); assert.equal(tree.body.truncated, false);
  assert.equal(tree.body.sha, source.tree.sha); assert.equal(rootTree(tree.body.tree), source.tree.sha);
  return {source, entries: tree.body.tree};
}

export async function prepareHorosCandidate({base, version, actor}, {client, native}) {
  const {source, entries} = await commitTree(client, base);
  const bytes = await sourceManifest(client, base);
  const manifestBytes = native.prepare(bytes, version);
  if (manifestBytes.equals(bytes)) return null;
  const manifest = entries.filter(entry => entry.path === 'build.zig.zon');
  assert.equal(manifest.length, 1); assert.equal(manifest[0].mode, '100644'); assert.equal(manifest[0].type, 'blob');
  assert.equal(manifest[0].sha, blobOid(bytes));
  assert.ok(Number.isSafeInteger(actor.id) && actor.id > 0);
  assert.match(actor.login, /^[a-z0-9][a-z0-9-]*\[bot\]$/);
  const person = {name: actor.login, email: `${actor.id}+${actor.login}@users.noreply.github.com`, date: source.committer.date};
  const candidate = {base, tree: rootTree(entries.map(entry => entry.path === 'build.zig.zon' ?
    {...entry, sha: blobOid(manifestBytes)} : entry)), version, manifestBytes, author: person, committer: {...person}};
  candidate.message = proposalMessage(candidate); candidate.head = proposalCommitOid(candidate);
  return candidate;
}

export function admitNativeVersion(native) {
  return async ({candidate, baseManifest}) => {
    assert.equal(native.read(candidate.manifestBytes), candidate.version);
    assert.deepEqual(native.prepare(baseManifest, candidate.version), candidate.manifestBytes, 'candidate is not the native version-only projection');
    assert.ok(!baseManifest.equals(candidate.manifestBytes), 'empty version preparation');
  };
}

export function classifyNativeVersion({client, native, actor}) {
  return async ({subject, pull, baseTree, baseManifestBytes, manifestBytes, originalCommits}) => {
    if (pull.user?.id !== actor.id || pull.user?.login !== actor.login || originalCommits.length !== 1) return {versionOnly: false};
    const version = native.read(manifestBytes), prepared = native.prepare(baseManifestBytes, version);
    if (prepared.equals(baseManifestBytes) || !prepared.equals(manifestBytes)) return {versionOnly: false};
    const candidate = await prepareHorosCandidate({base: subject.base, version, actor}, {client, native});
    assert.equal((await commitTree(client, subject.base)).source.tree.sha, baseTree);
    assert.equal(candidate.head, subject.head, 'generated version source differs'); assert.equal(candidate.tree, subject.tree);
    assert.equal(pull.body, proposalDescription(candidate).body, 'generated version proposal was edited');
    assert.equal(originalCommits[0].message, candidate.message);
    return {versionOnly: true};
  };
}
