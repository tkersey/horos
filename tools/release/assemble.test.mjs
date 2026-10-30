import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import test from 'node:test';
import {assembleHoros} from './assemble.mjs';
import {sha256} from './encoding.mjs';
import {readRecord} from './record.mjs';
import {metadata} from './test-support.mjs';

function inputs() {
  const manifest = Buffer.from('.{ .name = .horos, .version = "1.0.0" }\n');
  const archive = Buffer.from('test-only archive bytes');
  const input = metadata();
  input.artifacts[1].name = 'source.json';
  const inventory = {
    commit: input.source.commit, tree: input.source.tree, archive: 'source.tar',
    sha256: sha256(archive), size: archive.length, packageIdentity: input.source.packageIdentity,
    files: [{path: 'build.zig.zon', mode: 0o644, blob: createHash('sha1').update(`blob ${manifest.length}\0`).update(manifest).digest('hex')}],
    compiler: '0.17.0',
  };
  return {input, manifest, archive, inventory};
}

function payloads(value) {
  return new Map([
    ['source.tar', value.archive],
    ['source.json', Buffer.from(JSON.stringify(value.inventory))],
    ['evidence.json', Buffer.from('test-only evidence')],
  ]);
}

test('record assembly derives source facts from native inventory and actual payloads', () => {
  const value = inputs();
  value.input.source = null;
  value.input.tag = 'v99.0.0';
  const bytes = assembleHoros(value.input, payloads(value), value.manifest);
  const record = readRecord(bytes);
  assert.equal(record.tag, 'v1.0.0');
  assert.equal(record.source.manifestSha256, sha256(value.manifest));
  assert.equal(record.artifacts[0].sha256, value.inventory.sha256);
  assert.equal(record.source.commit, value.inventory.commit);
  assert.equal(value.input.source, null);
  assert.deepEqual(assembleHoros(value.input, payloads(value), value.manifest), bytes);
});

for (const [name, mutate] of [
  ['changed archive', value => {value.archive = Buffer.from('changed bytes');}],
  ['changed manifest', value => {value.manifest = Buffer.from('changed manifest');}],
  ['missing manifest', value => {value.inventory.files = [];}],
  ['duplicate manifest', value => {value.inventory.files.push(value.inventory.files[0]);}],
  ['wrong compiler', value => {value.inventory.compiler = '0.16.0';}],
  ['wrong package', value => {value.inventory.packageIdentity = 'invalid';}],
  ['unqualified source subject', value => {value.inventory.commit = 'd'.repeat(40);}],
]) {
  test(`assembly rejects ${name}`, () => {
    const value = inputs();
    mutate(value);
    assert.throws(() => assembleHoros(value.input, payloads(value), value.manifest));
  });
}
