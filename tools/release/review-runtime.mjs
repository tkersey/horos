import assert from 'node:assert/strict';
import {isAbsolute, normalize} from 'node:path';
import {parseEvidenceJson} from './evidence-json.mjs';
import {sha256} from './encoding.mjs';

function shellWords(command) {
  assert.ok(typeof command === 'string' && Buffer.byteLength(command) <= 1024 * 1024, 'invalid command');
  const words = [];
  let word = '', quote = null, started = false;
  for (let index = 0; index < command.length; index++) {
    const char = command[index];
    assert.ok(char !== '\0' && char !== '\r', 'invalid command character');
    if (quote === "'") {
      if (char === "'") quote = null;
      else word += char;
      continue;
    }
    if (quote === '"') {
      if (char === '"') quote = null;
      else if (char === '\\') {
        const next = command[++index];
        assert.ok(['\\', '"', '$', '`'].includes(next), 'unsupported quoted escape');
        word += next;
      } else {
        assert.ok(char !== '$' && char !== '`', 'shell substitution');
        word += char;
      }
      continue;
    }
    if (char === ' ' || char === '\t') {
      if (started) words.push(word);
      word = ''; started = false;
    } else if (char === "'" || char === '"') {
      quote = char; started = true;
    } else if (char === '\\') {
      const next = command[++index];
      assert.ok(next !== undefined && !/[\r\n\0]/.test(next), 'unsupported escape');
      word += next; started = true;
    } else {
      assert.ok(!/[\n$`;&|<>(){}*?~#!]/.test(char), 'unsupported shell syntax');
      word += char; started = true;
    }
    assert.ok(words.length <= 128, 'too many command words');
  }
  assert.equal(quote, null, 'unterminated quote');
  if (started) words.push(word);
  return words;
}

function reviewOptions(action) {
  return {
    flags: new Set(['--json', ...(action === 'wait' ? [] : ['--wait'])]),
    values: new Set(['--cwd', '--store-root', '--timeout-ms', '--poll-interval-ms',
      ...(action === 'wait' ? ['--review-thread-id', '--path'] : ['--base', '--codex-path', '--thread-start-params-json',
        '--workflow-binding-json', '--custom-instructions', '--fresh-attempt'])]),
  };
}

function commandArguments(command, expected) {
  let words = shellWords(command);
  if (['/bin/zsh', '/bin/bash'].includes(words[0])) {
    assert.equal(words.length, 3, 'unsupported shell wrapper');
    assert.equal(words[1], '-lc', 'unsupported shell wrapper');
    words = shellWords(words[2]);
  }
  assert.equal(words[0], expected.casPath, 'untrusted review executable');
  assert.equal(words[1], 'review', 'not a review command');
  const action = words[2];
  assert.ok(['start', 'wait'].includes(action), 'unsupported review action');
  const {flags, values} = reviewOptions(action);
  const options = new Map();
  for (let index = 3; index < words.length; index++) {
    const flag = words[index];
    assert.ok(!options.has(flag), 'duplicate review option');
    if (flags.has(flag)) options.set(flag, true);
    else {
      assert.ok(values.has(flag), 'unsupported review option');
      const value = words[++index];
      assert.ok(typeof value === 'string' && value.length > 0 && value !== '-' && !value.startsWith('--'), 'missing review option value');
      options.set(flag, value);
    }
  }
  assert.equal(options.get('--json'), true, 'missing JSON output');
  assert.equal(options.get('--cwd'), expected.repositoryPath, 'wrong repository');
  assert.equal(options.get('--store-root'), expected.storeRoot, 'wrong receipt store');
  for (const flag of ['--timeout-ms', '--poll-interval-ms']) {
    if (!options.has(flag)) continue;
    assert.match(options.get(flag), /^[1-9][0-9]{0,9}$/);
    assert.ok(Number(options.get(flag)) <= 4294967295, 'invalid review duration');
  }
  if (action === 'start') {
    assert.equal(options.get('--wait'), true, 'review was not owner-lived');
    assert.equal(options.get('--base'), expected.base, 'wrong review base');
    assert.equal(options.get('--codex-path'), expected.codexPath, 'wrong runtime executable');
    assert.ok((expected.settingsPaths ?? [expected.settingsPath]).some(path => options.get('--thread-start-params-json') === `@${path}`), 'wrong reviewer settings');
    assert.ok(options.has('--workflow-binding-json'), 'missing owner workflow binding');
  } else assert.equal(Number(options.has('--review-thread-id')) + Number(options.has('--path')), 1, 'missing unique attempt selector');
  return {action, options};
}

function textBytes(bytes, maximum) {
  assert.ok(Buffer.isBuffer(bytes) && bytes.length <= maximum, 'invalid runtime evidence bytes');
  return new TextDecoder('utf-8', {fatal: true}).decode(bytes);
}

function withoutTerminalNewline(text) {
  return text.endsWith('\r\n') ? text.slice(0, -2) : text.endsWith('\n') ? text.slice(0, -1) : text;
}

function reviewCommand(command, casPath) {
  if (typeof command !== 'string') return false;
  try {
    let words = shellWords(command);
    if (['/bin/zsh', '/bin/bash'].includes(words[0]) && words.length === 3) words = shellWords(words[2]);
    if (words[0] !== casPath || words[1] !== 'review') return false;
    if (words.length === 2 || ['--help', '--version'].includes(words[2])) return false;
    const {flags, values} = reviewOptions(words[2]);
    for (let index = 3; index < words.length; index++) {
      const option = words[index];
      if (['--help', '--version'].includes(option)) return false;
      if (flags.has(option)) continue;
      if (!values.has(option) || ++index >= words.length) return true;
    }
    return true;
  } catch {
    return command.includes(casPath) && /\breview\b/.test(command);
  }
}

export function capturedReceipts(captures, outputs, expected) {
  const receipts = new Map(), observations = [];
  assert.equal(captures.length, outputs.length);
  for (let source = 0; source < captures.length; source++) {
    const events = textBytes(captures[source].events, 64 * 1024 * 1024).trimEnd().split('\n').map(line => parseEvidenceJson(line));
    const started = new Set(), completed = new Set(), executions = [];
    for (const event of events) {
      const item = event.item;
      if (item?.type !== 'command_execution' || !reviewCommand(item.command, expected.casPath)) continue;
      if (event.type === 'item.started') started.add(item.id);
      if (event.type !== 'item.completed') continue;
      completed.add(item.id);
      commandArguments(item.command, expected);
      const bytes = Buffer.from(item.aggregated_output, 'utf8');
      const receipt = parseEvidenceJson(bytes);
      executions.push({source, item: item.id, bytes, receipt});
    }
    for (const id of started) assert.ok(completed.has(id), 'review execution is still unresolved');
    assert.ok(executions.length <= 1, 'owner turn performed more than one review operation');
    const output = outputs[source];
    if (executions.length === 1) {
      const execution = executions[0];
      const request = output.requests.find(request => request.request_id === execution.receipt.workflowBinding?.requestId);
      assert.ok(request, 'unexported original review execution');
      const name = request.receipt;
      assert.ok(typeof name === 'string' && name.length > 0 && !isAbsolute(name) && !name.split('/').includes('..'), 'invalid receipt name');
      assert.ok(!receipts.has(name), 'original receipt label reused for another execution');
      receipts.set(name, execution.bytes);
      observations.push({...execution, name, request});
    }
    for (const request of output.requests) {
      for (const name of [request.receipt, request.start_receipt, ...(request.prior_receipts ?? [])].filter(Boolean)) {
        assert.ok(receipts.has(name), 'owner export lacks original captured receipt');
      }
    }
  }
  return {receipts, observations};
}

export function authenticateReceipts(eventsBytes, receipts, expected, observations = null) {
  assert.ok(Array.isArray(eventsBytes) && eventsBytes.length > 0 && eventsBytes.length <= 64);
  assert.ok(receipts instanceof Map && receipts.size > 0 && receipts.size <= 256);
  for (const field of ['casPath', 'codexPath', 'repositoryPath', 'storeRoot']) {
    assert.ok(typeof expected[field] === 'string' && isAbsolute(expected[field]) && normalize(expected[field]) === expected[field], 'noncanonical expected path');
  }
  const settingsPaths = expected.settingsPaths ?? [expected.settingsPath];
  assert.ok(Array.isArray(settingsPaths) && settingsPaths.length > 0 && settingsPaths.length <= 64);
  for (const path of settingsPaths) assert.ok(typeof path === 'string' && isAbsolute(path) && normalize(path) === path, 'noncanonical settings path');
  assert.match(expected.base, /^[0-9a-f]{40}$/);
  const byOutput = new Map(), admitted = new Map(), completed = new Set();
  const byExecution = new Map(observations?.map(value => [JSON.stringify([value.source, value.item]), value.name]) ?? []);
  let receiptBytes = 0;
  for (const [name, bytes] of receipts) {
    assert.ok(typeof name === 'string' && name.length > 0 && !isAbsolute(name) && !name.split('/').includes('..'), 'invalid receipt name');
    const output = withoutTerminalNewline(textBytes(bytes, 8 * 1024 * 1024));
    receiptBytes += bytes.length;
    assert.ok(receiptBytes <= 64 * 1024 * 1024, 'receipt inventory too large');
    const receipt = parseEvidenceJson(output);
    assert.ok(observations !== null || !byOutput.has(output), 'duplicate receipt output');
    byOutput.set(output, {name, receipt, digest: sha256(bytes)});
  }
  let totalBytes = 0, sequence = 0;
  for (let source = 0; source < eventsBytes.length; source++) {
    totalBytes += eventsBytes[source].length;
    assert.ok(totalBytes <= 128 * 1024 * 1024, 'runtime evidence too large');
    const lines = textBytes(eventsBytes[source], 64 * 1024 * 1024).split('\n');
    if (lines.at(-1) === '') lines.pop();
    assert.ok(lines.length > 0 && lines.length <= 100000, 'invalid runtime event count');
    let thread;
    for (const line of lines) {
      const event = parseEvidenceJson(line);
      if (event.type === 'thread.started') {
        assert.equal(thread, undefined, 'multiple runtime threads');
        assert.ok(typeof event.thread_id === 'string' && event.thread_id.length > 0, 'missing runtime thread');
        thread = event.thread_id;
      }
      if (event.type !== 'item.completed' || event.item?.type !== 'command_execution') continue;
      assert.ok(thread, 'command before runtime thread');
      const item = event.item;
      assert.ok(typeof item.id === 'string' && item.id.length > 0, 'missing runtime command identity');
      const identity = JSON.stringify([source, thread, item.id]);
      assert.ok(!completed.has(identity), 'duplicate completed runtime command');
      completed.add(identity);
      sequence++;
      assert.equal(typeof item.aggregated_output, 'string', 'missing runtime command output');
      const name = byExecution.get(JSON.stringify([source, item.id]));
      const match = observations === null ? byOutput.get(withoutTerminalNewline(item.aggregated_output)) :
        name === undefined ? undefined : {name, receipt: parseEvidenceJson(receipts.get(name)), digest: sha256(receipts.get(name))};
      if (match && observations !== null) assert.equal(item.aggregated_output, receipts.get(name).toString('utf8'), 'captured output differs from original receipt');
      if (!match) {
        assert.ok(!reviewCommand(item.command, expected.casPath), 'review receipt lacks exact runtime execution evidence');
        continue;
      }
      assert.ok(['completed', 'failed'].includes(item.status), 'review command incomplete');
      assert.ok(Number.isInteger(item.exit_code) && item.exit_code >= 0, 'review command has no terminal exit');
      if (item.exit_code !== 0 || item.status !== 'completed') {
        assert.equal(match.receipt.tupleVerdictExists, false, 'failed command cannot establish review verdict');
        assert.ok(match.receipt.timedOut === true || typeof match.receipt.failureCode === 'string', 'failed command lacks original failure evidence');
      }
      const {action, options} = commandArguments(item.command, expected);
      assert.equal(match.receipt.action, action, 'receipt action differs from execution');
      assert.equal(match.receipt.cwd, expected.repositoryPath, 'receipt repository differs from execution');
      assert.equal(match.receipt.baseSha, expected.base, 'receipt base differs from execution');
      assert.ok(!admitted.has(match.name), 'receipt has multiple runtime executions');
      admitted.set(match.name, {source, thread, item: item.id, sequence, action, command: item.command,
        exitCode: item.exit_code, freshAttempt: options.get('--fresh-attempt') ?? null,
        receiptSha256: match.digest, receipt: match.receipt, options});
    }
  }
  assert.equal(admitted.size, receipts.size, 'receipt lacks exact runtime execution evidence');
  for (const evidence of admitted.values()) {
    if (evidence.action !== 'wait') continue;
    const starts = [...admitted.values()].filter(start => start.action === 'start' &&
      start.sequence < evidence.sequence && start.receipt.reviewThreadId === evidence.receipt.reviewThreadId);
    assert.equal(starts.length, 1, 'wait lacks unique original start execution');
    const start = starts[0];
    assert.ok(typeof start.receipt.reviewThreadId === 'string' && start.receipt.reviewThreadId.length > 0);
    if (evidence.options.has('--review-thread-id')) assert.equal(evidence.options.get('--review-thread-id'), start.receipt.reviewThreadId, 'wait selected another attempt');
    else {
      assert.ok(typeof start.receipt.recordPath === 'string' && start.receipt.recordPath.startsWith(`${expected.storeRoot}/`), 'invalid original session path');
      assert.equal(evidence.options.get('--path'), start.receipt.recordPath, 'wait selected another session record');
    }
  }
  return new Map([...admitted].map(([name, {receipt, options, ...provenance}]) => [name, provenance]));
}
