import assert from 'node:assert/strict';
import {HorosPublicationClient, executeGitHub} from './publish-github.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

export class HorosProposalClient extends HorosPublicationClient {
  constructor(execute = executeGitHub) { super(execute); }

  async graphql(query, variables) {
    assert.ok(typeof query === 'string' && query.length <= 32768);
    const input = Buffer.from(JSON.stringify({query, variables}));
    assert.ok(input.length <= 1024 * 1024);
    const result = await this.execute(['api', 'graphql', '--hostname', 'github.com', '--method', 'POST',
      '--input', '-', '-H', 'Content-Type: application/json'], input, 8 * 1024 * 1024);
    assert.equal(result.code, 0, 'GitHub GraphQL transport failed');
    assert.ok(Buffer.isBuffer(result.stdout) && result.stdout.length <= 8 * 1024 * 1024);
    const output = parseEvidenceJson(result.stdout);
    assert.equal(output.errors, undefined, 'GitHub GraphQL request rejected');
    assert.ok(output.data && typeof output.data === 'object', 'missing GitHub GraphQL data');
    return output.data;
  }
}
