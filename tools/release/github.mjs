import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {parseEvidenceJson} from './evidence-json.mjs';
import {repositories} from './record.mjs';

const execute = promisify(execFile);

export async function githubCommand(args, maximumBytes = 8 * 1024 * 1024) {
  const {stdout} = await execute('gh', args, {encoding: 'buffer', maxBuffer: maximumBytes, timeout: 60000});
  return stdout;
}

function oid(value) {
  assert.match(value, /^[0-9a-f]{40}$/);
  return value;
}

export class GitHubReader {
  constructor(repository, command = githubCommand) {
    assert.ok(Object.hasOwn(repositories, repository), 'unsupported repository');
    this.repository = repository;
    this.command = command;
  }

  async api(path) {
    assert.equal(typeof path, 'string');
    assert.ok(!path.startsWith('/') && !path.split('/').some(part => part === '..' || part === '.') &&
      !/[\x00-\x20\x7f]/.test(path), 'unsafe API path');
    const bytes = await this.command(['api', `repos/${this.repository}/${path}`, '-H', 'Accept: application/vnd.github+json']);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length <= 8 * 1024 * 1024, 'API response too large');
    return parseEvidenceJson(bytes);
  }

  async verifyRepository() {
    const bytes = await this.command(['api', `repos/${this.repository}`, '-H', 'Accept: application/vnd.github+json']);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length <= 1024 * 1024, 'repository response too large');
    const value = parseEvidenceJson(bytes);
    assert.equal(value.full_name, this.repository);
    assert.equal(value.id, repositories[this.repository], 'repository identity changed');
    assert.equal(value.default_branch, 'main', 'unapproved default branch');
    return value;
  }

  async releases() {
    const releases = [], ids = new Set();
    for (let page = 1; page <= 100; page++) {
      const values = await this.api(`releases?per_page=100&page=${page}`);
      assert.ok(Array.isArray(values) && values.length <= 100, 'invalid release page');
      for (const value of values) {
        assert.ok(Number.isSafeInteger(value.id) && value.id > 0, 'invalid release identity');
        assert.ok(!ids.has(value.id), 'release pagination changed; re-observe');
        ids.add(value.id);
        assert.equal(typeof value.draft, 'boolean');
        assert.equal(typeof value.prerelease, 'boolean');
        if (!value.draft && !value.prerelease) releases.push(value);
      }
      if (values.length < 100) return releases;
    }
    throw new Error('release discovery capacity exceeded');
  }

  async tagCommit(tag) {
    assert.match(tag, /^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/);
    const ref = await this.api(`git/ref/tags/${encodeURIComponent(tag)}`);
    assert.equal(ref.ref, `refs/tags/${tag}`);
    let object = ref.object;
    const seen = new Set();
    for (let depth = 0; depth < 16; depth++) {
      oid(object.sha);
      assert.ok(!seen.has(object.sha), 'tag cycle');
      seen.add(object.sha);
      if (object.type === 'commit') return object.sha;
      assert.equal(object.type, 'tag', 'unsupported tag object');
      const value = await this.api(`git/tags/${object.sha}`);
      assert.equal(value.sha, object.sha, 'tag identity mismatch');
      object = value.object;
    }
    throw new Error('tag nesting capacity exceeded');
  }

  async forward(base, head) {
    oid(base);
    oid(head);
    const comparison = await this.api(`compare/${base}...${head}`);
    assert.equal(comparison.base_commit.sha, base, 'comparison base mismatch');
    assert.ok(['ahead', 'behind', 'identical', 'diverged'].includes(comparison.status), 'invalid comparison');
    if (comparison.status === 'ahead' || comparison.status === 'identical') {
      assert.equal(comparison.merge_base_commit.sha, base, 'unapproved lineage');
      if (comparison.status === 'identical') assert.equal(base, head);
      return true;
    }
    return false;
  }
}

export async function selectSuccessor(reader, selectedCommit, admitted) {
  oid(selectedCommit);
  const candidates = [];
  for (const release of admitted) {
    oid(release.source.commit);
    if (release.source.commit !== selectedCommit && await reader.forward(selectedCommit, release.source.commit)) {
      candidates.push(release);
    }
  }
  let successor = null;
  for (const candidate of candidates) {
    if (successor === null) successor = candidate;
    else if (candidate.source.commit === successor.source.commit) {
      assert.equal(candidate.id, successor.id, 'ambiguous publications for one source');
    } else if (await reader.forward(successor.source.commit, candidate.source.commit)) successor = candidate;
    else assert.ok(await reader.forward(candidate.source.commit, successor.source.commit), 'divergent successor publications');
  }
  return successor;
}
