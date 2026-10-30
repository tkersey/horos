import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

export const maximumRecordBytes = 1024 * 1024;

function ordered(value, depth, budget) {
  assert.ok(depth <= 32 && --budget.remaining >= 0, 'record complexity exceeded');
  if (value === null || typeof value === 'boolean') return value;
  if (typeof value === 'string') {
    assert.ok(value.isWellFormed(), 'invalid Unicode');
    return value;
  }
  if (typeof value === 'number') {
    assert.ok(Number.isSafeInteger(value) && !Object.is(value, -0), 'unsafe number');
    return value;
  }
  assert.equal(typeof value, 'object', 'unsupported JSON value');
  if (Array.isArray(value)) {
    assert.equal(Object.keys(value).length, value.length, 'sparse or extended array');
    return value.map(item => ordered(item, depth + 1, budget));
  }
  assert.ok(Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null,
    'unsupported object');
  const result = Object.create(null);
  for (const key of Object.keys(value).sort()) {
    assert.ok(/^[A-Za-z][A-Za-z0-9_-]*$/.test(key), 'unsupported field name');
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    assert.ok(Object.hasOwn(descriptor, 'value'), 'accessor field');
    result[key] = ordered(descriptor.value, depth + 1, budget);
  }
  return result;
}

export function encodeRecord(value) {
  const bytes = Buffer.from(`${JSON.stringify(ordered(value, 0, {remaining: 32768}))}\n`, 'utf8');
  assert.ok(bytes.length <= maximumRecordBytes, 'record too large');
  return bytes;
}

export function decodeRecord(bytes) {
  assert.ok(Buffer.isBuffer(bytes) && bytes.length <= maximumRecordBytes, 'record too large or not bytes');
  const text = new TextDecoder('utf-8', {fatal: true}).decode(bytes);
  const value = JSON.parse(text);
  assert.ok(encodeRecord(value).equals(bytes), 'noncanonical or ambiguous record');
  return value;
}

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}
