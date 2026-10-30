import assert from 'node:assert/strict';
import test from 'node:test';
import {HorosPublicationClient} from './publish-github.mjs';

function response(status, body, code = 0) {
  return {code, stdout: Buffer.concat([Buffer.from(`HTTP/2.0 ${status} Result\nContent-Type: application/json\r\n\r\n`),
    Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body))])};
}

test('GitHub adapter uses structured argv and exact JSON stdin', async () => {
  const calls = [];
  const client = new HorosPublicationClient(async (...args) => { calls.push(args); return response(201, {id: 1}); });
  const body = {body: 'literal $(command) `code`\nnext line', draft: true};
  assert.equal((await client.request({method: 'POST', path: '/releases', body})).status, 201);
  assert.deepEqual(JSON.parse(calls[0][1]), body);
  assert.ok(calls[0][0].includes('--input'));
  assert.equal(calls[0][0][1], 'repos/tkersey/horos/releases');
  assert.ok(!calls[0][0].some(arg => arg.includes('literal')));
});

test('upload uses only fixed local repository uploads endpoint and exact binary stdin', async () => {
  const data = Buffer.from([0, 255, 13, 10]);
  const client = new HorosPublicationClient(async (args, input) => {
    assert.equal(args[1], 'https://uploads.github.com/repos/tkersey/horos/releases/1/assets?name=source.tar');
    assert.equal(args[args.indexOf('--method') + 1], 'POST');
    assert.deepEqual(input, data);
    return response(201, {id: 2});
  });
  await client.request({method: 'POST', path: 'https://uploads.github.com/repos/tkersey/horos/releases/1/assets?name=source.tar', body: data});
});

test('binary downloads preserve bytes after HTTP headers', async () => {
  const data = Buffer.from([0, 255, 10, 13, 0]);
  const client = new HorosPublicationClient(async args => {
    assert.ok(args.includes('Accept: application/octet-stream'));
    return response(200, data);
  });
  assert.deepEqual((await client.request({path: '/releases/assets/1', binary: true})).body, data);
});

test('HTTP absence differs from transport failure and oversized output', async () => {
  const absent = new HorosPublicationClient(async () => response(404, {message: 'Not Found'}, 1));
  assert.equal((await absent.request({path: '/immutable-releases'})).status, 404);
  const bad = new HorosPublicationClient(async () => ({code: 1, stdout: Buffer.from('network error')}));
  await assert.rejects(bad.request({path: '/releases'}), /HTTP status/);
  const truncated = new HorosPublicationClient(async () => response(200, Buffer.alloc(9)));
  await assert.rejects(truncated.request({path: '/releases/assets/1', binary: true, maximumBytes: 8}), /bound/);
});

test('cross-repository hosts traversal and destructive HTTP methods are rejected', async () => {
  const client = new HorosPublicationClient(async () => { throw new Error('must not execute'); });
  for (const path of ['https://evil.test/upload', 'https://uploads.github.com/repos/tkersey/kosmos/releases/1/assets?name=x',
    '/../../repos/other', '/releases\nheader', 'other/repository']) {
    await assert.rejects(client.request({method: 'POST', path, body: {}}), /invalid/);
  }
  for (const method of ['DELETE', 'PUT']) await assert.rejects(client.request({method, path: '/releases/1'}), /unsupported/);
});
