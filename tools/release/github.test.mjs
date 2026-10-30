import assert from 'node:assert/strict';
import test from 'node:test';
import {GitHubReader, selectSuccessor} from './github.mjs';

const a = 'a'.repeat(40), b = 'b'.repeat(40), c = 'c'.repeat(40);
const response = value => Buffer.from(JSON.stringify(value));

function reader(replies) {
  const calls = [];
  const github = new GitHubReader('tkersey/horos', async args => {
    calls.push(args);
    assert.equal(args[0], 'api');
    assert.ok(Object.hasOwn(replies, args[1]), `unexpected ${args[1]}`);
    return response(replies[args[1]]);
  });
  return {github, calls};
}

test('discovery reads every page and excludes drafts and unsupported prereleases', async () => {
  const first = Array.from({length: 100}, (_, index) => ({id: index + 1, draft: index === 0, prerelease: index === 1}));
  const {github, calls} = reader({
    'repos/tkersey/horos/releases?per_page=100&page=1': first,
    'repos/tkersey/horos/releases?per_page=100&page=2': [{id: 101, draft: false, prerelease: false}],
  });
  const values = await github.releases();
  assert.equal(values.length, 99);
  assert.equal(values.at(-1).id, 101);
  assert.equal(calls.length, 2);
});

test('pagination duplication rejects changing observations', async () => {
  const first = Array.from({length: 100}, (_, index) => ({id: index + 1, draft: false, prerelease: false}));
  const {github} = reader({
    'repos/tkersey/horos/releases?per_page=100&page=1': first,
    'repos/tkersey/horos/releases?per_page=100&page=2': [first[0]],
  });
  await assert.rejects(github.releases(), /pagination changed/);
});

test('annotated tags resolve to commits without trusting the release target hint', async () => {
  const {github} = reader({
    'repos/tkersey/horos/git/ref/tags/v1.0.0': {ref: 'refs/tags/v1.0.0', object: {type: 'tag', sha: a}},
    [`repos/tkersey/horos/git/tags/${a}`]: {sha: a, object: {type: 'tag', sha: b}},
    [`repos/tkersey/horos/git/tags/${b}`]: {sha: b, object: {type: 'commit', sha: c}},
  });
  assert.equal(await github.tagCommit('v1.0.0'), c);
  await assert.rejects(github.tagCommit('../main'));
});

test('cyclic and noncommit tags cannot be admitted', async () => {
  const {github} = reader({
    'repos/tkersey/horos/git/ref/tags/v1.0.0': {ref: 'refs/tags/v1.0.0', object: {type: 'tag', sha: a}},
    [`repos/tkersey/horos/git/tags/${a}`]: {sha: a, object: {type: 'tag', sha: a}},
  });
  await assert.rejects(github.tagCommit('v1.0.0'), /cycle/);
});

test('repository numeric identity prevents admission by name alone', async () => {
  const {github} = reader({'repos/tkersey/horos': {full_name: 'tkersey/horos', id: 1, default_branch: 'main'}});
  await assert.rejects(github.verifyRepository(), /identity changed/);
});

test('lineage observation rejects wrong base and unapproved rewrite', async () => {
  const {github} = reader({[`repos/tkersey/horos/compare/${a}...${b}`]: {base_commit: {sha: a}, merge_base_commit: {sha: c}, status: 'ahead'}});
  await assert.rejects(github.forward(a, b), /unapproved lineage/);
});

test('successor selection follows lineage regardless of API order or version', async () => {
  const lineage = [a, b, c];
  const github = {forward: async (base, head) => lineage.indexOf(base) <= lineage.indexOf(head)};
  const releases = [{id: 3, source: {commit: c, version: '1.0.0'}}, {id: 2, source: {commit: b, version: '9.0.0'}}];
  assert.equal((await selectSuccessor(github, a, releases)).id, 3);
  assert.equal((await selectSuccessor(github, a, [...releases].reverse())).id, 3);
  assert.equal(await selectSuccessor(github, c, releases), null);
});

test('divergent successors and conflicting publication identity block selection', async () => {
  const github = {forward: async (base, head) => base === a || base === head};
  await assert.rejects(selectSuccessor(github, a, [{id: 2, source: {commit: b}}, {id: 3, source: {commit: c}}]), /divergent/);
  await assert.rejects(selectSuccessor(github, a, [{id: 2, source: {commit: b}}, {id: 3, source: {commit: b}}]), /ambiguous/);
});
