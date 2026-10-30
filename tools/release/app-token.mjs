import assert from 'node:assert/strict';
import {sign, createPrivateKey} from 'node:crypto';
import {appendFileSync, writeFileSync} from 'node:fs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {repositories} from './record.mjs';

const readPermissions = Object.freeze({metadata: 'read', contents: 'read', actions: 'read', attestations: 'read', checks: 'read', pull_requests: 'read', variables: 'read'});
export const jobPermissions = Object.freeze({
  observer: readPermissions,
  check: Object.freeze({...readPermissions, checks: 'write'}),
  writer: Object.freeze({...readPermissions, contents: 'write', pull_requests: 'write', checks: 'write', administration: 'read'}),
  publisher: Object.freeze({...readPermissions, contents: 'write', administration: 'read'}),
});

export function appJwt(clientId, privateKey, now = Date.now()) {
  assert.ok(typeof clientId === 'string' && /^(?:[1-9][0-9]*|Iv[0-9A-Za-z.]+)$/.test(clientId));
  assert.ok(typeof privateKey === 'string' && privateKey.length > 0 && privateKey.length <= 32768);
  assert.ok(Number.isSafeInteger(now) && now > 0);
  const key = createPrivateKey(privateKey);
  assert.equal(key.asymmetricKeyType, 'rsa');
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = `${encode({alg: 'RS256', typ: 'JWT'})}.${encode({iat: Math.floor(now / 1000) - 60,
    exp: Math.floor(now / 1000) + 540, iss: clientId})}`;
  return `${unsigned}.${sign('RSA-SHA256', Buffer.from(unsigned), key).toString('base64url')}`;
}

async function request(path, token, method = 'GET', body, transport = fetch) {
  assert.ok(path.startsWith('/') && !/[\x00-\x20\x7f]/.test(path) && !path.includes('://'));
  const response = await transport(`https://api.github.com${path}`, {method, redirect: 'error',
    signal: AbortSignal.timeout(30000), headers: {Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2026-03-10', 'Content-Type': 'application/json'},
    ...(body === undefined ? {} : {body: JSON.stringify(body)})});
  assert.ok([200, 201, 204].includes(response.status), `GitHub App request rejected (${response.status})`);
  if (response.status === 204) return null;
  const chunks = []; let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length; assert.ok(size <= 1024 * 1024, 'GitHub App response exceeds bound');
    chunks.push(Buffer.from(chunk));
  }
  return parseEvidenceJson(Buffer.concat(chunks));
}

export async function createJobToken({repository, role, clientId, privateKey, now = Date.now()}, transport = fetch) {
  assert.ok(Object.hasOwn(repositories, repository));
  assert.ok(Object.hasOwn(jobPermissions, role));
  const jwt = appJwt(clientId, privateKey, now);
  const app = await request('/app', jwt, 'GET', undefined, transport);
  assert.ok(Number.isSafeInteger(app.id) && app.id > 0);
  assert.ok(typeof app.slug === 'string' && /^[a-z0-9][a-z0-9-]*$/.test(app.slug));
  assert.ok(String(app.id) === clientId || app.client_id === clientId, 'GitHub App identity differs');
  const installation = await request(`/repos/${repository}/installation`, jwt, 'GET', undefined, transport);
  assert.equal(installation.app_id, app.id); assert.equal(installation.suspended_at, null);
  assert.ok(Number.isSafeInteger(installation.id) && installation.id > 0);
  const permissions = jobPermissions[role];
  const result = await request(`/app/installations/${installation.id}/access_tokens`, jwt, 'POST',
    {repository_ids: [repositories[repository]], permissions}, transport);
  assert.ok(typeof result.token === 'string' && /^[A-Za-z0-9_]+$/.test(result.token) && result.token.length >= 20 && result.token.length <= 512);
  try {
    assert.deepEqual(result.permissions, permissions, 'installation token permissions differ from job scope');
    assert.equal(result.repository_selection, 'selected');
    assert.ok(Array.isArray(result.repositories) && result.repositories.length === 1, 'token has nonlocal repository authority');
    assert.equal(result.repositories[0].id, repositories[repository]); assert.equal(result.repositories[0].full_name, repository);
    const expiry = Date.parse(result.expires_at);
    assert.ok(Number.isFinite(expiry) && expiry > now + 600000 && expiry <= now + 3660000, 'unexpected installation token lifetime');
  } catch (error) {
    await revokeJobToken(result.token, transport);
    throw error;
  }
  return {token: result.token, identity: {appId: app.id, slug: app.slug, login: `${app.slug}[bot]`, installationId: installation.id,
    repository, repositoryId: repositories[repository], role, permissions, expiresAt: result.expires_at}};
}

export async function revokeJobToken(token, transport = fetch) {
  assert.ok(typeof token === 'string' && token.length > 0);
  await request('/installation/token', token, 'DELETE', undefined, transport);
}

if (import.meta.main) {
  const [command, repository, role, identityPath] = process.argv.slice(2);
  if (command === 'revoke') {
    assert.equal(repository, undefined); await revokeJobToken(process.env.GH_TOKEN);
  } else {
    assert.equal(command, 'create'); assert.ok(identityPath && process.env.GITHUB_OUTPUT);
    const result = await createJobToken({repository, role, clientId: process.env.REPOSITORY_APP_CLIENT_ID,
      privateKey: process.env.REPOSITORY_APP_PRIVATE_KEY});
    process.stdout.write(`::add-mask::${result.token}\n`);
    appendFileSync(process.env.GITHUB_OUTPUT, `token=${result.token}\n`);
    writeFileSync(identityPath, JSON.stringify(result.identity), {flag: 'wx', mode: 0o400});
  }
}
