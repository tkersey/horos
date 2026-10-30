import assert from 'node:assert/strict';
import test from 'node:test';
import {decodeRecord, encodeRecord, maximumRecordBytes, sha256} from './encoding.mjs';

test('encoding has one exact byte representation independent of insertion order', () => {
  const left = {schema: 'repository-release/v1', dependencies: [{tree: 'abc', commit: 'def'}]};
  const right = {dependencies: [{commit: 'def', tree: 'abc'}], schema: 'repository-release/v1'};
  assert.deepEqual(encodeRecord(left), encodeRecord(right));
  assert.deepEqual(decodeRecord(encodeRecord(left)), left);
  assert.equal(sha256(Buffer.from('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

for (const input of [
  '{"schema":"a","schema":"b"}\n',
  '{"schema":"a","\\u0073chema":"a"}\n',
  '{"z":1,"a":2}\n',
  '{"number":9007199254740993}\n',
  '{"number":1.0}\n',
  '{"number":-0}\n',
  '{"value":"\\ud800"}\n',
  '{"value":1} ',
  '{"__proto__":{}}\n',
]) {
  test(`reject ambiguous or unsupported encoding ${input.trim()}`, () => {
    assert.throws(() => decodeRecord(Buffer.from(input)));
  });
}

test('reject invalid UTF-8 and bounded byte/depth/node excess', () => {
  assert.throws(() => decodeRecord(Buffer.from([0xff])));
  assert.throws(() => decodeRecord(Buffer.alloc(maximumRecordBytes + 1)));
  assert.throws(() => encodeRecord({value: 'x'.repeat(maximumRecordBytes)}));
  assert.throws(() => encodeRecord(Array(32769).fill(null)));
  let nested = null;
  for (let index = 0; index < 34; index++) nested = {nested};
  assert.throws(() => encodeRecord(nested));
});

test('reject values JSON would silently omit or normalize', () => {
  for (const value of [undefined, NaN, Infinity, -0, 1.2, 1n, new Date(), {value: undefined}, Array(2)]) {
    assert.throws(() => encodeRecord(value));
  }
  assert.throws(() => encodeRecord({get value() { throw new Error('accessor executed'); }}), /accessor field/);
});
