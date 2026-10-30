import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {installReviewTools} from './review-tools.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';

export async function smokeReviewTools(directory) {
  assert.equal(process.platform, 'linux'); assert.equal(process.arch, 'x64');
  const root = resolve(directory); mkdirSync(root, {mode: 0o700});
  const tools = await installReviewTools(join(root, 'tools'));
  const home = join(root, 'home'), workspace = join(root, 'workspace'), capture = join(root, 'capture');
  for (const path of [home, workspace, capture, join(workspace, 'tmp'), join(workspace, 'cache'), join(workspace, 'reviewer-home')]) mkdirSync(path, {mode: 0o700});
  const script = join(capture, 'probe.mjs');
  writeFileSync(script, [
    "import assert from 'node:assert/strict';",
    "import {readFileSync, writeFileSync} from 'node:fs';",
    "import {join} from 'node:path';",
    "assert.match(readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim(), /^[0-9a-f-]{36}$/);",
    "writeFileSync(join(process.cwd(), 'allowed'), 'allowed', {flag: 'wx'});",
    "assert.throws(() => writeFileSync(process.argv[2], 'forbidden', {flag: 'wx'}), error => ['EACCES', 'EPERM', 'EROFS'].includes(error.code));",
    "assert.throws(() => writeFileSync(process.argv[3], 'forbidden', {flag: 'wx'}), error => ['EACCES', 'EPERM', 'EROFS'].includes(error.code));",
    "process.stdout.write('native Linux sandbox source/capture confinement passed\\n');",
  ].join('\n'), {flag: 'wx', mode: 0o400});
  const env = {PATH: process.env.PATH, HOME: home, CODEX_HOME: home, TMPDIR: join(workspace, 'tmp'), XDG_CACHE_HOME: join(workspace, 'cache')};
  const sandbox = ['sandbox', '-c', 'sandbox_mode="workspace-write"',
    '-c', 'sandbox_workspace_write.exclude_tmpdir_env_var=true', '-c', 'sandbox_workspace_write.exclude_slash_tmp=true',
    '-c', 'sandbox_workspace_write.writable_roots=[]', '-c', 'sandbox_workspace_write.network_access=true'];
  execFileSync(tools.codexPath, [...sandbox, '--', process.execPath, script, join(capture, 'forbidden'),
    `/tmp/horos-forbidden-${process.pid}`], {cwd: workspace, env, timeout: 60000, maxBuffer: 1024 * 1024});
  assert.equal(readFileSync(join(workspace, 'allowed'), 'utf8'), 'allowed');
  const preflight = parseEvidenceJson(execFileSync(tools.codexPath, [...sandbox, '--', tools.casPath,
    'app-server', 'preflight', '--cwd', workspace, '--codex-path', tools.codexPath,
    '--profile', 'review', '--app-server-transport', 'managed-ws', '--json'],
  {cwd: workspace, env: {...env, CODEX_HOME: join(workspace, 'reviewer-home')}, timeout: 180000, maxBuffer: 8 * 1024 * 1024}));
  assert.equal(preflight.status, 'compatible'); assert.equal(preflight.profile, 'review');
  assert.equal(preflight.contractId, 'codex-app-server-capabilities-v2');
  assert.equal(preflight.codex.binaryDigest, `sha256:${tools.codexSha256}`);
  for (const probe of preflight.behavioralProbes) if (probe.requirement === 'required') assert.equal(probe.status, 'passed', probe.id);
  writeFileSync(join(root, 'preflight.json'), JSON.stringify(preflight), {flag: 'wx', mode: 0o400});
  return {status: 'compatible', platform: 'linux-x86_64', reviewExecuted: false};
}

if (import.meta.main) {
  assert.equal(process.argv.length, 3);
  process.stdout.write(`${JSON.stringify(await smokeReviewTools(process.argv[2]))}\n`);
}
