import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

const runner = fileURLToPath(new URL('./test.mjs', import.meta.url));

for (const [name, source, succeeds] of [
  ['unmatched discovery', null, false],
  ['empty test file', '', false],
  ['skipped test', "import test from 'node:test'; test.skip('skip', () => {});", false],
  ['failed test', "import test from 'node:test'; test('fail', () => {throw Error('failure')});", false],
  ['executed test', "import test from 'node:test'; test('pass', () => {});", true],
]) {
  test(name, () => {
    const directory = mkdtempSync(join(tmpdir(), 'horos-release-discovery-'));
    try {
      if (source !== null) writeFileSync(join(directory, 'fixture.test.mjs'), source);
      const env = {...process.env};
      delete env.NODE_TEST_CONTEXT;
      const result = spawnSync(process.execPath, [runner, directory], {env, encoding: 'utf8', timeout: 10000});
      assert.equal(result.error, undefined);
      assert.equal(result.signal, null);
      assert.equal(result.status === 0, succeeds, result.stderr);
    } finally {
      rmSync(directory, {recursive: true, force: true});
    }
  });
}
