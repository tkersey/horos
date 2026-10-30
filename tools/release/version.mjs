import assert from 'node:assert/strict';

const impacts = ['none', 'patch', 'minor', 'major'];

export function parseVersion(version) {
  assert.equal(typeof version, 'string');
  assert.match(version, /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/);
  const parts = version.split('.').map(Number);
  assert.ok(parts.every(Number.isSafeInteger), 'version component overflow');
  return parts;
}

function compare(a, b) {
  for (let index = 0; index < 3; index++) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  }
  return 0;
}

export function prepareVersion({published, pending, declarations, publicationRequired}) {
  const previous = parseVersion(published);
  const current = parseVersion(pending);
  assert.ok(compare(current, previous) >= 0, 'pending version predates publication');
  assert.equal(typeof publicationRequired, 'boolean');
  assert.ok(Array.isArray(declarations) && declarations.length > 0, 'missing admitted impact');
  let rank = 0;
  for (const declaration of declarations) {
    assert.ok(impacts.includes(declaration), 'unsupported impact');
    rank = Math.max(rank, impacts.indexOf(declaration));
  }
  if (rank === 0 && !publicationRequired) return pending;
  rank = Math.max(rank, 1);
  const index = 3 - rank;
  const required = previous.slice();
  assert.ok(required[index] < Number.MAX_SAFE_INTEGER, 'version component overflow');
  required[index]++;
  for (let lower = index + 1; lower < 3; lower++) required[lower] = 0;
  return compare(current, required) >= 0 ? pending : required.join('.');
}
