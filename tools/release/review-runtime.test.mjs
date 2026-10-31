import assert from 'node:assert/strict';
import test from 'node:test';
import {authenticateReceipts} from './review-runtime.mjs';

const expected = {
  casPath: '/trusted/cas', codexPath: '/trusted/codex', repositoryPath: '/candidate',
  base: 'a'.repeat(40), settingsPath: '/trusted/settings.json', storeRoot: '/scratch/cas',
};
const startCommand = `/trusted/cas review start --wait --json --cwd /candidate --base ${expected.base} --codex-path /trusted/codex --thread-start-params-json @/trusted/settings.json --store-root /scratch/cas --workflow-binding-json @/scratch/binding.json`;
const receipt = {action: 'start', cwd: '/candidate', baseSha: expected.base, reviewThreadId: 'review-1', recordPath: '/scratch/cas/review_sessions/review-1.json'};
const bytes = value => Buffer.from(JSON.stringify(value));
const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
const item = (command = startCommand, value = receipt, overrides = {}) => ({
  type: 'item.completed', item: {id: 'command-1', type: 'command_execution', command,
    aggregated_output: JSON.stringify(value), exit_code: 0, status: 'completed', ...overrides},
});
const events = (...items) => Buffer.from([
  {type: 'thread.started', thread_id: 'owner-1'}, ...items, {type: 'turn.completed'},
].map(JSON.stringify).join('\n') + '\n');
const authenticate = (event = item(), record = receipt, settings = expected) => authenticateReceipts([events(event)], new Map([['receipt.json', bytes(record)]]), settings);

test('direct pinned command yields exact runtime provenance', () => {
  const result = authenticate();
  assert.equal(result.get('receipt.json').thread, 'owner-1');
  assert.equal(result.get('receipt.json').item, 'command-1');
  assert.equal(result.get('receipt.json').action, 'start');
  assert.match(result.get('receipt.json').receiptSha256, /^[0-9a-f]{64}$/);
});

test('single supported shell wrapper preserves direct command and quoted arguments', () => {
  for (const shell of ['/bin/zsh', '/bin/bash']) {
    const command = `${startCommand} --fresh-attempt 'owner confirmation' --custom-instructions 'literal $text; with a quote: '\\'' and new\nline'`;
    assert.equal(authenticate(item(`${shell} -lc ${shellQuote(command)}`)).size, 1);
  }
});

test('one harmless terminal newline is allowed without reserializing JSON', () => {
  assert.equal(authenticate(item(startCommand, receipt, {aggregated_output: JSON.stringify(receipt) + '\n'})).size, 1);
  assert.equal(authenticateReceipts([events(item())], new Map([['receipt.json', Buffer.from(JSON.stringify(receipt) + '\r\n')]]), expected).size, 1);
  assert.throws(() => authenticate(item(startCommand, receipt, {aggregated_output: JSON.stringify(receipt, null, 2)})), /lacks exact/);
});

test('forged echo and script output cannot authenticate receipts', () => {
  for (const command of ['echo fake', `/bin/cat /scratch/receipt.json`, '/trusted/cas-fake review start', 'node forge.mjs']) {
    assert.throws(() => authenticate(item(command)), /untrusted/);
  }
});

test('every command-bound selection must match trusted inputs', () => {
  for (const [before, after] of [
    ['/trusted/cas', '/scratch/cas-executable'], ['/trusted/codex', '/scratch/codex'],
    ['--cwd /candidate', '--cwd /other'], [expected.base, 'b'.repeat(40)],
    ['@/trusted/settings.json', '@/scratch/settings.json'], ['--store-root /scratch/cas', '--store-root /other'],
    ['--wait ', ''], ['--json ', ''], ['--workflow-binding-json @/scratch/binding.json', ''],
  ]) assert.throws(() => authenticate(item(startCommand.replace(before, after))));
});

test('shell substitutions redirects compound commands and environment overrides fail', () => {
  for (const command of [
    `${startCommand}; echo fake`, `${startCommand} > /scratch/result`, `${startCommand} | cat`,
    `${startCommand} && true`, `${startCommand}\necho fake`, `VAR=bad ${startCommand}`,
    `env ${startCommand}`, `${startCommand} --fresh-attempt $(touch /tmp/x)`,
    `${startCommand} --fresh-attempt "$(echo x)"`, `${startCommand} --fresh-attempt "\`echo x\`"`,
    `/bin/bash -lc ${shellQuote(`/bin/bash -lc ${shellQuote(startCommand)}`)}`,
    `/bin/bash -c ${shellQuote(startCommand)}`, `${startCommand} --fresh-attempt *.json`,
  ]) assert.throws(() => authenticate(item(command)));
});

test('unsupported duplicate and missing options fail closed', () => {
  for (const suffix of [' --json', ' --cwd /candidate', ' --hooks off', ' --parent-mode fresh', ' --fresh-attempt',
    ' --timeout-ms 0', ' --timeout-ms 4294967296', ' --timeout-ms 1.5', ' --fresh-attempt -']) {
    assert.throws(() => authenticate(item(startCommand + suffix)));
  }
  assert.equal(authenticate(item(startCommand + ' --timeout-ms 600000 --poll-interval-ms 250')).size, 1);
});

test('incomplete failed and non-command outputs provide no credit', () => {
  for (const override of [{status: 'in_progress'}, {status: 'failed'}, {exit_code: 1}, {exit_code: null}, {type: 'agent_message'}]) {
    assert.throws(() => authenticate(item(startCommand, receipt, override)));
  }
});

test('original failed CAS execution can be retained for recovery without becoming a verdict', () => {
  const failure = {...receipt, tupleVerdictExists: false, failureCode: 'review_transport_timeout', timedOut: true};
  const result = authenticate(item(startCommand, failure, {status: 'failed', exit_code: 1}), failure);
  assert.equal(result.get('receipt.json').exitCode, 1);
  const invented = {...failure, tupleVerdictExists: true};
  assert.throws(() => authenticate(item(startCommand, invented, {status: 'failed', exit_code: 1}), invented), /cannot establish review verdict/);
});

test('a fresh attempt reason named help cannot hide an unmatched original outcome', () => {
  const hidden = item(`${startCommand} --fresh-attempt '--help'`, {...receipt, reviewThreadId: 'unexported-original'}, {id: 'hidden'});
  assert.throws(() => authenticateReceipts([events(item(), hidden)], new Map([['receipt.json', bytes(receipt)]]), expected), /lacks exact runtime execution evidence/);
});

test('truncated or decorated output cannot authenticate original receipt', () => {
  for (const aggregated_output of [JSON.stringify(receipt).slice(0, -1), `Warning: truncated\n${JSON.stringify(receipt)}`, `{"output":${JSON.stringify(JSON.stringify(receipt))}}`]) {
    assert.throws(() => authenticate(item(startCommand, receipt, {aggregated_output})), /lacks exact/);
  }
  assert.throws(() => authenticateReceipts([events(item()).subarray(0, -3)], new Map([['receipt.json', bytes(receipt)]]), expected));
});

test('duplicate receipt names by content and repeated execution outputs are rejected', () => {
  assert.throws(() => authenticateReceipts([events(item())], new Map([['a.json', bytes(receipt)], ['b.json', bytes(receipt)]]), expected), /duplicate receipt/);
  assert.throws(() => authenticateReceipts([events(item(), item(startCommand, receipt, {id: 'command-2'}))], new Map([['a.json', bytes(receipt)]]), expected), /multiple runtime/);
  assert.throws(() => authenticateReceipts([events(item(), item())], new Map([['a.json', bytes(receipt)]]), expected), /duplicate completed/);
});

test('receipt subject and action must match actual execution', () => {
  for (const changed of [{...receipt, action: 'wait'}, {...receipt, baseSha: 'b'.repeat(40)}, {...receipt, cwd: '/other'}]) {
    assert.throws(() => authenticate(item(startCommand, changed), changed));
  }
});

test('wait binds to an earlier original start without disallowed launch options', () => {
  const waitReceipt = {...receipt, action: 'wait'};
  const records = new Map([['start.json', bytes(receipt)], ['wait.json', bytes(waitReceipt)]]);
  for (const selector of ['--review-thread-id review-1', `--path ${receipt.recordPath}`]) {
    const command = `/trusted/cas review wait --json --cwd /candidate --store-root /scratch/cas ${selector}`;
    const wait = item(command, waitReceipt, {id: 'command-2'});
    assert.equal(authenticateReceipts([events(item(), wait)], records, expected).get('wait.json').action, 'wait');
    assert.throws(() => authenticateReceipts([events(wait, item())], records, expected), /original start/);
    for (const extra of [' --codex-path /trusted/codex', ` --base ${expected.base}`, ' --thread-start-params-json @/trusted/settings.json', ' --latest']) {
      assert.throws(() => authenticateReceipts([events(item(), item(command + extra, waitReceipt, {id: 'command-2'}))], records, expected));
    }
  }
});

test('wait cannot select another thread or session record', () => {
  const waitReceipt = {...receipt, action: 'wait'};
  for (const selector of ['--review-thread-id review-2', '--path /scratch/cas/other.json', '--latest', '']) {
    const command = `/trusted/cas review wait --json --cwd /candidate --store-root /scratch/cas ${selector}`;
    assert.throws(() => authenticateReceipts([events(item(), item(command, waitReceipt, {id: 'command-2'}))],
      new Map([['start.json', bytes(receipt)], ['wait.json', bytes(waitReceipt)]]), expected));
  }
});

test('resumed owner captures admit exact independently protected settings paths', () => {
  const secondReceipt = {...receipt, reviewThreadId: 'review-2'};
  const secondEvents = events(item(startCommand.replace('@/trusted/settings.json', '@/trusted/resume.json'), secondReceipt))
    .toString().replace('owner-1', 'owner-2');
  const result = authenticateReceipts([events(item()), Buffer.from(secondEvents)],
    new Map([['a.json', bytes(receipt)], ['b.json', bytes(secondReceipt)]]),
    {...expected, settingsPaths: ['/trusted/settings.json', '/trusted/resume.json']});
  assert.equal(result.size, 2);
});

test('resumed captures may restart command IDs in the same owner thread', () => {
  const secondReceipt = {...receipt, reviewThreadId: 'review-2'};
  const result = authenticateReceipts([events(item()), events(item(startCommand, secondReceipt))],
    new Map([['a.json', bytes(receipt)], ['b.json', bytes(secondReceipt)]]), expected);
  assert.equal(result.get('a.json').thread, result.get('b.json').thread);
  assert.equal(result.get('a.json').item, result.get('b.json').item);
  assert.notEqual(result.get('a.json').source, result.get('b.json').source);
});

test('malformed evidence bytes duplicate JSON keys and excessive inputs fail closed', () => {
  assert.throws(() => authenticateReceipts([Buffer.from([0xff])], new Map([['a.json', bytes(receipt)]]), expected));
  assert.throws(() => authenticateReceipts([events(item())], new Map([['../escape', bytes(receipt)]]), expected));
  assert.throws(() => authenticateReceipts([events(item())], new Map([['a.json', Buffer.from('{"action":"start","action":"wait"}')]]), expected), /duplicate/);
  assert.throws(() => authenticateReceipts(Array(65).fill(events(item())), new Map([['a.json', bytes(receipt)]]), expected));
  assert.throws(() => authenticate(item(), receipt, {...expected, casPath: '/trusted/../trusted/cas'}));
});
