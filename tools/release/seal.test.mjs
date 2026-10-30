import assert from 'node:assert/strict';
import test from 'node:test';
import {sealHorosPublication} from './seal.mjs';
import {sealFixture} from './seal-test-support.mjs';
import {readRecord} from './record.mjs';
import {expectedReviewSettings} from './review-check.mjs';

test('sealing preserves original final bytes, review history and independent tool identities deterministically', () => {
  const value = sealFixture(), sealed = sealHorosPublication(value), record = readRecord(sealed.recordBytes);
  assert.deepEqual(sealHorosPublication(value), sealed);
  assert.equal(record.qualification.run.id, 17); assert.equal(record.review.originalEvidence.length, 1);
  assert.deepEqual(sealed.payloads.get('source.tar'), value.qualification.payloads.get('source.tar'));
  assert.deepEqual(sealed.payloads.get('qualification.json'), value.qualification.evidence);
  assert.equal(record.review.landing.tree, record.source.tree);
  assert.equal(record.toolchains[0].sha256, 'f'.repeat(64));
  assert.equal(record.review.tools[0].sha256, expectedReviewSettings.casSha256);
});

for (const [name, change] of [
  ['unready boundary', value => {value.boundary.status = 'prepare';}],
  ['edited boundary', value => {value.boundary.record.source.tree = 'd'.repeat(40);}],
  ['missing original review', value => {value.boundary.reviewProvenance.clear();}],
  ['nonlanded qualification', value => {value.qualification.run.event = 'pull_request';}],
  ['repeated qualification', value => {value.qualification.run.run_attempt = 2;}],
  ['failed lane', value => {value.qualification.jobs[0].conclusion = 'failure';}],
  ['missing lane', value => {value.qualification.jobs.pop();}],
  ['changed original API evidence', value => {value.qualification.evidence = Buffer.from('{}');}],
  ['substituted archive', value => {value.qualification.payloads.set('source.tar', Buffer.from('Substituted.'));}],
  ['changed version', value => {value.boundary.version = '2.0.0';}],
  ['unsupported publisher platform', value => {value.node.platform = 'linux-aarch64';}],
  ['wrong control workflow', value => {value.admission.path = '.github/workflows/other.yml';}],
]) test(`sealing rejects ${name}`, () => {
  const value = sealFixture(); change(value); assert.throws(() => sealHorosPublication(value));
});
