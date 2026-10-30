import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {ownerArguments, ownerPrompt, readRegular, reviewerEnvironment, reviewPolicyDigest, verifyOwnerChain, verifyOwnerTranscript} from './review-owner.mjs';
import {runOwnerProcess} from './owner-process.mjs';

const expected = {base: 'a'.repeat(40), head: 'b'.repeat(40), contextSha256: 'c'.repeat(64)};
function output() {
  return {schema: 'repository-review-owner/v1', status: 'blocked', ...expected,
    policySha256: reviewPolicyDigest, executionMode: 'cas', epochClosed: false,
    closureBasis: 'Test-only missing authentication.', requests: []};
}
function transcript(value) {
  const final = JSON.stringify(value);
  return [Buffer.from([
    {type: 'thread.started', thread_id: 'owner-test'},
    {type: 'turn.started'},
    {type: 'item.completed', item: {id: 'item-test', type: 'agent_message', text: final}},
    {type: 'turn.completed', usage: {input_tokens: 1, output_tokens: 1}},
  ].map(value => JSON.stringify(value)).join('\n') + '\n'), Buffer.from(final)];
}

test('review environment carries model auth without ambient GitHub or Git writer credentials', () => {
  const env = reviewerEnvironment('/review-home', '/accepted/bin', {
    OPENAI_API_KEY: 'test-model-key', GH_TOKEN: 'test-write-token', GITHUB_TOKEN: 'test-write-token',
    AWS_SECRET_ACCESS_KEY: 'test-secret', GIT_CONFIG_COUNT: '1', CODEX_HOME: '/ambient',
  });
  assert.equal(env.OPENAI_API_KEY, 'test-model-key');
  for (const key of ['GH_TOKEN', 'GITHUB_TOKEN', 'AWS_SECRET_ACCESS_KEY', 'GIT_CONFIG_COUNT']) assert.equal(env[key], undefined);
  assert.equal(env.HOME, '/review-home');
  assert.equal(env.CODEX_HOME, '/review-home/.codex');
  assert.equal(env.GIT_CONFIG_GLOBAL, '/dev/null');
});

test('owner invocation selects explicit model settings and the existing policy procedure', () => {
  const settings = {model: 'gpt-6-astra', reasoningEffort: 'high', serviceTier: 'default'};
  const args = ownerArguments({workspace: '/owner-workspace', captureRoot: '/captures/turn1', ...settings});
  assert.equal(args[0], 'exec');
  assert.ok(args.includes('review_model="gpt-6-astra"'));
  assert.ok(args.includes('model_reasoning_effort="high"'));
  assert.ok(!args.includes('--dangerously-bypass-approvals-and-sandbox'));
  assert.ok(args.includes('/captures/turn1/owner-final.json'));
  assert.ok(args.includes('sandbox_workspace_write.exclude_slash_tmp=true'));
  const prompt = ownerPrompt({repository: '/candidate', policyDirectory: '/policy', contextPath: '/context.json',
    workspace: '/owner-workspace', settingsPath: '/captures/turn1/thread-start.json', casPath: '/tools/cas', settings});
  assert.match(prompt, /ordinary review-closeout procedure with serial-reviews and CAS/);
  assert.match(prompt, /Native changeset standard must have no custom instructions/);
  assert.match(prompt, /never repair/i);
  assert.throws(() => ownerArguments({workspace: '/owner', model: 'model;command', reasoningEffort: 'high', serviceTier: 'default'}));
});

test('bounded owner turns resume the same session without awarding partial credit', () => {
  const pending = {...output(), status: 'pending'};
  const capture = value => {
    const [events, final] = transcript(value);
    return {events, final};
  };
  const result = verifyOwnerChain([capture(pending), capture(output())], expected);
  assert.equal(result.output.status, 'blocked');
  assert.throws(() => verifyOwnerChain([capture(output()), capture(pending)], expected), /terminal/);
  assert.throws(() => verifyOwnerChain([capture({...pending, epochClosed: true})], expected), /closed epoch/);
  const switched = capture(pending);
  switched.events = Buffer.from(switched.events.toString().replace('owner-test', 'different-owner'));
  assert.throws(() => verifyOwnerChain([capture(pending), switched], expected), /session changed/);
  const request = {request_id: 'one', request_fingerprint: 'bound', receipt: 'one.json'};
  assert.throws(() => verifyOwnerChain([capture({...pending, requests: [request]}), capture(pending)], expected), /lost original/);
  assert.throws(() => verifyOwnerChain([capture({...pending, requests: [request]}),
    capture({...pending, requests: [{...request, receipt: 'forged.json'}]})], expected), /rewritten original/);
  assert.equal(verifyOwnerChain([capture({...pending, requests: [request]}),
    capture({...pending, requests: [{...request, start_receipt: request.receipt, receipt: 'wait.json'}]})], expected).output.status, 'pending');
  assert.equal(verifyOwnerChain([capture({...pending, requests: [request]}),
    capture({...pending, requests: [{...request, prior_receipts: [request.receipt], receipt: 'recovered.json'}]})], expected).output.status, 'pending');
  const thread = '01234567-0123-4567-89ab-0123456789ab';
  const args = ownerArguments({workspace: '/owner', captureRoot: '/capture', model: 'gpt-6-astra',
    reasoningEffort: 'high', serviceTier: 'default', resumeThread: thread});
  assert.deepEqual(args.slice(-3), ['resume', thread, '-']);
});

test('blocked owner output is retained without granting review credit', () => {
  const [events, final] = transcript(output());
  const result = verifyOwnerTranscript(events, final, expected);
  assert.equal(result.thread, 'owner-test');
  assert.equal(result.output.status, 'blocked');
});

test('detached JSON, replayed subjects and nonterminal owner streams cannot establish provenance', () => {
  const [events, final] = transcript(output());
  assert.throws(() => verifyOwnerTranscript(events, Buffer.from('{}'), expected));
  assert.throws(() => verifyOwnerTranscript(events, final, {...expected, head: 'd'.repeat(40)}));
  assert.throws(() => verifyOwnerTranscript(events, final, {...expected, contextSha256: 'd'.repeat(64)}));
  const partial = Buffer.from(events.toString().split('\n').slice(0, -2).join('\n'));
  assert.throws(() => verifyOwnerTranscript(partial, final, expected));
  assert.throws(() => verifyOwnerTranscript(Buffer.concat([events, Buffer.from('{"type":"error","message":"failed"}\n')]), final, expected));
});

test('complete label without owner handoffs and bound context is rejected', () => {
  const value = {...output(), status: 'complete', epochClosed: true};
  const [events, final] = transcript(value);
  assert.throws(() => verifyOwnerTranscript(events, final, expected), /handoffs/);
});

test('evidence reader rejects symlinks and byte-limit violations', () => {
  const directory = mkdtempSync(join(tmpdir(), 'horos-review-files-'));
  try {
    const file = join(directory, 'file'), link = join(directory, 'link');
    writeFileSync(file, 'original');
    symlinkSync(file, link);
    assert.equal(readRegular(file, 8).toString(), 'original');
    assert.throws(() => readRegular(file, 7));
    assert.throws(() => readRegular(link, 8));
    assert.throws(() => readRegular(directory, 1024));
  } finally { rmSync(directory, {recursive: true, force: true}); }
});

for (const [name, script, options, expectedFailure] of [
  ['original output', "process.stdin.resume(); process.stdout.write('original');", {}, null],
  ['deadline', 'setInterval(() => {}, 1000);', {timeoutMs: 150}, 'deadline'],
  ['output limit', "process.stdout.write('x'.repeat(4096));", {maximumBytes: 1024}, 'output-limit'],
]) {
  test(`owner process retains ${name} without retry`, async () => {
    const root = mkdtempSync(join(tmpdir(), 'horos-owner-process-'));
    const workspace = join(root, 'workspace'), captureRoot = join(root, 'capture');
    mkdirSync(workspace);
    mkdirSync(captureRoot);
    try {
      const env = {...process.env};
      delete env.NODE_TEST_CONTEXT;
      const result = await runOwnerProcess(process.execPath, ['-e', script], {workspace, captureRoot, env, input: '', ...options});
      assert.equal(result.failure, expectedFailure);
      if (expectedFailure === null) {
        assert.equal(result.code, 0);
        assert.equal(readFileSync(join(captureRoot, 'owner-events.jsonl'), 'utf8'), 'original');
        assert.throws(() => readFileSync(join(workspace, 'owner-events.jsonl')));
      }
      await assert.rejects(runOwnerProcess(process.execPath, ['-e', script], {workspace, captureRoot, env, input: '', ...options}));
    } finally { rmSync(root, {recursive: true, force: true}); }
  });
}
