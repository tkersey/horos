import assert from 'node:assert/strict';
import test from 'node:test';
import {impactBlock, impactInput, requireCurrentImpact, versionPreparationImpact} from './impact.mjs';

const base = 'a'.repeat(40), head = 'b'.repeat(40);
test('impact capture binds semantic declaration to exact review subject', () => {
  const body = `Changes\n${impactBlock(versionPreparationImpact)}`;
  const input = impactInput(body, base, head);
  assert.deepEqual(input.declaration, versionPreparationImpact);
  assert.deepEqual(requireCurrentImpact(input, `${body}\nUpdated explanatory notes`, base, head), versionPreparationImpact);
  assert.throws(() => requireCurrentImpact(input, body, base, 'c'.repeat(40)), /changed after review/);
  assert.throws(() => requireCurrentImpact(input, impactBlock({...versionPreparationImpact, rationale: 'Different boundary'}), base, head), /changed after review/);
});

test('missing, duplicated, malformed and unsupported impacts cannot become review input', () => {
  const block = impactBlock(versionPreparationImpact);
  for (const body of ['', `${block}\n${block}`, block.replace('"patch"', '"automatic"'),
    block.replace('"impact":"patch"', '"impact":"patch","impact":"none"'), block.slice(0, -3)]) {
    assert.throws(() => impactInput(body, base, head));
  }
});
