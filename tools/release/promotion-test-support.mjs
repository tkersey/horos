import {readFileSync} from 'node:fs';
import {sha256} from './encoding.mjs';
import {reviewPolicyDigest} from './review-owner.mjs';

const policyBytes = readFileSync(new URL('../../test/fixtures/release/review-contract.json', import.meta.url));
const contract = JSON.parse(policyBytes);

function evidence(contextInput, runtime, focused = []) {
  const context = {repository: runtime.repository, base_sha: contextInput.base, head_sha: contextInput.head,
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
export function retainedFixture(contextInput, settings) {
  const runtime = {repository: contextInput.repository, repositoryPath: '/candidate', codexVersion: '0.166.0',
    codexBinaryDigest: `sha256:${settings.codexSha256}`, threadStartParamsDigest: `sha256:${'d'.repeat(64)}`};
  const value = evidence(contextInput, runtime);
  const context = Buffer.from(JSON.stringify(contextInput));
  Object.assign(value.output, {schema: 'repository-review-owner/v1', contextSha256: sha256(context),
    policySha256: reviewPolicyDigest, closureBasis: 'Test-only complete owner disposition.'});
  const final = Buffer.from(JSON.stringify(value.output));
  const binding = {repository: '/candidate', workspace: '/owner', casPath: '/tools/cas', codexPath: '/tools/codex',
    base: value.output.base, head: value.output.head, contextSha256: sha256(context), ...settings};
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
