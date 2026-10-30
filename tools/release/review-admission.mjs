import assert from 'node:assert/strict';
import {parseEvidenceJson} from './evidence-json.mjs';
import {sha256} from './encoding.mjs';

function same(a, b, message) {
  assert.deepEqual(JSON.parse(JSON.stringify(a)), JSON.parse(JSON.stringify(b)), message);
}

function instructionBytes(request, receipt, context, contract, policyFiles) {
  if (request.scope === 'changeset' && request.lens_name === 'standard') {
    assert.equal(receipt.developerInstructions ?? null, null, 'customized native standard');
    return Buffer.from('codex-default-review/v1');
  }
  assert.equal(typeof receipt.developerInstructions, 'string', 'missing original instructions');
  const actual = receipt.developerInstructions;
  const lens = contract.required_lenses.find(lens => lens.name === request.lens_name);
  const source = path => {
    const bytes = policyFiles.get(path);
    assert.ok(Buffer.isBuffer(bytes), 'missing pinned instruction source');
    return new TextDecoder('utf-8', {fatal: true}).decode(bytes);
  };
  if (request.scope === 'changeset') assert.equal(actual, source(lens.instructions_ref), 'changed auxiliary instructions');
  else {
    const segments = [source(contract.focused_file_reviews.instructions_ref)];
    if (lens.role !== 'standard') segments.push(source(lens.instructions_ref));
    const prefix = `${segments.join('\n\n')}\n\n`;
    assert.ok(actual.startsWith(prefix), 'changed focused-file instructions');
    same(parseEvidenceJson(actual.slice(prefix.length)), {
      repository: context.repository, base_sha: context.base_sha, head_sha: context.head_sha,
      lens_name: request.lens_name, scope: 'file', focus: request.focus,
    }, 'changed focused-file assignment');
  }
  return Buffer.from(actual);
}

function validateReceipt(request, receipt, context, contract, policyFiles, receipts, runtime) {
  assert.ok(['start', 'wait'].includes(receipt.action));
  const original = receipt.action === 'start' ? receipt : parseEvidenceJson(receipts.get(request.start_receipt));
  assert.equal(original.action, 'start');
  assert.equal(original.waited, true, 'review was not owner-lived');
  assert.equal(original.reviewThreadId, receipt.reviewThreadId, 'recovered different attempt');
  assert.equal(original.targetFingerprint, receipt.targetFingerprint, 'recovered different subject');
  same(original.workflowBinding, receipt.workflowBinding, 'recovered different request');
  const recovered = request.prior_receipts ?? [];
  assert.ok(Array.isArray(recovered) && recovered.length <= contract.transport_recovery.maximum_fresh_recovery_attempts,
    'transport recovery allowance exceeded');
  for (const name of recovered) {
    const failed = parseEvidenceJson(receipts.get(name));
    assert.equal(failed.action, 'start');
    assert.equal(failed.waited, true);
    assert.equal(failed.tupleVerdictExists, false, 'semantic outcome cannot be erased by transport recovery');
    assert.equal(failed.reviewAttemptPhase, 'review_terminal', 'observation timeout is not terminal');
    assert.equal(failed.failureClass, 'transport_review_attempt');
    assert.equal(failed.baseSha, context.base_sha); assert.equal(failed.headSha, context.head_sha);
    assert.equal(failed.targetFingerprint, request.target_fingerprint);
    same(failed.workflowBinding, receipt.workflowBinding, 'recovery changed request');
    assert.notEqual(failed.reviewThreadId, receipt.reviewThreadId, 'recovery reused failed context');
  }
  assert.equal(receipt.cwd, runtime.repositoryPath);
  assert.equal(receipt.timedOut, false);
  assert.equal(receipt.reviewAttemptExists, true);
  assert.equal(receipt.tupleVerdictExists, true);
  assert.equal(receipt.compatibilityVerdict, 'compatible');
  assert.equal(receipt.structuredReviewCapability, true);
  assert.equal(receipt.appServerContractId, 'codex-app-server-capabilities-v2');
  assert.equal(receipt.selectedTransport, 'websocket');
  assert.equal(receipt.resolvedCodexVersion, runtime.codexVersion);
  assert.equal(receipt.codexBinaryDigest, runtime.codexBinaryDigest);
  assert.equal(receipt.threadStartParamsDigest, runtime.threadStartParamsDigest);
  assert.equal(receipt.failureCode ?? null, null);
  const verdict = receipt.reviewVerdict;
  assert.ok(verdict && ['clean', 'findings'].includes(verdict.status), 'missing structured verdict');
  assert.equal(verdict.backendClass, 'cas-start-wait');
  assert.equal(verdict.principalStrength, 'strong');
  assert.equal(verdict.accountFingerprintReducedProtection, false);
  assert.ok(typeof verdict.accountFingerprint === 'string' && verdict.accountFingerprint.length > 0);
  assert.equal(verdict.failureCode ?? null, null);
  assert.ok(Array.isArray(verdict.findings));
  assert.equal(verdict.findingCount, verdict.findings.length);
  for (const value of [receipt, verdict]) {
    assert.equal(value.baseSha, context.base_sha);
    assert.equal(value.headSha, context.head_sha);
    assert.equal(value.targetFingerprint, request.target_fingerprint);
    same(value.workflowBinding, {requestId: request.request_id, requestFingerprint: request.request_fingerprint});
  }
  assert.ok(typeof verdict.reviewThreadId === 'string' && verdict.reviewThreadId.length > 0);
  assert.ok(typeof verdict.reviewTurnId === 'string' && verdict.reviewTurnId.length > 0);
  assert.equal(receipt.reviewThreadId, verdict.reviewThreadId);
  assert.equal(receipt.reviewTurnId, verdict.reviewTurnId);
  assert.equal(request.instruction_digest, sha256(instructionBytes(request, receipt, context, contract, policyFiles)));
  assert.equal(request.credit_disposition, 'credit', 'owner withheld review credit');
  assert.ok(typeof request.credit_basis === 'string' && request.credit_basis.length > 0, 'missing owner basis');
  assert.ok(Array.isArray(request.limitations), 'missing owner limitation dispositions');
  for (const limitation of request.limitations) {
    assert.ok(contract.review_credit.limitation_dispositions.includes(limitation.disposition));
    assert.notEqual(limitation.disposition, 'unresolved', 'unresolved review limitation');
    assert.ok(typeof limitation.basis === 'string' && limitation.basis.length > 0);
  }
  assert.equal(request.fold_complete, true, 'missing owner finding fold');
  same(request.unresolved_findings, [], 'unresolved findings');
  return verdict.reviewThreadId;
}

export function validateOwnerEvidence(output, contract, policyFiles, receipts, runtime) {
  assert.equal(output.status, 'complete', 'owner closeout is blocked');
  assert.equal(output.epochClosed, true, 'review epoch remains open');
  assert.equal(output.executionMode, 'cas');
  const context = output.reviewContext;
  assert.equal(context.repository, runtime.repository);
  assert.equal(context.execution_mode, 'cas');
  assert.equal(context.base_sha, output.base);
  assert.equal(context.head_sha, output.head);
  const focused = context.focused_files;
  assert.ok(Array.isArray(focused) && focused.length <= contract.focused_file_reviews.maximum_files);
  assert.equal(new Set(focused.map(value => JSON.stringify(value))).size, focused.length, 'duplicate focused file');
  const scopes = [{scope: 'changeset', focus: null}, ...focused.map(focus => ({scope: 'file', focus}))];
  const expected = scopes.flatMap(scope => contract.required_lenses.map(lens => ({
    ...scope, lens_name: lens.name, role: lens.role, phase: 'initial',
  })));
  for (let index = 1; index < contract.standard_convergence.required_consecutive_clean_attempts; index++) {
    expected.push({scope: 'changeset', focus: null, lens_name: 'standard', role: 'standard', phase: 'confirmation'});
  }
  assert.equal(output.requests.length, expected.length, 'incomplete owner review inventory');
  const ids = new Set(), threads = new Set(), receiptNames = new Set();
  for (let index = 0; index < expected.length; index++) {
    const request = output.requests[index];
    for (const key of ['scope', 'focus', 'lens_name', 'role', 'phase']) same(request[key], expected[index][key], 'owner obligation mismatch');
    assert.ok(typeof request.request_id === 'string' && request.request_id.length > 0);
    assert.ok(typeof request.request_fingerprint === 'string' && request.request_fingerprint.length > 0);
    assert.ok(typeof request.target_fingerprint === 'string' && request.target_fingerprint.length > 0);
    assert.ok(!ids.has(request.request_id), 'replayed request');
    assert.ok(!receiptNames.has(request.receipt), 'replayed original receipt');
    ids.add(request.request_id);
    receiptNames.add(request.receipt);
    const bytes = receipts.get(request.receipt);
    assert.ok(Buffer.isBuffer(bytes) && bytes.length <= 8 * 1024 * 1024, 'missing original receipt');
    const thread = validateReceipt(request, parseEvidenceJson(bytes), context, contract, policyFiles, receipts, runtime);
    assert.ok(!threads.has(thread), 'reused review context');
    threads.add(thread);
  }
  return {base: output.base, head: output.head, executionMode: 'cas', epochClosed: true};
}
