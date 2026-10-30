import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {parseEvidenceJson} from './evidence-json.mjs';

export function executeGitHub(args, input, maximumBytes) {
  return new Promise((resolve, reject) => {
    const child = execFile('gh', args, {encoding: 'buffer', maxBuffer: maximumBytes, timeout: 60000},
      (error, stdout) => {
        if (error && (error.killed || error.signal || error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER')) reject(new Error('GitHub transport incomplete', {cause: error}));
        else resolve({code: error?.code ?? 0, stdout});
      });
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
}

export class HorosPublicationClient {
  constructor(execute = executeGitHub) { this.execute = execute; }

  async request({method = 'GET', path = '', body, binary = false, maximumBytes = 8 * 1024 * 1024}) {
    assert.ok(['GET', 'POST', 'PATCH'].includes(method), 'unsupported publication method');
    assert.ok(typeof path === 'string' && !/[\x00-\x20\x7f]/.test(path) && !path.split('/').some(part => part === '.' || part === '..'), 'invalid publication path');
    const upload = /^https:\/\/uploads\.github\.com\/repos\/tkersey\/horos\/releases\/[1-9][0-9]*\/assets\?name=[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(path);
    assert.ok(upload || path === '' || path.startsWith('/'), 'invalid repository path');
    assert.ok(upload ? method === 'POST' : !path.includes('://'), 'invalid publication destination');
    assert.ok(Number.isSafeInteger(maximumBytes) && maximumBytes > 0 && maximumBytes <= 512 * 1024 * 1024);
    const args = ['api', upload ? path : `repos/tkersey/horos${path}`, '--hostname', 'github.com',
      '--method', method, '--include', '-H', `Accept: ${binary ? 'application/octet-stream' : 'application/vnd.github+json'}`,
      '-H', 'X-GitHub-Api-Version: 2026-03-10'];
    let input;
    if (body !== undefined) {
      input = Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body));
      args.push('--input', '-', '-H', `Content-Type: ${Buffer.isBuffer(body) ? 'application/octet-stream' : 'application/json'}`);
    }
    const response = await this.execute(args, input, maximumBytes + 65536);
    assert.ok(Buffer.isBuffer(response.stdout), 'missing GitHub response');
    const boundary = response.stdout.indexOf('\r\n\r\n');
    assert.ok(boundary > 0 && boundary <= 65536, 'missing GitHub HTTP status');
    const header = response.stdout.subarray(0, boundary).toString('latin1');
    const match = /^HTTP\/[0-9.]+ ([1-5][0-9]{2})(?: [^\r\n]*)?\r?\n/.exec(`${header}\r\n`);
    assert.ok(match, 'invalid GitHub HTTP status');
    const status = Number(match[1]);
    assert.ok(response.code === 0 || status >= 400, 'GitHub transport failed');
    const bytes = response.stdout.subarray(boundary + 4);
    assert.ok(bytes.length <= maximumBytes, 'GitHub response exceeds bound');
    return {status, body: binary || bytes.length === 0 ? bytes : parseEvidenceJson(bytes)};
  }
}
