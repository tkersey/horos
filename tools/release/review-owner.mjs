import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {constants, closeSync, fstatSync, mkdirSync, openSync, readSync, realpathSync, writeFileSync} from 'node:fs';
import {basename, dirname, isAbsolute, join, relative, resolve, sep} from 'node:path';
import {parseEvidenceJson} from './evidence-json.mjs';
import {encodeRecord, sha256} from './encoding.mjs';
import {runOwnerProcess, remainingOwnerTime} from './owner-process.mjs';
import {validateOwnerEvidence} from './review-admission.mjs';
import {admitOwnerHistory} from './review-history.mjs';

export const reviewPolicyCommit = '7aac0823b02dc31905ba57521dd9c1477686351e';
export const reviewPolicyDigest = 'cb72f160d9ff1ea1743513cee3058ca2f72e287599158e2763f296ab73b6e511';
const policyPath = 'agents/skills/actuating/references/review-contract.json';

function git(directory, args) {
  return execFileSync('git', ['--no-replace-objects', ...args], {
    cwd: directory, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 30000,
  }).trimEnd();
}

function outside(parent, child) {
  const distance = relative(parent, child);
  return distance === '..' || distance.startsWith(`..${sep}`);
}

function newDirectory(path) {
  const requested = resolve(path);
  const canonical = join(realpathSync(dirname(requested)), basename(requested));
  mkdirSync(canonical, {mode: 0o700});
  return canonical;
}

export function readRegular(path, maximumBytes) {
  const descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = fstatSync(descriptor, {bigint: true});
    assert.ok(before.isFile() && before.size <= BigInt(maximumBytes), 'unsupported evidence file');
    const buffer = Buffer.alloc(Number(before.size) + 1);
    let length = 0;
    while (length < buffer.length) {
      const count = readSync(descriptor, buffer, length, buffer.length - length, null);
      if (count === 0) break;
      length += count;
    }
    const bytes = buffer.subarray(0, length);
    const after = fstatSync(descriptor, {bigint: true});
    for (const field of ['dev', 'ino', 'size', 'mode', 'mtimeNs', 'ctimeNs']) assert.equal(after[field], before[field], 'evidence changed');
    assert.equal(BigInt(bytes.length), before.size);
    return bytes;
  } finally { closeSync(descriptor); }
}

export function reviewerEnvironment(reviewHome, path, environment = process.env) {
  assert.ok(isAbsolute(reviewHome) && typeof path === 'string' && path.length > 0);
  const result = {
    HOME: reviewHome, CODEX_HOME: join(reviewHome, '.codex'), PATH: path,
    GH_CONFIG_DIR: join(reviewHome, '.github-read-only'),
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8', TERM: 'dumb',
  };
  for (const key of ['OPENAI_API_KEY', 'SSL_CERT_FILE', 'SSL_CERT_DIR']) {
    if (environment[key]) result[key] = environment[key];
  }
  return result;
}

export function ownerArguments({workspace, captureRoot, model, reasoningEffort, serviceTier, resumeThread}) {
  assert.ok(isAbsolute(workspace) && isAbsolute(captureRoot));
  assert.ok(typeof model === 'string' && /^[A-Za-z0-9._-]+$/.test(model));
  assert.ok(['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].includes(reasoningEffort));
  assert.ok(['default', 'priority', 'flex'].includes(serviceTier));
  const args = ['exec', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
    '--sandbox', 'workspace-write', '--cd', workspace, '--model', model,
    '-c', 'approval_policy="never"', '-c', `model_reasoning_effort=${JSON.stringify(reasoningEffort)}`,
    '-c', `service_tier=${JSON.stringify(serviceTier)}`,
    '-c', `review_model=${JSON.stringify(model)}`,
    '-c', 'sandbox_workspace_write.exclude_tmpdir_env_var=true',
    '-c', 'sandbox_workspace_write.exclude_slash_tmp=true',
    '-c', 'sandbox_workspace_write.writable_roots=[]',
    '-c', 'sandbox_workspace_write.network_access=true',
    '-c', `shell_environment_policy.set.CODEX_HOME=${JSON.stringify(join(workspace, 'reviewer-home'))}`,
    '-c', `shell_environment_policy.set.TMPDIR=${JSON.stringify(join(workspace, 'tmp'))}`,
    '-c', `shell_environment_policy.set.XDG_CACHE_HOME=${JSON.stringify(join(workspace, 'cache'))}`,
    '--json', '--color', 'never', '--output-last-message', join(captureRoot, 'owner-final.json')];
  if (resumeThread !== undefined) {
    assert.match(resumeThread, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    args.push('resume', resumeThread);
  }
  return [...args, '-'];
}

export function ownerPrompt({repository, policyDirectory, contextPath, workspace, settingsPath, casPath, codexPath, settings, reviewTimeoutSeconds = 420}) {
  return [
    `Apply the Actuating skill at ${join(policyDirectory, 'agents/skills/actuating/SKILL.md')}.`,
    'Execute its ordinary review-closeout procedure with serial-reviews and CAS; this is the review owner invocation, not a request to replace it with a review loop.',
    `Read the accepted requirements, exact candidate and complete pre-review proof inventory in ${contextPath}.`,
    `Candidate repository: ${repository}. Accepted policy checkout: ${policyDirectory}.`,
    'The candidate and Git metadata are read-only. No implementation, commit, publication, PR comment, merge, credential creation, or repository administration is authorized.',
    'Use Node.js and shell for local evidence handling; do not invoke Python. Do not read or copy authentication into evidence. The reviewer-home directory is runtime-private active state and is never release evidence.',
    'If an entailed current finding is discovered, it blocks this mechanical path. Complete all owner-required evidence collection, recovery and fold before closing an invalidated initial epoch. Never repair the candidate.',
    `Use ${casPath} review start --wait --json with --codex-path ${codexPath} --thread-start-params-json @${settingsPath} --store-root ${join(workspace, 'cas')} for each owner-authorized request. Preserve the ordinary owner policy, original receipt and event evidence. Execute each CAS invocation as one direct command using the absolute binary, no shell operators, redirection, substitutions, environment wrappers or output filtering; retain complete stdout in the command execution event. The trusted adapter derives original receipt bytes from that event; receipt filenames are unique labels, never authority for replacement bytes.`,
    'In this invocation perform at most ONE next review selected by the ordinary owner procedure, or recover one existing attempt. Export status=pending when the epoch still needs further work. Never call a bounded pause complete or close the epoch merely to fit this turn. A later invocation resumes this exact owner session and its original CAS state. Use a CAS timeout below '+reviewTimeoutSeconds+' seconds and leave time to export the current owner facts; a timeout has no review credit and must retain recovery identity.',
    `Bind these exact model settings for owner and every reviewer: ${JSON.stringify(settings)}. Set reviewer sandbox=read-only and approvalPolicy=never; no silent executor or model fallback.`,
    'Native changeset standard must have no custom instructions. Auxiliary and focused-file instructions must use exact pinned owner sources.',
    'Preserve all original CAS stdout receipts, session records, event logs, instruction bytes, request bindings and per-request owner credit dispositions in this writable workspace. Do not copy secrets.',
    'Use the pinned Review Fold owner for adjudication and record any unavailable history honestly. An absent original receipt or unknown limitation cannot earn credit.',
    'Do not infer reviewability from this prompt: verify the supplied proof inventory and accepted source, and block if required proof is absent or not exact-subject.',
    'At the end of this bounded invocation export your actual owner facts as a JSON object with schema="repository-review-owner/v1", status="complete", "pending" or "blocked", contextSha256 (exact input context bytes), policySha256, base, head, executionMode="cas", epochClosed, epochInvalidated, invalidationBasis, closureBasis, reviewContext, and requests. epochInvalidated records whether this epoch has admitted a current material entailed finding or another owner-policy invalidation; it remains true thereafter and all credit remains held. invalidationBasis is null before invalidation, otherwise the original owner basis. Raw findings and unresolved limitations alone are not admitted invalidation. A reasoned rejection or limitation recovery may change hold to credit while the epoch remains valid. Return raw JSON without Markdown fences.',
    'reviewContext is your ordinary fully bound ephemeral review_context, including the frozen focused_files and proof inventory. requests preserves each existing per-request handoff in policy order: request_id, request_fingerprint, target_fingerprint, lens_name, role, scope, focus, phase (initial or confirmation), instruction_digest (lowercase SHA-256 hex), receipt (unique relative label for the latest captured stdout), credit_disposition, credit_basis, limitations (array of disposition/basis), fold_complete, and unresolved_findings. Assign a new receipt label for every start or wait observation; all earlier captured observations remain retained. If receipt is a recovered wait output, also retain start_receipt. If ordinary policy permits one fresh exact-request recovery after a verdictless terminal, retain that terminal failure observation in prior_receipts and preserve the same opaque request binding; never classify an observation timeout as terminal. Before a next initial request the previous turn must export the preceding terminal outcome and completed owner fold. Before a confirmation the previous turn must export the complete credited initial inventory and preceding confirmations. A turn may perform only adjudication when a hold needs reassessment. Do not invent requests, successful observations, counters, or receipts.',
    'Complete means the entire ordinary owner closeout is complete, with all required changeset and focused-file obligations and standard convergence. Pending means normal owner work remains on this frozen epoch. Blocked means a precise missing observation, required repair, or capability prevents progress. Process success alone is not credit.',
    'Write no new policy, scheduler state, or Actuating ledger. The requested final JSON is only a repository-local export of your existing owner facts and original evidence.',
  ].join('\n\n');
}

export function verifyOwnerTranscript(eventsBytes, finalBytes, expected) {
  assert.ok(eventsBytes.length <= 64 * 1024 * 1024 && finalBytes.length <= 4 * 1024 * 1024);
  const lines = eventsBytes.toString('utf8').trimEnd().split('\n');
  const events = lines.map(line => parseEvidenceJson(line));
  assert.equal(events.filter(event => event.type === 'thread.started').length, 1, 'missing unique owner thread');
  assert.equal(events.filter(event => event.type === 'turn.completed').length, 1, 'owner did not complete');
  assert.ok(!events.some(event => event.type === 'turn.failed' || event.type === 'error'), 'owner failed');
  const messages = events.filter(event => event.type === 'item.completed' && event.item?.type === 'agent_message');
  assert.ok(messages.length > 0, 'missing runtime-attributed owner output');
  assert.equal(messages.at(-1).item.text, finalBytes.toString('utf8'), 'owner final output differs from runtime event');
  const output = parseEvidenceJson(finalBytes);
  assert.equal(output.schema, 'repository-review-owner/v1');
  assert.ok(['complete', 'pending', 'blocked'].includes(output.status));
  assert.equal(output.contextSha256, expected.contextSha256);
  assert.equal(output.policySha256, reviewPolicyDigest);
  assert.equal(output.base, expected.base);
  assert.equal(output.head, expected.head);
  assert.equal(output.executionMode, 'cas');
  assert.ok(typeof output.closureBasis === 'string' && output.closureBasis.length > 0);
  assert.ok(Array.isArray(output.requests));
  assert.equal(typeof output.epochInvalidated, 'boolean', 'missing owner invalidation disposition');
  if (output.epochInvalidated) {
    assert.ok(typeof output.invalidationBasis === 'string' && output.invalidationBasis.length > 0, 'missing owner invalidation basis');
    assert.notEqual(output.status, 'complete', 'invalidated epoch cannot complete');
    for (const request of output.requests) assert.equal(request.credit_disposition, 'hold', 'invalidated epoch cannot earn credit');
  } else assert.equal(output.invalidationBasis, null);
  if (output.status === 'pending') assert.equal(output.epochClosed, false, 'pending owner closed epoch');
  if (output.status === 'complete') {
    assert.equal(output.epochClosed, true);
    assert.ok(output.requests.length > 0, 'missing original review handoffs');
    assert.equal(output.reviewContext?.base_sha, expected.base);
    assert.equal(output.reviewContext?.head_sha, expected.head);
    assert.equal(output.reviewContext?.execution_mode, 'cas');
  }
  return {thread: events.find(event => event.type === 'thread.started').thread_id, output};
}

export function verifyOwnerChain(captures, expected) {
  assert.ok(Array.isArray(captures) && captures.length > 0 && captures.length <= 64);
  let previous;
  for (const capture of captures) {
    const current = verifyOwnerTranscript(capture.events, capture.final, expected);
    if (previous) {
      assert.equal(previous.output.status, 'pending', 'cannot continue a terminal owner disposition');
      assert.equal(current.thread, previous.thread, 'owner session changed');
      if (previous.output.epochInvalidated) {
        assert.equal(current.output.epochInvalidated, true, 'accepted epoch invalidation was erased');
        assert.equal(current.output.invalidationBasis, previous.output.invalidationBasis, 'original invalidation basis changed');
      }
      for (const request of previous.output.requests) {
        const retained = current.output.requests.find(item => item.request_id === request.request_id);
        assert.ok(retained, 'lost original review request');
        for (const key of ['request_fingerprint', 'target_fingerprint', 'instruction_digest', 'scope', 'focus', 'phase', 'role', 'lens_name']) {
          assert.deepEqual(retained[key], request[key], 'rewritten original review request');
        }
      }
    }
    previous = current;
  }
  return previous;
}

function originalBytes(value) {
  assert.ok(typeof value === 'string' && value.length <= 64 * 1024 * 1024);
  const bytes = Buffer.from(value, 'base64');
  assert.equal(bytes.toString('base64'), value, 'noncanonical retained evidence');
  return bytes;
}

export function validateRetainedReview(bytes, expected) {
  const retained = parseEvidenceJson(bytes);
  assert.equal(retained.schema, 'repository-review-evidence/v1');
  const contextBytes = originalBytes(retained.context);
  const context = parseEvidenceJson(contextBytes);
  const binding = parseEvidenceJson(originalBytes(retained.binding));
  for (const key of ['base', 'head']) {
    assert.equal(binding[key], expected[key]);
    assert.equal(context[key], expected[key]);
  }
  assert.equal(binding.contextSha256, sha256(contextBytes));
  const contractBytes = originalBytes(retained.contract);
  assert.equal(sha256(contractBytes), reviewPolicyDigest);
  const contract = parseEvidenceJson(contractBytes);
  const captures = retained.captures.map(capture => ({events: originalBytes(capture.events), final: originalBytes(capture.final)}));
  const owner = verifyOwnerChain(captures, {...expected, contextSha256: sha256(contextBytes)});
  const retainedReceipts = new Map(Object.entries(retained.receipts).map(([name, value]) => [name, originalBytes(value)]));
  const policyFiles = new Map(Object.entries(retained.policyFiles).map(([name, value]) => [name, originalBytes(value)]));
  const runtime = retained.runtime;
  assert.equal(runtime.repository, context.repository);
  assert.equal(runtime.repositoryPath, binding.repository);
  assert.equal(runtime.codexBinaryDigest, `sha256:${binding.codexSha256}`);
  const {receipts} = admitOwnerHistory(captures, captures.map(capture => parseEvidenceJson(capture.final)), contract, policyFiles, runtime, {
    casPath: binding.casPath, codexPath: binding.codexPath, repositoryPath: binding.repository,
    base: expected.base, storeRoot: join(binding.workspace, 'cas'), settingsPaths: retained.settingsPaths,
  });
  assert.equal(retainedReceipts.size, receipts.size, 'retained original receipt inventory differs');
  for (const [name, bytes] of receipts) assert.ok(retainedReceipts.get(name)?.equals(bytes), 'retained original receipts differ from captured history');
  validateOwnerEvidence(owner.output, contract, policyFiles, receipts, runtime);
  return {owner, context, binding, runtime};
}

function retainReview({captures, receipts, contextBytes, binding, contractBytes, policyFiles, runtime, settingsPaths}) {
  const outputs = new Set([...receipts.values()].map(bytes => bytes.toString().trimEnd()));
  const compact = captures.map(capture => {
    const source = capture.events.toString('utf8').trimEnd().split('\n');
    const commands = new Set(source.map(line => parseEvidenceJson(line)).filter(event =>
      event.type === 'item.completed' && event.item?.type === 'command_execution' &&
      outputs.has(event.item.aggregated_output.trimEnd())).map(event => event.item.id));
    const lines = source.filter(line => {
      const event = parseEvidenceJson(line);
      if (['thread.started', 'turn.completed', 'turn.failed', 'error'].includes(event.type)) return true;
      if (event.item?.type === 'command_execution') return commands.has(event.item.id);
      return event.type === 'item.completed' && event.item?.type === 'agent_message';
    });
    return {events: Buffer.from(`${lines.join('\n')}\n`).toString('base64'), final: capture.final.toString('base64')};
  });
  const retained = {
    schema: 'repository-review-evidence/v1', context: contextBytes.toString('base64'), binding: binding.toString('base64'),
    contract: contractBytes.toString('base64'), captures: compact,
    receipts: Object.fromEntries([...receipts].map(([name, bytes]) => [name, bytes.toString('base64')])),
    policyFiles: Object.fromEntries([...policyFiles].map(([name, bytes]) => [name, bytes.toString('base64')])),
    runtime, settingsPaths,
  };
  const bytes = Buffer.from(`${JSON.stringify(retained)}\n`);
  assert.ok(bytes.length <= 64 * 1024 * 1024, 'retained review evidence exceeds capacity');
  validateRetainedReview(bytes, parseEvidenceJson(binding));
  return bytes;
}

export async function invokeOwner(options) {
  const repository = realpathSync(options.repository);
  const policyDirectory = realpathSync(options.policyDirectory);
  const requested = resolve(options.workspace);
  const workspace = join(realpathSync(dirname(requested)), basename(requested));
  const distance = relative(repository, workspace);
  assert.ok(distance === '..' || distance.startsWith(`..${sep}`), 'owner workspace must be outside candidate');
  const captureRoot = join(realpathSync(dirname(resolve(options.captureRoot))), basename(options.captureRoot));
  assert.ok(outside(workspace, captureRoot) && outside(repository, captureRoot), 'capture must be outside writable candidate and owner trees');
  assert.match(options.base, /^[0-9a-f]{40}$/);
  assert.match(options.head, /^[0-9a-f]{40}$/);
  assert.equal(git(repository, ['rev-parse', 'HEAD']), options.head);
  assert.equal(git(repository, ['status', '--porcelain=v1', '--untracked-files=all']), '', 'candidate must be clean');
  assert.equal(git(policyDirectory, ['rev-parse', 'HEAD']), reviewPolicyCommit);
  assert.equal(git(policyDirectory, ['status', '--porcelain=v1', '--', 'agents/skills']), '', 'policy must be clean');
  assert.equal(sha256(readRegular(join(policyDirectory, policyPath), 1024 * 1024)), reviewPolicyDigest);
  const contextBytes = readRegular(options.contextPath, 4 * 1024 * 1024);
  const context = parseEvidenceJson(contextBytes);
  assert.equal(context.base, options.base);
  assert.equal(context.head, options.head);
  const codexPath = realpathSync(options.codexPath), casPath = realpathSync(options.casPath);
  for (const path of [codexPath, casPath, policyDirectory, repository, realpathSync(options.reviewHome)]) {
    assert.ok(outside(workspace, path), 'trusted input inside owner workspace');
  }
  assert.equal(sha256(readRegular(codexPath, 512 * 1024 * 1024)), options.codexSha256);
  assert.equal(sha256(readRegular(casPath, 512 * 1024 * 1024)), options.casSha256);
  const expected = {base: options.base, head: options.head, contextSha256: sha256(contextBytes)};
  const binding = encodeRecord({...expected, workspace, repository, policyDirectory, codexPath, casPath,
    codexSha256: options.codexSha256, casSha256: options.casSha256,
    model: options.model, reasoningEffort: options.reasoningEffort, serviceTier: options.serviceTier});
  const captures = (options.previousCaptures ?? []).map(path => {
    const root = realpathSync(path);
    assert.ok(outside(workspace, root), 'previous capture inside owner workspace');
    assert.deepEqual(readRegular(join(root, 'binding.json'), 1024 * 1024), binding, 'resumption inputs changed');
    return {events: readRegular(join(root, 'owner-events.jsonl'), 64 * 1024 * 1024),
      final: readRegular(join(root, 'owner-final.json'), 4 * 1024 * 1024)};
  });
  const prior = captures.length === 0 ? null : verifyOwnerChain(captures, expected);
  if (prior) {
    assert.equal(prior.output.status, 'pending', 'cannot automatically retry terminal owner');
    assert.equal(realpathSync(workspace), workspace);
  } else {
    newDirectory(workspace);
    mkdirSync(join(workspace, 'tmp'), {mode: 0o700});
    mkdirSync(join(workspace, 'cache'), {mode: 0o700});
    mkdirSync(join(workspace, 'reviewer-home'), {mode: 0o700});
  }
  const auth = readRegular(join(realpathSync(options.reviewHome), '.codex', 'auth.json'), 1024 * 1024);
  const reviewerHome = join(workspace, 'reviewer-home');
  assert.equal(realpathSync(reviewerHome), reviewerHome, 'reviewer state replaced by symlink');
  writeFileSync(join(reviewerHome, 'auth.json'), auth, {mode: 0o600,
    flag: constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW});
  newDirectory(captureRoot);
  writeFileSync(join(captureRoot, 'binding.json'), binding, {flag: 'wx', mode: 0o400});
  const contextPath = join(captureRoot, 'context.json');
  writeFileSync(contextPath, contextBytes, {flag: 'wx', mode: 0o400});
  const settings = {model: options.model, reasoningEffort: options.reasoningEffort, serviceTier: options.serviceTier};
  const threadStart = {approvalPolicy: 'never', model: settings.model, modelProvider: 'openai', sandbox: 'read-only', config: {
    model_reasoning_effort: settings.reasoningEffort, review_model: settings.model, service_tier: settings.serviceTier,
  }};
  const threadBytes = encodeRecord(threadStart).subarray(0, -1);
  for (const root of options.previousCaptures ?? []) {
    assert.deepEqual(readRegular(join(root, 'thread-start.json'), 1024 * 1024), threadBytes, 'review settings changed');
  }
  const settingsPath = join(captureRoot, 'thread-start.json');
  writeFileSync(settingsPath, threadBytes, {flag: 'wx', mode: 0o400});
  const remainingMs = remainingOwnerTime(options.timeoutMs, options.deadline);
  assert.ok(remainingMs > 0, 'owner admission deadline exhausted before model execution');
  const reviewTimeoutSeconds = Math.max(1, Math.min(420, Math.floor(remainingMs / 1000) - 30));
  const prompt = ownerPrompt({repository, policyDirectory, contextPath, workspace, settingsPath, casPath, codexPath, settings, reviewTimeoutSeconds});
  writeFileSync(join(captureRoot, 'invocation.txt'), prompt, {flag: 'wx', mode: 0o400});
  const args = ownerArguments({...options, workspace, captureRoot, resumeThread: prior?.thread});
  const result = await runOwnerProcess(codexPath, args, {
    workspace, captureRoot, env: reviewerEnvironment(realpathSync(options.reviewHome), options.path), input: prompt,
    timeoutMs: options.timeoutMs, deadline: options.deadline,
  });
  writeFileSync(join(captureRoot, 'process.json'), JSON.stringify(result), {flag: 'wx', mode: 0o400});
  assert.equal(result.failure, null, 'owner execution incomplete; inspect original evidence before recovery');
  assert.equal(result.signal, null, 'owner interrupted; inspect original evidence before recovery');
  assert.equal(result.code, 0, 'owner failed; inspect original evidence before recovery');
  assert.equal(git(repository, ['rev-parse', 'HEAD']), options.head, 'candidate head changed');
  assert.equal(git(repository, ['status', '--porcelain=v1', '--untracked-files=all']), '', 'candidate changed');
  assert.equal(sha256(readRegular(codexPath, 512 * 1024 * 1024)), options.codexSha256, 'Codex binary changed');
  assert.equal(sha256(readRegular(casPath, 512 * 1024 * 1024)), options.casSha256, 'CAS binary changed');
  captures.push({events: readRegular(join(captureRoot, 'owner-events.jsonl'), 64 * 1024 * 1024),
    final: readRegular(join(captureRoot, 'owner-final.json'), 4 * 1024 * 1024)});
  const resultOwner = verifyOwnerChain(captures, expected);
  const contractBytes = readRegular(join(policyDirectory, policyPath), 1024 * 1024);
  const contract = parseEvidenceJson(contractBytes), policyFiles = new Map();
  for (const path of [contract.focused_file_reviews.instructions_ref,
    ...contract.required_lenses.filter(lens => lens.instructions_ref).map(lens => lens.instructions_ref)]) {
    policyFiles.set(path, readRegular(join(policyDirectory, path), 1024 * 1024));
  }
  const settingsPaths = [...(options.previousCaptures ?? []), captureRoot].map(root => join(realpathSync(root), 'thread-start.json'));
  const runtime = {
    repository: context.repository, repositoryPath: repository, codexVersion: '0.166.0',
    codexBinaryDigest: `sha256:${options.codexSha256}`, threadStartParamsDigest: `sha256:${sha256(threadBytes)}`,
  };
  const {receipts} = admitOwnerHistory(captures, captures.map(capture => parseEvidenceJson(capture.final)), contract, policyFiles, runtime, {
    casPath, codexPath, repositoryPath: repository, base: options.base, storeRoot: join(workspace, 'cas'), settingsPaths,
  });
  if (resultOwner.output.status === 'complete') {
    validateOwnerEvidence(resultOwner.output, contract, policyFiles, receipts, runtime);
    writeFileSync(join(captureRoot, 'review-evidence.json'), retainReview({captures, receipts, contextBytes, binding,
      contractBytes, policyFiles, runtime, settingsPaths}), {flag: 'wx', mode: 0o400});
  }
  return resultOwner;
}
