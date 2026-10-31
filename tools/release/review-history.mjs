import assert from 'node:assert/strict';
import {capturedReceipts, authenticateReceipts} from './review-runtime.mjs';
import {instructionBytes, reviewObligations, validateReceipt} from './review-admission.mjs';
import {sha256} from './encoding.mjs';

function terminalFailure(receipt) {
  assert.equal(receipt.tupleVerdictExists, false, 'semantic outcome cannot be replaced');
  assert.equal(receipt.reviewAttemptPhase, 'review_terminal', 'observation timeout is not terminal');
  assert.equal(receipt.failureClass, 'transport_review_attempt', 'not a recoverable terminal');
}

function credited(request) {
  assert.equal(request.fold_complete, true, 'prior owner fold is incomplete');
  assert.equal(request.credit_disposition, 'credit', 'prior owner withheld credit');
  assert.deepEqual(request.unresolved_findings, [], 'prior owner has unresolved findings');
  assert.ok(request.limitations.every(value => value.disposition !== 'unresolved'), 'prior owner has unresolved limitations');
}

export function admitOwnerHistory(captures, outputs, contract, policyFiles, runtime, expected) {
  const {receipts, observations} = capturedReceipts(captures, outputs, expected);
  const provenance = receipts.size === 0 ? new Map() : authenticateReceipts(captures.map(value => value.events), receipts, expected, observations);
  const attempts = new Map();
  let previous = null, frozenContext = null;
  for (let source = 0; source < outputs.length; source++) {
    const output = outputs[source];
    if (output.reviewContext !== undefined && output.reviewContext !== null) {
      if (frozenContext !== null) assert.deepEqual(output.reviewContext, frozenContext, 'frozen review context changed');
      frozenContext = output.reviewContext;
      assert.equal(frozenContext.repository, runtime.repository);
      assert.equal(frozenContext.base_sha, output.base);
      assert.equal(frozenContext.head_sha, output.head);
      assert.equal(frozenContext.execution_mode, 'cas');
    }
    assert.ok(output.requests.length === 0 || frozenContext !== null, 'missing frozen review context');
    const obligations = frozenContext === null ? [] : reviewObligations(frozenContext, contract);
    assert.ok(output.requests.length <= obligations.length, 'excess owner review inventory');
    for (let index = 0; index < output.requests.length; index++) {
      const request = output.requests[index];
      for (const key of ['scope', 'focus', 'lens_name', 'role', 'phase']) {
        assert.deepEqual(request[key], obligations[index][key], 'owner obligation mismatch');
      }
    }
    const observation = observations.find(value => value.source === source);
    if (observation) {
      const {request, receipt, name} = observation;
      const binding = {requestId: request.request_id, requestFingerprint: request.request_fingerprint};
      assert.deepEqual(receipt.workflowBinding, binding, 'captured request binding differs');
      assert.equal(receipt.baseSha, output.base);
      assert.equal(receipt.headSha, output.head);
      assert.equal(receipt.targetFingerprint, request.target_fingerprint);
      let attempt = attempts.get(request.request_id);
      if (receipt.action === 'start') {
        assert.equal(receipt.waited, true, 'review was not owner-lived');
        assert.equal(request.instruction_digest, sha256(instructionBytes(request, receipt, frozenContext, contract, policyFiles)));
        if (attempt) {
          terminalFailure(attempt.latest.receipt);
          assert.ok(attempt.failed.length < contract.transport_recovery.maximum_fresh_recovery_attempts, 'transport recovery allowance exceeded');
          assert.notEqual(receipt.reviewThreadId, attempt.start.receipt.reviewThreadId, 'fresh recovery reused original attempt');
          assert.ok(provenance.get(name).freshAttempt, 'missing explicit fresh recovery');
          attempt.failed.push(attempt.latest.name);
          attempt.start = observation;
        } else {
          const index = output.requests.indexOf(request);
          assert.equal(index, previous?.requests.length ?? 0, 'review dispatch did not extend original inventory');
          for (const prior of previous?.requests ?? []) {
            assert.equal(prior.fold_complete, true, 'review dispatched before prior owner fold');
            assert.equal(attempts.get(prior.request_id)?.latest.receipt.tupleVerdictExists, true, 'review dispatched before required recovery');
          }
          if (request.phase === 'confirmation') {
            assert.ok(previous && !previous.epochInvalidated, 'confirmation on invalidated epoch');
            for (const prior of previous.requests) credited(prior);
          }
          attempt = {start: observation, latest: observation, failed: []};
          attempts.set(request.request_id, attempt);
        }
      } else {
        assert.equal(receipt.action, 'wait');
        assert.ok(attempt, 'wait lacks original request');
        assert.equal(receipt.reviewThreadId, attempt.start.receipt.reviewThreadId, 'wait recovered another attempt');
        if (attempt.latest.receipt.tupleVerdictExists === true) {
          assert.deepEqual(receipt.reviewVerdict, attempt.latest.receipt.reviewVerdict, 'original semantic outcome changed');
        }
      }
      attempt.latest = observation;
    }
    assert.equal(output.requests.length, attempts.size, 'missing original request handoff');
    const ids = new Set();
    for (const request of output.requests) {
      assert.ok(!ids.has(request.request_id), 'duplicate owner request'); ids.add(request.request_id);
      const attempt = attempts.get(request.request_id);
      assert.ok(attempt, 'request lacks original execution');
      assert.equal(request.receipt, attempt.latest.name, 'owner replaced current original outcome');
      assert.deepEqual(request.prior_receipts ?? [], attempt.failed, 'owner omitted original failed outcome');
      if (attempt.latest.receipt.action === 'wait') assert.equal(request.start_receipt, attempt.start.name, 'missing original start');
      else assert.equal(request.start_receipt ?? request.receipt, request.receipt, 'wrong current start');
      assert.equal(typeof request.fold_complete, 'boolean');
      assert.ok(['hold', 'credit'].includes(request.credit_disposition));
      assert.ok(Array.isArray(request.unresolved_findings));
      assert.ok(Array.isArray(request.limitations));
      if (request.credit_disposition === 'credit') {
        assert.equal(provenance.get(request.receipt).exitCode, 0, 'credited receipt command failed');
        validateReceipt(request, attempt.latest.receipt, frozenContext, contract, policyFiles, receipts, runtime);
      }
    }
    if (output.epochClosed && output.epochInvalidated) {
      const initial = obligations.filter(value => value.phase === 'initial').length;
      assert.ok(output.requests.length >= initial, 'invalidated initial inventory remains open');
      for (const request of output.requests) {
        assert.equal(request.fold_complete, true, 'invalidated epoch requires owner fold');
        assert.equal(attempts.get(request.request_id).latest.receipt.tupleVerdictExists, true, 'invalidated epoch requires original outcomes');
      }
    }
    previous = output;
  }
  return {receipts, provenance};
}
