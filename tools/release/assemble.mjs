import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {parseExactJson} from '../v2/exact_json.mjs';
import {sha256} from './encoding.mjs';
import {produceRecord} from './record.mjs';

export function assembleHoros(metadata, payloads, manifestBytes) {
  assert.equal(metadata.repository.name, 'tkersey/horos');
  assert.ok(Buffer.isBuffer(manifestBytes));
  const archive = payloads.get('source.tar');
  const inventoryBytes = payloads.get('source.json');
  assert.ok(Buffer.isBuffer(archive) && Buffer.isBuffer(inventoryBytes));
  assert.ok(inventoryBytes.length <= 4 * 1024 * 1024, 'inventory too large');
  const inventory = parseExactJson(inventoryBytes);
  assert.equal(inventory.archive, 'source.tar');
  assert.equal(inventory.sha256, sha256(archive), 'archive bytes changed');
  assert.equal(inventory.size, archive.length, 'archive size changed');
  assert.equal(inventory.compiler, '0.17.0');
  assert.ok(Array.isArray(inventory.files) && inventory.files.length > 0 && inventory.files.length <= 10000);
  const manifests = inventory.files.filter(file => file.path === 'build.zig.zon');
  assert.equal(manifests.length, 1, 'missing unique source manifest');
  const blob = createHash('sha1').update(`blob ${manifestBytes.length}\0`).update(manifestBytes).digest('hex');
  assert.equal(manifests[0].blob, blob, 'manifest differs from native inventory');
  assert.equal(manifests[0].mode, 0o644);
  assert.match(inventory.packageIdentity, /^horos-(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-[A-Za-z0-9_-]{44}$/);
  const version = inventory.packageIdentity.slice('horos-'.length).split('-')[0];
  const source = {
    commit: inventory.commit, tree: inventory.tree, version,
    manifestSha256: sha256(manifestBytes), packageIdentity: inventory.packageIdentity, lockSha256: null,
  };
  const artifacts = metadata.artifacts.map(artifact => {
    if (artifact.name === 'source.tar') assert.equal(artifact.role, 'source');
    if (artifact.name === 'source.json') assert.equal(artifact.role, 'inventory');
    return artifact;
  });
  assert.ok(artifacts.some(artifact => artifact.name === 'source.tar'));
  assert.ok(artifacts.some(artifact => artifact.name === 'source.json'));
  return produceRecord({...metadata, source, tag: `v${version}`, artifacts}, payloads);
}
