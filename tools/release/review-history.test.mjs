import assert from 'node:assert/strict';
import test from 'node:test';
import {retainedFixture} from './promotion-test-support.mjs';
import {ownerCapture, reviewCommand} from './review-test-support.mjs';
import {admitOwnerHistory} from './review-history.mjs';
import {validateRetainedReview, verifyOwnerChain} from './review-owner.mjs';

const context = {repository: 'tkersey/horos', base: 'a'.repeat(40), head: 'b'.repeat(40)};
const settings = {codexSha256: 'c'.repeat(64)};
const bytes = value => Buffer.from(JSON.stringify(value));
const read = value => JSON.parse(Buffer.from(value, 'base64'));

function fixture() {
  const retained = retainedFixture(context, settings);
  const outputs = retained.captures.map(capture => read(capture.final));
  const captures = retained.captures.map(capture => ({events: Buffer.from(capture.events, 'base64'), final: Buffer.from(capture.final, 'base64')}));
  const binding = read(retained.binding);
  return {retained, outputs, captures, contract: read(retained.contract), runtime: retained.runtime,
    files: new Map(Object.entries(retained.policyFiles).map(([name, value]) => [name, Buffer.from(value, 'base64')])),
    expected: {...binding, casPath: binding.casPath, codexPath: binding.codexPath, repositoryPath: binding.repository,
      storeRoot: '/owner/cas', settingsPaths: retained.settingsPaths}};
}

function admit(value) {
  verifyOwnerChain(value.captures, value.expected);
  return admitOwnerHistory(value.captures, value.outputs, value.contract, value.files, value.runtime, value.expected);
}

function replace(value, index, output, commands) {
  value.outputs[index] = output;
  value.captures[index] = ownerCapture(output, commands);
}

function pending(value, request, extra = {}) {
  return {...value.outputs[0], status: 'pending', epochClosed: false, requests: [request], ...extra};
}

function first(value) {
  const request = structuredClone(value.outputs[0].requests[0]);
  const receipt = read(value.retained.receipts[request.receipt]);
  return {request, receipt};
}

function failure(receipt, overrides = {}) {
  return {...receipt, reviewThreadId: 'failed-thread', reviewTurnId: 'failed-turn', tupleVerdictExists: false,
    reviewAttemptPhase: 'review_terminal', failureClass: 'transport_review_attempt', failureCode: 'review_transport_timeout',
    timedOut: true, reviewVerdict: null, ...overrides};
}

test('capture history carries every original command through retained complete readback', () => {
  const value = fixture();
  assert.equal(admit(value).receipts.size, 10);
  assert.equal(validateRetainedReview(bytes(value.retained), context).owner.output.status, 'complete');
});

test('ordinary CAS interface inspection does not become an extra review operation', () => {
  for (const command of ['/tools/cas review --help', '/tools/cas review start --help',
    '/tools/cas review start --fresh-attempt reason --help', '/tools/cas review wait --version']) {
    const value = fixture(), {request, receipt} = first(value), output = value.outputs[0];
    const help = {id: 'help', type: 'command_execution', status: 'completed', exit_code: 0,
      command, aggregated_output: 'CAS review command help'};
    replace(value, 0, output, [help, reviewCommand(output, request.receipt, bytes(receipt))]);
    assert.equal(admit(value).receipts.size, 10);
  }
});

test('help and version option values cannot conceal an original captured review execution', () => {
  for (const option of ['--fresh-attempt', '--custom-instructions']) {
    for (const valueArgument of ['--help', '--version']) {
      const value = fixture(), {request, receipt} = first(value), output = value.outputs[0];
      const hidden = reviewCommand(output, 'unexported.json', bytes(receipt), 99);
      hidden.command += ` ${option} '${valueArgument}'`;
      replace(value, 0, output, [hidden, reviewCommand(output, request.receipt, bytes(receipt))]);
      assert.throws(() => admit(value), /missing review option value/);
    }
  }
});

test('original findings cannot be replaced under the same label or a fresh label', () => {
  for (const name of ['receipt-0.json', 'replacement.json']) {
    const value = fixture(), {request, receipt} = first(value);
    const original = {...receipt, reviewVerdict: {...receipt.reviewVerdict, status: 'findings', findingCount: 1, findings: [{title: 'original'}]}};
    const held = {...request, credit_disposition: 'hold', unresolved_findings: ['original']};
    const before = pending(value, held), after = pending(value, {...request, receipt: name});
    value.outputs = [before, after];
    value.captures = [ownerCapture(before, [reviewCommand(before, request.receipt, bytes(original))]),
      ownerCapture(after, [reviewCommand(after, name, bytes(receipt))])];
    assert.throws(() => admit(value), /label reused|semantic outcome/);
  }
});

test('owner rejection preserves reported findings while allowing hold to credit', () => {
  const value = fixture(), {request, receipt} = first(value);
  receipt.reviewVerdict = {...receipt.reviewVerdict, status: 'findings', findingCount: 1, findings: [{title: 'reported finding'}]};
  const held = pending(value, {...request, credit_disposition: 'hold', fold_complete: false, unresolved_findings: ['reported finding']});
  const rejected = pending(value, {...request, credit_basis: 'Owner rejected the finding against the accepted source.'});
  value.outputs.splice(0, 1, held, rejected);
  value.captures.splice(0, 1, ownerCapture(held, [reviewCommand(held, request.receipt, bytes(receipt))]), ownerCapture(rejected));
  const history = admit(value);
  assert.equal(JSON.parse(history.receipts.get(request.receipt)).reviewVerdict.status, 'findings');
  value.retained.receipts[request.receipt] = bytes(receipt).toString('base64');
  value.retained.captures = value.captures.map(capture => ({events: capture.events.toString('base64'), final: capture.final.toString('base64')}));
  assert.equal(validateRetainedReview(bytes(value.retained), context).owner.output.status, 'complete');
});

test('limitation recovery can credit the original obligation without another review', () => {
  const value = fixture(), {request, receipt} = first(value);
  const held = pending(value, {...request, credit_disposition: 'hold', limitations: [{disposition: 'unresolved', basis: 'Missing observation.'}]});
  const recovered = pending(value, {...request, limitations: [{disposition: 'recovered', basis: 'Original missing observation and reasoning completed.'}]});
  value.outputs = [held, recovered];
  value.captures = [ownerCapture(held, [reviewCommand(held, request.receipt, bytes(receipt))]), ownerCapture(recovered)];
  assert.equal(admit(value).receipts.size, 1);
});

test('accepted invalidation persists while remaining initial outcomes are folded for evidence', () => {
  const value = fixture();
  value.outputs = value.outputs.slice(0, 6).map((output, index) => ({...output, epochInvalidated: true,
    invalidationBasis: 'Owner accepted a current material entailed finding.', epochClosed: index === 5,
    status: index === 5 ? 'blocked' : 'pending', requests: output.requests.map(request => ({...request, credit_disposition: 'hold'}))}));
  value.captures = value.outputs.map((output, index) => ownerCapture(output,
    [reviewCommand(output, output.requests[index].receipt, Buffer.from(value.retained.receipts[output.requests[index].receipt], 'base64'), index)]));
  assert.equal(admit(value).receipts.size, 6);
  const revoked = {...value.outputs[5], epochInvalidated: false, invalidationBasis: null};
  replace(value, 5, revoked, [reviewCommand(revoked, revoked.requests[5].receipt, Buffer.from(value.retained.receipts[revoked.requests[5].receipt], 'base64'), 5)]);
  assert.throws(() => admit(value), /invalidation was erased/);
});

test('serial dispatch requires a prior folded terminal outcome', () => {
  const value = fixture(), {request, receipt} = first(value);
  const held = pending(value, {...request, credit_disposition: 'hold', fold_complete: false});
  replace(value, 0, held, [reviewCommand(held, request.receipt, bytes(receipt))]);
  assert.throws(() => admit(value), /before prior owner fold/);
});

test('policy-ordered exports cannot disguise confirmations executed before initial reviews', () => {
  const value = fixture();
  const commands = value.captures.map(capture => capture.events.toString().trimEnd().split('\n').map(JSON.parse)
    .find(event => event.type === 'item.completed' && event.item?.type === 'command_execution').item);
  replace(value, 0, value.outputs[0], [commands[6]]);
  replace(value, 6, value.outputs[6], [commands[0]]);
  assert.throws(() => admit(value), /unexported original/);
});

test('same-turn initial fold and confirmations cannot replace the causal turn boundary', () => {
  const value = fixture(), output = value.outputs.at(-1);
  value.outputs = [output];
  value.captures = [ownerCapture(output, output.requests.map((request, index) =>
    reviewCommand(output, request.receipt, Buffer.from(value.retained.receipts[request.receipt], 'base64'), index)))];
  assert.throws(() => admit(value), /more than one review operation/);
});

test('one fresh recovery preserves the failed original and rejects failure omission', () => {
  const value = fixture(), {request, receipt} = first(value);
  const failed = failure(receipt), held = pending(value, {...request, credit_disposition: 'hold', fold_complete: false});
  const recovered = pending(value, {...request, receipt: 'fresh.json', prior_receipts: [request.receipt]});
  const start = {...reviewCommand(held, request.receipt, bytes(failed)), exit_code: 1, status: 'failed'};
  const fresh = reviewCommand(recovered, 'fresh.json', bytes(receipt));
  fresh.command += " --fresh-attempt 'original terminal transport failure'";
  value.outputs = [held, recovered]; value.captures = [ownerCapture(held, [start]), ownerCapture(recovered, [fresh])];
  assert.equal(admit(value).receipts.size, 2);
  const omitted = pending(value, {...request, receipt: 'fresh.json'});
  replace(value, 1, omitted, [fresh]);
  assert.throws(() => admit(value), /omitted original failed outcome/);
});

test('repeated pending waits retain all original observations and admit the recovered outcome', () => {
  const value = fixture(), {request, receipt} = first(value);
  const running = failure(receipt, {reviewThreadId: receipt.reviewThreadId, reviewTurnId: receipt.reviewTurnId,
    reviewAttemptPhase: 'review_running', recordPath: '/owner/cas/original.json'});
  const outputs = [], captures = [];
  const add = (name, record, terminal) => {
    const next = pending(value, {...request, receipt: name, ...(record.action === 'wait' ? {start_receipt: request.receipt} : {}),
      credit_disposition: terminal ? 'credit' : 'hold', fold_complete: terminal});
    const command = reviewCommand(next, name, bytes(record));
    if (record.action === 'wait') command.command = `/tools/cas review wait --json --cwd /candidate --store-root /owner/cas --review-thread-id ${receipt.reviewThreadId}`;
    outputs.push(next); captures.push(ownerCapture(next, [command]));
  };
  add(request.receipt, running, false);
  add('wait-one.json', {...running, action: 'wait'}, false);
  add('wait-two.json', {...running, action: 'wait'}, false);
  add('wait-complete.json', {...receipt, action: 'wait'}, true);
  value.outputs = outputs; value.captures = captures;
  assert.equal(admit(value).receipts.size, 4);
});

test('an observation timeout cannot authorize a new review attempt', () => {
  const value = fixture(), {request, receipt} = first(value);
  const running = failure(receipt, {reviewAttemptPhase: 'review_running'});
  const held = pending(value, {...request, credit_disposition: 'hold', fold_complete: false});
  const fresh = pending(value, {...request, receipt: 'fresh.json', prior_receipts: [request.receipt]});
  const command = reviewCommand(fresh, 'fresh.json', bytes(receipt)); command.command += " --fresh-attempt 'timeout'";
  value.outputs = [held, fresh]; value.captures = [ownerCapture(held, [reviewCommand(held, request.receipt, bytes(running))]), ownerCapture(fresh, [command])];
  assert.throws(() => admit(value), /observation timeout is not terminal/);
});
