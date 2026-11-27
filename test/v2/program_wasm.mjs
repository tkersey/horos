import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";

const [probePath, emitter] = process.argv.slice(2);
const probe = await readFile(probePath);
const module = new WebAssembly.Module(probe);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const results = [];
for (const kind of ["install", "mixed", "irregular"]) {
  for (const count of [8, 256]) {
    const input = execFileSync(emitter, [String(count), kind], { maxBuffer: 1 << 20 });
    const { exports } = new WebAssembly.Instance(module, {});
    assert.ok(!(exports.memory.buffer instanceof SharedArrayBuffer));
    new Uint8Array(exports.memory.buffer, exports.compact_input_ptr(), input.length).set(input);
    const length = exports.program_encode(input.length);
    assert.equal(length, input.length, `${kind}-${count}`);
    const actual = new Uint8Array(exports.memory.buffer, exports.compact_output_ptr(), length);
    assert.deepEqual(actual, new Uint8Array(input));
    const identity = new Uint8Array(exports.memory.buffer, exports.program_identity_ptr(), 32);
    const expected = createHash("sha256").update("boundary.program/v3\0").update(input).digest();
    assert.deepEqual(identity, new Uint8Array(expected));
    assert.equal(exports.admitted_probe(input.length), 1, `${kind}-${count} immutable preparation`);
    assert.deepEqual(new Uint8Array(exports.memory.buffer, exports.program_identity_ptr(), 32), new Uint8Array(expected));
    results.push({ kind, count, bpi3: length, identity: expected.toString("hex") });
  }
}
for (const count of [8, 256]) {
  const plain = execFileSync(emitter, [String(count), "install"], { maxBuffer: 1 << 20 });
  const input = execFileSync(emitter, [String(count), "hinted"], { maxBuffer: 1 << 20 });
  assert.ok(input.length > plain.length, `hinted-${count} table`);
  assert.deepEqual(input.subarray(20, plain.length), plain.subarray(20), `hinted-${count} records`);
  const { exports } = new WebAssembly.Instance(module, {});
  new Uint8Array(exports.memory.buffer, exports.compact_input_ptr(), input.length).set(input);
  const length = exports.hinted_program_encode(input.length);
  assert.equal(length, input.length, `hinted-${count}`);
  const actual = new Uint8Array(exports.memory.buffer, exports.compact_output_ptr(), length);
  assert.deepEqual(actual, new Uint8Array(input));
  const identity = new Uint8Array(exports.memory.buffer, exports.program_identity_ptr(), 32);
  const expected = createHash("sha256").update("boundary.program/v3\0").update(input).digest();
  assert.deepEqual(identity, new Uint8Array(expected));
  const erased = exports.program_encode(input.length);
  assert.equal(erased, plain.length, `hinted-${count} erased`);
  const records = new Uint8Array(exports.memory.buffer, exports.compact_output_ptr(), erased);
  assert.deepEqual(records, new Uint8Array(plain));
  results.push({ kind: "hinted", count, bpi3: length, identity: expected.toString("hex") });
}
console.log(JSON.stringify({ check: "BPI3 native/wasm32 byte and identity agreement", results }));
