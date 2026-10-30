import assert from 'node:assert/strict';
import test from 'node:test';
import {parseVersion, prepareVersion} from './version.mjs';

const prepare = overrides => prepareVersion({published: '1.2.3', pending: '1.2.3', declarations: ['patch'], publicationRequired: true, ...overrides});

test('highest admitted impact determines the lower version bound', () => {
  assert.equal(prepare({}), '1.2.4');
  assert.equal(prepare({declarations: ['patch', 'minor']}), '1.3.0');
  assert.equal(prepare({declarations: ['major', 'none', 'patch']}), '2.0.0');
});

test('sufficient pending versions are preserved and repeated preparation converges', () => {
  for (const pending of ['1.2.4', '1.3.0', '2.0.0']) assert.equal(prepare({pending}), pending);
  const version = prepare({declarations: ['minor']});
  assert.equal(prepare({pending: version, declarations: ['minor']}), version);
});

test('none is idle unless a distinct publication is required', () => {
  assert.equal(prepare({declarations: ['none'], publicationRequired: false}), '1.2.3');
  assert.equal(prepare({declarations: ['none']}), '1.2.4');
  assert.equal(prepare({published: '1.2.4', pending: '1.2.4', declarations: ['none'], publicationRequired: false}), '1.2.4');
});

test('missing or contradictory authority and unsafe versions are rejected', () => {
  for (const version of ['01.2.3', '1.2', 'v1.2.3', '1.2.3-rc.1', '9007199254740992.0.0']) {
    assert.throws(() => parseVersion(version));
  }
  assert.throws(() => prepare({declarations: []}));
  assert.throws(() => prepare({declarations: ['breaking']}));
  assert.throws(() => prepare({pending: '1.2.2'}));
  assert.throws(() => prepare({published: '1.2.9007199254740991', pending: '1.2.9007199254740991'}));
});
