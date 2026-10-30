import assert from 'node:assert/strict';
import {readdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {run} from 'node:test';
import {fileURLToPath} from 'node:url';

const directory = process.argv[2] ?? fileURLToPath(new URL('.', import.meta.url));
const files = readdirSync(directory, {withFileTypes: true})
  .filter(entry => entry.isFile() && entry.name.endsWith('.test.mjs'))
  .map(entry => resolve(directory, entry.name)).sort();
assert.ok(files.length > 0, 'no release test files discovered');
const completed = new Set();
let summary;
for await (const {type, data} of run({files, timeout: 120000})) {
  if (type === 'test:fail') console.error(data);
  if (type !== 'test:summary') continue;
  assert.equal(data.success, true, 'release tests failed');
  for (const field of ['failed', 'cancelled', 'skipped', 'todo']) assert.equal(data.counts[field], 0, field);
  assert.ok(data.counts.tests > 0 && data.counts.passed > 0, 'no tests executed');
  if (data.file) {
    assert.ok(files.includes(data.file) && !completed.has(data.file), 'unexpected test summary');
    completed.add(data.file);
  } else summary = data;
}
assert.equal(completed.size, files.length, 'missing file test execution');
assert.ok(summary, 'missing terminal test result');
console.log(`${summary.counts.passed} release tests passed across ${completed.size} files.`);
