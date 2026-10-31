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

test('explicit transport limits preserve canonical bytes without widening ordinary records', () => {
  const limits = {maximumBytes: 4 * maximumRecordBytes, maximumValues: 65536, maximumDepth: 33};
  let nested = null;
  for (let index = 0; index < 33; index++) nested = {nested};
  for (const value of [{value: 'x'.repeat(maximumRecordBytes)}, Array(32768).fill(null), nested]) {
    assert.throws(() => encodeRecord(value));
    const bytes = encodeRecord(value, limits);
    assert.deepEqual(decodeRecord(bytes, limits), value);
    assert.throws(() => decodeRecord(bytes));
  }
  const ordinary = {z: ['x', true, null], a: {b: 1}};
  assert.deepEqual(encodeRecord(ordinary, limits), encodeRecord(ordinary));
  assert.throws(() => decodeRecord(Buffer.from('{"z":1,"a":2}\n'), limits), /noncanonical/);
  assert.throws(() => decodeRecord(Buffer.from('{"a":1,"a":2}\n'), limits), /noncanonical/);
});

test('explicit transport limits remain finite and enforce each resource bound', () => {
  for (const field of ['maximumBytes', 'maximumValues', 'maximumDepth']) {
    for (const invalid of [Infinity, NaN, 0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
      assert.throws(() => encodeRecord(null, {[field]: invalid}), /invalid record limit/);
      assert.throws(() => decodeRecord(Buffer.from('null\n'), {[field]: invalid}), /invalid record limit/);
    }
  }
  assert.throws(() => encodeRecord('abc', {maximumBytes: 5}), /too large/);
  assert.throws(() => encodeRecord([null, null], {maximumValues: 2}), /complexity/);
  assert.throws(() => encodeRecord({a: {b: null}}, {maximumDepth: 1}), /complexity/);
});
