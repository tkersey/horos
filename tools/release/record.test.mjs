import assert from 'node:assert/strict';
import test from 'node:test';
import {encodeRecord} from './encoding.mjs';
import {produceRecord, readRecord, validateRecord} from './record.mjs';

import {metadata} from './test-support.mjs';

for (const name of ['horos', 'kosmos', 'protean']) {
  test(`producer emits deterministic structurally valid ${name} record with exact payload digests`, () => {
    const input = metadata(name);
    const payloads = new Map(input.artifacts.map(artifact => [artifact.name, Buffer.from(artifact.name)]));
    const bytes = produceRecord(input, payloads);
    assert.deepEqual(produceRecord(input, payloads), bytes);
    const actual = readRecord(bytes);
    assert.equal(actual.artifacts[0].bytes, 10);
    assert.equal(actual.artifacts[0].sha256, '0bc95072b76855f2694cf3790eaf11576ceead0b67df265a25efb653f16d3f4c');
    assert.equal(input.artifacts[0].bytes, 1);
  });
}

const invalid = [
  ['future schema', value => {value.schema = 'repository-release/v2';}],
  ['unexpected field', value => {value.passed = true;}],
  ['wrong repository number', value => {value.repository.id++;}],
  ['foreign repository', value => {value.repository.name = 'other/horos';}],
  ['short commit', value => {value.source.commit = 'abc123';}],
  ['mismatched tag', value => {value.tag = 'v2.0.0';}],
  ['wrong package version', value => {value.source.packageIdentity = `horos-2.0.0-${'a'.repeat(44)}`;}],
  ['unexpected dependency', value => {value.dependencies = metadata('kosmos').dependencies;}],
  ['duplicate assets', value => {value.artifacts.push(value.artifacts[0]);}],
  ['record hash cycle', value => {value.artifacts[0].name = 'release.json';}],
  ['path traversal asset', value => {value.artifacts[0].name = '../source.tar';}],
  ['zero-byte asset', value => {value.artifacts[0].bytes = 0;}],
  ['missing source', value => {value.artifacts[0].role = 'evidence';}],
  ['missing evidence', value => {value.review.closeout = 'missing.json';}],
  ['payload as evidence', value => {value.review.closeout = 'source.tar';}],
  ['duplicate qualification result', value => {value.qualification.results.push(value.qualification.results[0]);}],
  ['wrong tested tree', value => {value.qualification.run.tree = 'd'.repeat(40);}],
  ['PR qualification instead of landed', value => {value.qualification.run.event = 'pull_request';}],
  ['wrong landing', value => {value.review.landing.commit = 'd'.repeat(40);}],
  ['missing original evidence', value => {value.review.originalEvidence = [];}],
  ['unknown review executor', value => {value.review.executionMode = 'mock';}],
  ['missing compatibility rationale', value => {value.compatibility.rationale = '';}],
  ['unknown impact', value => {value.compatibility.impact = 'auto';}],
  ['unsafe policy path', value => {value.review.policy.definition.path = '../policy';}],
];
for (const [name, mutate] of invalid) {
  test(`reject ${name}`, () => {
    const value = metadata();
    mutate(value);
    assert.throws(() => validateRecord(value));
  });
}

test('consumer dependency order and Protean lock identity are required', () => {
  const value = metadata('protean');
  value.dependencies.reverse();
  assert.throws(() => validateRecord(value));
  value.dependencies.reverse();
  value.source.lockSha256 = null;
  assert.throws(() => validateRecord(value));
});

test('producer rejects absent and extra payloads and reader rejects noncanonical bytes', () => {
  const input = metadata();
  assert.throws(() => produceRecord(input, new Map()));
  const payloads = new Map(input.artifacts.map(artifact => [artifact.name, Buffer.from(artifact.name)]));
  payloads.set('extra', Buffer.from('extra'));
  assert.throws(() => produceRecord(input, payloads));
  assert.throws(() => readRecord(Buffer.from(JSON.stringify(input))));
  assert.throws(() => readRecord(encodeRecord({...input, schema: 'unknown'})));
});
