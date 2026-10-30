import assert from 'node:assert/strict';

export function parseEvidenceJson(input, maximumBytes = 64 * 1024 * 1024) {
  assert.ok(Number.isSafeInteger(maximumBytes) && maximumBytes > 0 && maximumBytes <= 256 * 1024 * 1024);
  const text = typeof input === 'string' ? input : new TextDecoder('utf-8', {fatal: true}).decode(input);
  assert.ok(Buffer.byteLength(text) <= maximumBytes, 'evidence JSON too large');
  const token = /\s+|"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"|[{}\[\]:,]|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null/y;
  const stack = [];
  let offset = 0, count = 0;
  while (offset < text.length) {
    token.lastIndex = offset;
    const match = token.exec(text);
    assert.ok(match, 'invalid evidence JSON token');
    offset = token.lastIndex;
    const value = match[0];
    if (/^\s/.test(value)) continue;
    assert.ok(++count <= 2000000, 'evidence JSON too complex');
    const top = stack.at(-1);
    if (value === '{' || value === '[') {
      assert.ok(stack.length < 64, 'evidence JSON too deep');
      stack.push(value === '{' ? {keys: new Set(), key: true} : null);
    } else if (value === '}' || value === ']') stack.pop();
    else if (top && value === ':') top.key = false;
    else if (top && value === ',') top.key = true;
    else if (top?.key && value.startsWith('"')) {
      const key = JSON.parse(value);
      assert.ok(!top.keys.has(key), 'duplicate evidence field');
      top.keys.add(key);
    }
  }
  return JSON.parse(text, (_key, value) => {
    if (typeof value === 'number') assert.ok(Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value)), 'unsafe evidence number');
    if (typeof value === 'string') assert.ok(value.isWellFormed(), 'invalid evidence Unicode');
    return value;
  });
}
