import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {admitPublishedRelease, attestationArguments} from './release-admission.mjs';
import {produceRecord, readRecord} from './record.mjs';
import {sha256} from './encoding.mjs';
import {metadata} from './test-support.mjs';

function fixture() {
  const value = metadata();
  const definition = Buffer.from('trusted workflow fixture');
  value.admission.workflow.sha256 = sha256(definition);
  const payloads = new Map(value.artifacts.map(asset => [asset.name, Buffer.from(asset.name)]));
  const recordBytes = produceRecord(value, payloads), record = readRecord(recordBytes);
  payloads.set('release.json', recordBytes);
  const assets = [...payloads].map(([name, bytes], index) => ({id: index + 10, name,
    state: 'uploaded', size: bytes.length, digest: `sha256:${sha256(bytes)}`}));
  const release = {id: 7, draft: false, prerelease: false, immutable: true, tag_name: record.tag};
  const calls = [];
  const replies = new Map([
    ['repos/tkersey/horos', {full_name: 'tkersey/horos', id: 1176152390, default_branch: 'main'}],
    ['repos/tkersey/horos/releases/7', release],
    ['repos/tkersey/horos/releases/7/assets?per_page=100&page=1', assets],
    [`repos/tkersey/horos/git/ref/tags/${record.tag}`, {ref: `refs/tags/${record.tag}`, object: {type: 'commit', sha: record.source.commit}}],
    [`repos/tkersey/horos/git/commits/${record.source.commit}`, {sha: record.source.commit, tree: {sha: record.source.tree}}],
    ['repos/tkersey/horos/git/ref/heads/main', {ref: 'refs/heads/main', object: {type: 'commit', sha: record.admission.workflow.commit}}],
    [`repos/tkersey/horos/compare/${record.admission.workflow.commit}...${record.admission.workflow.commit}`,
      {base_commit: {sha: record.admission.workflow.commit}, merge_base_commit: {sha: record.admission.workflow.commit}, status: 'identical'}],
    [`repos/tkersey/horos/contents/${record.admission.workflow.path}?ref=${record.admission.workflow.commit}`,
      {type: 'file', encoding: 'base64', content: definition.toString('base64')}],
  ]);
  for (const asset of assets) replies.set(`repos/tkersey/horos/releases/assets/${asset.id}`, payloads.get(asset.name));
  const command = async args => {
    calls.push(args);
    if (args[0] === 'attestation') return Buffer.from('[{"testOnly":"verified invocation contract"}]');
    if (args[0] === 'release') return Buffer.from('{"testOnly":"platform invocation contract"}');
    assert.ok(replies.has(args[1]), `unexpected API request ${args[1]}`);
    const response = replies.get(args[1]);
    return Buffer.isBuffer(response) ? response : Buffer.from(JSON.stringify(response));
  };
  return {record, recordBytes, assets, release, calls, replies, command};
}

async function run(value, command = value.command) {
  const directory = mkdtempSync(join(tmpdir(), 'horos-release-admission-'));
  try {
    return await admitPublishedRelease({repository: 'tkersey/horos', releaseId: 7,
      outputDirectory: join(directory, 'download')}, command);
  } finally { rmSync(directory, {recursive: true, force: true}); }
}

test('published release admission verifies signer, exact tag, every asset and source separately', async () => {
  const value = fixture();
  const result = await run(value, async args => {
    if (args[0] === 'attestation') {
      assert.deepEqual(args, attestationArguments(args[2], value.record));
      assert.deepEqual(readFileSync(args[2]), value.recordBytes);
      assert.ok(args.includes('--cert-identity') && args.includes('--signer-digest') && args.includes('--source-digest'));
      assert.ok(!args.includes('--bundle'));
    }
    return value.command(args);
  });
  assert.equal(result.id, 7);
  assert.equal(result.recordSha256, sha256(value.recordBytes));
  assert.equal(result.payloads.size, value.record.artifacts.length);
  assert.equal(value.calls.filter(args => args[0] === 'release').length, value.assets.length);
});

for (const [name, mutate] of [
  ['mutable release', value => {value.release.immutable = false;}],
  ['draft', value => {value.release.draft = true;}],
  ['prerelease', value => {value.release.prerelease = true;}],
  ['repository replacement', value => {value.replies.get('repos/tkersey/horos').id++;}],
  ['duplicate asset', value => {value.assets.push(value.assets[0]);}],
  ['unexpected asset', value => {value.assets.push({...value.assets[0], id: 888, name: 'unadmitted'});}],
  ['corrupt record transport', value => {value.replies.set(`repos/tkersey/horos/releases/assets/${value.assets.at(-1).id}`, Buffer.from('corrupt'));}],
  ['payload substitution', value => {value.replies.set('repos/tkersey/horos/releases/assets/10', Buffer.from('x'.repeat(value.assets[0].size)));}],
  ['tag substitution', value => {value.replies.get(`repos/tkersey/horos/git/ref/tags/${value.record.tag}`).object.sha = 'f'.repeat(40);}],
  ['wrong source tree', value => {value.replies.get(`repos/tkersey/horos/git/commits/${value.record.source.commit}`).tree.sha = 'f'.repeat(40);}],
  ['changed workflow bytes', value => {value.replies.get(`repos/tkersey/horos/contents/${value.record.admission.workflow.path}?ref=${value.record.admission.workflow.commit}`).content = Buffer.from('forged').toString('base64');}],
]) {
  test(`published release admission rejects ${name}`, async () => {
    const value = fixture(); mutate(value);
    await assert.rejects(run(value));
  });
}

test('signature or platform attestation failure never falls back to digest-only admission', async () => {
  for (const rejected of ['attestation', 'release']) {
    const value = fixture();
    await assert.rejects(run(value, async args => {
      if (args[0] === rejected) throw new Error('signature rejected');
      return value.command(args);
    }), /signature rejected/);
  }
});

test('successful process with no verified attestations is not admission', async () => {
  const value = fixture();
  await assert.rejects(run(value, args => args[0] === 'attestation' ? Buffer.from('[]') : value.command(args)), /missing verified/);
});
