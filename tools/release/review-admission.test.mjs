import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {sha256} from './encoding.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {validateOwnerEvidence} from './review-admission.mjs';
import {reviewPolicyDigest, validateRetainedReview} from './review-owner.mjs';

const policyBytes = readFileSync(new URL('../../test/fixtures/release/review-contract.json', import.meta.url));
const contract = JSON.parse(policyBytes);
const runtime = {repository: 'tkersey/horos', repositoryPath: '/candidate', codexVersion: '0.166.0',
  codexBinaryDigest: `sha256:${'c'.repeat(64)}`, threadStartParamsDigest: `sha256:${'d'.repeat(64)}`};

function evidence(focused = []) {
  const context = {repository: runtime.repository, base_sha: 'a'.repeat(40), head_sha: 'b'.repeat(40),
    execution_mode: 'cas', focused_files: focused};
  const output = {status: 'complete', epochClosed: true, executionMode: 'cas',
    base: context.base_sha, head: context.head_sha, reviewContext: context, requests: []};
  const files = new Map([[contract.focused_file_reviews.instructions_ref, Buffer.from('test file-focus\n')]]);
  for (const lens of contract.required_lenses.filter(lens => lens.instructions_ref)) files.set(lens.instructions_ref, Buffer.from(`test ${lens.name}\n`));
  const receipts = new Map();
  const add = (lens, scope, focus, phase) => {
    const index = output.requests.length;
    let instructions = null;
    if (scope === 'file') {
      const parts = [files.get(contract.focused_file_reviews.instructions_ref).toString()];
      if (lens.instructions_ref) parts.push(files.get(lens.instructions_ref).toString());
      parts.push(JSON.stringify({repository: context.repository, base_sha: context.base_sha,
        head_sha: context.head_sha, lens_name: lens.name, scope, focus}));
      instructions = parts.join('\n\n');
    } else if (lens.instructions_ref) instructions = files.get(lens.instructions_ref).toString();
    const request = {request_id: `request-${index}`, request_fingerprint: `binding-${index}`,
      target_fingerprint: `target-${index}`, lens_name: lens.name, role: lens.role, scope, focus, phase,
      instruction_digest: sha256(Buffer.from(instructions ?? 'codex-default-review/v1')),
      receipt: `receipt-${index}.json`, credit_disposition: 'credit', credit_basis: 'Test-only owner disposition.',
      limitations: [], fold_complete: true, unresolved_findings: []};
    const binding = {requestId: request.request_id, requestFingerprint: request.request_fingerprint};
    const identity = {baseSha: output.base, headSha: output.head, targetFingerprint: request.target_fingerprint,
      workflowBinding: binding, reviewThreadId: `thread-${index}`, reviewTurnId: `turn-${index}`};
    receipts.set(request.receipt, Buffer.from(JSON.stringify({
      ...identity, action: 'start', waited: true, timedOut: false, cwd: runtime.repositoryPath,
      reviewAttemptExists: true, tupleVerdictExists: true, compatibilityVerdict: 'compatible',
      structuredReviewCapability: true, appServerContractId: 'codex-app-server-capabilities-v2', selectedTransport: 'websocket',
      resolvedCodexVersion: runtime.codexVersion, codexBinaryDigest: runtime.codexBinaryDigest,
      threadStartParamsDigest: runtime.threadStartParamsDigest, developerInstructions: instructions,
      reviewResult: {findings: [], overall_correctness: 'patch is correct', overall_confidence_score: 0.91},
      reviewVerdict: {...identity, status: 'clean', backendClass: 'cas-start-wait', principalStrength: 'strong',
        accountFingerprintReducedProtection: false, accountFingerprint: 'test-account', findingCount: 0, findings: []},
    })));
    output.requests.push(request);
  };
  for (const focus of [null, ...focused]) {
    for (const lens of contract.required_lenses) add(lens, focus === null ? 'changeset' : 'file', focus, 'initial');
  }
  for (let index = 0; index < 4; index++) add(contract.required_lenses[0], 'changeset', null, 'confirmation');
  return {output, files, receipts};
}
function validate(value) { return validateOwnerEvidence(value.output, contract, value.files, value.receipts, runtime); }
function changeReceipt(value, change, index = 0) {
  const name = value.output.requests[index].receipt;
  const receipt = JSON.parse(value.receipts.get(name));
  change(receipt);
  value.receipts.set(name, Buffer.from(JSON.stringify(receipt)));
}

test('admission follows the pinned owner inventory and original attributed facts', () => {
  assert.equal(sha256(policyBytes), reviewPolicyDigest);
  const value = evidence();
  assert.equal(value.output.requests.length, 10);
  assert.equal(validate(value).head, value.output.head);
  const focused = evidence([{base_path: 'src/source.zig', head_path: 'src/source.zig'}]);
  assert.equal(focused.output.requests.length, 16);
  assert.equal(validate(focused).head, focused.output.head);
});

for (const [name, change] of [
  ['five standards without auxiliary evidence', value => {value.output.requests = value.output.requests.filter(request => request.lens_name === 'standard');}],
  ['held owner credit', value => {value.output.requests[0].credit_disposition = 'hold';}],
  ['missing owner basis', value => {value.output.requests[0].credit_basis = '';}],
  ['unresolved evidence limitation', value => {value.output.requests[0].limitations = [{disposition: 'unresolved', basis: 'Missing source.'}];}],
  ['unfolded finding', value => {value.output.requests[0].fold_complete = false;}],
  ['unresolved finding', value => {value.output.requests[0].unresolved_findings = ['finding'];}],
  ['missing original receipt', value => {value.receipts.delete('receipt-0.json');}],
  ['replayed request', value => {value.output.requests[1].request_id = value.output.requests[0].request_id;}],
  ['unclosed epoch', value => {value.output.epochClosed = false;}],
  ['wrong executor', value => {value.output.executionMode = 'subagents';}],
]) {
  test(`reject ${name}`, () => {const value = evidence(); change(value); assert.throws(() => validate(value));});
}

for (const [name, change] of [
  ['different head', receipt => {receipt.reviewVerdict.headSha = 'e'.repeat(40);}],
  ['different request binding', receipt => {receipt.workflowBinding.requestId = 'other';}],
  ['different model settings', receipt => {receipt.threadStartParamsDigest = 'other';}],
  ['different runtime', receipt => {receipt.codexBinaryDigest = 'other';}],
  ['reduced principal', receipt => {receipt.reviewVerdict.accountFingerprintReducedProtection = true;}],
  ['fallback backend', receipt => {receipt.reviewVerdict.backendClass = 'fallback';}],
  ['incompatible runtime', receipt => {receipt.compatibilityVerdict = 'incompatible';}],
  ['unstructured verdict', receipt => {delete receipt.reviewVerdict;}],
  ['custom native standard', receipt => {receipt.developerInstructions = 'altered';}],
  ['lost owner', receipt => {receipt.waited = false;}],
  ['timed-out review', receipt => {receipt.timedOut = true;}],
]) {
  test(`reject original receipt with ${name}`, () => {const value = evidence(); changeReceipt(value, change); assert.throws(() => validate(value));});
}

test('focused file obligations cannot be replaced by further changeset standards', () => {
  const value = evidence([{base_path: null, head_path: 'new.zig'}]);
  value.output.requests[6].scope = 'changeset';
  value.output.requests[6].focus = null;
  assert.throws(() => validate(value));
});

test('changed auxiliary bytes fail even if the owner export repeats the new digest', () => {
  const value = evidence();
  changeReceipt(value, receipt => {receipt.developerInstructions += ' extra';}, 1);
  value.output.requests[1].instruction_digest = sha256(Buffer.from('test soundness-skeptic\n extra'));
  assert.throws(() => validate(value), /auxiliary instructions/);
});

test('one verdictless terminal preserves original evidence before an exact-request fresh recovery', () => {
  const value = evidence();
  const request = value.output.requests[0];
  const failed = JSON.parse(value.receipts.get(request.receipt));
  Object.assign(failed, {reviewThreadId: 'failed-thread', reviewTurnId: 'failed-turn',
    tupleVerdictExists: false, reviewAttemptPhase: 'review_terminal', failureClass: 'transport_review_attempt',
    failureCode: 'review_transport_timeout', reviewVerdict: null});
  value.receipts.set('failed.json', Buffer.from(JSON.stringify(failed)));
  request.prior_receipts = ['failed.json'];
  assert.equal(validate(value).head, value.output.head);
  request.prior_receipts.push('failed.json');
  assert.throws(() => validate(value), /allowance exceeded/);
  request.prior_receipts.pop();
  failed.reviewAttemptPhase = 'review_running';
  value.receipts.set('failed.json', Buffer.from(JSON.stringify(failed)));
  assert.throws(() => validate(value), /observation timeout/);
  failed.reviewAttemptPhase = 'review_terminal';
  failed.tupleVerdictExists = true;
  value.receipts.set('failed.json', Buffer.from(JSON.stringify(failed)));
  assert.throws(() => validate(value), /semantic outcome/);
});

test('evidence JSON accepts actual fractional confidence but rejects duplicate or unsafe identities', () => {
  assert.equal(parseEvidenceJson('{"confidence":0.91}').confidence, 0.91);
  for (const text of ['{"head":"a","head":"b"}', '{"head":"a","\\u0068ead":"b"}', '{"id":9007199254740993}', '{"x":1e999}']) {
    assert.throws(() => parseEvidenceJson(text));
  }
});

function retainedEvidence() {
  const value = evidence();
  const context = Buffer.from(JSON.stringify({repository: runtime.repository, base: value.output.base, head: value.output.head}));
  Object.assign(value.output, {schema: 'repository-review-owner/v1', contextSha256: sha256(context),
    policySha256: reviewPolicyDigest, closureBasis: 'Test-only complete owner disposition.'});
  const final = Buffer.from(JSON.stringify(value.output));
  const binding = {repository: '/candidate', workspace: '/owner', casPath: '/tools/cas', codexPath: '/tools/codex',
    base: value.output.base, head: value.output.head, contextSha256: sha256(context), codexSha256: 'c'.repeat(64)};
  const events = [{type: 'thread.started', thread_id: 'owner-retention-test'},
    ...[...value.receipts].map(([name, bytes], index) => ({type: 'item.completed', item: {
      id: `command-${index}`, type: 'command_execution', status: 'completed', exit_code: 0,
      command: `/tools/cas review start --wait --json --cwd /candidate --base ${value.output.base} --codex-path /tools/codex --thread-start-params-json @/capture/settings.json --store-root /owner/cas --workflow-binding-json @/owner/${name}.binding`,
      aggregated_output: bytes.toString(),
    }})),
    {type: 'item.completed', item: {id: 'final', type: 'agent_message', text: final.toString()}},
    {type: 'turn.completed'}];
  const base64 = value => Buffer.isBuffer(value) ? value.toString('base64') : Buffer.from(JSON.stringify(value)).toString('base64');
  return {schema: 'repository-review-evidence/v1', context: base64(context), binding: base64(binding),
    contract: base64(policyBytes), captures: [{events: base64(Buffer.from(events.map(event => JSON.stringify(event)).join('\n') + '\n')), final: base64(final)}],
    receipts: Object.fromEntries([...value.receipts].map(([name, bytes]) => [name, base64(bytes)])),
    policyFiles: Object.fromEntries([...value.files].map(([name, bytes]) => [name, base64(bytes)])), runtime,
    settingsPaths: ['/capture/settings.json']};
}

test('compact retained evidence preserves exact runtime and owner admission checks', () => {
  const retained = retainedEvidence(), expected = {base: 'a'.repeat(40), head: 'b'.repeat(40)};
  assert.equal(validateRetainedReview(Buffer.from(JSON.stringify(retained)), expected).owner.output.status, 'complete');
  assert.throws(() => validateRetainedReview(Buffer.from(JSON.stringify(retained)), {...expected, head: 'f'.repeat(40)}));
  retained.receipts['receipt-0.json'] = Buffer.from('{}').toString('base64');
  assert.throws(() => validateRetainedReview(Buffer.from(JSON.stringify(retained)), expected), /runtime execution evidence/);
});

test('retained owner clean export without its original command output cannot be admitted', () => {
  const retained = retainedEvidence();
  const events = Buffer.from(retained.captures[0].events, 'base64').toString().split('\n')
    .filter(line => !line.includes('command-0')).join('\n');
  retained.captures[0].events = Buffer.from(events).toString('base64');
  assert.throws(() => validateRetainedReview(Buffer.from(JSON.stringify(retained)), {base: 'a'.repeat(40), head: 'b'.repeat(40)}), /runtime execution evidence/);
});
