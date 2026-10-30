import assert from 'node:assert/strict';
import test from 'node:test';
import {publishHoros} from './publish.mjs';
import {produceRecord, readRecord} from './record.mjs';
import {sha256} from './encoding.mjs';
import {metadata} from './test-support.mjs';

function fixture() {
  const payloads = new Map(metadata().artifacts.map(item => [item.name, Buffer.from(item.name)]));
  const recordBytes = produceRecord(metadata(), payloads);
  const record = readRecord(recordBytes);
  const state = {mode: 'promote', enabled: 'true', immutable: {enabled: true, enforced_by_owner: false},
    releases: [], assets: [], contents: new Map(), tag: null, calls: [], admissions: [], verified: [],
    failAfter: null, failBefore: null, onRequest: null, extraReleases: [], repositoryId: 1176152390};
  let nextAsset = 10;
  const reply = body => ({status: 200, body});
  const client = {async request(request) {
    const method = request.method ?? 'GET', path = request.path;
    state.calls.push({method, path, body: request.body});
    await state.onRequest?.(request, state);
    if (method !== 'GET' && state.failBefore?.(request)) throw new Error('transport lost before mutation');
    let response;
    if (method === 'GET') {
      if (path === '') return reply({full_name: 'tkersey/horos', id: state.repositoryId, default_branch: 'main', permissions: {push: true}});
      if (path.startsWith('/actions/variables/')) {
        const name = path.split('/').at(-1), value = name === 'REPOSITORY_AUTOMATION' ? state.mode : state.enabled;
        return value === null ? {status: 404} : reply({name, value});
      }
      if (path === '/immutable-releases') return state.immutableStatus ? {status: state.immutableStatus} : reply(state.immutable);
      if (path.startsWith('/git/ref/')) return state.tag ? reply({ref: `refs/tags/${record.tag}`, object: state.tag}) : {status: 404};
      if (path.startsWith('/git/tags/')) return reply({sha: path.split('/').at(-1), object: {type: 'commit', sha: record.source.commit}});
      if (path.startsWith('/git/commits/')) return reply({sha: record.source.commit, tree: {sha: state.tree ?? record.source.tree}});
      if (path.startsWith('/releases?')) {
        const page = Number(new URL(`https://example.test${path}`).searchParams.get('page'));
        return reply([...state.extraReleases, ...state.releases].slice((page - 1) * 100, page * 100).map(value => ({...value})));
      }
      if (path === '/releases/1') return reply({...state.releases[0]});
      if (path.startsWith('/releases/1/assets?')) {
        const page = Number(new URL(`https://example.test${path}`).searchParams.get('page'));
        return reply(state.assets.slice((page - 1) * 100, page * 100).map(value => ({...value})));
      }
      if (path.startsWith('/releases/assets/')) return reply(Buffer.from(state.contents.get(Number(path.split('/').at(-1)))));
      throw new Error(`unexpected GET ${path}`);
    }
    if (method === 'POST' && path === '/git/refs') {
      assert.equal(state.tag, null);
      state.tag = {type: 'commit', sha: request.body.sha};
      response = {status: 201, body: {ref: request.body.ref, object: state.tag}};
    } else if (method === 'POST' && path === '/releases') {
      assert.equal(state.releases.length, 0);
      state.releases.push({...request.body, id: 1, immutable: false});
      response = {status: 201, body: {...state.releases[0]}};
    } else if (method === 'POST' && path.startsWith('https://uploads.github.com/')) {
      const name = new URL(path).searchParams.get('name');
      assert.ok(!state.assets.some(value => value.name === name));
      const asset = {id: nextAsset++, name, state: 'uploaded', size: request.body.length, digest: `sha256:${sha256(request.body)}`};
      state.assets.push(asset);
      state.contents.set(asset.id, Buffer.from(request.body));
      response = {status: 201, body: {...asset}};
    } else if (method === 'PATCH' && path === '/releases/1') {
      assert.deepEqual(request.body, {draft: false, make_latest: 'false'});
      assert.equal(state.assets.length, payloads.size + 1);
      state.releases[0].draft = false;
      state.releases[0].immutable = true;
      response = reply({...state.releases[0]});
    } else throw new Error(`unexpected mutation ${method} ${path}`);
    if (state.failAfter?.(request)) throw new Error('transport lost after mutation');
    return response;
  }};
  const options = {recordBytes, payloads, client,
    admit: async input => { state.admissions.push(input.stage); assert.equal(sha256(input.recordBytes), sha256(recordBytes)); },
    verifyPublished: async input => { state.verified.push(input.release.id); assert.equal(input.release.immutable, true); },
  };
  return {state, options, record, publish: overrides => publishHoros({...options, ...overrides}), writes: () => state.calls.filter(call => call.method !== 'GET')};
}

test('publishes exact staged bytes and authenticates final immutable publication', async () => {
  const f = fixture();
  assert.equal((await f.publish()).status, 'published');
  assert.deepEqual(f.state.admissions, ['prepare', 'publish']);
  assert.deepEqual(f.state.verified, [1]);
  assert.equal(f.writes().length, 7);
  assert.deepEqual(f.state.assets.map(value => value.name), ['release.json', ...f.options.payloads.keys()]);
  for (let index = 0; index < f.state.calls.length; index++) {
    if (f.state.calls[index].method === 'GET') continue;
    assert.equal(f.state.calls[index - 1].path, '/immutable-releases');
    assert.equal(f.state.calls[index - 2].path, '/actions/variables/RELEASE_PUBLICATION_ENABLED');
    assert.equal(f.state.calls[index - 3].path, '/actions/variables/REPOSITORY_AUTOMATION');
  }
});

test('identical completed publication is a verified no-op even with controls disabled', async () => {
  const f = fixture();
  await f.publish();
  f.state.calls = []; f.state.mode = 'off'; f.state.enabled = 'false';
  assert.equal((await f.publish()).status, 'unchanged');
  assert.equal(f.writes().length, 0);
  assert.equal(f.state.admissions.at(-1), 'existing');
  assert.equal(f.state.verified.length, 2);
});

test('off defaults and separate publication control prevent every mutation', async () => {
  for (const [mode, enabled] of [['off', 'true'], ['promote', 'false'], [null, 'true'], ['propose', null]]) {
    const f = fixture(); f.state.mode = mode; f.state.enabled = enabled;
    assert.equal((await f.publish()).status, 'disabled');
    assert.equal(f.writes().length, 0);
    assert.deepEqual(f.state.admissions, []);
  }
  const f = fixture(); f.state.mode = 'propose';
  assert.equal((await f.publish()).status, 'published');
});

test('missing disabled or unproven immutable setting blocks before writes', async () => {
  for (const change of [{immutableStatus: 403}, {immutableStatus: 404}, {immutable: {enabled: false, enforced_by_owner: false}}, {immutable: {enabled: true}}]) {
    const f = fixture(); Object.assign(f.state, change);
    await assert.rejects(f.publish(), /immutable/);
    assert.equal(f.writes().length, 0);
  }
});

test('unknown controls and wrong numeric repository fail closed', async () => {
  for (const change of [{mode: 'yes'}, {enabled: 'TRUE'}, {repositoryId: 1}]) {
    const f = fixture(); Object.assign(f.state, change);
    await assert.rejects(f.publish());
    assert.equal(f.writes().length, 0);
  }
});

test('tag conflicts and source tree mismatch preserve every existing object', async () => {
  for (const change of [{tag: {type: 'commit', sha: 'd'.repeat(40)}}, {tree: 'd'.repeat(40)}]) {
    const f = fixture(); Object.assign(f.state, change);
    await assert.rejects(f.publish(), /conflicting|tree/);
    assert.equal(f.writes().length, 0);
  }
});

test('annotated exact-source tags are resolved without retagging', async () => {
  const f = fixture(); f.state.tag = {type: 'tag', sha: 'd'.repeat(40)};
  await f.publish();
  assert.ok(!f.writes().some(call => call.path === '/git/refs'));
});

test('conflicting draft metadata is never overwritten', async () => {
  for (const field of ['body', 'target_commitish', 'name']) {
    const f = fixture(); await f.publish();
    f.state.releases[0].draft = true; f.state.releases[0][field] = 'human content'; f.state.calls = [];
    await assert.rejects(f.publish(), /conflicting draft/);
    assert.equal(f.writes().length, 0);
  }
});

test('corrupt downloaded bytes conflict despite unchanged advertised digest', async () => {
  const f = fixture(); await f.publish();
  const asset = f.state.assets.find(value => value.name === 'source.tar');
  f.state.contents.set(asset.id, Buffer.alloc(asset.size, 0)); f.state.calls = [];
  await assert.rejects(f.publish(), /downloaded release asset/);
  assert.equal(f.writes().length, 0);
});

test('unexpected duplicate starter and missing final assets cannot be published', async () => {
  for (const mutate of [
    state => state.assets.push({...state.assets[0], id: 99, name: 'unexpected.txt'}),
    state => state.assets.push({...state.assets[0], id: 99}),
    state => { state.assets[0].state = 'starter'; },
    state => { state.assets.pop(); },
  ]) {
    const f = fixture(); await f.publish(); mutate(f.state); f.state.calls = [];
    await assert.rejects(f.publish());
    assert.equal(f.writes().length, 0);
  }
});

test('conflicting partial draft is inspected before creating a missing tag', async () => {
  const f = fixture(); await f.publish();
  f.state.releases[0].draft = true; f.state.tag = null;
  f.state.assets[0].state = 'starter'; f.state.calls = [];
  await assert.rejects(f.publish(), /incomplete release asset/);
  assert.equal(f.writes().length, 0);
});

test('final release source tree and immutable flag remain required on no-op recovery', async () => {
  for (const mutate of [state => { state.tree = 'd'.repeat(40); }, state => { state.releases[0].immutable = false; }]) {
    const f = fixture(); await f.publish(); mutate(f.state); f.state.calls = [];
    await assert.rejects(f.publish(), /tree|mutable/);
    assert.equal(f.writes().length, 0);
  }
});

test('uncertain successful tag draft upload and publication writes are reobserved once', async () => {
  const f = fixture(); f.state.failAfter = () => true;
  assert.equal((await f.publish()).status, 'published');
  assert.equal(f.writes().length, 7);
});

test('uncertain absent write is never blindly retried', async () => {
  const f = fixture(); f.state.failBefore = () => true;
  await assert.rejects(f.publish(), /not confirmed/);
  assert.equal(f.writes().length, 1);
  assert.ok(f.state.calls.at(-1).path.startsWith('/git/ref/'));
});

test('resume uploads only missing identical bytes after interrupted transport', async () => {
  const f = fixture();
  f.state.failBefore = request => request.path.includes('name=inventory.json');
  await assert.rejects(f.publish(), /not confirmed/);
  assert.deepEqual(f.state.assets.map(value => value.name), ['release.json', 'source.tar']);
  f.state.failBefore = null; f.state.calls = [];
  assert.equal((await f.publish()).status, 'published');
  assert.deepEqual(f.writes().filter(call => call.method === 'POST').map(call => new URL(call.path).searchParams.get('name')), ['inventory.json', 'evidence.json']);
});

test('control pause immediately before a later write stops remaining mutations', async () => {
  const f = fixture();
  f.state.onRequest = (request, state) => {
    if (request.path === '/actions/variables/REPOSITORY_AUTOMATION' && state.tag) state.mode = 'off';
  };
  await assert.rejects(f.publish(), /disabled/);
  assert.equal(f.writes().length, 1);
  assert.equal(f.state.releases.length, 0);
});

test('trusted admission failure and final attestation failure are never success', async () => {
  const f = fixture();
  await assert.rejects(f.publish({admit: async () => { throw new Error('unqualified subject'); }}), /unqualified/);
  assert.equal(f.writes().length, 0);
  await assert.rejects(f.publish({verifyPublished: async () => { throw new Error('invalid release attestation'); }}), /attestation/);
  assert.equal(f.state.releases[0].draft, false);
  assert.equal(f.writes().filter(call => call.method === 'PATCH').length, 1);
});

test('frozen bytes survive caller mutation and publisher never builds replacement artifacts', async () => {
  const f = fixture();
  const original = Buffer.from(f.options.payloads.get('source.tar'));
  await f.publish({admit: async input => {
    f.options.payloads.get('source.tar').fill(0); input.payloads.get('source.tar').fill(0);
    input.recordBytes.fill(0);
  }});
  const asset = f.state.assets.find(value => value.name === 'source.tar');
  assert.deepEqual(f.state.contents.get(asset.id), original);
});

test('release pagination includes matching drafts after the first hundred results', async () => {
  const f = fixture(); await f.publish();
  f.state.extraReleases = Array.from({length: 100}, (_, i) => ({id: i + 100, tag_name: `v0.0.${i}`, draft: false}));
  f.state.calls = [];
  assert.equal((await f.publish()).status, 'unchanged');
  assert.ok(f.state.calls.some(call => call.path === '/releases?per_page=100&page=2'));
  assert.equal(f.writes().length, 0);
});

test('payload corruption and foreign repository records fail before network access', async () => {
  const f = fixture();
  f.options.payloads.get('source.tar').fill(0);
  await assert.rejects(f.publish(), /payload changed/);
  assert.equal(f.state.calls.length, 0);
  const p = fixture(), foreign = produceRecord(metadata('kosmos'), p.options.payloads);
  await assert.rejects(p.publish({recordBytes: foreign}));
  assert.equal(p.state.calls.length, 0);
});
