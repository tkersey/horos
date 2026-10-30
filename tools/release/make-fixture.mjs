import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {parseExactJson} from '../v2/exact_json.mjs';
import {assembleHoros} from './assemble.mjs';
import {metadata} from './test-support.mjs';

const [directory, repository] = process.argv.slice(2);
assert.ok(directory && repository && process.argv.length === 4, 'expected native output directory and frozen repository');
const inventoryBytes = readFileSync(join(directory, 'source.json'));
const inventory = parseExactJson(inventoryBytes);
assert.match(inventory.commit, /^[0-9a-f]{40}$/);
const manifest = execFileSync('git', ['--no-replace-objects', 'show', `${inventory.commit}:build.zig.zon`], {cwd: repository});
const input = metadata();
input.artifacts[1].name = 'source.json';
input.qualification.run.commit = inventory.commit;
input.qualification.run.tree = inventory.tree;
input.review.subject.head = inventory.commit;
input.review.subject.tree = inventory.tree;
input.review.landing.commit = inventory.commit;
input.review.landing.tree = inventory.tree;
input.compatibility.rationale = 'Compatibility fixture only. Source facts come from the native producer; review, qualification, and admission fields are synthetic and confer no production authority.';
const evidence = Buffer.from(`${JSON.stringify({fixture: true, authority: 'none',
  statement: 'No review, qualification, signer, or publication credit.'})}\n`);
const payloads = new Map([
  ['source.tar', readFileSync(join(directory, 'source.tar'))],
  ['source.json', inventoryBytes],
  ['evidence.json', evidence],
]);
const record = assembleHoros(input, payloads, manifest);
const output = new URL('../../test/fixtures/release/', import.meta.url);
writeFileSync(new URL('horos-v1.json', output), record);
writeFileSync(new URL('source.json', output), inventoryBytes);
writeFileSync(new URL('build.zig.zon.txt', output), manifest);
writeFileSync(new URL('evidence.json', output), evidence);
