import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import {main} from './cli.mjs';

test('release commands reject missing or unknown operations before execution', async () => {
  for (const args of [[], ['invented'], ['review-owner'], ['admit-release'],
    ['admit-release', 'tkersey/horos', '1; command', '/tmp/unused'], ['check-qualification', 'latest', 'main', 'tree']]) {
    await assert.rejects(main(args));
  }
});

test('release command failure exits nonzero without emitting a success record', () => {
  const result = spawnSync(process.execPath, ['tools/release/cli.mjs', 'invented'], {encoding: 'utf8'});
  assert.notEqual(result.status, 0);
  assert.equal(result.stdout, '');
});
