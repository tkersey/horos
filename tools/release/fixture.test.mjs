import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {parseExactJson} from '../v2/exact_json.mjs';
import {sha256} from './encoding.mjs';
import {readRecord} from './record.mjs';

const root = new URL('../../test/fixtures/release/', import.meta.url);
const load = name => readFileSync(new URL(name, root));

test('frozen Horos producer fixture binds native inventory and manifest bytes', () => {
  const record = readRecord(load('horos-v1.json'));
  const inventory = parseExactJson(load('source.json'));
  const manifest = load('build.zig.zon.txt');
  assert.equal(record.source.commit, '2fbcc41c98887bcd6ece56060d263730394b1bc6');
  assert.equal(record.source.tree, '6da66c8d7415697d924aeabdaa917615a93196eb');
  assert.equal(record.source.packageIdentity, 'horos-8.0.0-flclaIItVgCRBCbUEysErcsQyVqsukGf2Q8X2is_wRuU');
  assert.equal(record.source.manifestSha256, sha256(manifest));
  assert.equal(record.source.commit, inventory.commit);
  assert.equal(record.source.tree, inventory.tree);
  assert.equal(record.artifacts.find(value => value.role === 'source').sha256, inventory.sha256);
  assert.equal(record.artifacts.find(value => value.role === 'source').bytes, inventory.size);
  const file = inventory.files.find(value => value.path === 'build.zig.zon');
  assert.equal(file.blob, createHash('sha1').update(`blob ${manifest.length}\0`).update(manifest).digest('hex'));
  for (const name of ['source.json', 'evidence.json']) {
    const asset = record.artifacts.find(value => value.name === name);
    assert.equal(asset.sha256, sha256(load(name)));
    assert.equal(asset.bytes, load(name).length);
  }
  assert.match(record.compatibility.rationale, /synthetic/);
});
