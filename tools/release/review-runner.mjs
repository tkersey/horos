import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {appendFileSync, mkdirSync, realpathSync, writeFileSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {observeHorosReview, automationMode} from './review-observer.mjs';
import {readActiveReview, reviewEnvelope, reviewNames} from './review-result.mjs';
import {authenticateWorkflowArtifact, workflowPages} from './workflow-artifact.mjs';
import {executeReviewTurn} from './review-job.mjs';
import {ownerTurnDeadline, ownerStepTimeoutMs} from './owner-process.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRegular} from './review-owner.mjs';
import {sha256} from './encoding.mjs';
import {GitHubReader} from './github.mjs';
import {reviewArchives} from './review-tools.mjs';
import {observeHorosBootstrap, pendingHorosBootstrap} from './bootstrap-review.mjs';
import {readReviewResult} from './review-result.mjs';
import {requireCurrentImpact} from './impact.mjs';

export const automatedReviewSettings = Object.freeze({model: 'gpt-6-astra', reasoningEffort: 'high', serviceTier: 'priority'});

function git(directory, args) {
  return execFileSync('git', ['--no-replace-objects', '-c', 'core.hooksPath=/dev/null', '-c', 'protocol.file.allow=never', ...args],
    {cwd: directory, encoding: 'utf8', timeout: 120000, maxBuffer: 8 * 1024 * 1024,
      env: {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_TERMINAL_PROMPT: '0'}}).trimEnd();
}

function output(values) {
  if (!process.env.GITHUB_OUTPUT) return;
  for (const [key, value] of Object.entries(values)) {
    assert.match(key, /^[a-z_]+$/); assert.ok(!/[\r\n]/.test(String(value)));
    appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
  }
}

async function workflowDigest(commit) {
  const reader = new GitHubReader('tkersey/horos');
  const value = await reader.api(`contents/.github/workflows/repository-review.yml?ref=${commit}`);
  assert.equal(value.type, 'file'); assert.equal(value.encoding, 'base64');
  return sha256(Buffer.from(value.content.replaceAll('\n', ''), 'base64'));
}

export async function prepareReviewPlan(controlDirectory, outputDirectory, requestedPull = null) {
  const controlCommit = git(controlDirectory, ['rev-parse', 'HEAD']);
  assert.equal(git(controlDirectory, ['status', '--porcelain=v1', '--untracked-files=no']), '', 'control checkout changed');
  const bootstrap = bootstrapInput(process.env);
  assert.ok(bootstrap === null || requestedPull === null, 'choose a pull or a bootstrap source range');
  const pending = requestedPull === null ? await pendingHorosBootstrap(controlCommit) : null;
  if (pending && bootstrap) {
    assert.equal(bootstrap.base, pending.envelope.context.base);
    assert.equal(bootstrap.initialVersion, pending.envelope.context.bootstrap.initialVersion);
    assert.deepEqual(bootstrap.declaration, pending.envelope.context.impact.declaration, 'pending bootstrap inputs changed');
  }
  const result = pending ? await observeHorosBootstrap({controlCommit, original: pending}) : bootstrap ?
    await observeHorosBootstrap({controlCommit, request: bootstrap}) : await observeHorosReview({controlCommit, requestedPull});
  mkdirSync(outputDirectory, {recursive: true, mode: 0o700});
  writeFileSync(join(outputDirectory, 'plan.json'), JSON.stringify({controlCommit, ...result}), {flag: 'wx', mode: 0o600});
  output({ready: result.status === 'ready', ...(result.status === 'ready' ? reviewNames(result.context.base, result.context.head,
    result.context.bootstrap ? 'bootstrap' : 'pull') : {})});
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\nReview observation: ${JSON.stringify(result.status)}\n\n${JSON.stringify(result.observations ?? [])}\n`);
  return result;
}

export async function prepareReviewRuntime({planPath, toolsPath, runtimeDirectory, outputDirectory}) {
  assert.equal(process.platform, 'linux', 'automated owner execution requires native Linux');
  assert.equal(process.arch, 'x64', 'automated owner execution requires native x86-64');
  const plan = parseEvidenceJson(readRegular(planPath, 4 * 1024 * 1024));
  assert.equal(plan.status, 'ready');
  const priorBootstrap = plan.context.bootstrap && plan.previous !== null ? await readReviewResult({...plan.context, purpose: 'bootstrap'}) : null;
  const refreshed = plan.context.bootstrap ? await observeHorosBootstrap({controlCommit: plan.controlCommit,
    ...(priorBootstrap ? {original: priorBootstrap} : {request: {base: plan.context.base,
      initialVersion: plan.context.bootstrap.initialVersion, declaration: plan.context.impact.declaration}})}) :
    await observeHorosReview({controlCommit: plan.controlCommit, requestedPull: plan.context.pullNumber});
  assert.equal(refreshed.status, 'ready');
  assert.deepEqual(refreshed.context, plan.context, 'review inputs changed during preparation');
  assert.deepEqual(refreshed.previous, plan.previous, 'original owner progressed during preparation');
  assert.ok(typeof process.env.REPOSITORY_REVIEW_AUTH_JSON === 'string' && process.env.REPOSITORY_REVIEW_AUTH_JSON.length > 0,
    'missing REPOSITORY_REVIEW_AUTH_JSON model authentication');
  parseEvidenceJson(process.env.REPOSITORY_REVIEW_AUTH_JSON);
  const tools = parseEvidenceJson(readRegular(toolsPath, 1024 * 1024));
  for (const name of ['cas', 'codex']) {
    assert.equal(tools[`${name}Sha256`], reviewArchives[name].binarySha256);
    assert.equal(sha256(readRegular(tools[`${name}Path`], 512 * 1024 * 1024)), reviewArchives[name].binarySha256);
  }
  const runtime = realpathSync(runtimeDirectory), repositoryPath = join(runtime, 'candidate');
  mkdirSync(repositoryPath, {mode: 0o700});
  git(repositoryPath, ['init', '--quiet']);
  git(repositoryPath, ['fetch', '--quiet', '--no-tags', 'https://github.com/tkersey/horos.git', plan.context.base, plan.context.head]);
  git(repositoryPath, ['checkout', '--quiet', '--detach', plan.context.head]);
  assert.equal(git(repositoryPath, ['rev-parse', 'HEAD']), plan.context.head);
  assert.equal(git(repositoryPath, ['rev-parse', 'HEAD^{tree}']), plan.context.tree);
  assert.equal(git(repositoryPath, ['status', '--porcelain=v1', '--untracked-files=all']), '');
  const prepared = {...plan, tools, repositoryPath, root: join(runtime, 'active'), outputDirectory: resolve(outputDirectory),
    settings: automatedReviewSettings, workflowSha256: await workflowDigest(plan.controlCommit)};
  const configPath = join(runtime, 'review-runtime.json');
  writeFileSync(configPath, JSON.stringify(prepared), {flag: 'wx', mode: 0o400});
  const start = {schema: 'repository-review-start/v1', base: plan.context.base, head: plan.context.head,
    controlCommit: plan.controlCommit, contextSha256: sha256(Buffer.from(JSON.stringify(plan.context))),
    previous: plan.previous, runId: process.env.GITHUB_RUN_ID};
  writeFileSync(join(outputDirectory, reviewNames(plan.context.base, plan.context.head, plan.context.bootstrap ? 'bootstrap' : 'pull').start), JSON.stringify(start), {flag: 'wx', mode: 0o400});
  return {configPath};
}

export async function runPreparedReview(configPath) {
  const stepStarted = performance.now();
  const config = parseEvidenceJson(readRegular(configPath, 4 * 1024 * 1024));
  assert.notEqual(await automationMode(), 'off', 'automation paused before owner admission');
  const reader = new GitHubReader('tkersey/horos');
  const runId = Number(process.env.GITHUB_RUN_ID);
  assert.ok(Number.isSafeInteger(runId) && runId > 0, 'original owner workflow run is missing');
  const jobs = await workflowPages(reader, `actions/runs/${runId}/jobs?filter=latest`, 'jobs');
  const current = jobs.filter(job => job.name === 'Owner review');
  assert.equal(current.length, 1, 'original owner job is missing or ambiguous');
  assert.equal(current[0].run_id, runId); assert.equal(current[0].head_sha, config.controlCommit);
  assert.equal(current[0].status, 'in_progress');
  const deadline = ownerTurnDeadline({stepStarted, jobStarted: Date.parse(current[0].started_at)});
  if (config.context.bootstrap) {
    assert.equal((await reader.api('git/ref/heads/main')).object.sha, config.controlCommit);
  } else {
    const pull = await reader.api(`pulls/${config.context.pullNumber}`);
    assert.equal(pull.head.sha, config.context.head); assert.equal(pull.base.sha, config.controlCommit);
    assert.equal(pull.state, 'open'); assert.equal(pull.draft, false);
    assert.ok(!pull.labels.some(label => label.name === 'automation-hold'));
    requireCurrentImpact(config.context.impact, pull.body, config.context.base, config.context.head);
  }
  let previous = null, activeState = null;
  if (config.previous !== null) {
    const authenticated = await authenticateWorkflowArtifact({repository: config.context.repository, runId: config.previous.runId,
      controlCommit: config.previous.controlCommit, workflowPath: '.github/workflows/repository-review.yml', workflowSha256: config.previous.workflowSha256,
      jobName: 'Owner review', name: reviewNames(config.context.base, config.context.head, config.context.bootstrap ? 'bootstrap' : 'pull').result});
    const envelope = reviewEnvelope(authenticated.bytes, config.context);
    previous = {status: envelope.status, envelope, ...authenticated};
    assert.equal(previous.status, 'pending');
    assert.equal(previous.run.id, config.previous.runId);
    assert.equal(previous.artifact.id, config.previous.artifactId);
    assert.equal(sha256(previous.bytes), config.previous.sha256);
    activeState = await readActiveReview(previous, config.context);
  }
  const authentication = Buffer.from(process.env.REPOSITORY_REVIEW_AUTH_JSON ?? '');
  assert.ok(authentication.length > 0, 'missing model authentication');
  const result = await executeReviewTurn({...config, previous, activeState, authentication, timeoutMs: ownerStepTimeoutMs, deadline});
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\nOwner review: ${result.status}\n\n${result.reason}\n`);
  return result;
}

export function bootstrapInput(environment) {
  if (!environment.BOOTSTRAP_BASE) {
    for (const name of ['BOOTSTRAP_VERSION', 'BOOTSTRAP_RATIONALE', 'BOOTSTRAP_CONTRACTS']) {
      assert.ok(!environment[name], 'bootstrap source base is missing');
    }
    return null;
  }
  return {base: environment.BOOTSTRAP_BASE, initialVersion: environment.BOOTSTRAP_VERSION,
    declaration: {impact: environment.BOOTSTRAP_IMPACT, disposition: environment.BOOTSTRAP_DISPOSITION,
      rationale: environment.BOOTSTRAP_RATIONALE, contracts: parseEvidenceJson(environment.BOOTSTRAP_CONTRACTS)}};
}

if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2);
  let result;
  if (command === 'plan') {
    assert.ok(args.length === 2 || args.length === 3);
    const number = args[2] === undefined || args[2] === '' ? null : Number(args[2]);
    assert.ok(number === null || (Number.isSafeInteger(number) && number > 0));
    result = await prepareReviewPlan(resolve(args[0]), resolve(args[1]), number);
  } else if (command === 'prepare') {
    assert.equal(args.length, 4);
    result = await prepareReviewRuntime({planPath: resolve(args[0]), toolsPath: resolve(args[1]), runtimeDirectory: resolve(args[2]), outputDirectory: resolve(args[3])});
  } else if (command === 'run') {
    assert.equal(args.length, 1); result = await runPreparedReview(resolve(args[0]));
  } else throw new Error('expected plan CONTROL OUTPUT [PULL], prepare PLAN TOOLS RUNTIME OUTPUT, or run CONFIG');
  process.stdout.write(`${JSON.stringify(result.context ? {status: result.status, head: result.context.head, pullNumber: result.context.pullNumber} : result)}\n`);
}
