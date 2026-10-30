import assert from 'node:assert/strict';
import test from 'node:test';
import {HorosProposalClient} from './proposal-github.mjs';

test('GraphQL uses fixed host structured variables and exact stdin', async () => {
  const client = new HorosProposalClient(async (args, input) => {
    assert.deepEqual(args.slice(0, 6), ['api', 'graphql', '--hostname', 'github.com', '--method', 'POST']);
    assert.deepEqual(JSON.parse(input), {query: 'mutation Example($input:Input!){example(input:$input){id}}', variables: {input: {message: 'literal `command` $(x)\n'}}});
    return {code: 0, stdout: Buffer.from('{"data":{"example":{"id":"1"}}}')};
  });
  assert.deepEqual(await client.graphql('mutation Example($input:Input!){example(input:$input){id}}', {input: {message: 'literal `command` $(x)\n'}}), {example: {id: '1'}});
});

test('GraphQL partial errors missing data and failed transport cannot count as write success', async () => {
  for (const response of [{code: 1, stdout: Buffer.from('{}')}, {code: 0, stdout: Buffer.from('{"data":{},"errors":[{"message":"failed"}]}')},
    {code: 0, stdout: Buffer.from('{}')}, {code: 0, stdout: Buffer.from('{"data":{},"data":{}}')}]) {
    const client = new HorosProposalClient(async () => response);
    await assert.rejects(client.graphql('query {viewer{login}}', {}));
  }
});
