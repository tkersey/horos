import assert from 'node:assert/strict';
import {mkdirSync, realpathSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {GitHubReader, githubCommand} from './github.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRecord} from './record.mjs';
import {sha256} from './encoding.mjs';

export const admissionPredicate = 'https://slsa.dev/provenance/v1';

export function attestationArguments(path, record) {
  const workflow = record.admission.workflow;
  return ['attestation', 'verify', path, '--repo', record.repository.name,
    '--cert-identity', `https://github.com/${record.repository.name}/${workflow.path}@refs/heads/main`,
    '--signer-digest', workflow.commit, '--source-digest', workflow.commit,
    '--source-ref', 'refs/heads/main', '--deny-self-hosted-runners',
    '--predicate-type', admissionPredicate, '--format', 'json'];
}

function positiveId(value) {
  assert.ok(Number.isSafeInteger(value) && value > 0, 'invalid remote identity');
  return value;
}

export async function verifyPublishedAsset(command, repository, tag, path) {
  const bytes = await command(['release', 'verify-asset', tag, path, '--repo', repository, '--format', 'json']);
  assert.ok(Buffer.isBuffer(bytes) && bytes.length > 0 && bytes.length <= 8 * 1024 * 1024, 'missing release attestation result');
  return parseEvidenceJson(bytes);
}

export async function admitPublishedRelease({repository, releaseId, outputDirectory}, command = githubCommand) {
  const reader = new GitHubReader(repository, command);
  await reader.verifyRepository();
  positiveId(releaseId);
  const release = await reader.api(`releases/${releaseId}`);
  assert.equal(release.id, releaseId);
  assert.equal(release.draft, false, 'release is draft');
  assert.equal(release.prerelease, false, 'unsupported prerelease');
  assert.equal(release.immutable, true, 'release is not immutable');
  const assets = [], names = new Set(), ids = new Set();
  for (let page = 1; page <= 3; page++) {
    const values = await reader.api(`releases/${releaseId}/assets?per_page=100&page=${page}`);
    assert.ok(Array.isArray(values) && values.length <= 100);
    for (const asset of values) {
      positiveId(asset.id);
      assert.match(asset.name, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/);
      assert.ok(!names.has(asset.name) && !ids.has(asset.id), 'duplicate release asset');
      assert.equal(asset.state, 'uploaded', 'unfinished asset');
      assert.ok(Number.isSafeInteger(asset.size) && asset.size > 0 && asset.size <= 512 * 1024 * 1024, 'asset exceeds capacity');
      names.add(asset.name); ids.add(asset.id); assets.push(asset);
    }
    if (values.length < 100) break;
    assert.ok(page < 3, 'asset pagination capacity exceeded');
  }
  const recordAsset = assets.find(asset => asset.name === 'release.json');
  assert.ok(recordAsset && recordAsset.size <= 1024 * 1024, 'missing bounded release record');
  const download = async asset => {
    const bytes = await command(['api', `repos/${repository}/releases/assets/${asset.id}`,
      '-H', 'Accept: application/octet-stream'], asset.size + 1);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length === asset.size, 'asset size differs');
    assert.equal(asset.digest, `sha256:${sha256(bytes)}`, 'asset digest differs');
    return bytes;
  };
  const recordBytes = await download(recordAsset);
  const record = readRecord(recordBytes);
  assert.equal(record.repository.name, repository);
  assert.equal(record.tag, release.tag_name);
  assert.equal(await reader.tagCommit(record.tag), record.source.commit, 'published tag source differs');
  const source = await reader.api(`git/commits/${record.source.commit}`);
  assert.equal(source.sha, record.source.commit);
  assert.equal(source.tree.sha, record.source.tree, 'published source tree differs');
  const main = await reader.api('git/ref/heads/main');
  assert.equal(main.ref, 'refs/heads/main');
  assert.equal(main.object.type, 'commit');
  assert.ok(await reader.forward(record.admission.workflow.commit, main.object.sha), 'unapproved admission workflow lineage');
  const definition = await reader.api(`contents/${record.admission.workflow.path}?ref=${record.admission.workflow.commit}`);
  assert.equal(definition.type, 'file');
  assert.equal(definition.encoding, 'base64');
  assert.equal(sha256(Buffer.from(definition.content.replace(/\n/g, ''), 'base64')), record.admission.workflow.sha256,
    'admission workflow definition differs');
  const expectedNames = ['release.json', ...record.artifacts.map(asset => asset.name)].sort();
  assert.deepEqual([...names].sort(), expectedNames, 'published asset inventory differs');
  mkdirSync(outputDirectory, {mode: 0o700});
  const root = realpathSync(outputDirectory);
  const recordPath = join(root, 'release.json');
  writeFileSync(recordPath, recordBytes, {flag: 'wx', mode: 0o400});
  const signatureBytes = await command(attestationArguments(recordPath, record));
  const signatures = parseEvidenceJson(signatureBytes);
  assert.ok(Array.isArray(signatures) && signatures.length > 0, 'missing verified admission signature');
  await verifyPublishedAsset(command, repository, record.tag, recordPath);
  const payloads = new Map(), paths = new Map([['release.json', recordPath]]);
  let total = recordBytes.length;
  for (const expected of record.artifacts) {
    const asset = assets.find(asset => asset.name === expected.name);
    assert.equal(asset.size, expected.bytes, 'record asset size differs');
    assert.equal(asset.digest, `sha256:${expected.sha256}`, 'record asset digest differs');
    total += expected.bytes;
    assert.ok(total <= 1024 * 1024 * 1024, 'release exceeds capacity');
    const bytes = await download(asset);
    const path = join(root, expected.name);
    writeFileSync(path, bytes, {flag: 'wx', mode: 0o400});
    await verifyPublishedAsset(command, repository, record.tag, path);
    payloads.set(expected.name, bytes); paths.set(expected.name, path);
  }
  const after = await reader.api(`releases/${releaseId}`);
  assert.equal(after.id, releaseId);
  assert.equal(after.immutable, true);
  assert.equal(after.draft, false);
  assert.equal(after.tag_name, record.tag);
  assert.equal(await reader.tagCommit(record.tag), record.source.commit);
  return {id: releaseId, record, recordSha256: sha256(recordBytes), paths, payloads,
    admissionVerification: signatureBytes};
}
