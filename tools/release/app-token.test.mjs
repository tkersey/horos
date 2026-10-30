import assert from 'node:assert/strict';
import test from 'node:test';
import {generateKeyPairSync, verify} from 'node:crypto';
import {appJwt, createJobToken, jobPermissions, revokeJobToken} from './app-token.mjs';

const keys = generateKeyPairSync('rsa', {modulusLength: 2048});
const privateKey = keys.privateKey.export({type: 'pkcs8', format: 'pem'}), now = 1793363344000;

function fixture(role = 'observer') {
  const token = {token: 'ghs_local_fixture_token_12345678', expires_at: new Date(now + 3600000).toISOString(),
    permissions: {...jobPermissions[role]}, repository_selection: 'selected',
    repositories: [{id: 1176152390, full_name: 'tkersey/horos'}]};
  const installation = {id: 6, app_id: 5, suspended_at: null};
  const calls = [];
  const transport = async (url, options) => {
    calls.push({url, options});
    assert.equal(options.redirect, 'error');
    assert.ok(options.signal instanceof AbortSignal);
    const path = new URL(url).pathname;
    if (path === '/app') return Response.json({id: 5, client_id: 'Iv1.example', slug: 'local-release'});
    if (path === '/repos/tkersey/horos/installation') return Response.json(installation);
    if (path === '/app/installations/6/access_tokens') {
      assert.equal(options.method, 'POST');
      assert.deepEqual(JSON.parse(options.body), {repository_ids: [1176152390], permissions: jobPermissions[role]});
      return Response.json(token, {status: 201});
    }
    assert.equal(path, '/installation/token'); assert.equal(options.method, 'DELETE');
    return new Response(null, {status: 204});
  };
  return {token, installation, calls, transport, options: {repository: 'tkersey/horos', role, clientId: 'Iv1.example', privateKey, now}};
}

test('GitHub App authentication signs a short-lived issuer-bound RS256 token', () => {
  const jwt = appJwt('Iv1.example', privateKey, now), parts = jwt.split('.');
  assert.equal(parts.length, 3);
  assert.deepEqual(JSON.parse(Buffer.from(parts[0], 'base64url')), {alg: 'RS256', typ: 'JWT'});
  assert.deepEqual(JSON.parse(Buffer.from(parts[1], 'base64url')), {iat: now / 1000 - 60, exp: now / 1000 + 540, iss: 'Iv1.example'});
  assert.ok(verify('RSA-SHA256', Buffer.from(parts.slice(0, 2).join('.')), keys.publicKey, Buffer.from(parts[2], 'base64url')));
  assert.throws(() => appJwt('https://attacker.invalid', privateKey, now));
});

for (const role of Object.keys(jobPermissions)) {
  test(`${role} receives only explicit permissions for its one repository`, async () => {
    const value = fixture(role), result = await createJobToken(value.options, value.transport);
    assert.equal(result.token, value.token.token);
    assert.equal(result.identity.appId, 5); assert.equal(result.identity.role, role);
    assert.equal(result.identity.login, 'local-release[bot]');
    assert.deepEqual(result.identity.permissions, jobPermissions[role]);
    assert.equal(result.identity.permissions.checks, ['writer', 'check'].includes(role) ? 'write' : 'read');
    assert.equal(result.identity.permissions.attestations, 'read');
    assert.equal(result.identity.privateKey, undefined);
    if (role === 'observer') assert.ok(Object.values(result.identity.permissions).every(permission => permission === 'read'));
    await revokeJobToken(result.token, value.transport);
    assert.equal(value.calls.at(-1).options.headers.Authorization, `Bearer ${result.token}`);
  });
}

for (const [name, mutate] of [
  ['cross repository authority', value => {value.token.repositories.push({id: 1251308461, full_name: 'tkersey/kosmos'});}],
  ['wrong repository identity', value => {value.token.repositories[0].id++;}],
  ['all repositories', value => {value.token.repository_selection = 'all';}],
  ['unexpected write permission', value => {value.token.permissions.contents = 'write';}],
  ['missing scoped permission', value => {delete value.token.permissions.variables;}],
  ['different app', value => {value.installation.app_id++;}],
  ['suspended installation', value => {value.installation.suspended_at = '2026-10-30T00:00:00Z';}],
  ['expired credential', value => {value.token.expires_at = new Date(now - 1).toISOString();}],
  ['unexpected credential lifetime', value => {value.token.expires_at = new Date(now + 7200000).toISOString();}],
]) {
  test(`job token refuses ${name}`, async () => {
    const value = fixture(); mutate(value);
    await assert.rejects(createJobToken(value.options, value.transport));
  });
}

test('unsupported repository and role cannot request an installation token', async () => {
  const value = fixture();
  for (const options of [{repository: 'attacker/repo'}, {role: 'administrator'}]) {
    await assert.rejects(createJobToken({...value.options, ...options}, value.transport));
  }
  assert.equal(value.calls.length, 0);
});
