import assert from 'node:assert/strict';
import {decodeRecord, encodeRecord, sha256} from './encoding.mjs';
import {parseVersion} from './version.mjs';

export const repositories = Object.freeze({
  'tkersey/horos': 1176152390,
  'tkersey/kosmos': 1251308461,
  'tkersey/protean': 1328996555,
});

function fields(value, names) {
  assert.ok(value !== null && typeof value === 'object' && !Array.isArray(value), 'expected object');
  assert.deepEqual(Object.keys(value).sort(), names.split(' ').sort(), 'unexpected fields');
}

function text(value, maximum = 1024) {
  assert.ok(typeof value === 'string' && value.length > 0 && value.length <= maximum, 'invalid text');
  assert.ok(!/[\x00-\x1f\x7f]/.test(value), 'control character');
}

function digest(value, length = 64) {
  assert.ok(typeof value === 'string' && new RegExp(`^[0-9a-f]{${length}}$`).test(value), 'invalid digest');
}

function positive(value) {
  assert.ok(Number.isSafeInteger(value) && value > 0, 'invalid positive integer');
}

function list(value, maximum, empty = false) {
  assert.ok(Array.isArray(value) && value.length <= maximum && (empty || value.length > 0), 'invalid list');
}

function unique(values) {
  assert.equal(new Set(values).size, values.length, 'duplicate identity');
}

function repository(value) {
  fields(value, 'name id');
  assert.ok(Object.hasOwn(repositories, value.name), 'unsupported repository');
  assert.equal(value.id, repositories[value.name], 'repository identity mismatch');
}

function source(value, name) {
  fields(value, 'commit tree version manifestSha256 packageIdentity lockSha256');
  digest(value.commit, 40);
  digest(value.tree, 40);
  parseVersion(value.version);
  digest(value.manifestSha256);
  if (name === 'tkersey/protean') digest(value.lockSha256);
  else assert.equal(value.lockSha256, null);
  const packageName = name.split('/')[1];
  assert.equal(typeof value.packageIdentity, 'string');
  assert.ok(value.packageIdentity.startsWith(`${packageName}-${value.version}-`), 'package version mismatch');
  assert.match(value.packageIdentity.slice(`${packageName}-${value.version}-`.length), /^[A-Za-z0-9_-]{44}$/);
}

function definition(value) {
  fields(value, 'path commit sha256');
  text(value.path, 256);
  assert.match(value.path, /^(?:[A-Za-z0-9_.-]+\/)*[A-Za-z0-9_.-]+$/);
  assert.ok(!value.path.split('/').some(part => part === '.' || part === '..'), 'unsafe definition path');
  digest(value.commit, 40);
  digest(value.sha256);
}

function tool(value) {
  fields(value, 'name version platform sha256');
  text(value.name, 64);
  text(value.version, 128);
  text(value.platform, 128);
  digest(value.sha256);
}

function validateArtifacts(artifacts) {
  list(artifacts, 128);
  unique(artifacts.map(value => value.name));
  const byName = new Map();
  for (const artifact of artifacts) {
    fields(artifact, 'name role platform bytes sha256');
    assert.match(artifact.name, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/);
    assert.ok(!['release.json', 'SHA256SUMS'].includes(artifact.name), 'cyclic record artifact');
    assert.ok(['source', 'runtime', 'native', 'evidence', 'inventory'].includes(artifact.role), 'unknown artifact role');
    if (artifact.platform !== null) text(artifact.platform, 128);
    if (artifact.role === 'native') assert.notEqual(artifact.platform, null, 'native platform required');
    positive(artifact.bytes);
    digest(artifact.sha256);
    byName.set(artifact.name, artifact);
  }
  assert.equal(artifacts.filter(value => value.role === 'source').length, 1, 'one full source asset required');
  assert.equal(artifacts.filter(value => value.role === 'inventory').length, 1, 'one full source inventory required');
  return name => {
    assert.equal(byName.get(name)?.role, 'evidence', 'missing evidence asset');
  };
}

function validateDependencies(record) {
  const expected = {
    'tkersey/horos': [],
    'tkersey/kosmos': ['tkersey/horos'],
    'tkersey/protean': ['tkersey/horos', 'tkersey/kosmos'],
  }[record.repository.name];
  list(record.dependencies, 2, true);
  assert.deepEqual(record.dependencies.map(value => value.repository?.name), expected, 'invalid dependency shape or order');
  for (const dependency of record.dependencies) {
    fields(dependency, 'repository source release');
    repository(dependency.repository);
    source(dependency.source, dependency.repository.name);
    fields(dependency.release, 'id tag recordSha256');
    positive(dependency.release.id);
    assert.equal(dependency.release.tag, `v${dependency.source.version}`);
    digest(dependency.release.recordSha256);
  }
}

function validateQualification(value, subject, evidence) {
  fields(value, 'workflow run results aggregate');
  definition(value.workflow);
  assert.match(value.workflow.path, /^\.github\/workflows\/[A-Za-z0-9_-]+\.yml$/);
  fields(value.run, 'id attempt event commit tree');
  positive(value.run.id);
  positive(value.run.attempt);
  assert.equal(value.run.event, 'push', 'release requires landed qualification');
  assert.equal(value.run.commit, subject.commit);
  assert.equal(value.run.tree, subject.tree);
  list(value.results, 128);
  unique(value.results.map(result => `${result.platform}\0${result.profile}`));
  for (const result of value.results) {
    fields(result, 'platform profile evidence');
    text(result.platform, 128);
    text(result.profile, 128);
    evidence(result.evidence);
  }
  fields(value.aggregate, 'name evidence');
  text(value.aggregate.name, 128);
  evidence(value.aggregate.evidence);
}

function validateReview(value, subject, evidence) {
  fields(value, 'owner executionMode policy tools subject landing closeout originalEvidence');
  assert.equal(value.owner, 'actuating');
  assert.ok(['cas', 'subagents'].includes(value.executionMode), 'unsupported executor');
  fields(value.policy, 'repository definition');
  assert.equal(value.policy.repository, 'tkersey/dotfiles');
  definition(value.policy.definition);
  list(value.tools, 16);
  unique(value.tools.map(item => `${item.name}\0${item.platform}`));
  value.tools.forEach(tool);
  fields(value.subject, 'base head tree');
  for (const key of ['base', 'head', 'tree']) digest(value.subject[key], 40);
  fields(value.landing, 'commit tree evidence');
  assert.equal(value.landing.commit, subject.commit);
  assert.equal(value.landing.tree, subject.tree);
  evidence(value.landing.evidence);
  evidence(value.closeout);
  list(value.originalEvidence, 128);
  unique(value.originalEvidence);
  value.originalEvidence.forEach(evidence);
}

export function validateRecord(record) {
  fields(record, 'schema repository source tag dependencies artifacts admission qualification review compatibility toolchains');
  assert.equal(record.schema, 'repository-release/v1');
  repository(record.repository);
  source(record.source, record.repository.name);
  assert.equal(record.tag, `v${record.source.version}`);
  validateDependencies(record);
  const evidence = validateArtifacts(record.artifacts);
  fields(record.admission, 'workflow');
  definition(record.admission.workflow);
  assert.equal(record.admission.workflow.path, '.github/workflows/repository-release.yml');
  validateQualification(record.qualification, record.source, evidence);
  validateReview(record.review, record.source, evidence);
  fields(record.compatibility, 'impact disposition rationale contracts evidence');
  assert.ok(['none', 'patch', 'minor', 'major'].includes(record.compatibility.impact));
  assert.ok(['compatible', 'breaking'].includes(record.compatibility.disposition));
  text(record.compatibility.rationale, 8192);
  list(record.compatibility.contracts, 128);
  unique(record.compatibility.contracts);
  record.compatibility.contracts.forEach(value => text(value, 256));
  evidence(record.compatibility.evidence);
  list(record.toolchains, 32);
  unique(record.toolchains.map(item => `${item.name}\0${item.platform}`));
  record.toolchains.forEach(tool);
  encodeRecord(record);
  return record;
}

export function readRecord(bytes) {
  return validateRecord(decodeRecord(bytes));
}

export function produceRecord(metadata, payloads) {
  assert.ok(payloads instanceof Map);
  const record = structuredClone(metadata);
  record.artifacts = record.artifacts.map(artifact => {
    const bytes = payloads.get(artifact.name);
    assert.ok(Buffer.isBuffer(bytes), 'missing artifact bytes');
    return {...artifact, bytes: bytes.length, sha256: sha256(bytes)};
  });
  assert.equal(payloads.size, record.artifacts.length, 'unexpected artifact bytes');
  return encodeRecord(validateRecord(record));
}
