import assert from 'node:assert/strict';
import {readRecord} from './record.mjs';
import {sha256} from './encoding.mjs';
import {HorosPublicationClient} from './publish-github.mjs';

function identifier(value) {
  assert.ok(Number.isSafeInteger(value) && value > 0, 'invalid GitHub object identity');
  return value;
}

async function json(client, path, missing = false) {
  const result = await client.request({path});
  if (missing && result.status === 404) return null;
  assert.equal(result.status, 200, `GitHub read unavailable: ${path}`);
  return result.body;
}

async function pages(client, path) {
  const all = [], identities = new Set();
  for (let page = 1; page <= 100; page++) {
    const values = await json(client, `${path}?per_page=100&page=${page}`);
    assert.ok(Array.isArray(values) && values.length <= 100, 'invalid GitHub page');
    for (const value of values) {
      identifier(value.id);
      assert.ok(!identities.has(value.id), 'GitHub pagination changed');
      identities.add(value.id);
      all.push(value);
    }
    if (values.length < 100) return all;
  }
  throw new Error('publication pagination capacity exceeded');
}

async function repository(client) {
  const value = await json(client, '');
  assert.equal(value.full_name, 'tkersey/horos', 'wrong publication repository');
  assert.equal(value.id, 1176152390, 'publication repository identity changed');
  assert.equal(value.default_branch, 'main', 'unapproved publication branch');
  assert.equal(value.permissions?.push, true, 'draft visibility requires repository write access');
}

async function controls(client) {
  const mode = await json(client, '/actions/variables/REPOSITORY_AUTOMATION', true);
  const publication = await json(client, '/actions/variables/RELEASE_PUBLICATION_ENABLED', true);
  if (mode !== null) assert.equal(mode.name, 'REPOSITORY_AUTOMATION');
  if (publication !== null) assert.equal(publication.name, 'RELEASE_PUBLICATION_ENABLED');
  const automation = mode?.value ?? 'off', enabled = publication?.value ?? 'false';
  assert.ok(['off', 'propose', 'promote'].includes(automation), 'invalid automation control');
  assert.ok(['false', 'true'].includes(enabled), 'invalid publication control');
  return automation !== 'off' && enabled === 'true';
}

async function guard(client) {
  await repository(client);
  assert.equal(await controls(client), true, 'publication disabled');
  const result = await client.request({path: '/immutable-releases'});
  assert.equal(result.status, 200, 'immutable-release setting unavailable; administrative verification required');
  assert.equal(result.body?.enabled, true, 'immutable releases are not enabled');
  assert.equal(typeof result.body.enforced_by_owner, 'boolean', 'unknown immutable-release capability');
}

async function tag(client, record) {
  const value = await json(client, `/git/ref/tags/${record.tag}`, true);
  if (value === null) return null;
  assert.equal(value.ref, `refs/tags/${record.tag}`);
  let object = value.object;
  const seen = new Set();
  for (let depth = 0; depth < 16; depth++) {
    assert.match(object.sha, /^[0-9a-f]{40}$/);
    assert.ok(!seen.has(object.sha), 'tag cycle');
    seen.add(object.sha);
    if (object.type === 'commit') {
      assert.equal(object.sha, record.source.commit, 'conflicting published tag source');
      return object.sha;
    }
    assert.equal(object.type, 'tag', 'unsupported tag object');
    const annotated = await json(client, `/git/tags/${object.sha}`);
    assert.equal(annotated.sha, object.sha);
    object = annotated.object;
  }
  throw new Error('tag depth capacity exceeded');
}

async function release(client, record, marker) {
  const matches = (await pages(client, '/releases')).filter(value => value.tag_name === record.tag);
  assert.ok(matches.length <= 1, 'conflicting releases for tag');
  if (matches.length === 0) return null;
  const value = await json(client, `/releases/${identifier(matches[0].id)}`);
  assert.equal(value.id, matches[0].id);
  assert.equal(value.tag_name, record.tag);
  assert.equal(typeof value.draft, 'boolean');
  assert.equal(value.prerelease, false, 'unsupported prerelease');
  if (value.draft) {
    assert.equal(value.target_commitish, record.source.commit, 'conflicting draft source');
    assert.equal(value.name, record.tag, 'conflicting draft title');
    assert.equal(value.body, marker, 'conflicting draft provenance');
  }
  return value;
}

async function staged(client, value, payloads, complete) {
  const assets = await pages(client, `/releases/${identifier(value.id)}/assets`);
  const names = new Set();
  for (const asset of assets) {
    assert.ok(payloads.has(asset.name) && !names.has(asset.name), 'unexpected or duplicate release asset');
    names.add(asset.name);
    assert.equal(asset.state, 'uploaded', 'incomplete release asset; operator recovery required');
    const expected = payloads.get(asset.name);
    assert.equal(asset.size, expected.length, 'conflicting release asset size');
    if (asset.digest !== undefined && asset.digest !== null) assert.equal(asset.digest, `sha256:${sha256(expected)}`, 'conflicting release asset digest');
    const response = await client.request({path: `/releases/assets/${identifier(asset.id)}`, binary: true, maximumBytes: expected.length + 1});
    assert.equal(response.status, 200, 'release asset download unavailable');
    assert.ok(Buffer.isBuffer(response.body));
    assert.equal(response.body.length, expected.length, 'conflicting downloaded asset size');
    assert.equal(sha256(response.body), sha256(expected), 'conflicting downloaded release asset');
  }
  if (complete) assert.equal(names.size, payloads.size, 'incomplete staged release');
  return names;
}

async function writeAndObserve(client, request, observe) {
  await guard(client);
  let failure;
  try {
    const result = await client.request(request);
    if (![200, 201].includes(result.status)) failure = new Error(`GitHub write returned ${result.status}`);
  } catch (error) { failure = error; }
  try { return await observe(); }
  catch (error) {
    throw new Error('publication write not confirmed; inspect existing objects before retry', {cause: failure ?? error});
  }
}

export async function publishHoros({recordBytes, payloads, admit, verifyPublished, client = new HorosPublicationClient()}) {
  assert.equal(typeof admit, 'function', 'trusted admission procedure required');
  assert.equal(typeof verifyPublished, 'function', 'trusted publication verification required');
  assert.ok(Buffer.isBuffer(recordBytes) && recordBytes.length <= 4 * 1024 * 1024);
  const frozenRecord = Buffer.from(recordBytes), record = readRecord(frozenRecord);
  assert.equal(record.repository.name, 'tkersey/horos');
  assert.equal(record.repository.id, 1176152390);
  assert.ok(payloads instanceof Map && payloads.size === record.artifacts.length, 'unexpected publication payload inventory');
  const frozen = new Map([['release.json', frozenRecord]]);
  let totalBytes = frozenRecord.length;
  for (const artifact of record.artifacts) {
    const bytes = payloads.get(artifact.name);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length === artifact.bytes && bytes.length <= 512 * 1024 * 1024 - 1, 'invalid publication payload');
    assert.equal(sha256(bytes), artifact.sha256, 'publication payload changed');
    totalBytes += bytes.length;
    assert.ok(totalBytes <= 512 * 1024 * 1024, 'publication payload inventory too large');
    frozen.set(artifact.name, Buffer.from(bytes));
  }
  const marker = `repository-release/v1\nrecord-sha256: ${sha256(frozenRecord)}\nsource: ${record.source.commit}\n`;
  const input = () => ({recordBytes: Buffer.from(frozenRecord), payloads: new Map([...frozen].map(([name, bytes]) => [name, Buffer.from(bytes)]))});
  await repository(client);
  let current = await release(client, record, marker);
  const finish = async (value, status) => {
    assert.equal(value.draft, false, 'release remains a draft');
    assert.equal(value.immutable, true, 'published release is mutable');
    assert.equal(await tag(client, record), record.source.commit, 'published tag missing');
    const source = await json(client, `/git/commits/${record.source.commit}`);
    assert.equal(source.sha, record.source.commit);
    assert.equal(source.tree?.sha, record.source.tree, 'published source tree changed');
    await staged(client, value, frozen, true);
    await verifyPublished({...input(), release: structuredClone(value)});
    return {status, releaseId: value.id, tag: record.tag, source: record.source.commit, recordSha256: sha256(frozenRecord)};
  };
  if (current !== null && !current.draft) {
    await admit({...input(), stage: 'existing'});
    return finish(current, 'unchanged');
  }
  if (!await controls(client)) return {status: 'disabled', tag: record.tag, source: record.source.commit};
  await guard(client);
  await admit({...input(), stage: 'prepare'});
  if (current !== null) await staged(client, current, frozen, false);
  const source = await json(client, `/git/commits/${record.source.commit}`);
  assert.equal(source.sha, record.source.commit);
  assert.equal(source.tree?.sha, record.source.tree, 'source tree changed');
  if (await tag(client, record) === null) {
    await writeAndObserve(client, {method: 'POST', path: '/git/refs', body: {ref: `refs/tags/${record.tag}`, sha: record.source.commit}}, async () => {
      assert.equal(await tag(client, record), record.source.commit, 'tag creation not observed');
    });
  }
  if (current === null) {
    current = await writeAndObserve(client, {method: 'POST', path: '/releases', body: {
      tag_name: record.tag, target_commitish: record.source.commit, name: record.tag, body: marker,
      draft: true, prerelease: false, generate_release_notes: false,
    }}, async () => {
      const found = await release(client, record, marker);
      assert.ok(found, 'draft creation not observed');
      return found;
    });
  }
  if (!current.draft) return finish(current, 'unchanged');
  const releaseId = current.id;
  for (const [name, bytes] of frozen) {
    current = await release(client, record, marker);
    assert.ok(current, 'draft disappeared');
    assert.equal(current.id, releaseId, 'draft identity changed');
    if (!current.draft) return finish(current, 'unchanged');
    assert.equal(await tag(client, record), record.source.commit, 'tag disappeared');
    const names = await staged(client, current, frozen, false);
    if (names.has(name)) continue;
    await writeAndObserve(client, {method: 'POST', path: `https://uploads.github.com/repos/tkersey/horos/releases/${current.id}/assets?name=${name}`, body: bytes}, async () => {
      const names = await staged(client, current, frozen, false);
      assert.ok(names.has(name), 'asset upload not observed');
    });
  }
  await admit({...input(), stage: 'publish'});
  current = await release(client, record, marker);
  assert.ok(current, 'draft disappeared before publication');
  assert.equal(current.id, releaseId, 'draft identity changed before publication');
  if (!current.draft) return finish(current, 'unchanged');
  assert.equal(await tag(client, record), record.source.commit, 'tag disappeared before publication');
  await staged(client, current, frozen, true);
  const published = await writeAndObserve(client, {method: 'PATCH', path: `/releases/${current.id}`, body: {draft: false, make_latest: 'false'}}, async () => {
    const found = await release(client, record, marker);
    assert.ok(found && found.id === current.id && found.draft === false, 'publication not observed');
    return found;
  });
  return finish(published, 'published');
}
