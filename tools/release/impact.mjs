import assert from 'node:assert/strict';
import {encodeRecord, sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

const start = '<!-- repository-release-impact/v1\n', end = '\n-->';

export function validateImpact(value) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), ['contracts', 'disposition', 'impact', 'rationale']);
  assert.ok(['none', 'patch', 'minor', 'major'].includes(value.impact), 'missing reviewed release impact');
  assert.ok(['compatible', 'breaking'].includes(value.disposition));
  assert.ok(typeof value.rationale === 'string' && value.rationale.length > 0 && value.rationale.length <= 8192);
  assert.ok(Array.isArray(value.contracts) && value.contracts.length > 0 && value.contracts.length <= 128);
  assert.equal(new Set(value.contracts).size, value.contracts.length);
  for (const contract of value.contracts) assert.ok(typeof contract === 'string' && contract.length > 0 && contract.length <= 256);
  encodeRecord(value);
  return value;
}

export function impactBlock(value) {
  return `${start}${encodeRecord(validateImpact(value)).toString().trimEnd()}${end}`;
}

export function impactInput(body, base, head) {
  assert.ok(typeof body === 'string' && Buffer.byteLength(body) <= 1024 * 1024);
  assert.match(base, /^[0-9a-f]{40}$/); assert.match(head, /^[0-9a-f]{40}$/);
  const first = body.indexOf(start);
  assert.ok(first >= 0 && body.indexOf(start, first + start.length) === -1, 'missing unique release-impact declaration');
  const last = body.indexOf(end, first + start.length);
  assert.ok(last > first, 'unfinished release-impact declaration');
  const declaration = validateImpact(parseEvidenceJson(body.slice(first + start.length, last)));
  return {base, head, declaration, sha256: sha256(encodeRecord({base, head, declaration}))};
}

export function requireCurrentImpact(captured, body, base, head) {
  assert.deepEqual(impactInput(body, base, head), captured, 'release impact changed after review');
  return captured.declaration;
}

export const versionPreparationImpact = Object.freeze({
  impact: 'patch', disposition: 'compatible',
  rationale: 'Prepare a distinct package version for the reviewed publication boundary. The preparation changes only the package version.',
  contracts: Object.freeze(['package version identity']),
});
