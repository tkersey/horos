import assert from 'node:assert/strict';
import {mkdtempSync, realpathSync, rmSync, existsSync, writeFileSync, chmodSync, readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {preparePublication, publishPrepared, publicationEnabled, publicationServices} from './publication-runner.mjs';
import {sealHorosPublication} from './seal.mjs';
import {sealFixture} from './seal-test-support.mjs';

function fixture(t) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), 'publication-test-'))); t.after(() => rmSync(directory, {recursive: true, force: true}));
  const sealed = sealHorosPublication(sealFixture()), calls = [], output = join(directory, 'output');
  const services = {enabled: async () => true, prepare: async () => ({status: 'ready', ...sealed}),
    verifyAttestation: async (path, record) => {assert.equal(path, join(output, 'assets/release.json')); assert.equal(record.source.version, '1.0.0'); calls.push('attestation');},
    verifyPublished: async () => {calls.push('published verification');}};
  return {directory, output, sealed, services, calls};
}

test('default-off and publication-false prohibit preparation without probing source', async t => {
  const value = fixture(t); value.services.enabled = async () => false;
  value.services.prepare = async () => {throw new Error('must not prepare');};
  assert.deepEqual(await preparePublication(value.output, value.services), {status: 'disabled'});
  assert.equal(existsSync(value.output), false);
  for (const mode of [undefined, 'off', 'propose', 'promote']) for (const publication of [undefined, 'false', 'true']) {
    const client = {request: async ({path}) => {
      const name = path.split('/').at(-1), value = name === 'REPOSITORY_AUTOMATION' ? mode : publication;
      return value === undefined ? {status: 404} : {status: 200, body: {name, value}};
    }};
    assert.equal(await publicationEnabled(client), ['propose', 'promote'].includes(mode) && publication === 'true');
  }
});

test('seals exact assets then revalidates original evidence and signature before both publication stages', async t => {
  const value = fixture(t);
  assert.equal((await preparePublication(value.output, value.services)).status, 'ready');
  assert.deepEqual(readFileSync(join(value.output, 'assets/release.json')), value.sealed.recordBytes);
  const publish = async input => {
    assert.deepEqual(input.payloads, value.sealed.payloads);
    await input.admit({...input, stage: 'prepare'}); await input.admit({...input, stage: 'publish'});
    await input.verifyPublished({}); return {status: 'published'};
  };
  assert.equal((await publishPrepared(value.output, value.services, publish)).status, 'published');
  assert.deepEqual(value.calls, ['attestation', 'attestation', 'published verification']);
});

test('identical completed release needs retained immutable evidence, without expired qualification rerun', async t => {
  const value = fixture(t); await preparePublication(value.output, value.services);
  value.services.prepare = async () => {throw new Error('expired original qualification');};
  await publishPrepared(value.output, value.services, async input => {
    await input.admit({...input, stage: 'existing'}); await input.verifyPublished({}); return {status: 'unchanged'};
  });
  assert.deepEqual(value.calls, ['attestation', 'published verification']);
});

for (const stage of ['prepare', 'publish']) for (const change of ['disabled', 'changed source', 'changed evidence', 'missing attestation']) {
  test(`${stage} refuses ${change} before publication`, async t => {
    const value = fixture(t); await preparePublication(value.output, value.services);
    if (change === 'disabled') value.services.enabled = async () => false;
    if (change === 'changed source') value.services.prepare = async () => ({status: 'prepare'});
    if (change === 'changed evidence') value.services.prepare = async () => ({status: 'ready', ...value.sealed, recordBytes: Buffer.from('{}')});
    if (change === 'missing attestation') value.services.verifyAttestation = async () => {throw new Error('no signature');};
    await assert.rejects(() => publishPrepared(value.output, value.services, async input => input.admit({...input, stage})));
  });
}

for (const name of ['source.tar', 'plan.json', 'extra']) test(`prepared ${name} mutation cannot reach writer`, async t => {
  const value = fixture(t); await preparePublication(value.output, value.services);
  const path = name === 'plan.json' ? join(value.output, name) : join(value.output, 'assets', name);
  if (existsSync(path)) chmodSync(path, 0o600);
  writeFileSync(path, '{}'); let called = false;
  await assert.rejects(() => publishPrepared(value.output, value.services, async () => {called = true;}));
  assert.equal(called, false);
});

test('pending qualification and already published source produce no candidate files', async t => {
  const value = fixture(t);
  for (const status of ['landed-qualification-pending', 'unchanged', 'idle', 'prepare']) {
    value.services.prepare = async () => ({status});
    assert.deepEqual(await preparePublication(value.output, value.services), {status}); assert.equal(existsSync(value.output), false);
  }
});

test('missing App disables the real publication service before credentialed control or source access', async t => {
  const value = fixture(t);
  const services = publicationServices({identity: null, controlDirectory: join(value.directory, 'unavailable-control'),
    nativePath: join(value.directory, 'unavailable-native'), compilerPath: join(value.directory, 'unavailable-compiler')});
  const result = await preparePublication(value.output, services);
  assert.equal(result.status, 'disabled'); assert.match(result.reason, /App credential is missing/);
  assert.equal(existsSync(value.output), false);
});
