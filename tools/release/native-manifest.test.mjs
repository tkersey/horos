import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {after, test} from 'node:test';
import {manifestOperations, prepareHorosCandidate, admitNativeVersion, classifyNativeVersion} from './native-manifest.mjs';
import {proposalDescription} from './proposal.mjs';

const directory = mkdtempSync(join(tmpdir(), 'horos-native-version-test-'));
after(() => rmSync(directory, {recursive: true, force: true}));
assert.equal(execFileSync('zig', ['version'], {encoding: 'utf8'}).trim(), '0.17.0');
const tool = join(directory, 'horos-manifest');
const cpu = process.platform === 'linux' && process.arch === 'x64' ? ['-mcpu', 'baseline'] : [];
execFileSync('zig', ['build-exe', resolve('tools/release_manifest.zig'), '-O', 'ReleaseSafe', ...cpu, `-femit-bin=${tool}`],
  {timeout: 90000, maxBuffer: 1024 * 1024});
const native = manifestOperations(tool), actor = {id: 42, login: 'horos-release[bot]'};
const bytes = Buffer.from('.{ .name = .horos, .version = "1.0.0", .paths = .{"1.0.0", "src"} }\n');

function fixture(t) {
  const repository = mkdtempSync(join(directory, 'repo-'));
  t.after(() => rmSync(repository, {recursive: true, force: true}));
  const date = '2026-10-30T00:00:00Z';
  const env = {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: actor.login, GIT_AUTHOR_EMAIL: `${actor.id}+${actor.login}@users.noreply.github.com`, GIT_AUTHOR_DATE: date,
    GIT_COMMITTER_NAME: actor.login, GIT_COMMITTER_EMAIL: `${actor.id}+${actor.login}@users.noreply.github.com`, GIT_COMMITTER_DATE: date};
  const git = (args, input) => execFileSync('git', ['-C', repository, ...args], {env, input, encoding: 'utf8'}).trimEnd();
  git(['init', '--quiet', '--bare']);
  const blob = git(['hash-object', '-w', '--stdin'], bytes), other = git(['hash-object', '-w', '--stdin'], 'preserve\n');
  const entries = [{mode: '100644', type: 'blob', path: 'README.md', sha: other},
    {mode: '100644', type: 'blob', path: 'build.zig.zon', sha: blob}];
  const tree = git(['mktree'], entries.map(row => `${row.mode} ${row.type} ${row.sha}\t${row.path}\n`).join(''));
  const base = git(['-c', 'commit.gpgsign=false', 'commit-tree', tree], 'base\n');
  const values = new Map([
    [`/contents/build.zig.zon?ref=${base}`, {type: 'file', encoding: 'base64', content: bytes.toString('base64'), sha: blob}],
    [`/git/commits/${base}`, {sha: base, tree: {sha: tree}, committer: {date}}],
    [`/git/trees/${tree}`, {sha: tree, truncated: false, tree: entries}],
  ]);
  const client = {async request({path, method = 'GET'}) {
    assert.equal(method, 'GET'); assert.ok(values.has(path), path); return {status: 200, body: structuredClone(values.get(path))};
  }};
  return {client, base, tree, values, git, entries};
}

test('native parser reads and prepares only the root version', () => {
  assert.equal(native.read(bytes), '1.0.0');
  assert.equal(native.prepare(bytes, '1.0.1').toString(), '.{ .name = .horos, .version = "1.0.1", .paths = .{"1.0.0", "src"} }\n');
  assert.deepEqual(native.prepare(bytes, '1.0.0'), bytes);
  assert.deepEqual(native.prepare(bytes, '1.0.1'), native.prepare(bytes, '1.0.1'));
});

test('native malformed, duplicate and overflowing version inputs fail', () => {
  for (const value of ['.{ .version = "1.0.0", .version = "2.0.0" }', '.{ .version = "01.0.0" }', '.{']) {
    assert.throws(() => native.read(Buffer.from(value)));
  }
  assert.throws(() => native.prepare(bytes, '9007199254740992.0.0'));
});

test('native candidate has independently checked deterministic Git identities', async t => {
  const value = fixture(t), input = {base: value.base, version: '1.0.1', actor};
  const candidate = await prepareHorosCandidate(input, {client: value.client, native});
  const blob = value.git(['hash-object', '-w', '--stdin'], candidate.manifestBytes);
  const tree = value.git(['mktree'], value.entries.map(row => `${row.mode} ${row.type} ${row.path === 'build.zig.zon' ? blob : row.sha}\t${row.path}\n`).join(''));
  assert.equal(candidate.tree, tree);
  assert.equal(candidate.head, value.git(['-c', 'commit.gpgsign=false', 'commit-tree', tree, '-p', value.base], candidate.message));
  assert.deepEqual(await prepareHorosCandidate(input, {client: value.client, native}), candidate);
  assert.equal(await prepareHorosCandidate({...input, version: '1.0.0'}, {client: value.client, native}), null);
  await admitNativeVersion(native)({candidate, baseManifest: bytes});
  await assert.rejects(() => admitNativeVersion(native)({candidate: {...candidate,
    manifestBytes: Buffer.from(candidate.manifestBytes.toString().replace('"src"', '"other"'))}, baseManifest: bytes}), /native version-only/);
});

test('generated version-only classification preserves ordinary change impact', async t => {
  const value = fixture(t), candidate = await prepareHorosCandidate({base: value.base, version: '1.0.1', actor}, {client: value.client, native});
  const classify = classifyNativeVersion({client: value.client, native, actor});
  const input = {subject: {base: value.base, head: candidate.head, tree: candidate.tree}, baseTree: value.tree,
    baseManifestBytes: bytes, manifestBytes: candidate.manifestBytes,
    pull: {user: actor, body: proposalDescription(candidate).body}, originalCommits: [{message: candidate.message}]};
  assert.deepEqual(await classify(input), {versionOnly: true});
  assert.deepEqual(await classify({...input, pull: {...input.pull, user: {id: 99, login: 'human'}}}), {versionOnly: false});
  assert.deepEqual(await classify({...input, manifestBytes: Buffer.from(candidate.manifestBytes.toString().replace('"src"', '"other"'))}), {versionOnly: false});
  assert.deepEqual(await classify({...input, pull: {...input.pull, body: input.pull.body + '\nReviewed explanation.\n'}}), {versionOnly: true});
  await assert.rejects(() => classify({...input, pull: {...input.pull, body: input.pull.body.replace('repository-proposal/v1', 'repository-proposal/v2')}}), /binding changed/);
});

test('tampered native executable and Git blob are rejected before candidate admission', async t => {
  const value = fixture(t);
  value.values.get(`/contents/build.zig.zon?ref=${value.base}`).content = Buffer.from('forged').toString('base64');
  await assert.rejects(() => prepareHorosCandidate({base: value.base, version: '1.0.1', actor}, {client: value.client, native}), /Git blob differs/);
  const fake = join(directory, 'changed-tool'); writeFileSync(fake, 'original');
  const operations = manifestOperations(fake); writeFileSync(fake, 'changed');
  assert.throws(() => operations.read(bytes), /native manifest tool changed/);
});
